// Explicit filesystem locations this tool reads/writes -- replaces every module's own
// std::filesystem::current_path()-relative path computation, and the subprocess helper paths that
// used to be resolved implicitly (kicad-cli via $PATH/a hardcoded install location,
// kicad_query_helper via "sibling of the running executable"). A GUI embedding this library runs
// on its own working directory and bundles its own copies of the helper tools, so nothing in
// libkicadems may assume a shared process CWD or a fixed on-disk layout relative to itself --
// every path a caller cares about is supplied here instead.
#pragma once

#include <filesystem>

namespace kicad_ems {

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

    // Explicit paths to bundleable helper tools this library shells out to -- never resolved via
    // $PATH or a location relative to this process's own binary (see importer.hpp/libkicad_query.hpp
    // and simulation.hpp's Simulation::run(), which posix_spawns fdtdWorkerPath).
    std::filesystem::path kicadCliPath;    // Legacy compatibility field; geometry no longer invokes it.
    std::filesystem::path kicadQueryHelperPath;
    std::filesystem::path fdtdWorkerPath;
    // Same kind of path as fdtdWorkerPath -- posix_spawn'd instead of it when
    // RunOptions::backend == FDTDBackend::CopperGPU (see Simulation::run()). Defaulted empty so
    // every existing forConfigFile() call site keeps compiling unchanged; a caller that never
    // selects the Copper backend never needs to set this.
    std::filesystem::path copperFdtdWorkerPath;

    /// Builds every derived field from `configFile` and the helper-tool paths. The CLI's own
    /// convenience default: a GUI app is free to populate a PathsConfig by hand instead (e.g. to
    /// point kicadQueryHelperPath/fdtdWorkerPath at bundled copies rather than sibling binaries).
    static PathsConfig forConfigFile(std::filesystem::path configFile, std::filesystem::path kicadCliPath,
                                      std::filesystem::path kicadQueryHelperPath,
                                      std::filesystem::path fdtdWorkerPath,
                                      std::filesystem::path copperFdtdWorkerPath = {});
};

} // namespace kicad_ems
