// Small convenience wrapper around CSXCAD::CSRectGrid's raw C++ API.
//
// CSXCAD's Python bindings expose a friendlier `grid.AddLine("x", [...])` / `grid.GetLines("x")`
// style API, but that convenience layer is itself pure Python (CSXCAD/python/CSXCAD/CSRectGrid.pyx)
// sitting on top of the compiled library's lower-level `AddDiscLine(int direct, double val)` /
// `GetLines(int direct, double* array, unsigned int& qty, bool sorted)` methods. This header
// reimplements just that convenience layer against the native C++ class, since the rest of the
// port (grid_gen, simulation) leans on it heavily.
#pragma once

#include <cstdint>
#include <stdexcept>
#include <string>
#include <vector>

#include <CSXCAD/CSRectGrid.h>

namespace gerber2ems {

/// Translates "x"/"y"/"z" into 0/1/2, matching CSXCAD's CheckNyDir for Cartesian coordinates.
inline std::int32_t axisIndex(const std::string& axis) {
    if (axis == "x") {
        return 0;
    }
    if (axis == "y") {
        return 1;
    }
    if (axis == "z") {
        return 2;
    }
    throw std::invalid_argument("Invalid grid axis: " + axis);
}

/// Adds a single line without clearing previously defined lines in that direction.
inline void addGridLine(CSRectGrid& grid, const std::string& axis, double value) {
    grid.AddDiscLine(axisIndex(axis), value);
}

/// Adds a set of lines without clearing previously defined lines in that direction.
inline void addGridLines(CSRectGrid& grid, const std::string& axis, const std::vector<double>& values) {
    const std::int32_t direct = axisIndex(axis);
    for (const double value : values) {
        grid.AddDiscLine(direct, value);
    }
}

inline void clearGridLines(CSRectGrid& grid, const std::string& axis) { grid.ClearLines(axisIndex(axis)); }

inline std::size_t gridLineCount(CSRectGrid& grid, const std::string& axis) {
    return grid.GetQtyLines(axisIndex(axis));
}

/// Returns all lines in the given direction (0/1/2 == x/y/z). CSRectGrid::GetLines hands back a
/// heap array that the caller owns (per its own doc comment); this copies it into a vector and
/// frees it.
inline std::vector<double> gridLines(CSRectGrid& grid, std::int32_t direct, bool sorted = true) {
    unsigned int qty = 0;
    double* array = grid.GetLines(direct, nullptr, qty, sorted);
    std::vector<double> result(array, array + qty);
    delete[] array;
    return result;
}

inline std::vector<double> gridLines(CSRectGrid& grid, const std::string& axis, bool sorted = true) {
    return gridLines(grid, axisIndex(axis), sorted);
}

} // namespace gerber2ems
