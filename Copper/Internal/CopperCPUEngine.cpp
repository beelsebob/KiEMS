// Backend::CPU -- a from-scratch CPU port of CopperFDTD.metal's own kernels (update_e_interior,
// update_h_interior and their CPML, apply_excitation_e/h), not a port of
// openEMS's own Engine: every formula below is transcribed directly from that .metal file (see its
// own top comment for where each one in turn came from), cyclically-permuted-per-axis and all, so
// there is exactly one place (that file) documenting the physics/openEMS correspondence, and this
// file's only job is reproducing the same arithmetic on the CPU.
//
// E/H fields and coefficients use the identical flat, x-fastest, copperGridIndex()-indexed layout
// CopperEngine's Metal backend keeps in its own MTLStorageModeShared buffers -- see
// CopperEngineBackend.hpp's own top comment for why (byte-for-byte interchangeable with the GPU
// buffers, the shared in-memory format a future hybrid CPU+GPU run over one grid would rely on).
//
// The interior update kernels (by far the hottest loops for any grid where the PML/CPML shell and
// excitation cell counts are a small fraction of the total cell count, which is every board this
// pipeline simulates) are vectorized one x-row at a time via Accelerate's vDSP, gated `#if
// __APPLE__` with a plain scalar fallback -- x is the fastest-varying axis in this layout, so a
// whole row (fixed y,z) is always contiguous, and every one of update_e_interior/update_h_interior's
// six per-component curl formulas turns out to need at most one *within-row* neighbor shift (the
// other neighbor read is always an entirely different, equally contiguous row) -- see
// shiftRowRightClampFirst()'s own comment. CPML and excitation are comparatively small (thin slabs
// or a handful of excited cells against a whole-grid update), so they stay plain per-cell scalar
// loops -- correctness-critical, intricate index math that isn't worth the added risk for a small
// fraction of total runtime.
#include "CopperEngineBackend.hpp"

#include <algorithm>
#include <cstdint>

#if defined(__APPLE__)
#include <Accelerate/Accelerate.h>
#endif

#include "CopperPhysicalConstants.hpp"

namespace copper {

namespace {

/// out[i] = vv[i]*out[i] + vi[i] * ((a0[i]-a1[i]) - (b0[i]-b1[i])), for i in [0,n) -- the curl-then-
/// blend formula every one of update_e_interior/update_h_interior's six per-component formulas
/// reduces to (CopperFDTD.metal's own comment documents each one's (a0,a1,b0,b1) in terms of
/// Hx/Hy/Hz or Ex/Ey/Ez); `a0`/`a1`/`b0`/`b1` are separate row pointers (possibly into the very same
/// underlying array, e.g. a shifted view -- see shiftRowRightClampFirst()), not `n`-contiguous
/// sub-ranges of one bigger buffer. `scratch0`/`scratch1` are caller-owned length->=n workspace,
/// reused across every row/axis in one interior-update pass rather than allocated per call.
void curlUpdateRow(const float* a0, const float* a1, const float* b0, const float* b1, const float* vv,
                    const float* vi, float* out, std::size_t n, float* scratch0, float* scratch1) {
    if (n == 0) {
        return;
    }
#if defined(__APPLE__)
    const auto len = static_cast<vDSP_Length>(n);
    // vDSP_vsub(B, A, C, N) computes C = A - B (B first, A second -- easy to get backwards).
    vDSP_vsub(a1, 1, a0, 1, scratch0, 1, len);             // scratch0 = a0 - a1
    vDSP_vsub(b1, 1, b0, 1, scratch1, 1, len);             // scratch1 = b0 - b1
    vDSP_vsub(scratch1, 1, scratch0, 1, scratch0, 1, len); // scratch0 = curl = (a0-a1) - (b0-b1)
    vDSP_vmul(vv, 1, out, 1, scratch1, 1, len);            // scratch1 = vv * out
    vDSP_vmul(vi, 1, scratch0, 1, scratch0, 1, len);       // scratch0 = vi * curl
    vDSP_vadd(scratch1, 1, scratch0, 1, out, 1, len);      // out = vv*out + vi*curl
#else
    (void)scratch0;
    (void)scratch1;
    for (std::size_t i = 0; i < n; ++i) {
        const float curl = (a0[i] - a1[i]) - (b0[i] - b1[i]);
        out[i] = vv[i] * out[i] + vi[i] * curl;
    }
#endif
}

/// shifted[0] = row[0]; shifted[i] = row[i-1] for i in [1,n) -- the whole-row materialization of
/// update_e_interior's own per-cell `s = (pos != 0) ? 1 : 0` shift-and-clamp-at-0 trick, needed only
/// when a curl term's neighbor is offset along x (the row's own axis) rather than y/z (an entirely
/// different, already-contiguous row read directly, no copy needed) -- e.g. Ey's `Hz[x-sx,y,z]`
/// term. Every element independently already encodes whichever of the two `sx` cases applies to it
/// (index 0 reads itself; every other index reads its left neighbor), so this needs no per-element
/// branch either.
void shiftRowRightClampFirst(const float* row, float* shifted, std::size_t n) {
    if (n == 0) {
        return;
    }
    shifted[0] = row[0];
    if (n > 1) {
        std::copy(row, row + (n - 1), shifted + 1);
    }
}

} // namespace

class CPUEngineImpl final : public EngineBackend {
public:
    CPUEngineImpl(const CopperYeeGrid& grid, const CopperExcitation& excitation,
                  const CopperCPML& cpml, const CopperDomainMask& domainMask);

    void run(std::uint32_t steps) override;
    void runWithProbeSampling(std::uint32_t steps, const CopperEngine::ProbeSampler& sampler,
                               const CopperEngine::MidStepCorrection& midStepCorrection) override;
    void readField(CopperEngine::Field field, std::vector<float>& destination) const override;
    float readFieldCell(CopperEngine::Field field, std::uint32_t x, std::uint32_t y, std::uint32_t z) const override;
    void writeFieldCell(CopperEngine::Field field, std::uint32_t x, std::uint32_t y, std::uint32_t z,
                         float value) override;
    double estimateEnergy() const override;
    const CopperGridDims& dims() const override { return _dims; }
    void setLumpedRLC(const std::vector<CopperLumpedRLCCell>& cells) override {
        _lumpedRLC = cells;
        _lumpedState.assign(cells.size(), {});
    }

private:
    // SERIES lumped RLC elements this engine corrects itself (CopperEngine::setLumpedRLC), with each
    // one's last three vdn and jn -- in double, like CopperFDTDRunner's CPU correction always was.
    struct LumpedRLCState {
        double vdn[3] = {0.0, 0.0, 0.0};
        double jn[3] = {0.0, 0.0, 0.0};
    };
    std::vector<CopperLumpedRLCCell> _lumpedRLC;
    std::vector<LumpedRLCState> _lumpedState;
    void applyLumpedRLC();

    CopperGridDims _dims;
    std::vector<float> _eField[3];
    std::vector<float> _hField[3];
    std::vector<float> _vv[3], _vi[3], _ii[3], _iv[3];

    // The CPML (see CopperCPML) and its psi: [E/H side][grading axis][term], laid out exactly as
    // the Metal backend's -- term 0 is component (w+1)%3's, term 1 component (w+2)%3's.
    CopperCPML _cpml;
    std::vector<float> _cpmlPsi[2][3][2];

    std::vector<CopperExcitationCell> _voltageCells;
    std::vector<CopperExcitationCell> _currentCells;
    std::vector<float> _voltageSignal;
    std::vector<float> _currentSignal;
    double _timestepSeconds = 0.0;
    double _signalPeriodSeconds = 0.0;
    std::uint32_t _currentTimestep = 0;

    // Row-length (nx) scratch space, reused across every row/axis of one interior-update pass rather
    // than allocated per call -- mutable since the update methods are logically non-const (they
    // mutate field state) but never called from a const context anyway; kept as plain members, not
    // thread-local, since one CPUEngineImpl is not used from multiple threads concurrently.
    std::vector<float> _scratch0, _scratch1, _scratchShift;

    enum class IterationPhase { Full, Voltage, Current };
    void runIterationPhase(IterationPhase phase);
    void updateEInterior();
    void updateHInterior();
    void applyCPML(int side);
    void applyExcitationE();
    void applyExcitationH();

    std::size_t index(std::uint32_t x, std::uint32_t y, std::uint32_t z) const {
        return copperGridIndex(_dims, x, y, z);
    }
    std::size_t rowBase(std::uint32_t y, std::uint32_t z) const {
        return static_cast<std::size_t>(_dims.nx) * (y + static_cast<std::size_t>(_dims.ny) * z);
    }
};

CPUEngineImpl::CPUEngineImpl(const CopperYeeGrid& grid, const CopperExcitation& excitation,
                              const CopperCPML& cpml, const CopperDomainMask& domainMask)
    : _dims(grid.dims),
      _cpml(cpml),
      _voltageCells(excitation.voltageCells),
      _currentCells(excitation.currentCells),
      _voltageSignal(excitation.voltageSignal),
      _currentSignal(excitation.currentSignal),
      _timestepSeconds(grid.timestepSeconds),
      _signalPeriodSeconds(excitation.signalPeriodSeconds) {
    const std::size_t cellCount = _dims.cellCount();
    for (int axis = 0; axis < 3; ++axis) {
        _eField[axis].assign(cellCount, 0.0F);
        _hField[axis].assign(cellCount, 0.0F);
        _vv[axis] = grid.vv[axis];
        _vi[axis] = grid.vi[axis];
        _ii[axis] = grid.ii[axis];
        _iv[axis] = grid.iv[axis];
        if (!domainMask.empty()) {
            for (std::uint32_t y = 0; y < _dims.ny; ++y) {
                for (std::uint32_t x = 0; x < _dims.nx; ++x) {
                    if (domainMask.at(x, y) != 0) continue;
                    for (std::uint32_t z = 0; z < _dims.nz; ++z) {
                        const std::size_t i = copperGridIndex(_dims, x, y, z);
                        _vv[axis][i] = _vi[axis][i] = _ii[axis][i] = _iv[axis][i] = 0.0F;
                    }
                }
            }
        }
    }
    float* const vv[3] = {_vv[0].data(), _vv[1].data(), _vv[2].data()};
    float* const vi[3] = {_vi[0].data(), _vi[1].data(), _vi[2].data()};
    float* const ii[3] = {_ii[0].data(), _ii[1].data(), _ii[2].data()};
    float* const iv[3] = {_iv[0].data(), _iv[1].data(), _iv[2].data()};
    applyRingAbsorber(domainMask, grid.timestepSeconds, _dims, vv, vi, ii, iv);

    for (auto& side : _cpmlPsi) {
        for (int axis = 0; axis < 3; ++axis) {
            for (auto& term : side[axis]) term.assign(_cpml.psiCount(_dims, axis), 0.0F);
        }
    }

    _scratch0.assign(_dims.nx, 0.0F);
    _scratch1.assign(_dims.nx, 0.0F);
    _scratchShift.assign(_dims.nx, 0.0F);
}

void CPUEngineImpl::updateEInterior() {
    const std::uint32_t nx = _dims.nx, ny = _dims.ny, nz = _dims.nz;
    for (std::uint32_t z = 0; z < nz; ++z) {
        const std::uint32_t sz = (z != 0) ? 1 : 0;
        for (std::uint32_t y = 0; y < ny; ++y) {
            const std::uint32_t sy = (y != 0) ? 1 : 0;
            const std::size_t base = rowBase(y, z);
            const std::size_t rowYm1 = rowBase(y - sy, z);
            const std::size_t rowZm1 = rowBase(y, z - sz);

            // Ex: (Hz_row(y,z) - Hz_row(y-sy,z)) - (Hy_row(y,z) - Hy_row(y,z-sz)) -- neither term
            // shifts along x, so both reads are whole, already-contiguous rows.
            curlUpdateRow(&_hField[2][base], &_hField[2][rowYm1], &_hField[1][base], &_hField[1][rowZm1],
                          &_vv[0][base], &_vi[0][base], &_eField[0][base], nx, _scratch0.data(), _scratch1.data());

            // Ey: (Hx_row(y,z) - Hx_row(y,z-sz)) - (Hz_row(y,z) - shiftX(Hz_row(y,z)))
            shiftRowRightClampFirst(&_hField[2][base], _scratchShift.data(), nx);
            curlUpdateRow(&_hField[0][base], &_hField[0][rowZm1], &_hField[2][base], _scratchShift.data(),
                          &_vv[1][base], &_vi[1][base], &_eField[1][base], nx, _scratch0.data(), _scratch1.data());

            // Ez: (Hy_row(y,z) - shiftX(Hy_row(y,z))) - (Hx_row(y,z) - Hx_row(y-sy,z))
            shiftRowRightClampFirst(&_hField[1][base], _scratchShift.data(), nx);
            curlUpdateRow(&_hField[1][base], _scratchShift.data(), &_hField[0][base], &_hField[0][rowYm1],
                          &_vv[2][base], &_vi[2][base], &_eField[2][base], nx, _scratch0.data(), _scratch1.data());
        }
    }
}

void CPUEngineImpl::updateHInterior() {
    // Dispatched over exactly (nx-1,ny-1,nz-1), matching update_h_interior's own dispatch size --
    // every pos+1 neighbor read below stays in bounds by construction (H physically exists on a
    // grid one cell smaller per axis than E).
    const std::uint32_t nx = _dims.nx;
    const std::uint32_t hnx = nx > 0 ? nx - 1 : 0;
    const std::uint32_t hny = _dims.ny > 0 ? _dims.ny - 1 : 0;
    const std::uint32_t hnz = _dims.nz > 0 ? _dims.nz - 1 : 0;
    for (std::uint32_t z = 0; z < hnz; ++z) {
        for (std::uint32_t y = 0; y < hny; ++y) {
            const std::size_t base = rowBase(y, z);
            const std::size_t rowYp1 = rowBase(y + 1, z);
            const std::size_t rowZp1 = rowBase(y, z + 1);

            // Hx: (Ez_row(y,z) - Ez_row(y+1,z)) - (Ey_row(y,z) - Ey_row(y,z+1)) -- both whole rows.
            curlUpdateRow(&_eField[2][base], &_eField[2][rowYp1], &_eField[1][base], &_eField[1][rowZp1],
                          &_ii[0][base], &_iv[0][base], &_hField[0][base], hnx, _scratch0.data(), _scratch1.data());

            // Hy: (Ex_row(y,z) - Ex_row(y,z+1)) - (Ez_row(y,z) - Ez_row(y,z)[x+1:]) -- the x+1 shift
            // needs no clamp (dispatch bound already guarantees x+1 < nx), so it's a zero-copy
            // pointer offset into the very same row, not a materialized shifted copy.
            curlUpdateRow(&_eField[0][base], &_eField[0][rowZp1], &_eField[2][base], &_eField[2][base + 1],
                          &_ii[1][base], &_iv[1][base], &_hField[1][base], hnx, _scratch0.data(), _scratch1.data());

            // Hz: (Ey_row(y,z) - Ey_row(y,z)[x+1:]) - (Ex_row(y,z) - Ex_row(y+1,z))
            curlUpdateRow(&_eField[1][base], &_eField[1][base + 1], &_eField[0][base], &_eField[0][rowYp1],
                          &_ii[2][base], &_iv[2][base], &_hField[2][base], hnx, _scratch0.data(), _scratch1.data());
        }
    }
}

// CopperFDTD.metal's cpmlTerms, as a pass after the interior update rather than folded into it --
// the same arithmetic per cell either way: each component's curl term gains psi0 - psi1, summed
// over the graded axes in order x, y, z. On the H side only update_h_interior's (nx-1, ny-1, nz-1)
// cells have an H to correct. External nodes of an irregular domain have zeroed coefficients here,
// so they stay at zero.
void CPUEngineImpl::applyCPML(int side) {
    if (_cpml.empty()) return;
    const bool h = side == 1;
    const std::uint32_t nx = _dims.nx, ny = _dims.ny, nz = _dims.nz;
    const std::uint32_t end[3] = {h ? nx - 1 : nx, h ? ny - 1 : ny, h ? nz - 1 : nz};
    std::vector<float>* const field = h ? _hField : _eField;
    const std::vector<float>* const in = h ? _eField : _hField;
    const std::vector<float>* const coefficient = h ? _iv : _vi;
    const std::size_t plane = static_cast<std::size_t>(nx) * ny;
    for (std::uint32_t z = 0; z < end[2]; ++z) {
        for (std::uint32_t y = 0; y < end[1]; ++y) {
            for (std::uint32_t x = 0; x < end[0]; ++x) {
                const std::uint32_t layer[3] = {_cpml.axes[0].layerOf[x], _cpml.axes[1].layerOf[y],
                                                _cpml.axes[2].layerOf[z]};
                if (layer[0] == CopperCPML::kNoLayer && layer[1] == CopperCPML::kNoLayer &&
                    layer[2] == CopperCPML::kNoLayer) {
                    continue;
                }
                const std::size_t g = index(x, y, z);
                // Each component's two curl differences as the update forms them: first (added),
                // second (subtracted). E reads the H below; H the E above.
                float t0[3], t1[3];
                if (h) {
                    const std::size_t dx = 1, dy = nx, dz = plane;
                    t0[0] = in[2][g] - in[2][g + dy];
                    t0[1] = in[0][g] - in[0][g + dz];
                    t0[2] = in[1][g] - in[1][g + dx];
                    t1[0] = in[1][g] - in[1][g + dz];
                    t1[1] = in[2][g] - in[2][g + dx];
                    t1[2] = in[0][g] - in[0][g + dy];
                } else {
                    const std::size_t dx = x != 0 ? 1 : 0, dy = y != 0 ? nx : 0, dz = z != 0 ? plane : 0;
                    t0[0] = in[2][g] - in[2][g - dy];
                    t0[1] = in[0][g] - in[0][g - dz];
                    t0[2] = in[1][g] - in[1][g - dx];
                    t1[0] = in[1][g] - in[1][g - dz];
                    t1[1] = in[2][g] - in[2][g - dx];
                    t1[2] = in[0][g] - in[0][g - dy];
                }
                float sum[3] = {0.0F, 0.0F, 0.0F};
                for (int w = 0; w < 3; ++w) {
                    if (layer[w] == CopperCPML::kNoLayer) continue;
                    const CopperCPML::Axis& axis = _cpml.axes[w];
                    const float b = h ? axis.bH[layer[w]] : axis.bE[layer[w]];
                    const float c = h ? axis.cH[layer[w]] : axis.cE[layer[w]];
                    const std::size_t layers = axis.layerCount();
                    const std::size_t p = w == 0   ? layer[w] + layers * (y + static_cast<std::size_t>(ny) * z)
                                          : w == 1 ? x + nx * (layer[w] + layers * z)
                                                   : x + nx * (y + static_cast<std::size_t>(ny) * layer[w]);
                    const int a = (w + 1) % 3, bb = (w + 2) % 3;
                    float& psiA = _cpmlPsi[side][w][0][p];
                    float& psiB = _cpmlPsi[side][w][1][p];
                    psiA = b * psiA + c * t1[a];
                    psiB = b * psiB + c * t0[bb];
                    sum[a] -= psiA;
                    sum[bb] += psiB;
                }
                for (int n = 0; n < 3; ++n) field[n][g] += coefficient[n][g] * sum[n];
            }
        }
    }
}

// applyExcitationCell()'s exc_pos formula is ported *exactly*, multiply-by-boolean tricks included,
// rather than rewritten as more obviously-equivalent branches -- see CopperExcitationCell's own doc
// comment: "clamp(timestep - delaySteps, 0, length-1 or wrapped by signalPeriodSeconds)" is the
// intent, but the actual behavior when exc_pos falls outside [0, length) is to read signal[0], not
// signal[length-1] -- reproducing that quirk exactly (matching CopperFDTD.metal's own
// applyExcitationCell) is the point.
void CPUEngineImpl::applyExcitationE() {
    if (_voltageCells.empty()) {
        return;
    }
    const auto numTS = static_cast<std::int32_t>(_currentTimestep);
    const std::int32_t period = (_signalPeriodSeconds > 0.0)
                                     ? static_cast<std::int32_t>(_signalPeriodSeconds / _timestepSeconds)
                                     : numTS + 1;
    const auto signalLength = static_cast<std::int32_t>(_voltageSignal.size());
    for (const CopperExcitationCell& cell : _voltageCells) {
        std::int32_t excPos = numTS - static_cast<std::int32_t>(cell.delaySteps);
        excPos *= static_cast<std::int32_t>(excPos > 0);
        excPos %= period;
        excPos *= static_cast<std::int32_t>(excPos < signalLength);
        const float value = cell.amplitude * _voltageSignal[static_cast<std::uint32_t>(excPos)];
        _eField[cell.axis][index(cell.x, cell.y, cell.z)] += value;
    }
}

void CPUEngineImpl::applyExcitationH() {
    if (_currentCells.empty()) {
        return;
    }
    const auto numTS = static_cast<std::int32_t>(_currentTimestep);
    const std::int32_t period = (_signalPeriodSeconds > 0.0)
                                     ? static_cast<std::int32_t>(_signalPeriodSeconds / _timestepSeconds)
                                     : numTS + 1;
    const auto signalLength = static_cast<std::int32_t>(_currentSignal.size());
    for (const CopperExcitationCell& cell : _currentCells) {
        std::int32_t excPos = numTS - static_cast<std::int32_t>(cell.delaySteps);
        excPos *= static_cast<std::int32_t>(excPos > 0);
        excPos %= period;
        excPos *= static_cast<std::int32_t>(excPos < signalLength);
        const float value = cell.amplitude * _currentSignal[static_cast<std::uint32_t>(excPos)];
        _hField[cell.axis][index(cell.x, cell.y, cell.z)] += value;
    }
}

// Engine_Ext_LumpedRLC::Apply2VoltagesImpl's SERIES branch, as CopperFDTDRunner applied it.
void CPUEngineImpl::applyLumpedRLC() {
    for (std::size_t i = 0; i < _lumpedRLC.size(); ++i) {
        const CopperLumpedRLCCell& cell = _lumpedRLC[i];
        LumpedRLCState& state = _lumpedState[i];
        state.vdn[2] = state.vdn[1];
        state.vdn[1] = state.vdn[0];
        state.jn[2] = state.jn[1];
        state.jn[1] = state.jn[0];
        float& field = _eField[cell.axis][index(cell.x, cell.y, cell.z)];
        const double vdn0 = static_cast<double>(cell.vvd) *
                            (static_cast<double>(field) + static_cast<double>(cell.vv2) * state.vdn[2] +
                             static_cast<double>(cell.vj1) * state.jn[1] + static_cast<double>(cell.vj2) * state.jn[2]);
        state.jn[0] = static_cast<double>(cell.ib0) * (vdn0 - state.vdn[2]) -
                      static_cast<double>(cell.b1) * static_cast<double>(cell.ib0) * state.jn[1] -
                      static_cast<double>(cell.b2) * static_cast<double>(cell.ib0) * state.jn[2];
        state.vdn[0] = vdn0;
        field = static_cast<float>(vdn0);
    }
}

void CPUEngineImpl::runIterationPhase(IterationPhase phase) {
    const bool doVoltage = phase != IterationPhase::Current;
    const bool doCurrent = phase != IterationPhase::Voltage;

    // Voltage (E) update: update_e_interior and its CPML -> apply_excitation_e -> lumped RLC.
    if (doVoltage) {
        updateEInterior();
        applyCPML(0);
        applyExcitationE();
        applyLumpedRLC();
    }

    // Current (H) update: update_h_interior and its CPML -> apply_excitation_h.
    if (doCurrent) {
        updateHInterior();
        applyCPML(1);
        applyExcitationH();
        ++_currentTimestep;
    }
}

void CPUEngineImpl::run(std::uint32_t steps) {
    for (std::uint32_t step = 0; step < steps; ++step) {
        runIterationPhase(IterationPhase::Full);
    }
}

void CPUEngineImpl::runWithProbeSampling(std::uint32_t steps, const CopperEngine::ProbeSampler& sampler,
                                          const CopperEngine::MidStepCorrection& midStepCorrection) {
    for (std::uint32_t step = 0; step < steps; ++step) {
        if (midStepCorrection) {
            runIterationPhase(IterationPhase::Voltage);
            midStepCorrection();
            runIterationPhase(IterationPhase::Current);
        } else {
            runIterationPhase(IterationPhase::Full);
        }
        if (!sampler(_currentTimestep)) {
            break;
        }
    }
}

void CPUEngineImpl::readField(CopperEngine::Field field, std::vector<float>& destination) const {
    const int axis = static_cast<int>(field) % 3;
    const bool isH = static_cast<int>(field) >= 3;
    destination = isH ? _hField[axis] : _eField[axis];
}

float CPUEngineImpl::readFieldCell(CopperEngine::Field field, std::uint32_t x, std::uint32_t y,
                                    std::uint32_t z) const {
    const int axis = static_cast<int>(field) % 3;
    const bool isH = static_cast<int>(field) >= 3;
    return (isH ? _hField[axis] : _eField[axis])[index(x, y, z)];
}

void CPUEngineImpl::writeFieldCell(CopperEngine::Field field, std::uint32_t x, std::uint32_t y, std::uint32_t z,
                                    float value) {
    const int axis = static_cast<int>(field) % 3;
    const bool isH = static_cast<int>(field) >= 3;
    (isH ? _hField[axis] : _eField[axis])[index(x, y, z)] = value;
}

double CPUEngineImpl::estimateEnergy() const {
    // Matches CopperEngine.mm's own estimateEnergy() exactly, including why the accumulation must
    // happen in double (a float32 sum-of-squares accumulator can spuriously overflow to inf on a
    // large/energetic real board even though every individual field value is still finite).
    const std::size_t n = _dims.cellCount();
    double eSumSq = 0.0;
    double hSumSq = 0.0;
#if defined(__APPLE__)
    std::vector<double> converted(n);
    for (int axis = 0; axis < 3; ++axis) {
        double axisSumSq = 0.0;
        vDSP_vspdp(_eField[axis].data(), 1, converted.data(), 1, static_cast<vDSP_Length>(n));
        vDSP_svesqD(converted.data(), 1, &axisSumSq, static_cast<vDSP_Length>(n));
        eSumSq += axisSumSq;

        vDSP_vspdp(_hField[axis].data(), 1, converted.data(), 1, static_cast<vDSP_Length>(n));
        vDSP_svesqD(converted.data(), 1, &axisSumSq, static_cast<vDSP_Length>(n));
        hSumSq += axisSumSq;
    }
#else
    for (int axis = 0; axis < 3; ++axis) {
        for (const float v : _eField[axis]) {
            eSumSq += static_cast<double>(v) * static_cast<double>(v);
        }
        for (const float v : _hField[axis]) {
            hSumSq += static_cast<double>(v) * static_cast<double>(v);
        }
    }
#endif
    return physical::epsilon0 * eSumSq + physical::mu0 * hSumSq;
}

std::unique_ptr<EngineBackend> makeCPUEngineBackend(const CopperYeeGrid& grid,
                                                     const CopperExcitation& excitation,
                                                     const CopperCPML& cpml,
                                                     const CopperDomainMask& domainMask) {
    return std::make_unique<CPUEngineImpl>(grid, excitation, cpml, domainMask);
}

} // namespace copper
