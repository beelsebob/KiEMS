#include "geometry_result.hpp"

#include <filesystem>

#include "logging.hpp"
#include "simulation.hpp"

namespace gerber2ems {

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

GeometryResult::GeometryResult(std::shared_ptr<EMSConfig> config, PathsConfig paths)
    : _config(std::move(config)), _paths(std::move(paths)) {}

std::filesystem::path GeometryResult::geometryFile(const std::string& simulationName) const {
    return _paths.geometryDir / simulationName / "geometry.xml";
}

std::expected<GeometryResult, std::string> GeometryResult::build(EMSConfig config, const RunOptions& options,
                                                                   const PathsConfig& paths) {
    // config arrives in file units (see EMSConfig::scaledToSimulationUnits()'s doc comment) --
    // everything from here on (board slicing, grid generation, port placement) needs simulation
    // units, so this is the one point that conversion happens.
    auto ownedConfig = std::make_shared<EMSConfig>(config.scaledToSimulationUnits());

    for (auto& simConfig : ownedConfig->simulations()) {
        logInfo("### Building geometry for simulation \"" + simConfig.name() + "\" ###");
        if (auto dirResult = createDir(paths.geometryDir / simConfig.name()); !dirResult) {
            return std::unexpected(dirResult.error());
        }

        Simulation sim(simConfig, *ownedConfig, options, paths);
        if (auto result = sim.sliceBoard(); !result) {
            return std::unexpected(result.error());
        }
        sim.createMaterials();
        sim.addGerbers();
        sim.addGrid();
        sim.addSubstrates();
        sim.addNPTHHoles();
        if (options.exportField.has_value()) {
            sim.addDumpBoxes();
        }
        // PML, not MUR (setBoundaryConditions's default) -- MUR is a much weaker absorber for
        // oblique-incidence and near-field/evanescent content, which a PCB floating in open space
        // radiates plenty of close to the domain boundary. Passing false here previously left every
        // boundary on MUR, which showed up as the total domain energy plateauing well above the
        // -60dB end criteria instead of decaying -- reflections off the boundary keep feeding energy
        // back into the domain indefinitely rather than letting it actually leave.
        sim.setBoundaryConditions(true);
        if (auto result = sim.addVias(); !result) {
            return std::unexpected(result.error());
        }
        if (auto result = sim.addPorts(); !result) {
            return std::unexpected(result.error());
        }
        sim.saveGeometry();
    }

    return GeometryResult(std::move(ownedConfig), paths);
}

std::expected<GeometryResult, std::string> GeometryResult::load(EMSConfig config, const PathsConfig& paths) {
    // Scaled for the same reason as build() -- so a GeometryResult behaves identically regardless
    // of whether it was just built or reloaded from a previous run.
    auto ownedConfig = std::make_shared<EMSConfig>(config.scaledToSimulationUnits());

    GeometryResult result(ownedConfig, paths);
    for (const auto& simConfig : ownedConfig->simulations()) {
        const std::filesystem::path geometryFile = result.geometryFile(simConfig.name());
        if (!std::filesystem::exists(geometryFile)) {
            return std::unexpected("Geometry file does not exist. Did you run the geometry step? (" +
                                    geometryFile.string() + ")");
        }
    }
    return result;
}

} // namespace gerber2ems
