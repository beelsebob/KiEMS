#include "gerber_composite.hpp"

#include <algorithm>
#include <cmath>
#include <limits>

#include <clipper2/clipper.h>

#include "config.hpp"
#include "constants.hpp"
#include "gerber_io.hpp"
#include "logging.hpp"

namespace kicad_ems {

using namespace Cu;

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

} // namespace

std::expected<BoundingBox, std::string> edgeCutsBoundingBox(const std::filesystem::path& fabDir,
                                                              double tessellationTolerance) {
    BoundingBox box;
    std::error_code ec;
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
        return std::unexpected("No EdgeCuts gerber in fab dir(" + fabDir.string() + ")");
    }
    auto edgeCutsResult = GerberFile::load(*edgeCutsPath, tessellationTolerance);
    if (!edgeCutsResult) {
        return std::unexpected(std::move(edgeCutsResult).error());
    }
    const GerberFile& edgeCuts = *edgeCutsResult;
    for (const auto& seg : edgeCuts.traceForNet(NetName("no-net")).segments()) {
        box.xMin = std::min({seg.start().x(), seg.stop().x(), box.xMin});
        box.yMin = std::min({seg.start().y(), seg.stop().y(), box.yMin});
        box.xMax = std::max({seg.start().x(), seg.stop().x(), box.xMax});
        box.yMax = std::max({seg.start().y(), seg.stop().y(), box.yMax});
    }
    return box;
}

namespace {

// ---- CopperOp -> Clipper2 paths ----

/// Every dark-polarity Gerber element (a pad flash, a zone region, a stroke) independently means
/// "this area is copper", full stop -- Gerber itself carries no winding-direction convention for a
/// single filled shape. But Clipper2Lib::Union's NonZero fill rule *is* winding-sensitive: two
/// overlapping but oppositely-wound simple polygons contribute opposite-signed winding numbers and
/// cancel to zero (unfilled) in their overlap, rather than reinforcing to nonzero (filled). This
/// pipeline's own shape generators aren't wound consistently with each other -- e.g. ApertureRect's
/// point order comes out positive-area (CCW) while _zoneToPaths just replays a zone's own file-order
/// vertices verbatim, which came out negative-area (CW) on every real board this was checked
/// against -- so an SMD pad flashed on top of a same-net zone/plane fill could cancel out to a hole
/// instead of just being redundant coverage, exactly where the pad sits. Forcing every path to the
/// same (positive-area) orientation before it ever reaches a Union/Difference call makes overlap
/// always reinforce, matching Gerber's actual "just more copper" semantics regardless of whichever
/// generator produced the path or which order its points happened to come out in.
void _normalizePositiveOrientation(Clipper2Lib::Paths64& paths) {
    for (Clipper2Lib::Path64& path : paths) {
        if (!Clipper2Lib::IsPositive(path)) {
            std::reverse(path.begin(), path.end());
        }
    }
}

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

Clipper2Lib::Paths64 compositeOps(const GerberFile& gerber, const std::vector<CopperOp>& ops, double originX,
                                    double originY, double tessellationTolerance) {
    // Walk ops in (file) order, applying each maximal same-polarity run against a running
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

    for (const CopperOp& op : ops) {
        if (haveRun && op.additive != runAdditive) {
            flushRun();
        }
        runAdditive = op.additive;
        haveRun = true;

        Clipper2Lib::Paths64 opPaths;
        if (op.kind == CopperOp::Kind::Stroke) {
            opPaths = _strokeToPaths(std::get<TraceSegment>(op.payload), tessellationTolerance, originX, originY);
        } else if (op.kind == CopperOp::Kind::Pad) {
            opPaths =
                _padToPaths(std::get<Pad>(op.payload), gerber.apertures(), tessellationTolerance, originX, originY);
        } else {
            opPaths = _zoneToPaths(std::get<std::vector<TraceSegment>>(op.payload), originX, originY);
        }
        _normalizePositiveOrientation(opPaths);
        runPaths.insert(runPaths.end(), opPaths.begin(), opPaths.end());
    }
    flushRun();
    return accumulator;
}

std::vector<Triangle> triangulate(const Clipper2Lib::Paths64& composited, double tessellationTolerance,
                                    const std::string& contextForErrors) {
    if (composited.empty()) {
        return {};
    }

    Clipper2Lib::PolyTree64 tree;
    Clipper2Lib::BooleanOp(Clipper2Lib::ClipType::Union, Clipper2Lib::FillRule::NonZero, composited, {}, tree);

    std::vector<std::pair<Clipper2Lib::Path64, Clipper2Lib::Paths64>> regions;
    _collectRegions(&tree, regions);

    std::vector<Triangle> result;
    for (auto& [outer, holes] : regions) {
        // SimplifyPath (Douglas-Peucker-style vertex removal) occasionally *introduces* a
        // self-intersection it didn't have before -- a documented Clipper2 characteristic, not
        // something specific to this pipeline's input -- on a polygon with tight concave detail
        // close to `tessellationTolerance` (a dense zone's thermal-relief notches around a cluster
        // of pads, say). `outer`/`holes` themselves came straight out of a PolyTree a Union boolean
        // op just produced, so they're guaranteed simple on their own; only the simplified copies
        // can fail to triangulate this way. Retrying with those un-simplified originals (more
        // vertices, but geometrically identical, and reliably triangulable) recovers the region
        // instead of silently dropping it -- which used to make whole copper regions vanish from
        // this pipeline's output for no reason visible anywhere in the source data itself.
        Clipper2Lib::Paths64 simplified;
        simplified.reserve(holes.size() + 1);
        simplified.push_back(Clipper2Lib::SimplifyPath(outer, tessellationTolerance, true));
        for (const auto& hole : holes) {
            simplified.push_back(Clipper2Lib::SimplifyPath(hole, tessellationTolerance, true));
        }

        Clipper2Lib::Paths64 solution;
        Clipper2Lib::TriangulateResult triResult = Clipper2Lib::Triangulate(simplified, solution);
        if (triResult != Clipper2Lib::TriangulateResult::success) {
            Clipper2Lib::Paths64 raw;
            raw.reserve(holes.size() + 1);
            raw.push_back(outer);
            raw.insert(raw.end(), holes.begin(), holes.end());
            solution.clear();
            triResult = Clipper2Lib::Triangulate(raw, solution);
        }
        if (triResult != Clipper2Lib::TriangulateResult::success) {
            logError("Triangulation failed for a copper region in " + contextForErrors + " (code " +
                      std::to_string(static_cast<int>(triResult)) + ")");
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

    logDebug("Found " + std::to_string(result.size()) + " triangles for " + contextForErrors);
    return result;
}

std::expected<std::vector<Triangle>, std::string> compositeLayerTriangles(const std::filesystem::path& fabDir,
                                                                            const std::filesystem::path& gerberPath,
                                                                            double tessellationTolerance) {
    auto gerberResult = GerberFile::load(gerberPath, tessellationTolerance);
    if (!gerberResult) {
        return std::unexpected(std::move(gerberResult).error());
    }
    const GerberFile& gerber = *gerberResult;
    auto originResult = edgeCutsBoundingBox(fabDir, tessellationTolerance);
    if (!originResult) {
        return std::unexpected(std::move(originResult).error());
    }
    const BoundingBox& origin = *originResult;

    const Clipper2Lib::Paths64 composited =
        compositeOps(gerber, gerber.copperOps(), origin.xMin, origin.yMin, tessellationTolerance);
    return triangulate(composited, tessellationTolerance, gerberPath.string());
}

} // namespace kicad_ems
