// A dedicated, single-purpose process that runs exactly one port's FDTD pass on Copper's CPU
// engine and exits -- the CPU sibling of copper_fdtd_worker (see that target's own main.cpp,
// which this one mirrors closely; the two differ only in which copper::runFDTDPortOn{CPU,GPU}()
// they call). Spawned by Simulation::run() (see simulation.hpp/.cpp) via posix_spawn when
// RunOptions::backend == FDTDBackend::OpenEMSCPU -- that enumerator's name is a historical holdover
// from when this worker ran openEMS's own Engine::RunFDTD() directly; it now runs Copper's own CPU
// backend instead (see kiems::Simulation's own doc comments for why the real CPU stepping loop is
// no longer used by anything in this codebase). Same job.json contract, same worker_error.txt
// failure convention, same exit-code convention as copper_fdtd_worker -- Simulation::run() itself
// can't tell which backend actually produced a given simulation directory's output.
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
        std::cerr << "usage: kiems_fdtd_worker <job.json>\n";
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

    // Owned by main so the loaded KiCad board is torn down before main returns, while KiCad's own
    // process-wide state is still alive -- not from exit()'s static destructors.
    auto runtime = libkicad::Runtime::create();
    if (!runtime) {
        writeError(simPath, runtime.error());
        return EXIT_FAILURE;
    }
    const libkicad::Board board(*runtime, paths.kicadBoardPaths());

    if (auto result = importStackup(board, config); !result) {
        writeError(simPath, result.error());
        return EXIT_FAILURE;
    }
    if (auto result = resolveSimulationPorts(config, board); !result) {
        writeError(simPath, result.error());
        return EXIT_FAILURE;
    }
    // Simulation takes simulation-unit values, exactly as GeometryResult::build()/load() hand them
    // to the in-process path -- the parsed config is still in file units (see
    // EMSConfig::scaledToSimulationUnits()). Without this, every port, lumped component, via and
    // grid setting came out a factor of constants::unitMultiplier too small relative to the cached
    // sliced geometry and grid lines, which are already in simulation units.
    config = config.scaledToSimulationUnits();

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

    Simulation simulation(*simConfig, config, options, paths, board);
    simulation.adoptSlicedBoard(simDataResult->geometry().slicedBoard);
    simulation.adoptGridLines(simDataResult->grid().gridLines);
    if (auto result = simulation.populateGeometry(); !result) {
        writeError(simPath, result.error());
        return EXIT_FAILURE;
    }
    simulation.setupPorts(excitedPort);

    // prepareRunDirectory() chdirs into this port's simulation directory (and stays there on success
    // -- see its own doc comment) so probe files land in the same place the GPU worker's would have.
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
    const copper::CopperFDTDRunResult cpuResult = copper::runFDTDPortOnCPU(
        simulation.csx(), portConfig, {}, cpmlAlphaMax,
        kiems::constants::pmlDepthCells);
    std::filesystem::current_path(cwd);
    if (!cpuResult.success) {
        writeError(simPath, cpuResult.errorMessage);
        return EXIT_FAILURE;
    }

    // runFDTDPortOnCPU() doesn't write probe files itself -- this worker is one of the callers that
    // still needs them on disk (job.json's own contract is a directory of probe files), so it writes
    // them explicitly from the returned in-memory result via CopperProbeResult::data().
    for (const copper::CopperProbeResult& probeResult : cpuResult.probes) {
        std::ofstream probeFile(probeDir / probeResult.name);
        if (!probeFile.is_open()) {
            writeError(simPath, "Failed to open probe file for writing: " + (probeDir / probeResult.name).string());
            return EXIT_FAILURE;
        }
        probeFile << probeResult.data();
    }
    return EXIT_SUCCESS;
}
