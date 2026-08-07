// Gerber/drill/stackup importing. Ported from gerber2ems/importer.py.
#pragma once

#include <cstdint>
#include <filesystem>
#include <utility>
#include <vector>

#include "gerber_io.hpp"

namespace gerber2ems {

/// A single mesh triangle. NOTE the coordinate convention deliberately matches the Python
/// source's mesh points exactly: a() holds the image ROW-derived coordinate and b() holds the
/// COLUMN-derived coordinate (both already scaled to simulation units) -- simulation.cpp's
/// add_contours (ported from Simulation.add_contours) relies on this exact axis order when it
/// flips row into board Y via `pcbHeight - a()` and maps b() straight to board X.
struct Triangle {
    Position a;
    Position b;
    Position c;
};

struct ViaHole {
    double x = 0;
    double y = 0;
    double diameter = 0;
};

/// Finds the edge-cuts gerber and all copper gerbers in `fab/`, rendering each copper layer to a
/// cropped PNG in `ems/geometry` via the external `gerbv` tool.
void processGbrsToPngs();

/// Returns board (width, height) in simulation units, read from a PNG in `ems/geometry`.
std::pair<double, double> getDimensions(const std::string& inputFilename);

/// Triangulates the copper regions of a PNG in `ems/geometry` (thresholded to black & white),
/// returning the resulting triangles in image-pixel-derived simulation units. Holes (e.g.
/// clearances around unconnected vias in a copper pour) are handled correctly.
std::vector<Triangle> getTriangles(const std::string& inputFilename);

/// Parses `fab/*-PTH.drl` (Excellon drill file) for plated through-hole via positions/diameters.
std::vector<ViaHole> getVias();

/// Imports stackup information from `fab/stackup.json` into the shared Config.
void importStackup();

/// Imports port positions/directions from `fab/*pos.csv` into the shared Config's ports.
void importPortPositions();

} // namespace gerber2ems
