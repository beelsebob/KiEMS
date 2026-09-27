// The one function copper_fdtd_worker (and any other future caller outside Copper.framework
// itself) actually needs: run one excited port's FDTD pass entirely on the GPU, given an
// a `ContinuousStructure`, and hand back the resulting probe data.
#pragma once

#include <array>
#include <cstdint>
#include <filesystem>
#include <functional>
#include <optional>
#include <string>
#include <vector>

// Deliberately forward-declared, not #included, so callers do not inherit CSXCAD's large public
// header surface merely to pass their geometry into Copper.
class ContinuousStructure;

namespace copper {

/// Plain, Copper-native config CopperOperator needs to build its mesh/coefficients -- the caller
/// builds this directly from state it already has (e.g. kiems::Simulation's own boundaryIsPEC()/
/// maxTimesteps()/excitationF0()/excitationFc() accessors) instead of this file reading it back off
/// an already-built, real openEMS Operator/Excitation. That indirection used to be the only reason
/// runFDTDPortOnGPU/OnCPU required `fdtd` to have already been through a full, genuine
/// `openEMS::SetupFDTD()` call -- confirmed in practice to roughly double per-port setup time on a
/// real board, since SetupFDTD() redundantly computes the exact same mesh/material/PEC coefficients
/// CopperOperator was about to compute itself, and the result was thrown away except for these 3
/// values.
///
/// `boundaryIsPEC[i]` (face order 0=xmin,1=xmax,2=ymin,3=ymax,4=zmin,5=zmax, matching openEMS's own
/// Set_BC_Type/Set_BC_PML side numbering) true means PEC, false means "everything else" (MUR or
/// PML/CPML -- a CPML shell, built separately, provides the real absorption regardless, see
/// Internal/CopperOperator.hpp's own CopperOperator::BoundaryType doc comment). `f0`/`fc` are the
/// Gaussian pulse's own center frequency/half-bandwidth, Hz (openEMS::SetGaussExcite's own
/// convention). `maxTimesteps` clamps the excitation signal length (openEMS::SetNumberOfTimeSteps's
/// own convention).
struct CopperFDTDPortConfig {
    std::array<bool, 6> boundaryIsPEC = {false, false, false, false, false, false};
    double f0 = 0.0;
    double fc = 0.0;
    std::uint32_t maxTimesteps = 0;

    struct DomainPoint {
        double x = 0.0;
        double y = 0.0;
    };
    /// The true hull-cut board polygon (outer loops and clockwise holes), in CSX drawing units.
    /// When present, Copper only updates the hull plus `domainPadding`, surrounds that with
    /// `pmlDepthCells` offset CPML rings, and leaves every other XY cell identically zero. Empty
    /// preserves the historical rectangular-domain behaviour for tests and non-KiEMS callers.
    std::vector<std::vector<DomainPoint>> domainCutoutLoops;
    double domainPadding = 0.0;
    double domainCPMLCellSize = 0.0;
};

/// Opt-in request to persist this run's field-frame time series to disk in the field frame-series
/// format (see docs/field_frame_series_format.md and FieldFrameSeriesWriter.hpp). When present, the
/// captured frames are streamed to this file instead of being retained in CopperFDTDRunResult's
/// in-memory fieldSnapshot; callers can reopen them lazily with FieldFrameSeriesReader. Left unset
/// preserves the original in-memory result for callers which do not have an on-disk consumer.
struct FieldFrameSeriesRequest {
    std::filesystem::path path;
    std::string simulationName;
    std::int32_t excitedPort = 0;
    double boardZMin = 0.0;
    double boardZMax = 0.0;
    /// See FieldFrameSeriesWriter::create()'s own `chunkFrames` parameter.
    std::uint32_t chunkFrames = 16;
    /// Called after the file has been created and entered SWMR-write mode, before frame generation
    /// starts. A live viewer can begin opening `path` here without racing file creation or mistaking
    /// a stale file from an earlier run for this one.
    std::function<void(const std::filesystem::path&)> onWriterReady;
};

/// Voltage vs current -- deliberately a distinct type from Internal/CopperProbes.hpp's own
/// CopperProbeType, not a shared one: that header uses the flat/source-checkout include form (see
/// this file's own comment above), so nothing it declares can appear in this public boundary header
/// without reintroducing the exact clash forward-declaring openEMS/ContinuousStructure avoids.
enum class CopperProbeKind { Voltage, Current };

/// `2*pi*lowFrequencyHz*EPS0` -- the value runFDTDPortOnGPU()'s own `cpmlAlphaMax` parameter expects
/// for a simulation whose own frequency sweep floor is `lowFrequencyHz`, matching the formula its
/// generic 100MHz-based default already uses internally (see that parameter's own doc comment). CPML's
/// alpha (CFS) term is what keeps the PML's decay bounded away from 1 even where ordinary conductivity
/// grading is weak/zero -- exactly the mechanism that fixes late-time instability -- but it does so
/// relative to *this* frequency: leaving cpmlAlphaMax at a value derived from a higher frequency than a
/// simulation's own actual sweep floor under-damps whatever content lies between the two, which then
/// persists and grows in relative visibility over a long run instead of decaying. Every real caller
/// should pass this (with its own EMSConfig's Frequency::start(), the same value that determines the
/// sweep's own frequency-domain floor) rather than relying on runFDTDPortOnGPU()'s generic default.
double cpmlAlphaMaxForFrequency(double lowFrequencyHz);

/// One (time, value) sample -- `value` already has the probe's own weight applied (matching
/// ProcessIntegral::Process's own `m_Results[n] * m_weight`, see Internal/CopperProbes.hpp's
/// CopperProbeWriter, whose role this replaces inside runFDTDPortOnGPU -- see CopperFDTDRunResult's
/// own comment for why). Ready to write to a file or plot as-is; no further weighting needed.
struct CopperProbeSample {
    double timeSeconds = 0.0;
    double value = 0.0;
};

/// One probe's full set of samples from a single FDTD run, in timestep order. `name` matches what
/// the probe box's own openEMS-format file would have been called -- the probe's own weighting has
/// already been applied to every sample's value.
struct CopperProbeResult {
    std::string name;
    CopperProbeKind kind = CopperProbeKind::Voltage;
    std::vector<CopperProbeSample> samples;

    /// Formats this probe's samples in openEMS's own ASCII probe-file shape: a couple of
    /// `%`-prefixed header lines, then one `time\tvalue` row per sample, taken as-is (no further
    /// weighting -- see this struct's own doc comment on why `samples` is already final). Writing
    /// the returned string to a file named `name` is what lets kiems's existing on-disk
    /// S-parameter pipeline (which reads these files back -- see
    /// libkiems/kiems/ports.cpp's `_loadUiFile`) keep working unmodified against a
    /// runFDTDPortOnGPU() result -- a caller that doesn't need a file at all (e.g. a live-plotting
    /// GUI) can just read `samples` directly instead of calling this.
    std::string data() const;
};

/// Deliberately a distinct, self-contained type rather than reusing Internal/CopperYeeGrid.hpp's
/// own CopperGridDims -- see this file's own top comment on why the public boundary header can't
/// pull in an Internal/ header (flat vs. installed openEMS include forms can't mix in one
/// translation unit).
struct CopperFieldGridDims {
    std::uint32_t nx = 0;
    std::uint32_t ny = 0;
    std::uint32_t nz = 0;
};

/// One full-grid energy snapshot at a single point in the run -- for spatial visualization (e.g. a
/// 3D field/energy viewer's own timeline scrubber), not for anything read every timestep (see
/// CopperFDTDRunner.cpp's own comment on why per-timestep probe sampling deliberately avoids a
/// full-grid read). `cellEnergy` is `dims.nx*ny*nz` floats (see CopperFieldSnapshot::dims), one per
/// cell, in Yee-grid x-fastest-varying order (matches CopperYeeGrid's own copperGridIndex()):
/// `EPS0*(Ex^2+Ey^2+Ez^2) + MUE0*(Hx^2+Hy^2+Hz^2)`, each component read at the *same* global index
/// with no attempt to interpolate across the Yee-cell's own half-cell E/H staggering -- a
/// deliberate, cheap simplification (sub-cell-scale error) acceptable for a spatial visualization,
/// not a rigorously co-located energy density.
struct CopperFieldFrame {
    std::uint32_t timestep = 0;
    double timeSeconds = 0.0;
    std::vector<float> cellEnergy;
};

/// A time series of full-grid energy snapshots captured periodically across a run -- see
/// CopperFDTDRunner.cpp's own comment for the capture cadence (a bounded frame budget, not a fixed
/// wall-clock interval, so an hours-long run doesn't produce thousands of multi-megabyte frames).
/// `lineX/Y/Z` are the primary (E) mesh's own line positions, metres, in the same absolute frame
/// every other Copper coordinate is in (matches Internal/CopperYeeGrid.hpp's `lineX/Y/Z`) --
/// `lineW.size()` is `dims.nW+1` (cell *boundaries*, not centers) -- shared by every frame, since
/// the mesh itself never changes mid-run, only the field state does.
struct CopperFieldSnapshot {
    CopperFieldGridDims dims;
    std::vector<float> lineX, lineY, lineZ;
    std::vector<CopperFieldFrame> frames; // timestep order
};

/// `probes` is only meaningful when `success` -- one entry per probe box discovered on the board
/// (voltage and current), each carrying every timestep's sample in memory rather than on disk (see
/// runFDTDPortOnGPU's own doc comment for why runFDTDPortOnGPU itself no longer writes files: it's
/// a pure compute function now, and persisting the result -- if a caller needs to at all, e.g. to
/// keep kiems's existing on-disk S-parameter pipeline working unmodified -- is an explicit,
/// visible step in that caller's own code, via CopperProbeResult::data() above, not an implicit
/// side effect buried in here). Field captures are likewise only meaningful when `success`: they
/// are either available through `fieldFrameSeriesPath` when disk persistence was requested, or as
/// at least one in-memory `fieldSnapshot.frames` entry otherwise.
struct CopperFDTDRunResult {
    bool success = false;
    std::string errorMessage; // only meaningful when !success
    /// True iff this run stopped early because the caller's own `isCancelled` (see
    /// runFDTDPortOnGPU's own doc comment) returned true, rather than reaching `steps` or the
    /// energy-decay end criteria. `success` is still false in this case (there's no complete probe
    /// data), but a caller that distinguishes "genuinely failed" from "the user cancelled it" should
    /// check this rather than treating every `!success` the same way.
    bool cancelled = false;
    std::vector<CopperProbeResult> probes;
    /// Populated only when a requested FieldFrameSeriesRequest was written and closed successfully.
    /// In that case fieldSnapshot contains mesh metadata but no frames.
    std::optional<std::filesystem::path> fieldFrameSeriesPath;
    CopperFieldSnapshot fieldSnapshot;
};

/// Which major stage of runFDTDPortOnGPU a CopperFDTDProgress report describes. `Setup` covers
/// Copper operator construction before the timestep loop starts. It has no useful intermediate
/// progress estimate, hence Setup only ever reports
/// currentStep 0 then 1 of 1, not finer sub-steps that would just be fabricated precision).
/// `Postprocessing` is never reported by runFDTDPortOnGPU itself (S-parameter computation happens
/// entirely outside Copper, in kiems's own Postprocessor) -- it exists here purely so a host
/// process orchestrating the whole setup->FDTD->postprocess sequence (see copper_fdtd_worker's own
/// sibling, an in-process caller) can report all three phases through this one shared type.
enum class CopperFDTDPhase { Setup, FDTDRun, Postprocessing };

/// One progress update. `currentStep`/`totalSteps` are the FDTDRun phase's actual timestep count
/// (from kiems::Simulation's own EMSConfig::maxSteps()) -- 0/1 for Setup and Postprocessing,
/// which have no comparable step count. `energyChangeDB`/`targetEnergyChangeDB` mirror
/// CopperFDTDRunner.cpp's own energy-decay end criteria (see its own comment for where `1e-6`/60dB
/// comes from) -- both 0 outside the FDTDRun phase, where there's nothing to report yet.
/// `absoluteEnergy` is the same `engine.estimateEnergy()` reading `energyChangeDB` is itself derived
/// from (see CopperFDTDRunner.cpp), in whatever unnormalized units CalcFastEnergy() itself uses --
/// unlike energyChangeDB (relative to this run's own peak), this is meaningful to compare against
/// the stdout log line's own "Energy: ~%.2e" figure, but not across different boards/excitations. 0
/// outside the FDTDRun phase, same as energyChangeDB.
/// `duringExcitation` is true while the precomputed Gaussian pulse is being injected. Always false
/// outside the FDTDRun phase. `simulationTimeSeconds` is the physical FDTD time at `currentStep`
/// (`currentStep * CopperYeeGrid::timestepSeconds`), not elapsed wall-clock time. The two duration
/// duration fields expose the exact X-axis landmarks known before stepping starts: the full pulse
/// buffer and the maximum configured run time. `excitationF0Hz`/`excitationFcHz` expose the exact
/// modulated-Gaussian parameters so a UI can render magnitude continuously instead of reducing the
/// pulse to a misleading hard boundary. All values are 0 outside the FDTDRun phase.
struct CopperFDTDProgress {
    CopperFDTDPhase phase = CopperFDTDPhase::Setup;
    std::uint32_t currentStep = 0;
    std::uint32_t totalSteps = 0;
    double energyChangeDB = 0.0;
    double targetEnergyChangeDB = 0.0;
    double absoluteEnergy = 0.0;
    bool duringExcitation = false;
    double simulationTimeSeconds = 0.0;
    double excitationEndTimeSeconds = 0.0;
    double plannedSimulationTimeSeconds = 0.0;
    double excitationF0Hz = 0.0;
    double excitationFcHz = 0.0;
};

using CopperFDTDProgressCallback = std::function<void(const CopperFDTDProgress&)>;

/// Runs one excited port's FDTD pass entirely on the GPU (Copper's own Metal engine, not openEMS's
/// CPU one) and returns every discovered probe's full sample set in `CopperFDTDRunResult::probes` --
/// a pure computation, no disk I/O of its own (see CopperProbeResult::data() above for a caller that
/// wants openEMS-format file content, matching what the real CPU `openEMS::RunFDTD()` would have
/// produced). `portConfig` supplies everything CopperOperator needs to build the mesh/coefficients
/// itself (see CopperFDTDPortConfig's own doc comment) -- `fdtd` does not need
/// `openEMS::SetupFDTD()` to have run on it; this never calls SetupFDTD() itself or touches the process's current
/// working directory.
///
/// `onProgress`, if given, is invoked with a CopperFDTDProgress once entering Setup, once leaving
/// it, and periodically throughout FDTDRun (the same >4s wall-clock cadence the energy-decay check
/// itself runs at -- see CopperFDTDRunner.cpp -- calling it more often would just be redundant,
/// since nothing new is known between checks). Leave it as the default (empty) to get plain stdout
/// progress printing instead.
///
/// `cpmlAlphaMax` is CPML's alpha (CFS) parameter, in S/m (see Internal/CopperCPML.hpp); defaults to
/// `2*pi*100MHz*EPS0`, matching this codebase's own real boards' lowest excited frequency to date --
/// a caller whose simulation's own frequency sweep floor differs should pass
/// `cpmlAlphaMaxForFrequency(f_low)` for that simulation's own configured start frequency instead
/// (see that function's own doc comment for why leaving this at the generic default under-damps a
/// simulation whose own sweep floor is well below 100MHz, producing exactly the late-time-growing
/// energy CPML exists to prevent). See Internal/CopperCPML.hpp for why a run must never have called
/// openEMS's own Set_BC_PML() (the caller is responsible for that; this is just told the depth it
/// would otherwise have passed there, in cells, uniform on all 6 faces) and instead computes its own
/// shell geometry directly from this value. Defaults to 16, matching kiems::constants::
/// pmlDepthCells -- a caller linking kiems should pass that constant explicitly rather than rely
/// on this default staying in sync with it.
///
/// `isCancelled`, if given, is checked once per timestep (the same per-step sampler callback the
/// energy-decay end criteria already uses to stop the loop early -- see CopperFDTDRunner.cpp) --
/// returning true stops the run within a timestep or two, well under a second even on a long run.
/// Left as the default (empty) means the run can never be cancelled this way. See
/// CopperFDTDRunResult::cancelled for how a caller tells this apart from a genuine failure.
///
/// `fieldFrameSeries`, if given, persists every captured field frame to disk instead of retaining
/// the frames in memory (see FieldFrameSeriesRequest's own doc comment). Left at the default
/// (nullopt) preserves the original in-memory CopperFDTDRunResult::fieldSnapshot behaviour.
CopperFDTDRunResult runFDTDPortOnGPU(ContinuousStructure& csx, const CopperFDTDPortConfig& portConfig,
                                      const CopperFDTDProgressCallback& onProgress = {},
                                      double cpmlAlphaMax = -1.0, std::uint32_t pmlDepthCells = 16,
                                      const std::function<bool()>& isCancelled = {},
                                      const std::optional<FieldFrameSeriesRequest>& fieldFrameSeries = std::nullopt);

/// The CPU twin of runFDTDPortOnGPU() above -- identical setup, identical per-timestep probe
/// sampling/progress/cancellation/field-capture behavior, and the exact same parameter meanings
/// (see runFDTDPortOnGPU's own doc comments for every one of them), differing only in which
/// Internal/CopperEngine.hpp `Backend` actually runs the leapfrog loop (`Backend::CPU` here vs.
/// `Backend::Metal` there -- see that enum's own doc comment for why the two produce results
/// matching to float-rounding tolerance, not a behavioral difference). Exists so
/// kiems_fdtd_worker (the process RunOptions::backend == FDTDBackend::OpenEMSCPU spawns) can run
/// on Copper's own CPU engine instead of openEMS's real `Engine`/`RunFDTD()` -- see
/// kiems::Simulation's own doc comments for why that real CPU stepping loop is no longer used by
/// anything in this codebase.
CopperFDTDRunResult runFDTDPortOnCPU(ContinuousStructure& csx, const CopperFDTDPortConfig& portConfig,
                                      const CopperFDTDProgressCallback& onProgress = {},
                                      double cpmlAlphaMax = -1.0, std::uint32_t pmlDepthCells = 16,
                                      const std::function<bool()>& isCancelled = {},
                                      const std::optional<FieldFrameSeriesRequest>& fieldFrameSeries = std::nullopt);

/// One-off diagnostic, NOT part of the normal run path: sets up exactly like runFDTDPortOnGPU() (same
/// grid/coefficient/excitation extraction, same CopperEngine), then instead of running to completion,
/// steps the engine one timestep at a time for `frameCount` steps, writing every raw field component
/// (Ex/Ey/Ez/Hx/Hy/Hz) after each step -- plus the static per-cell coupling coefficients
/// (vv0-2/vi0-2/ii0-2/iv0-2) once, up front -- to `outputDir`, cropped to a box around the excitation
/// cells (their own bounding box, expanded by `marginCells` in every direction, clamped to the grid).
/// Exists to answer "where and why does energy stop spreading" by hand/offline (e.g. in Python) when
/// comparing against a real openEMS CPU run isn't practical -- see this function's own .cpp for the
/// exact file layout. Returns an error string on failure (mirrors CopperFDTDRunResult's own contract,
/// but this has no probes/field-snapshot payload of its own -- everything of interest is on disk).
std::string dumpEarlyFrames(ContinuousStructure& csx, const CopperFDTDPortConfig& portConfig,
                             const std::filesystem::path& outputDir, std::uint32_t frameCount = 100,
                             std::uint32_t marginCells = 25, double cpmlAlphaMax = -1.0,
                             std::uint32_t pmlDepthCells = 16);

/// A second one-off diagnostic, even more targeted than dumpEarlyFrames(): instead of just before/
/// after field snapshots, prints every *intermediate* term of the update formula -- the raw neighbor
/// reads that make up each curl difference, the vv/vi (or ii/iv) coefficient applied, the resulting
/// product, and (for excited cells) the exact excitation signal sample and its own contribution --
/// for every cell in a small (`boxSide`-per-axis, e.g. 4 => 64 cells) box centered on the excitation,
/// over just `stepCount` timesteps. Where dumpEarlyFrames() answers "what does the field look like",
/// this answers "which specific term in the formula is small" -- e.g. whether a tiny result comes
/// from a tiny coupling coefficient, a tiny (already-decayed) neighbor read, or something else
/// entirely -- without needing a separate offline reconstruction pass. Prints directly to stdout
/// (plain text, not a binary file -- the whole point is a bounded amount of output a human or an
/// agent can read directly). Returns an error string on failure, matching dumpEarlyFrames()'s own
/// contract.
std::string dumpDetailedTrace(ContinuousStructure& csx, const CopperFDTDPortConfig& portConfig,
                               std::uint32_t stepCount = 4, std::uint32_t boxSide = 4,
                               double cpmlAlphaMax = -1.0, std::uint32_t pmlDepthCells = 16);

} // namespace copper
