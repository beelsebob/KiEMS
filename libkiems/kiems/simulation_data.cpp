#include <set>
#include "simulation_data.hpp"

#include <fstream>

#include "logging.hpp"

namespace kiems {

using namespace Cu;

std::expected<SimulationGeometry, std::string> generateGeometry(const SimulationData<SimulationStage::Configured>& data,
                                                                  const EMSConfig& config, const libkicad::Board& board,
                                                                  const GeometryProcessingProgressCallback& onProgress) {
    // sliceBoardForSimulation() is a plain, pure function -- no Simulation/CSXCAD/openEMS object
    // needed just to slice a board (see board_slicing.hpp). The board load and net-name resolution
    // it needs (classifyCopperForSimulation()) are the only IO in this pipeline stage.
    logInfo("Slicing board for " + data.configuration().name());
    auto geometry = board.boardGeometry();
    if (!geometry) {
        return std::unexpected(std::move(geometry).error());
    }
    auto copper = classifyCopperForSimulation(data.configuration(), *geometry, board);
    if (!copper) {
        return std::unexpected(std::move(copper).error());
    }

    auto origin = boardBoundsInSimulationUnits(*geometry);
    if (!origin) {
        return std::unexpected(std::move(origin).error());
    }
    // Best-effort: if the KiCad hole query fails, slicing/stitching just proceed without this data
    // rather than failing the whole slice over it (the same as if the board genuinely had none).
    std::vector<ViaHole> existingVias;
    if (auto vias = getVias(board, origin->xMin, origin->yMin); vias) {
        existingVias = std::move(*vias);
    }
    std::vector<NPTHHole> npthHoles;
    if (auto holes = getNPTHHoles(board, origin->xMin, origin->yMin); holes) {
        npthHoles = std::move(*holes);
    }

    const SlicingConfig slicing = SlicingConfig::from(data.configuration(), config);
    auto sliced = sliceBoardForSimulation(slicing, *geometry, copper->involved,
                                           copper->geometryOnly, copper->ground, copper->hullContributions,
                                           existingVias, npthHoles,
                                           onProgress);
    if (!sliced) {
        return std::unexpected(sliced.error());
    }
    restrictLumpedComponentsToCutout(data.configuration(), *sliced);
    if (onProgress) {
        onProgress({GeometryProcessingPhase::Finishing, 0, 1});
    }
    return SimulationGeometry{std::move(*sliced)};
}

SimulationGrid generateGrid(const SimulationData<SimulationStage::Geometry>& data, const EMSConfig& config,
                             const RunOptions& options, const PathsConfig& paths,
                             const libkicad::Board& board) {
    // Placing grid lines does need a real Simulation (addGrid() reads/writes its own CSXCAD grid
    // object) -- this one is thrown away once gridLines() has been read off it, exactly like
    // GeometryResult::build()'s own canonical Simulation is discarded once saveSimulationData() is
    // done with it.
    Simulation sim(data.configuration(), config, options, paths, board);
    sim.adoptSlicedBoard(data.geometry().slicedBoard);
    sim.addGrid();
    return SimulationGrid{sim.computedGridLines()};
}

std::expected<SimulationResults, std::string> generateResults(const SimulationData<SimulationStage::Grid>& data,
                                                                const EMSConfig& config, const RunOptions& options,
                                                                const PathsConfig& paths, const libkicad::Board& board,
                                                                const std::vector<double>& frequencies,
                                                                const FDTDPortRunner& portRunner) {
    SimulationResults results;
    const auto& ports = data.configuration().ports();
    // A port driven only by adversarial (non-main) excitations is never used past the primary runs'
    // length (see excitationRecordEnd()), so primary ports run first and the rest are capped at the
    // longest primary run. A port with no excitation at all counts as primary (uncapped).
    std::set<std::int32_t> primaryPorts;
    std::set<std::int32_t> adversarialPorts;
    for (const auto& excitation : data.configuration().excitations()) {
        if (excitation.drivenPortIndex().has_value()) {
            (excitation.isMain() ? primaryPorts : adversarialPorts).insert(*excitation.drivenPortIndex());
        }
    }
    std::vector<std::int32_t> runOrder;
    for (const bool adversarialPass : {false, true}) {
        for (std::size_t index = 0; index < ports.size(); ++index) {
            const auto portIndex = static_cast<std::int32_t>(index);
            const bool adversarial = adversarialPorts.contains(portIndex) && !primaryPorts.contains(portIndex);
            if (ports[index].excite() && adversarial == adversarialPass) {
                runOrder.push_back(portIndex);
            }
        }
    }
    std::uint32_t primaryTimesteps = 0;
    bool primaryTimestepsKnown = true;
    for (const std::int32_t excitedPortIndex : runOrder) {
        const bool adversarial =
            adversarialPorts.contains(excitedPortIndex) && !primaryPorts.contains(excitedPortIndex);

        // A fresh, independent Simulation per excited port so each run owns its mutable
        // ContinuousStructure and configured ports, never sharing them across runs. `data`
        // itself is only ever read here, never mutated, so the same SimulationGeometry/
        // SimulationGrid gets reused for every port with no encode/decode step anywhere.
        Simulation sim(data.configuration(), config, options, paths, board);
        sim.adoptSlicedBoard(data.geometry().slicedBoard);
        sim.adoptGridLines(data.grid().gridLines);
        if (auto result = sim.populateGeometry(); !result) {
            return std::unexpected(result.error());
        }
        sim.setupPorts(excitedPortIndex);
        if (adversarial && primaryTimestepsKnown && primaryTimesteps > 0) {
            sim.setMaxTimestepsCap(primaryTimesteps);
        }
        auto runResult = portRunner ? portRunner(sim, excitedPortIndex)
                                    : sim.run(excitedPortIndex).transform([] { return std::uint32_t{0}; });
        if (!runResult) {
            return std::unexpected(runResult.error());
        }
        if (!adversarial) {
            // An unknown primary length (0) disables the cap rather than guessing one.
            primaryTimestepsKnown = primaryTimestepsKnown && *runResult > 0;
            primaryTimesteps = std::max(primaryTimesteps, *runResult);
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

    restrictLumpedComponentsToCutout(configuration, geometry.slicedBoard);

    const SimulationData<SimulationStage::Configured> configured(configuration);
    const SimulationData<SimulationStage::Geometry> geometryData(configured, std::move(geometry));
    return SimulationData<SimulationStage::Grid>(geometryData, std::move(grid));
}

} // namespace kiems
