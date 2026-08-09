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
#include "gerber2ems/logging.hpp"
#include "gerber2ems/paths_config.hpp"
#include "gerber2ems/simulation.hpp"

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
    try {
        configPath = job.at("config_path").get<std::string>();
        simName = job.at("simulation_name").get<std::string>();
        excitedPort = job.at("excited_port").get<std::int32_t>();
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

    // No kicad-cli/kicad_query_helper/worker paths needed -- this process never shells out further,
    // it only reloads the geometry a prior stage already saved to disk.
    const PathsConfig paths = PathsConfig::forConfigFile(configPath, "", "", "");

    Simulation simulation(*simConfig, config, options, paths);
    if (auto result = simulation.loadGeometry(); !result) {
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
