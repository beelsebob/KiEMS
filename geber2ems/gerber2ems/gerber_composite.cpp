#include "gerber_composite.hpp"

#include <cmath>
#include <limits>

#include <clipper2/clipper.h>

#include "config.hpp"
#include "constants.hpp"
#include "gerber_io.hpp"
#include "logging.hpp"

namespace gerber2ems {

namespace {

// ---- Position <-> Clipper2 Path64 (this module's own conversion; gerber_io.cpp's ApertureMacro
// has a separate, unscaled one for compositing a macro's own sub-primitives -- see its comment) ----
//
// Coordinates are simulation units (already ~0.1um resolution) directly, minus the board's
// Edge_Cuts origin, rounded to the nearest integer. Cross/area products Clipper2 computes
// internally stay many orders of magnitude below int64_t overflow for any realistic board size.

Clipper2Lib::Path64 _positionsToPath64(const std::vector<Position>& points, double originX, double originY) {
    Clipper2Lib::Path64 path;
    path.reserve(points.size());
    for (const auto& p : points) {
        path.emplace_back(static_cast<std::int64_t>(std::llround(p.x() - originX)),
                           static_cast<std::int64_t>(std::llround(p.y() - originY)));
    }
    return path;
}

Position _pointToPosition(const Clipper2Lib::Point64& pt) {
    return Position(static_cast<double>(pt.x), static_cast<double>(pt.y));
}

// ---- board origin ----

/// Bounding box of the board's Edge_Cuts outline, in native (unshifted) simulation-unit
/// coordinates. Every other consumer of board extent (getDimensions(), grid_gen.cpp's own
/// independent parse) derives it the same way -- from Edge_Cuts vector geometry directly, not a
/// rendered raster -- so this intentionally duplicates that small scan rather than threading a
/// shared cache through unrelated modules for a parse that costs microseconds.
struct BoundingBox {
    double xMin = std::numeric_limits<double>::infinity();
    double xMax = -std::numeric_limits<double>::infinity();
    double yMin = std::numeric_limits<double>::infinity();
    double yMax = -std::numeric_limits<double>::infinity();
};

BoundingBox _edgeCutsBoundingBox() {
    BoundingBox box;
    std::error_code ec;
    const std::filesystem::path fabDir = std::filesystem::current_path() / "fab";
    std::optional<std::filesystem::path> edgeCutsPath;
    if (std::filesystem::is_directory(fabDir, ec)) {
        for (const auto& entry : std::filesystem::directory_iterator(fabDir, ec)) {
            const std::string name = entry.path().filename().string();
            if (name.size() >= 13 && name.compare(name.size() - 13, 13, "Edge_Cuts.gbr") == 0) {
                edgeCutsPath = entry.path();
                break;
            }
        }
    }
    if (!edgeCutsPath.has_value()) {
        logError("No EdgeCuts gerber in fab dir(" + fabDir.string() + ")");
        std::exit(1);
    }
    GerberFile edgeCuts(*edgeCutsPath);
    for (const auto& seg : edgeCuts.traceForNet("no-net").segments()) {
        box.xMin = std::min({seg.start().x(), seg.stop().x(), box.xMin});
        box.yMin = std::min({seg.start().y(), seg.stop().y(), box.yMin});
        box.xMax = std::max({seg.start().x(), seg.stop().x(), box.xMax});
        box.yMax = std::max({seg.start().y(), seg.stop().y(), box.yMax});
    }
    return box;
}

// ---- CopperOp -> Clipper2 paths ----

/// A stroke is widened via Minkowski-sum offsetting (round join/cap): exact for the only stroke
/// aperture shape the parser allows (circular -- see the "is not circular aperture" check in
/// gerber_io.cpp), and independent per-segment inflation is mathematically identical to inflating a
/// whole multi-segment chain at once (a round cap's disk simply dominates at shared vertices, which
/// is also physically correct at a trace-width transition), so no chain-grouping is needed.
Clipper2Lib::Paths64 _strokeToPaths(const TraceSegment& seg, double tessellationTolerance, double originX,
                                     double originY) {
    const Clipper2Lib::Path64 line = _positionsToPath64({seg.start(), seg.stop()}, originX, originY);
    // arc_tolerance explicit (rather than Clipper2's own auto-heuristic default) so the round caps'
    // fidelity is controlled by the same knob as every other curved shape in this pipeline.
    return Clipper2Lib::InflatePaths({line}, seg.width() / 2.0, Clipper2Lib::JoinType::Round,
                                      Clipper2Lib::EndType::Round, 2.0, tessellationTolerance);
}

Clipper2Lib::Paths64 _padToPaths(const Pad& pad, const std::unordered_map<std::string, Aperture>& apertures,
                                  double tessellationTolerance, double originX, double originY) {
    Clipper2Lib::Paths64 paths;
    const auto it = apertures.find(pad.aperture());
    if (it == apertures.end()) {
        logError("Aperture `" + pad.aperture() + "` used for a pad flash is not defined!");
        return paths;
    }
    const std::vector<std::vector<Position>> loops =
        it->second.data().toPolygon(pad.pos(), pad.rotation(), pad.scale(), pad.mirror(), 0, tessellationTolerance);
    paths.reserve(loops.size());
    for (const auto& loop : loops) {
        if (loop.size() < 3) {
            continue; // degenerate
        }
        paths.push_back(_positionsToPath64(loop, originX, originY));
    }
    return paths;
}

/// A zone's segment chain is already a closed loop (force-closed at G37); consecutive segments'
/// start points are its vertices directly, no widening needed.
Clipper2Lib::Paths64 _zoneToPaths(const std::vector<TraceSegment>& segments, double originX, double originY) {
    std::vector<Position> loop;
    loop.reserve(segments.size());
    for (const auto& seg : segments) {
        loop.push_back(seg.start());
    }
    if (loop.size() < 3) {
        return {};
    }
    return {_positionsToPath64(loop, originX, originY)};
}

// ---- PolyTree -> (outer, holes) regions ----
//
// Recognises holes purely by tree level (odd levels are outers/islands, even non-zero levels are
// holes) so arbitrary nesting (an island inside a hole inside an outer, etc.) is handled correctly,
// not just the common single-level case.
void _collectRegions(const Clipper2Lib::PolyPath64* node,
                      std::vector<std::pair<Clipper2Lib::Path64, Clipper2Lib::Paths64>>& regions) {
    if (node->Level() > 0 && !node->IsHole()) {
        Clipper2Lib::Paths64 holes;
        holes.reserve(node->Count());
        for (std::size_t i = 0; i < node->Count(); ++i) {
            holes.push_back(node->Child(i)->Polygon());
        }
        regions.emplace_back(node->Polygon(), std::move(holes));
    }
    for (std::size_t i = 0; i < node->Count(); ++i) {
        _collectRegions(node->Child(i), regions);
    }
}

} // namespace

std::vector<Triangle> compositeLayerTriangles(const std::filesystem::path& gerberPath) {
    const GerberFile gerber(gerberPath);
    const BoundingBox origin = _edgeCutsBoundingBox();
    const double tessellationTolerance =
        static_cast<double>(Config::sharedConfig().pixelSize()) * constants::unitMultiplier;

    // Walk copperOps in file order, applying each maximal same-polarity run against a running
    // accumulator: Union for dark, Difference for clear. This reproduces Gerber's actual
    // painter's-algorithm polarity compositing (see CopperOp's own doc comment for why grouping
    // into runs is lossless rather than just a performance shortcut).
    Clipper2Lib::Paths64 accumulator;
    Clipper2Lib::Paths64 runPaths;
    bool haveRun = false;
    bool runAdditive = true;

    auto flushRun = [&]() {
        if (!haveRun || runPaths.empty()) {
            runPaths.clear();
            haveRun = false;
            return;
        }
        const Clipper2Lib::Paths64 runUnion = Clipper2Lib::Union(runPaths, Clipper2Lib::FillRule::NonZero);
        accumulator = runAdditive ? Clipper2Lib::Union(accumulator, runUnion, Clipper2Lib::FillRule::NonZero)
                                   : Clipper2Lib::Difference(accumulator, runUnion, Clipper2Lib::FillRule::NonZero);
        runPaths.clear();
        haveRun = false;
    };

    for (const CopperOp& op : gerber.copperOps()) {
        if (haveRun && op.additive != runAdditive) {
            flushRun();
        }
        runAdditive = op.additive;
        haveRun = true;

        Clipper2Lib::Paths64 opPaths;
        if (op.kind == CopperOp::Kind::Stroke) {
            opPaths = _strokeToPaths(std::get<TraceSegment>(op.payload), tessellationTolerance, origin.xMin,
                                      origin.yMin);
        } else if (op.kind == CopperOp::Kind::Pad) {
            opPaths = _padToPaths(std::get<Pad>(op.payload), gerber.apertures(), tessellationTolerance, origin.xMin,
                                   origin.yMin);
        } else {
            opPaths = _zoneToPaths(std::get<std::vector<TraceSegment>>(op.payload), origin.xMin, origin.yMin);
        }
        runPaths.insert(runPaths.end(), opPaths.begin(), opPaths.end());
    }
    flushRun();

    if (accumulator.empty()) {
        return {}; // No copper features on this layer.
    }

    Clipper2Lib::PolyTree64 tree;
    Clipper2Lib::BooleanOp(Clipper2Lib::ClipType::Union, Clipper2Lib::FillRule::NonZero, accumulator, {}, tree);

    std::vector<std::pair<Clipper2Lib::Path64, Clipper2Lib::Paths64>> regions;
    _collectRegions(&tree, regions);

    std::vector<Triangle> result;
    for (auto& [outer, holes] : regions) {
        Clipper2Lib::Paths64 pp;
        pp.reserve(holes.size() + 1);
        pp.push_back(Clipper2Lib::SimplifyPath(outer, tessellationTolerance, true));
        for (const auto& hole : holes) {
            pp.push_back(Clipper2Lib::SimplifyPath(hole, tessellationTolerance, true));
        }

        Clipper2Lib::Paths64 solution;
        const Clipper2Lib::TriangulateResult triResult = Clipper2Lib::Triangulate(pp, solution);
        if (triResult != Clipper2Lib::TriangulateResult::success) {
            logError("Triangulation failed for a copper region in " + gerberPath.string() +
                      " (code " + std::to_string(static_cast<int>(triResult)) + ")");
            continue;
        }
        for (const auto& tri : solution) {
            if (tri.size() != 3) {
                logError("Triangulate returned a non-triangular path; skipping");
                continue;
            }
            result.push_back(Triangle{_pointToPosition(tri[0]), _pointToPosition(tri[1]), _pointToPosition(tri[2])});
        }
    }

    logDebug("Found " + std::to_string(result.size()) + " triangles for " + gerberPath.string());
    return result;
}

} // namespace gerber2ems
