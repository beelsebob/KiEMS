#include "CopperFDTDRunner.h"

#include <algorithm>
#include <array>
#include <chrono>
#include <cerrno>
#include <cmath>
#include <condition_variable>
#include <cstdint>
#include <cstdio>
#include <fstream>
#include <limits>
#include <memory>
#include <mutex>
#include <optional>
#include <sstream>
#include <string>
#include <system_error>
#include <thread>
#include <utility>
#include <vector>

#include <mach/mach.h>

#include "FieldFrameSeriesWriter.hpp"
#include "Internal/CopperCPML.hpp"
#include "Internal/CopperDomain.hpp"
#include "Internal/CopperEngine.hpp"
#include "Internal/CopperExcitation.hpp"
#include "Internal/CopperFieldFrameSignposts.hpp"
#include "Internal/CopperLumpedRLC.hpp"
#include "Internal/CopperOperator.hpp"
#include "Internal/CopperPhysicalConstants.hpp"
#include "Internal/CopperProbes.hpp"
#include "Internal/CopperYeeGrid.hpp"

namespace copper {

double cpmlAlphaMaxForFrequency(double lowFrequencyHz) {
    return 2 * physical::pi * lowFrequencyHz * physical::epsilon0;
}

namespace {

// Converts the caller-supplied, Copper-native CopperFDTDPortConfig (see CopperFDTDRunner.h's own
// doc comment on it) into CopperOperator::Config -- a plain field-by-field translation, since the
// caller already computed every value directly from its own state (e.g. kiems::Simulation's
// boundaryIsPEC()/maxTimesteps()/excitationF0()/excitationFc()) instead of this file reading them
// back off an already-built, real openEMS Operator/Excitation (the old copperOperatorConfigFrom()
// this replaces required a full, genuine openEMS::SetupFDTD() call just to produce these 3 values,
// then threw away everything else it had computed -- confirmed in practice to roughly double
// per-port setup time on a real board).
CopperOperator::Config copperOperatorConfig(const CopperFDTDPortConfig& portConfig) {
    CopperOperator::Config config;
    for (std::size_t side = 0; side < 6; ++side) {
        config.boundary[side] =
            portConfig.boundaryIsPEC[side] ? CopperOperator::BoundaryType::PEC : CopperOperator::BoundaryType::Open;
    }
    config.f0 = portConfig.f0;
    config.fc = portConfig.fc;
    config.maxTimesteps = portConfig.maxTimesteps;
    return config;
}

// openEMS's own CPU RunFDTD() prints live "grab a cup of coffee" timestep/speed progress to
// stdout throughout the run -- runFDTDPortOnGPU had none of that until this instrumentation, which
// made a genuinely slow phase indistinguishable from a hung one (this is what prompted adding it:
// a real run against a large board looked stuck with zero visibility into which phase it was even
// in). Written to stdout (matching openems.cpp's own `cout <<`, not stderr) at the same cadence
// openEMS's own reporter uses -- `t_diff>4` (openems.cpp's RunFDTD loop): print at most once every
// 4 seconds of wall time, not every N steps, so the two backends' progress output reads at a
// comparable rate regardless of how many steps/second either one is actually managing. Kept
// intentionally lightweight (plain fprintf) rather than piped through kiems's own logging.hpp,
// since Copper.framework doesn't link libkiems (see the Copper implementation plan's "no
// dependency on Copper" rule, which cuts both ways).
// The exact metric Activity Monitor's own "Memory" column reports for this process (unlike RSS,
// phys_footprint already accounts for compression/dedup/purgeable state the way the OS actually
// charges it against the app). Paired with CopperEngine::currentAllocatedMetalBytes() in the
// periodic progress report below so a real run's console log shows, at the same cadence, how much
// of any observed growth is Metal-resident vs. everything else (plain heap, HDF5/Blosc2 buffers,
// mapped files, ...) -- without needing a full Instruments trace to tell the two apart.
std::size_t currentPhysFootprintBytes() {
    task_vm_info_data_t info;
    mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
    const kern_return_t result =
        task_info(mach_task_self(), TASK_VM_INFO, reinterpret_cast<task_info_t>(&info), &count);
    if (result != KERN_SUCCESS) {
        return 0;
    }
    return static_cast<std::size_t>(info.phys_footprint);
}

class PhaseTimer {
public:
    void mark(const char* phase) {
        const auto now = std::chrono::steady_clock::now();
        const double elapsed = std::chrono::duration<double>(now - _last).count();
        std::fprintf(stdout, "Copper: %s took %.2fs\n", phase, elapsed);
        _last = now;
    }

private:
    std::chrono::steady_clock::time_point _last = std::chrono::steady_clock::now();
};

// One reusable capture frame around the synchronous HDF5 writer. The former two-slot, sixteen-frame
// producer queue retained 32 *six-component* full-grid frames. On a large board that was over 100
// GiB before HDF5/Metal working memory. Applying back-pressure at every captured frame deliberately
// trades a little simulation throughput for a hard one-frame staging bound.
class BufferedFieldFrameSeriesWriter {
public:
    BufferedFieldFrameSeriesWriter(FieldFrameSeriesWriter writer, std::size_t cellCount)
        : _writer(std::move(writer)) {
        for (std::vector<float>& component : _components) {
            component.reserve(cellCount);
        }
    }

    BufferedFieldFrameSeriesWriter(const BufferedFieldFrameSeriesWriter&) = delete;
    BufferedFieldFrameSeriesWriter& operator=(const BufferedFieldFrameSeriesWriter&) = delete;

    ~BufferedFieldFrameSeriesWriter() { (void)close(); }

    std::expected<void, std::string> capture(CopperEngine& engine, std::uint32_t timestep,
                                              double timeSeconds) {
        if (_closed) {
            return std::unexpected("Field-frame capture requested after writer close");
        }

        const os_signpost_id_t frameSignpost = os_signpost_id_generate(fieldFrameSignpostLog());
        os_signpost_interval_begin(fieldFrameSignpostLog(), frameSignpost, "Generate field frame",
                                   "timestep=%u", timestep);
        for (std::size_t component = 0; component < _components.size(); ++component) {
            engine.readField(static_cast<CopperEngine::Field>(component), _components[component]);
        }
        os_signpost_interval_end(fieldFrameSignpostLog(), frameSignpost, "Generate field frame",
                                 "timestep=%u", timestep);
        errno = 0;
        auto written = _writer.writeFrame(timestep, timeSeconds, _components[0], _components[1],
                                          _components[2], _components[3], _components[4], _components[5]);
        if (!written && errno == ENOSPC) {
            return std::unexpected(written.error() + ": disk is full (no space left on device)");
        }
        if (!written && errno != 0) {
            return std::unexpected(written.error() + ": " +
                                   std::error_code(errno, std::generic_category()).message());
        }
        return written;
    }

    std::expected<void, std::string> close() {
        if (_closed) return {};
        _closed = true;
        return _writer.close();
    }

private:
    FieldFrameSeriesWriter _writer;
    std::array<std::vector<float>, 6> _components;
    bool _closed = false;
};

// Shared by runFDTDPortOnGPU/runFDTDPortOnCPU below -- the two differ only in which CopperEngine
// backend actually runs the leapfrog loop (see CopperFDTDRunner.h's own doc comment on
// runFDTDPortOnCPU for why that's a pure implementation-strategy choice, not a behavioral one).
CopperFDTDRunResult runFDTDPortImpl(ContinuousStructure& csx, const CopperFDTDPortConfig& portConfig,
                                     CopperEngine::Backend backend, const CopperFDTDProgressCallback& onProgress,
                                     double cpmlAlphaMax, std::uint32_t pmlDepthCells,
                                     const std::function<bool()>& isCancelled,
                                     const std::optional<FieldFrameSeriesRequest>& fieldFrameSeries) {
    CopperFDTDRunResult result;
    // See CopperFDTDRunner.h's own doc comment on cpmlAlphaMax's default -- 100MHz is every real
    // board this codebase has actually simulated so far, not an arbitrary round number.
    if (cpmlAlphaMax < 0.0) {
        // See CopperFDTDRunner.h's own doc comment on cpmlAlphaMax's default -- 100MHz is every
        // real board this codebase had actually simulated as of when that default was chosen, not
        // an arbitrary round number, but a caller with a lower configured sweep floor should prefer
        // cpmlAlphaMaxForFrequency() with that simulation's own value instead of relying on this.
        constexpr double kDefaultCpmlLowFrequencyHz = 100e6;
        cpmlAlphaMax = cpmlAlphaMaxForFrequency(kDefaultCpmlLowFrequencyHz);
    }
    PhaseTimer timer;
    try {
        if (onProgress) {
            onProgress(CopperFDTDProgress{CopperFDTDPhase::Setup, 0, 1, 0.0, 0.0, 0.0});
        }

        // CopperOperator replaces openEMS's own Operator/Excitation/Operator_Ext_Excitation/the
        // PARALLEL branch of Operator_Ext_LumpedRLC (see Internal/CopperOperator.hpp's own top
        // comment) -- config built directly from `portConfig` (see CopperFDTDPortConfig's own doc
        // comment for why that no longer means reading it back off a real, already-built Operator).
        // CPML never touches `grid` at all: its convolutional correction and matched residual decay
        // operate on top of the host medium's unmodified coefficients, so grid stays a plain,
        // single, const build for both boundary kinds.
        CopperOperator newOp(csx, copperOperatorConfig(portConfig));
        const CopperYeeGrid& grid = newOp.grid();
        if (!onProgress) {
            timer.mark("CopperOperator construction (mesh, coefficients, excitation)");
        }

        const CopperDomainMask domainMask = buildDomainMask(newOp, portConfig, pmlDepthCells);
        if (!domainMask.empty() && !onProgress) {
            const std::size_t total = domainMask.xyClass.size();
            std::size_t dispatched = 0;
            for (const auto& box : domainMask.dispatchBoxes)
                dispatched += static_cast<std::size_t>(box.width) * box.height;
            const std::size_t skipped = total > dispatched ? total - dispatched : 0;
            std::fprintf(stdout, "Copper: irregular XY domain dispatches %zu class-pure nodes and skips %zu/%zu "
                                 "enclosing-grid nodes (%.1f%%) in %zu cuboids\n",
                         dispatched, skipped, total,
                         total == 0 ? 0.0 : 100.0 * static_cast<double>(skipped) / static_cast<double>(total),
                         domainMask.dispatchBoxes.size());
        }
        // A rectangular domain gets the general per-face CPML; an irregular one only its Z slabs,
        // whose compact form the engines fold into the interior update (see CopperZCPML).
        std::vector<CopperCPMLShell> cpmlShells;
        CopperZCPML zcpml;
        if (domainMask.empty()) {
            cpmlShells = buildCPMLShells(newOp, cpmlAlphaMax, pmlDepthCells);
        } else {
            zcpml = buildZCPML(newOp, cpmlAlphaMax, pmlDepthCells);
        }
        std::uint64_t pmlCellTotal = 0;
        std::size_t shellCount = 0;
        shellCount = cpmlShells.size();
        for (const CopperCPMLShell& shell : cpmlShells) {
            pmlCellTotal += shell.dims.cellCount();
        }
        if (!zcpml.empty()) {
            std::uint64_t activeNodes = 0;
            for (const auto& box : domainMask.dispatchBoxes) activeNodes += std::uint64_t{box.width} * box.height;
            pmlCellTotal += activeNodes * zcpml.layerCount();
        }
        if (!onProgress) {
            timer.mark("buildCPMLShells");
            if (zcpml.empty()) {
                std::fprintf(stdout, "Copper: %zu PML shell(s), %llu cell(s) total\n", shellCount,
                             static_cast<unsigned long long>(pmlCellTotal));
            } else {
                std::fprintf(stdout, "Copper: Z-only CPML on %u z-plane(s), %llu cell(s) total\n",
                             zcpml.layerCount(), static_cast<unsigned long long>(pmlCellTotal));
            }
        }
        const CopperExcitation& excitation = newOp.excitation();
        if (excitation.voltageCells.empty() && excitation.currentCells.empty()) {
            result.errorMessage =
                "Copper: the enabled excitation does not intersect any Yee-grid cells; check the port geometry "
                "and mesh placement";
            return result;
        }
        // Auto-discovered lumped RLC components (kiems::Simulation::addLumpedComponents(), see
        // CopperLumpedRLC.hpp's own top comment) -- discovered once up front like `excitation`, but
        // corrected every timestep below via a rolling ADE state this run owns directly (mirrors
        // Engine_Ext_LumpedRLC's own Vdn/Jn ring buffers, since nothing here is a real openEMS
        // Engine that could own an Engine_Extension itself).
        const std::vector<CopperLumpedRLCCell> lumpedRLC = discoverLumpedRLC(csx, grid, newOp);
        struct LumpedRLCState {
            double vdn[3] = {0.0, 0.0, 0.0};
            double jn[3] = {0.0, 0.0, 0.0};
        };
        std::vector<LumpedRLCState> lumpedRLCState(lumpedRLC.size());
        if (!onProgress) {
            timer.mark("discoverLumpedRLC");
            if (!lumpedRLC.empty()) {
                std::fprintf(stdout, "Copper: %zu lumped RLC cell(s)\n", lumpedRLC.size());
            }
        }
        // Unconditional (unlike the !onProgress-gated lines above): the GUI app never sets up this
        // console at all otherwise, so these setup-time diagnostics -- exactly the ones useful for
        // telling apart "excitation/lumped-RLC coefficient is degenerate from the first timestep" from
        // "numerically unstable partway through" -- were invisible there. Also prints each lumped RLC
        // cell's own ADE coefficients (vvd/vv2/vj1/vj2/ib0/b1/b2): a single non-finite one here would
        // inject NaN into the field on literally the very first applyLumpedRLC() call, matching an
        // immediate-onset NaN.
        std::fprintf(stderr,
                     "Copper: setup -- %zu PML shell(s) + %u Z-only CPML plane(s) (%llu cell(s)), %zu voltage/%zu "
                     "current excitation cell(s), %zu lumped RLC cell(s)\n",
                     shellCount, zcpml.layerCount(), static_cast<unsigned long long>(pmlCellTotal),
                     excitation.voltageCells.size(),
                     excitation.currentCells.size(), lumpedRLC.size());
        for (std::size_t i = 0; i < lumpedRLC.size(); ++i) {
            const CopperLumpedRLCCell& cell = lumpedRLC[i];
            const bool allFinite = std::isfinite(cell.vvd) && std::isfinite(cell.vv2) && std::isfinite(cell.vj1) &&
                                    std::isfinite(cell.vj2) && std::isfinite(cell.ib0) && std::isfinite(cell.b1) &&
                                    std::isfinite(cell.b2);
            std::fprintf(stderr,
                         "Copper: lumped RLC[%zu] axis=%u (%u,%u,%u) vvd=%.6e vv2=%.6e vj1=%.6e vj2=%.6e "
                         "ib0=%.6e b1=%.6e b2=%.6e%s\n",
                         i, cell.axis, cell.x, cell.y, cell.z, cell.vvd, cell.vv2, cell.vj1, cell.vj2, cell.ib0,
                         cell.b1, cell.b2, allFinite ? "" : "  <-- NON-FINITE");
        }
        CopperEngine engine(grid, excitation, cpmlShells, backend, domainMask, zcpml);
        if (!onProgress) {
            timer.mark(backend == CopperEngine::Backend::CPU ? "CopperEngine construction (CPU coefficient upload)"
                                                              : "CopperEngine construction (GPU buffer upload)");
        }

        const std::vector<CopperProbe> probes = discoverProbes(csx, newOp);
        const std::uint32_t steps = portConfig.maxTimesteps;

        // Accumulated in memory, not streamed to disk -- see CopperFDTDRunResult's own doc comment.
        // One entry per probe, sized/reserved up front so the per-timestep loop below never
        // reallocates.
        result.probes.resize(probes.size());
        for (std::size_t i = 0; i < probes.size(); ++i) {
            result.probes[i].name = probes[i].name;
            result.probes[i].kind =
                probes[i].type == CopperProbeType::Voltage ? CopperProbeKind::Voltage : CopperProbeKind::Current;
            result.probes[i].samples.reserve(steps);
        }
        if (!onProgress) {
            timer.mark("discoverProbes");
        }

        if (onProgress) {
            onProgress(CopperFDTDProgress{CopperFDTDPhase::Setup, 1, 1, 0.0, 0.0, 0.0});
        } else {
            std::fprintf(stdout, "Copper: running %u timesteps on %zu cell(s), %zu probe(s)...\n", steps,
                         static_cast<std::size_t>(grid.dims.cellCount()), probes.size());
        }
        const auto runStart = std::chrono::steady_clock::now();
        auto lastPrint = runStart;
        std::uint32_t lastPrintStep = 0;
        // Per-cell accessors, not full-array reads -- a probe box only ever touches a handful of
        // cells, so reading it via CopperEngine::readFieldCell (O(1), no allocation) rather than
        // readField() (a full cellCount()-length copy) is the difference between this loop costing
        // a few dozen memory reads per timestep and multiple hundred-megabyte copies per timestep.
        // Confirmed in practice: the latter was the dominant cost of a real multi-million-cell board
        // run before this existed.
        auto eField = [&](std::uint32_t axis, std::uint32_t x, std::uint32_t y, std::uint32_t z) {
            return engine.readFieldCell(static_cast<CopperEngine::Field>(static_cast<int>(axis)), x, y, z);
        };
        auto hField = [&](std::uint32_t axis, std::uint32_t x, std::uint32_t y, std::uint32_t z) {
            return engine.readFieldCell(static_cast<CopperEngine::Field>(static_cast<int>(axis) + 3), x, y, z);
        };

        // Field-frame time series for spatial visualization (see CopperFDTDRunResult's own doc
        // comment) -- mesh geometry is static for the whole run, captured once here; per-frame
        // energy is captured periodically inside the timestep loop below, at a cadence bounded by
        // kFieldFrameBudget rather than a fixed wall-clock interval, so an hours-long run doesn't
        // accumulate thousands of multi-megabyte frames.
        result.fieldSnapshot.dims = {grid.dims.nx, grid.dims.ny, grid.dims.nz};
        result.fieldSnapshot.lineX.assign(grid.lineX.begin(), grid.lineX.end());
        result.fieldSnapshot.lineY.assign(grid.lineY.begin(), grid.lineY.end());
        result.fieldSnapshot.lineZ.assign(grid.lineZ.begin(), grid.lineZ.end());

        // Opt-in persistence of field frames to disk instead of retaining them in the result -- see
        // FieldFrameSeriesRequest's own doc comment. A failure here is reported by leaving
        // result.fieldFrameSeriesPath empty; the caller decides whether losing visualization data
        // should also invalidate the otherwise-complete probe result.
        std::unique_ptr<BufferedFieldFrameSeriesWriter> fieldFrameSeriesWriter;
        std::optional<std::string> fieldFrameSeriesFailure;
        if (fieldFrameSeries) {
            FieldFrameSeriesWriter::Header header;
            header.simulationName = fieldFrameSeries->simulationName;
            header.excitedPort = fieldFrameSeries->excitedPort;
            header.nx = grid.dims.nx;
            header.ny = grid.dims.ny;
            header.nz = grid.dims.nz;
            header.timestepSeconds = grid.timestepSeconds;
            header.boardZMin = fieldFrameSeries->boardZMin;
            header.boardZMax = fieldFrameSeries->boardZMax;
            header.lineX.assign(grid.lineX.begin(), grid.lineX.end());
            header.lineY.assign(grid.lineY.begin(), grid.lineY.end());
            header.lineZ.assign(grid.lineZ.begin(), grid.lineZ.end());
            header.domainXYClass = domainMask.xyClass;
            errno = 0;
            auto writer = FieldFrameSeriesWriter::create(fieldFrameSeries->path, header, fieldFrameSeries->chunkFrames);
            const int writerCreationErrno = errno;
            if (writer) {
                if (fieldFrameSeries->onWriterReady) {
                    fieldFrameSeries->onWriterReady(fieldFrameSeries->path);
                }
                fieldFrameSeriesWriter = std::make_unique<BufferedFieldFrameSeriesWriter>(
                    std::move(*writer), static_cast<std::size_t>(grid.dims.cellCount()));
            } else {
                result.errorMessage = "Could not create field frame-series file " +
                                      fieldFrameSeries->path.string() + ": " + writer.error();
                if (writerCreationErrno == ENOSPC) {
                    result.errorMessage += ": disk is full (no space left on device)";
                } else if (writerCreationErrno != 0) {
                    result.errorMessage += ": " +
                                           std::error_code(writerCreationErrno, std::generic_category()).message();
                }
                return result;
            }
        }

        const std::uint32_t minCaptureStepSpacing = 1000;
        std::uint32_t lastCaptureStep = 0;
        std::uint32_t capturedFrameCount = 0;
        auto captureFieldFrame = [&](std::uint32_t globalTimestep) {
            lastCaptureStep = globalTimestep;
            ++capturedFrameCount;

            if (fieldFrameSeriesWriter) {
                // Capture applies immediate back-pressure: at most one reusable six-component CPU
                // frame exists while its preview and spatial detail tiles are encoded.
                auto written = fieldFrameSeriesWriter->capture(
                    engine, globalTimestep, static_cast<double>(globalTimestep) * grid.timestepSeconds);
                if (!written) {
                    std::fprintf(stderr, "Copper: field frame-series write failed, disabling further writes: %s\n",
                                 written.error().c_str());
                    fieldFrameSeriesFailure = "Could not write field-frame data to " +
                                              fieldFrameSeries->path.string() + ": " + written.error();
                    fieldFrameSeriesWriter.reset();
                }
            } else if (!fieldFrameSeries) {
                // Preserve the original result for callers which did not request a series. The app
                // always supplies one, so its full-grid frames never accumulate in memory.
                const std::vector<float> ex = engine.readField(CopperEngine::Field::Ex);
                const std::vector<float> ey = engine.readField(CopperEngine::Field::Ey);
                const std::vector<float> ez = engine.readField(CopperEngine::Field::Ez);
                const std::vector<float> hx = engine.readField(CopperEngine::Field::Hx);
                const std::vector<float> hy = engine.readField(CopperEngine::Field::Hy);
                const std::vector<float> hz = engine.readField(CopperEngine::Field::Hz);
                CopperFieldFrame frame;
                frame.timestep = globalTimestep;
                frame.timeSeconds = static_cast<double>(globalTimestep) * grid.timestepSeconds;
                const std::size_t cellCount = ex.size();
                frame.cellEnergy.resize(cellCount);
                for (std::size_t i = 0; i < cellCount; ++i) {
                    const float eSq = ex[i] * ex[i] + ey[i] * ey[i] + ez[i] * ez[i];
                    const float hSq = hx[i] * hx[i] + hy[i] * hy[i] + hz[i] * hz[i];
                    frame.cellEnergy[i] = static_cast<float>(physical::epsilon0) * eSq +
                                          static_cast<float>(physical::mu0) * hSq;
                }
                result.fieldSnapshot.frames.push_back(std::move(frame));
            }
        };

        // Energy-decay end criteria, matching openEMS's own RunFDTD() loop (openems.cpp) exactly:
        // `endCrit = 1e-6` is openEMS's own default (-60dB, `endCrit = pow(10, -dB/10)`; openEMS
        // itself hardcodes this same default, see openems.cpp's own `endCrit = 1e-6` -- not
        // currently exposed as a config option on either backend, so hardcoding it here matches
        // reality rather than pretending it's configurable). `maxEnergy` tracks the highest energy
        // ever observed (effectively the excitation pulse's own peak, once it's fully entered the
        // domain); `energyChange = currentEnergy/maxEnergy` is compared against `endCriteria` at the
        // same >4s cadence as the progress print below (openEMS's own RunFDTD() computes both in the
        // same `t_diff>4` block) -- CalcFastEnergy()/estimateEnergy() is cheap enough (a couple of
        // vDSP sum-of-squares calls) that computing it more often would just be wasted work, not
        // more useful information.
        constexpr double endCriteria = 1e-6;
        double maxEnergy = 0.0;
        double energyChange = 1.0; // matches RunFDTD()'s own `double change=1;` initial value
        bool endCriteriaReached = false;
        bool cancelled = false;
        std::uint32_t stepsActuallyRun = 0;

        // Lumped RLC correction: a direct, SERIES-only port of
        // Engine_Ext_LumpedRLC::Apply2VoltagesImpl (engine_ext_lumpedRLC.cpp).
        // This callback runs after the GPU voltage phase has completed and
        // before the current phase is encoded, exactly matching
        // Engine::IterateTS. Omitting the callback entirely when no lumped
        // cells exist preserves CopperEngine's single-command-buffer fast path
        // for ordinary boards.
        CopperEngine::MidStepCorrection applyLumpedRLC;
        if (!lumpedRLC.empty()) {
            applyLumpedRLC = [&]() {
                for (std::size_t i = 0; i < lumpedRLC.size(); ++i) {
                    const CopperLumpedRLCCell& cell = lumpedRLC[i];
                    LumpedRLCState& state = lumpedRLCState[i];
                    state.vdn[2] = state.vdn[1];
                    state.vdn[1] = state.vdn[0];
                    state.jn[2] = state.jn[1];
                    state.jn[1] = state.jn[0];

                    const auto field = static_cast<CopperEngine::Field>(cell.axis);
                    double vdn0 = static_cast<double>(engine.readFieldCell(field, cell.x, cell.y, cell.z));
                    vdn0 = static_cast<double>(cell.vvd) *
                           (vdn0 + static_cast<double>(cell.vv2) * state.vdn[2] +
                            static_cast<double>(cell.vj1) * state.jn[1] + static_cast<double>(cell.vj2) * state.jn[2]);
                    state.jn[0] = static_cast<double>(cell.ib0) * (vdn0 - state.vdn[2]) -
                                  static_cast<double>(cell.b1) * static_cast<double>(cell.ib0) * state.jn[1] -
                                  static_cast<double>(cell.b2) * static_cast<double>(cell.ib0) * state.jn[2];
                    state.vdn[0] = vdn0;
                    engine.writeFieldCell(field, cell.x, cell.y, cell.z, static_cast<float>(vdn0));
                }
            };
        }

        // Captures the true pristine initial condition (E=H=0, before any leapfrog update has run)
        // as frame 0 -- CopperEngine::runWithProbeSampling()'s own sampler callback never actually
        // receives globalTimestep==0 (its first invocation is always 1, *after* the first step has
        // already landed; see CopperEngine::Impl::currentTimestep's own doc comment), so a
        // `globalTimestep == 0` check inside that callback -- which this file used to have -- was
        // silently unreachable and the series' own first frame was simply missing. This is the only
        // place that value is ever actually captured.
        captureFieldFrame(0);

        const double plannedSimulationTimeSeconds = static_cast<double>(steps) * grid.timestepSeconds;
        const double excitationEndTimeSeconds =
            std::min(static_cast<double>(excitation.voltageSignal.size()) * grid.timestepSeconds,
                     plannedSimulationTimeSeconds);
        // Publish the timing envelope before the first (wall-clock-throttled) energy report. This
        // lets live charts start at their final X scale and show the excitation interval instead
        // of growing horizontally for the first several seconds.
        if (onProgress) {
            const double targetDB = std::fabs(10.0 * std::log10(endCriteria));
            onProgress(CopperFDTDProgress{CopperFDTDPhase::FDTDRun, 0, steps, 0.0, targetDB, 0.0,
                                          !excitation.voltageSignal.empty(), 0.0, excitationEndTimeSeconds,
                                          plannedSimulationTimeSeconds, portConfig.f0, portConfig.fc});
        }

        engine.runWithProbeSampling(
            steps,
            [&](std::uint32_t globalTimestep) -> bool {
                stepsActuallyRun = globalTimestep;

                for (std::size_t i = 0; i < probes.size(); ++i) {
                    const CopperProbe& probe = probes[i];
                    // Voltage probes sample at t=numTS*dT; current probes at
                    // t=(numTS+0.5)*dT -- see
                    // Engine_Interface_Base::GetTime(dualTime) and openems.cpp's
                    // own SetDualTime(true) for ProbeType==1, which this mirrors
                    // (see CopperProbes.hpp's own doc comments). Weight applied
                    // here (matching ProcessIntegral::Process's own `m_Results[n] *
                    // m_weight`) so every stored sample is already final -- see
                    // CopperProbeResult's own doc comment.
                    if (probe.type == CopperProbeType::Voltage) {
                        const double t = static_cast<double>(globalTimestep) * grid.timestepSeconds;
                        result.probes[i].samples.push_back({t, sampleVoltageProbe(probe, eField) * probe.weight});
                    } else {
                        const double t = (static_cast<double>(globalTimestep) + 0.5) * grid.timestepSeconds;
                        result.probes[i].samples.push_back({t, sampleCurrentProbe(probe, hField) * probe.weight});
                    }
                }

                const auto now = std::chrono::steady_clock::now();
                const double sinceLastPrint = std::chrono::duration<double>(now - lastPrint).count();
                if (sinceLastPrint > 4.0 || globalTimestep == steps) {
                    const double elapsed = std::chrono::duration<double>(now - runStart).count();
                    const double stepRate = sinceLastPrint / static_cast<double>(globalTimestep - lastPrintStep);

                    const double currentEnergy = engine.estimateEnergy();
                    if (currentEnergy > maxEnergy) {
                        maxEnergy = currentEnergy;
                    }
                    if (maxEnergy > 0.0) {
                        energyChange = currentEnergy / maxEnergy;
                    }
                    const double energyChangeDB = std::fabs(10.0 * std::log10(energyChange));
                    const double targetDB = std::fabs(10.0 * std::log10(endCriteria));

                    // Diagnostic for tracking down real, Activity-Monitor-visible memory growth that
                    // doesn't show up in Instruments' malloc-based Allocations/Leaks tools (Metal
                    // buffers aren't heap allocations) -- logged unconditionally (both GUI and CLI
                    // paths, stderr so it interleaves with the CLI's own stdout progress line without
                    // getting swallowed by it) at the same cadence as the rest of this block.
                    // processFootprintGB is phys_footprint -- the same number Activity Monitor's own
                    // "Memory" column reports for this process -- so subtracting metalAllocatedGB from
                    // it isolates exactly how much of any growth is Metal-resident vs. everything else
                    // (plain heap, HDF5/Blosc2 buffers, mapped files, ...), at the same per-timestep
                    // resolution, without a full Instruments trace.
                    const double metalAllocatedGB =
                        static_cast<double>(engine.currentAllocatedMetalBytes()) / (1024.0 * 1024.0 * 1024.0);
                    const double processFootprintGB =
                        static_cast<double>(currentPhysFootprintBytes()) / (1024.0 * 1024.0 * 1024.0);
                    std::fprintf(stderr,
                                 "Copper: [@ %7.1fs] timestep %u/%u -- Metal allocated: %.3f GB, process "
                                 "footprint: %.3f GB\n",
                                 elapsed, globalTimestep, steps, metalAllocatedGB, processFootprintGB);

                    if (onProgress) {
                        const bool duringExcitation = globalTimestep < excitation.voltageSignal.size();
                        onProgress(CopperFDTDProgress{CopperFDTDPhase::FDTDRun, globalTimestep, steps, energyChangeDB,
                                                      targetDB, currentEnergy, duringExcitation,
                                                      static_cast<double>(globalTimestep) * grid.timestepSeconds,
                                                      excitationEndTimeSeconds, plannedSimulationTimeSeconds,
                                                      portConfig.f0, portConfig.fc});
                    } else {
                        std::fprintf(stdout,
                                     "Copper: [@ %7.1fs] timestep %u/%u || Speed: "
                                     "%.4f s/step || Energy: ~%.2e (-%.2fdB)\n",
                                     elapsed, globalTimestep, steps, stepRate, currentEnergy, energyChangeDB);
                    }
                    lastPrint = now;
                    lastPrintStep = globalTimestep;

                    if (energyChange <= endCriteria) {
                        endCriteriaReached = true;
                    }
                }
                // Periodic capture piggybacks on the same >4s wall-clock check above (so a
                // field-frame capture never adds its own separate timing pass), and only actually
                // captures once at least minCaptureStepSpacing steps have passed since the last one
                // -- bounding the total frame count regardless of how long the run itself takes.
                // The final step's own state is captured unconditionally, deliberately NOT gated
                // behind the wall-clock check too -- a run whose last step happens to land <4s after
                // the previous progress tick (common on a short/fast run) would otherwise silently
                // drop its own last frame the same way frame 0 used to be dropped (see this
                // function's own captureFieldFrame(0) call, above the loop).
                if (globalTimestep == steps ||
                    (sinceLastPrint > 4.0 && globalTimestep - lastCaptureStep >= minCaptureStepSpacing)) {
                    captureFieldFrame(globalTimestep);
                }
                // Checked every timestep (not gated behind the >4s wall-clock
                // block above, unlike the energy check) -- cancellation should
                // take effect within a timestep or two, not wait for the next
                // progress-reporting tick.
                if (isCancelled && isCancelled()) {
                    cancelled = true;
                }
                return !endCriteriaReached && !cancelled && !fieldFrameSeriesFailure.has_value();
            },
            applyLumpedRLC);
        // No "zero frames captured" fallback needed here any more -- captureFieldFrame(0) above the
        // loop and the unconditional `globalTimestep == steps` capture inside it together already
        // guarantee at least the initial and final states are always captured, even for a run that
        // never crosses the periodic >4s wall-clock cadence at all.
        if (!onProgress) {
            timer.mark("FDTD run (all timesteps + per-timestep probe sampling)");
            if (endCriteriaReached) {
                std::fprintf(stdout, "Copper: end criteria of -%.2fdB reached after %u timesteps, stopping early\n",
                             std::fabs(10.0 * std::log10(endCriteria)), stepsActuallyRun);
            } else {
                std::fprintf(stdout,
                             "Copper: RunFDTD: Warning: Max. number of timesteps was reached before the "
                             "end-criteria of -%.2fdB was reached...\n",
                             std::fabs(10.0 * std::log10(endCriteria)));
            }
        }

        if (!onProgress) {
            timer.mark("field snapshot capture (6x readField + per-cell energy, per frame)");
            std::fprintf(stdout, "Copper: captured %u field frame(s)\n", capturedFrameCount);
        }

        if (fieldFrameSeriesWriter) {
            // Best-effort even here -- a cancelled run (see `cancelled` below) still leaves
            // whatever frames were captured before cancellation as a valid, reopenable file (every
            // completed chunk was already flushed inside captureFieldFrame/writeFrame); this just
            // finalizes the last, possibly-partial chunk.
            errno = 0;
            if (auto closed = fieldFrameSeriesWriter->close(); !closed) {
                std::fprintf(stderr, "Copper: field frame-series close() failed: %s\n", closed.error().c_str());
                fieldFrameSeriesFailure = "Could not finish field-frame data in " +
                                          fieldFrameSeries->path.string() + ": " + closed.error();
                if (errno == ENOSPC) {
                    *fieldFrameSeriesFailure += ": disk is full (no space left on device)";
                } else if (errno != 0) {
                    *fieldFrameSeriesFailure += ": " +
                                                std::error_code(errno, std::generic_category()).message();
                }
            } else {
                result.fieldFrameSeriesPath = fieldFrameSeries->path;
            }
        }

        if (fieldFrameSeriesFailure.has_value()) {
            result.errorMessage = *fieldFrameSeriesFailure;
        } else if (cancelled) {
            // Deliberately !success -- probes and the field series/snapshot above only hold whatever
            // partial data was gathered before the sampler stopped early, not a complete run. See
            // CopperFDTDRunResult::cancelled's own doc comment for why a caller should check this
            // before treating an unsuccessful result as a genuine failure.
            result.cancelled = true;
            result.errorMessage = "Cancelled";
        } else {
            result.success = true;
        }
    } catch (const std::exception& error) {
        result.errorMessage = std::string("Copper FDTD run failed: ") + error.what();
    }
    return result;
}

} // namespace

CopperFDTDRunResult runFDTDPortOnGPU(ContinuousStructure& csx, const CopperFDTDPortConfig& portConfig,
                                      const CopperFDTDProgressCallback& onProgress, double cpmlAlphaMax,
                                      std::uint32_t pmlDepthCells,
                                      const std::function<bool()>& isCancelled,
                                      const std::optional<FieldFrameSeriesRequest>& fieldFrameSeries) {
    return runFDTDPortImpl(csx, portConfig, CopperEngine::Backend::Metal, onProgress, cpmlAlphaMax,
                            pmlDepthCells, isCancelled, fieldFrameSeries);
}

CopperFDTDRunResult runFDTDPortOnCPU(ContinuousStructure& csx, const CopperFDTDPortConfig& portConfig,
                                      const CopperFDTDProgressCallback& onProgress, double cpmlAlphaMax,
                                      std::uint32_t pmlDepthCells,
                                      const std::function<bool()>& isCancelled,
                                      const std::optional<FieldFrameSeriesRequest>& fieldFrameSeries) {
    return runFDTDPortImpl(csx, portConfig, CopperEngine::Backend::CPU, onProgress, cpmlAlphaMax,
                            pmlDepthCells, isCancelled, fieldFrameSeries);
}

std::string dumpEarlyFrames(ContinuousStructure& csx, const CopperFDTDPortConfig& portConfig,
                             const std::filesystem::path& outputDir, std::uint32_t frameCount,
                             std::uint32_t marginCells, double cpmlAlphaMax,
                             std::uint32_t pmlDepthCells) {
    if (cpmlAlphaMax < 0.0) {
        // See CopperFDTDRunner.h's own doc comment on cpmlAlphaMax's default -- 100MHz is every
        // real board this codebase had actually simulated as of when that default was chosen, not
        // an arbitrary round number, but a caller with a lower configured sweep floor should prefer
        // cpmlAlphaMaxForFrequency() with that simulation's own value instead of relying on this.
        constexpr double kDefaultCpmlLowFrequencyHz = 100e6;
        cpmlAlphaMax = cpmlAlphaMaxForFrequency(kDefaultCpmlLowFrequencyHz);
    }
    try {
        CopperOperator newOp(csx, copperOperatorConfig(portConfig));
        const CopperYeeGrid& grid = newOp.grid();
        std::fprintf(stdout, "Copper dumpEarlyFrames: grid %ux%ux%u\n", grid.dims.nx, grid.dims.ny, grid.dims.nz);

        std::vector<CopperCPMLShell> cpmlShells = buildCPMLShells(newOp, cpmlAlphaMax, pmlDepthCells);
        const CopperExcitation& excitation = newOp.excitation();
        std::fprintf(stdout, "Copper dumpEarlyFrames: %zu voltage excitation cell(s), %zu current\n",
                     excitation.voltageCells.size(), excitation.currentCells.size());
        CopperEngine engine(grid, excitation, cpmlShells);

        // Crop box: the excitation cells' own bounding box, expanded by marginCells in every
        // direction, clamped to the grid -- small enough to write/analyze quickly while still
        // covering plenty of margin beyond wherever propagation is supposed to reach in
        // `frameCount` timesteps (a correctly-coupled leapfrog stencil advances its domain of
        // dependence by exactly one cell per timestep, so `frameCount` >> marginCells would mean
        // the crop itself, not the physics, is what's limiting how far this dump can show -- keep
        // frameCount comparable to or smaller than marginCells for this dump to stay meaningful).
        std::uint32_t x0 = grid.dims.nx, x1 = 0, y0 = grid.dims.ny, y1 = 0, z0 = grid.dims.nz, z1 = 0;
        bool anyExcitationCell = false;
        auto expand = [&](const CopperExcitationCell& cell) {
            anyExcitationCell = true;
            x0 = std::min(x0, cell.x);
            x1 = std::max(x1, cell.x);
            y0 = std::min(y0, cell.y);
            y1 = std::max(y1, cell.y);
            z0 = std::min(z0, cell.z);
            z1 = std::max(z1, cell.z);
        };
        for (const CopperExcitationCell& cell : excitation.voltageCells) {
            expand(cell);
        }
        for (const CopperExcitationCell& cell : excitation.currentCells) {
            expand(cell);
        }
        if (!anyExcitationCell) {
            return "Copper dumpEarlyFrames: no excitation cells found to center the crop box on";
        }
        auto clampSub = [](std::uint32_t v, std::uint32_t margin) -> std::uint32_t {
            return margin > v ? 0 : v - margin;
        };
        const std::uint32_t cropX0 = clampSub(x0, marginCells);
        const std::uint32_t cropY0 = clampSub(y0, marginCells);
        const std::uint32_t cropZ0 = clampSub(z0, marginCells);
        const std::uint32_t cropX1 = std::min(x1 + marginCells, grid.dims.nx - 1);
        const std::uint32_t cropY1 = std::min(y1 + marginCells, grid.dims.ny - 1);
        const std::uint32_t cropZ1 = std::min(z1 + marginCells, grid.dims.nz - 1);
        const std::uint32_t cropNx = cropX1 - cropX0 + 1;
        const std::uint32_t cropNy = cropY1 - cropY0 + 1;
        const std::uint32_t cropNz = cropZ1 - cropZ0 + 1;
        std::fprintf(stdout,
                     "Copper dumpEarlyFrames: crop [%u..%u]x[%u..%u]x[%u..%u] (%ux%ux%u = %llu cell(s))\n", cropX0,
                     cropX1, cropY0, cropY1, cropZ0, cropZ1, cropNx, cropNy, cropNz,
                     static_cast<unsigned long long>(cropNx) * cropNy * cropNz);

        std::error_code mkdirError;
        std::filesystem::create_directories(outputDir, mkdirError);

        // meta.txt: everything needed to interpret coefficients.bin/fields.bin without guessing --
        // grid/crop dims, per-axis primary mesh line positions (metres), the excitation cell list
        // (so the reader knows exactly which crop-local cell(s) are being directly driven each
        // step, as opposed to which are receiving coupled energy), and the timestep itself.
        {
            std::ofstream meta(outputDir / "meta.txt");
            meta << "nx " << grid.dims.nx << "\n";
            meta << "ny " << grid.dims.ny << "\n";
            meta << "nz " << grid.dims.nz << "\n";
            meta << "cropX0 " << cropX0 << "\n";
            meta << "cropY0 " << cropY0 << "\n";
            meta << "cropZ0 " << cropZ0 << "\n";
            meta << "cropNx " << cropNx << "\n";
            meta << "cropNy " << cropNy << "\n";
            meta << "cropNz " << cropNz << "\n";
            meta << "frameCount " << frameCount << "\n";
            meta << "timestepSeconds " << grid.timestepSeconds << "\n";
            meta << "boundaryKind CPML\n";
            meta << "fieldOrder Ex Ey Ez Hx Hy Hz\n";
            meta << "coefficientOrder vv0 vv1 vv2 vi0 vi1 vi2 ii0 ii1 ii2 iv0 iv1 iv2\n";
            meta.precision(9);
            meta << "excitationCells";
            for (const CopperExcitationCell& cell : excitation.voltageCells) {
                meta << " V:" << cell.x << "," << cell.y << "," << cell.z << "," << cell.axis << ","
                     << cell.amplitude;
            }
            for (const CopperExcitationCell& cell : excitation.currentCells) {
                meta << " I:" << cell.x << "," << cell.y << "," << cell.z << "," << cell.axis << ","
                     << cell.amplitude;
            }
            meta << "\n";
            meta << "lineX";
            for (float v : grid.lineX) {
                meta << " " << v;
            }
            meta << "\n";
            meta << "lineY";
            for (float v : grid.lineY) {
                meta << " " << v;
            }
            meta << "\n";
            meta << "lineZ";
            for (float v : grid.lineZ) {
                meta << " " << v;
            }
            meta << "\n";
        }

        // A cropped, flattened (x fastest-varying, matching copperGridIndex()) copy of one full-grid
        // array -- shared by both the coefficient dump (static, from `grid`) and the per-step field
        // dump (from `engine.readFieldCell()`) below.
        auto writeCroppedFullArray = [&](std::ofstream& out, const std::vector<float>& full) {
            for (std::uint32_t z = cropZ0; z <= cropZ1; ++z) {
                for (std::uint32_t y = cropY0; y <= cropY1; ++y) {
                    for (std::uint32_t x = cropX0; x <= cropX1; ++x) {
                        const float v = full[copperGridIndex(grid.dims, x, y, z)];
                        out.write(reinterpret_cast<const char*>(&v), sizeof(float));
                    }
                }
            }
        };

        // coefficients.bin: 12 cropped arrays back-to-back, order matches meta.txt's own
        // "coefficientOrder" line -- static for the whole run (openEMS bakes material/boundary
        // condition into these once, at setup), so this is the one part of the dump that's only
        // written once, not per-step.
        {
            std::ofstream coeffFile(outputDir / "coefficients.bin", std::ios::binary);
            for (unsigned axis = 0; axis < 3; ++axis) {
                writeCroppedFullArray(coeffFile, grid.vv[axis]);
            }
            for (unsigned axis = 0; axis < 3; ++axis) {
                writeCroppedFullArray(coeffFile, grid.vi[axis]);
            }
            for (unsigned axis = 0; axis < 3; ++axis) {
                writeCroppedFullArray(coeffFile, grid.ii[axis]);
            }
            for (unsigned axis = 0; axis < 3; ++axis) {
                writeCroppedFullArray(coeffFile, grid.iv[axis]);
            }
        }

        // fields.bin: `frameCount` frames back-to-back, each frame six cropped arrays back-to-back
        // (Ex,Ey,Ez,Hx,Hy,Hz, matching meta.txt's own "fieldOrder" line) -- one real timestep
        // between each frame (engine.run(1), not runWithProbeSampling's batched form), so frame N
        // is the field state immediately after global timestep N+1.
        {
            std::ofstream fieldsFile(outputDir / "fields.bin", std::ios::binary);
            const std::array<CopperEngine::Field, 6> fields = {
                CopperEngine::Field::Ex, CopperEngine::Field::Ey, CopperEngine::Field::Ez,
                CopperEngine::Field::Hx, CopperEngine::Field::Hy, CopperEngine::Field::Hz,
            };
            for (std::uint32_t step = 0; step < frameCount; ++step) {
                engine.run(1);
                for (const CopperEngine::Field field : fields) {
                    for (std::uint32_t z = cropZ0; z <= cropZ1; ++z) {
                        for (std::uint32_t y = cropY0; y <= cropY1; ++y) {
                            for (std::uint32_t x = cropX0; x <= cropX1; ++x) {
                                const float v = engine.readFieldCell(field, x, y, z);
                                fieldsFile.write(reinterpret_cast<const char*>(&v), sizeof(float));
                            }
                        }
                    }
                }
                if (step % 10 == 0 || step + 1 == frameCount) {
                    std::fprintf(stdout, "Copper dumpEarlyFrames: step %u/%u\n", step + 1, frameCount);
                }
            }
        }

        std::fprintf(stdout, "Copper dumpEarlyFrames: wrote %u frame(s) to %s\n", frameCount,
                     outputDir.string().c_str());
        return {};
    } catch (const std::exception& error) {
        return std::string("Copper dumpEarlyFrames failed: ") + error.what();
    }
}

std::string dumpDetailedTrace(ContinuousStructure& csx, const CopperFDTDPortConfig& portConfig,
                               std::uint32_t stepCount, std::uint32_t boxSide, double cpmlAlphaMax,
                               std::uint32_t pmlDepthCells) {
    if (cpmlAlphaMax < 0.0) {
        // See CopperFDTDRunner.h's own doc comment on cpmlAlphaMax's default -- 100MHz is every
        // real board this codebase had actually simulated as of when that default was chosen, not
        // an arbitrary round number, but a caller with a lower configured sweep floor should prefer
        // cpmlAlphaMaxForFrequency() with that simulation's own value instead of relying on this.
        constexpr double kDefaultCpmlLowFrequencyHz = 100e6;
        cpmlAlphaMax = cpmlAlphaMaxForFrequency(kDefaultCpmlLowFrequencyHz);
    }
    try {
        CopperOperator newOp(csx, copperOperatorConfig(portConfig));
        const CopperYeeGrid& grid = newOp.grid();
        std::vector<CopperCPMLShell> cpmlShells = buildCPMLShells(newOp, cpmlAlphaMax, pmlDepthCells);
        const CopperExcitation& excitation = newOp.excitation();
        CopperEngine engine(grid, excitation, cpmlShells);

        std::uint32_t x0 = grid.dims.nx, x1 = 0, y0 = grid.dims.ny, y1 = 0, z0 = grid.dims.nz, z1 = 0;
        bool anyExcitationCell = false;
        auto expand = [&](const CopperExcitationCell& cell) {
            anyExcitationCell = true;
            x0 = std::min(x0, cell.x);
            x1 = std::max(x1, cell.x);
            y0 = std::min(y0, cell.y);
            y1 = std::max(y1, cell.y);
            z0 = std::min(z0, cell.z);
            z1 = std::max(z1, cell.z);
        };
        for (const CopperExcitationCell& cell : excitation.voltageCells) {
            expand(cell);
        }
        for (const CopperExcitationCell& cell : excitation.currentCells) {
            expand(cell);
        }
        if (!anyExcitationCell) {
            return "Copper dumpDetailedTrace: no excitation cells found to center the box on";
        }

        auto centerStart = [](std::uint32_t lo, std::uint32_t hi, std::uint32_t n,
                               std::uint32_t side) -> std::uint32_t {
            if (side >= n) {
                return 0;
            }
            const std::uint32_t center = (lo + hi) / 2;
            std::uint32_t start = center >= side / 2 ? center - side / 2 : 0;
            if (start + side > n) {
                start = n - side;
            }
            return start;
        };
        const std::uint32_t boxX0 = centerStart(x0, x1, grid.dims.nx, boxSide);
        const std::uint32_t boxY0 = centerStart(y0, y1, grid.dims.ny, boxSide);
        const std::uint32_t boxZ0 = centerStart(z0, z1, grid.dims.nz, boxSide);
        const std::uint32_t boxX1 = std::min(boxX0 + boxSide, grid.dims.nx) - 1;
        const std::uint32_t boxY1 = std::min(boxY0 + boxSide, grid.dims.ny) - 1;
        const std::uint32_t boxZ1 = std::min(boxZ0 + boxSide, grid.dims.nz) - 1;

        std::fprintf(stdout,
                     "Copper dumpDetailedTrace: grid %ux%ux%u dt=%.9e box=[%u..%u]x[%u..%u]x[%u..%u] (%u cell(s)) "
                     "steps=%u boundaryKind=CPML\n",
                     grid.dims.nx, grid.dims.ny, grid.dims.nz, grid.timestepSeconds, boxX0, boxX1, boxY0, boxY1,
                     boxZ0, boxZ1, (boxX1 - boxX0 + 1) * (boxY1 - boxY0 + 1) * (boxZ1 - boxZ0 + 1), stepCount);

        // Is the tiny-coefficient anomaly localized to the excited port, or present everywhere in
        // the domain? Sample vv/vi at points spread across the *whole* grid, not just the crop box
        // -- domain center, each axis's own midpoint offset, and a corner well away from the port.
        {
            const std::uint32_t cx = grid.dims.nx / 2, cy = grid.dims.ny / 2, cz = grid.dims.nz / 2;
            const struct {
                const char* label;
                std::uint32_t x, y, z;
            } samples[] = {
                {"domain center", cx, cy, cz},
                {"center, x/4", grid.dims.nx / 4, cy, cz},
                {"center, y/4", cx, grid.dims.ny / 4, cz},
                {"center, z near board mid", cx, cy, grid.dims.nz / 2},
                {"far corner (low x/y, mid z)", 5, 5, cz},
                {"far corner (high x/y, mid z)", grid.dims.nx - 6, grid.dims.ny - 6, cz},
                // Isolating which axis of the excited port (61, ~42, ~25) is responsible: each of
                // these swaps exactly one of the port's own coordinates in for the domain-center
                // value, keeping the other two at domain center.
                {"port's own X, center Y/Z", 61, cy, cz},
                {"center X, port's own Y, center Z", cx, 42, cz},
                {"center X/Y, port's own Z", cx, cy, 25},
                {"port's own X/Y, center Z", 61, 42, cz},
                {"port's own X/Y/Z (matches the excited cell exactly)", 61, 42, 25},
            };
            for (const auto& s : samples) {
                if (s.x >= grid.dims.nx || s.y >= grid.dims.ny || s.z >= grid.dims.nz) {
                    continue;
                }
                const std::uint32_t sidx = copperGridIndex(grid.dims, s.x, s.y, s.z);
                std::fprintf(stdout,
                             "Copper dumpDetailedTrace: GLOBAL SAMPLE [%s] (%u,%u,%u): vv0=%.6e vv1=%.6e vv2=%.6e "
                             "vi0=%.6e vi1=%.6e vi2=%.6e\n",
                             s.label, s.x, s.y, s.z, static_cast<double>(grid.vv[0][sidx]),
                             static_cast<double>(grid.vv[1][sidx]), static_cast<double>(grid.vv[2][sidx]),
                             static_cast<double>(grid.vi[0][sidx]), static_cast<double>(grid.vi[1][sidx]),
                             static_cast<double>(grid.vi[2][sidx]));
            }
            // Full Z sweep at domain-center X/Y -- isolating exactly which Z indices are affected
            // (the port's own Z, 25, collapsed vi2 by ~11 orders of magnitude independent of X/Y --
            // this maps the real transition point(s) along Z, rather than assuming where the
            // board-vs-PML/margin boundary sits).
            for (std::uint32_t z = 0; z < grid.dims.nz; ++z) {
                const std::uint32_t sidx = copperGridIndex(grid.dims, cx, cy, z);
                std::fprintf(stdout,
                             "Copper dumpDetailedTrace: Z SWEEP z=%u lineZ=%.6e: vv2=%.6e vi2=%.6e\n", z,
                             static_cast<double>(grid.lineZ[z]), static_cast<double>(grid.vv[2][sidx]),
                             static_cast<double>(grid.vi[2][sidx]));
            }
        }
        // Primary AND dual (H-grid) mesh line positions around the box, with a margin -- edge
        // length/area (and so vv/vi/ii/iv) depend on BOTH, not just the primary line spacing already
        // checked; a bug specific to dual-mesh placement wouldn't show up in primary spacing alone.
        auto printLines = [&](const char* label, const std::vector<float>& lines, std::uint32_t lo,
                               std::uint32_t hi) {
            const std::uint32_t margin = 2;
            const std::uint32_t start = lo > margin ? lo - margin : 0;
            const std::uint32_t end = std::min<std::uint32_t>(hi + margin, static_cast<std::uint32_t>(lines.size()) - 1);
            std::fprintf(stdout, "Copper dumpDetailedTrace: %s[%u..%u] =", label, start, end);
            for (std::uint32_t i = start; i <= end; ++i) {
                std::fprintf(stdout, " %.9e", static_cast<double>(lines[i]));
            }
            std::fprintf(stdout, "\n");
        };
        printLines("lineX", grid.lineX, boxX0, boxX1);
        printLines("lineY", grid.lineY, boxY0, boxY1);
        printLines("lineZ", grid.lineZ, boxZ0, boxZ1);
        printLines("dualLineX", grid.dualLineX, boxX0, boxX1);
        printLines("dualLineY", grid.dualLineY, boxY0, boxY1);
        printLines("dualLineZ", grid.dualLineZ, boxZ0, boxZ1);
        for (const CopperExcitationCell& c : excitation.voltageCells) {
            std::fprintf(stdout,
                         "Copper dumpDetailedTrace: voltage-excited cell (%u,%u,%u) axis=%u amplitude=%.9e "
                         "delaySteps=%u\n",
                         c.x, c.y, c.z, c.axis, static_cast<double>(c.amplitude), c.delaySteps);
        }
        for (const CopperExcitationCell& c : excitation.currentCells) {
            std::fprintf(stdout,
                         "Copper dumpDetailedTrace: current-excited cell (%u,%u,%u) axis=%u amplitude=%.9e "
                         "delaySteps=%u\n",
                         c.x, c.y, c.z, c.axis, static_cast<double>(c.amplitude), c.delaySteps);
        }
        const std::size_t signalPreview = std::min<std::size_t>(stepCount + 2, excitation.voltageSignal.size());
        std::fprintf(stdout, "Copper dumpDetailedTrace: voltageSignal[0..%zu] =", signalPreview);
        for (std::size_t i = 0; i < signalPreview; ++i) {
            std::fprintf(stdout, " %.9e", static_cast<double>(excitation.voltageSignal[i]));
        }
        std::fprintf(stdout, "\n");
        const std::size_t currentSignalPreview = std::min<std::size_t>(stepCount + 2, excitation.currentSignal.size());
        std::fprintf(stdout, "Copper dumpDetailedTrace: currentSignal[0..%zu] =", currentSignalPreview);
        for (std::size_t i = 0; i < currentSignalPreview; ++i) {
            std::fprintf(stdout, " %.9e", static_cast<double>(excitation.currentSignal[i]));
        }
        std::fprintf(stdout, "\n");

        auto excPosFor = [](std::int32_t numTS, std::uint32_t delaySteps, std::int32_t period,
                             std::uint32_t signalLength) -> std::int32_t {
            std::int32_t excPos = numTS - static_cast<std::int32_t>(delaySteps);
            excPos *= (excPos > 0) ? 1 : 0;
            excPos %= period;
            excPos *= (excPos < static_cast<std::int32_t>(signalLength)) ? 1 : 0;
            return excPos;
        };
        auto excitationContribution = [&](std::uint32_t x, std::uint32_t y, std::uint32_t z, std::uint32_t axis,
                                           bool isVoltage, std::int32_t numTS, std::int32_t period) -> float {
            const std::vector<CopperExcitationCell>& cells =
                isVoltage ? excitation.voltageCells : excitation.currentCells;
            const std::vector<float>& signal = isVoltage ? excitation.voltageSignal : excitation.currentSignal;
            for (const CopperExcitationCell& c : cells) {
                if (c.x == x && c.y == y && c.z == z && c.axis == axis) {
                    const std::int32_t excPos =
                        excPosFor(numTS, c.delaySteps, period, static_cast<std::uint32_t>(signal.size()));
                    return c.amplitude * signal[static_cast<std::size_t>(excPos)];
                }
            }
            return 0.0F;
        };

        const std::array<const char*, 3> axisName = {"x", "y", "z"};

        for (std::uint32_t step = 0; step < stepCount; ++step) {
            const auto numTS = static_cast<std::int32_t>(step);
            const std::int32_t period = excitation.signalPeriodSeconds > 0.0
                                             ? static_cast<std::int32_t>(excitation.signalPeriodSeconds /
                                                                          grid.timestepSeconds)
                                             : numTS + 1;

            std::fprintf(stdout, "\n=== Copper dumpDetailedTrace: step %u (numTS=%d, period=%d) ===\n", step, numTS,
                         period);
            for (const CopperExcitationCell& c : excitation.voltageCells) {
                const std::int32_t excPos =
                    excPosFor(numTS, c.delaySteps, period, static_cast<std::uint32_t>(excitation.voltageSignal.size()));
                const float signalValue = excitation.voltageSignal[static_cast<std::size_t>(excPos)];
                const float value = c.amplitude * signalValue;
                std::fprintf(stdout,
                             "  voltage excitation (%u,%u,%u) axis=%s: excPos=%d signal=%.9e amplitude=%.9e "
                             "contribution=%.9e\n",
                             c.x, c.y, c.z, axisName[c.axis], excPos, static_cast<double>(signalValue),
                             static_cast<double>(c.amplitude), static_cast<double>(value));
            }

            // --- Capture every term needed to predict this step's E and H updates *before* letting
            // the GPU actually run it, then compare predicted vs actual once it has. H's own curl
            // term needs the *new* E (computed earlier in the same iteration), so only H's own old
            // value/coefficients are captured now; its curl is read fresh after engine.run(1).
            struct ETrace {
                std::uint32_t x, y, z, axis;
                float oldE, h0, h1, h2, h3, curlDiff, vv, vi, predictedBeforeExc, excContribution, predictedAfterExc;
            };
            struct HPending {
                std::uint32_t x, y, z, axis;
                float oldH, ii, iv;
            };
            std::vector<ETrace> eTraces;
            std::vector<HPending> hPending;

            for (std::uint32_t z = boxZ0; z <= boxZ1; ++z) {
                for (std::uint32_t y = boxY0; y <= boxY1; ++y) {
                    for (std::uint32_t x = boxX0; x <= boxX1; ++x) {
                        const std::uint32_t sx = (x != 0) ? 1 : 0;
                        const std::uint32_t sy = (y != 0) ? 1 : 0;
                        const std::uint32_t sz = (z != 0) ? 1 : 0;
                        const std::uint32_t idx = copperGridIndex(grid.dims, x, y, z);

                        for (std::uint32_t axis = 0; axis < 3; ++axis) {
                            const auto eField = static_cast<CopperEngine::Field>(axis);
                            const float oldE = engine.readFieldCell(eField, x, y, z);
                            float h0 = 0, h1 = 0, h2 = 0, h3 = 0;
                            if (axis == 0) { // Ex: Hz(x,y,z) - Hz(x,y-sy,z) - Hy(x,y,z) + Hy(x,y,z-sz)
                                h0 = engine.readFieldCell(CopperEngine::Field::Hz, x, y, z);
                                h1 = engine.readFieldCell(CopperEngine::Field::Hz, x, y - sy, z);
                                h2 = engine.readFieldCell(CopperEngine::Field::Hy, x, y, z);
                                h3 = engine.readFieldCell(CopperEngine::Field::Hy, x, y, z - sz);
                            } else if (axis == 1) { // Ey: Hx(x,y,z) - Hx(x,y,z-sz) - Hz(x,y,z) + Hz(x-sx,y,z)
                                h0 = engine.readFieldCell(CopperEngine::Field::Hx, x, y, z);
                                h1 = engine.readFieldCell(CopperEngine::Field::Hx, x, y, z - sz);
                                h2 = engine.readFieldCell(CopperEngine::Field::Hz, x, y, z);
                                h3 = engine.readFieldCell(CopperEngine::Field::Hz, x - sx, y, z);
                            } else { // Ez: Hy(x,y,z) - Hy(x-sx,y,z) - Hx(x,y,z) + Hx(x,y-sy,z)
                                h0 = engine.readFieldCell(CopperEngine::Field::Hy, x, y, z);
                                h1 = engine.readFieldCell(CopperEngine::Field::Hy, x - sx, y, z);
                                h2 = engine.readFieldCell(CopperEngine::Field::Hx, x, y, z);
                                h3 = engine.readFieldCell(CopperEngine::Field::Hx, x, y - sy, z);
                            }
                            const float curlDiff = h0 - h1 - h2 + h3;
                            const float vv = grid.vv[axis][idx];
                            const float vi = grid.vi[axis][idx];
                            const float predictedBeforeExc = vv * oldE + vi * curlDiff;
                            const float excContribution = excitationContribution(x, y, z, axis, true, numTS, period);
                            const float predictedAfterExc = predictedBeforeExc + excContribution;
                            eTraces.push_back({x, y, z, axis, oldE, h0, h1, h2, h3, curlDiff, vv, vi,
                                                predictedBeforeExc, excContribution, predictedAfterExc});

                            const bool hInBounds =
                                (x + 1 < grid.dims.nx && y + 1 < grid.dims.ny && z + 1 < grid.dims.nz);
                            if (hInBounds) {
                                const auto hField = static_cast<CopperEngine::Field>(axis + 3);
                                const float oldH = engine.readFieldCell(hField, x, y, z);
                                hPending.push_back({x, y, z, axis, oldH, grid.ii[axis][idx], grid.iv[axis][idx]});
                            }
                        }
                    }
                }
            }

            engine.run(1);

            std::fprintf(stdout, "  -- E terms (old, curl components, coefficients, predicted vs actual) --\n");
            double maxEDiff = 0.0;
            for (const ETrace& t : eTraces) {
                const auto eField = static_cast<CopperEngine::Field>(t.axis);
                const float actual = engine.readFieldCell(eField, t.x, t.y, t.z);
                const double diff = std::fabs(static_cast<double>(actual) - static_cast<double>(t.predictedAfterExc));
                maxEDiff = std::max(maxEDiff, diff);
                std::fprintf(stdout,
                             "  E%s(%u,%u,%u): old=%.6e h=[%.6e,%.6e,%.6e,%.6e] curl=%.6e vv=%.6e vi=%.6e "
                             "predicted(pre-exc)=%.6e exc=%.6e predicted(post-exc)=%.6e actual=%.6e |diff|=%.3e\n",
                             axisName[t.axis], t.x, t.y, t.z, static_cast<double>(t.oldE), static_cast<double>(t.h0),
                             static_cast<double>(t.h1), static_cast<double>(t.h2), static_cast<double>(t.h3),
                             static_cast<double>(t.curlDiff), static_cast<double>(t.vv), static_cast<double>(t.vi),
                             static_cast<double>(t.predictedBeforeExc), static_cast<double>(t.excContribution),
                             static_cast<double>(t.predictedAfterExc), static_cast<double>(actual), diff);
            }
            std::fprintf(stdout, "  (max |E prediction error| this step: %.6e)\n", maxEDiff);

            std::fprintf(stdout, "  -- H terms (old, curl components from the *new* E, coefficients, predicted vs "
                                  "actual) --\n");
            double maxHDiff = 0.0;
            for (const HPending& p : hPending) {
                const std::uint32_t x = p.x, y = p.y, z = p.z, axis = p.axis;
                float e0 = 0, e1 = 0, e2 = 0, e3 = 0;
                if (axis == 0) { // Hx: Ez(x,y,z) - Ez(x,y+1,z) - Ey(x,y,z) + Ey(x,y,z+1)
                    e0 = engine.readFieldCell(CopperEngine::Field::Ez, x, y, z);
                    e1 = engine.readFieldCell(CopperEngine::Field::Ez, x, y + 1, z);
                    e2 = engine.readFieldCell(CopperEngine::Field::Ey, x, y, z);
                    e3 = engine.readFieldCell(CopperEngine::Field::Ey, x, y, z + 1);
                } else if (axis == 1) { // Hy: Ex(x,y,z) - Ex(x,y,z+1) - Ez(x,y,z) + Ez(x+1,y,z)
                    e0 = engine.readFieldCell(CopperEngine::Field::Ex, x, y, z);
                    e1 = engine.readFieldCell(CopperEngine::Field::Ex, x, y, z + 1);
                    e2 = engine.readFieldCell(CopperEngine::Field::Ez, x, y, z);
                    e3 = engine.readFieldCell(CopperEngine::Field::Ez, x + 1, y, z);
                } else { // Hz: Ey(x,y,z) - Ey(x+1,y,z) - Ex(x,y,z) + Ex(x,y+1,z)
                    e0 = engine.readFieldCell(CopperEngine::Field::Ey, x, y, z);
                    e1 = engine.readFieldCell(CopperEngine::Field::Ey, x + 1, y, z);
                    e2 = engine.readFieldCell(CopperEngine::Field::Ex, x, y, z);
                    e3 = engine.readFieldCell(CopperEngine::Field::Ex, x, y + 1, z);
                }
                const float curlDiff = e0 - e1 - e2 + e3;
                const float predictedBeforeExc = p.ii * p.oldH + p.iv * curlDiff;
                const float excContribution = excitationContribution(x, y, z, axis, false, numTS, period);
                const float predictedAfterExc = predictedBeforeExc + excContribution;
                const auto hField = static_cast<CopperEngine::Field>(axis + 3);
                const float actual = engine.readFieldCell(hField, x, y, z);
                const double diff = std::fabs(static_cast<double>(actual) - static_cast<double>(predictedAfterExc));
                maxHDiff = std::max(maxHDiff, diff);
                std::fprintf(stdout,
                             "  H%s(%u,%u,%u): old=%.6e e=[%.6e,%.6e,%.6e,%.6e] curl=%.6e ii=%.6e iv=%.6e "
                             "predicted(pre-exc)=%.6e exc=%.6e predicted(post-exc)=%.6e actual=%.6e |diff|=%.3e\n",
                             axisName[axis], x, y, z, static_cast<double>(p.oldH), static_cast<double>(e0),
                             static_cast<double>(e1), static_cast<double>(e2), static_cast<double>(e3),
                             static_cast<double>(curlDiff), static_cast<double>(p.ii), static_cast<double>(p.iv),
                             static_cast<double>(predictedBeforeExc), static_cast<double>(excContribution),
                             static_cast<double>(predictedAfterExc), static_cast<double>(actual), diff);
            }
            std::fprintf(stdout, "  (max |H prediction error| this step: %.6e)\n", maxHDiff);
        }

        return {};
    } catch (const std::exception& error) {
        return std::string("Copper dumpDetailedTrace failed: ") + error.what();
    }
}

std::string CopperProbeResult::data() const {
    std::ostringstream out;
    const char* kindName = kind == CopperProbeKind::Voltage ? "voltage" : "current";
    out << "% time-domain " << kindName << " probe, written by Copper\n";
    out << "% t/s\t" << kindName << "\n";
    out.precision(12);
    for (const CopperProbeSample& sample : samples) {
        out << sample.timeSeconds << "\t" << sample.value << "\n";
    }
    return out.str();
}

} // namespace copper
