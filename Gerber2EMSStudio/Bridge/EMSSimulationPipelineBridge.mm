#import "EMSSimulationPipelineBridge.h"
#import "EMSConfigBridge+Private.h"
#import "GeometryPreviewBridge+Private.h"
#import "SimulationResultsBridge+Private.h"

#include <algorithm>
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
std::expected<void, std::string> runGPUPortInProcess(Simulation& sim, std::int32_t excitedPortNumber,
                                                       EMSPipelineProgressHandler progressHandler,
                                                       std::size_t totalExcitedPorts, std::size_t& portsCompleted) {
    const std::filesystem::path cwd = std::filesystem::current_path();
    if (auto result = sim.setupFDTDOperator(excitedPortNumber); !result) {
        return std::unexpected(result.error());
    }
    const std::filesystem::path probeDir = std::filesystem::current_path();
    // Boundary kind and alphaMax both left at runFDTDPortOnGPU()'s own defaults (real CPML -- see
    // Internal/CopperCPML.hpp -- with alphaMax = 2*pi*100MHz*EPS0) -- matches the CLI's own default;
    // no app-side toggle for gerber2ems::PMLKind yet (plain UPML, openEMS's own original formulation,
    // is reachable via `--pml upml` on the CLI for comparison/fallback -- see PMLKind's own doc
    // comment).
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
    const copper::CopperFDTDRunResult gpuResult =
        copper::runFDTDPortOnGPU(sim.fdtdEngine(), sim.csx(), onCopperProgress);
    std::filesystem::current_path(cwd);
    if (!gpuResult.success) {
        return std::unexpected(gpuResult.errorMessage);
    }
    ++portsCompleted;

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

// kicad-cli export/stackup import/port resolution, plus taking a fresh scaled-to-simulation-units
// snapshot of `config` -- everything every later stage needs but none of them individually
// recomputes (see EMSConfig::scaledToSimulationUnits()'s own doc comment for why this has to
// happen after port resolution, not before: resolved ports' width/length get scaled too). Only
// actually does anything the first time it's called since construction or the last
// invalidateFromStage: call -- `_paths` doubles as "has this already run" for that reason.
- (BOOL)ensurePrepared:(EMSConfigBridge*)config
             packageDir:(NSString*)packageDir
           kicadCliPath:(NSString*)kicadCliPath
   kicadQueryHelperPath:(NSString*)helperPath
                  error:(NSError**)error {
    if (_paths.has_value()) {
        return YES;
    }

    EMSConfig& liveConfig = config.cxxConfig;
    if (!liveConfig.kicadPcbPath().has_value()) {
        if (error) *error = makeError("No KiCad board linked to this document yet.");
        return NO;
    }

    PathsConfig paths = PathsConfig::forConfigFile(std::filesystem::path(packageDir.UTF8String) / "simulation.json",
                                                    kicadCliPath.UTF8String, helperPath.UTF8String, "");

    if (auto result = gerber2ems::exportKicadPcb(paths, *liveConfig.kicadPcbPath()); !result) {
        if (error) *error = makeError(result.error());
        return NO;
    }
    if (auto result = gerber2ems::importStackup(paths, liveConfig); !result) {
        if (error) *error = makeError(result.error());
        return NO;
    }
    if (auto result = gerber2ems::resolveSimulationPorts(liveConfig, paths); !result) {
        if (error) *error = makeError(result.error());
        return NO;
    }
    // packageDir is always a private scratch directory (see Document.pipelineDirectory's own doc
    // comment) that only ever gets fab/ems written into it; simulation.json itself is only ever
    // saved into the real, user-visible package. Saving the live, already-port-resolved config here
    // keeps the on-disk package's own simulation.json in sync with it, the same as `geber2ems -a`
    // would leave behind.
    if (auto result = liveConfig.save(paths.configFile); !result) {
        if (error) *error = makeError(result.error());
        return NO;
    }

    EMSConfig scaled = liveConfig.scaledToSimulationUnits();
    auto simIt = std::find_if(scaled.simulations().begin(), scaled.simulations().end(),
                               [&](const auto& sim) { return sim.name() == _simulationName; });
    if (simIt == scaled.simulations().end()) {
        if (error) *error = makeError("Simulation \"" + _simulationName + "\" not found.");
        return NO;
    }

    _scaledConfig.emplace(std::move(scaled));
    _simConfig = &*std::find_if(_scaledConfig->simulations().begin(), _scaledConfig->simulations().end(),
                                 [&](const auto& sim) { return sim.name() == _simulationName; });
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
        // The 0.5 checkpoint lands here (not right after generateGeometry() above), unconditionally,
        // so it's reported whether slicing *just* happened above or was already cached from an
        // earlier ensureStage: call -- either way, grid placement is genuinely the second half of
        // this call's own remaining geometry-phase work.
        reportGeometryProgress(0.5);
        auto grid = gerber2ems::generateGrid(*_geometry, *_scaledConfig, options, *_paths);
        _grid.emplace(*_geometry, std::move(grid));
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
        auto portRunner = [progressHandler, totalExcitedPorts, &portsCompleted](
                               Simulation& sim, std::int32_t excitedPortNumber) {
            return runGPUPortInProcess(sim, excitedPortNumber, progressHandler, totalExcitedPorts, portsCompleted);
        };
        auto resultsResult =
            gerber2ems::generateResults(*_grid, *_scaledConfig, options, *_paths, frequencies, portRunner);
        if (!resultsResult) {
            if (error) *error = makeError(resultsResult.error());
            return NO;
        }
        if (resultsResult->byExcitedPort.empty()) {
            if (error) *error = makeError("No port is configured to excite; nothing to simulate.");
            return NO;
        }
        _results.emplace(*_grid, std::move(*resultsResult));
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
    const gerber2ems::ComputedGridLines* gridLines = _grid.has_value() ? &_grid->grid().gridLines : nullptr;
    return buildGeometryPreview(_geometry->geometry().slicedBoard, *_simConfig, *_scaledConfig, *_paths, gridLines);
}

- (nullable EMSResultsPreview*)resultsPreview {
    if (!_postprocessing.has_value()) {
        return nil;
    }
    return buildResultsPreview(*_postprocessing->postprocessing().postprocessor, *_simConfig);
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
        _grid.reset();
        _geometry.reset();
        _configured.reset();
        _paths.reset();
        _simConfig = nullptr;
        _scaledConfig.reset();
        break;
    case EMSPipelineStageGrid:
        // Geometry stays valid -- only the grid lines (and anything built from them) get redone.
        _postprocessing.reset();
        _results.reset();
        _grid.reset();
        break;
    case EMSPipelineStageResults:
        // Geometry (and the grid lines placed on it) stay valid -- only the FDTD run and its own
        // postprocessing get redone.
        _postprocessing.reset();
        _results.reset();
        break;
    }
}

@end
