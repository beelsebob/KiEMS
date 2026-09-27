// Gerber/drill/stackup importing. Ported from kiems/importer.py.
#pragma once

#include <cmath>
#include <cstdint>
#include <expected>
#include <filesystem>
#include <string>
#include <vector>

#include "config.hpp"
#include "gerber_io.hpp"
#include "paths_config.hpp"
#include "polygon_geometry.hpp"

namespace kiems {

using Cu::Triangle;

/// Common shape shared by every real-board hole this pipeline models as a capsule/stadium --
/// ViaHole/NPTHHole alike (see board_slicing.cpp's own tessellateHoles(), the one place that treats
/// them uniformly): a straight, round-ended centerline (`path()`, already re-origined into
/// simulation-unit coordinates, start==end for a plain round hole) inflated by `diameter`/2. Neither
/// subclass adds any behavior of its own, only the differently-named coordinate fields each already
/// had before this common base existed (ViaHole's x/y vs. NPTHHole's x1/y1, both kept for source
/// compatibility with every existing call site) -- `path()` is what lets a caller stop caring which.
struct Hole {
    double diameter = 0;

    virtual ~Hole() = default;

    /// Two points (start==end for a plain round hole), ready for a round-cap buffer at radius
    /// diameter/2 -- see tessellateHoles() (board_slicing.cpp).
    virtual Cu::Polygon path() const = 0;
};

/// Already re-origined the same way (see getVias()) -- safe to use directly alongside a
/// SlicedBoard's outline/layerTriangles, both in the same [0, pcbWidth] x [0, pcbHeight] frame. A
/// plated through-hole is a capsule/stadium shape between (x, y) and (x2, y2) with `diameter` as
/// its width -- Excellon's G85 "canned slot" cycle drills exactly this shape for an elongated
/// through-hole (e.g. a connector's oblong SHIELD pad), the same convention NPTHHole uses for a
/// non-plated one; a plain round via is the degenerate case where x2==x, y2==y.
struct ViaHole : Hole {
    double x = 0;
    double y = 0;
    double x2 = 0;
    double y2 = 0;

    Cu::Polygon path() const override {
        return {{x, y}, {x2, y2}};
    }
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
struct NPTHHole : Hole {
    double x1 = 0;
    double y1 = 0;
    double x2 = 0;
    double y2 = 0;

    Cu::Polygon path() const override {
        return {{x1, y1}, {x2, y2}};
    }
};

/// Reads every mechanical hole directly from KiCad NPTH pads and re-origins it like getVias().
/// This is a hole to be subtracted from copper, never copper to add.
std::expected<std::vector<NPTHHole>, std::string> getNPTHHoles(const PathsConfig& paths, double originX,
                                                                  double originY);

/// Imports stackup information (copper/dielectric layer thicknesses and dielectric constants) from
/// the live board, via ki, into `config`. Requires fab/board.kicad_pcb (persisted by
/// exportKicadPcb()).
std::expected<void, std::string> importStackup(const PathsConfig& paths, EMSConfig& config);

} // namespace kiems
