// Explicit filesystem locations this tool reads/writes -- replaces every module's own
// std::filesystem::current_path()-relative path computation, and external-tool paths that used to
// be resolved implicitly (for example kicad-cli via $PATH/a hardcoded install location). A GUI
// embedding this library runs on its own working directory and bundles its own helper tools, so nothing in
// libkiems may assume a shared process CWD or a fixed on-disk layout relative to itself --
// every path a caller cares about is supplied here instead.
#pragma once

#include <filesystem>

#include "../../libkicad/libkicad.hpp"

namespace kiems {

struct PathsConfig {
    std::filesystem::path configFile;      // the resolved simulation.json path itself
    std::filesystem::path configDir;       // configFile's parent directory; base for the rest
    std::filesystem::path fabDir;          // configDir / "fab" -- persistent KiCad board/project copies
    std::filesystem::path fabBoardFile;    // configDir / "fab/board.kicad_pcb"
    std::filesystem::path fabProjectFile;  // configDir / "fab/board.kicad_pro"
    std::filesystem::path baseDir;         // configDir / "ems"
    std::filesystem::path geometryDir;     // configDir / "ems/geometry"
    std::filesystem::path simulationDir;   // configDir / "ems/simulation"
    std::filesystem::path resultsDir;      // configDir / "ems/results"

    // Explicit paths to bundleable helper tools this library shells out to.
    std::filesystem::path kicadCliPath;    // Legacy compatibility field; geometry no longer invokes it.

    libkicad::BoardPaths kicadBoardPaths() const {
        return {fabProjectFile.string(), fabBoardFile.string()};
    }
    std::filesystem::path fdtdWorkerPath;
    // Same kind of path as fdtdWorkerPath -- posix_spawn'd instead of it when
    // RunOptions::backend == FDTDBackend::CopperGPU (see Simulation::run()). Defaulted empty so
    // every existing forConfigFile() call site keeps compiling unchanged; a caller that never
    // selects the Copper backend never needs to set this.
    std::filesystem::path copperFdtdWorkerPath;

    /// Builds every derived field from `configFile` and the external-tool paths.
    static PathsConfig forConfigFile(std::filesystem::path configFile, std::filesystem::path kicadCliPath,
                                      std::filesystem::path fdtdWorkerPath,
                                      std::filesystem::path copperFdtdWorkerPath = {});
};

} // namespace kiems
