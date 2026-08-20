// A dedicated, single-purpose process that runs exactly one port's FDTD pass and exits. Spawned by
// Simulation::run() (see simulation.hpp/.cpp) via posix_spawn -- this is the process that actually
// chdirs for openEMS's benefit, so the caller's own process/working directory is never touched.
// Takes one argument: the path to a small job.json (written by Simulation::run() into the
// simulation's own output directory) describing which config/simulation/port to run. On failure,
// writes a human-readable message to "worker_error.txt" next to the job file and exits non-zero;
// Simulation::run() reads that file back to build its own std::expected failure.

#include <cstdlib>
#include <fstream>
#include <iostream>
#include <sstream>
#include <string>

#include <nlohmann/json.hpp>

#include "gerber2ems/config.hpp"
#include "gerber2ems/importer.hpp"
#include "gerber2ems/logging.hpp"
#include "gerber2ems/paths_config.hpp"
#include "gerber2ems/port_resolution.hpp"
#include "gerber2ems/simulation.hpp"
#include "gerber2ems/simulation_data.hpp"

using namespace gerber2ems;

namespace {

void writeError(const std::filesystem::path& simPath, const std::string& message) {
    std::ofstream err(simPath / "worker_error.txt");
    err << message;
}

} // namespace

int main(int argc, char** argv) {
    if (argc != 2) {
        std::cerr << "usage: gerber2ems_fdtd_worker <job.json>\n";
        return EXIT_FAILURE;
    }
    const std::filesystem::path jobPath(argv[1]);
    const std::filesystem::path simPath = jobPath.parent_path();

    std::ifstream jobFile(jobPath);
    if (!jobFile.is_open()) {
        writeError(simPath, "Could not open job file: " + jobPath.string());
        return EXIT_FAILURE;
    }
    nlohmann::json job;
    try {
        jobFile >> job;
    } catch (const nlohmann::json::parse_error& error) {
        writeError(simPath, std::string("Failed to parse job file: ") + error.what());
        return EXIT_FAILURE;
    }

    std::filesystem::path configPath;
    std::string simName;
    std::int32_t excitedPort = 0;
    std::filesystem::path kicadQueryHelperPath;
    try {
        configPath = job.at("config_path").get<std::string>();
        simName = job.at("simulation_name").get<std::string>();
        excitedPort = job.at("excited_port").get<std::int32_t>();
        kicadQueryHelperPath = job.at("kicad_query_helper_path").get<std::string>();
    } catch (const nlohmann::json::exception& error) {
        writeError(simPath, std::string("Malformed job file: ") + error.what());
        return EXIT_FAILURE;
    }

    RunOptions options;
    options.oversampling = job.value("oversampling", 4);

    auto configResult = EMSConfig::parse(configPath, false);
    if (!configResult) {
        writeError(simPath, configResult.error());
        return EXIT_FAILURE;
    }
    EMSConfig config = std::move(*configResult);

    // No kicad-cli/worker paths needed -- this process never exports gerbers or spawns a further
    // worker, it only reloads the geometry a prior stage already saved to disk. kicadQueryHelperPath
    // *is* needed though: simConfig.ports() isn't (de)serialized (see PortConfig's own doc comment
    // in config.hpp), so it must be rebuilt fresh below via importStackup()+resolveSimulationPorts(),
    // exactly like main.cpp's own -s/-p path does, using the same helper path the spawning process
    // already resolved (passed through job.json rather than re-derived here).
    const PathsConfig paths = PathsConfig::forConfigFile(configPath, "", kicadQueryHelperPath, "");

    if (auto result = importStackup(paths, config); !result) {
        writeError(simPath, result.error());
        return EXIT_FAILURE;
    }
    if (auto result = resolveSimulationPorts(config, paths); !result) {
        writeError(simPath, result.error());
        return EXIT_FAILURE;
    }

    SimulationConfig* simConfig = nullptr;
    for (auto& sim : config.simulations()) {
        if (sim.name() == simName) {
            simConfig = &sim;
            break;
        }
    }
    if (simConfig == nullptr) {
        writeError(simPath, "Simulation \"" + simName + "\" not found in " + configPath.string());
        return EXIT_FAILURE;
    }

    // Deserializes the exact same SimulationData<Grid> (sliced board + placed grid lines --
    // see simulation_data.hpp) GeometryResult::build()/load() would have in memory in-process --
    // this worker is a genuinely separate process, so a file is the only way to get it. Rebuilding
    // this Simulation's ContinuousStructure from that (populateGeometry(), including its own
    // setBoundaryConditions(true)) happens on *this* freshly-constructed Simulation's own `_fdtd`,
    // not a reload of some other object's state -- unlike the old geometry.xml round trip (which
    // only ever restored `_csx`, leaving `_fdtd`'s separate boundary-condition state at openEMS's
    // own PEC default), there's no second, explicit setBoundaryConditions() call needed here.
    auto simDataResult = loadSimulationData(*simConfig, simulationDataFile(paths, simName));
    if (!simDataResult) {
        writeError(simPath, simDataResult.error());
        return EXIT_FAILURE;
    }

    Simulation simulation(*simConfig, config, options, paths);
    simulation.adoptSlicedBoard(simDataResult->geometry().slicedBoard);
    simulation.adoptGridLines(simDataResult->grid().gridLines);
    if (auto result = simulation.populateGeometry(); !result) {
        writeError(simPath, result.error());
        return EXIT_FAILURE;
    }
    simulation.setExcitation();
    simulation.setupPorts(excitedPort);

    if (auto result = simulation.runFDTDInPlace(excitedPort); !result) {
        writeError(simPath, result.error());
        return EXIT_FAILURE;
    }
    return EXIT_SUCCESS;
}
