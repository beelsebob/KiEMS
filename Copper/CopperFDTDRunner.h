// The one function copper_fdtd_worker (and any other future caller outside Copper.framework
// itself) actually needs: run one excited port's FDTD pass entirely on the GPU, given an
// already-set-up `openEMS`/`ContinuousStructure` pair, and hand back the resulting probe data.
#pragma once

#include <cstdint>
#include <filesystem>
#include <functional>
#include <string>
#include <vector>

// Deliberately forward-declared, not #included -- this header must be includable from a
// translation unit that already has the *installed* (`<openEMS/openems.h>`,
// `<CSXCAD/ContinuousStructure.h>`) header forms in scope (e.g. copper_fdtd_worker/main.cpp, via
// libgerber2ems's own simulation.hpp), while runFDTDPortOnGPU's own *implementation*
// (CopperFDTDRunner.cpp) uses the flat/source-checkout forms every other Copper/Internal/ header
// does (see Copper/Internal/CopperOpenEMSAccess.hpp's file comment for why the two forms can never
// appear together in one translation unit). A forward declaration is compatible with both sides,
// since a caller passing a reference through only ever needs *some* complete type to exist
// somewhere, not specifically the one this header would otherwise pull in.
class openEMS;
class ContinuousStructure;

namespace copper {

/// Voltage vs current -- deliberately a distinct type from Internal/CopperProbes.hpp's own
/// CopperProbeType, not a shared one: that header uses the flat/source-checkout include form (see
/// this file's own comment above), so nothing it declares can appear in this public boundary header
/// without reintroducing the exact clash forward-declaring openEMS/ContinuousStructure avoids.
enum class CopperProbeKind { Voltage, Current };

/// Which PML formulation to use -- see Internal/CopperCPML.hpp's own doc comment for why plain UPML
/// (openEMS's own original formulation) can numerically diverge on long runs, and why real CFS-PML
/// (Roden & Gedney 2000) fixes that structurally rather than just delaying it. CPML is this enum's
/// own default (see runFDTDPortOnGPU's own `boundaryKind` parameter below); a previous, incorrect
/// attempt at CPML here (which generalized openEMS's own UPML coefficients directly, rather than
/// implementing CPML's actual auxiliary-convolution formula) was replaced after read-through of the
/// real Taflove & Hagness/Roden-Gedney derivation showed it was a structurally different medium --
/// re-validate against a real board's own worst-case late-time-instability scenario before trusting
/// this in production. UPML stays available (still exactly openEMS's own formula, untouched) for
/// comparison/fallback. Kept a plain enum here (not buried inside CopperPML.hpp) so a caller
/// selecting it doesn't need to know anything about how either is actually computed.
enum class CopperBoundaryKind { UPML, CPML };

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
    /// the returned string to a file named `name` is what lets gerber2ems's existing on-disk
    /// S-parameter pipeline (which reads these files back -- see
    /// libgerber2ems/gerber2ems/ports.cpp's `_loadUiFile`) keep working unmodified against a
    /// runFDTDPortOnGPU() result -- a caller that doesn't need a file at all (e.g. a live-plotting
    /// GUI) can just read `samples` directly instead of calling this.
    std::string data() const;
};

/// `probes` is only meaningful when `success` -- one entry per probe box discovered on the board
/// (voltage and current), each carrying every timestep's sample in memory rather than on disk (see
/// runFDTDPortOnGPU's own doc comment for why runFDTDPortOnGPU itself no longer writes files: it's
/// a pure compute function now, and persisting the result -- if a caller needs to at all, e.g. to
/// keep gerber2ems's existing on-disk S-parameter pipeline working unmodified -- is an explicit,
/// visible step in that caller's own code, via CopperProbeResult::data() above, not an implicit
/// side effect buried in here).
struct CopperFDTDRunResult {
    bool success = false;
    std::string errorMessage; // only meaningful when !success
    std::vector<CopperProbeResult> probes;
};

/// Which major stage of runFDTDPortOnGPU a CopperFDTDProgress report describes. `Setup` covers
/// everything before the timestep loop starts, including the *caller's* own
/// gerber2ems::Simulation::setupFDTDOperator() (openEMS's own SetupFDTD()/CalcECOperator(), which
/// dominates setup cost -- confirmed in practice to take ~300s on a real board -- but is a single
/// opaque call with no intermediate progress to report, hence Setup only ever reports
/// currentStep 0 then 1 of 1, not finer sub-steps that would just be fabricated precision).
/// `Postprocessing` is never reported by runFDTDPortOnGPU itself (S-parameter computation happens
/// entirely outside Copper, in gerber2ems's own Postprocessor) -- it exists here purely so a host
/// process orchestrating the whole setup->FDTD->postprocess sequence (see copper_fdtd_worker's own
/// sibling, an in-process caller) can report all three phases through this one shared type.
enum class CopperFDTDPhase { Setup, FDTDRun, Postprocessing };

/// One progress update. `currentStep`/`totalSteps` are the FDTDRun phase's actual timestep count
/// (from gerber2ems::Simulation's own EMSConfig::maxSteps()) -- 0/1 for Setup and Postprocessing,
/// which have no comparable step count. `energyChangeDB`/`targetEnergyChangeDB` mirror
/// CopperFDTDRunner.cpp's own energy-decay end criteria (see its own comment for where `1e-6`/60dB
/// comes from) -- both 0 outside the FDTDRun phase, where there's nothing to report yet.
/// `absoluteEnergy` is the same `engine.estimateEnergy()` reading `energyChangeDB` is itself derived
/// from (see CopperFDTDRunner.cpp), in whatever unnormalized units CalcFastEnergy() itself uses --
/// unlike energyChangeDB (relative to this run's own peak), this is meaningful to compare against
/// the stdout log line's own "Energy: ~%.2e" figure, but not across different boards/excitations. 0
/// outside the FDTDRun phase, same as energyChangeDB.
/// `duringExcitation` is `globalTimestep < excitation signal length` -- true while the excitation
/// pulse itself is still being injected into the domain, false once it's finished and the run is
/// just observing decay (or the excitation was empty/instantaneous to begin with). Always false
/// outside the FDTDRun phase.
struct CopperFDTDProgress {
    CopperFDTDPhase phase = CopperFDTDPhase::Setup;
    std::uint32_t currentStep = 0;
    std::uint32_t totalSteps = 0;
    double energyChangeDB = 0.0;
    double targetEnergyChangeDB = 0.0;
    double absoluteEnergy = 0.0;
    bool duringExcitation = false;
};

using CopperFDTDProgressCallback = std::function<void(const CopperFDTDProgress&)>;

/// Runs one excited port's FDTD pass entirely on the GPU (Copper's own Metal engine, not openEMS's
/// CPU one) and returns every discovered probe's full sample set in `CopperFDTDRunResult::probes` --
/// a pure computation, no disk I/O of its own (see CopperProbeResult::data() above for a caller that
/// wants openEMS-format file content, matching what the real CPU `openEMS::RunFDTD()` would have
/// produced). `fdtd` must already have had `openEMS::SetupFDTD()` run on it (see
/// gerber2ems::Simulation::setupFDTDOperator()) -- this never calls SetupFDTD() itself, and never
/// touches the process's current working directory.
///
/// `onProgress`, if given, is invoked with a CopperFDTDProgress once entering Setup, once leaving
/// it, and periodically throughout FDTDRun (the same >4s wall-clock cadence the energy-decay check
/// itself runs at -- see CopperFDTDRunner.cpp -- calling it more often would just be redundant,
/// since nothing new is known between checks). Leave it as the default (empty) to get plain stdout
/// progress printing instead.
///
/// `boundaryKind` defaults to CPML -- see CopperBoundaryKind's own doc comment for why (fixes
/// UPML's late-time numerical instability on long runs; validated against a real board's own
/// worst-case failure scenario). Pass CopperBoundaryKind::UPML explicitly for openEMS's own original
/// formulation instead. `cpmlAlphaMax` is only meaningful when `boundaryKind` is CPML -- CPML's own
/// alpha (CFS) parameter, in S/m (see Internal/CopperCPML.hpp's own doc comment); defaults to
/// `2*pi*100MHz*EPS0`, matching this codebase's own real boards' lowest excited frequency to date --
/// a caller whose simulation's own frequency sweep floor differs should pass `2*pi*f_low*EPS0` for
/// that simulation's own value instead.
CopperFDTDRunResult runFDTDPortOnGPU(openEMS& fdtd, ContinuousStructure& csx,
                                      const CopperFDTDProgressCallback& onProgress = {},
                                      CopperBoundaryKind boundaryKind = CopperBoundaryKind::CPML,
                                      double cpmlAlphaMax = -1.0);

} // namespace copper
