// Explicit filesystem locations this tool reads/writes -- replaces every module's own
// std::filesystem::current_path()-relative path computation, and the subprocess helper paths that
// used to be resolved implicitly (kicad-cli via $PATH/a hardcoded install location,
// kicad_query_helper via "sibling of the running executable"). A GUI embedding this library runs
// on its own working directory and bundles its own copies of the helper tools, so nothing in
// libgerber2ems may assume a shared process CWD or a fixed on-disk layout relative to itself --
// every path a caller cares about is supplied here instead.
#pragma once

#include <filesystem>

namespace gerber2ems {

struct PathsConfig {
    std::filesystem::path configDir;      // directory containing simulation.json; base for the rest
    std::filesystem::path stackupFile;     // configDir / "stackup.json"
    std::filesystem::path fabDir;          // configDir / "fab" -- kicad-cli-regenerated gerbers/drill/pos
    std::filesystem::path fabBoardFile;    // configDir / "fab/board.kicad_pcb"
    std::filesystem::path fabProjectFile;  // configDir / "fab/board.kicad_pro"
    std::filesystem::path baseDir;         // configDir / "ems"
    std::filesystem::path geometryDir;     // configDir / "ems/geometry"
    std::filesystem::path simulationDir;   // configDir / "ems/simulation"
    std::filesystem::path resultsDir;      // configDir / "ems/results"

    // Explicit paths to bundleable helper tools this library shells out to -- never resolved via
    // $PATH or a location relative to this process's own binary (see importer.hpp/libkicad_query.hpp).
    std::filesystem::path kicadCliPath;
    std::filesystem::path kicadQueryHelperPath;

    /// Builds every derived field from `configDir` and the two helper-tool paths. The CLI's own
    /// convenience default: a GUI app is free to populate a PathsConfig by hand instead (e.g. to
    /// point kicadQueryHelperPath at a bundled copy rather than a sibling binary).
    static PathsConfig forConfigDir(std::filesystem::path configDir, std::filesystem::path kicadCliPath,
                                     std::filesystem::path kicadQueryHelperPath);
};

} // namespace gerber2ems
