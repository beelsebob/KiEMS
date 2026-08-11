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
/// edgeCutsBoundingBox() and ports already use natively. `a`/`b`/`c` are plain vertices in
/// (x, y) order (unlike the old raster pipeline's Triangle, which stored a row/column-swapped
/// convention that Simulation::addContours had to undo).
struct Triangle {
    Position a;
    Position b;
    Position c;
};

/// Already re-origined the same way (see getVias()) -- safe to use directly alongside a
/// SlicedBoard's outline/layerTriangles, both in the same [0, pcbWidth] x [0, pcbHeight] frame. A
/// plated through-hole is a capsule/stadium shape between (x, y) and (x2, y2) with `diameter` as
/// its width -- Excellon's G85 "canned slot" cycle drills exactly this shape for an elongated
/// through-hole (e.g. a connector's oblong SHIELD pad), the same convention NPTHHole uses for a
/// non-plated one; a plain round via is the degenerate case where x2==x, y2==y.
struct ViaHole {
    double x = 0;
    double y = 0;
    double x2 = 0;
    double y2 = 0;
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
/// positions/diameters, re-origined by (originX, originY) -- pass edgeCutsBoundingBox()'s
/// xMin/yMin, exactly like compositeOps(), for the same [0, pcbWidth] x [0, pcbHeight] convention
/// the rest of the pipeline uses. Excellon coordinates come out of kicad-cli relative to the
/// board's auxiliary origin, the same as every Gerber this pipeline reads (both exported with
/// --use-drill-file-origin) -- without this shift, a via's position isn't comparable to anything
/// else this pipeline computes (a SlicedBoard's outline, a layer's triangulated copper, ...),
/// which silently broke every "does this via still fall inside the sliced board" check downstream.
std::expected<std::vector<ViaHole>, std::string> getVias(const PathsConfig& paths, double originX, double originY);

/// A non-plated through-hole -- a bare mechanical/alignment hole with no copper of its own anywhere
/// (unlike ViaHole), modeled as a capsule/stadium shape between two endpoints with `diameter` as the
/// capsule's width: Excellon's G85 "canned slot" cycle drills exactly this shape for an elongated
/// hole (e.g. a USB connector's mounting/alignment slots), and a plain round hole is just the
/// degenerate case where both endpoints coincide (x1==x2, y1==y2).
struct NPTHHole {
    double x1 = 0;
    double y1 = 0;
    double x2 = 0;
    double y2 = 0;
    double diameter = 0;
};

/// Parses `paths.fabDir`'s `*-NPTH.drl` (Excellon non-plated-hole drill file) for every mechanical
/// hole, round or slotted, re-origined the same way getVias() re-origins PTH holes (see its own doc
/// comment) so this lands in the same frame as everything else in this pipeline. Returns an empty
/// vector (not an error) if the board has no NPTH holes at all -- unlike a PTH file, which every
/// real board has at least one via in, a board with only plated vias and no mechanical holes is
/// entirely normal, so a missing/empty file isn't a parsing failure here. This is a hole to be
/// *subtracted* from copper wherever it falls (see board_slicing.cpp), not copper to add -- unlike
/// getVias()'s output, it never feeds Simulation::addVias().
std::expected<std::vector<NPTHHole>, std::string> getNPTHHoles(const PathsConfig& paths, double originX,
                                                                  double originY);

/// Imports stackup information (copper/dielectric layer thicknesses and dielectric constants) from
/// the live board, via libkicad_query, into `config`. Requires fab/board.kicad_pcb (persisted by
/// exportKicadPcb()).
std::expected<void, std::string> importStackup(const PathsConfig& paths, EMSConfig& config);

} // namespace gerber2ems
