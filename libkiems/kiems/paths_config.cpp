#include "paths_config.hpp"

#include "constants.hpp"

namespace kiems {

PathsConfig PathsConfig::forConfigFile(std::filesystem::path configFile, std::filesystem::path kicadCliPath,
                                        std::filesystem::path kicadQueryHelperPath,
                                        std::filesystem::path fdtdWorkerPath,
                                        std::filesystem::path copperFdtdWorkerPath) {
    PathsConfig paths;
    const std::filesystem::path configDir = configFile.parent_path();
    paths.fabDir = configDir / "fab";
    paths.fabBoardFile = configDir / constants::fabBoardFile;
    paths.fabProjectFile = configDir / constants::fabProjectFile;
    paths.baseDir = configDir / constants::baseDir;
    paths.geometryDir = configDir / constants::geometryDir;
    paths.simulationDir = configDir / constants::simulationDir;
    paths.resultsDir = configDir / constants::resultsDir;
    paths.kicadCliPath = std::move(kicadCliPath);
    paths.kicadQueryHelperPath = std::move(kicadQueryHelperPath);
    paths.fdtdWorkerPath = std::move(fdtdWorkerPath);
    paths.copperFdtdWorkerPath = std::move(copperFdtdWorkerPath);
    paths.configDir = configDir;
    paths.configFile = std::move(configFile);
    return paths;
}

} // namespace kiems
