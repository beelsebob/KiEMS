// Constants used throughout the app. Ported from gerber2ems/constants.py.
#pragma once

#include <cstdint>
#include <filesystem>
#include <string_view>

namespace gerber2ems::constants {

inline constexpr std::int32_t unitMultiplier = 10;
inline constexpr double baseUnit = 1e-6; // Length units used in the whole script are microns

inline const std::filesystem::path baseDir = "ems"; // Name of the directory that outputs will be stored in
inline const std::filesystem::path simulationDir = baseDir / "simulation";
inline const std::filesystem::path geometryDir = baseDir / "geometry";
inline const std::filesystem::path resultsDir = baseDir / "results";

inline const std::filesystem::path defaultConfigPath = "./simulation.json";

// Via geometry is approximated using n-sided right prism
inline constexpr std::int32_t viaPolygon = 12;

inline constexpr std::string_view stackupFormatVersion = "1.0";
inline constexpr std::string_view configFormatVersion = "1.2";

} // namespace gerber2ems::constants
