// Gerber/drill/stackup importing. Ported from gerber2ems/importer.py.
#pragma once

#include <cstdint>
#include <expected>
#include <filesystem>
#include <string>
#include <vector>

#include "config.hpp"
#include "gerber_io.hpp"
#include "paths_config.hpp"

namespace gerber2ems {

/// A single mesh triangle, in simulation units, already re-origined so the board's Edge_Cuts
/// bounding-box minimum corner maps to (0,0) -- the same frame gerber_composite.hpp's
/// edgeCutsBoundingBox() and vias/ports already use natively. `a`/`b`/`c` are plain vertices in
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

/// Exports gerbers, an Excellon drill file, and a position file from a KiCad PCB into
/// `paths.fabDir` (creating it if needed), by shelling out to `paths.kicadCliPath` -- KiCad's own
/// officially-maintained headless export tool. There is no practical way to do this without
/// invoking KiCad's own tooling: its IPC API only gained export support in KiCad 11, and its
/// internal plotting classes (GERBER_PLOTTER etc.) are undocumented internals that pull in KiCad's
/// full wxWidgets/Cairo/Boost dependency stack with no stable ABI -- both considered and rejected
/// for the same reasons linking libgerbv directly was rejected earlier in this project.
std::expected<void, std::string> exportKicadPcb(const PathsConfig& paths, const std::filesystem::path& kicadPcbPath);

/// Parses `paths.fabDir`'s `*-PTH.drl` (Excellon drill file) for plated through-hole via
/// positions/diameters.
std::expected<std::vector<ViaHole>, std::string> getVias(const PathsConfig& paths);

/// Imports stackup information (copper/dielectric layer thicknesses and dielectric constants) from
/// the live board, via libkicad_query, into `config`. Requires fab/board.kicad_pcb (persisted by
/// exportKicadPcb()).
std::expected<void, std::string> importStackup(const PathsConfig& paths, EMSConfig& config);

} // namespace gerber2ems
