#import "EMSSimulationPipelineBridge.h"
#import "EMSConfigBridge+Private.h"
#import "FieldSnapshotBridge+Private.h"
#import "GeometryPreviewBridge+Private.h"
#import "KicadBoardBridge+Private.h"
#import "SimulationResultsBridge+Private.h"

#include <CommonCrypto/CommonDigest.h>
#include <fcntl.h>
#include <sys/file.h>
#include <unistd.h>

#include <algorithm>
#include <atomic>
#include <cmath>
#include <filesystem>
#include <fstream>
#include <limits>
#include <map>
#include <mutex>
#include <optional>
#include <regex>
#include <set>
#include <string>
#include <utility>
#include <vector>

#include "kiems/excitation_postprocess.hpp"
#include "kiems/config.hpp"
#include "kiems/constants.hpp"
#include "kiems/importer.hpp"
#include "kiems/paths_config.hpp"
#include "kiems/port_resolution.hpp"
#include "kiems/simulation.hpp"
#include "kiems/simulation_data.hpp"

#include "CopperUtils/logging.hpp"

// Forward-declare-only boundary header (see its own file comment) keeps Copper's private
// implementation details out of the bridge while accepting libkiems's CSXCAD geometry. This lets
// the App run Copper's GPU engine
// in-process (see runGPUPortInProcess() below) instead of posix_spawning kiems_fdtd_worker as
// a separate process -- KiEMS links Copper.framework directly (see the Xcode project's
// own build settings), while libkiems itself still never does.
#include "CopperFDTDRunner.h"
#include "Copper/Internal/CopperDomain.hpp"

using kiems::DifferentialPairConfig;
using kiems::EMSConfig;
using kiems::FDTDBackend;
using kiems::PathsConfig;
using kiems::Postprocessor;
using kiems::RunOptions;
using kiems::Simulation;
using kiems::SimulationConfig;
using kiems::SimulationData;
using kiems::SimulationStage;

@implementation EMSPipelineProgress
- (instancetype)initWithPhase:(EMSPipelineProgressPhase)phase
                       fraction:(double)fraction
                 energyChangeDB:(double)energyChangeDB
           targetEnergyChangeDB:(double)targetEnergyChangeDB
                 absoluteEnergy:(double)absoluteEnergy
               duringExcitation:(BOOL)duringExcitation
          simulationTimeSeconds:(double)simulationTimeSeconds
         excitationEndTimeSeconds:(double)excitationEndTimeSeconds
      plannedSimulationTimeSeconds:(double)plannedSimulationTimeSeconds
                    excitationF0Hz:(double)excitationF0Hz
                    excitationFcHz:(double)excitationFcHz
                 excitedNetName:(nullable NSString*)excitedNetName
                    currentStep:(NSInteger)currentStep
                     totalSteps:(NSInteger)totalSteps
                 portsCompleted:(NSInteger)portsCompleted
               excitedPortCount:(NSInteger)excitedPortCount {
    self = [super init];
    if (self) {
        _phase = phase;
        _fraction = fraction;
        _energyChangeDB = energyChangeDB;
        _targetEnergyChangeDB = targetEnergyChangeDB;
        _absoluteEnergy = absoluteEnergy;
        _duringExcitation = duringExcitation;
        _simulationTimeSeconds = simulationTimeSeconds;
        _excitationEndTimeSeconds = excitationEndTimeSeconds;
        _plannedSimulationTimeSeconds = plannedSimulationTimeSeconds;
        _excitationF0Hz = excitationF0Hz;
        _excitationFcHz = excitationFcHz;
        _excitedNetName = [excitedNetName copy];
        _currentStep = currentStep;
        _totalSteps = totalSteps;
        _portsCompleted = portsCompleted;
        _excitedPortCount = excitedPortCount;
    }
    return self;
}
@end

@implementation EMSGridStatistics
- (instancetype)initWithCountX:(NSInteger)countX
                        countY:(NSInteger)countY
                        countZ:(NSInteger)countZ
                     coreCells:(long long)coreCells
                 boundaryCells:(long long)boundaryCells
              excitedPortCount:(NSInteger)excitedPortCount
           maxTimestepsPerPort:(NSInteger)maxTimestepsPerPort {
    self = [super init];
    if (self) {
        _countX = countX;
        _countY = countY;
        _countZ = countZ;
        _coreCells = coreCells;
        _boundaryCells = boundaryCells;
        _excitedPortCount = excitedPortCount;
        _maxTimestepsPerPort = maxTimestepsPerPort;
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

// std::filesystem::current_path()'s default (no error_code) overload throws on failure -- an
// uncaught exception there previously crashed the whole app outright (rather than just failing this
// one job) when the process's cwd was deleted out from under a still-running background job (see
// JobScheduler::cleanUpDirectory(_:)'s own doc comment for the actual race that caused this in
// practice). Used at every runGPUPortInProcess() call site that queries the current directory,
// converting that failure into this function's own std::expected error channel instead.
std::expected<std::filesystem::path, std::string> currentPathOrError() {
    std::error_code ec;
    std::filesystem::path path = std::filesystem::current_path(ec);
    if (ec) {
        return std::unexpected("Could not determine the current working directory: " + ec.message());
    }
    return path;
}

// A distinct error code (rather than matching on makeError()'s own message text) so
// +isCancellationError: can tell a cancellation apart from a message that merely happens to equal
// kCancelledMessage for some unrelated reason.
constexpr NSInteger kCancelledErrorCode = 2;
constexpr const char* kCancelledMessage = "Cancelled";

// Persisted pipeline products are valid only for the exact resolved, single-simulation config
// that produced them. In particular, an Absorbing checkbox changes the physical CSXCAD model but
// not the shape of geometry.json or the S-parameter CSVs, so merely finding those files is not
// enough to prove they can be reused. Bump this version whenever a solver/serialization change
// makes otherwise-identical saved products unsafe to restore.
constexpr const char* kPipelineCacheVersion = "KiEMS-pipeline-cache-v12\n";
constexpr const char* kGeometryCacheInputsName = "cache_inputs.txt";
constexpr const char* kResultsCacheInputsName = "cache_inputs.txt";

std::optional<std::string> readWholeFile(const std::filesystem::path& path) {
    std::ifstream in(path, std::ios::binary);
    if (!in.is_open()) return std::nullopt;
    return std::string(std::istreambuf_iterator<char>(in), std::istreambuf_iterator<char>());
}

std::string sha256Hex(const std::string& data) {
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(data.data(), static_cast<CC_LONG>(data.size()), digest);
    static constexpr char hex[] = "0123456789abcdef";
    std::string out;
    out.reserve(2 * CC_SHA256_DIGEST_LENGTH);
    for (unsigned char byte : digest) {
        out.push_back(hex[byte >> 4]);
        out.push_back(hex[byte & 0xF]);
    }
    return out;
}

// simulation.json alone doesn't identify the model: it only names the KiCad board, whose contents
// (copied into fab/ by exportKicadPcb before this is called) can change under an identical config.
// Digest the board and its project (net classes) too, so editing the PCB invalidates saved products.
std::optional<std::string> pipelineCacheInputs(const PathsConfig& paths) {
    auto config = readWholeFile(paths.configFile);
    if (!config.has_value()) return std::nullopt;
    auto board = readWholeFile(paths.fabBoardFile);
    if (!board.has_value()) return std::nullopt;
    auto project = readWholeFile(paths.fabProjectFile);
    return std::string(kPipelineCacheVersion) + "board-sha256 " + sha256Hex(*board) + "\nproject-sha256 " +
           (project.has_value() ? sha256Hex(*project) : std::string("none")) + "\n" + *config;
}

// Every pipeline of a document shares its scratch package's fab/ export, so a report restoring
// saved results in the background must not export (or digest) it while a job's own preparation is
// rewriting it. flock() locks belong to the open file description, so this serializes threads of
// this process as well as other processes, with no shared in-memory state.
class ScratchPackageLock {
public:
    explicit ScratchPackageLock(const std::filesystem::path& packageDir)
        : _descriptor(::open((packageDir / ".prepare.lock").c_str(), O_CREAT | O_RDWR | O_CLOEXEC, 0644)) {
        if (_descriptor >= 0) {
            while (::flock(_descriptor, LOCK_EX) != 0 && errno == EINTR) {}
        }
    }
    ~ScratchPackageLock() {
        if (_descriptor >= 0) ::close(_descriptor);
    }
    ScratchPackageLock(const ScratchPackageLock&) = delete;
    ScratchPackageLock& operator=(const ScratchPackageLock&) = delete;

private:
    int _descriptor;
};

// The eye settings only feed the results preview, built afresh from the saved products, so they're
// left out when deciding whether those products still match: changing a mask must not throw away an
// FDTD run the next time the document opens. Inputs that don't parse are compared verbatim.
std::string withoutEyeAnalysisSettings(const std::string& cacheInputs) {
    // The header is three lines (version, board digest, project digest); simulation.json follows.
    std::size_t configStart = 0;
    for (int line = 0; line < 3; ++line) {
        configStart = cacheInputs.find('\n', configStart);
        if (configStart == std::string::npos) return cacheInputs;
        ++configStart;
    }
    nlohmann::json config = nlohmann::json::parse(cacheInputs.substr(configStart), nullptr, false);
    if (config.is_discarded() || !config.contains("simulations") || !config["simulations"].is_array()) {
        return cacheInputs;
    }
    for (auto& simulation : config["simulations"]) {
        if (!simulation.is_object()) continue;
        for (const char* key : {"eye_bit_rate", "eye_draw_count", "adversarial_shared_clock", "eye_test"}) {
            simulation.erase(key);
        }
    }
    return cacheInputs.substr(0, configStart) + config.dump();
}

bool cacheInputsMatch(const std::filesystem::path& marker, const std::optional<std::string>& current) {
    if (!current.has_value()) return false;
    const auto saved = readWholeFile(marker);
    return saved.has_value() &&
           (*saved == *current || withoutEyeAnalysisSettings(*saved) == withoutEyeAnalysisSettings(*current));
}

void saveCacheInputs(const std::filesystem::path& marker, const std::optional<std::string>& current) {
    if (!current.has_value()) return;
    const std::filesystem::path temporary = marker.string() + ".tmp";
    std::ofstream out(temporary, std::ios::binary | std::ios::trunc);
    if (!out.is_open()) {
        Cu::logWarning("Could not write pipeline cache marker " + temporary.string());
        return;
    }
    out.write(current->data(), static_cast<std::streamsize>(current->size()));
    out.close();
    if (!out) {
        Cu::logWarning("Could not finish pipeline cache marker " + temporary.string());
        return;
    }
    std::error_code ec;
    std::filesystem::remove(marker, ec);
    ec.clear();
    std::filesystem::rename(temporary, marker, ec);
    if (ec) Cu::logWarning("Could not install pipeline cache marker " + marker.string() + ": " + ec.message());
}

NSError* makeCancelledError() {
    return [NSError errorWithDomain:EMSConfigErrorDomain
                                code:kCancelledErrorCode
                            userInfo:@{NSLocalizedDescriptionKey : @(kCancelledMessage)}];
}

// Evenly-spaced frequency samples between start/stop -- matches libkiems's own (private)
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

/// The irregular-domain inputs Copper classifies the XY grid from (cutout loops, padding, ring cell
/// size). Shared by the FDTD run and gridStatistics so both see exactly the same active cells.
void applyDomainConfig(copper::CopperFDTDPortConfig& portConfig, const kiems::SlicedBoard& sliced,
                       const kiems::ComputedGridLines& gridLines, const EMSConfig& config) {
    for (const auto& loop : sliced.cutoutLoops) {
        std::vector<copper::CopperFDTDPortConfig::DomainPoint> out;
        out.reserve(loop.size());
        for (const auto& point : loop) out.push_back({point.x(), point.y()});
        portConfig.domainCutoutLoops.push_back(std::move(out));
    }
    const auto& bounds = sliced.bounds;
    const auto depth = static_cast<std::size_t>(config.grid().absorbingBoundaryCells());
    if (gridLines.x.size() > 2 * depth && gridLines.y.size() > 2 * depth) {
        portConfig.domainPadding = std::max({bounds.xMin - gridLines.x[depth],
                                             gridLines.x[gridLines.x.size() - depth - 1] - bounds.xMax,
                                             bounds.yMin - gridLines.y[depth],
                                             gridLines.y[gridLines.y.size() - depth - 1] - bounds.yMax});
    }
    portConfig.domainCPMLCellSize = config.grid().max();
}

/// Counts core/absorbing cells the way Copper's engine dispatches them (see EMSGridStatistics). The
/// CPML slab extents mirror copper::buildCPML(): `depth` lines at the lower face, `depth + 1` at the
/// upper, and no CPML at all on an axis too short to hold both.
EMSGridStatistics* computeGridStatistics(const kiems::SlicedBoard& sliced, const kiems::ComputedGridLines& gridLines,
                                         const EMSConfig& config, const SimulationConfig& simConfig) {
    const std::uint64_t lines[3] = {gridLines.x.size(), gridLines.y.size(), gridLines.z.size()};
    const auto depth = static_cast<std::uint64_t>(std::max(0, config.grid().absorbingBoundaryCells()));
    const auto slab = [depth](std::uint64_t count) { return count > 2 * depth ? 2 * depth + 1 : 0; };

    copper::CopperFDTDPortConfig domainConfig;
    applyDomainConfig(domainConfig, sliced, gridLines, config);
    const copper::CopperDomainMask domain = copper::buildDomainMask(
        gridLines.x, gridLines.y, domainConfig, static_cast<std::uint32_t>(depth));

    std::uint64_t core = 0;
    std::uint64_t boundary = 0;
    if (domain.empty()) {
        // Rectangular: CPML on all six faces.
        const std::uint64_t total = lines[0] * lines[1] * lines[2];
        core = 1;
        for (const std::uint64_t count : lines) core *= count - slab(count);
        boundary = total - core;
    } else {
        // Irregular: XY absorbing rings span every Z layer; interior columns have only Z slabs.
        std::uint64_t interiorNodes = 0;
        std::uint64_t ringNodes = 0;
        for (const auto& box : domain.dispatchBoxes) {
            const std::uint64_t nodes = std::uint64_t{box.width} * box.height;
            (box.region == copper::CopperDomainMask::Region::Interior ? interiorNodes : ringNodes) += nodes;
        }
        const std::uint64_t zSlab = slab(lines[2]);
        core = interiorNodes * (lines[2] - zSlab);
        boundary = ringNodes * lines[2] + interiorNodes * zSlab;
    }

    NSInteger excitedPorts = 0;
    for (const auto& port : simConfig.ports()) {
        if (port.excite()) ++excitedPorts;
    }
    return [[EMSGridStatistics alloc] initWithCountX:static_cast<NSInteger>(lines[0])
                                              countY:static_cast<NSInteger>(lines[1])
                                              countZ:static_cast<NSInteger>(lines[2])
                                           coreCells:static_cast<long long>(core)
                                       boundaryCells:static_cast<long long>(boundary)
                                    excitedPortCount:excitedPorts
                                 maxTimestepsPerPort:static_cast<NSInteger>(config.maxSteps())];
}

/// The kiems::FDTDPortRunner passed to kiems::generateResults() so the FDTD step runs in
/// this one process -- mirrors kiems/main.cpp's own runGPUPortInProcess() exactly (see its own
/// doc comment for why a portRunner has to do the prepareRunDirectory()/runFDTDPortOnGPU()/
/// probe-file-write sequence itself), just without CLI-style stdout progress logging: this app
/// reports progress through `progressHandler` instead (see EMSPipelineProgress's own doc comment).
///
/// `totalExcitedPorts`/`portsCompleted` let a multi-port simulation's overall Simulation-phase
/// progress read as one continuously-advancing 0...1 fraction across every excited port's own FDTD
/// run, rather than resetting to 0 and confusingly re-climbing to 1 once per port -- `portsCompleted`
/// is a plain `std::size_t&` (not atomic/thread-safety-guarded) because generateResults() calls this
/// FDTDPortRunner for each excited port strictly sequentially, never concurrently.
///
/// `outFieldFrameSeriesPath`, if non-null, is overwritten with this port's own on-disk field series
/// on success. The caller supplies a distinct path per excitation so every completed run remains
/// available to the field viewer.
std::expected<std::uint32_t, std::string> runGPUPortInProcess(Simulation& sim, std::int32_t excitedPortNumber,
                                                       EMSPipelineProgressHandler progressHandler,
                                                       std::size_t totalExcitedPorts, std::size_t& portsCompleted,
                                                       const std::string& simulationName,
                                                       const std::string& excitedNetName,
                                                       double boardZMinMeters, double boardZMaxMeters,
                                                       const std::filesystem::path& fieldFrameSeriesPath,
                                                       std::function<void(const std::filesystem::path&)> onWriterReady,
                                                       const copper::FieldFrameStorage& fieldFrameStorage,
                                                       std::uint32_t fieldFrameIntervalSteps,
                                                       std::filesystem::path* outFieldFrameSeriesPath,
                                                       const std::atomic<bool>& cancelRequested) {
    // Checked before doing any work for this port at all -- a multi-port simulation's excited
    // ports run strictly sequentially (see this function's own caller, generateResults()'s
    // FDTDPortRunner loop), so a cancellation requested while an earlier port was running (or
    // between ports) stops the *next* port from ever starting, without generateResults() itself
    // needing to know anything about cancellation.
    if (cancelRequested.load()) {
        return std::unexpected(kCancelledMessage);
    }
    auto cwdResult = currentPathOrError();
    if (!cwdResult) {
        return std::unexpected(cwdResult.error());
    }
    const std::filesystem::path cwd = *cwdResult;
    // Report one indeterminate SettingUp phase before directory preparation and Copper operator
    // construction. Without this, the UI's last-known phase
    // just stays whatever Geometry left it at (fraction 1.0), which is what made this look like
    // geometry itself was still running. No fraction/estimate of any kind attached -- a caller should
    // show an indeterminate ("barber pole") indicator for this phase, not a predicted countdown.
    if (progressHandler) {
        progressHandler([[EMSPipelineProgress alloc] initWithPhase:EMSPipelineProgressPhaseSettingUp
                                                            fraction:0.0
                                                      energyChangeDB:0.0
                                                targetEnergyChangeDB:0.0
                                                      absoluteEnergy:0.0
                                                    duringExcitation:NO
                                         simulationTimeSeconds:0.0
                                        excitationEndTimeSeconds:0.0
                                     plannedSimulationTimeSeconds:0.0
                                                   excitationF0Hz:0.0
                                                   excitationFcHz:0.0
                                                      excitedNetName:@(excitedNetName.c_str())
                                                         currentStep:0
                                                          totalSteps:0
                                                      portsCompleted:static_cast<NSInteger>(portsCompleted)
                                                    excitedPortCount:static_cast<NSInteger>(totalExcitedPorts)]);
    }
    if (auto result = sim.prepareRunDirectory(excitedPortNumber); !result) {
        return std::unexpected(result.error());
    }
    auto probeDirResult = currentPathOrError();
    if (!probeDirResult) {
        return std::unexpected(probeDirResult.error());
    }
    const std::filesystem::path probeDir = *probeDirResult;
    // Boundary kind left at runFDTDPortOnGPU()'s own default (real CPML -- see
    // Internal/CopperCPML.hpp). alphaMax is *not* left at
    // runFDTDPortOnGPU()'s own generic 100MHz-based default -- see copper::cpmlAlphaMaxForFrequency()'s
    // own doc comment for why a simulation whose configured sweep floor is below 100MHz (this app's own
    // Frequency::start() default is 1MHz -- config.hpp) needs alphaMax computed from that simulation's
    // own value instead, or late-time energy from the under-damped gap between the two frequencies
    // persists and visibly grows over a long run.
    //
    // Pass the configured absorbing boundary depth explicitly so Copper and GridGenerator use the same one.
    const double cpmlAlphaMax = copper::cpmlAlphaMaxForFrequency(sim.config().frequency().start());
    copper::CopperFDTDPortConfig portConfig;
    portConfig.boundaryIsPEC = sim.boundaryIsPEC();
    portConfig.f0 = sim.excitationF0();
    portConfig.fc = sim.excitationFc();
    portConfig.maxTimesteps = sim.maxTimesteps();
    applyDomainConfig(portConfig, sim.slicedBoard(), sim.computedGridLines(), sim.config());
    copper::CopperFDTDProgressCallback onCopperProgress;
    if (progressHandler) {
        onCopperProgress = [&](const copper::CopperFDTDProgress& p) {
            // runFDTDPortOnGPU brackets its own GPU-buffer/discovery setup with synthetic 0/1 and
            // 1/1 reports.  That work is still part of the indeterminate SettingUp phase reported
            // above; treating those markers as timestep progress made the simulation bar run
            // 0% -> 100% and then jump back to the real FDTD fraction.  Only actual timesteps belong
            // on the determinate Simulation progress bar.
            if (p.phase != copper::CopperFDTDPhase::FDTDRun) {
                return;
            }
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
                                            duringExcitation:p.duringExcitation
                                 simulationTimeSeconds:p.simulationTimeSeconds
                                excitationEndTimeSeconds:p.excitationEndTimeSeconds
                             plannedSimulationTimeSeconds:p.plannedSimulationTimeSeconds
                                           excitationF0Hz:p.excitationF0Hz
                                           excitationFcHz:p.excitationFcHz
                                              excitedNetName:@(excitedNetName.c_str())
                                                 currentStep:static_cast<NSInteger>(p.currentStep)
                                                  totalSteps:static_cast<NSInteger>(p.totalSteps)
                                              portsCompleted:static_cast<NSInteger>(portsCompleted)
                                            excitedPortCount:static_cast<NSInteger>(totalExcitedPorts)];
            progressHandler(progress);
        };
    }
    // Check the solver's rasterized metal for nets the board keeps apart that it joins anyway (see
    // Simulation::writeMetalShortReport()); findings land in shorts.txt beside ports.txt, and a
    // failure to check only costs the check, never the run.
    try {
        const copper::CopperMetalMap metal(sim.csx(), portConfig);
        sim.writeMetalShortReport(
            [&](const std::array<double, 3>& point) { return metal.regionAt(point); },
            [&](const std::array<double, 3>& start, const std::array<double, 3>& stop) {
                return metal.regionsIn(start, stop);
            },
            probeDir);
    } catch (const std::exception& exception) {
        Cu::logWarning(std::string("Couldn't check the grid for shorted nets: ") + exception.what());
    }
    copper::FieldFrameSeriesRequest fieldSeries;
    fieldSeries.path = fieldFrameSeriesPath;
    fieldSeries.simulationName = simulationName;
    fieldSeries.excitedPort = excitedPortNumber;
    fieldSeries.boardZMin = boardZMinMeters;
    fieldSeries.boardZMax = boardZMaxMeters;
    fieldSeries.onWriterReady = std::move(onWriterReady);
    fieldSeries.storage = fieldFrameStorage;
    fieldSeries.captureIntervalSteps = fieldFrameIntervalSteps;
    // Keep the writer's default multi-frame compression chunk. FieldFrameSeriesReader requests only
    // the displayed frame's hyperslab and retains that frame plus one prefetched successor, so the
    // viewer's resident memory remains bounded independently of the series length.
    const copper::CopperFDTDRunResult gpuResult = copper::runFDTDPortOnGPU(
        sim.csx(), portConfig, onCopperProgress, cpmlAlphaMax,
        static_cast<std::uint32_t>(sim.config().grid().absorbingBoundaryCells()), [&] { return cancelRequested.load(); },
        fieldSeries);
    // Best-effort restore -- `cwd` no longer existing shouldn't discard an otherwise-successful run's
    // own results (unlike currentPathOrError()'s other two call sites above, both load-bearing).
    std::error_code restoreEc;
    std::filesystem::current_path(cwd, restoreEc);
    if (gpuResult.cancelled) {
        return std::unexpected(kCancelledMessage);
    }
    if (!gpuResult.success) {
        return std::unexpected(gpuResult.errorMessage);
    }
    ++portsCompleted;
    if (!gpuResult.fieldFrameSeriesPath.has_value()) {
        return std::unexpected("Copper completed without producing its requested field-frame series");
    }
    if (outFieldFrameSeriesPath != nullptr) {
        *outFieldFrameSeriesPath = *gpuResult.fieldFrameSeriesPath;
    }

    for (const copper::CopperProbeResult& probeResult : gpuResult.probes) {
        std::ofstream probeFile(probeDir / probeResult.name);
        if (!probeFile.is_open()) {
            return std::unexpected("Failed to open probe file for writing: " +
                                    (probeDir / probeResult.name).string());
        }
        probeFile << probeResult.data();
    }
    return gpuResult.timestepsRun;
}

struct SavedFieldFrameSeries {
    std::vector<std::pair<std::int32_t, std::filesystem::path>> files;
    std::uint64_t generation = 0;
};

constexpr const char* kFieldFrameManifestName = "field_frames_current.txt";
// Field-frame series live in a `.kemsf` package directory -- one series file per excited port, in
// two alternating slots (see fieldFrameSeriesSlot in ensureStage:). Inside the document by default,
// or in the frame directory chosen in Settings.
constexpr const char* kFieldFramePackageExtension = ".kemsf";
constexpr const char* kDefaultFieldFramePackageName = "field_frames";

/// Writes one metadata file into a `.kemsf` package, replacing it atomically. Best-effort: the
/// frames themselves still play inside the document if this fails.
void writeFieldFramePackageFile(const std::filesystem::path& package, NSString* name, NSData* _Nullable data) {
    NSString* path = [@(package.c_str()) stringByAppendingPathComponent:name];
    NSError* error = nil;
    if (data == nil || ![data writeToFile:path options:NSDataWritingAtomic error:&error]) {
        Cu::logWarning("Could not write " + std::string(path.UTF8String) + ": " +
                       (error ? std::string(error.localizedDescription.UTF8String) : "nothing to write"));
    }
}

// Accepts both the `.kemsf` package's `port_N_S.h5` and the loose `field_frames_port_N_S.h5` files
// older documents kept directly in the simulation directory.
std::optional<std::pair<std::int32_t, std::uint64_t>> fieldFrameIdentity(const std::filesystem::path& path) {
    static const std::regex pattern(R"(^(?:field_frames_)?port_([0-9]+)_([01])\.h5$)");
    std::smatch match;
    const std::string filename = path.filename().string();
    if (!std::regex_match(filename, match, pattern)) {
        return std::nullopt;
    }
    try {
        const long long port = std::stoll(match[1].str());
        if (port < 0 || port > std::numeric_limits<std::int32_t>::max()) {
            return std::nullopt;
        }
        return std::pair{static_cast<std::int32_t>(port), static_cast<std::uint64_t>(std::stoull(match[2].str()))};
    } catch (const std::exception&) {
        return std::nullopt;
    }
}

void saveFieldFrameManifest(
    const std::filesystem::path& simulationDirectory,
    const std::vector<std::pair<std::int32_t, std::filesystem::path>>& series) {
    const std::filesystem::path destination = simulationDirectory / kFieldFrameManifestName;
    const std::filesystem::path temporary = destination.string() + ".tmp";
    std::ofstream out(temporary, std::ios::trunc);
    if (!out.is_open()) {
        Cu::logWarning("Could not write field-frame manifest " + temporary.string());
        return;
    }
    // Paths relative to the simulation directory when inside it (so the document stays movable),
    // absolute when the frames live in an external frame directory.
    for (const auto& [port, path] : series) {
        const std::filesystem::path relative = path.lexically_relative(simulationDirectory);
        const bool inside = !relative.empty() && *relative.begin() != "..";
        out << port << ' ' << (inside ? relative : path).string() << '\n';
    }
    out.close();
    if (!out) {
        Cu::logWarning("Could not finish writing field-frame manifest " + temporary.string());
        return;
    }
    std::error_code ec;
    std::filesystem::remove(destination, ec);
    ec.clear();
    std::filesystem::rename(temporary, destination, ec);
    if (ec) {
        Cu::logWarning("Could not install field-frame manifest " + destination.string() + ": " + ec.message());
    }
}

SavedFieldFrameSeries loadFieldFrameSeries(const std::filesystem::path& simulationDirectory) {
    SavedFieldFrameSeries restored;
    const std::filesystem::path manifest = simulationDirectory / kFieldFrameManifestName;
    std::ifstream in(manifest);
    if (in.is_open()) {
        std::int32_t declaredPort = -1;
        std::string entry;
        // The rest of each line is the path -- an external frame directory's may contain spaces.
        while (in >> declaredPort && std::getline(in >> std::ws, entry)) {
            const std::filesystem::path entryPath(entry);
            const std::filesystem::path path = entryPath.is_absolute() ? entryPath : simulationDirectory / entryPath;
            const auto identity = fieldFrameIdentity(path);
            if (!identity.has_value() || identity->first != declaredPort || !std::filesystem::is_regular_file(path)) {
                restored.files.clear();
                break;
            }
            restored.files.emplace_back(declaredPort, path);
            restored.generation = identity->second;
        }
        if (!restored.files.empty()) {
            return restored;
        }
    }

    // Compatibility with packages saved before the manifest existed. Each completed run used one
    // common 0/1 slot for all ports, so choose the slot containing the newest frame file, then take
    // every port from that slot. A newly saved run always has the unambiguous manifest above.
    std::error_code iteratorError;
    std::filesystem::directory_iterator iterator(simulationDirectory, iteratorError), end;
    std::optional<std::uint64_t> newestSlot;
    std::filesystem::file_time_type newestTime = std::filesystem::file_time_type::min();
    std::map<std::uint64_t, std::map<std::int32_t, std::filesystem::path>> bySlot;
    for (; !iteratorError && iterator != end; iterator.increment(iteratorError)) {
        const auto identity = fieldFrameIdentity(iterator->path());
        if (!identity.has_value() || !iterator->is_regular_file()) {
            continue;
        }
        bySlot[identity->second][identity->first] = iterator->path();
        std::error_code timeError;
        const auto modified = iterator->last_write_time(timeError);
        if (!timeError && (!newestSlot.has_value() || modified > newestTime)) {
            newestSlot = identity->second;
            newestTime = modified;
        }
    }
    if (newestSlot.has_value()) {
        restored.generation = *newestSlot;
        for (const auto& [port, path] : bySlot[*newestSlot]) {
            restored.files.emplace_back(port, path);
        }
    }
    return restored;
}

} // namespace

@implementation EMSSimulationPipelineBridge {
    std::string _simulationName;
    // Declared before _board: ivars are destroyed in reverse order, so the board is torn down while
    // its runtime is still alive.
    KicadRuntime* _runtime;

    // Reset together, only the first time any stage needs computing since construction or the last
    // invalidateFromStage: call -- see -ensurePrepared:error:. `_simConfig` points into
    // `_scaledConfig`'s own simulations() vector; valid as long as `_scaledConfig` itself is (never
    // resized after scaling), invalidated together with it.
    std::optional<EMSConfig> _scaledConfig;
    SimulationConfig* _simConfig;
    std::optional<PathsConfig> _paths;
    // pipelineCacheInputs() as of preparation, taken while this pipeline's own export and config
    // were the ones on disk. Stamps are written from this rather than re-read later, because other
    // pipelines rewrite the shared fab/ export whenever they're prepared. Reset with `_paths`.
    std::optional<std::string> _cacheInputs;
    NSString* _savedResultsUnavailableReason;
    // Set while the loaded results were saved under an older port numbering (see
    // kiems::savedPortRenumbering()); reset whenever they're discarded or replaced by a fresh run.
    std::optional<kiems::PortRenumbering> _savedRenumbering;
    NSString* _kicadSourcesWarning;
    // The fab/ copy of the KiCad board under `_paths` -- loaded on first use, reset with `_paths`.
    std::optional<libkicad::Board> _board;
    std::optional<SimulationData<SimulationStage::Configured>> _configured;

    std::optional<SimulationData<SimulationStage::Geometry>> _geometry;
    std::optional<SimulationData<SimulationStage::Grid>> _grid;
    std::optional<SimulationData<SimulationStage::Results>> _results;
    // Kept independently of SimulationData<Results> because a reopened document restores the
    // processed data directly from its saved CSVs. The raw incident/reflected FDTD phasors aren't
    // needed again unless Results is invalidated, at which point both objects are discarded and a
    // fresh run rebuilds them together.
    std::shared_ptr<Postprocessor> _postprocessor;
    // Set by -invalidatePostprocessing: the next Results-stage run rebuilds _results from the FDTD
    // port data already on disk (no new FDTD pass) when _results itself isn't in memory -- e.g.
    // after a reopen, which restores only _postprocessor.
    BOOL _reloadResultsFromDisk;

    // -geometryPreview's own cache -- buildGeometryPreview() now does real work (a libkicad
    // component-model export subprocess, plus via mesh generation), so unlike the flyweight it used
    // to be, it must not be rebuilt on every call. Reset alongside `_geometry`/`_grid` themselves
    // (see -invalidateFromStage:) since it's derived from exactly those two.
    EMSGeometryPreview* _geometryPreviewCache;
    // -gridStatistics's own cache, reset alongside _geometryPreviewCache.
    EMSGridStatistics* _gridStatisticsCache;
    EMSResultsPreview* _resultsPreviewCache;

    // One file per excited port. The Objective-C snapshots contain only metadata/lazy frame handles,
    // each sharing one open reader for its own series, so retaining every excitation does not retain
    // every field grid in RAM.
    std::vector<std::pair<std::int32_t, std::filesystem::path>> _fieldFrameSeries;
    std::mutex _fieldFrameSeriesMutex;
    std::uint64_t _fieldFrameSeriesGeneration;
    // Path -> last snapshot built for that exact SWMR series file, guarded by the same mutex above
    // -- -fieldSnapshots reuses each entry's own reader (refreshing it in place) across calls
    // instead of reopening the file from scratch every time, so a live progress-driven refresh
    // doesn't cold-start the decode/prefetch caches a still-open FieldViewer depends on for smooth
    // playback. Keyed by path rather than port index so a rerun's ping-ponged path (see
    // fieldFrameSeriesSlot below) naturally misses this cache and opens fresh, rather than
    // refreshing and serving the previous run's now-abandoned file.
    NSMutableDictionary<NSString*, EMSFieldSnapshot*>* _fieldSnapshotCache;

    // "<positiveExcitation port index>|<negativeExcitation port index>" -> last differential-mode
    // snapshot combined from that pair's own two legs, guarded by the same mutex above. These are
    // lightweight frame handles just like the single-ended snapshots; their field data is combined
    // only when the viewer asks to display a frame. Rebuild only when either leg publishes more.
    NSMutableDictionary<NSString*, EMSFieldSnapshot*>* _combinedFieldSnapshotCache;

    // "<primary series excitedPort>|<adversarial leg count>" -> last snapshot superposing that
    // primary series with every adversarial run, guarded by the same mutex above.
    NSMutableDictionary<NSString*, EMSFieldSnapshot*>* _adversarialFieldSnapshotCache;

    // Set by -requestCancellation (any thread), read by -ensurePrepared:/-ensureStage: (the
    // background thread actually running them) at each checkpoint -- see -requestCancellation's own
    // doc comment. Cleared at the top of -ensureStage: for the next run, not at the end of this one
    // -- avoids a race in the gap between one call finishing and the next one starting. Default-
    // constructed to false (C++20 std::atomic's default constructor value-initializes) -- no
    // in-class initializer here, Objective-C's ivar block doesn't support one the way a plain C++
    // class body would.
    // Held for the whole of -ensureStage: and -restoreSavedStages:, so a report restoring saved
    // results off JobScheduler's queue can't race a job that starts on this pipeline meanwhile.
    std::mutex _stageMutex;
    std::atomic<bool> _cancelRequested;
    std::atomic<bool> _lastEnsureStageWroteOutput;
}

- (instancetype)initWithSimulationName:(NSString*)simulationName runtime:(KicadRuntime*)runtime {
    self = [super init];
    if (self) {
        _simulationName = simulationName.UTF8String;
        _runtime = runtime;
        _simConfig = nullptr;
        _cancelRequested.store(false);
        _lastEnsureStageWroteOutput.store(false);
        _fieldFramePrecision = EMSFieldFramePrecisionFloat32;
        _fieldFrameChannels = EMSFieldFrameChannelsAllComponents;
        _fieldFrameIntervalSteps = 1000;
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
        return _postprocessor != nullptr;
    }
}

- (BOOL)lastEnsureStageWroteOutput {
    return _lastEnsureStageWroteOutput.load();
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
// package's own "simulation <name>.json" (saved below) ends up holding just this trimmed copy too -- a
// genuinely temporary, single-simulation file, distinct from the real project package's own.
- (nullable NSString*)kicadSourcesWarning {
    return _kicadSourcesWarning;
}

- (nullable NSString*)metalShortsWarning {
    if (!_paths.has_value()) return nil;
    // Every excited port's run writes its own shorts.txt (see Simulation::writeMetalShortReport()).
    std::set<std::string> findings;
    std::error_code ec;
    for (const auto& entry : std::filesystem::directory_iterator(_paths->simulationDir / _simulationName, ec)) {
        std::ifstream report(entry.path() / "shorts.txt");
        for (std::string line; std::getline(report, line);) {
            if (!line.empty() && line[0] != '#') findings.insert(line);
        }
    }
    if (findings.empty()) return nil;
    std::string text = "The simulation grid joins nets the board keeps apart -- refine the mesh there:";
    for (const std::string& finding : findings) text += "\n" + finding;
    return @(text.c_str());
}

- (BOOL)restoreSavedStagesWithConfig:(EMSConfigBridge*)config
                          packageDir:(NSString*)packageDir
                        kicadCliPath:(NSString*)kicadCliPath
                               error:(NSError**)error {
    std::lock_guard stageLock(_stageMutex);
    if (_paths.has_value()) {
        // Already prepared, perhaps when the saved products couldn't be matched; try again rather
        // than leave a completed simulation reading as not run.
        [self hydrateSavedStages];
        return YES;
    }
    _cancelRequested.store(false);
    return [self ensurePrepared:config packageDir:packageDir kicadCliPath:kicadCliPath error:error];
}

- (BOOL)ensurePrepared:(EMSConfigBridge*)config
             packageDir:(NSString*)packageDir
           kicadCliPath:(NSString*)kicadCliPath
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

    // Each pipeline writes its own trimmed config (FDTD workers read it back by path mid-run), so
    // preparing one simulation can't swap the config out from under another's run or cache check.
    const std::filesystem::path scratchPackage(packageDir.UTF8String);
    PathsConfig paths = PathsConfig::forConfigFile(scratchPackage / ("simulation " + _simulationName + ".json"),
                                                    kicadCliPath.UTF8String, "");
    std::optional<ScratchPackageLock> scratchLock(std::in_place, scratchPackage);

    // Simulate what KiCad has, including changes it has only autosaved (see resolveKicadSources()).
    // The trimmed config, and so every worker reading its scratch config file, then points at
    // the same snapshot.
    const kiems::KicadSources sources =
        kiems::resolveKicadSources(_runtime.cxxRuntime, *trimmedConfig.kicadPcbPath(), paths.fabDir / "kicad-source");
    _kicadSourcesWarning = sources.warning.empty() ? nil : @(sources.warning.c_str());
    trimmedConfig.setKicadPcbPath(sources.boardPath);
    if (auto result = kiems::exportKicadPcb(paths, sources.boardPath); !result) {
        if (error) *error = makeError(result.error());
        return NO;
    }
    // Open the board fab/ was exported from rather than fab/'s copy: KiCad holds one project at a
    // time, so a board on fab's copy of the project and the document's own board (the whole-board
    // view, net lists, previews) unloaded each other on every alternating query -- a full re-parse
    // each time, about a minute per simulation on a large board. Sharing the project lets both stay
    // loaded.
    const std::filesystem::path sourceProjectPath = std::filesystem::path(sources.boardPath).replace_extension(".kicad_pro");
    libkicad::Board board = std::filesystem::is_regular_file(sourceProjectPath)
        ? libkicad::Board(_runtime.cxxRuntime, sourceProjectPath.string(), sources.boardPath.string())
        : libkicad::Board(_runtime.cxxRuntime, paths.kicadBoardPaths());
    if (auto result = kiems::importStackup(board, trimmedConfig); !result) {
        if (error) *error = makeError(result.error());
        return NO;
    }
    if (auto result = kiems::resolveSimulationPorts(trimmedConfig, board); !result) {
        if (error) *error = makeError(result.error());
        return NO;
    }
    // packageDir is always a private scratch directory (see Document.pipelineDirectory's own doc
    // comment) that only ever gets fab/ems written into it; simulation.json itself is only ever
    // saved into the real, user-visible package. Saving the trimmed, already-port-resolved
    // single-simulation config here keeps this pipeline's own scratch config file self-contained
    // -- e.g. for a worker subprocess later spawned against paths.configFile -- without pulling in
    // every other simulation the live document happens to also contain.
    if (auto result = trimmedConfig.save(paths.configFile); !result) {
        if (error) *error = makeError(result.error());
        return NO;
    }

    EMSConfig scaled = trimmedConfig.scaledToSimulationUnits();
    // Scaling drops Simulation Set templates, which only generate other simulations.
    if (scaled.simulations().empty()) {
        if (error) *error = makeError("\"" + _simulationName + "\" is a Simulation Set; it isn't run itself.");
        return NO;
    }
    _scaledConfig.emplace(std::move(scaled));
    // trimmedConfig.simulations() (and so scaled.simulations()) has exactly one entry -- the trim
    // above found the one named _simulationName, and the check above rejected a Simulation Set.
    _simConfig = &_scaledConfig->simulations().front();
    _paths.emplace(std::move(paths));
    _board.emplace(std::move(board));
    _configured.emplace(*_simConfig);
    _cacheInputs = pipelineCacheInputs(*_paths);
    scratchLock.reset();
    [self hydrateSavedStages];
    return YES;
}

// Restores whichever stages the scratch package holds products for that match `_cacheInputs`, and
// that aren't in memory already. A missing, stale or malformed product is a normal cache miss: the
// stage is left for ensureStage to regenerate. Requires -ensurePrepared: to have succeeded.
- (void)hydrateSavedStages {
    // A pending -invalidatePostprocessing asked for results rebuilt from the FDTD data instead.
    if (!_paths.has_value() || _postprocessor != nullptr) {
        return;
    }
    if (_reloadResultsFromDisk) {
        [self noteSavedResultsUnavailable:"postprocessing is waiting to be rerun from the FDTD data"];
        return;
    }
    const std::optional<std::string>& currentCacheInputs = _cacheInputs;
    const std::filesystem::path geometryCacheInputs =
        _paths->geometryDir / _simulationName / kGeometryCacheInputsName;
    if (!cacheInputsMatch(geometryCacheInputs, currentCacheInputs)) {
        [self noteSavedResultsUnavailable:"Saved geometry/results ignored for " + _simulationName +
                     ": cache inputs differ from the current simulation configuration"];
        return;
    }

    // A reopened Document seeds this scratch package from its saved fab/ems directories before the
    // bridge is created (Document.pipelineDirectory). Hydrate every stage that can be reconstructed
    // from those files now, so ensureStage's post-prepare cache check can return before performing
    // another expensive FDTD run. A missing/malformed cache remains a normal cache miss: ensureStage
    // continues below and regenerates it instead of making the document unopenable.
    if (!_grid.has_value()) {
        auto loadedGrid = kiems::loadSimulationData(*_simConfig, kiems::simulationDataFile(*_paths, _simulationName));
        if (!loadedGrid) {
            [self noteSavedResultsUnavailable:"No saved pipeline data restored for " + _simulationName + ": " + loadedGrid.error()];
            return;
        }
        kiems::SimulationGeometry geometry = loadedGrid->geometry();
        kiems::SimulationGrid grid = loadedGrid->grid();
        _geometry.emplace(*_configured, std::move(geometry));
        _grid.emplace(*_geometry, std::move(grid));
    }

    const std::filesystem::path resultsCacheInputs =
        _paths->simulationDir / _simulationName / kResultsCacheInputsName;
    if (!cacheInputsMatch(resultsCacheInputs, currentCacheInputs)) {
        [self noteSavedResultsUnavailable:"Saved simulation results ignored for " + _simulationName +
                     ": cache inputs differ from the current simulation configuration"];
        return;
    }

    // The stamps cover the config, not how its ports resolve: check each run against the ports
    // it was simulated with. Runs from before absorb-only terminations were dropped still load,
    // renumbered onto the current ports.
    std::optional<kiems::PortRenumbering> renumbering;
    {
        std::error_code runsError;
        for (const auto& run : std::filesystem::directory_iterator(_paths->simulationDir / _simulationName, runsError)) {
            if (!run.is_directory()) continue;
            const std::filesystem::path portsTxt = run.path() / "ports.txt";
            const auto mismatch = kiems::resolvedPortsMismatch(*_simConfig, portsTxt);
            if (!mismatch) continue;
            auto runRenumbering = kiems::savedPortRenumbering(*_simConfig, portsTxt);
            if (!runRenumbering) {
                [self noteSavedResultsUnavailable:"Saved simulation results for " + _simulationName +
                                                  " are out of date: " + *mismatch + "; " + runRenumbering.error()];
                return;
            }
            if (renumbering && renumbering->savedFromCurrent != runRenumbering->savedFromCurrent) {
                [self noteSavedResultsUnavailable:"Saved simulation results for " + _simulationName +
                                                  " are out of date: its runs were simulated with different ports"];
                return;
            }
            renumbering = std::move(*runRenumbering);
        }
    }
    const kiems::PortRenumbering* const renumberingPtr = renumbering ? &*renumbering : nullptr;

    const std::vector<double> frequencies =
        linspace(_scaledConfig->frequency().start(), _scaledConfig->frequency().stop(),
                 kiems::constants::frequencySampleCount);
    auto restoredPostprocessor = std::make_shared<Postprocessor>(frequencies, *_simConfig);
    const std::filesystem::path simulationDirectory = _paths->simulationDir / _simulationName;
    try {
        if (auto result = restoredPostprocessor->loadSparams(simulationDirectory, renumberingPtr); !result) {
            [self noteSavedResultsUnavailable:"No saved simulation results restored for " + _simulationName + ": " + result.error()];
            return;
        }
        if (auto result = restoredPostprocessor->loadProbes(simulationDirectory, renumberingPtr); !result) {
            [self noteSavedResultsUnavailable:"Saved probe results could not be restored for " + _simulationName + ": " + result.error()];
            return;
        }
        restoredPostprocessor->processData();
    } catch (const std::exception& exception) {
        [self noteSavedResultsUnavailable:"Saved simulation results could not be restored for " + _simulationName + ": " +
                       exception.what()];
        return;
    }
    _postprocessor = std::move(restoredPostprocessor);
    _savedResultsUnavailableReason = nil;
    _savedRenumbering = std::move(renumbering);

    SavedFieldFrameSeries restoredFields = loadFieldFrameSeries(simulationDirectory);
    if (_savedRenumbering) {
        std::vector<std::pair<std::int32_t, std::filesystem::path>> renumbered;
        for (auto& [port, path] : restoredFields.files) {
            if (const auto current = _savedRenumbering->current(port)) renumbered.emplace_back(*current, std::move(path));
        }
        restoredFields.files = std::move(renumbered);
    }
    {
        std::lock_guard lock(_fieldFrameSeriesMutex);
        _fieldFrameSeries = std::move(restoredFields.files);
        _fieldFrameSeriesGeneration = restoredFields.generation;
    }
}

// Why -hydrateSavedStages left this simulation without results -- shown by the report in place
// of "not run", and logged where a Release build's console doesn't filter it out.
- (void)noteSavedResultsUnavailable:(const std::string&)reason {
    _savedResultsUnavailableReason = @(reason.c_str());
    NSLog(@"[restore] %s: %s", _simulationName.c_str(), reason.c_str());
}

- (nullable NSString*)renumberedResultsWarning {
    if (!_savedRenumbering || _postprocessor == nullptr) return nil;
    std::string dropped;
    for (const std::string& name : _savedRenumbering->droppedPorts) {
        dropped += (dropped.empty() ? "" : ", ") + name;
    }
    return @(("Simulated with absorbing terminations port resolution has since dropped (" + dropped +
              "); its results were renumbered onto the current ports. Rerun it for results from the current model.")
                 .c_str());
}

- (nullable NSString*)savedResultsUnavailableReason {
    return _savedResultsUnavailableReason;
}

- (BOOL)ensureStage:(EMSPipelineStage)stage
             config:(EMSConfigBridge*)config
         packageDir:(NSString*)packageDir
       kicadCliPath:(NSString*)kicadCliPath
           progress:(nullable EMSPipelineProgressHandler)progressHandler
              error:(NSError**)error {
    std::lock_guard stageLock(_stageMutex);
    _lastEnsureStageWroteOutput.store(false);
    if ([self hasStage:stage]) {
        return YES;
    }
    // Cleared here, not at the end of a run -- avoids a race in the gap between one call finishing
    // and the next one starting (see _cancelRequested's own ivar comment).
    _cancelRequested.store(false);
    if (![self ensurePrepared:config packageDir:packageDir kicadCliPath:kicadCliPath error:error]) {
        return NO;
    }
    // ensurePrepared also hydrates any stages persisted in a reopened package. It may therefore
    // have satisfied this request even though the pre-prepare hasStage check above was necessarily
    // false on a newly constructed bridge.
    if ([self hasStage:stage]) {
        return YES;
    }

    auto reportGeometryProgress = [&](double fraction) {
        if (progressHandler) {
            progressHandler([[EMSPipelineProgress alloc] initWithPhase:EMSPipelineProgressPhaseGeometry
                                                                 fraction:fraction
                                                           energyChangeDB:0
                                                     targetEnergyChangeDB:0
                                                           absoluteEnergy:0
                                                         duringExcitation:NO
                                              simulationTimeSeconds:0
                                             excitationEndTimeSeconds:0
                                          plannedSimulationTimeSeconds:0
                                                        excitationF0Hz:0
                                                        excitationFcHz:0
                                                           excitedNetName:nil
                                                              currentStep:0
                                                               totalSteps:0
                                                           portsCompleted:0
                                                         excitedPortCount:0]);
        }
    };
    auto reportGeometryProcessingProgress = [&](const kiems::GeometryProcessingProgress& progress) {
        const double primitiveFraction = progress.totalPrimitives == 0
            ? 0.0
            : std::clamp(static_cast<double>(progress.completedPrimitives) /
                             static_cast<double>(progress.totalPrimitives),
                         0.0, 1.0);
        switch (progress.phase) {
            case kiems::GeometryProcessingPhase::PolygonOperations:
                reportGeometryProgress(0.80 * primitiveFraction);
                break;
            case kiems::GeometryProcessingPhase::Triangulation:
                reportGeometryProgress(0.80 + 0.19 * primitiveFraction);
                break;
            case kiems::GeometryProcessingPhase::Finishing:
                reportGeometryProgress(0.99);
                break;
        }
    };

    if (!_geometry.has_value()) {
        if (_cancelRequested.load()) {
            if (error) *error = makeCancelledError();
            return NO;
        }
        reportGeometryProgress(0.0);
        auto geometryResult = kiems::generateGeometry(*_configured, *_scaledConfig, *_board,
                                                       reportGeometryProcessingProgress);
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
    // FDTD run is wanted -- see kiems::generateResults()'s own doc comment -- so those three
    // still run straight through together below).
    RunOptions options;
    options.backend = FDTDBackend::CopperGPU;

    if (!_grid.has_value()) {
        if (_cancelRequested.load()) {
            if (error) *error = makeCancelledError();
            return NO;
        }
        // Polygon processing and triangulation occupy the first 99%; grid placement, persistence,
        // and the remaining bookkeeping deliberately stay in the final one-percent tail.
        reportGeometryProgress(0.99);
        auto grid = kiems::generateGrid(*_geometry, *_scaledConfig, options, *_paths, *_board);
        _grid.emplace(*_geometry, std::move(grid));
        // A cached -geometryPreview built while only EMSPipelineStageGeometry had run (gridLines
        // still empty) would otherwise keep serving that stale, grid-less snapshot forever now that
        // grid lines actually exist.
        _geometryPreviewCache = nil;
        _gridStatisticsCache = nil;
        // Written to disk too (matching `kiems -g`) so a later CLI invocation against this same
        // saved package (e.g. `kiems -s`) can pick up straight from here without redoing any of
        // this work itself -- see GeometryResult::load()'s own doc comment. Unlike GeometryResult::
        // build(), nothing else along this path has created paths.geometryDir/_simulationName yet
        // (prepareRunDirectory() creates its own simulationDir subtree later, but that's a different
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
        if (auto result = kiems::saveSimulationData(
                *_grid, kiems::simulationDataFile(*_paths, _simulationName));
            !result) {
            if (error) *error = makeError(result.error());
            return NO;
        }
        saveCacheInputs(_paths->geometryDir / _simulationName / kGeometryCacheInputsName,
                        _cacheInputs);
        _lastEnsureStageWroteOutput.store(true);
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
        linspace(_scaledConfig->frequency().start(), _scaledConfig->frequency().stop(), kiems::constants::frequencySampleCount);

    if (!_results.has_value() && _reloadResultsFromDisk) {
        // No-op runner: generateResults() still sets up each port and then reads that port's
        // already-written probe files via getPortParameters(), it just never runs FDTD.
        auto loadOnlyRunner = [](Simulation&, std::int32_t) -> std::expected<std::uint32_t, std::string> {
            return std::uint32_t{0};
        };
        auto resultsResult =
            kiems::generateResults(*_grid, *_scaledConfig, options, *_paths, *_board, frequencies, loadOnlyRunner);
        if (!resultsResult) {
            if (error) *error = makeError("Could not reload FDTD results for postprocessing: " + resultsResult.error());
            return NO;
        }
        if (resultsResult->byExcitedPort.empty()) {
            if (error) *error = makeError("No port is configured to excite; nothing to simulate.");
            return NO;
        }
        _results.emplace(*_grid, std::move(*resultsResult));
        _reloadResultsFromDisk = NO;
    }

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
        double boardThickness = 0.0;
        for (const auto& substrate : _scaledConfig->getSubstrates()) {
            boardThickness += substrate.thickness();
        }
        constexpr double kSimUnitsToMeters =
            kiems::constants::baseUnit / static_cast<double>(kiems::constants::unitMultiplier);
        const double boardZMinMeters = -boardThickness * kSimUnitsToMeters;
        // Alternate files: the viewer may still have the preceding generation open while a rerun
        // begins, so truncating one fixed path is unsafe. Two slots avoid that collision without
        // leaving one potentially-large series behind for every rerun during the document's life.
        const std::uint64_t fieldFrameSeriesSlot = ++_fieldFrameSeriesGeneration % 2;
        const std::filesystem::path simulationDirectory = _paths->simulationDir / _simulationName;
        std::filesystem::path fieldFrameSeriesDirectory =
            simulationDirectory / (std::string(kDefaultFieldFramePackageName) + kFieldFramePackageExtension);
        if (NSString* frameDirectory = self.fieldFrameDirectory; frameDirectory.length > 0) {
            NSString* seriesName = self.fieldFrameSeriesName.length > 0 ? self.fieldFrameSeriesName
                                                                         : @(_simulationName.c_str());
            // A '/' would silently nest the package one level deeper.
            seriesName = [seriesName stringByReplacingOccurrencesOfString:@"/" withString:@"-"];
            fieldFrameSeriesDirectory = std::filesystem::path(frameDirectory.fileSystemRepresentation) /
                                        (std::string(seriesName.UTF8String) + kFieldFramePackageExtension);
        }
        {
            std::error_code directoryError;
            std::filesystem::create_directories(fieldFrameSeriesDirectory, directoryError);
            if (directoryError) {
                if (error) {
                    *error = makeError("Could not create the field-frame package " +
                                       fieldFrameSeriesDirectory.string() + ": " + directoryError.message());
                }
                return NO;
            }
        }
        {
            std::lock_guard lock(_fieldFrameSeriesMutex);
            _fieldFrameSeries.clear();
            _fieldSnapshotCache = nil;
            _combinedFieldSnapshotCache = nil;
            _adversarialFieldSnapshotCache = nil;
        }
        // Everything a `.kemsf` needs to play back without this document: how its series combine,
        // and the board to draw them over. Written before the first port runs so a package left
        // by an interrupted run still opens; series.json gains the series list when the run ends.
        FieldSeriesLayout packageLayout = [self fieldSeriesLayout];
        writeFieldFramePackageFile(fieldFrameSeriesDirectory, kFieldFramePackageLayoutName,
                                   encodeFieldSeriesLayout(packageLayout));
        {
            const kiems::ComputedGridLines* gridLines = _grid.has_value() ? &_grid->grid().gridLines : nullptr;
            EMSGeometryPreview* boardPreview =
                buildGeometryPreview(_geometry->geometry().slicedBoard, *_simConfig, *_scaledConfig, *_paths, *_board,
                                     gridLines);
            writeFieldFramePackageFile(fieldFrameSeriesDirectory, kFieldFramePackageBoardName, [boardPreview archivedData]);
        }
        auto portRunner = [self, progressHandler, totalExcitedPorts, &portsCompleted,
                           boardZMinMeters, fieldFrameSeriesDirectory,
                           fieldFrameSeriesSlot](
                               Simulation& sim, std::int32_t excitedPortNumber) {
            const std::string& excitedNetName =
                self->_simConfig->ports().at(static_cast<std::size_t>(excitedPortNumber)).netName();
            const std::filesystem::path requestedPath =
                fieldFrameSeriesDirectory /
                ("port_" + std::to_string(excitedPortNumber) + "_" +
                 std::to_string(fieldFrameSeriesSlot) + ".h5");
            // Advertise only after Copper has created and entered SWMR mode. The alternating path
            // may still contain an older run before H5Fcreate truncates it, so publishing it sooner
            // could briefly show stale fields during setup.
            auto onWriterReady = [self, excitedPortNumber](const std::filesystem::path& readyPath) {
                std::lock_guard lock(self->_fieldFrameSeriesMutex);
                self->_fieldFrameSeries.emplace_back(excitedPortNumber, readyPath);
            };
            copper::FieldFrameStorage storage;
            switch (self.fieldFramePrecision) {
                case EMSFieldFramePrecisionInt8: storage.precision = copper::FieldSamplePrecision::Int8; break;
                case EMSFieldFramePrecisionInt12: storage.precision = copper::FieldSamplePrecision::Int12; break;
                case EMSFieldFramePrecisionFloat16: storage.precision = copper::FieldSamplePrecision::Float16; break;
                case EMSFieldFramePrecisionFloat32: storage.precision = copper::FieldSamplePrecision::Float32; break;
            }
            storage.channels = self.fieldFrameChannels == EMSFieldFrameChannelsEnergy
                ? copper::FieldChannels::Energy : copper::FieldChannels::Components;
            const auto intervalSteps = static_cast<std::uint32_t>(
                std::clamp<NSUInteger>(self.fieldFrameIntervalSteps, 1, std::numeric_limits<std::uint32_t>::max()));
            std::filesystem::path completedPath;
            auto result = runGPUPortInProcess(sim, excitedPortNumber, progressHandler, totalExcitedPorts,
                                               portsCompleted, self->_simulationName, excitedNetName,
                                               boardZMinMeters, 0.0, requestedPath, std::move(onWriterReady),
                                               storage, intervalSteps, &completedPath,
                                               self->_cancelRequested);
            return result;
        };
        auto resultsResult =
            kiems::generateResults(*_grid, *_scaledConfig, options, *_paths, *_board, frequencies, portRunner);
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
        std::vector<std::pair<std::int32_t, std::filesystem::path>> completedSeries;
        {
            std::lock_guard lock(_fieldFrameSeriesMutex);
            completedSeries = _fieldFrameSeries;
        }
        saveFieldFrameManifest(simulationDirectory, completedSeries);
        for (const auto& [port, path] : completedSeries) {
            packageLayout.seriesFiles.emplace_back(port, path.filename().string());
        }
        writeFieldFramePackageFile(fieldFrameSeriesDirectory, kFieldFramePackageLayoutName,
                                   encodeFieldSeriesLayout(packageLayout));
    }

    if (_postprocessor == nullptr) {
        auto postprocessing = kiems::generatePostprocessing(*_results, frequencies);
        // calculateSparams() (inside generatePostprocessing()) alone isn't enough for this app's own
        // charts -- impedance/diff-pair/trace-delay data additionally needs processData() (see
        // Postprocessor::processData()'s own doc comment: "Should be called after
        // calculateSparams()"). Matches PostprocessResult::compute()'s own identical extra step,
        // which this bridge otherwise bypasses (that type exists for the CLI's whole-EMSConfig batch
        // use, keyed by simulation name across every simulation at once -- overkill for this
        // one-simulation-at-a-time pipeline, which already has its own Postprocessor directly).
        postprocessing.postprocessor->processData();
        // Written to disk too, matching what `kiems -a` would leave behind in the saved package.
        postprocessing.postprocessor->sparamToFile(_paths->simulationDir / _simulationName);
        postprocessing.postprocessor->probeToFile(_paths->simulationDir / _simulationName);
        _postprocessor = std::move(postprocessing.postprocessor);
        _savedRenumbering.reset();
        saveCacheInputs(_paths->simulationDir / _simulationName / kResultsCacheInputsName,
                        _cacheInputs);
        _lastEnsureStageWroteOutput.store(true);
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
    const kiems::ComputedGridLines* gridLines = _grid.has_value() ? &_grid->grid().gridLines : nullptr;
    _geometryPreviewCache =
        buildGeometryPreview(_geometry->geometry().slicedBoard, *_simConfig, *_scaledConfig, *_paths, *_board,
                             gridLines);
    return _geometryPreviewCache;
}

- (nullable EMSGridStatistics*)gridStatistics {
    if (!_geometry.has_value() || !_grid.has_value()) {
        return nil;
    }
    if (!_gridStatisticsCache) {
        _gridStatisticsCache = computeGridStatistics(_geometry->geometry().slicedBoard, _grid->grid().gridLines,
                                                     *_scaledConfig, *_simConfig);
    }
    return _gridStatisticsCache;
}

- (nullable EMSGeometryLayer*)geometryLayerNamed:(NSString*)layerName error:(NSError**)error {
    if (!_geometry || !_scaledConfig || !_board) return nil;
    const double tolerance = static_cast<double>(_scaledConfig->pixelSize()) *
                             kiems::constants::unitMultiplier;
    auto result = buildSlicedBoardLayerPreview(*_board, layerName.UTF8String,
                                                _geometry->geometry().slicedBoard, tolerance);
    if (!result) {
        if (error != nil) *error = makeError(result.error());
        return nil;
    }
    return *result;
}

- (nullable EMSResultsPreview*)resultsPreview {
    if (_postprocessor == nullptr) {
        return nil;
    }
    if (!_resultsPreviewCache) {
        // Read once per preview build, not per eye: each is one small probe file per excited port.
        const std::map<std::int32_t, double> runDurations =
            _paths.has_value() ? kiems::ExcitationPostprocessor::loadRunDurations(
                                     _paths->simulationDir / _simulationName, *_simConfig,
                                     _savedRenumbering ? &*_savedRenumbering : nullptr)
                               : std::map<std::int32_t, double>{};
        _resultsPreviewCache =
            buildResultsPreview(*_postprocessor, *_simConfig, _scaledConfig->frequency(), runDurations);
    }
    return _resultsPreviewCache;
}

- (void)updateEyeAnalysisFromSimulation:(EMSSimulationBridge*)simulation {
    if (_simConfig != nullptr) {
        // Through the bridge's own getter, which reads an unset bit rate as the frequency stop.
        _simConfig->setEyeBitRate(simulation.eyeBitRate);
        _simConfig->setEyeDrawCount(simulation.cxxSim.eyeDrawCount());
        _simConfig->setAdversarialSharedClock(simulation.cxxSim.adversarialSharedClock());
        _simConfig->setEyeTest(simulation.cxxSim.eyeTest());
    }
    _resultsPreviewCache = nil;
}

- (NSArray<EMSFieldSnapshot*>*)fieldSnapshots {
    std::vector<std::pair<std::int32_t, std::filesystem::path>> series;
    NSDictionary<NSString*, EMSFieldSnapshot*>* previousCache;
    {
        std::lock_guard lock(_fieldFrameSeriesMutex);
        series = _fieldFrameSeries;
        previousCache = [_fieldSnapshotCache copy];
    }
    // Refreshes the lightweight SWMR readers already open from a previous call (see
    // buildFieldSnapshot()'s own doc comment) on each UI progress refresh, discovering newly
    // published blocks without reopening the file or sharing an HDF5 handle across the simulation
    // and UI threads; each returned snapshot then owns its reader for lazy frame decoding/playback.
    NSMutableArray<EMSFieldSnapshot*>* snapshots = [NSMutableArray arrayWithCapacity:series.size()];
    NSMutableDictionary<NSString*, EMSFieldSnapshot*>* refreshedCache =
        [NSMutableDictionary dictionaryWithCapacity:series.size()];
    for (const auto& [portIndex, path] : series) {
        if (portIndex < 0 || static_cast<std::size_t>(portIndex) >= _simConfig->ports().size()) {
            continue;
        }
        const std::string& excitationName = _simConfig->ports()[static_cast<std::size_t>(portIndex)].name();
        NSString* pathKey = @(path.string().c_str());
        if (EMSFieldSnapshot* snapshot = buildFieldSnapshot(path, excitationName, previousCache[pathKey])) {
            [snapshots addObject:snapshot];
            refreshedCache[pathKey] = snapshot;
        }
    }
    {
        std::lock_guard lock(_fieldFrameSeriesMutex);
        // Only entries for paths still current survive -- a rerun's ping-ponged path naturally
        // drops the previous run's now-abandoned reader here instead of retaining it forever.
        _fieldSnapshotCache = refreshedCache;
    }

    // _simConfig is null until -ensurePrepared: has actually run -- snapshots is then still empty
    // too (nothing in _fieldFrameSeries yet), so there's nothing to combine.
    if (_simConfig == nullptr) {
        return [snapshots copy];
    }
    const FieldSeriesLayout layout = [self fieldSeriesLayout];
    FieldSnapshotCombinationCache combinationCache;
    {
        std::lock_guard lock(_fieldFrameSeriesMutex);
        combinationCache = {_combinedFieldSnapshotCache, _adversarialFieldSnapshotCache};
    }
    NSArray<EMSFieldSnapshot*>* assembled = assembleFieldSnapshots(snapshots, layout, combinationCache);
    {
        std::lock_guard lock(_fieldFrameSeriesMutex);
        _combinedFieldSnapshotCache = [combinationCache.differential mutableCopy];
        _adversarialFieldSnapshotCache = [combinationCache.adversarial mutableCopy];
    }
    return assembled;
}

/// This simulation's series combinations, from its resolved config -- see FieldSeriesLayout.
/// Requires _simConfig.
- (FieldSeriesLayout)fieldSeriesLayout {
    FieldSeriesLayout layout;
    layout.simulationName = _simulationName;
    for (std::size_t port = 0; port < _simConfig->ports().size(); ++port) {
        layout.excitationNames[static_cast<std::int32_t>(port)] = _simConfig->ports()[port].name();
    }
    for (const DifferentialPairConfig& pair : _simConfig->diffPairs()) {
        if (!pair.correct() || !pair.positiveExcitation().resolvedIndex().has_value() ||
            !pair.negativeExcitation().resolvedIndex().has_value()) {
            Cu::logDebug() << "fieldSnapshots: differential pair '"
                           << pair.name().value_or("(unnamed differential pair)")
                           << "' has an unresolved port reference, skipping";
            continue;
        }
        layout.differentialPairs.push_back({pair.displayName(), *pair.positiveExcitation().resolvedIndex(),
                                            *pair.negativeExcitation().resolvedIndex()});
    }
    for (const auto& excitation : _simConfig->excitations()) {
        if (!excitation.drivenPortIndex().has_value()) continue;
        const NSInteger port = *excitation.drivenPortIndex();
        if (excitation.isMain()) {
            layout.primaryPorts.insert(port);
        } else {
            layout.adversarialAmplitudes[port] += excitation.amplitude().value_or(1.0);
        }
    }
    return layout;
}

- (void)invalidatePostprocessing {
    if (_postprocessor == nullptr && !_results.has_value()) {
        // Nothing has been simulated (or restored) yet -- a normal Results run will postprocess.
        return;
    }
    _postprocessor.reset();
    _resultsPreviewCache = nil;
    if (_savedRenumbering && !_results.has_value()) {
        // The raw FDTD port files are in the saved numbering, which a reload through
        // generateResults() would misread; postprocess the renumbered saved results again instead.
        _savedRenumbering.reset();
        [self hydrateSavedStages];
        return;
    }
    _reloadResultsFromDisk = !_results.has_value();
}

- (void)invalidateFromStage:(EMSPipelineStage)stage {
    _reloadResultsFromDisk = NO;
    // The scratch directory is later copied wholesale back into the document package. Remove the
    // invalidated stage's persisted form as well as its in-memory objects, otherwise saving after a
    // config edit (but before rerunning) would preserve stale files that a future launch could
    // incorrectly restore as current.
    if (_paths.has_value()) {
        std::error_code removeError;
        if (stage == EMSPipelineStageGeometry || stage == EMSPipelineStageGrid) {
            std::filesystem::remove_all(_paths->geometryDir / _simulationName, removeError);
            if (removeError) {
                Cu::logWarning("Could not remove invalidated geometry cache for " + _simulationName + ": " +
                               removeError.message());
            }
        }
        removeError.clear();
        std::filesystem::remove_all(_paths->simulationDir / _simulationName, removeError);
        if (removeError) {
            Cu::logWarning("Could not remove invalidated simulation cache for " + _simulationName + ": " +
                           removeError.message());
        }
    }
    [self discardLoadedFromStage:stage];
}

// The in-memory half of -invalidateFromStage:, leaving the saved products on disk.
- (void)discardLoadedFromStage:(EMSPipelineStage)stage {
    switch (stage) {
    case EMSPipelineStageGeometry:
        // Everything depends, directly or transitively, on the sliced board -- discard the whole
        // chain, including the prepared/scaled config snapshot (a config edit invalidating geometry
        // might just as well have changed something scaledToSimulationUnits() would scale
        // differently, e.g. hull padding).
        _postprocessor.reset();
        _savedRenumbering.reset();
        _resultsPreviewCache = nil;
        _results.reset();
        {
            std::lock_guard lock(_fieldFrameSeriesMutex);
            _fieldFrameSeries.clear();
            _fieldSnapshotCache = nil;
            _combinedFieldSnapshotCache = nil;
            _adversarialFieldSnapshotCache = nil;
        }
        _grid.reset();
        _geometry.reset();
        _geometryPreviewCache = nil;
        _gridStatisticsCache = nil;
        _configured.reset();
        _board.reset();
        _paths.reset();
        _cacheInputs.reset();
        _simConfig = nullptr;
        _scaledConfig.reset();
        break;
    case EMSPipelineStageGrid:
        // Geometry stays valid -- only the grid lines (and anything built from them) get redone.
        _postprocessor.reset();
        _savedRenumbering.reset();
        _resultsPreviewCache = nil;
        _results.reset();
        {
            std::lock_guard lock(_fieldFrameSeriesMutex);
            _fieldFrameSeries.clear();
            _fieldSnapshotCache = nil;
            _combinedFieldSnapshotCache = nil;
            _adversarialFieldSnapshotCache = nil;
        }
        _grid.reset();
        _geometryPreviewCache = nil;
        _gridStatisticsCache = nil;
        break;
    case EMSPipelineStageResults:
        // Geometry (and the grid lines placed on it) stay valid -- only the FDTD run and its own
        // postprocessing get redone.
        _postprocessor.reset();
        _savedRenumbering.reset();
        _resultsPreviewCache = nil;
        _results.reset();
        {
            std::lock_guard lock(_fieldFrameSeriesMutex);
            _fieldFrameSeries.clear();
            _fieldSnapshotCache = nil;
            _combinedFieldSnapshotCache = nil;
            _adversarialFieldSnapshotCache = nil;
        }
        break;
    }
}

- (void)releaseLoadedStages {
    std::lock_guard stageLock(_stageMutex);
    _reloadResultsFromDisk = NO;
    [self discardLoadedFromStage:EMSPipelineStageGeometry];
}

@end
