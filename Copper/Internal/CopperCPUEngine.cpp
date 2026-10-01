// Backend::CPU -- a from-scratch CPU port of CopperFDTD.metal's own kernels (update_e_interior,
// update_h_interior, cpml_correct_e/h, apply_excitation_e/h), not a port of
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
// shiftRowRightClampFirst()'s own comment. PML/CPML/excitation are comparatively tiny (a thin shell
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
                  const std::vector<CopperCPMLShell>& cpmlShells, const CopperDomainMask& domainMask,
                  const CopperZCPML& zcpml);

    void run(std::uint32_t steps) override;
    void runWithProbeSampling(std::uint32_t steps, const CopperEngine::ProbeSampler& sampler,
                               const CopperEngine::MidStepCorrection& midStepCorrection) override;
    void readField(CopperEngine::Field field, std::vector<float>& destination) const override;
    float readFieldCell(CopperEngine::Field field, std::uint32_t x, std::uint32_t y, std::uint32_t z) const override;
    void writeFieldCell(CopperEngine::Field field, std::uint32_t x, std::uint32_t y, std::uint32_t z,
                         float value) override;
    double estimateEnergy() const override;
    const CopperGridDims& dims() const override { return _dims; }

private:
    CopperGridDims _dims;
    std::vector<float> _eField[3];
    std::vector<float> _hField[3];
    std::vector<float> _vv[3], _vi[3], _ii[3], _iv[3];

    // Mutable copies -- CopperCPMLShell's own psiE0/psiE1/psiH0/psiH1 fields *are* this run's
    // auxiliary convolution state (zero-initialized by buildCPMLShells()), mutated in place below,
    // same as CopperEngine.mm's own zero-uploaded psi buffers.
    std::vector<CopperCPMLShell> _cpmlShells;

    // An irregular domain's Z-only CPML (see CopperZCPML) and its d/dz-driven psi for Ex, Ey, Hx,
    // Hy, nx*ny per graded plane. Applied as its own pass after the interior update, rather than
    // folded into it as on the GPU -- same arithmetic per cell either way.
    CopperZCPML _zcpml;
    std::vector<float> _zcpmlPsi[4];

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
    void cpmlCorrectE();
    void cpmlCorrectH();
    void zcpmlCorrectE();
    void zcpmlCorrectH();
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
                              const std::vector<CopperCPMLShell>& cpmlShells,
                              const CopperDomainMask& domainMask, const CopperZCPML& zcpml)
    : _dims(grid.dims),
      _cpmlShells(cpmlShells),
      _zcpml(zcpml),
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

    if (!_zcpml.empty()) {
        const std::size_t psiCount = static_cast<std::size_t>(_dims.nx) * _dims.ny * _zcpml.layerCount();
        for (auto& psi : _zcpmlPsi) psi.assign(psiCount, 0.0F);
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

void CPUEngineImpl::cpmlCorrectE() {
    for (CopperCPMLShell& shell : _cpmlShells) {
        for (std::uint32_t lz = 0; lz < shell.dims.nz; ++lz) {
            for (std::uint32_t ly = 0; ly < shell.dims.ny; ++ly) {
                for (std::uint32_t lx = 0; lx < shell.dims.nx; ++lx) {
                    const std::uint32_t x = lx + shell.startX, y = ly + shell.startY, z = lz + shell.startZ;
                    const std::uint32_t sx = (x != 0) ? 1 : 0, sy = (y != 0) ? 1 : 0, sz = (z != 0) ? 1 : 0;
                    const std::size_t localIdx = copperGridIndex(shell.dims, lx, ly, lz);
                    const std::size_t globalIdx = index(x, y, z);

                    // Ex: grading axes y (nP), z (nPP) -- same two terms as update_e_interior's own.
                    {
                        const float hzDiff = _hField[2][index(x, y, z)] - _hField[2][index(x, y - sy, z)];
                        const float hyDiff = _hField[1][index(x, y, z)] - _hField[1][index(x, y, z - sz)];
                        float& psi0 = shell.psiE0[0][localIdx];
                        float& psi1 = shell.psiE1[0][localIdx];
                        psi0 = shell.bE[1][localIdx] * psi0 + shell.cE[1][localIdx] * hzDiff;
                        psi1 = shell.bE[2][localIdx] * psi1 + shell.cE[2][localIdx] * hyDiff;
                        _eField[0][globalIdx] += _vi[0][globalIdx] * (psi0 - psi1);
                    }
                    // Ey: grading axes z (nP), x (nPP).
                    {
                        const float hxDiff = _hField[0][index(x, y, z)] - _hField[0][index(x, y, z - sz)];
                        const float hzDiff = _hField[2][index(x, y, z)] - _hField[2][index(x - sx, y, z)];
                        float& psi0 = shell.psiE0[1][localIdx];
                        float& psi1 = shell.psiE1[1][localIdx];
                        psi0 = shell.bE[2][localIdx] * psi0 + shell.cE[2][localIdx] * hxDiff;
                        psi1 = shell.bE[0][localIdx] * psi1 + shell.cE[0][localIdx] * hzDiff;
                        _eField[1][globalIdx] += _vi[1][globalIdx] * (psi0 - psi1);
                    }
                    // Ez: grading axes x (nP), y (nPP).
                    {
                        const float hyDiff = _hField[1][index(x, y, z)] - _hField[1][index(x - sx, y, z)];
                        const float hxDiff = _hField[0][index(x, y, z)] - _hField[0][index(x, y - sy, z)];
                        float& psi0 = shell.psiE0[2][localIdx];
                        float& psi1 = shell.psiE1[2][localIdx];
                        psi0 = shell.bE[0][localIdx] * psi0 + shell.cE[0][localIdx] * hyDiff;
                        psi1 = shell.bE[1][localIdx] * psi1 + shell.cE[1][localIdx] * hxDiff;
                        _eField[2][globalIdx] += _vi[2][globalIdx] * (psi0 - psi1);
                    }
                }
            }
        }
    }
}

void CPUEngineImpl::cpmlCorrectH() {
    for (CopperCPMLShell& shell : _cpmlShells) {
        for (std::uint32_t lz = 0; lz < shell.dims.nz; ++lz) {
            for (std::uint32_t ly = 0; ly < shell.dims.ny; ++ly) {
                for (std::uint32_t lx = 0; lx < shell.dims.nx; ++lx) {
                    const std::uint32_t x = lx + shell.startX, y = ly + shell.startY, z = lz + shell.startZ;
                    // Only cells satisfying update_h_interior's own (nx-1,ny-1,nz-1) dispatch bound
                    // have a meaningful H value to correct -- guard identically to cpml_correct_h.
                    if (x + 1 >= _dims.nx || y + 1 >= _dims.ny || z + 1 >= _dims.nz) {
                        continue;
                    }
                    const std::size_t localIdx = copperGridIndex(shell.dims, lx, ly, lz);
                    const std::size_t globalIdx = index(x, y, z);

                    // Hx: grading axes y (nP), z (nPP).
                    {
                        const float ezDiff = _eField[2][index(x, y, z)] - _eField[2][index(x, y + 1, z)];
                        const float eyDiff = _eField[1][index(x, y, z)] - _eField[1][index(x, y, z + 1)];
                        float& psi0 = shell.psiH0[0][localIdx];
                        float& psi1 = shell.psiH1[0][localIdx];
                        psi0 = shell.bH[1][localIdx] * psi0 + shell.cH[1][localIdx] * ezDiff;
                        psi1 = shell.bH[2][localIdx] * psi1 + shell.cH[2][localIdx] * eyDiff;
                        _hField[0][globalIdx] += _iv[0][globalIdx] * (psi0 - psi1);
                    }
                    // Hy: grading axes z (nP), x (nPP).
                    {
                        const float exDiff = _eField[0][index(x, y, z)] - _eField[0][index(x, y, z + 1)];
                        const float ezDiff = _eField[2][index(x, y, z)] - _eField[2][index(x + 1, y, z)];
                        float& psi0 = shell.psiH0[1][localIdx];
                        float& psi1 = shell.psiH1[1][localIdx];
                        psi0 = shell.bH[2][localIdx] * psi0 + shell.cH[2][localIdx] * exDiff;
                        psi1 = shell.bH[0][localIdx] * psi1 + shell.cH[0][localIdx] * ezDiff;
                        _hField[1][globalIdx] += _iv[1][globalIdx] * (psi0 - psi1);
                    }
                    // Hz: grading axes x (nP), y (nPP).
                    {
                        const float eyDiff = _eField[1][index(x, y, z)] - _eField[1][index(x + 1, y, z)];
                        const float exDiff = _eField[0][index(x, y, z)] - _eField[0][index(x, y + 1, z)];
                        float& psi0 = shell.psiH0[2][localIdx];
                        float& psi1 = shell.psiH1[2][localIdx];
                        psi0 = shell.bH[0][localIdx] * psi0 + shell.cH[0][localIdx] * eyDiff;
                        psi1 = shell.bH[1][localIdx] * psi1 + shell.cH[1][localIdx] * exDiff;
                        _hField[2][globalIdx] += _iv[2][globalIdx] * (psi0 - psi1);
                    }
                }
            }
        }
    }
}

// CopperFDTD.metal's updateE<true>/updateH<true> Z-only CPML terms (see CopperZCPML), over every node
// of each graded plane -- external nodes have zeroed coefficients here, so they stay at zero.
void CPUEngineImpl::zcpmlCorrectE() {
    if (_zcpml.empty()) return;
    const std::size_t nx = _dims.nx, nxny = nx * _dims.ny;
    for (std::uint32_t z = 0; z < _dims.nz; ++z) {
        const std::uint32_t layer = _zcpml.layerOfZ[z];
        if (layer == CopperZCPML::kNoLayer) continue;
        const float b = _zcpml.bE[layer], c = _zcpml.cE[layer];
        const std::size_t dz = z != 0 ? nxny : 0;
        for (std::uint32_t y = 0; y < _dims.ny; ++y) {
            for (std::uint32_t x = 0; x < _dims.nx; ++x) {
                const std::size_t g = index(x, y, z);
                const std::size_t p = x + nx * (y + static_cast<std::size_t>(_dims.ny) * layer);
                const float psiEx = b * _zcpmlPsi[0][p] + c * (_hField[1][g] - _hField[1][g - dz]);
                const float psiEy = b * _zcpmlPsi[1][p] + c * (_hField[0][g] - _hField[0][g - dz]);
                _zcpmlPsi[0][p] = psiEx;
                _zcpmlPsi[1][p] = psiEy;
                _eField[0][g] += _vi[0][g] * (0.0F - psiEx);
                _eField[1][g] += _vi[1][g] * psiEy;
            }
        }
    }
}

void CPUEngineImpl::zcpmlCorrectH() {
    if (_zcpml.empty()) return;
    const std::size_t nx = _dims.nx, nxny = nx * _dims.ny;
    for (std::uint32_t z = 0; z + 1 < _dims.nz; ++z) {
        const std::uint32_t layer = _zcpml.layerOfZ[z];
        if (layer == CopperZCPML::kNoLayer) continue;
        const float b = _zcpml.bH[layer], c = _zcpml.cH[layer];
        for (std::uint32_t y = 0; y + 1 < _dims.ny; ++y) {
            for (std::uint32_t x = 0; x + 1 < _dims.nx; ++x) {
                const std::size_t g = index(x, y, z);
                const std::size_t p = x + nx * (y + static_cast<std::size_t>(_dims.ny) * layer);
                const float psiHx = b * _zcpmlPsi[2][p] + c * (_eField[1][g] - _eField[1][g + nxny]);
                const float psiHy = b * _zcpmlPsi[3][p] + c * (_eField[0][g] - _eField[0][g + nxny]);
                _zcpmlPsi[2][p] = psiHx;
                _zcpmlPsi[3][p] = psiHy;
                _hField[0][g] += _iv[0][g] * (0.0F - psiHx);
                _hField[1][g] += _iv[1][g] * psiHy;
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

void CPUEngineImpl::runIterationPhase(IterationPhase phase) {
    const bool doVoltage = phase != IterationPhase::Current;
    const bool doCurrent = phase != IterationPhase::Voltage;

    // Voltage (E) update: update_e_interior -> cpml_correct_e -> apply_excitation_e.
    if (doVoltage) {
        updateEInterior();
        cpmlCorrectE();
        zcpmlCorrectE();
        applyExcitationE();
    }

    // Current (H) update: update_h_interior -> cpml_correct_h -> apply_excitation_h.
    if (doCurrent) {
        updateHInterior();
        cpmlCorrectH();
        zcpmlCorrectH();
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
                                                     const std::vector<CopperCPMLShell>& cpmlShells,
                                                     const CopperDomainMask& domainMask,
                                                     const CopperZCPML& zcpml) {
    return std::make_unique<CPUEngineImpl>(grid, excitation, cpmlShells, domainMask, zcpml);
}

} // namespace copper
