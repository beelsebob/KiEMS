#include "paths_config.hpp"

#include "constants.hpp"

namespace gerber2ems {

PathsConfig PathsConfig::forConfigDir(std::filesystem::path configDir, std::filesystem::path kicadCliPath,
                                       std::filesystem::path kicadQueryHelperPath) {
    PathsConfig paths;
    paths.stackupFile = configDir / "stackup.json";
    paths.fabDir = configDir / "fab";
    paths.fabBoardFile = configDir / constants::fabBoardFile;
    paths.fabProjectFile = configDir / constants::fabProjectFile;
    paths.baseDir = configDir / constants::baseDir;
    paths.geometryDir = configDir / constants::geometryDir;
    paths.simulationDir = configDir / constants::simulationDir;
    paths.resultsDir = configDir / constants::resultsDir;
    paths.kicadCliPath = std::move(kicadCliPath);
    paths.kicadQueryHelperPath = std::move(kicadQueryHelperPath);
    paths.configDir = std::move(configDir);
    return paths;
}

} // namespace gerber2ems
