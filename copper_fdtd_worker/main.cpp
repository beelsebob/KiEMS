// A dedicated, single-purpose process that runs exactly one port's FDTD pass on Copper's GPU
// engine and exits -- the GPU sibling of kiems_fdtd_worker (see that target's own main.cpp,
// which this one mirrors closely), posix_spawn'd by Simulation::run() when
// RunOptions::backend == FDTDBackend::CopperGPU. Same job.json contract, same worker_error.txt
// failure convention, same exit-code convention -- Simulation::run() itself can't tell which
// backend actually produced a given simulation directory's output.
//
// This worker stays on Copper's public boundary: simulation.hpp supplies the complete CSXCAD type,
// while CopperFDTDRunner.h only forward-declares it. No Copper/Internal headers are needed here.

#include <cstdlib>
#include <fstream>
#include <iostream>
#include <sstream>
#include <string>

#include <nlohmann/json.hpp>

#include "kiems/config.hpp"
#include "kiems/constants.hpp"
#include "kiems/importer.hpp"
#include "kiems/paths_config.hpp"
#include "kiems/port_resolution.hpp"
#include "kiems/simulation.hpp"
#include "kiems/simulation_data.hpp"

#include "CopperFDTDRunner.h"

using namespace kiems;

namespace {

void writeError(const std::filesystem::path& simPath, const std::string& message) {
    std::ofstream err(simPath / "worker_error.txt");
    err << message;
}

} // namespace

int main(int argc, char** argv) {
    if (argc != 2) {
        std::cerr << "usage: copper_fdtd_worker <job.json>\n";
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

    const PathsConfig paths = PathsConfig::forConfigFile(configPath, "", "");

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

    // Deserializes the exact same SimulationData<Grid> (sliced board + placed grid lines -- see
    // simulation_data.hpp) GeometryResult::build()/load() would have in memory in-process -- this
    // worker is a genuinely separate process, so a file is the only way to get it. This rebuilds
    // the worker's own ContinuousStructure directly from that cached geometry and grid.
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
    simulation.setupPorts(excitedPort);

    // prepareRunDirectory() chdirs into this port's simulation directory (and stays there on success
    // -- see its own doc comment) so the Copper run's probe files land in the same place the real
    // CPU worker's would have.
    const std::filesystem::path cwd = std::filesystem::current_path();
    if (auto result = simulation.prepareRunDirectory(excitedPort); !result) {
        writeError(simPath, result.error());
        return EXIT_FAILURE;
    }

    const std::filesystem::path probeDir = std::filesystem::current_path();
    // Pass pmlDepthCells explicitly so Copper and GridGenerator use the same CPML shell depth.
    const double cpmlAlphaMax = copper::cpmlAlphaMaxForFrequency(simulation.config().frequency().start());
    copper::CopperFDTDPortConfig portConfig;
    portConfig.boundaryIsPEC = simulation.boundaryIsPEC();
    portConfig.f0 = simulation.excitationF0();
    portConfig.fc = simulation.excitationFc();
    portConfig.maxTimesteps = simulation.maxTimesteps();
    const copper::CopperFDTDRunResult gpuResult = copper::runFDTDPortOnGPU(
        simulation.csx(), portConfig, {}, cpmlAlphaMax,
        kiems::constants::pmlDepthCells);
    std::filesystem::current_path(cwd);
    if (!gpuResult.success) {
        writeError(simPath, gpuResult.errorMessage);
        return EXIT_FAILURE;
    }

    // runFDTDPortOnGPU() no longer writes probe files itself -- this worker is one of the callers
    // that still needs them on disk (job.json's own contract is a directory of probe files, matching
    // what kiems_fdtd_worker's real CPU RunFDTD() would have produced), so it writes them
    // explicitly from the returned in-memory result via CopperProbeResult::data().
    for (const copper::CopperProbeResult& probeResult : gpuResult.probes) {
        std::ofstream probeFile(probeDir / probeResult.name);
        if (!probeFile.is_open()) {
            writeError(simPath, "Failed to open probe file for writing: " + (probeDir / probeResult.name).string());
            return EXIT_FAILURE;
        }
        probeFile << probeResult.data();
    }
    return EXIT_SUCCESS;
}
