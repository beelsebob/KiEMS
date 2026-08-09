//
//  main.cpp
//  geber2ems
//
//  CLI entry point. Ported from gerber2ems/main.py.

#include <algorithm>
#include <array>
#include <cstdlib>
#include <filesystem>
#include <iostream>
#include <optional>
#include <sstream>
#include <string>
#include <vector>

#if defined(__APPLE__)
#include <mach-o/dyld.h>
#endif

#include "gerber2ems/config.hpp"
#include "gerber2ems/constants.hpp"
#include "gerber2ems/excitation_postprocess.hpp"
#include "gerber2ems/importer.hpp"
#include "gerber2ems/logging.hpp"
#include "gerber2ems/paths_config.hpp"
#include "gerber2ems/port_resolution.hpp"
#include "gerber2ems/postprocess.hpp"
#include "gerber2ems/simulation.hpp"

using namespace gerber2ems;

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
                 "                    [--oversampling N] [-t] [--plot-phase] [-i INPUT] [-o OUTPUT]\n"
                 "                    [-d | -l {DEBUG,INFO,WARNING,ERROR}]\n\n"
                 "This application allows to perform EM simulations based on standard PCB\n"
                 "production files (gerber).\n\n"
                 "  -c, --config CONFIG_FILE   Path to config file [default: ./simulation.json]\n"
                 "  --update-config            Add missing fields to config file\n"
                 "  -g, --geometry             Create geometry\n"
                 "  -s, --simulate             Run simulation\n"
                 "  -p, --postprocess          Postprocess the data\n"
                 "  -a, --all                  Execute all steps (geometry, simulation, postprocessing)\n"
                 "  --export-field, --ef [...] [s] Export electric field data from the simulation\n"
                 "  --oversampling N           [s] Field dump time-oversampling (default: 4)\n"
                 "  -t, --transparent          [p] Export graphs with transparent background\n"
                 "  --plot-phase               [p] Plot phase on S-param graphs\n"
                 "  -i, --input INPUT          [p] Directory with input S-param files, OR a .kicad_pcb\n"
                 "                                 file to export gerbers/drill/position files from\n"
                 "                                 (via kicad-cli) into ./fab/ before running\n"
                 "  -o, --output OUTPUT        [p] Directory where results will be placed\n"
                 "  -d, --debug                Enable debug logging\n"
                 "  -l, --log LEVEL            Set log level (DEBUG, INFO, WARNING, ERROR)\n";
}

[[noreturn]] void printUsageAndExit(int code) {
    printUsage();
    std::exit(code);
}

bool looksLikeFlag(const std::string& s) { return s.size() > 1 && s[0] == '-'; }

[[noreturn]] void missingValue(const std::string& flag) {
    std::cerr << "Missing value for " << flag << "\n";
    printUsageAndExit(2);
}

Arguments parseArguments(int argc, char** argv) {
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
// sandboxed GUI can't, and libgerber2ems itself never does -- see importer.hpp); it's a convenience
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
// _NSGetExecutablePath API -- libkicad_smoketest is always a sibling build product in the same
// BUILT_PRODUCTS_DIR as this CLI. Only the CLI does this "sibling of self" resolution; the library
// itself takes the helper's path as an explicit PathsConfig field (see libkicad_query.hpp) so a
// sandboxed GUI app can point it at a bundled copy instead.
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

void geometry(EMSConfig& config, const RunOptions& options, const PathsConfig& paths) {
    for (auto& simConfig : config.simulations()) {
        logInfo("### Building geometry for simulation \"" + simConfig.name() + "\" ###");
        createDir(paths.geometryDir / simConfig.name());

        Simulation sim(simConfig, config, options, paths);
        sim.sliceBoard();
        sim.createMaterials();
        sim.addGerbers();
        sim.addGrid();
        sim.addSubstrates();
        if (options.exportField.has_value()) {
            sim.addDumpBoxes();
        }
        sim.setBoundaryConditions(false);
        sim.addVias();
        sim.addPorts();
        sim.saveGeometry();
    }
}

void simulate(EMSConfig& config, const RunOptions& options, const PathsConfig& paths) {
    for (auto& simConfig : config.simulations()) {
        createDir(paths.simulationDir / simConfig.name());

        std::optional<Simulation> sim;
        auto& ports = simConfig.ports();
        for (std::size_t index = 0; index < ports.size(); ++index) {
            if (ports[index].excite()) {
                sim.emplace(simConfig, config, options, paths);
                logInfo("[" + simConfig.name() + "] Simulating with excitation on port #" + std::to_string(index));
                sim->loadGeometry();
                sim->setExcitation();
                sim->setupPorts(static_cast<std::int32_t>(index));
                sim->run(static_cast<std::int32_t>(index));
            }
        }
        if (!sim.has_value()) {
            logError("[" + simConfig.name() + "] No port is configured to excite; nothing to simulate.");
            continue;
        }
        if (sim->ports().empty()) {
            sim->addVirtualPorts();
        }

        const std::vector<double> frequencies = linspace(config.frequency().start(), config.frequency().stop(), 1001);
        Postprocessor post(frequencies, simConfig);

        for (std::size_t index = 0; index < ports.size(); ++index) {
            if (ports[index].excite()) {
                auto [reflected, incident] = sim->getPortParameters(static_cast<std::int32_t>(index), frequencies);
                for (std::size_t i = 0; i < ports.size(); ++i) {
                    post.addPortData(static_cast<std::int32_t>(i), static_cast<std::int32_t>(index), incident[i],
                                      reflected[i]);
                }
            }
        }
        post.calculateSparams();
        post.sparamToFile(paths.simulationDir / simConfig.name());
    }
}

void postprocess(EMSConfig& config, const Arguments& args) {
    for (auto& simConfig : config.simulations()) {
        const std::filesystem::path outDir = args.output() / simConfig.name();
        std::filesystem::create_directories(outDir);

        const std::vector<double> frequencies = linspace(config.frequency().start(), config.frequency().stop(), 1001);
        Postprocessor post(frequencies, simConfig);
        post.loadSparams(args.input() / simConfig.name());
        post.processData();
        post.saveToFile(outDir);
        post.renderSParams(args.plotPhase(), args.transparent(), outDir);
        post.renderImpedance(args.transparent(), outDir);
        post.renderSmith(args.transparent(), outDir);
        post.renderDiffPairSParams(args.transparent(), outDir);
        post.renderDiffImpedance(args.transparent(), outDir);
        post.renderTraceDelays(args.transparent(), outDir);

        if (!simConfig.excitations().empty()) {
            const std::filesystem::path excDir = outDir / "excitations";
            std::filesystem::create_directories(excDir);
            ExcitationPostprocessor excPost(simConfig, post, frequencies, config.frequency());
            excPost.run();
            excPost.saveToFile(excDir);
            excPost.renderPlots(excDir, args.transparent());
        }
    }
}

} // namespace

int main(int argc, char** argv) {
    Arguments args = parseArguments(argc, argv);

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

    const PathsConfig paths =
        PathsConfig::forConfigDir(configDir, resolveKicadCli(), executableDir() / "libkicad_smoketest");

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
    if (auto result = importStackup(paths, config); !result) {
        logError(result.error());
        return EXIT_FAILURE;
    }
    if (auto result = resolveSimulationPorts(config, paths); !result) {
        logError(result.error());
        return EXIT_FAILURE;
    }

    createDir(paths.baseDir);

    RunOptions options;
    options.oversampling = args.oversampling();
    options.exportField = args.exportField();
    options.transparent = args.transparent();
    options.plotPhase = args.plotPhase();

    if (args.geometry() || args.all()) {
        logInfo("Creating geometry");
        createDir(paths.geometryDir, true);
        geometry(config, options, paths);
    }
    if (args.simulate() || args.all()) {
        logInfo("Running simulation");
        createDir(paths.simulationDir, true);
        simulate(config, options, paths);
    }
    if (args.postprocess() || args.all()) {
        logInfo("Postprocessing");
        createDir(paths.resultsDir, true);
        postprocess(config, args);
    }

    return EXIT_SUCCESS;
}
