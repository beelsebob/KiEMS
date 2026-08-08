// Gerber/drill/stackup importing. Ported from gerber2ems/importer.py.
#pragma once

#include <cstdint>
#include <filesystem>
#include <utility>
#include <vector>

#include "gerber_io.hpp"

namespace gerber2ems {

/// A single mesh triangle, in simulation units, already re-origined so the board's Edge_Cuts
/// bounding-box minimum corner maps to (0,0) -- the same [0, pcbWidth] x [0, pcbHeight] frame
/// getDimensions() and vias/ports already use natively. `a`/`b`/`c` are plain vertices in
/// (x, y) order (unlike the old raster pipeline's Triangle, which stored a row/column-swapped
/// convention that Simulation::addContours had to undo).
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

/// Exports gerbers, an Excellon drill file, and a position file from a KiCad PCB into `./fab/`
/// (creating it if needed), by shelling out to `kicad-cli` -- KiCad's own officially-maintained
/// headless export tool. There is no practical way to do this without invoking KiCad's own
/// tooling: its IPC API only gained export support in KiCad 11, and its internal plotting classes
/// (GERBER_PLOTTER etc.) are undocumented internals that pull in KiCad's full wxWidgets/Cairo/Boost
/// dependency stack with no stable ABI -- both considered and rejected for the same reasons
/// linking libgerbv directly was rejected earlier in this project. Exits the process on failure.
void exportKicadPcb(const std::filesystem::path& kicadPcbPath);

/// Returns board (width, height) in simulation units, computed directly from the Edge_Cuts
/// gerber's own vector geometry (bounding box).
std::pair<double, double> getDimensions();

/// Builds the true copper region for the metal layer whose stackup file-stem name (e.g. "F_Cu")
/// matches `layerFileName`, by compositing every paint operation on its gerber file via Clipper2
/// (see gerber_composite.hpp), and triangulates it. Holes (e.g. clearances around unconnected vias
/// in a copper pour) are handled correctly, at arbitrary nesting depth.
std::vector<Triangle> getTriangles(const std::string& layerFileName);

/// Parses `fab/*-PTH.drl` (Excellon drill file) for plated through-hole via positions/diameters.
std::vector<ViaHole> getVias();

/// Imports stackup information from `fab/stackup.json` into the shared Config.
void importStackup();

/// Imports port positions/directions from `fab/*pos.csv` into the shared Config's ports.
void importPortPositions();

} // namespace gerber2ems
