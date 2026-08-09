// Constants used throughout the app. Ported from gerber2ems/constants.py.
#pragma once

#include <cstdint>
#include <filesystem>
#include <string>
#include <string_view>

namespace gerber2ems::constants {

inline constexpr std::int32_t unitMultiplier = 10;
inline constexpr double baseUnit = 1e-6; // Length units used in the whole script are microns

inline const std::filesystem::path baseDir = "ems"; // Name of the directory that outputs will be stored in
inline const std::filesystem::path simulationDir = baseDir / "simulation";
inline const std::filesystem::path geometryDir = baseDir / "geometry";
inline const std::filesystem::path resultsDir = baseDir / "results";

// Every simulation now builds/runs/reports independently (see the "board slicing + net-driven
// ports and excitations" plan) -- these namespace the three directories above by
// SimulationConfig::name() so multiple simulations' outputs never collide.
inline std::filesystem::path simGeometryDir(const std::string& simName) { return geometryDir / simName; }
inline std::filesystem::path simSimulationDir(const std::string& simName) { return simulationDir / simName; }
inline std::filesystem::path simResultsDir(const std::string& simName) { return resultsDir / simName; }

inline const std::filesystem::path defaultConfigPath = "./simulation.json";

// Persistent copies of the source board/project, kept alongside the kicad-cli-exported
// gerbers/drill/pos files so port_resolution.cpp (libkicad-based net/pad queries) always has a
// board to query, even when -g/-s/-p are invoked in a separate process from the original -i export.
// Not built from a separate "fab dir" constant: importer.cpp already has several same-named local
// `fabDir` variables (via its own `using namespace constants`), which would shadow one here.
inline const std::filesystem::path fabBoardFile = "fab/board.kicad_pcb";
inline const std::filesystem::path fabProjectFile = "fab/board.kicad_pro";

// Via geometry is approximated using n-sided right prism
inline constexpr std::int32_t viaPolygon = 12;

inline constexpr std::string_view stackupFormatVersion = "1.0";
inline constexpr std::string_view configFormatVersion = "2.0";

} // namespace gerber2ems::constants
