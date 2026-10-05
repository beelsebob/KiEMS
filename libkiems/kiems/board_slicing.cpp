#include "board_slicing.hpp"

#include <algorithm>
#include <stdexcept>
#if defined(__APPLE__)
#include <dispatch/dispatch.h>
#endif
#include <cmath>
#include <unordered_set>

#include "config.hpp"
#include "constants.hpp"
#include "../../libkicad/libkicad.hpp"
#include "logging.hpp"
#include "polygon_geometry.hpp"
#include "via_stitching.hpp"

namespace kiems {

using namespace Cu;

namespace {

double _mmToSimUnits(double mm) {
    return mm / 1000.0 / constants::baseUnit * static_cast<double>(constants::unitMultiplier);
}

Polygon _polygonLoopToPolygon(const libkicad::PolygonLoop& loop, double originX, double originY) {
    Polygon path;
    path.reserve(loop.pointsMm.size());
    for (const auto& [xMm, yMm] : loop.pointsMm) {
        path.emplace_back(_mmToSimUnits(xMm) - originX, _mmToSimUnits(yMm) - originY);
    }
    const bool shouldBePositive = !loop.hole;
    if (path.size() >= 3 && isPositive(path) != shouldBePositive) {
        std::reverse(path.begin(), path.end());
    }
    return path;
}

PolygonSet _polygonLoopsToPolygons(const std::vector<libkicad::PolygonLoop>& loops, double originX, double originY) {
    PolygonSet paths;
    paths.reserve(loops.size());
    for (const libkicad::PolygonLoop& loop : loops) {
        Polygon path = _polygonLoopToPolygon(loop, originX, originY);
        if (path.size() >= 3) {
            paths.push_back(std::move(path));
        }
    }
    return paths;
}

/// Runs body(0..count-1) concurrently on Apple platforms, serially elsewhere.
template <typename Body>
void parallelFor(std::size_t count, const Body& body) {
#if defined(__APPLE__)
    dispatch_apply_f(count, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), const_cast<Body*>(&body),
                     [](void* context, std::size_t i) { (*static_cast<const Body*>(context))(i); });
#else
    for (std::size_t i = 0; i < count; ++i) body(i);
#endif
}

PolygonSet _copperOnLayer(const std::vector<libkicad::CopperPolygon>& polygons, const std::string& layerName,
                          double originX, double originY) {
    PolygonSet paths;
    for (const libkicad::CopperPolygon& polygon : polygons) {
        if (polygon.copperLayerName != layerName) {
            continue;
        }
        Polygon path = _polygonLoopToPolygon(polygon.loop, originX, originY);
        if (path.size() >= 3) {
            paths.push_back(std::move(path));
        }
    }
    return unionPolygons(paths);
}

/// Tessellates every hole in `holes` into its own capsule/stadium polygon using a round buffer at
/// radius diameter/2, round-jointed/round-ended so an elongated
/// (start != end) hole comes out as an actual elongated cutout rather than a hole only at its
/// center point -- concatenated into one polygon set. `HoleT` is any of NPTHHole/ViaHole (real Hole
/// subclasses) or StitchingVia (which only shares Hole's path()/diameter shape -- see its own doc
/// comment, board_slicing.hpp, for why it isn't one); this template is what lets all three share one
/// implementation despite that.
template <typename HoleT>
PolygonSet tessellateHoles(const std::vector<HoleT>& holes, double tessellationTolerance) {
    PolygonSet result;
    for (const HoleT& hole : holes) {
        const PolygonSet capsule = bufferOpenPaths({hole.path()}, hole.diameter / 2.0, tessellationTolerance);
        result.insert(result.end(), capsule.begin(), capsule.end());
    }
    return result;
}

struct PreparedLayer {
    PolygonSet finalLayer;
    PolygonSet previewLayer;
};

/// Completes the Boolean work for one metal layer, leaving both polygon sets ready for the later,
/// separately-progressed triangulation phase. The real FDTD version deliberately keeps via/NPTH
/// holes; the preview version cuts them out (see SlicedBoard's field documentation).
PreparedLayer prepareLayer(const PolygonSet& signal, const PolygonSet& geometryOnly,
                           const PolygonSet& ground, const PolygonSet& cutout,
                           const PolygonSet& npthHolePolygons,
                           const PolygonSet& viaHolePolygons) {
    const PolygonSet geometryOnlyInCutout = intersectPolygons(geometryOnly, cutout);
    const PolygonSet groundInCutout = intersectPolygons(ground, cutout);
    // These operands have each already been composited. Do not flatten their loops and feed them
    // back through the raw-input union: a net may deliberately occur in more than one bucket (GND
    // is commonly both geometry-only and the selected ground net), and duplicate outer shells can
    // then steal one another's clockwise clearance holes. On the TestSim Upstream/SS CTx1 board,
    // crossing 12.0 -> 12.1 mm padding made that ambiguity fill the ground-plane clearances and
    // merge most top-layer signal islands into ground at once.
    PolygonSet finalLayer = unionCompositedPolygons({signal, geometryOnlyInCutout, groundInCutout});
    PolygonSet previewLayer = differencePolygons(finalLayer, npthHolePolygons);
    previewLayer = differencePolygons(previewLayer, viaHolePolygons);
    return {std::move(finalLayer), std::move(previewLayer)};
}

struct PreparedMask {
    PolygonSet coverage;
    std::vector<std::vector<Position>> openingLoops;
};

/// Solder mask geometry from KiCad is the board's copper-exposure openings, not the mask's own
/// covering shape. Prepares two representations of the same mask (see
/// SlicedBoard::topMaskTriangles' own doc comment for why): cropped raw opening loops for the
/// simulation, and the full "coverage minus openings" polygon set for the later triangulation phase.
/// `sourceLoops` is the board's own frontMaskOpenings/backMaskOpenings (mm, whole-board frame);
/// `layerName` names the side for triangulate()'s own error context (e.g. "F.Mask").
PreparedMask prepareMask(const std::vector<libkicad::PolygonLoop>& sourceLoops, const std::string& layerName,
                         const PolygonSet& cutout, const PolygonSet& copperInCutout,
                         double originX, double originY) {
    PreparedMask result;
    const PolygonSet rawOpenings = _polygonLoopsToPolygons(sourceLoops, originX, originY);
    // KiCad's own ConvertBrdLayerToPolygonalContours() (libkicad.cpp) already produced a clean,
    // simple polygon per opening -- the same result the KiCad editor itself renders correctly. If
    // any one of them is self-intersecting *here*, that self-intersection was introduced by our own
    // coordinate conversion in _polygonLoopToPolygon above, not by KiCad -- and a self-intersecting
    // input can make the Union() below silently drop or mangle that one opening (observed on a real
    // board: a whole pad's worth of mask stayed uncut, exactly where a bogus wedge-shaped sliver then
    // appeared in the final coverage difference). Checking every individual loop before it ever
    // reaches Union() pins that down directly rather than debugging the union/difference output.
    for (std::size_t i = 0; i < rawOpenings.size(); ++i) {
        if (const auto hit = findSelfIntersection(rawOpenings[i])) {
            const auto& [a, b] = *hit;
            const auto& poly = rawOpenings[i];
            logWarning("solder mask " + layerName + ": opening loop " + std::to_string(i) + " (" +
                       std::to_string(poly.size()) + " vertices) is self-intersecting after mm->sim-unit "
                       "conversion: edge " + std::to_string(a) + " (" + std::to_string(poly[a].x()) + "," +
                       std::to_string(poly[a].y()) + ")-(" + std::to_string(poly[(a + 1) % poly.size()].x()) + "," +
                       std::to_string(poly[(a + 1) % poly.size()].y()) + ") crosses edge " + std::to_string(b) +
                       " (" + std::to_string(poly[b].x()) + "," + std::to_string(poly[b].y()) + ")-(" +
                       std::to_string(poly[(b + 1) % poly.size()].x()) + "," +
                       std::to_string(poly[(b + 1) % poly.size()].y()) + ")");
        }
    }
    // Stage-by-stage loop count/area tracking -- rawOpenings is already confirmed clean (see the
    // self-intersection check above), so if a pad's opening goes missing from the final coverage, it
    // has to disappear at one of these three remaining steps. Logging area (not just loop count) at
    // each one distinguishes "lost entirely" (area drops) from "merged with a neighbor" (count drops,
    // area doesn't) -- the latter is normal NonZero-union behavior for touching/overlapping pads, not
    // a bug.
    const double rawOpeningsArea = std::abs(area(rawOpenings));
    const PolygonSet openingsWholeBoard = unionPolygons(rawOpenings);
    const double openingsWholeBoardArea = std::abs(area(openingsWholeBoard));
    logWarning("solder mask " + layerName + ": " + std::to_string(rawOpenings.size()) + " raw opening loop(s), area " +
             std::to_string(rawOpeningsArea) + " -> Union() produced " + std::to_string(openingsWholeBoard.size()) +
             " loop(s), area " + std::to_string(openingsWholeBoardArea));
    if (openingsWholeBoard.empty()) {
        result.coverage = cutout;
        return result;
    }
    const PolygonSet openings = intersectPolygons(openingsWholeBoard, cutout);
    const double openingsArea = std::abs(area(openings));
    const double cutoutArea = std::abs(area(cutout));
    logWarning("solder mask " + layerName + ": Intersect() with cutout (area " + std::to_string(cutoutArea) +
             ") produced " + std::to_string(openings.size()) + " opening loop(s), area " +
             std::to_string(openingsArea) + " (from " + std::to_string(openingsWholeBoard.size()) +
             " loop(s), area " + std::to_string(openingsWholeBoardArea) + " pre-crop)");
    // The aggregate area above balances (see Difference()'s own log line below), so nothing is being
    // lost in bulk. Two earlier versions of this check were both wrong: bbox-containment was a
    // worthless proxy against this cutout (a single non-convex 336-point polygon covering only ~26%
    // of its own bounding rectangle), and checking whether the *surviving* portion of a partially-
    // cropped opening overlaps copper is trivially true whenever copper and mask share a crop
    // boundary -- confirmed on real data: "kept" area and "overlaps copper" area matched exactly on
    // every candidate that check flagged, i.e. it was reporting consistent, correct cropping as if it
    // were a bug. The test that actually matters is the *dropped* portion (loop minus what Intersect()
    // kept): if that specific, discarded-by-design region overlaps copper that *did* survive the same
    // crop, this pad's copper renders but the mask never gets cut open over it -- a real inconsistency.
    // If the dropped mask region instead overlaps only copper that *also* got dropped, both sides are
    // being cropped identically and there's nothing wrong.
    if (!copperInCutout.empty()) {
        for (const Polygon& loop : openingsWholeBoard) {
            const PolygonSet dropped = differencePolygons({loop}, cutout);
            const double droppedArea = std::abs(area(dropped));
            if (droppedArea <= 0.0) {
                continue; // Nothing dropped -- this opening survived the crop intact.
            }
            const double droppedOverlapsSurvivingCopperArea =
                std::abs(area(intersectPolygons(dropped, copperInCutout)));
            if (droppedOverlapsSurvivingCopperArea <= 0.0) {
                continue; // The discarded part of this opening lines up with discarded copper -- consistent, not a bug.
            }
            const auto loopBounds = bounds(loop);
            std::string coords = "{";
            for (const auto& pt : loop) {
                coords += "{" + std::to_string(pt.x()) + "," + std::to_string(pt.y()) + "},";
            }
            coords += "}";
            logWarning("solder mask " + layerName + ": opening loop with bbox [" + std::to_string(loopBounds.xMin) +
                       "," + std::to_string(loopBounds.xMax) + "]x[" + std::to_string(loopBounds.yMin) + "," +
                       std::to_string(loopBounds.yMax) + "] has " + std::to_string(droppedArea) +
                       " of its area discarded by Intersect() with cutout, and " +
                       std::to_string(droppedOverlapsSurvivingCopperArea) +
                       " of that discarded part overlaps copper that DID survive the same crop -- this pad's "
                       "copper renders there but the mask never gets cut open over it. Vertices: " + coords);
        }
    }
    result.openingLoops = openings;
    result.coverage = differencePolygons(cutout, openings);
    const double coverageArea = std::abs(area(result.coverage));
    logWarning("solder mask " + layerName + ": Difference(cutout, openings) produced " +
             std::to_string(result.coverage.size()) + " region(s), area " + std::to_string(coverageArea) +
             " (expected roughly cutoutArea - openingsArea = " + std::to_string(cutoutArea - openingsArea) + ")");
    return result;
}

std::vector<Triangle> triangulateMask(const PreparedMask& mask, const std::string& layerName,
                                      double tessellationTolerance) {
    std::vector<Triangle> triangles =
        triangulate(mask.coverage, tessellationTolerance, "solder mask " + layerName);
    double triangleAreaSum = 0.0;
    for (const Triangle& tri : triangles) {
        triangleAreaSum += std::abs((tri.b.x() - tri.a.x()) * (tri.c.y() - tri.a.y()) -
                                    (tri.c.x() - tri.a.x()) * (tri.b.y() - tri.a.y())) / 2.0;
    }
    logWarning("solder mask " + layerName + ": triangulation produced " + std::to_string(triangles.size()) +
               " triangle(s) summing to area " + std::to_string(triangleAreaSum) + " (coverage's own area is " +
               std::to_string(std::abs(area(mask.coverage))) + ")");
    return triangles;
}

} // namespace

SlicingConfig SlicingConfig::from(const SimulationConfig& sim, const EMSConfig& config) {
    std::vector<std::string> layerNames;
    for (const LayerConfig& layer : config.getMetals()) {
        layerNames.push_back(layer.name());
    }
    return SlicingConfig{
        .viaEdgeDistance = sim.viaEdgeDistance(),
        .viaSpacing = sim.viaSpacing(),
        .platingThickness = config.via().platingThickness(),
        .stitchingViaHoleDiameter = config.via().stitchingViaHoleDiameter(),
        .stitchingViaAnnularRingDiameter = config.via().stitchingViaAnnularRingDiameter(),
        .viaClearance = config.via().viaClearance(),
        .pixelSize = config.pixelSize(),
        .layerNames = std::move(layerNames),
        .edgeTerminatedNets = sim.edgeTerminatedNets(),
        .edgeTerminationWidth = config.grid().max(),
    };
}

std::expected<std::vector<std::string>, std::string> resolveInvolvedNetNames(
    const libkicad::Board& board, const InvolvedNetConfig& entry) {
    switch (entry.kind()) {
        case NetSelectorKind::Net:
            return std::vector<std::string>{*entry.net()};
        case NetSelectorKind::NetClass:
            return board.netsInNetClass(*entry.netClass());
        case NetSelectorKind::FootprintPin: {
            std::vector<std::string> nets;
            for (const std::string& pin : entry.pins()) {
                auto net = board.netForFootprintPin(*entry.footprint(), pin);
                if (!net) return std::unexpected(std::move(net).error());
                if (std::find(nets.begin(), nets.end(), *net) == nets.end()) {
                    nets.push_back(std::move(*net));
                }
            }
            return nets;
        }
    }
    return std::vector<std::string>{};
}

std::expected<std::vector<std::string>, std::string> resolveGroundNetNames(
    const libkicad::Board& board, const GroundNetConfig& ground) {
    switch (ground.kind()) {
        case GroundSelectorKind::Net:
            return std::vector<std::string>{*ground.net()};
        case GroundSelectorKind::NetClass:
            return board.netsInNetClass(*ground.netClass());
    }
    return std::vector<std::string>{};
}

std::expected<BoundingBox<double>, std::string> boardBoundsInSimulationUnits(
    const libkicad::BoardGeometry& geometry) {
    auto mm = libkicad::boardBounds(geometry);
    if (!mm) return std::unexpected(std::move(mm).error());
    BoundingBox<double> result;
    result.xMin = _mmToSimUnits(mm->xMinMm);
    result.xMax = _mmToSimUnits(mm->xMaxMm);
    result.yMin = _mmToSimUnits(mm->yMinMm);
    result.yMax = _mmToSimUnits(mm->yMaxMm);
    return result;
}

std::expected<ClassifiedCopper, std::string> classifyCopperForSimulation(const SimulationConfig& sim,
                                                                           const libkicad::BoardGeometry& geometry,
                                                                           const libkicad::Board& board) {
    std::unordered_set<NetName, NetNameHash> involvedNets;
    std::unordered_set<NetName, NetNameHash> geometryOnlyNets;
    std::vector<std::pair<std::unordered_set<NetName, NetNameHash>, double>> hullSelectors;
    for (const InvolvedNetConfig& entry : sim.involvedNets()) {
        auto nets = resolveInvolvedNetNames(board, entry);
        if (!nets) return std::unexpected(std::move(nets).error());
        auto& target = entry.inclusionLevel() == NetInclusionLevel::GeometryOnly ? geometryOnlyNets : involvedNets;
        std::unordered_set<NetName, NetNameHash> selectorNets;
        for (const std::string& net : *nets) {
            target.insert(NetName(net));
            selectorNets.insert(NetName(net));
        }
        if (entry.inclusionLevel() == NetInclusionLevel::SimulationNet) {
            hullSelectors.emplace_back(std::move(selectorNets), entry.hullPadding());
        }
    }
    std::unordered_set<NetName, NetNameHash> groundNets;
    {
        auto nets = resolveGroundNetNames(board, sim.groundNet());
        if (!nets) return std::unexpected(std::move(nets).error());
        for (const std::string& net : *nets) {
            groundNets.insert(NetName(net));
        }
    }

    ClassifiedCopper result;
    result.hullContributions.resize(hullSelectors.size());
    for (std::size_t index = 0; index < hullSelectors.size(); ++index) {
        result.hullContributions[index].padding = hullSelectors[index].second;
    }
    for (const libkicad::CopperPolygon& polygon : geometry.copper) {
        const NetName net(polygon.netName);
        if (involvedNets.count(net) != 0) {
            result.involved.push_back(polygon);
        }
        if (geometryOnlyNets.count(net) != 0) {
            result.geometryOnly.push_back(polygon);
        }
        if (groundNets.count(net) != 0) {
            result.ground.push_back(polygon);
        }
        for (std::size_t index = 0; index < hullSelectors.size(); ++index) {
            if (hullSelectors[index].first.count(net) != 0) {
                result.hullContributions[index].copper.push_back(polygon);
            }
        }
    }
    return result;
}

namespace {

/// Everything steps 1, 2 and 4 of sliceBoardForSimulation() produce -- shared verbatim by that
/// function and planSlicedBoardForSimulation(), so the setup screen's plan can never disagree with
/// the geometry stage about where the cut or the stitching vias fall.
struct CutoutStage {
    BoundingBox<double> origin;
    double tessellationTolerance = 0;
    std::vector<PolygonSet> signalPerLayer;
    std::vector<PolygonSet> groundPerLayer;
    PolygonSet cutout;
    StitchingViaPlacement stitching;
};

std::expected<CutoutStage, std::string> computeCutoutStage(
    const SlicingConfig& slicing, const libkicad::BoardGeometry& geometry,
    const std::vector<libkicad::CopperPolygon>& involvedCopper,
    const std::vector<libkicad::CopperPolygon>& groundCopper,
    const std::vector<ClassifiedCopper::HullContribution>& hullContributions,
    const std::vector<ViaHole>& existingVias, const std::function<void()>& polygonPrimitiveDone) {
    CutoutStage stage;
    stage.tessellationTolerance = static_cast<double>(slicing.pixelSize) * constants::unitMultiplier;
    const double tessellationTolerance = stage.tessellationTolerance;

    auto originResult = boardBoundsInSimulationUnits(geometry);
    if (!originResult) {
        return std::unexpected(std::move(originResult).error());
    }
    stage.origin = *originResult;
    const BoundingBox<double>& origin = stage.origin;
    const PolygonSet realOutline = _polygonLoopsToPolygons(geometry.outline, origin.xMin, origin.yMin);
    const std::vector<std::string>& layerNames = slicing.layerNames;

    std::vector<PolygonSet>& signalPerLayer = stage.signalPerLayer;
    std::vector<PolygonSet>& groundPerLayer = stage.groundPerLayer;
    signalPerLayer.resize(layerNames.size());
    groundPerLayer.resize(layerNames.size());
    std::vector<PolygonSet> nonGroundCopperObstaclesPerLayer(layerNames.size());

    std::unordered_set<NetName, NetNameHash> groundNets;
    for (const libkicad::CopperPolygon& polygon : groundCopper) {
        groundNets.insert(NetName(polygon.netName));
    }
    std::vector<libkicad::CopperPolygon> nonGroundCopperObstacles;
    for (const libkicad::CopperPolygon& polygon : geometry.copper) {
        // Non-ground zones are intentionally allowed by the placement policy. Every other piece
        // of non-ground copper is a hard obstacle: that includes both routed traces and footprint
        // pads. Omitting pads here let a generated ground via overlap a signal pad once a wider
        // hull first reached a component, electrically merging that signal into ground.
        if (!polygon.zone && groundNets.count(NetName(polygon.netName)) == 0) {
            nonGroundCopperObstacles.push_back(polygon);
        }
    }

    // Every (layer, copper class) union is independent, and together they dominate this stage, so
    // run them concurrently. GEOS contexts are thread-local in polygon_geometry.cpp; each task
    // writes only its own slot, and progress is reported afterwards on this thread.
    const std::vector<libkicad::CopperPolygon>* copperClasses[] = {&involvedCopper, &groundCopper,
                                                                   &nonGroundCopperObstacles};
    std::vector<PolygonSet>* perLayerClasses[] = {&signalPerLayer, &groundPerLayer,
                                                  &nonGroundCopperObstaclesPerLayer};
    std::vector<std::string> unionErrors(3 * layerNames.size());
    parallelFor(3 * layerNames.size(), [&](std::size_t task) {
        const std::size_t layerIndex = task / 3;
        const std::size_t copperClass = task % 3;
        try {
            (*perLayerClasses[copperClass])[layerIndex] = _copperOnLayer(
                *copperClasses[copperClass], layerNames[layerIndex], origin.xMin, origin.yMin);
        } catch (const std::exception& exception) {
            unionErrors[task] = exception.what();
        }
    });
    for (const std::string& error : unionErrors) {
        if (!error.empty()) throw std::runtime_error(error);
    }
    for (std::size_t task = 0; task < 3 * layerNames.size(); ++task) polygonPrimitiveDone();

    // Each per-layer set is already a regularized union, so "no copper anywhere" is just "every
    // layer empty" -- no need to union all layers together (which, done incrementally, re-unioned
    // an ever-growing polygon set once per layer purely to answer this yes/no question).
    if (std::all_of(signalPerLayer.begin(), signalPerLayer.end(),
                    [](const PolygonSet& layer) { return layer.empty(); })) {
        return std::unexpected("Involved nets have no copper on any layer");
    }

    // Each full simulation selector grows the hull by its own configured amount. In particular,
    // zero is not the same as GeometryOnly: a zero-padding contribution is unioned into the cutout
    // at its exact copper edge and therefore survives clipping. GeometryOnly copper is absent here
    // and remains clipped to the union these contributors produce.
    PolygonSet cutoutSource;
    for (const auto& contribution : hullContributions) {
        PolygonSet source;
        for (const auto& layerName : layerNames) {
            PolygonSet onLayer = _copperOnLayer(contribution.copper, layerName, origin.xMin, origin.yMin);
            source.insert(source.end(), onLayer.begin(), onLayer.end());
        }
        source = unionPolygons(source);
        if (!source.empty()) {
            // Preserve the exact union for a zero-padding contributor. Apart from avoiding an
            // unnecessary GEOS operation, this makes the semantic distinction explicit: zero is
            // still a hull contribution, whereas GeometryOnly copper never enters this loop.
            PolygonSet expanded = contribution.padding > 0.0
                                      ? offsetPolygons(source, contribution.padding, tessellationTolerance)
                                      : source;
            cutoutSource.insert(cutoutSource.end(), expanded.begin(), expanded.end());
        }
    }
    cutoutSource = unionPolygons(cutoutSource);
    polygonPrimitiveDone();
    stage.cutout = intersectPolygons(cutoutSource, realOutline);
    polygonPrimitiveDone();
    if (stage.cutout.empty()) {
        return std::unexpected("Computed cutout region is empty");
    }

    stage.stitching = placeStitchingVias(slicing, stage.cutout, realOutline, groundPerLayer,
                                         nonGroundCopperObstaclesPerLayer, existingVias);
    return stage;
}

} // namespace

std::expected<SlicedBoardPlan, std::string> planSlicedBoardForSimulation(
    const SlicingConfig& slicing, const libkicad::BoardGeometry& geometry,
    const std::vector<libkicad::CopperPolygon>& involvedCopper,
    const std::vector<libkicad::CopperPolygon>& groundCopper,
    const std::vector<ClassifiedCopper::HullContribution>& hullContributions,
    const std::vector<ViaHole>& existingVias) {
    auto stage = computeCutoutStage(slicing, geometry, involvedCopper, groundCopper, hullContributions,
                                    existingVias, [] {});
    if (!stage) return std::unexpected(std::move(stage).error());
    return SlicedBoardPlan{std::move(stage->cutout), std::move(stage->stitching.vias),
                           std::move(stage->stitching.failedAttempts)};
}

std::expected<SlicedBoard, std::string> sliceBoardForSimulation(
    const SlicingConfig& slicing, const libkicad::BoardGeometry& geometry,
    const std::vector<libkicad::CopperPolygon>& involvedCopper,
    const std::vector<libkicad::CopperPolygon>& geometryOnlyCopper,
    const std::vector<libkicad::CopperPolygon>& groundCopper,
    const std::vector<ClassifiedCopper::HullContribution>& hullContributions,
    const std::vector<ViaHole>& existingVias,
    const std::vector<NPTHHole>& npthHoles,
    const GeometryProcessingProgressCallback& onProgress) {
    const std::vector<std::string>& layerNames = slicing.layerNames;
    const std::size_t polygonPrimitiveCount = 6 * layerNames.size() + 8;
    std::size_t completedPolygonPrimitives = 0;
    const auto polygonPrimitiveDone = [&] {
        ++completedPolygonPrimitives;
        if (onProgress) {
            onProgress({GeometryProcessingPhase::PolygonOperations, completedPolygonPrimitives,
                        polygonPrimitiveCount});
        }
    };
    if (onProgress) {
        onProgress({GeometryProcessingPhase::PolygonOperations, 0, polygonPrimitiveCount});
    }

    auto stageResult = computeCutoutStage(slicing, geometry, involvedCopper, groundCopper, hullContributions,
                                          existingVias, polygonPrimitiveDone);
    if (!stageResult) return std::unexpected(std::move(stageResult).error());
    CutoutStage& stage = *stageResult;
    const BoundingBox<double>& origin = stage.origin;
    const double tessellationTolerance = stage.tessellationTolerance;
    const std::vector<PolygonSet>& signalPerLayer = stage.signalPerLayer;
    const std::vector<PolygonSet>& groundPerLayer = stage.groundPerLayer;
    const PolygonSet& cutout = stage.cutout;
    StitchingViaPlacement& stitching = stage.stitching;

    // Geometry-only copper never influences the cutout or stitching, so it's only built here.
    std::vector<PolygonSet> geometryOnlyPerLayer(layerNames.size());
    for (std::size_t layerIndex = 0; layerIndex < layerNames.size(); ++layerIndex) {
        geometryOnlyPerLayer[layerIndex] =
            _copperOnLayer(geometryOnlyCopper, layerNames[layerIndex], origin.xMin, origin.yMin);
        polygonPrimitiveDone();
    }

    const PolygonSet npthHolePolygons = tessellateHoles(npthHoles, tessellationTolerance);
    polygonPrimitiveDone();
    PolygonSet viaHolePolygons = tessellateHoles(existingVias, tessellationTolerance);
    polygonPrimitiveDone();
    const PolygonSet stitchingViaHolePolygons = tessellateHoles(stitching.vias, tessellationTolerance);
    polygonPrimitiveDone();
    viaHolePolygons.insert(viaHolePolygons.end(), stitchingViaHolePolygons.begin(), stitchingViaHolePolygons.end());

    std::vector<PreparedLayer> preparedLayers;
    preparedLayers.reserve(layerNames.size());
    for (std::size_t layerIndex = 0; layerIndex < layerNames.size(); ++layerIndex) {
        preparedLayers.push_back(
            prepareLayer(signalPerLayer[layerIndex], geometryOnlyPerLayer[layerIndex],
                         groundPerLayer[layerIndex], cutout, npthHolePolygons, viaHolePolygons));
        polygonPrimitiveDone();
    }

    // What copper actually survives this simulation's cutout crop, across every layer -- the ground
    // truth triangulateMask() cross-checks a dropped mask opening against (see its own comment on
    // copperInCutout). Built from the same raw per-layer polygons triangulateLayer() above already
    // used, unioned together and cropped the same way, rather than trying to reconstruct it from the
    // triangulated output.
    std::vector<PolygonSet> allCopperOperands;
    allCopperOperands.reserve(3 * layerNames.size());
    for (std::size_t layerIndex = 0; layerIndex < layerNames.size(); ++layerIndex) {
        allCopperOperands.push_back(signalPerLayer[layerIndex]);
        allCopperOperands.push_back(geometryOnlyPerLayer[layerIndex]);
        allCopperOperands.push_back(groundPerLayer[layerIndex]);
        polygonPrimitiveDone();
    }
    const PolygonSet allCopper = unionCompositedPolygons(allCopperOperands);
    const PolygonSet copperInCutout = intersectPolygons(allCopper, cutout);
    polygonPrimitiveDone();

    PreparedMask topMask = prepareMask(geometry.frontMaskOpenings, "F.Mask", cutout, copperInCutout,
                                       origin.xMin, origin.yMin);
    polygonPrimitiveDone();
    PreparedMask bottomMask = prepareMask(geometry.backMaskOpenings, "B.Mask", cutout, copperInCutout,
                                          origin.xMin, origin.yMin);
    polygonPrimitiveDone();

    const std::size_t triangulationPrimitiveCount = 2 * layerNames.size() + 2;
    std::size_t completedTriangulationPrimitives = 0;
    const auto triangulationPrimitiveDone = [&] {
        ++completedTriangulationPrimitives;
        if (onProgress) {
            onProgress({GeometryProcessingPhase::Triangulation, completedTriangulationPrimitives,
                        triangulationPrimitiveCount});
        }
    };
    if (onProgress) {
        onProgress({GeometryProcessingPhase::Triangulation, 0, triangulationPrimitiveCount});
    }

    SlicedBoard result;
    result.layerCopperLoops.resize(layerNames.size());
    result.layerTriangles.resize(layerNames.size());
    result.previewLayerTriangles.resize(layerNames.size());
    for (std::size_t layerIndex = 0; layerIndex < layerNames.size(); ++layerIndex) {
        // Preserve the post-Boolean, post-cut copper itself for grid generation. Do this before
        // triangulation so the grid never sees tessellator-created internal diagonals.
        result.layerCopperLoops[layerIndex] = preparedLayers[layerIndex].finalLayer;
        result.layerTriangles[layerIndex] =
            triangulate(preparedLayers[layerIndex].finalLayer, tessellationTolerance,
                        "layer " + std::to_string(layerIndex));
        triangulationPrimitiveDone();
        result.previewLayerTriangles[layerIndex] =
            triangulate(preparedLayers[layerIndex].previewLayer, tessellationTolerance,
                        "layer " + std::to_string(layerIndex) + " (preview)");
        triangulationPrimitiveDone();
    }
    result.topMaskTriangles = triangulateMask(topMask, "F.Mask", tessellationTolerance);
    triangulationPrimitiveDone();
    result.topMaskOpeningLoops = std::move(topMask.openingLoops);
    result.bottomMaskTriangles = triangulateMask(bottomMask, "B.Mask", tessellationTolerance);
    triangulationPrimitiveDone();
    result.bottomMaskOpeningLoops = std::move(bottomMask.openingLoops);

    if (onProgress) {
        onProgress({GeometryProcessingPhase::Finishing, 0, 1});
    }

    result.npthHoleLoops = npthHolePolygons;

    // Board outline consumers (Simulation::addSubstrates()) expect a single closed polygon loop --
    // if slicing produced more than one disjoint outer region (a broad, spatially-split net class,
    // say), take only the largest by area rather than concatenating them into one bogus loop.
    const Polygon* largestOuter = nullptr;
    double largestArea = 0;
    for (const Polygon& loop : cutout) {
        const double loopArea = signedArea(loop);
        if (loopArea > largestArea) {
            largestArea = loopArea;
            largestOuter = &loop;
        }
    }
    if (largestOuter == nullptr) {
        return std::unexpected("Cutout region has no outer loop");
    }

    result.outline = *largestOuter;
    // The domain, though, must span every outer loop: bounds sizes the grid and the plane/substrate
    // boxes, and cutoutLoops below keeps the smaller disjoint regions' copper, which would otherwise
    // fall outside the simulated volume.
    result.bounds = bounds(*largestOuter);
    for (const Polygon& loop : cutout) {
        if (signedArea(loop) <= 0) continue;
        const auto loopBounds = bounds(loop);
        result.bounds.xMin = std::min(result.bounds.xMin, loopBounds.xMin);
        result.bounds.yMin = std::min(result.bounds.yMin, loopBounds.yMin);
        result.bounds.xMax = std::max(result.bounds.xMax, loopBounds.xMax);
        result.bounds.yMax = std::max(result.bounds.yMax, loopBounds.yMax);
    }
    // Every loop of the true cutout, not just the largest -- see cutoutLoops' own doc comment
    // (board_slicing.hpp) for why grid_gen.cpp needs this rather than `outline` above.
    result.cutoutLoops = cutout;
    result.stitchingVias = std::move(stitching.vias);
    result.failedStitchingViaAttempts = std::move(stitching.failedAttempts);

    // Edge terminations: each terminated net's copper within one termination width of the cut.
    if (!slicing.edgeTerminatedNets.empty() && slicing.edgeTerminationWidth > 0) {
        std::unordered_set<NetName, NetNameHash> terminated;
        for (const std::string& net : slicing.edgeTerminatedNets) {
            if (!net.empty()) terminated.insert(NetName(net)); // "" is a UI row with no net chosen yet
        }
        std::vector<libkicad::CopperPolygon> terminatedCopper;
        for (const auto* source : {&involvedCopper, &geometryOnlyCopper}) {
            for (const libkicad::CopperPolygon& polygon : *source) {
                if (terminated.contains(NetName(polygon.netName))) terminatedCopper.push_back(polygon);
            }
        }
        const PolygonSet band = differencePolygons(
            cutout, offsetPolygons(cutout, -slicing.edgeTerminationWidth, tessellationTolerance));
        result.edgeTerminationLoops.resize(layerNames.size());
        std::size_t layersWithTermination = 0;
        for (std::size_t layerIndex = 0; layerIndex < layerNames.size(); ++layerIndex) {
            const PolygonSet copper =
                _copperOnLayer(terminatedCopper, layerNames[layerIndex], origin.xMin, origin.yMin);
            if (copper.empty()) continue;
            result.edgeTerminationLoops[layerIndex] = intersectPolygons(copper, band);
            if (!result.edgeTerminationLoops[layerIndex].empty()) ++layersWithTermination;
        }
        result.edgeTerminationWidth = slicing.edgeTerminationWidth;
        if (layersWithTermination == 0) {
            logWarning("Edge-terminated nets have no copper along the cut -- no terminations placed");
            result.edgeTerminationLoops.clear();
        }
    }

    // placeStitchingVias() already logged its own via-count/DIAG summary -- this is just the
    // overall sliced-board bbox.
    logInfo("Sliced board bbox = " + to_string(result.bounds) + " sim units");
    return result;
}

std::expected<SlicedBoard, std::string> sliceBoardForSimulation(
    const SlicingConfig& slicing, const libkicad::BoardGeometry& geometry,
    const std::vector<libkicad::CopperPolygon>& involvedCopper,
    const std::vector<libkicad::CopperPolygon>& geometryOnlyCopper,
    const std::vector<libkicad::CopperPolygon>& groundCopper, const std::vector<ViaHole>& existingVias,
    const std::vector<NPTHHole>& npthHoles,
    const GeometryProcessingProgressCallback& onProgress) {
    std::vector<ClassifiedCopper::HullContribution> contributions;
    if (!involvedCopper.empty()) {
        contributions.push_back({involvedCopper, slicing.hullPadding});
    }
    return sliceBoardForSimulation(slicing, geometry, involvedCopper, geometryOnlyCopper, groundCopper,
                                   contributions, existingVias, npthHoles, onProgress);
}

void restrictLumpedComponentsToCutout(SimulationConfig& simulation, const SlicedBoard& board) {
    // Geometry caches written before cutoutLoops was introduced cannot support this test. Preserve
    // their already-resolved components; a newly generated geometry stage always has real loops.
    if (board.cutoutLoops.empty()) return;
    const auto contains = [&](const std::pair<double, double>& position) {
        const Position point(position.first, position.second);
        bool inside = false;
        for (const Polygon& loop : board.cutoutLoops) {
            if (loop.size() < 3) continue;
            // Treat the boundary as inside. This matters for a GeometryOnly net whose surviving
            // copper can end exactly at the cut edge and whose pad centre lands on that edge.
            for (std::size_t i = 0, j = loop.size() - 1; i < loop.size(); j = i++) {
                const Position& a = loop[j];
                const Position& b = loop[i];
                const double dx = b.x() - a.x();
                const double dy = b.y() - a.y();
                const double lengthSquared = dx * dx + dy * dy;
                const double t = std::clamp(lengthSquared > 0
                                                ? ((point.x() - a.x()) * dx + (point.y() - a.y()) * dy) /
                                                      lengthSquared
                                                : 0.0,
                                            0.0, 1.0);
                if (std::hypot(point.x() - (a.x() + t * dx), point.y() - (a.y() + t * dy)) <= 1e-6) {
                    return true;
                }
            }
            bool insideThisLoop = false;
            for (std::size_t i = 0, j = loop.size() - 1; i < loop.size(); j = i++) {
                const double xi = loop[i].x();
                const double yi = loop[i].y();
                const double xj = loop[j].x();
                const double yj = loop[j].y();
                if ((yi > point.y()) != (yj > point.y()) &&
                    point.x() < (xj - xi) * (point.y() - yi) / (yj - yi) + xi) {
                    insideThisLoop = !insideThisLoop;
                }
            }
            if (insideThisLoop) inside = !inside;
        }
        return inside;
    };

    auto& components = simulation.lumpedComponents();
    const std::size_t before = components.size();
    std::erase_if(components, [&](const LumpedComponentConfig& component) {
        return !contains(component.position1()) && !contains(component.position2());
    });
    if (components.size() != before) {
        logInfo("Simulation \"" + simulation.name() + "\": discarded " +
                std::to_string(before - components.size()) +
                " lumped component(s) with both pins outside the sliced cutout");
    }
}

} // namespace kiems
