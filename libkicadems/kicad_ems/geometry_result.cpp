#include "geometry_result.hpp"

#include <filesystem>

#include "logging.hpp"
#include "simulation.hpp"

namespace kicad_ems {

using namespace Cu;

namespace {

std::expected<void, std::string> createDir(const std::filesystem::path& directoryPath) {
    std::error_code ec;
    std::filesystem::create_directories(directoryPath, ec);
    if (ec) {
        return std::unexpected("Failed to create directory " + directoryPath.string() + ": " + ec.message());
    }
    return {};
}

} // namespace

GeometryResult::GeometryResult(std::shared_ptr<EMSConfig> config, PathsConfig paths,
                                std::shared_ptr<std::map<std::string, SimulationData<SimulationStage::Grid>>>
                                    simulationData)
    : _config(std::move(config)), _paths(std::move(paths)), _simulationData(std::move(simulationData)) {}

std::filesystem::path GeometryResult::geometryFile(const std::string& simulationName) const {
    return simulationDataFile(_paths, simulationName);
}

const SimulationData<SimulationStage::Grid>* GeometryResult::simulationData(const std::string& simulationName) const {
    const auto it = _simulationData->find(simulationName);
    return it == _simulationData->end() ? nullptr : &it->second;
}

std::expected<GeometryResult, std::string> GeometryResult::build(EMSConfig config, const RunOptions& options,
                                                                   const PathsConfig& paths,
                                                                   const GeometryProgressCallback& onProgress) {
    // config arrives in file units (see EMSConfig::scaledToSimulationUnits()'s doc comment) --
    // everything from here on (board slicing, grid generation, port placement) needs simulation
    // units, so this is the one point that conversion happens.
    auto ownedConfig = std::make_shared<EMSConfig>(config.scaledToSimulationUnits());
    auto simulationDataBySimName = std::make_shared<std::map<std::string, SimulationData<SimulationStage::Grid>>>();

    const std::size_t simCount = ownedConfig->simulations().size();
    std::size_t simIndex = 0;
    for (auto& simConfig : ownedConfig->simulations()) {
        logInfo("### Building geometry for simulation \"" + simConfig.name() + "\" ###");
        if (auto dirResult = createDir(paths.geometryDir / simConfig.name()); !dirResult) {
            return std::unexpected(dirResult.error());
        }

        auto report = [&](GeometryPhase phase, std::uint32_t currentStep) {
            if (onProgress) {
                onProgress(GeometryProgress{simConfig.name(), simIndex, simCount, phase, currentStep, 1});
            }
        };

        // The typed pipeline (see simulation_data.hpp) -- Configured -> Geometry (sliced board) ->
        // Grid (+ placed grid lines). Neither stage needs a fully-populated ContinuousStructure
        // (materials/gerbers/substrates/vias/ports) -- that only ever gets built later, once per
        // excited port, by generateResults() -- so the geometry step itself is just these two
        // stages plus writing them to disk (see saveSimulationData()) for a spawned FDTD worker or
        // a later `-s`-only invocation to pick up; SimulationResult::run() reuses the same
        // in-memory SimulationData<Grid> cached below directly, with no serialization at all.
        SimulationData<SimulationStage::Configured> configured(simConfig);

        report(GeometryPhase::SlicingBoard, 0);
        auto geometry = generateGeometry(configured, *ownedConfig, paths);
        if (!geometry) {
            return std::unexpected(geometry.error());
        }
        report(GeometryPhase::SlicingBoard, 1);
        SimulationData<SimulationStage::Geometry> geometryData(configured, std::move(*geometry));

        report(GeometryPhase::PlacingGrid, 0);
        SimulationData<SimulationStage::Grid> gridData(geometryData,
                                                         generateGrid(geometryData, *ownedConfig, options, paths));
        report(GeometryPhase::PlacingGrid, 1);

        if (auto result = saveSimulationData(gridData, simulationDataFile(paths, simConfig.name())); !result) {
            return std::unexpected(result.error());
        }

        simulationDataBySimName->emplace(simConfig.name(), std::move(gridData));
        ++simIndex;
    }

    return GeometryResult(std::move(ownedConfig), paths, std::move(simulationDataBySimName));
}

std::expected<GeometryResult, std::string> GeometryResult::load(EMSConfig config, const PathsConfig& paths) {
    // Scaled for the same reason as build() -- so a GeometryResult behaves identically regardless
    // of whether it was just built or reloaded from a previous run.
    auto ownedConfig = std::make_shared<EMSConfig>(config.scaledToSimulationUnits());
    auto simulationDataBySimName = std::make_shared<std::map<std::string, SimulationData<SimulationStage::Grid>>>();

    for (auto& simConfig : ownedConfig->simulations()) {
        auto loaded = loadSimulationData(simConfig, simulationDataFile(paths, simConfig.name()));
        if (!loaded) {
            return std::unexpected(loaded.error());
        }
        simulationDataBySimName->emplace(simConfig.name(), std::move(*loaded));
    }

    return GeometryResult(std::move(ownedConfig), paths, std::move(simulationDataBySimName));
}

} // namespace kicad_ems
