#include "simulation_data.hpp"

#include <fstream>

namespace kicad_ems {

std::expected<SimulationGeometry, std::string> generateGeometry(const SimulationData<SimulationStage::Configured>& data,
                                                                  const EMSConfig& config, const PathsConfig& paths) {
    // sliceBoardForSimulation() is a plain, pure function -- no Simulation/CSXCAD/openEMS object
    // needed just to slice a board (see board_slicing.hpp).
    auto sliced = sliceBoardForSimulation(data.configuration(), config, paths);
    if (!sliced) {
        return std::unexpected(sliced.error());
    }
    return SimulationGeometry{std::move(*sliced)};
}

SimulationGrid generateGrid(const SimulationData<SimulationStage::Geometry>& data, const EMSConfig& config,
                             const RunOptions& options, const PathsConfig& paths) {
    // Placing grid lines does need a real Simulation (addGrid() reads/writes its own CSXCAD grid
    // object) -- this one is thrown away once gridLines() has been read off it, exactly like
    // GeometryResult::build()'s own canonical Simulation is discarded once saveSimulationData() is
    // done with it.
    Simulation sim(data.configuration(), config, options, paths);
    sim.adoptSlicedBoard(data.geometry().slicedBoard);
    sim.addGrid();
    return SimulationGrid{sim.computedGridLines()};
}

std::expected<SimulationResults, std::string> generateResults(const SimulationData<SimulationStage::Grid>& data,
                                                                const EMSConfig& config, const RunOptions& options,
                                                                const PathsConfig& paths,
                                                                const std::vector<double>& frequencies,
                                                                const FDTDPortRunner& portRunner) {
    SimulationResults results;
    const auto& ports = data.configuration().ports();
    for (std::size_t index = 0; index < ports.size(); ++index) {
        if (!ports[index].excite()) {
            continue;
        }
        const auto excitedPortIndex = static_cast<std::int32_t>(index);

        // A fresh, independent Simulation per excited port -- same reason generateGrid()'s own is
        // thrown away rather than shared: openEMS's SetCSX()/Reset() give a freshly-constructed
        // openEMS object exclusive ownership of its ContinuousStructure (see Simulation's own _csx
        // doc comment), so each excited port needs its own, never one shared across ports. `data`
        // itself is only ever read here, never mutated, so the same SimulationGeometry/
        // SimulationGrid gets reused for every port with no encode/decode step anywhere.
        Simulation sim(data.configuration(), config, options, paths);
        sim.adoptSlicedBoard(data.geometry().slicedBoard);
        sim.adoptGridLines(data.grid().gridLines);
        if (auto result = sim.populateGeometry(); !result) {
            return std::unexpected(result.error());
        }
        sim.setExcitation();
        sim.setupPorts(excitedPortIndex);
        auto runResult = portRunner ? portRunner(sim, excitedPortIndex) : sim.run(excitedPortIndex);
        if (!runResult) {
            return std::unexpected(runResult.error());
        }

        // populateGeometry() never rebuilds the lightweight C++-side _ports bookkeeping addPorts()
        // does -- without this, getPortParameters() below reads the real port positions instead of
        // a dummy fallback (see the earlier, now-historical version of this comment in
        // SimulationResult::run() for the exact symptom this fixes).
        if (auto result = sim.addPorts(); !result) {
            return std::unexpected(result.error());
        }
        auto paramsResult = sim.getPortParameters(excitedPortIndex, frequencies);
        if (!paramsResult) {
            return std::unexpected(paramsResult.error());
        }
        auto& [reflected, incident, probeVoltage, probeCurrent, probeImpedance] = *paramsResult;
        results.byExcitedPort.emplace(
            excitedPortIndex, SimulationPortResults{std::move(reflected), std::move(incident), std::move(probeVoltage),
                                                      std::move(probeCurrent), std::move(probeImpedance)});
    }
    return results;
}

SimulationPostprocessing generatePostprocessing(const SimulationData<SimulationStage::Results>& data,
                                                 const std::vector<double>& frequencies) {
    auto postprocessor = std::make_shared<Postprocessor>(frequencies, data.configuration());
    const auto& ports = data.configuration().ports();
    for (const auto& [excitedPortIndex, portResults] : data.results().byExcitedPort) {
        for (std::size_t measuredPort = 0; measuredPort < ports.size(); ++measuredPort) {
            const auto index = static_cast<std::int32_t>(measuredPort);
            if (ports[measuredPort].absorbSignal()) {
                postprocessor->addPortData(index, excitedPortIndex, portResults.incident[measuredPort],
                                            portResults.reflected[measuredPort]);
            } else {
                postprocessor->addProbeData(index, excitedPortIndex, portResults.probeVoltage.at(index),
                                             portResults.probeCurrent.at(index));
                if (ports[measuredPort].isTraceProbe()) {
                    postprocessor->addProbeImpedance(index, excitedPortIndex, portResults.probeImpedance.at(index));
                }
            }
        }
    }
    postprocessor->calculateSparams();
    return SimulationPostprocessing{std::move(postprocessor)};
}

std::filesystem::path simulationDataFile(const PathsConfig& paths, const std::string& simulationName) {
    return paths.geometryDir / simulationName / "geometry.json";
}

std::expected<void, std::string> saveSimulationData(const SimulationData<SimulationStage::Grid>& data,
                                                      const std::filesystem::path& file) {
    nlohmann::json j;
    j["geometry"] = data.geometry();
    j["grid"] = data.grid();

    std::ofstream out(file);
    if (!out.is_open()) {
        return std::unexpected("Failed to open " + file.string() + " for writing");
    }
    out << j.dump(2);
    return {};
}

std::expected<SimulationData<SimulationStage::Grid>, std::string> loadSimulationData(SimulationConfig& configuration,
                                                                                       const std::filesystem::path& file) {
    std::ifstream in(file);
    if (!in.is_open()) {
        return std::unexpected("Geometry data file does not exist. Did you run the geometry step? (" + file.string() +
                                ")");
    }
    nlohmann::json j;
    try {
        in >> j;
    } catch (const nlohmann::json::parse_error& error) {
        return std::unexpected("Failed to parse " + file.string() + ": " + std::string(error.what()));
    }

    SimulationGeometry geometry;
    SimulationGrid grid;
    try {
        j.at("geometry").get_to(geometry);
        j.at("grid").get_to(grid);
    } catch (const nlohmann::json::exception& error) {
        return std::unexpected("Malformed " + file.string() + ": " + std::string(error.what()));
    }

    const SimulationData<SimulationStage::Configured> configured(configuration);
    const SimulationData<SimulationStage::Geometry> geometryData(configured, std::move(geometry));
    return SimulationData<SimulationStage::Grid>(geometryData, std::move(grid));
}

} // namespace kicad_ems
