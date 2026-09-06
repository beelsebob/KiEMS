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

inline void to_json(nlohmann::json& j, const Triangle& t) { j = nlohmann::json{{"a", t.a}, {"b", t.b}, {"c", t.c}}; }

inline void from_json(const nlohmann::json& j, Triangle& t) {
    j.at("a").get_to(t.a);
    j.at("b").get_to(t.b);
    j.at("c").get_to(t.c);
}

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

/// Copies the KiCad board/project into `paths.fabDir` for persistent libkicad queries. The
/// historical function name is retained for source compatibility; no manufacturing files are
/// exported.
std::expected<void, std::string> exportKicadPcb(const PathsConfig& paths, const std::filesystem::path& kicadPcbPath);

/// Reads plated through-hole positions and drill shapes directly from libkicad and re-origins them
/// by (originX, originY), preserving the downstream capsule representation used for round and
/// slotted holes.
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

/// Reads every mechanical hole directly from KiCad NPTH pads and re-origins it like getVias().
/// This is a hole to be subtracted from copper, never copper to add.
std::expected<std::vector<NPTHHole>, std::string> getNPTHHoles(const PathsConfig& paths, double originX,
                                                                  double originY);

/// Imports stackup information (copper/dielectric layer thicknesses and dielectric constants) from
/// the live board, via libkicad_query, into `config`. Requires fab/board.kicad_pcb (persisted by
/// exportKicadPcb()).
std::expected<void, std::string> importStackup(const PathsConfig& paths, EMSConfig& config);

} // namespace gerber2ems
