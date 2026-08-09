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
    auto ownedConfig = std::make_shared<EMSConfig>(std::move(config));

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
        if (options.exportField.has_value()) {
            sim.addDumpBoxes();
        }
        sim.setBoundaryConditions(false);
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
    auto ownedConfig = std::make_shared<EMSConfig>(std::move(config));

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
