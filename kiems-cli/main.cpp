//
//  main.cpp
//  kiems
//
//  CLI entry point. Ported from kiems/main.py.

#include <algorithm>
#include <array>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <optional>
#include <sstream>
#include <string>
#include <vector>

#if defined(__APPLE__)
#include <mach-o/dyld.h>
#endif

#include "arguments.hpp"

#include "kiems/config.hpp"
#include "kiems/constants.hpp"
#include "kiems/excitation_postprocess.hpp"
#include "kiems/geometry_result.hpp"
#include "kiems/importer.hpp"
#include "logging.hpp"
#include "kiems/paths_config.hpp"
#include "kiems/port_resolution.hpp"
#include "kiems/postprocess_result.hpp"
#include "kiems/simulation.hpp"
#include "kiems/simulation_result.hpp"

// Forward-declare-only boundary header (see its own file comment) -- it keeps Copper's private
// implementation details out of the CLI while accepting libkiems's CSXCAD geometry. This lets the
// CLI run Copper's GPU engine in-process (see
// runGPUPortInProcess() below) instead of posix_spawning copper_fdtd_worker as a separate process --
// the CLI links Copper.framework directly (see the Xcode project's own build settings), while
// libkiems itself still never does.
#include "CopperFDTDRunner.h"

using namespace kiems;
using namespace Cu;

namespace {

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

void printUsage() {
    std::cout << "Usage: EM-Simulator [-c CONFIG_FILE] [--update-config] [-g] [-s] [-p] [-a]\n"
                 "                    [--export-field [{outer,cu-outer,cu-inner,substrate} ...]]\n"
                 "                    [--oversampling N] [--absorbing-boundary-cells N] [-t] [--plot-phase] [-i INPUT] [-o OUTPUT]\n"
                 "                    [-d | -l {DEBUG,INFO,WARNING,ERROR}]\n\n"
                 "This application performs EM simulations directly from KiCad PCB files.\n\n"
                 "  -c, --config CONFIG_FILE   Path to config file [default: ./simulation.json]\n"
                 "  --update-config            Add missing fields to config file\n"
                 "  -g, --geometry             Create geometry\n"
                 "  -s, --simulate             Run simulation\n"
                 "  -p, --postprocess          Postprocess the data\n"
                 "  -a, --all                  Execute all steps (geometry, simulation, postprocessing)\n"
                 "  --export-field, --ef [...] [s] Export electric field data from the simulation\n"
                 "  --oversampling N           [s] Field dump time-oversampling (default: 4)\n"
                 "  --absorbing-boundary-cells N\n"
                 "                             [g] Depth in cells of the absorbing boundary on every face\n"
                 "                                 (CPML, plus the matched ring on an irregular domain),\n"
                 "                                 overriding grid.absorbing_boundary_cells (default: 8).\n"
                 "                                 Changes the geometry, so needs -g or -a\n"
                 "  -t, --transparent          [p] Export graphs with transparent background\n"
                 "  --plot-phase               [p] Plot phase on S-param graphs\n"
                 "  -i, --input INPUT          [p] Directory with input S-param files, OR a .kicad_pcb\n"
                 "                                 file to import directly into ./fab/ before running\n"
                 "  -o, --output OUTPUT        [p] Directory where results will be placed\n"
                 "  -d, --debug                Enable debug logging\n"
                 "  -l, --log LEVEL            Set log level (DEBUG, INFO, WARNING, ERROR)\n"
                 "  --backend {cpu,gpu}        [s] FDTD engine: openEMS CPU (default) or Copper GPU\n"
                 "  --dump-early-frames DIR    [s] Diagnostic only, GPU backend: instead of a normal run,\n"
                 "                                 step the first N timesteps one at a time, writing raw\n"
                 "                                 field components + coupling coefficients (cropped to a\n"
                 "                                 box around the excitation) to DIR/port<N>/ -- see\n"
                 "                                 copper::dumpEarlyFrames()'s own doc comment\n"
                 "  --dump-frame-count N       [s] Frame count for --dump-early-frames [default: 100]\n"
                 "  --dump-margin-cells N      [s] Crop margin (cells) for --dump-early-frames [default: 25]\n"
                 "  --dump-detailed-trace      [s] Diagnostic only, GPU backend: instead of a normal run,\n"
                 "                                 prints every intermediate update term (curl components,\n"
                 "                                 coefficients, excitation contribution) for a small box\n"
                 "                                 around the excitation over --dump-trace-steps timesteps --\n"
                 "                                 see copper::dumpDetailedTrace()'s own doc comment\n"
                 "  --dump-trace-steps N       [s] Step count for --dump-detailed-trace [default: 4]\n"
                 "  --dump-trace-box-side N    [s] Box side (cells) for --dump-detailed-trace [default: 4]\n";
}

/// CLI-only diagnostic knobs for --dump-early-frames/--dump-detailed-trace -- deliberately not part
/// of Arguments/RunOptions (Arguments belongs to this CLI; these are still separate one-off
/// debugging aids that do not belong in its normal command-line state).
struct DumpOptions {
    std::optional<std::filesystem::path> dir;
    bool detailedTrace = false;
    std::uint32_t traceSteps = 4;
    std::uint32_t traceBoxSide = 4;
    std::uint32_t frameCount = 100;
    std::uint32_t marginCells = 25;
};

[[noreturn]] void printUsageAndExit(int code) {
    printUsage();
    std::exit(code);
}

bool looksLikeFlag(const std::string& s) { return s.size() > 1 && s[0] == '-'; }

[[noreturn]] void missingValue(const std::string& flag) {
    std::cerr << "Missing value for " << flag << "\n";
    printUsageAndExit(2);
}

Arguments parseArguments(int argc, char** argv, DumpOptions& dumpOptions) {
    Arguments args;
    // Left relative: main() resolves these against the config file's own directory once parsing is
    // done (see the PathsConfig setup in main()), so a relative default -- or a relative -i/-o --
    // correctly resolves relative to simulation.json's location, not wherever the tool happened to
    // be invoked from.
    args.setInput(constants::simulationDir);
    args.setOutput(constants::resultsDir);

    static const std::vector<std::string> exportFieldChoices = {"outer", "cu-outer", "cu-inner", "substrate"};
    static const std::vector<std::string> logChoices = {"DEBUG", "INFO", "WARNING", "ERROR"};

    const std::vector<std::string> tokens(argv + 1, argv + argc);
    std::size_t i = 0;
    while (i < tokens.size()) {
        const std::string& tok = tokens[i];
        if (tok == "-h" || tok == "--help") {
            printUsageAndExit(0);
        } else if (tok == "-c" || tok == "--config") {
            if (++i >= tokens.size()) {
                missingValue(tok);
            }
            args.setConfigPath(tokens[i]);
        } else if (tok == "--update-config") {
            args.setUpdateConfig(true);
        } else if (tok == "-g" || tok == "--geometry") {
            args.setGeometry(true);
        } else if (tok == "-s" || tok == "--simulate") {
            args.setSimulate(true);
        } else if (tok == "-p" || tok == "--postprocess") {
            args.setPostprocess(true);
        } else if (tok == "-a" || tok == "--all") {
            args.setAll(true);
        } else if (tok == "--export-field" || tok == "--ef") {
            std::vector<std::string> values;
            while (i + 1 < tokens.size() && !looksLikeFlag(tokens[i + 1])) {
                ++i;
                if (std::find(exportFieldChoices.begin(), exportFieldChoices.end(), tokens[i]) ==
                    exportFieldChoices.end()) {
                    std::cerr << "argument --export-field: invalid choice: '" << tokens[i] << "'\n";
                    printUsageAndExit(2);
                }
                values.push_back(tokens[i]);
            }
            args.setExportField(values);
        } else if (tok == "--oversampling") {
            if (++i >= tokens.size()) {
                missingValue(tok);
            }
            args.setOversampling(std::stoi(tokens[i]));
        } else if (tok == "--absorbing-boundary-cells") {
            if (++i >= tokens.size()) {
                missingValue(tok);
            }
            const std::int32_t depth = std::stoi(tokens[i]);
            if (depth < 1 || depth > 64) {
                std::cerr << "argument --absorbing-boundary-cells: must be between 1 and 64\n";
                printUsageAndExit(2);
            }
            args.setAbsorbingBoundaryCells(depth);
        } else if (tok == "-t" || tok == "--transparent") {
            args.setTransparent(true);
        } else if (tok == "--plot-phase") {
            args.setPlotPhase(true);
        } else if (tok == "-i" || tok == "--input") {
            if (++i >= tokens.size()) {
                missingValue(tok);
            }
            args.setInput(std::filesystem::path(tokens[i]));
        } else if (tok == "-o" || tok == "--output") {
            if (++i >= tokens.size()) {
                missingValue(tok);
            }
            args.setOutput(std::filesystem::path(tokens[i]));
        } else if (tok == "-d" || tok == "--debug") {
            if (args.logLevel().has_value()) {
                std::cerr << "argument -d/--debug: not allowed with argument -l/--log\n";
                printUsageAndExit(2);
            }
            args.setDebug(true);
        } else if (tok == "-l" || tok == "--log") {
            if (args.debug()) {
                std::cerr << "argument -l/--log: not allowed with argument -d/--debug\n";
                printUsageAndExit(2);
            }
            if (++i >= tokens.size()) {
                missingValue(tok);
            }
            if (std::find(logChoices.begin(), logChoices.end(), tokens[i]) == logChoices.end()) {
                std::cerr << "argument -l/--log: invalid choice: '" << tokens[i] << "'\n";
                printUsageAndExit(2);
            }
            args.setLogLevel(tokens[i]);
        } else if (tok == "--backend") {
            if (++i >= tokens.size()) {
                missingValue(tok);
            }
            if (tokens[i] == "cpu") {
                args.setBackend(FDTDBackend::OpenEMSCPU);
            } else if (tokens[i] == "gpu") {
                args.setBackend(FDTDBackend::CopperGPU);
            } else {
                std::cerr << "argument --backend: invalid choice: '" << tokens[i] << "'\n";
                printUsageAndExit(2);
            }
        } else if (tok == "--dump-early-frames") {
            if (++i >= tokens.size()) {
                missingValue(tok);
            }
            dumpOptions.dir = std::filesystem::path(tokens[i]);
        } else if (tok == "--dump-frame-count") {
            if (++i >= tokens.size()) {
                missingValue(tok);
            }
            dumpOptions.frameCount = static_cast<std::uint32_t>(std::stoul(tokens[i]));
        } else if (tok == "--dump-margin-cells") {
            if (++i >= tokens.size()) {
                missingValue(tok);
            }
            dumpOptions.marginCells = static_cast<std::uint32_t>(std::stoul(tokens[i]));
        } else if (tok == "--dump-detailed-trace") {
            dumpOptions.detailedTrace = true;
        } else if (tok == "--dump-trace-steps") {
            if (++i >= tokens.size()) {
                missingValue(tok);
            }
            dumpOptions.traceSteps = static_cast<std::uint32_t>(std::stoul(tokens[i]));
        } else if (tok == "--dump-trace-box-side") {
            if (++i >= tokens.size()) {
                missingValue(tok);
            }
            dumpOptions.traceBoxSide = static_cast<std::uint32_t>(std::stoul(tokens[i]));
        } else {
            std::cerr << "Unknown argument: " << tok << "\n";
            printUsageAndExit(2);
        }
        ++i;
    }
    return args;
}

void setupLogging(const Arguments& args) {
    LogLevel level = LogLevel::Info;
    if (args.debug()) {
        level = LogLevel::Debug;
    }
    if (args.logLevel().has_value()) {
        const std::string& lvl = *args.logLevel();
        if (lvl == "DEBUG") {
            level = LogLevel::Debug;
        } else if (lvl == "INFO") {
            level = LogLevel::Info;
        } else if (lvl == "WARNING") {
            level = LogLevel::Warning;
        } else if (lvl == "ERROR") {
            level = LogLevel::Error;
        }
    }
    setLogLevel(level);
}

// macOS's KiCad.app doesn't symlink kicad-cli anywhere on a typical PATH -- it ships only inside
// the app bundle. Only the CLI is allowed to do this kind of PATH-scanning/fallback-guessing (a
// sandboxed GUI can't, and libkiems itself never does -- see importer.hpp); it's a convenience
// specific to this unsandboxed developer tool.
std::filesystem::path resolveKicadCli() {
    const char* pathEnv = std::getenv("PATH");
    if (pathEnv != nullptr) {
        std::stringstream pathStream(pathEnv);
        std::string dir;
        while (std::getline(pathStream, dir, ':')) {
            std::error_code ec;
            if (std::filesystem::is_regular_file(std::filesystem::path(dir) / "kicad-cli", ec)) {
                return "kicad-cli";
            }
        }
    }
    static const std::array<std::filesystem::path, 1> kKicadCliFallbackPaths = {
        "/Applications/KiCad/KiCad.app/Contents/MacOS/kicad-cli",
    };
    for (const auto& candidate : kKicadCliFallbackPaths) {
        std::error_code ec;
        if (std::filesystem::is_regular_file(candidate, ec)) {
            logDebug("kicad-cli not found on PATH; using " + candidate.string());
            return candidate;
        }
    }
    return "kicad-cli"; // Let posix_spawnp's own error reporting handle the "truly not found" case.
}

// Absolute path to the currently-running executable's own directory, via the macOS-specific
// _NSGetExecutablePath API. Worker executables are sibling build products in the same
// BUILT_PRODUCTS_DIR as this CLI.
std::filesystem::path executableDir() {
    std::array<char, 4096> buffer{};
    std::uint32_t size = static_cast<std::uint32_t>(buffer.size());
    if (_NSGetExecutablePath(buffer.data(), &size) != 0) {
        return {};
    }
    std::error_code ec;
    const std::filesystem::path resolved = std::filesystem::canonical(buffer.data(), ec);
    return (ec ? std::filesystem::path(buffer.data()) : resolved).parent_path();
}

void createDir(const std::filesystem::path& directoryPath, bool cleanup = false) {
    if (cleanup && std::filesystem::exists(directoryPath)) {
        std::filesystem::remove_all(directoryPath);
    }
    if (!std::filesystem::exists(directoryPath)) {
        std::filesystem::create_directory(directoryPath);
    }
}

/// Every simulation's frequency-domain results, once postprocessed -- writes CSVs/PNGs to
/// args.output()/<simName>, mirroring what the old postprocess() free function did directly
/// against a raw Postprocessor. Excitation postprocessing (a downstream consumer of S-parameters,
/// not part of the geometry->simulate->postprocess pipeline itself) still reaches into the
/// underlying Postprocessor via PostprocessResult::postprocessorFor() -- see its doc comment.
void saveAndRenderResults(const PostprocessResult& results, const Arguments& args) {
    for (const auto& simConfig : results.config().simulations()) {
        const std::filesystem::path outDir = args.output() / simConfig.name();
        std::filesystem::create_directories(outDir);

        results.saveToFile(simConfig.name(), outDir);
        results.renderSParams(simConfig.name(), args.plotPhase(), args.transparent(), outDir);
        results.renderImpedance(simConfig.name(), args.transparent(), outDir);
        results.renderSmith(simConfig.name(), args.transparent(), outDir);
        results.renderDiffPairSParams(simConfig.name(), args.transparent(), outDir);
        results.renderDiffImpedance(simConfig.name(), args.transparent(), outDir);
        results.renderTraceDelays(simConfig.name(), args.transparent(), outDir);
        results.renderProbes(simConfig.name(), args.transparent(), outDir);

        if (!simConfig.excitations().empty()) {
            const Postprocessor* post = results.postprocessorFor(simConfig.name());
            if (post == nullptr) {
                continue;
            }
            const std::filesystem::path excDir = outDir / "excitations";
            std::filesystem::create_directories(excDir);
            const std::vector<double> frequencies =
                linspace(results.config().frequency().start(), results.config().frequency().stop(),
                         constants::frequencySampleCount);
            ExcitationPostprocessor excPost(
                simConfig, *post, frequencies, results.config().frequency(),
                ExcitationPostprocessor::loadRunDurations(args.input() / simConfig.name(), simConfig));
            excPost.run();
            excPost.saveToFile(excDir);
            excPost.renderPlots(excDir, args.transparent());
        }
    }
}

/// Renders one GeometryProgress update -- the CLI's own consumer of GeometryResult::build()'s
/// progress contract (which simulation, out of how many, and which of its two phases -- see
/// GeometryPhase's own doc comment), in the same plain logInfo()-per-update style as
/// printCopperProgress() below.
void printGeometryProgress(const GeometryProgress& progress) {
    std::ostringstream line;
    line << "[Geometry] [" << progress.simulationName << " " << (progress.simulationIndex + 1) << "/"
         << progress.simulationCount << "] ";
    switch (progress.phase) {
    case GeometryPhase::SlicingBoard:
        line << "Slicing board: " << (progress.currentStep == 0 ? "starting..." : "complete");
        break;
    case GeometryPhase::PlacingGrid:
        line << "Placing grid: " << (progress.currentStep == 0 ? "starting..." : "complete");
        break;
    }
    logInfo(line.str());
}

/// Renders one copper::CopperFDTDProgress update -- the CLI's own consumer of the 3-axis progress
/// contract (major phase / progress through that phase's own step count / progress toward the
/// energy-decay end criteria) copper::runFDTDPortOnGPU() reports, in place of its own default
/// stdout printing (see CopperFDTDRunner.h's own doc comment on `onProgress`). Deliberately a plain
/// logInfo() line per update (matching every other stage's own "Creating geometry"/"Running
/// simulation" style in this file) rather than an in-place-updating status line -- keeps this
/// readable in a piped/redirected log too, not just an interactive terminal.
void printCopperProgress(const copper::CopperFDTDProgress& progress) {
    std::ostringstream line;
    line << "[Copper] ";
    switch (progress.phase) {
    case copper::CopperFDTDPhase::Setup:
        line << "Setup: " << (progress.currentStep == 0 ? "starting..." : "complete");
        break;
    case copper::CopperFDTDPhase::FDTDRun: {
        const double stepPercent = progress.totalSteps > 0
                                        ? 100.0 * static_cast<double>(progress.currentStep) /
                                              static_cast<double>(progress.totalSteps)
                                        : 0.0;
        const double energyPercent =
            progress.targetEnergyChangeDB > 0.0
                ? std::min(100.0, 100.0 * progress.energyChangeDB / progress.targetEnergyChangeDB)
                : 0.0;
        line << "FDTD run: step " << progress.currentStep << "/" << progress.totalSteps << " (" << std::fixed
             << std::setprecision(1) << stepPercent << "%) | energy decay " << std::setprecision(2)
             << progress.energyChangeDB << "/" << progress.targetEnergyChangeDB << "dB (" << std::setprecision(1)
             << energyPercent << "%)";
        break;
    }
    case copper::CopperFDTDPhase::Postprocessing:
        line << "Postprocessing...";
        break;
    }
    logInfo(line.str());
}

/// The SimulationResult::FDTDPortRunner passed to SimulationResult::run() when
/// RunOptions::backend == FDTDBackend::CopperGPU -- runs Copper's GPU engine directly in this
/// process instead of the default sim.run(excitedPortNumber), which posix_spawns a separate worker.
/// By the time generateResults() (simulation_data.hpp) hands `sim` to this callback, it has already
/// had adoptSlicedBoard()/adoptGridLines()/populateGeometry()/setupPorts() called on it -- this only needs to
/// do the FDTD-specific part (prepareRunDirectory()/runFDTDPortOnGPU()), mirroring
/// copper_fdtd_worker/main.cpp's own sequence; the only difference is *where* it runs: here, in the
/// CLI's own process, rather than a spawned child's.
std::expected<std::uint32_t, std::string> runGPUPortInProcess(Simulation& sim, std::int32_t excitedPortNumber) {
    const std::filesystem::path cwd = std::filesystem::current_path();
    if (auto result = sim.prepareRunDirectory(excitedPortNumber); !result) {
        return std::unexpected(result.error());
    }
    const std::filesystem::path probeDir = std::filesystem::current_path();
    const double cpmlAlphaMax = copper::cpmlAlphaMaxForFrequency(sim.config().frequency().start());
    copper::CopperFDTDPortConfig portConfig;
    portConfig.boundaryIsPEC = sim.boundaryIsPEC();
    portConfig.f0 = sim.excitationF0();
    portConfig.fc = sim.excitationFc();
    portConfig.maxTimesteps = sim.maxTimesteps();
    const copper::CopperFDTDRunResult gpuResult =
        copper::runFDTDPortOnGPU(sim.csx(), portConfig, printCopperProgress, cpmlAlphaMax,
                                  static_cast<std::uint32_t>(sim.config().grid().absorbingBoundaryCells()));
    std::filesystem::current_path(cwd);
    if (!gpuResult.success) {
        return std::unexpected(gpuResult.errorMessage);
    }

    // runFDTDPortOnGPU() no longer writes probe files itself -- write them explicitly here so
    // getPortParameters()'s existing on-disk S-parameter pipeline keeps working unmodified (see
    // copper_fdtd_worker/main.cpp's own identical step) via CopperProbeResult::data().
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

/// --dump-early-frames/--dump-detailed-trace's own FDTDPortRunner -- same prepareRunDirectory()/
/// cwd-restore shape as runGPUPortInProcess() above, but calls copper::dumpEarlyFrames() and/or
/// copper::dumpDetailedTrace() instead of copper::runFDTDPortOnGPU(): a one-off diagnostic capture,
/// not a normal run, so there are no probe files to write afterward. dumpEarlyFrames() writes into
/// `dumpOptions.dir`/port<excitedPortNumber>/ so a multi-port config doesn't clobber one port's dump
/// with another's; dumpDetailedTrace() just prints to stdout, no directory needed.
std::expected<std::uint32_t, std::string> dumpGPUPortInProcess(Simulation& sim, std::int32_t excitedPortNumber,
                                                        const DumpOptions& dumpOptions) {
    const std::filesystem::path cwd = std::filesystem::current_path();
    if (auto result = sim.prepareRunDirectory(excitedPortNumber); !result) {
        return std::unexpected(result.error());
    }
    const double cpmlAlphaMax = copper::cpmlAlphaMaxForFrequency(sim.config().frequency().start());
    copper::CopperFDTDPortConfig portConfig;
    portConfig.boundaryIsPEC = sim.boundaryIsPEC();
    portConfig.f0 = sim.excitationF0();
    portConfig.fc = sim.excitationFc();
    portConfig.maxTimesteps = sim.maxTimesteps();
    if (dumpOptions.dir.has_value()) {
        const std::filesystem::path portDir = *dumpOptions.dir / ("port" + std::to_string(excitedPortNumber));
        const std::string error =
            copper::dumpEarlyFrames(sim.csx(), portConfig, portDir, dumpOptions.frameCount,
                                     dumpOptions.marginCells, cpmlAlphaMax, static_cast<std::uint32_t>(sim.config().grid().absorbingBoundaryCells()));
        if (!error.empty()) {
            std::filesystem::current_path(cwd);
            return std::unexpected(error);
        }
    }
    if (dumpOptions.detailedTrace) {
        std::fprintf(stdout, "Copper: dumpDetailedTrace for excited port %d\n", excitedPortNumber);
        const std::string error =
            copper::dumpDetailedTrace(sim.csx(), portConfig, dumpOptions.traceSteps,
                                       dumpOptions.traceBoxSide, cpmlAlphaMax, static_cast<std::uint32_t>(sim.config().grid().absorbingBoundaryCells()));
        if (!error.empty()) {
            std::filesystem::current_path(cwd);
            return std::unexpected(error);
        }
    }
    std::filesystem::current_path(cwd);
    return std::uint32_t{0}; // a diagnostic capture, not a full run
}

} // namespace

int main(int argc, char** argv) {
    DumpOptions dumpOptions;
    Arguments args = parseArguments(argc, argv, dumpOptions);

    // Every relative path in this tool (fab/, ems/, etc., and -i/-o if given as relative paths) is
    // meant to be relative to simulation.json's own location, not to wherever the tool happened to
    // be invoked from -- resolve the config path against the invoking shell's cwd once, here, and
    // build every other path explicitly off its parent directory below (no chdir: the library
    // itself never assumes a shared process cwd, and this CLI doesn't need one either).
    const std::filesystem::path cfgPath = std::filesystem::absolute(
        args.configPath().has_value() ? std::filesystem::path(*args.configPath()) : constants::defaultConfigPath);
    args.setConfigPath(cfgPath.string());
    const std::filesystem::path configDir = cfgPath.parent_path();
    if (args.input().is_relative()) {
        args.setInput(configDir / args.input());
    }
    if (args.output().is_relative()) {
        args.setOutput(configDir / args.output());
    }

    const PathsConfig paths = PathsConfig::forConfigFile(cfgPath, resolveKicadCli(),
                                                          executableDir() / "kiems_fdtd_worker",
                                                          executableDir() / "copper_fdtd_worker");

    if (args.input().extension() == ".kicad_pcb") {
        if (auto result = exportKicadPcb(paths, args.input()); !result) {
            logError(result.error());
            return EXIT_FAILURE;
        }
    }
    auto configResult = EMSConfig::parse(cfgPath, args.updateConfig());
    if (!configResult) {
        logError(configResult.error());
        return EXIT_FAILURE;
    }
    EMSConfig config = std::move(*configResult);
    if (args.absorbingBoundaryCells().has_value()) {
        // A standalone -s reuses the cached grid, built with whatever depth -g had: running it with
        // another would grade the wrong cells as CPML.
        if (!args.geometry() && !args.all()) {
            logError("--absorbing-boundary-cells changes the geometry: run it with -g or -a");
            return EXIT_FAILURE;
        }
        config.grid().setAbsorbingBoundaryCells(*args.absorbingBoundaryCells());
    }
    setupLogging(args);
    if (args.updateConfig()) {
        return EXIT_SUCCESS;
    }

    if (!args.geometry() && !args.simulate() && !args.postprocess() && !args.all()) {
        logInfo(R"(No steps selected. Exiting. To select steps use "-g", "-s", "-p", "-a" flags)");
        return EXIT_SUCCESS;
    }

    // Resolved unconditionally (not just for -g/-a): -s/-p invoked standalone, in a separate
    // process from whichever earlier invocation ran -g, still need every simulation's ports()
    // populated -- simulate() reads which ports to excite, postprocess() needs the right port
    // count to load Sx<port>.csv files. Requires fab/board.kicad_pcb (persisted by exportKicadPcb())
    // from this invocation's own -i or an earlier one, and fab/stackup.json (importStackup()) for
    // resolveSimulationPorts()'s copper-layer-index lookup.
    // Owned by main so the loaded KiCad board is torn down before main returns, while KiCad's own
    // process-wide state is still alive -- not from exit()'s static destructors.
    auto runtime = libkicad::Runtime::create();
    if (!runtime) {
        logError(runtime.error());
        return EXIT_FAILURE;
    }
    const libkicad::Board board(*runtime, paths.kicadBoardPaths());

    if (auto result = importStackup(board, config); !result) {
        logError(result.error());
        return EXIT_FAILURE;
    }
    if (auto result = resolveSimulationPorts(config, board); !result) {
        logError(result.error());
        return EXIT_FAILURE;
    }

    createDir(paths.baseDir);

    RunOptions options;
    options.oversampling = args.oversampling();
    options.exportField = args.exportField();
    options.transparent = args.transparent();
    options.plotPhase = args.plotPhase();
    options.backend = args.backend();
    // --dump-early-frames/--dump-detailed-trace only exist on Copper's GPU engine -- silently
    // forcing the backend here (rather than requiring --backend gpu too) keeps either one-off
    // diagnostic invocation to a single flag.
    const bool dumpRequested = dumpOptions.dir.has_value() || dumpOptions.detailedTrace;
    if (dumpRequested) {
        options.backend = FDTDBackend::CopperGPU;
    }

    // Each stage's result carries its own EMSConfig forward (see geometry_result.hpp), so `config`
    // itself is only ever consumed once, by whichever of build()/load() below runs first -- every
    // later stage reads through the previous stage's result instead of touching `config` again.
    std::optional<GeometryResult> geometryResult;
    std::optional<SimulationResult> simulationResult;
    std::optional<PostprocessResult> postprocessResult;

    if (args.geometry() || args.all()) {
        logInfo("Creating geometry");
        createDir(paths.geometryDir, true);
        auto result = GeometryResult::build(std::move(config), options, paths, board, printGeometryProgress);
        if (!result) {
            logError(result.error());
            return EXIT_FAILURE;
        }
        geometryResult = std::move(*result);
    }
    if (args.simulate() || args.all()) {
        logInfo("Running simulation");
        createDir(paths.simulationDir, true);
        if (!geometryResult.has_value()) {
            // -s invoked standalone, in a separate process from whichever -g produced this data.
            auto loaded = GeometryResult::load(std::move(config), paths);
            if (!loaded) {
                logError(loaded.error());
                return EXIT_FAILURE;
            }
            geometryResult = std::move(*loaded);
        }
        // Copper's GPU backend runs directly in this process (see runGPUPortInProcess()'s own doc
        // comment for why, and why libkiems itself still never depends on Copper) rather than
        // posix_spawning copper_fdtd_worker -- the whole point being live progress reporting through
        // this process's own stdout, not a separate process's.
        auto result =
            options.backend != FDTDBackend::CopperGPU
                ? SimulationResult::run(*geometryResult, options, board)
                : (dumpRequested
                       ? SimulationResult::run(*geometryResult, options, board,
                                                [&dumpOptions](Simulation& sim, std::int32_t excitedPortNumber) {
                                                    return dumpGPUPortInProcess(sim, excitedPortNumber, dumpOptions);
                                                })
                       : SimulationResult::run(*geometryResult, options, board,
                                                [](Simulation& sim, std::int32_t excitedPortNumber) {
                                                    return runGPUPortInProcess(sim, excitedPortNumber);
                                                }));
        if (!result) {
            logError(result.error());
            return EXIT_FAILURE;
        }
        if (dumpRequested) {
            logInfo("Dump diagnostic complete; skipping postprocessing (there are no valid S-parameters from a "
                     "short diagnostic run)");
            return EXIT_SUCCESS;
        }
        simulationResult = std::move(*result);
    }
    if (args.postprocess() || args.all()) {
        logInfo("Postprocessing");
        createDir(paths.resultsDir, true);
        if (!simulationResult.has_value()) {
            // -p invoked standalone: reload geometry (if this invocation didn't just build it) and
            // Sx<port>.csv from args.input() -- the CLI's own -i override, defaulting to
            // paths.simulationDir -- rather than re-running FDTD.
            if (!geometryResult.has_value()) {
                auto loaded = GeometryResult::load(std::move(config), paths);
                if (!loaded) {
                    logError(loaded.error());
                    return EXIT_FAILURE;
                }
                geometryResult = std::move(*loaded);
            }
            auto loaded = SimulationResult::load(*geometryResult, args.input());
            if (!loaded) {
                logError(loaded.error());
                return EXIT_FAILURE;
            }
            simulationResult = std::move(*loaded);
        }
        auto result = PostprocessResult::compute(*simulationResult);
        if (!result) {
            logError(result.error());
            return EXIT_FAILURE;
        }
        postprocessResult = std::move(*result);
        saveAndRenderResults(*postprocessResult, args);
    }

    return EXIT_SUCCESS;
}
