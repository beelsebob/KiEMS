#import "EMSSimulationPipelineBridge.h"
#import "EMSConfigBridge+Private.h"
#import "FieldSnapshotBridge+Private.h"
#import "GeometryPreviewBridge+Private.h"
#import "SimulationResultsBridge+Private.h"

#include <algorithm>
#include <atomic>
#include <cmath>
#include <filesystem>
#include <fstream>
#include <optional>
#include <string>
#include <vector>

#include "gerber2ems/config.hpp"
#include "gerber2ems/constants.hpp"
#include "gerber2ems/importer.hpp"
#include "gerber2ems/paths_config.hpp"
#include "gerber2ems/port_resolution.hpp"
#include "gerber2ems/simulation.hpp"
#include "gerber2ems/simulation_data.hpp"

// Forward-declare-only boundary header (see its own file comment) -- safe alongside every
// gerber2ems header above despite those using the *installed* CSXCAD/openEMS forms and Copper's
// own internals using the flat/source-checkout forms, for the same reason
// geber2ems/main.cpp's own runGPUPortInProcess() can: this header never exposes a complete
// openEMS/ContinuousStructure definition itself. This is what lets the App run Copper's GPU engine
// in-process (see runGPUPortInProcess() below) instead of posix_spawning gerber2ems_fdtd_worker as
// a separate process -- Gerber2EMSStudio links Copper.framework directly (see the Xcode project's
// own build settings), while libgerber2ems itself still never does.
#include "CopperFDTDRunner.h"

using gerber2ems::EMSConfig;
using gerber2ems::FDTDBackend;
using gerber2ems::PathsConfig;
using gerber2ems::Postprocessor;
using gerber2ems::RunOptions;
using gerber2ems::Simulation;
using gerber2ems::SimulationConfig;
using gerber2ems::SimulationData;
using gerber2ems::SimulationStage;

@implementation EMSPipelineProgress
- (instancetype)initWithPhase:(EMSPipelineProgressPhase)phase
                       fraction:(double)fraction
                 energyChangeDB:(double)energyChangeDB
           targetEnergyChangeDB:(double)targetEnergyChangeDB
                 absoluteEnergy:(double)absoluteEnergy
               duringExcitation:(BOOL)duringExcitation {
    self = [super init];
    if (self) {
        _phase = phase;
        _fraction = fraction;
        _energyChangeDB = energyChangeDB;
        _targetEnergyChangeDB = targetEnergyChangeDB;
        _absoluteEnergy = absoluteEnergy;
        _duringExcitation = duringExcitation;
    }
    return self;
}
@end

namespace {

NSError* makeError(const std::string& message) {
    return [NSError errorWithDomain:EMSConfigErrorDomain
                                code:1
                            userInfo:@{NSLocalizedDescriptionKey : @(message.c_str())}];
}

// A distinct error code (rather than matching on makeError()'s own message text) so
// +isCancellationError: can tell a cancellation apart from a message that merely happens to equal
// kCancelledMessage for some unrelated reason.
constexpr NSInteger kCancelledErrorCode = 2;
constexpr const char* kCancelledMessage = "Cancelled";

NSError* makeCancelledError() {
    return [NSError errorWithDomain:EMSConfigErrorDomain
                                code:kCancelledErrorCode
                            userInfo:@{NSLocalizedDescriptionKey : @(kCancelledMessage)}];
}

// Evenly-spaced frequency samples between start/stop -- matches libgerber2ems's own (private)
// linspace() in simulation_result.cpp exactly; not worth sharing across a library boundary for
// something this small (every other C++/ObjC++ bridge file in this app duplicates its own similarly
// tiny helpers -- e.g. makeError() above -- rather than growing a shared-utilities header for them).
std::vector<double> linspace(double start, double stop, std::int32_t num) {
    std::vector<double> result(static_cast<std::size_t>(num));
    if (num == 1) {
        result[0] = start;
        return result;
    }
    for (std::int32_t i = 0; i < num; ++i) {
        result[static_cast<std::size_t>(i)] = start + static_cast<double>(i) * (stop - start) / (num - 1);
    }
    return result;
}

/// The gerber2ems::FDTDPortRunner passed to gerber2ems::generateResults() so the FDTD step runs in
/// this one process -- mirrors geber2ems/main.cpp's own runGPUPortInProcess() exactly (see its own
/// doc comment for why a portRunner has to do the setupFDTDOperator()/runFDTDPortOnGPU()/
/// probe-file-write sequence itself), just without CLI-style stdout progress logging: this app
/// reports progress through `progressHandler` instead (see EMSPipelineProgress's own doc comment).
///
/// `totalExcitedPorts`/`portsCompleted` let a multi-port simulation's overall Simulation-phase
/// progress read as one continuously-advancing 0...1 fraction across every excited port's own FDTD
/// run, rather than resetting to 0 and confusingly re-climbing to 1 once per port -- `portsCompleted`
/// is a plain `std::size_t&` (not atomic/thread-safety-guarded) because generateResults() calls this
/// FDTDPortRunner for each excited port strictly sequentially, never concurrently.
///
/// `outFieldSnapshot`, if non-null, is overwritten with this port's own full-grid field snapshot on
/// success (see copper::CopperFDTDRunResult::fieldSnapshot) -- for a multi-port simulation this
/// means whichever port runs *last* wins; the Field Viewer only ever shows one snapshot at a time
/// and there's no per-port selector yet, so "the most recently computed port's own field state" is
/// the simplest reasonable default rather than keeping one per port.
std::expected<void, std::string> runGPUPortInProcess(Simulation& sim, std::int32_t excitedPortNumber,
                                                       EMSPipelineProgressHandler progressHandler,
                                                       std::size_t totalExcitedPorts, std::size_t& portsCompleted,
                                                       copper::CopperFieldSnapshot* outFieldSnapshot,
                                                       const std::atomic<bool>& cancelRequested) {
    // Checked before doing any work for this port at all -- a multi-port simulation's excited
    // ports run strictly sequentially (see this function's own caller, generateResults()'s
    // FDTDPortRunner loop), so a cancellation requested while an earlier port was running (or
    // between ports) stops the *next* port from ever starting, without generateResults() itself
    // needing to know anything about cancellation.
    if (cancelRequested.load()) {
        return std::unexpected(kCancelledMessage);
    }
    const std::filesystem::path cwd = std::filesystem::current_path();
    // sim.setupFDTDOperator() (openEMS's own SetupFDTD()/CalcECOperator()) is the one call in this
    // whole pipeline with genuinely no progress hook of its own -- it's also, per real-world timing,
    // the single most expensive step of the entire Simulation phase on anything but a tiny board (see
    // EMSPipelineProgressPhase's own doc comment). Reported here as one single SettingUp-phase
    // report, before the call, rather than left silent -- without this, the UI's last-known phase
    // just stays whatever Geometry left it at (fraction 1.0), which is what made this look like
    // geometry itself was still running. No fraction/estimate of any kind attached -- a caller should
    // show an indeterminate ("barber pole") indicator for this phase, not a predicted countdown.
    if (progressHandler) {
        progressHandler([[EMSPipelineProgress alloc] initWithPhase:EMSPipelineProgressPhaseSettingUp
                                                            fraction:0.0
                                                      energyChangeDB:0.0
                                                targetEnergyChangeDB:0.0
                                                      absoluteEnergy:0.0
                                                    duringExcitation:NO]);
    }
    if (auto result = sim.setupFDTDOperator(excitedPortNumber); !result) {
        return std::unexpected(result.error());
    }
    const std::filesystem::path probeDir = std::filesystem::current_path();
    // Boundary kind and alphaMax both left at runFDTDPortOnGPU()'s own defaults (real CPML -- see
    // Internal/CopperCPML.hpp -- with alphaMax = 2*pi*100MHz*EPS0) -- matches the CLI's own default;
    // no app-side toggle for gerber2ems::PMLKind yet (plain UPML, openEMS's own original formulation,
    // is reachable via `--pml upml` on the CLI for comparison/fallback -- see PMLKind's own doc
    // comment). pmlDepthCells passed explicitly (matching gerber2ems::constants::pmlDepthCells, the
    // same value Simulation::setBoundaryConditions() used -- or, for a CPML run, deliberately did
    // *not* pass to openEMS's own Set_BC_PML() -- see that function's own comment) rather than
    // relying on runFDTDPortOnGPU()'s own default staying in sync with it.
    copper::CopperFDTDProgressCallback onCopperProgress;
    if (progressHandler) {
        onCopperProgress = [&](const copper::CopperFDTDProgress& p) {
            const double stepFraction =
                p.totalSteps > 0 ? static_cast<double>(p.currentStep) / static_cast<double>(p.totalSteps) : 0.0;
            const double overall = totalExcitedPorts > 0
                                        ? (static_cast<double>(portsCompleted) + stepFraction) /
                                              static_cast<double>(totalExcitedPorts)
                                        : stepFraction;
            EMSPipelineProgress* progress =
                [[EMSPipelineProgress alloc] initWithPhase:EMSPipelineProgressPhaseSimulation
                                                    fraction:overall
                                              energyChangeDB:p.energyChangeDB
                                        targetEnergyChangeDB:p.targetEnergyChangeDB
                                              absoluteEnergy:p.absoluteEnergy
                                            duringExcitation:p.duringExcitation];
            progressHandler(progress);
        };
    }
    const copper::CopperFDTDRunResult gpuResult = copper::runFDTDPortOnGPU(
        sim.fdtdEngine(), sim.csx(), onCopperProgress, copper::CopperBoundaryKind::CPML, -1.0,
        gerber2ems::constants::pmlDepthCells, [&] { return cancelRequested.load(); });
    std::filesystem::current_path(cwd);
    if (gpuResult.cancelled) {
        return std::unexpected(kCancelledMessage);
    }
    if (!gpuResult.success) {
        return std::unexpected(gpuResult.errorMessage);
    }
    ++portsCompleted;
    if (outFieldSnapshot != nullptr) {
        *outFieldSnapshot = gpuResult.fieldSnapshot;
    }

    for (const copper::CopperProbeResult& probeResult : gpuResult.probes) {
        std::ofstream probeFile(probeDir / probeResult.name);
        if (!probeFile.is_open()) {
            return std::unexpected("Failed to open probe file for writing: " +
                                    (probeDir / probeResult.name).string());
        }
        probeFile << probeResult.data();
    }
    return {};
}

} // namespace

@implementation EMSSimulationPipelineBridge {
    std::string _simulationName;

    // Reset together, only the first time any stage needs computing since construction or the last
    // invalidateFromStage: call -- see -ensurePrepared:error:. `_simConfig` points into
    // `_scaledConfig`'s own simulations() vector; valid as long as `_scaledConfig` itself is (never
    // resized after scaling), invalidated together with it.
    std::optional<EMSConfig> _scaledConfig;
    SimulationConfig* _simConfig;
    std::optional<PathsConfig> _paths;
    std::optional<SimulationData<SimulationStage::Configured>> _configured;

    std::optional<SimulationData<SimulationStage::Geometry>> _geometry;
    std::optional<SimulationData<SimulationStage::Grid>> _grid;
    std::optional<SimulationData<SimulationStage::Results>> _results;
    std::optional<SimulationData<SimulationStage::Postprocessing>> _postprocessing;

    // -geometryPreview's own cache -- buildGeometryPreview() now does real work (a libkicad
    // component-model export subprocess, plus via mesh generation), so unlike the flyweight it used
    // to be, it must not be rebuilt on every call. Reset alongside `_geometry`/`_grid` themselves
    // (see -invalidateFromStage:) since it's derived from exactly those two.
    EMSGeometryPreview* _geometryPreviewCache;

    // The last excited port's own full-grid field snapshot, captured alongside `_results` -- see
    // runGPUPortInProcess()'s own doc comment for why "last port wins" rather than one per port.
    // Reset together with `_results` (see -invalidateFromStage:).
    std::optional<copper::CopperFieldSnapshot> _lastFieldSnapshot;

    // Set by -requestCancellation (any thread), read by -ensurePrepared:/-ensureStage: (the
    // background thread actually running them) at each checkpoint -- see -requestCancellation's own
    // doc comment. Cleared at the top of -ensureStage: for the next run, not at the end of this one
    // -- avoids a race in the gap between one call finishing and the next one starting. Default-
    // constructed to false (C++20 std::atomic's default constructor value-initializes) -- no
    // in-class initializer here, Objective-C's ivar block doesn't support one the way a plain C++
    // class body would.
    std::atomic<bool> _cancelRequested;
}

- (instancetype)initWithSimulationName:(NSString*)simulationName {
    self = [super init];
    if (self) {
        _simulationName = simulationName.UTF8String;
        _simConfig = nullptr;
    }
    return self;
}

- (BOOL)hasStage:(EMSPipelineStage)stage {
    switch (stage) {
    case EMSPipelineStageGeometry:
        return _geometry.has_value();
    case EMSPipelineStageGrid:
        return _grid.has_value();
    case EMSPipelineStageResults:
        return _postprocessing.has_value();
    }
}

- (void)requestCancellation {
    _cancelRequested.store(true);
}

+ (BOOL)isCancellationError:(NSError*)error {
    return [error.domain isEqualToString:EMSConfigErrorDomain] && error.code == kCancelledErrorCode;
}

// kicad-cli export/stackup import/port resolution, plus taking a fresh scaled-to-simulation-units
// snapshot of `config` -- everything every later stage needs but none of them individually
// recomputes (see EMSConfig::scaledToSimulationUnits()'s own doc comment for why this has to
// happen after port resolution, not before: resolved ports' width/length get scaled too). Only
// actually does anything the first time it's called since construction or the last
// invalidateFromStage: call -- `_paths` doubles as "has this already run" for that reason.
//
// Everything from here on operates on a *trimmed* copy of `config` -- document-level fields
// (stackup/frequency/grid/via/...) untouched, but `simulations()` narrowed down to just this one
// pipeline's own `_simulationName` entry -- rather than the live, full multi-simulation config.
// resolveSimulationPorts() loops every simulation in whatever EMSConfig it's given, so against the
// untrimmed config, opening one simulation's tab used to also re-resolve every *other* simulation's
// ports (redone again, wastefully, the next time each of those tabs was opened) and could fail this
// tab over a completely unrelated simulation's bad involved_nets/excitation config. Trimming first
// means this pipeline only ever does and depends on the one simulation's own work. The scratch
// package's own simulation.json (saved below) ends up holding just this trimmed copy too -- a
// genuinely temporary, single-simulation file, distinct from the real project package's own.
- (BOOL)ensurePrepared:(EMSConfigBridge*)config
             packageDir:(NSString*)packageDir
           kicadCliPath:(NSString*)kicadCliPath
   kicadQueryHelperPath:(NSString*)helperPath
                  error:(NSError**)error {
    if (_paths.has_value()) {
        return YES;
    }
    if (_cancelRequested.load()) {
        if (error) *error = makeCancelledError();
        return NO;
    }

    EMSConfig& liveConfig = config.cxxConfig;
    if (!liveConfig.kicadPcbPath().has_value()) {
        if (error) *error = makeError("No KiCad board linked to this document yet.");
        return NO;
    }

    EMSConfig trimmedConfig = liveConfig;
    auto trimmedSimIt = std::find_if(trimmedConfig.simulations().begin(), trimmedConfig.simulations().end(),
                                      [&](const auto& sim) { return sim.name() == _simulationName; });
    if (trimmedSimIt == trimmedConfig.simulations().end()) {
        if (error) *error = makeError("Simulation \"" + _simulationName + "\" not found.");
        return NO;
    }
    trimmedConfig.simulations() = {std::move(*trimmedSimIt)};

    PathsConfig paths = PathsConfig::forConfigFile(std::filesystem::path(packageDir.UTF8String) / "simulation.json",
                                                    kicadCliPath.UTF8String, helperPath.UTF8String, "");

    if (auto result = gerber2ems::exportKicadPcb(paths, *trimmedConfig.kicadPcbPath()); !result) {
        if (error) *error = makeError(result.error());
        return NO;
    }
    if (auto result = gerber2ems::importStackup(paths, trimmedConfig); !result) {
        if (error) *error = makeError(result.error());
        return NO;
    }
    if (auto result = gerber2ems::resolveSimulationPorts(trimmedConfig, paths); !result) {
        if (error) *error = makeError(result.error());
        return NO;
    }
    // packageDir is always a private scratch directory (see Document.pipelineDirectory's own doc
    // comment) that only ever gets fab/ems written into it; simulation.json itself is only ever
    // saved into the real, user-visible package. Saving the trimmed, already-port-resolved
    // single-simulation config here keeps this pipeline's own scratch simulation.json self-contained
    // -- e.g. for a worker subprocess later spawned against paths.configFile -- without pulling in
    // every other simulation the live document happens to also contain.
    if (auto result = trimmedConfig.save(paths.configFile); !result) {
        if (error) *error = makeError(result.error());
        return NO;
    }

    EMSConfig scaled = trimmedConfig.scaledToSimulationUnits();
    _scaledConfig.emplace(std::move(scaled));
    // trimmedConfig.simulations() (and so scaled.simulations()) always has exactly one entry --
    // the trim above already found the one named _simulationName, or bailed out if it didn't exist.
    _simConfig = &_scaledConfig->simulations().front();
    _paths.emplace(std::move(paths));
    _configured.emplace(*_simConfig);
    return YES;
}

- (BOOL)ensureStage:(EMSPipelineStage)stage
             config:(EMSConfigBridge*)config
         packageDir:(NSString*)packageDir
       kicadCliPath:(NSString*)kicadCliPath
kicadQueryHelperPath:(NSString*)helperPath
           progress:(nullable EMSPipelineProgressHandler)progressHandler
              error:(NSError**)error {
    if ([self hasStage:stage]) {
        return YES;
    }
    // Cleared here, not at the end of a run -- avoids a race in the gap between one call finishing
    // and the next one starting (see _cancelRequested's own ivar comment).
    _cancelRequested.store(false);
    if (![self ensurePrepared:config packageDir:packageDir kicadCliPath:kicadCliPath kicadQueryHelperPath:helperPath
                         error:error]) {
        return NO;
    }

    // Geometry phase: only two real checkpoints exist (board-slicing and grid-placement each have
    // no finer-grained progress of their own to report -- see gerber2ems::GeometryPhase, which
    // GeometryResult::build()'s own onProgress bracketing mirrors identically), so this reports
    // 0.0 -> 0.5 -> 1.0 rather than a continuously-advancing fraction. Reported even when only
    // EMSPipelineStageGeometry/Grid was actually requested, not just on the way to Results -- a
    // caller watching only the Geometry row still wants to see it move.
    auto reportGeometryProgress = [&](double fraction) {
        if (progressHandler) {
            progressHandler([[EMSPipelineProgress alloc] initWithPhase:EMSPipelineProgressPhaseGeometry
                                                                 fraction:fraction
                                                           energyChangeDB:0
                                                     targetEnergyChangeDB:0
                                                           absoluteEnergy:0
                                                         duringExcitation:NO]);
        }
    };

    if (!_geometry.has_value()) {
        if (_cancelRequested.load()) {
            if (error) *error = makeCancelledError();
            return NO;
        }
        reportGeometryProgress(0.0);
        auto geometryResult = gerber2ems::generateGeometry(*_configured, *_scaledConfig, *_paths);
        if (!geometryResult) {
            if (error) *error = makeError(geometryResult.error());
            return NO;
        }
        _geometry.emplace(*_configured, std::move(*geometryResult));
    }
    if (stage == EMSPipelineStageGeometry) {
        reportGeometryProgress(1.0);
        return YES;
    }

    // EMSPipelineStageGrid, or an unavoidable step on the way to EMSPipelineStageResults (Grid,
    // Results, and Postprocessing have no meaningful intermediate UI state between them once a real
    // FDTD run is wanted -- see gerber2ems::generateResults()'s own doc comment -- so those three
    // still run straight through together below).
    RunOptions options;
    options.backend = FDTDBackend::CopperGPU;

    if (!_grid.has_value()) {
        if (_cancelRequested.load()) {
            if (error) *error = makeCancelledError();
            return NO;
        }
        // The 0.5 checkpoint lands here (not right after generateGeometry() above), unconditionally,
        // so it's reported whether slicing *just* happened above or was already cached from an
        // earlier ensureStage: call -- either way, grid placement is genuinely the second half of
        // this call's own remaining geometry-phase work.
        reportGeometryProgress(0.5);
        auto grid = gerber2ems::generateGrid(*_geometry, *_scaledConfig, options, *_paths);
        _grid.emplace(*_geometry, std::move(grid));
        // A cached -geometryPreview built while only EMSPipelineStageGeometry had run (gridLines
        // still empty) would otherwise keep serving that stale, grid-less snapshot forever now that
        // grid lines actually exist.
        _geometryPreviewCache = nil;
        // Written to disk too (matching `geber2ems -g`) so a later CLI invocation against this same
        // saved package (e.g. `geber2ems -s`) can pick up straight from here without redoing any of
        // this work itself -- see GeometryResult::load()'s own doc comment. Unlike GeometryResult::
        // build(), nothing else along this path has created paths.geometryDir/_simulationName yet
        // (setupFDTDOperator() creates its own simulationDir subtree later, but that's a different
        // directory) -- has to happen here, or saveSimulationData()'s ofstream fails to open.
        std::error_code dirEc;
        std::filesystem::create_directories(_paths->geometryDir / _simulationName, dirEc);
        if (dirEc) {
            if (error) {
                *error = makeError("Failed to create directory " +
                                    (_paths->geometryDir / _simulationName).string() + ": " + dirEc.message());
            }
            return NO;
        }
        if (auto result = gerber2ems::saveSimulationData(
                *_grid, gerber2ems::simulationDataFile(*_paths, _simulationName));
            !result) {
            if (error) *error = makeError(result.error());
            return NO;
        }
    }
    // Reported unconditionally here (not just inside the !_grid.has_value() branch above) -- geometry
    // and grid are always fully done by this point whether either was freshly computed by this call
    // or already cached from an earlier one, and either way the Geometry row's own progress should
    // read 100% before Simulation-phase progress (if this call continues on to Results) starts.
    reportGeometryProgress(1.0);
    if (stage == EMSPipelineStageGrid) {
        return YES;
    }

    std::vector<double> frequencies =
        linspace(_scaledConfig->frequency().start(), _scaledConfig->frequency().stop(), gerber2ems::constants::frequencySampleCount);

    if (!_results.has_value()) {
        std::size_t totalExcitedPorts = 0;
        for (const auto& port : _simConfig->ports()) {
            if (port.excite()) {
                ++totalExcitedPorts;
            }
        }
        // Plain (non-atomic) local, safely shared by reference across every runGPUPortInProcess()
        // call below -- generateResults() calls its FDTDPortRunner once per excited port strictly
        // sequentially, never concurrently, so there's no real data race to guard against.
        std::size_t portsCompleted = 0;
        copper::CopperFieldSnapshot capturedFieldSnapshot;
        auto portRunner = [self, progressHandler, totalExcitedPorts, &portsCompleted, &capturedFieldSnapshot](
                               Simulation& sim, std::int32_t excitedPortNumber) {
            return runGPUPortInProcess(sim, excitedPortNumber, progressHandler, totalExcitedPorts, portsCompleted,
                                        &capturedFieldSnapshot, self->_cancelRequested);
        };
        auto resultsResult =
            gerber2ems::generateResults(*_grid, *_scaledConfig, options, *_paths, frequencies, portRunner);
        if (!resultsResult) {
            // generateResults() only ever sees "cancelled" as a plain error string bubbled up from
            // portRunner (runGPUPortInProcess) -- it has no concept of cancellation itself -- so it
            // has to be recognized by matching text here, not passed through as a distinguishable
            // error the way the checkpoints above construct directly.
            if (error) {
                *error = resultsResult.error() == kCancelledMessage ? makeCancelledError() : makeError(resultsResult.error());
            }
            return NO;
        }
        if (resultsResult->byExcitedPort.empty()) {
            if (error) *error = makeError("No port is configured to excite; nothing to simulate.");
            return NO;
        }
        _results.emplace(*_grid, std::move(*resultsResult));
        _lastFieldSnapshot = std::move(capturedFieldSnapshot);
    }

    if (!_postprocessing.has_value()) {
        auto postprocessing = gerber2ems::generatePostprocessing(*_results, frequencies);
        // calculateSparams() (inside generatePostprocessing()) alone isn't enough for this app's own
        // charts -- impedance/diff-pair/trace-delay data additionally needs processData() (see
        // Postprocessor::processData()'s own doc comment: "Should be called after
        // calculateSparams()"). Matches PostprocessResult::compute()'s own identical extra step,
        // which this bridge otherwise bypasses (that type exists for the CLI's whole-EMSConfig batch
        // use, keyed by simulation name across every simulation at once -- overkill for this
        // one-simulation-at-a-time pipeline, which already has its own Postprocessor directly).
        postprocessing.postprocessor->processData();
        // Written to disk too, matching what `geber2ems -a` would leave behind in the saved package.
        postprocessing.postprocessor->sparamToFile(_paths->simulationDir / _simulationName);
        _postprocessing.emplace(*_results, std::move(postprocessing));
    }
    return YES;
}

- (nullable EMSGeometryPreview*)geometryPreview {
    if (!_geometry.has_value()) {
        return nil;
    }
    if (_geometryPreviewCache) {
        return _geometryPreviewCache;
    }
    const gerber2ems::ComputedGridLines* gridLines = _grid.has_value() ? &_grid->grid().gridLines : nullptr;
    _geometryPreviewCache =
        buildGeometryPreview(_geometry->geometry().slicedBoard, *_simConfig, *_scaledConfig, *_paths, gridLines);
    return _geometryPreviewCache;
}

- (nullable EMSResultsPreview*)resultsPreview {
    if (!_postprocessing.has_value()) {
        return nil;
    }
    return buildResultsPreview(*_postprocessing->postprocessing().postprocessor, *_simConfig);
}

- (nullable EMSFieldSnapshot*)fieldSnapshot {
    if (!_lastFieldSnapshot.has_value()) {
        return nil;
    }
    // Board top is always Z=0, bottom is the substrate stack's own total thickness below that --
    // matches GridGenerator::Impl::_generateZ()'s own convention exactly (offset starts at 0,
    // decreases by each substrate layer's thickness() -- see grid_gen.cpp), computed independently
    // here since GridGenerator has no public accessor for it (only xmin()/ymin()). `.thickness()`
    // is already in simulation units (LayerConfig's own doc comment), same frame buildFieldSnapshot
    // converts Copper's own metres-based lineZ into -- no further scaling needed.
    double boardThickness = 0.0;
    const std::vector<gerber2ems::LayerConfig> substrates = _scaledConfig->getSubstrates();
    for (const auto& substrate : substrates) {
        boardThickness += substrate.thickness();
    }
    return buildFieldSnapshot(*_lastFieldSnapshot, -boardThickness, 0.0);
}

- (void)invalidateFromStage:(EMSPipelineStage)stage {
    switch (stage) {
    case EMSPipelineStageGeometry:
        // Everything depends, directly or transitively, on the sliced board -- discard the whole
        // chain, including the prepared/scaled config snapshot (a config edit invalidating geometry
        // might just as well have changed something scaledToSimulationUnits() would scale
        // differently, e.g. hull padding).
        _postprocessing.reset();
        _results.reset();
        _lastFieldSnapshot.reset();
        _grid.reset();
        _geometry.reset();
        _geometryPreviewCache = nil;
        _configured.reset();
        _paths.reset();
        _simConfig = nullptr;
        _scaledConfig.reset();
        break;
    case EMSPipelineStageGrid:
        // Geometry stays valid -- only the grid lines (and anything built from them) get redone.
        _postprocessing.reset();
        _results.reset();
        _lastFieldSnapshot.reset();
        _grid.reset();
        _geometryPreviewCache = nil;
        break;
    case EMSPipelineStageResults:
        // Geometry (and the grid lines placed on it) stay valid -- only the FDTD run and its own
        // postprocessing get redone.
        _postprocessing.reset();
        _results.reset();
        _lastFieldSnapshot.reset();
        break;
    }
}

@end
