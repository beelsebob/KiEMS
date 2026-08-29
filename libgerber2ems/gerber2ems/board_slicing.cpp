#include "board_slicing.hpp"

#include <algorithm>
#include <cmath>
#include <cstdlib>
#include <filesystem>
#include <limits>
#include <unordered_set>

#include <clipper2/clipper.h>

#include "config.hpp"
#include "constants.hpp"
#include "gerber_composite.hpp"
#include "gerber_io.hpp"
#include "libkicad_query.hpp"
#include "logging.hpp"

namespace gerber2ems {

using namespace Cu;

namespace {

Clipper2Lib::Path64 _positionsToPath64(const std::vector<Position>& points, double originX, double originY) {
    Clipper2Lib::Path64 path;
    path.reserve(points.size());
    for (const auto& p : points) {
        path.emplace_back(static_cast<std::int64_t>(std::llround(p.x() - originX)),
                           static_cast<std::int64_t>(std::llround(p.y() - originY)));
    }
    return path;
}

std::vector<Position> _path64ToPositions(const Clipper2Lib::Path64& path) {
    std::vector<Position> points;
    points.reserve(path.size());
    for (const auto& pt : path) {
        points.emplace_back(static_cast<double>(pt.x), static_cast<double>(pt.y));
    }
    return points;
}

constexpr double kOutlineChainToleranceSimUnits = 100.0; // 10 microns, at 10 sim-units/micron

/// Reassembles `segments` into a single connected loop by repeatedly matching each new segment's
/// nearest endpoint to the growing chain's current end -- KiCad plots Edge_Cuts as separate draw
/// primitives (individual lines/arcs, each arc itself tessellated into several short segments), not
/// necessarily emitted in geometric traversal order the way a zone's already-closed fill boundary
/// is, so file order alone isn't a usable loop ordering for anything but the simplest rectangular
/// board. A real board outline is a simple closed curve (each vertex touched by exactly two
/// segments), so this greedy nearest-endpoint walk is exact as long as segment endpoints coincide
/// within tolerance -- true of a single kicad-cli Gerber export. Leaves any segments that couldn't
/// be chained (a genuinely disjoint second loop, or a malformed outline) in `remaining`.
std::vector<Position> _chainSegmentsIntoLoop(std::vector<TraceSegment> remaining) {
    if (remaining.empty()) {
        return {};
    }
    std::vector<Position> loop = {remaining.front().start(), remaining.front().stop()};
    remaining.erase(remaining.begin());

    bool foundMatch = true;
    while (!remaining.empty() && foundMatch) {
        foundMatch = false;
        const Position& current = loop.back();
        for (std::size_t i = 0; i < remaining.size(); ++i) {
            const double startDist =
                std::hypot(remaining[i].start().x() - current.x(), remaining[i].start().y() - current.y());
            const double stopDist =
                std::hypot(remaining[i].stop().x() - current.x(), remaining[i].stop().y() - current.y());
            if (startDist <= kOutlineChainToleranceSimUnits || stopDist <= kOutlineChainToleranceSimUnits) {
                loop.push_back(startDist <= stopDist ? remaining[i].stop() : remaining[i].start());
                remaining.erase(remaining.begin() + static_cast<std::ptrdiff_t>(i));
                foundMatch = true;
                break;
            }
        }
    }
    if (!remaining.empty()) {
        logWarning("Edge_Cuts outline: " + std::to_string(remaining.size()) +
                   " segment(s) didn't chain into the main loop (disjoint loop, or a gap bigger than " +
                   std::to_string(kOutlineChainToleranceSimUnits / 10.0) + " microns) -- ignored");
    }
    return loop;
}

/// The board's real Edge_Cuts outline as one closed polygon loop, in the same re-origined frame as
/// every composited copper layer. Assumes the outline is a single closed loop (true of every real
/// board this pipeline has been validated against); a board whose Edge_Cuts is multiple disjoint
/// loops (a cutout/slot as a separate closed loop, rather than a single self-touching "keyhole"
/// outline -- see gerber_io.cpp's own note on the same assumption for zone regions) would need this
/// extended to collect multiple loops, which isn't done here.
std::expected<Clipper2Lib::Path64, std::string> _realBoardOutline(const std::filesystem::path& fabDir,
                                                                    double originX, double originY,
                                                                    double tessellationTolerance) {
    std::optional<std::filesystem::path> edgeCutsPath;
    std::error_code ec;
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
    const std::vector<Position> loop = _chainSegmentsIntoLoop(edgeCuts.traceForNet(NetName("no-net")).segments());
    if (loop.size() < 3) {
        return std::unexpected("Edge_Cuts outline has fewer than 3 points");
    }
    return _positionsToPath64(loop, originX, originY);
}

/// Shortest distance from `pt` to the polyline formed by `path`'s edges (treated as a closed loop).
double _distancePointToPolyline(const Clipper2Lib::Point64& pt, const Clipper2Lib::Path64& path) {
    double best = std::numeric_limits<double>::infinity();
    for (std::size_t i = 0; i < path.size(); ++i) {
        const Clipper2Lib::Point64& a = path[i];
        const Clipper2Lib::Point64& b = path[(i + 1) % path.size()];
        const double abx = static_cast<double>(b.x - a.x);
        const double aby = static_cast<double>(b.y - a.y);
        const double lenSq = abx * abx + aby * aby;
        double t = 0;
        if (lenSq > 0) {
            t = (static_cast<double>(pt.x - a.x) * abx + static_cast<double>(pt.y - a.y) * aby) / lenSq;
            t = std::clamp(t, 0.0, 1.0);
        }
        const double px = static_cast<double>(a.x) + t * abx;
        const double py = static_cast<double>(a.y) + t * aby;
        const double dx = static_cast<double>(pt.x) - px;
        const double dy = static_cast<double>(pt.y) - py;
        best = std::min(best, std::hypot(dx, dy));
    }
    return best;
}

/// Point-membership test against a NonZero-fill composited region (e.g. gerber_composite's
/// compositeOps() output), handling arbitrarily-nested holes/islands the same way
/// gerber_composite.cpp's own triangulate()/_collectRegions does: build a PolyTree and check, at
/// whatever depth `pt` is found, whether that level is an outer region (odd level) or a hole
/// (even, non-zero level).
bool _pointInComposite(const Clipper2Lib::Point64& pt, const Clipper2Lib::Paths64& composited) {
    if (composited.empty()) {
        return false;
    }
    Clipper2Lib::PolyTree64 tree;
    Clipper2Lib::BooleanOp(Clipper2Lib::ClipType::Union, Clipper2Lib::FillRule::NonZero, composited, {}, tree);

    const Clipper2Lib::PolyPath64* node = &tree;
    bool inside = false;
    bool descended = true;
    while (descended) {
        descended = false;
        for (std::size_t i = 0; i < node->Count(); ++i) {
            const Clipper2Lib::PolyPath64* child = node->Child(i);
            if (Clipper2Lib::PointInPolygon(pt, child->Polygon()) != Clipper2Lib::PointInPolygonResult::IsOutside) {
                inside = !child->IsHole();
                node = child;
                descended = true;
                break;
            }
        }
    }
    return inside;
}

// _opsOnNets() below compares net names straight against Gerber's own copperOps() (already NetName,
// real-unescaped-slash form -- see gerber_io.cpp), while involvedNets/groundNets come from
// libkicad_query in KiCad's own escaped form ("{slash}" standing in for a literal "/" in a
// hierarchical-sheet-path net name, e.g. "/MCU/USB/Upstream/SSRx-"). Wrapping both sides in NetName
// (rather than manually reversing the escaping here, as this used to) lets NetName's own
// normalize-before-compare handle that mismatch structurally -- see net_name.hpp's own doc comment.
std::vector<CopperOp> _opsOnNets(const GerberFile& gerber, const std::unordered_set<NetName, NetNameHash>& nets) {
    std::vector<CopperOp> filtered;
    for (const CopperOp& op : gerber.copperOps()) {
        if (nets.count(op.net) != 0) {
            filtered.push_back(op);
        }
    }
    return filtered;
}

std::optional<std::filesystem::path> _copperGerberForFileName(const std::filesystem::path& fabDir,
                                                                const std::string& layerFileName) {
    const std::string suffix = "-" + layerFileName + ".gbr";
    std::error_code ec;
    if (std::filesystem::is_directory(fabDir, ec)) {
        for (const auto& entry : std::filesystem::directory_iterator(fabDir, ec)) {
            const std::string name = entry.path().filename().string();
            if (name.size() >= suffix.size() && name.compare(name.size() - suffix.size(), suffix.size(), suffix) == 0) {
                return entry.path();
            }
        }
    }
    return std::nullopt;
}

} // namespace

std::expected<SlicedBoard, std::string> sliceBoardForSimulation(const SimulationConfig& sim, const EMSConfig& config,
                                                                  const PathsConfig& paths) {
    std::unordered_set<NetName, NetNameHash> involvedNets;
    for (const InvolvedNetConfig& entry : sim.involvedNets()) {
        auto nets = libkicad_query::resolveInvolvedNetNames(paths, entry);
        if (!nets) return std::unexpected(std::move(nets).error());
        for (const std::string& net : *nets) {
            involvedNets.insert(NetName(net));
        }
    }
    std::unordered_set<NetName, NetNameHash> groundNets;
    {
        auto nets = libkicad_query::resolveGroundNetNames(paths, sim.groundNet());
        if (!nets) return std::unexpected(std::move(nets).error());
        for (const std::string& net : *nets) {
            groundNets.insert(NetName(net));
        }
    }

    const double tessellationTolerance = static_cast<double>(config.pixelSize()) * constants::unitMultiplier;
    auto originResult = edgeCutsBoundingBox(paths.fabDir, tessellationTolerance);
    if (!originResult) return std::unexpected(std::move(originResult).error());
    const BoundingBox& origin = *originResult;
    const std::vector<LayerConfig> metals = config.getMetals();

    // Per layer: the involved-net and ground-net composites (pre-cutout), and the GerberFile they
    // came from (kept alive for _opsOnNets' aperture lookups during compositing). Every other net's
    // copper (including unnamed/net-less pours) is deliberately never composited at all -- it never
    // survives into layerTriangles below (only signalPerLayer/groundInCutout do), so it was never
    // actually present in the simulated geometry for a stitching via's own full-depth barrel to
    // short against; an earlier version of this function also rejected via candidates that merely
    // sat over such copper *on the original, unsliced board*, which was overly conservative for
    // exactly that reason -- see the stitching-via placement loop below.
    std::vector<Clipper2Lib::Paths64> signalPerLayer(metals.size());
    std::vector<Clipper2Lib::Paths64> groundPerLayer(metals.size());

    Clipper2Lib::Paths64 signalUnionAllLayers;
    for (std::size_t layerIndex = 0; layerIndex < metals.size(); ++layerIndex) {
        const std::optional<std::filesystem::path> gerberPath =
            _copperGerberForFileName(paths.fabDir, metals[layerIndex].file());
        if (!gerberPath.has_value()) {
            continue; // No copper on this layer at all.
        }
        auto gerberResult = GerberFile::load(*gerberPath, tessellationTolerance);
        if (!gerberResult) return std::unexpected(std::move(gerberResult).error());
        const GerberFile& gerber = *gerberResult;

        const std::vector<CopperOp> involvedOps = _opsOnNets(gerber, involvedNets);
        signalPerLayer[layerIndex] = compositeOps(gerber, involvedOps, origin.xMin, origin.yMin, tessellationTolerance);
        groundPerLayer[layerIndex] =
            compositeOps(gerber, _opsOnNets(gerber, groundNets), origin.xMin, origin.yMin, tessellationTolerance);

        signalUnionAllLayers = Clipper2Lib::Union(signalUnionAllLayers, signalPerLayer[layerIndex],
                                                    Clipper2Lib::FillRule::NonZero);
    }

    if (signalUnionAllLayers.empty()) {
        return std::unexpected("Simulation \"" + sim.name() + "\": involved nets have no copper on any layer");
    }

    // Cutout region: involved-net footprint padded by hull_padding, clipped to the real board
    // outline (see board_slicing.hpp's algorithm doc comment -- this stands in for a true concave
    // hull/alpha-shape, which isn't implemented here).
    auto realOutlineResult = _realBoardOutline(paths.fabDir, origin.xMin, origin.yMin, tessellationTolerance);
    if (!realOutlineResult) return std::unexpected(std::move(realOutlineResult).error());
    const Clipper2Lib::Path64& realOutline = *realOutlineResult;
    const Clipper2Lib::Paths64 padded =
        Clipper2Lib::InflatePaths(signalUnionAllLayers, sim.hullPadding(), Clipper2Lib::JoinType::Round,
                                    Clipper2Lib::EndType::Polygon, 2.0, tessellationTolerance);
    const Clipper2Lib::Paths64 cutout =
        Clipper2Lib::Intersect(padded, {realOutline}, Clipper2Lib::FillRule::NonZero);
    if (cutout.empty()) {
        return std::unexpected("Simulation \"" + sim.name() + "\": computed cutout region is empty");
    }

    // Real vias near this simulation, seeding the clearance/spacing checks below -- a stitching via
    // must never collide with one, and (if the real via is itself on the ground net) must respect
    // the same viaSpacing from it as from another stitching via. Best-effort: if the drill file
    // can't be read, stitching vias just place without this check rather than failing the whole
    // slice over it (the same as if the board genuinely had no other vias nearby).
    struct ExistingVia {
        double x = 0;
        double y = 0;
        double outerRadius = 0; // For the clearance check (edge-to-edge, not center-to-center).
        bool isGround = false;  // For the viaSpacing check, which only applies among ground-net vias.
    };
    std::vector<ExistingVia> existingVias;
    // Kept (not just the derived ExistingVia stats below) so the final per-layer copper loop can
    // also cut each real via's own hole out of the copper -- see viaHolePolygons' own comment.
    std::vector<ViaHole> realViasForHoleCutting;
    if (auto realVias = getVias(paths, origin.xMin, origin.yMin); realVias) {
        existingVias.reserve(realVias->size());
        realViasForHoleCutting = *realVias;
        for (const ViaHole& via : *realVias) {
            // Midpoint of the via's own capsule centerline -- exactly (via.x, via.y) for a plain
            // round via (x2==x, y2==y), the center of the pad for an elongated one.
            const double midX = (via.x + via.x2) / 2;
            const double midY = (via.y + via.y2) / 2;
            const Clipper2Lib::Point64 pos(static_cast<std::int64_t>(std::llround(midX)),
                                             static_cast<std::int64_t>(std::llround(midY)));
            const bool isGround = std::any_of(groundPerLayer.begin(), groundPerLayer.end(),
                                                [&](const Clipper2Lib::Paths64& ground) {
                                                    return _pointInComposite(pos, ground);
                                                });
            // Circumscribing radius from the midpoint -- half the centerline length plus the pad's
            // own half-width -- so an elongated pad's clearance footprint is never underestimated,
            // even though this treats it as round for the purpose of this check (a conservative
            // over-approximation, not an exact capsule-to-capsule distance).
            const double halfLength = std::hypot(via.x2 - via.x, via.y2 - via.y) / 2;
            const double outerRadius = halfLength + via.diameter / 2 + config.via().platingThickness();
            existingVias.push_back({midX, midY, outerRadius, isGround});
        }
    }

    // True if placing a stitchingViaAnnularRingDiameter()-sized via centered at (x, y) would either
    // physically collide with an existing via (real or already placed in this same pass -- any net,
    // checked edge-to-edge against config.via().viaClearance()) or sit closer than sim.viaSpacing()
    // to an existing *ground-net* via specifically (real or already placed -- a stitching via is
    // always ground, so this also naturally keeps freshly-placed stitching vias that spacing apart
    // from each other, alongside real ground vias).
    const double candidateRadius = config.via().stitchingViaAnnularRingDiameter() / 2;
    auto tooCloseToExistingVia = [&](double x, double y) {
        for (const ExistingVia& existing : existingVias) {
            const double dist = std::hypot(x - existing.x, y - existing.y);
            if (dist < candidateRadius + existing.outerRadius + config.via().viaClearance()) {
                return true;
            }
            if (existing.isGround && dist < sim.viaSpacing()) {
                return true;
            }
        }
        return false;
    };

    // Stitching vias: walk every outer boundary loop of the cutout, classify each edge against the
    // real board outline (on/near it -> pre-existing, no stitching needed there), and place vias
    // along new-cut edges only -- spaced sim.viaSpacing() apart along the *whole contiguous run* of
    // new-cut edges, not restarted at every individual polygon edge. The cutout boundary comes out
    // of Clipper2 boolean ops (in particular InflatePaths' round joins) tessellated into many short
    // segments, most of them far shorter than any real via spacing -- stepping per-edge like the
    // rest of this pipeline's per-segment code would place a minimum of one via at *every* edge
    // regardless of its length, since floor(shortSegLen / viaSpacing) always floors to 0 and gets
    // clamped back up to the "at least 1" minimum. That's what actually produced the reported bug:
    // clusters of near-duplicate vias at every tessellated vertex, spaced by tessellation
    // granularity rather than viaSpacing.
    std::vector<StitchingVia> stitchingVias;
    std::vector<Position> failedStitchingViaAttempts;
    // TEMPORARY diagnostic counters -- see the "electrically floating" warning below, which can't
    // currently tell "no ground copper reachable here at all" apart from "a real board via already
    // sits right there, so a redundant stitching via was correctly skipped" -- those mean very
    // different things for whether the edge is actually disconnected.
    std::size_t diagNoGroundCopperCount = 0;
    std::size_t diagTooCloseCount = 0;
    constexpr double kOnEdgeToleranceSimUnits = 100.0; // 10 microns, at 10 sim-units/micron
    for (const Clipper2Lib::Path64& loop : cutout) {
        const double area = Clipper2Lib::Area(loop);
        if (std::abs(area) < 1.0) {
            continue; // degenerate
        }
        const bool isHole = area < 0; // Clipper2's Union/Intersect output: positive-area = outer
        if (isHole) {
            continue; // Never stitch a hole's own boundary (e.g. a real board cutout) -- it's a
                      // genuine board edge already, per the same logic as the outer loop check.
        }

        const std::size_t n = loop.size();
        std::vector<bool> isNewCut(n, false);
        std::vector<double> segLens(n, 0.0);
        for (std::size_t i = 0; i < n; ++i) {
            const Clipper2Lib::Point64& a = loop[i];
            const Clipper2Lib::Point64& b = loop[(i + 1) % n];
            segLens[i] = std::hypot(static_cast<double>(b.x - a.x), static_cast<double>(b.y - a.y));
            if (segLens[i] < 1.0) {
                continue; // degenerate edge: leave isNewCut false, it'll just be skipped
            }
            const Clipper2Lib::Point64 midpoint((a.x + b.x) / 2, (a.y + b.y) / 2);
            isNewCut[i] = _distancePointToPolyline(midpoint, realOutline) > kOnEdgeToleranceSimUnits;
        }

        // Run-start indices: an edge starts a new run if it's a new cut and its predecessor isn't
        // -- except when literally every edge is a new cut (the whole loop is deep inside the real
        // board, touching it nowhere), which is one single run that can start anywhere; index 0 is
        // picked arbitrarily for that case.
        const bool allNewCut = std::all_of(isNewCut.begin(), isNewCut.end(), [](bool v) { return v; });
        std::vector<std::size_t> runStarts;
        if (allNewCut && n > 0) {
            runStarts.push_back(0);
        } else {
            for (std::size_t i = 0; i < n; ++i) {
                const std::size_t prev = (i + n - 1) % n;
                if (isNewCut[i] && !isNewCut[prev]) {
                    runStarts.push_back(i);
                }
            }
        }

        for (std::size_t runStart : runStarts) {
            std::vector<std::size_t> runEdges;
            std::size_t idx = runStart;
            for (std::size_t count = 0; count < n; ++count) {
                if (!isNewCut[idx]) {
                    break;
                }
                runEdges.push_back(idx);
                idx = (idx + 1) % n;
                if (idx == runStart) {
                    break; // Wrapped fully around -- only possible in the allNewCut case.
                }
            }
            if (runEdges.empty()) {
                continue;
            }

            // Flatten the run into cumulative-arc-length vertices, so a via's position can be found
            // by distance along the *whole run* regardless of which underlying edge that distance
            // falls in.
            struct RunVertex {
                double cumDist = 0;
                Clipper2Lib::Point64 point;
            };
            std::vector<RunVertex> vertices;
            vertices.reserve(runEdges.size() + 1);
            vertices.push_back({0.0, loop[runStart]});
            double cum = 0.0;
            for (std::size_t e : runEdges) {
                cum += segLens[e];
                vertices.push_back({cum, loop[(e + 1) % n]});
            }
            const double totalLength = cum;

            // Via center (post viaEdgeDistance inward offset) at a given arc-length distance along
            // this run -- the same interpolation the old fixed-step loop did inline, factored out so
            // the adaptive walk below can probe arbitrary distances while searching for the next
            // candidate.
            auto viaCenterAtArcLength = [&](double dist) -> std::pair<double, double> {
                std::size_t k = 0;
                while (k + 2 < vertices.size() && vertices[k + 1].cumDist < dist) {
                    ++k;
                }
                const RunVertex& v0 = vertices[k];
                const RunVertex& v1 = vertices[k + 1];
                const double vertexSegLen = v1.cumDist - v0.cumDist;
                const double t = vertexSegLen > 1e-6 ? (dist - v0.cumDist) / vertexSegLen : 0.0;
                const double edgeX = static_cast<double>(v0.point.x) + t * static_cast<double>(v1.point.x - v0.point.x);
                const double edgeY = static_cast<double>(v0.point.y) + t * static_cast<double>(v1.point.y - v0.point.y);
                // Inward normal (cutout's outer loops are wound so the interior is to the left of
                // each directed edge, per Clipper2's default orientation for positive-area outer
                // paths).
                const double dx = vertexSegLen > 1e-6 ? static_cast<double>(v1.point.x - v0.point.x) / vertexSegLen : 1.0;
                const double dy = vertexSegLen > 1e-6 ? static_cast<double>(v1.point.y - v0.point.y) / vertexSegLen : 0.0;
                return {edgeX - dy * sim.viaEdgeDistance(), edgeY + dx * sim.viaEdgeDistance()};
            };

            // Walk the run placing candidates spaced sim.viaSpacing() apart by *straight-line*
            // (crow-flies) distance between successive via centers, not by equal arc length -- on
            // any edge that isn't dead straight, the arc length between two points always exceeds
            // their straight-line distance, so stepping by a fixed arc length alone systematically
            // overshoots on curvature: consecutive candidates land closer together (as the crow
            // flies) than viaSpacing, and every other one then gets rejected by tooCloseToExistingVia
            // below -- "every second via never appears" on any edge that isn't perfectly straight.
            // Finds each next arc-length position with a simple secant-style correction: walk a
            // guessed distance, measure the shortfall between the resulting straight-line distance
            // and the target, and correct the walk by that shortfall (scaled by kViaWalkOvershoot so
            // it converges in a handful of iterations for a gently-curved edge rather than creeping
            // up on the target asymptotically); tooCloseToExistingVia below is still the actual
            // safety net if a tight curve keeps this from converging exactly.
            constexpr double kViaWalkOvershoot = 1.2;
            constexpr int kViaWalkMaxIterations = 20;
            const double viaWalkMinStep = std::max(sim.viaSpacing() * 0.01, kOnEdgeToleranceSimUnits);

            std::vector<double> candidateDists{0.0};
            {
                double curDist = 0.0;
                auto [curX, curY] = viaCenterAtArcLength(0.0);
                while (curDist < totalLength) {
                    // Search for the next arc-length position whose straight-line distance from
                    // (curX, curY) reaches sim.viaSpacing() -- NOT decided by comparing against the
                    // run's own endpoint up front: on a run that curves back near where it started
                    // (an arc hugging a rounded board corner, or the whole-loop case where the run's
                    // end literally coincides with its start), that chord can be far shorter than
                    // viaSpacing even though there's plenty of arc length still ahead to place vias
                    // along -- checking it early terminated the whole run after only one or two
                    // candidates instead of walking it properly.
                    double walk = std::min(totalLength - curDist, sim.viaSpacing() * kViaWalkOvershoot);
                    double dist = curDist;
                    double crow = 0.0;
                    bool converged = false;
                    for (int iter = 0; iter < kViaWalkMaxIterations; ++iter) {
                        dist = std::min(curDist + walk, totalLength);
                        const auto [x, y] = viaCenterAtArcLength(dist);
                        crow = std::hypot(x - curX, y - curY);
                        // A one-sided threshold, not "closest to the target": stop at the *first*
                        // walk whose straight-line distance reaches sim.viaSpacing(), never one that
                        // falls even slightly short of it. tooCloseToExistingVia() below rejects
                        // anything strictly closer than sim.viaSpacing() to the previous via -- and
                        // since this walk always continues from the last *computed* candidate
                        // regardless of whether it end up accepted (see the accept/reject loop
                        // below), a symmetric "closest approach" tolerance would let convergence land
                        // just under the target roughly half the time, get rejected, and then have
                        // the next candidate walk on from that same too-close point -- reproducing
                        // exactly the "every second via never appears" bug this whole loop exists to
                        // fix. Overshooting slightly is harmless; undershooting is not.
                        if (crow >= sim.viaSpacing()) {
                            converged = true;
                            break;
                        }
                        if (dist >= totalLength) {
                            break; // Can't walk any further even though we haven't converged.
                        }
                        const double error = sim.viaSpacing() - crow;
                        walk = std::max(walk + error * kViaWalkOvershoot, viaWalkMinStep);
                    }
                    if (!converged && dist >= totalLength) {
                        // Ran out of run before reaching a full viaSpacing crow-flies distance --
                        // take the run's own end as one last candidate if it's a meaningfully
                        // different point, then stop.
                        if (crow > viaWalkMinStep) {
                            candidateDists.push_back(totalLength);
                        }
                        break;
                    }
                    candidateDists.push_back(dist);
                    curDist = dist;
                    std::tie(curX, curY) = viaCenterAtArcLength(curDist);
                }
            }

            const std::size_t stitchingViasBeforeRun = stitchingVias.size();
            for (const double dist : candidateDists) {
                const auto [viaXRaw, viaYRaw] = viaCenterAtArcLength(dist);
                const Clipper2Lib::Point64 viaPos(static_cast<std::int64_t>(std::llround(viaXRaw)),
                                                    static_cast<std::int64_t>(std::llround(viaYRaw)));

                const double viaX = static_cast<double>(viaPos.x);
                const double viaY = static_cast<double>(viaPos.y);
                const bool onAnyGroundLayer = std::any_of(groundPerLayer.begin(), groundPerLayer.end(),
                                                            [&](const Clipper2Lib::Paths64& ground) {
                                                                return _pointInComposite(viaPos, ground);
                                                            });
                if (!onAnyGroundLayer) {
                    failedStitchingViaAttempts.emplace_back(viaX, viaY);
                    ++diagNoGroundCopperCount;
                    continue; // No ground copper here to stitch to -- skip rather than place a
                              // floating via.
                }
                if (tooCloseToExistingVia(viaX, viaY)) {
                    failedStitchingViaAttempts.emplace_back(viaX, viaY);
                    ++diagTooCloseCount;
                    continue;
                }
                stitchingVias.push_back(StitchingVia{viaX, viaY, config.via().stitchingViaHoleDiameter(),
                                                       config.via().stitchingViaAnnularRingDiameter()});
                existingVias.push_back({viaX, viaY, candidateRadius, true});
            }
            // Every candidate along this run got rejected (no ground copper there, or too close to
            // another via) -- this cut edge is left with no return-path connection at all, i.e. a
            // floating plane segment. Physically, a plane segment that's
            // only reconnected by sparse stitching vias (or not reconnected at all) behaves like a
            // slot/comb resonator: it can trap energy near-field rather than letting it radiate or
            // dissipate, which shows up as the FDTD's total domain energy plateauing instead of
            // decaying toward the end criteria. Warned rather than failed outright, since a
            // genuinely tiny cut edge with nowhere valid to stitch may be harmless -- but a long run
            // with zero vias is worth a user's attention.
            if (stitchingVias.size() == stitchingViasBeforeRun) {
                logWarning("Simulation \"" + sim.name() + "\": a " + std::to_string(totalLength / constants::unitMultiplier) +
                           " um cut edge of the ground/power plane got no stitching vias at all (every "
                           "candidate position was rejected) -- this leaves that plane segment "
                           "electrically floating, which can trap energy and prevent FDTD convergence. "
                           "Consider a smaller via, tighter via_spacing, or more hull_padding so the cut "
                           "falls somewhere with room to stitch.");
            }
        }
    }

    // Non-plated through-holes (mechanical/alignment holes -- e.g. a USB connector's elongated
    // mounting slots) have no copper of their own anywhere and never appear in any copper Gerber at
    // all, so nothing upstream already carves them out of a zone/plane pour that happens to cover
    // that area the way it would for a real pad or trace -- they have to be explicitly subtracted
    // from every layer's final copper below. Modeled as capsule/stadium shapes (round-jointed
    // InflatePaths of the hole's own two endpoints, same technique _strokeToPaths uses for a
    // circular-aperture stroke) so an elongated slot comes out as an actual elongated cutout, not
    // just a hole at its center point. Best-effort: if the drill file can't be read, the board just
    // doesn't get these holes cut (as if this feature didn't exist), rather than failing the whole
    // slice over it.
    Clipper2Lib::Paths64 npthHolePolygons;
    if (auto npthHoles = getNPTHHoles(paths, origin.xMin, origin.yMin); npthHoles) {
        for (const NPTHHole& hole : *npthHoles) {
            const Clipper2Lib::Path64 line =
                _positionsToPath64({Position(hole.x1, hole.y1), Position(hole.x2, hole.y2)}, 0, 0);
            const Clipper2Lib::Paths64 capsule =
                Clipper2Lib::InflatePaths({line}, hole.diameter / 2.0, Clipper2Lib::JoinType::Round,
                                            Clipper2Lib::EndType::Round, 2.0, tessellationTolerance);
            npthHolePolygons.insert(npthHolePolygons.end(), capsule.begin(), capsule.end());
        }
    }

    // Every via's own drilled hole (real board vias and the stitching vias just placed above alike),
    // as an already-tessellated capsule/stadium polygon loop -- the same InflatePaths-of-the-
    // centerline technique npthHolePolygons above uses, just at each via's own hole diameter rather
    // than an NPTHHole's. Cut out of *every* metal layer's own final copper below, matching the
    // simplifying assumption already in force everywhere else a via is modeled in this codebase (both
    // the real FDTD geometry -- Simulation::addVia() always extrudes its own via metal/filling boxes
    // the *entire* substrate stack height, regardless of which layers a via is actually connected to
    // -- and this same preview's own via markers, which never carried a per-layer connectivity list
    // either): a via reaches every layer, full stop, no blind/buried distinction anywhere upstream
    // (ViaHole/StitchingVia carry no such data to derive one from even if this wanted to).
    //
    // Harmless for the *real* FDTD geometry despite changing what layerTriangles itself contains:
    // Simulation::addVia() places its own via metal/filling material at CSXCAD priority 50/51, well
    // above the copper Gerber's own priority 1 (see simulation.cpp's own comment there) -- CSXCAD
    // resolves overlapping primitives by highest priority wins, so removing the now-redundant copper
    // underneath a via's own hole changes nothing about the resolved simulated fields, only what a
    // *previewer* (with no such priority system, just real depth-tested triangles) sees where a via's
    // own barrel/annular-ring geometry needs an actual absence of flat copper to sit correctly in 3D.
    Clipper2Lib::Paths64 viaHolePolygons;
    for (const ViaHole& via : realViasForHoleCutting) {
        const Clipper2Lib::Path64 line =
            _positionsToPath64({Position(via.x, via.y), Position(via.x2, via.y2)}, 0, 0);
        const Clipper2Lib::Paths64 capsule =
            Clipper2Lib::InflatePaths({line}, via.diameter / 2.0, Clipper2Lib::JoinType::Round,
                                        Clipper2Lib::EndType::Round, 2.0, tessellationTolerance);
        viaHolePolygons.insert(viaHolePolygons.end(), capsule.begin(), capsule.end());
    }
    for (const StitchingVia& via : stitchingVias) {
        const Clipper2Lib::Path64 line = _positionsToPath64({Position(via.x, via.y), Position(via.x, via.y)}, 0, 0);
        const Clipper2Lib::Paths64 capsule =
            Clipper2Lib::InflatePaths({line}, via.diameter / 2.0, Clipper2Lib::JoinType::Round,
                                        Clipper2Lib::EndType::Round, 2.0, tessellationTolerance);
        viaHolePolygons.insert(viaHolePolygons.end(), capsule.begin(), capsule.end());
    }

    // Final per-layer copper: involved-net composite (already inside the cutout by construction)
    // union ground-net composite intersected with the cutout. layerTriangles (fed to the real FDTD
    // geometry) deliberately skips the NPTH/via hole subtraction -- see its own doc comment for why
    // that's redundant there (both already get correctly overridden by higher-priority CSXCAD
    // primitives regardless) and measurably expensive (many extra small triangle primitives, each
    // checked at every quarter-cell query across the whole mesh during real FDTD setup).
    // previewLayerTriangles is the same copper with those holes cut, computed as a second, separate
    // triangulation purely for GeometryPreviewBridge's own rendering.
    SlicedBoard result;
    result.layerTriangles.resize(metals.size());
    result.previewLayerTriangles.resize(metals.size());
    for (std::size_t layerIndex = 0; layerIndex < metals.size(); ++layerIndex) {
        const Clipper2Lib::Paths64 groundInCutout =
            Clipper2Lib::Intersect(groundPerLayer[layerIndex], cutout, Clipper2Lib::FillRule::NonZero);
        const Clipper2Lib::Paths64 finalLayer =
            Clipper2Lib::Union(signalPerLayer[layerIndex], groundInCutout, Clipper2Lib::FillRule::NonZero);
        result.layerTriangles[layerIndex] =
            triangulate(finalLayer, tessellationTolerance, "simulation \"" + sim.name() + "\" layer " + std::to_string(layerIndex));

        Clipper2Lib::Paths64 previewLayer = finalLayer;
        if (!npthHolePolygons.empty()) {
            previewLayer = Clipper2Lib::Difference(previewLayer, npthHolePolygons, Clipper2Lib::FillRule::NonZero);
        }
        if (!viaHolePolygons.empty()) {
            previewLayer = Clipper2Lib::Difference(previewLayer, viaHolePolygons, Clipper2Lib::FillRule::NonZero);
        }
        result.previewLayerTriangles[layerIndex] = triangulate(
            previewLayer, tessellationTolerance, "simulation \"" + sim.name() + "\" layer " + std::to_string(layerIndex) + " (preview)");
    }

    // Solder mask: F_Mask.gbr/B_Mask.gbr draw the board's own copper-exposure openings, not the
    // mask's own covering shape -- confirmed by inspecting a real export, these files carry
    // %TF.FilePolarity,Negative% and their drawn shapes are pad/via-shaped cutouts, not the mask
    // itself. Produces two representations of the same mask (see SlicedBoard::topMaskTriangles'
    // own doc comment for why): the raw opening loops (cropped to this simulation's own cutout
    // region, same as every other per-simulation layer here) for Simulation::addSolderMask() to
    // punch a small number of cutouts out of one big coverage box; and, only for
    // GeometryPreviewBridge's benefit, the full triangulated "coverage minus openings" shape,
    // computed the same Difference()-then-triangulate() way copper-minus-holes is just above.
    // Gracefully empty (not an error) if the board has no mask gerbers exported, or a mask layer
    // parses to zero draws (no pads on this side at all, however unlikely).
    auto maskForFile = [&](const std::string& fileName, std::vector<Triangle>& outTriangles,
                            std::vector<std::vector<Position>>& outOpeningLoops) {
        const std::optional<std::filesystem::path> maskPath = _copperGerberForFileName(paths.fabDir, fileName);
        if (!maskPath.has_value()) {
            return;
        }
        auto maskGerberResult = GerberFile::load(*maskPath, tessellationTolerance);
        if (!maskGerberResult) {
            logWarning("Simulation \"" + sim.name() + "\": failed to load solder mask gerber " +
                       maskPath->string() + ": " + maskGerberResult.error() + " -- solder mask not modeled");
            return;
        }
        const Clipper2Lib::Paths64 openingsWholeBoard = compositeOps(
            *maskGerberResult, maskGerberResult->copperOps(), origin.xMin, origin.yMin, tessellationTolerance);
        if (openingsWholeBoard.empty()) {
            outTriangles = triangulate(cutout, tessellationTolerance, "simulation \"" + sim.name() + "\" solder mask " + fileName);
            return;
        }
        const Clipper2Lib::Paths64 openings =
            Clipper2Lib::Intersect(openingsWholeBoard, cutout, Clipper2Lib::FillRule::NonZero);
        for (const Clipper2Lib::Path64& loop : openings) {
            outOpeningLoops.push_back(_path64ToPositions(loop));
        }
        const Clipper2Lib::Paths64 coverage = Clipper2Lib::Difference(cutout, openings, Clipper2Lib::FillRule::NonZero);
        outTriangles = triangulate(coverage, tessellationTolerance, "simulation \"" + sim.name() + "\" solder mask " + fileName);
    };
    maskForFile("F_Mask", result.topMaskTriangles, result.topMaskOpeningLoops);
    maskForFile("B_Mask", result.bottomMaskTriangles, result.bottomMaskOpeningLoops);

    // Kept (as already-tessellated polygon loops, not raw NPTHHoles) so Simulation::addNPTHHoles()
    // can also cut these out of the substrate model -- the copper subtraction above only affects
    // copper that happened to exist there, but a real drilled hole removes the dielectric too,
    // regardless of whether any layer had copper at that exact spot.
    for (const Clipper2Lib::Path64& loop : npthHolePolygons) {
        result.npthHoleLoops.push_back(_path64ToPositions(loop));
    }

    // Board outline consumers (Simulation::addSubstrates()) expect a single closed polygon loop --
    // if slicing produced more than one disjoint outer region (a broad, spatially-split net class,
    // say), take only the largest by area rather than concatenating them into one bogus loop.
    const Clipper2Lib::Path64* largestOuter = nullptr;
    double largestArea = 0;
    for (const Clipper2Lib::Path64& loop : cutout) {
        const double area = Clipper2Lib::Area(loop);
        if (area > largestArea) {
            largestArea = area;
            largestOuter = &loop;
        }
    }
    if (largestOuter == nullptr) {
        return std::unexpected("Simulation \"" + sim.name() + "\": cutout region has no outer loop");
    }

    double xMin = std::numeric_limits<double>::infinity();
    double xMax = -std::numeric_limits<double>::infinity();
    double yMin = std::numeric_limits<double>::infinity();
    double yMax = -std::numeric_limits<double>::infinity();
    for (const Position& p : _path64ToPositions(*largestOuter)) {
        result.outline.push_back(p);
        xMin = std::min(xMin, p.x());
        xMax = std::max(xMax, p.x());
        yMin = std::min(yMin, p.y());
        yMax = std::max(yMax, p.y());
    }
    result.xMin = xMin;
    result.yMin = yMin;
    result.width = xMax - xMin;
    result.height = yMax - yMin;
    result.stitchingVias = std::move(stitchingVias);
    result.failedStitchingViaAttempts = std::move(failedStitchingViaAttempts);

    logInfo("Simulation \"" + sim.name() + "\": sliced board to " + std::to_string(result.width) + "x" +
             std::to_string(result.height) + " sim units, " + std::to_string(result.stitchingVias.size()) +
             " stitching via(s), " + std::to_string(result.failedStitchingViaAttempts.size()) +
             " failed attempt(s) [DIAG: " + std::to_string(diagNoGroundCopperCount) + " no-ground-copper, " +
             std::to_string(diagTooCloseCount) + " too-close-to-existing-via]");
    return result;
}

} // namespace gerber2ems
