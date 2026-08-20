// A dedicated, single-purpose process that runs exactly one port's FDTD pass on Copper's GPU
// engine and exits -- the GPU sibling of gerber2ems_fdtd_worker (see that target's own main.cpp,
// which this one mirrors closely), posix_spawn'd by Simulation::run() when
// RunOptions::backend == FDTDBackend::CopperGPU. Same job.json contract, same worker_error.txt
// failure convention, same exit-code convention -- Simulation::run() itself can't tell which
// backend actually produced a given simulation directory's output.
//
// IMPORTANT: this file includes gerber2ems/simulation.hpp (and therefore the *installed*
// <openEMS/openems.h>/<CSXCAD/ContinuousStructure.h> header forms) -- it must never also include
// any Copper/Internal/ header directly, which all use the flat/source-checkout forms instead (see
// Copper/Internal/CopperOpenEMSAccess.hpp's file comment). The only Copper entry point this file
// touches is CopperFDTDRunner.h, deliberately declared with only forward-declared
// openEMS/ContinuousStructure types for exactly this reason.

#include <cstdlib>
#include <fstream>
#include <iostream>
#include <sstream>
#include <string>

#include <nlohmann/json.hpp>

#include "gerber2ems/config.hpp"
#include "gerber2ems/constants.hpp"
#include "gerber2ems/importer.hpp"
#include "gerber2ems/logging.hpp"
#include "gerber2ems/paths_config.hpp"
#include "gerber2ems/port_resolution.hpp"
#include "gerber2ems/simulation.hpp"
#include "gerber2ems/simulation_data.hpp"

#include "CopperFDTDRunner.h"

using namespace gerber2ems;

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

    // Deserializes the exact same SimulationData<Grid> (sliced board + placed grid lines -- see
    // simulation_data.hpp) GeometryResult::build()/load() would have in memory in-process -- this
    // worker is a genuinely separate process, so a file is the only way to get it. Rebuilding this
    // Simulation's ContinuousStructure from that (populateGeometry(), including its own
    // setBoundaryConditions(true)) happens on *this* freshly-constructed Simulation's own `_fdtd`,
    // not a reload of some other object's state -- unlike the old geometry.xml round trip (which
    // only ever restored `_csx`, leaving `_fdtd`'s separate boundary-condition state at openEMS's
    // own PEC default -- see gerber2ems_fdtd_worker/main.cpp's own identical fix, which is what
    // first caught this: CopperPML's own shell discovery came back empty for a real board despite
    // the geometry step's own PML log line), there's no second, explicit setBoundaryConditions()
    // call needed here.
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

    // setupFDTDOperator() chdirs into this port's simulation directory (and stays there on success
    // -- see its own doc comment) so the Copper run's probe files land in the same place the real
    // CPU worker's would have.
    const std::filesystem::path cwd = std::filesystem::current_path();
    if (auto result = simulation.setupFDTDOperator(excitedPort); !result) {
        writeError(simPath, result.error());
        return EXIT_FAILURE;
    }

    const std::filesystem::path probeDir = std::filesystem::current_path();
    // pmlDepthCells passed explicitly (matching gerber2ems::constants::pmlDepthCells, the same
    // value Simulation::setBoundaryConditions() used -- or, for a CPML run, deliberately did *not*
    // pass to openEMS's own Set_BC_PML() -- see that function's own comment) rather than relying on
    // runFDTDPortOnGPU()'s own default staying in sync with it.
    const copper::CopperFDTDRunResult gpuResult = copper::runFDTDPortOnGPU(
        simulation.fdtdEngine(), simulation.csx(), {}, copper::CopperBoundaryKind::CPML, -1.0,
        gerber2ems::constants::pmlDepthCells);
    std::filesystem::current_path(cwd);
    if (!gpuResult.success) {
        writeError(simPath, gpuResult.errorMessage);
        return EXIT_FAILURE;
    }

    // runFDTDPortOnGPU() no longer writes probe files itself -- this worker is one of the callers
    // that still needs them on disk (job.json's own contract is a directory of probe files, matching
    // what gerber2ems_fdtd_worker's real CPU RunFDTD() would have produced), so it writes them
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
