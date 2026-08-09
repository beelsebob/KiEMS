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
Clipper2Lib::Path64 _realBoardOutline(double originX, double originY) {
    const std::filesystem::path fabDir = std::filesystem::current_path() / "fab";
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
        logError("No EdgeCuts gerber in fab dir(" + fabDir.string() + ")");
        std::exit(1);
    }
    auto edgeCutsResult = GerberFile::load(*edgeCutsPath);
    if (!edgeCutsResult) {
        logError(edgeCutsResult.error());
        std::exit(1);
    }
    const GerberFile& edgeCuts = *edgeCutsResult;
    const std::vector<Position> loop = _chainSegmentsIntoLoop(edgeCuts.traceForNet("no-net").segments());
    if (loop.size() < 3) {
        logError("Edge_Cuts outline has fewer than 3 points");
        std::exit(1);
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

std::vector<CopperOp> _opsOnNets(const GerberFile& gerber, const std::unordered_set<std::string>& nets) {
    std::vector<CopperOp> filtered;
    for (const CopperOp& op : gerber.copperOps()) {
        if (nets.count(op.net) != 0) {
            filtered.push_back(op);
        }
    }
    return filtered;
}

std::optional<std::filesystem::path> _copperGerberForFileName(const std::string& layerFileName) {
    const std::filesystem::path fabDir = std::filesystem::current_path() / "fab";
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

SlicedBoard sliceBoardForSimulation(const SimulationConfig& sim) {
    std::unordered_set<std::string> involvedNets;
    for (const InvolvedNetConfig& entry : sim.involvedNets()) {
        for (const std::string& net : libkicad_query::resolveInvolvedNetNames(entry)) {
            involvedNets.insert(net);
        }
    }
    std::unordered_set<std::string> groundNets;
    for (const std::string& net : libkicad_query::resolveGroundNetNames(sim.groundNet())) {
        groundNets.insert(net);
    }

    const BoundingBox origin = edgeCutsBoundingBox();
    const double tessellationTolerance =
        static_cast<double>(Config::sharedConfig().pixelSize()) * constants::unitMultiplier;
    const std::vector<LayerConfig> metals = Config::sharedConfig().getMetals();

    // Per layer: the involved-net and ground-net composites (pre-cutout), and the GerberFile they
    // came from (kept alive for _opsOnNets' aperture lookups during compositing).
    std::vector<Clipper2Lib::Paths64> signalPerLayer(metals.size());
    std::vector<Clipper2Lib::Paths64> groundPerLayer(metals.size());

    Clipper2Lib::Paths64 signalUnionAllLayers;
    for (std::size_t layerIndex = 0; layerIndex < metals.size(); ++layerIndex) {
        const std::optional<std::filesystem::path> gerberPath = _copperGerberForFileName(metals[layerIndex].file());
        if (!gerberPath.has_value()) {
            continue; // No copper on this layer at all.
        }
        auto gerberResult = GerberFile::load(*gerberPath);
        if (!gerberResult) {
            logError(gerberResult.error());
            std::exit(1);
        }
        const GerberFile& gerber = *gerberResult;

        signalPerLayer[layerIndex] =
            compositeOps(gerber, _opsOnNets(gerber, involvedNets), origin.xMin, origin.yMin, tessellationTolerance);
        groundPerLayer[layerIndex] =
            compositeOps(gerber, _opsOnNets(gerber, groundNets), origin.xMin, origin.yMin, tessellationTolerance);

        signalUnionAllLayers = Clipper2Lib::Union(signalUnionAllLayers, signalPerLayer[layerIndex],
                                                    Clipper2Lib::FillRule::NonZero);
    }

    if (signalUnionAllLayers.empty()) {
        logError("Simulation \"" + sim.name() + "\": involved nets have no copper on any layer");
        std::exit(1);
    }

    // Cutout region: involved-net footprint padded by hull_padding, clipped to the real board
    // outline (see board_slicing.hpp's algorithm doc comment -- this stands in for a true concave
    // hull/alpha-shape, which isn't implemented here).
    const Clipper2Lib::Path64 realOutline = _realBoardOutline(origin.xMin, origin.yMin);
    const Clipper2Lib::Paths64 padded =
        Clipper2Lib::InflatePaths(signalUnionAllLayers, sim.hullPadding(), Clipper2Lib::JoinType::Round,
                                    Clipper2Lib::EndType::Polygon, 2.0, tessellationTolerance);
    const Clipper2Lib::Paths64 cutout =
        Clipper2Lib::Intersect(padded, {realOutline}, Clipper2Lib::FillRule::NonZero);
    if (cutout.empty()) {
        logError("Simulation \"" + sim.name() + "\": computed cutout region is empty");
        std::exit(1);
    }

    // Stitching vias: walk every outer boundary loop of the cutout, classify each edge against the
    // real board outline (on/near it -> pre-existing, no stitching needed there), and place vias
    // along new-cut edges only.
    std::vector<StitchingVia> stitchingVias;
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

        for (std::size_t i = 0; i < loop.size(); ++i) {
            const Clipper2Lib::Point64& a = loop[i];
            const Clipper2Lib::Point64& b = loop[(i + 1) % loop.size()];
            const double segLen = std::hypot(static_cast<double>(b.x - a.x), static_cast<double>(b.y - a.y));
            if (segLen < 1.0) {
                continue;
            }

            const Clipper2Lib::Point64 midpoint((a.x + b.x) / 2, (a.y + b.y) / 2);
            if (_distancePointToPolyline(midpoint, realOutline) <= kOnEdgeToleranceSimUnits) {
                continue; // Coincides with the real board edge -- not a new cut.
            }

            // Inward normal (cutout's outer loops are wound so the interior is to the left of each
            // directed edge, per Clipper2's default orientation for positive-area outer paths).
            const double dx = static_cast<double>(b.x - a.x) / segLen;
            const double dy = static_cast<double>(b.y - a.y) / segLen;
            const double inwardX = -dy;
            const double inwardY = dx;

            const auto stepCount = static_cast<std::size_t>(std::max(1.0, std::floor(segLen / sim.viaSpacing())));
            for (std::size_t step = 0; step <= stepCount; ++step) {
                const double t = static_cast<double>(step) / static_cast<double>(stepCount);
                const double edgeX = static_cast<double>(a.x) + t * static_cast<double>(b.x - a.x);
                const double edgeY = static_cast<double>(a.y) + t * static_cast<double>(b.y - a.y);
                const Clipper2Lib::Point64 viaPos(
                    static_cast<std::int64_t>(std::llround(edgeX + inwardX * sim.viaEdgeDistance())),
                    static_cast<std::int64_t>(std::llround(edgeY + inwardY * sim.viaEdgeDistance())));

                const bool onAnyGroundLayer = std::any_of(groundPerLayer.begin(), groundPerLayer.end(),
                                                            [&](const Clipper2Lib::Paths64& ground) {
                                                                return _pointInComposite(viaPos, ground);
                                                            });
                if (!onAnyGroundLayer) {
                    continue; // No ground copper here to stitch to -- skip rather than place a
                              // floating via.
                }
                stitchingVias.push_back(StitchingVia{static_cast<double>(viaPos.x), static_cast<double>(viaPos.y),
                                                       Config::sharedConfig().via().platingThickness()});
            }
        }
    }

    // Final per-layer copper: involved-net composite (already inside the cutout by construction)
    // union ground-net composite intersected with the cutout.
    SlicedBoard result;
    result.layerTriangles.resize(metals.size());
    for (std::size_t layerIndex = 0; layerIndex < metals.size(); ++layerIndex) {
        const Clipper2Lib::Paths64 groundInCutout =
            Clipper2Lib::Intersect(groundPerLayer[layerIndex], cutout, Clipper2Lib::FillRule::NonZero);
        const Clipper2Lib::Paths64 finalLayer =
            Clipper2Lib::Union(signalPerLayer[layerIndex], groundInCutout, Clipper2Lib::FillRule::NonZero);
        result.layerTriangles[layerIndex] =
            triangulate(finalLayer, tessellationTolerance, "simulation \"" + sim.name() + "\" layer " + std::to_string(layerIndex));
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
        logError("Simulation \"" + sim.name() + "\": cutout region has no outer loop");
        std::exit(1);
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

    logInfo("Simulation \"" + sim.name() + "\": sliced board to " + std::to_string(result.width) + "x" +
             std::to_string(result.height) + " sim units, " + std::to_string(result.stitchingVias.size()) +
             " stitching via(s)");
    return result;
}

} // namespace gerber2ems
