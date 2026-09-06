#import "GeometryPreviewBridge.h"
#import "GeometryPreviewBridge+Private.h"

#include <algorithm>
#include <array>
#include <cmath>
#include <cstdint>
#include <limits>
#include <optional>
#include <string>
#include <string_view>
#include <tuple>
#include <unordered_map>
#include <unordered_set>
#include <utility>
#include <vector>

#include "kiems/board_slicing.hpp"
#include "kiems/config.hpp"
#include "kiems/constants.hpp"
#include "kiems/importer.hpp"
#include "kiems/libkicad_query.hpp"
#include "logging.hpp"
#include "kiems/paths_config.hpp"

using kiems::EMSConfig;
using namespace Cu;
using kiems::PathsConfig;
using kiems::SimulationConfig;
using kiems::SlicedBoard;

namespace {

CGPoint toCGPoint(const kiems::Position& position) {
    return CGPointMake(position.x(), position.y());
}

// Matches port_resolution.cpp's own (private) _mmToSimUnits exactly -- kiems::libkicad_query's
// results (like every other libkicad_query position) come back in millimetres, board-auxiliary-
// origin-relative; this pipeline's own native frame is simulation units, further re-origined to the
// board's Edge_Cuts bounding box (see getVias()'s own doc comment) -- the bounding-box shift still
// needs applying by the caller, this just handles the unit conversion.
double mmToSimUnits(double mm) { return mm / 1000.0 / kiems::constants::baseUnit * kiems::constants::unitMultiplier; }

std::expected<std::pair<double, double>, std::string> boardOrigin(const PathsConfig& paths) {
    auto geometry = kiems::libkicad_query::boardGeometry(paths, "Loading board outline for geometry preview");
    if (!geometry) {
        return std::unexpected(std::move(geometry).error());
    }
    double xMin = std::numeric_limits<double>::infinity();
    double yMin = std::numeric_limits<double>::infinity();
    for (const kiems::libkicad_query::PolygonLoop& loop : geometry->outline) {
        for (const auto& [xMm, yMm] : loop.pointsMm) {
            xMin = std::min(xMin, mmToSimUnits(xMm));
            yMin = std::min(yMin, mmToSimUnits(yMm));
        }
    }
    if (!std::isfinite(xMin) || !std::isfinite(yMin)) {
        return std::unexpected("KiCad board geometry has no usable Edge.Cuts points");
    }
    return std::pair{xMin, yMin};
}

// A real via's *actual* copper pad is already drawn separately, as part of that layer's copper
// geometry read directly from KiCad -- Simulation::addVia() only needs its own ring to be
// wide enough for the drilled barrel's real conductive wall (config.via().platingThickness(), a
// physically thin quantity -- a few tens of microns -- correct for FDTD conductor modeling), not a
// full pad. But that same thin margin looks wrong reused here for the *preview*'s own ring,
// visually representing a real via's annular ring: platingThickness is a copper-wall-thickness
// value, not an annular-ring-width one -- two genuinely different PCB quantities that happen to
// share the same "make the ring a bit wider than the hole" formula shape. This is only a fallback
// now (a typical production annular-ring-width minimum, ~0.15mm per side) for when the real size
// (queried from KiCad itself -- see realAnnularRingDiameter()) isn't available for some reason; the
// FDTD geometry itself (Simulation::addVia()) is untouched by any of this and keeps using
// platingThickness, correctly.
constexpr double kPreviewViaAnnularRingMarginSimUnits = 1500.0; // 0.15mm, at 10000 sim-units/mm

// One board through-hole's real pad/ring size, already converted into this preview's own
// coordinate frame (simulation units, Edge_Cuts-bounding-box-origined) -- see
// buildRealHoleSizes()/matchRealHoleSize(). Width/height kept separate (not pre-collapsed into one
// "diameter") specifically so an oblong pad's ring can be sized correctly on each axis -- see
// ringCapsuleForRealPad()'s own comment for why collapsing them caused a real, confirmed bug.
struct RealHoleSize {
    double xSim = 0;
    double ySim = 0;
    double padWidthSim = 0;
    double padHeightSim = 0;
};

// Queries the board's real through-holes (vias and through-hole footprint pads alike -- see
// kiems::libkicad_query::ThroughHole's own doc comment) once per geometry build, converting
// each into this preview's frame. Best-effort: an empty result (query failure, or just an older
// libkicad_smoketest that doesn't support the command yet) leaves every via falling back to
// kPreviewViaAnnularRingMarginSimUnits instead, not a hard error -- the ring is a cosmetic preview
// detail, never worth failing the whole geometry step over.
std::vector<RealHoleSize> buildRealHoleSizes(const kiems::PathsConfig& paths, double originX, double originY) {
    std::vector<RealHoleSize> sizes;
    auto holesResult = kiems::libkicad_query::throughHoles(paths, "Reading real via/pad sizes");
    if (!holesResult) {
        return sizes;
    }
    sizes.reserve(holesResult->size());
    for (const auto& hole : *holesResult) {
        RealHoleSize size;
        size.xSim = mmToSimUnits(hole.xMm) - originX;
        size.ySim = mmToSimUnits(hole.yMm) - originY;
        size.padWidthSim = mmToSimUnits(hole.padWidthMm);
        size.padHeightSim = mmToSimUnits(hole.padHeightMm);
        sizes.push_back(size);
    }
    return sizes;
}

// Nearest-position lookup into `sizes` (see buildRealHoleSizes()) -- a plain linear scan, not a
// spatial index: this runs against a few thousand through-holes at most, once per geometry build,
// nowhere near enough to need one. `sizes` and `getVias()` are two independently converted views
// of the same board data read directly from KiCad -- a tolerance (not exact equality) accounts for
// the small floating-point/rounding differences between them, while remaining tight enough that a
// match cannot cross to a genuinely different, merely nearby via.
std::optional<RealHoleSize> matchRealHoleSize(const std::vector<RealHoleSize>& sizes, double xSim, double ySim) {
    constexpr double kMatchToleranceSimUnits = 200.0; // 20 microns
    double bestDistance = std::numeric_limits<double>::infinity();
    std::optional<RealHoleSize> best;
    for (const RealHoleSize& size : sizes) {
        const double distance = std::hypot(xSim - size.xSim, ySim - size.ySim);
        if (distance < bestDistance) {
            bestDistance = distance;
            best = size;
        }
    }
    if (bestDistance > kMatchToleranceSimUnits) {
        return std::nullopt;
    }
    return best;
}

// The ring/pad's own capsule centerline + radius, given the *hole's* own centerline (holePos1/2 --
// the drill's two endpoints, from getVias(), always the true drilled shape) and the real pad size
// matched against it. Returns {position, position2, diameter}.
//
// Reusing the hole's own centerline length for the ring (as an earlier version of this code did --
// just picking max(padWidth, padHeight) as a flat radius applied around the *same* two points the
// hole itself uses) is wrong on two axes at once: it makes the ring exactly as wide as the pad's
// *longer* dimension even perpendicular to that axis (a 0.8x1.4mm pad rendered ~1.4mm wide, not
// 0.8mm), and it *adds* that same radius to each end of the hole's own centerline on top of the
// hole's real length (turning a 1.4mm-long pad into a ~2.1mm-long ring) -- both errors compounding
// into a ring large enough to visually overlap unrelated nearby copper, a real, confirmed bug (a
// WQFN connector's oblong SHIELD pad reported as "shorting other components" once rendered at
// roughly 1.5x its true size on both axes).
//
// The fix: derive the ring's own capsule directly from the pad's real width/height instead --
// radius = the *shorter* pad dimension / 2 (a capsule's width, by definition), and a centerline
// length of (longer dimension - shorter dimension) so the endpoint-to-endpoint span, *including*
// the two end radii, comes out to exactly the pad's real longer dimension. The capsule's own axis
// (which way "longer" points) is taken from the hole's own centerline direction, not re-derived
// independently -- a designer always aligns an oblong pad's shape with its own oblong drill, and
// this pipeline has no separate pad-rotation data to do otherwise; a round hole (no direction of
// its own) falls back to an arbitrary +X axis, harmless since the ring comes out round too whenever
// the matched pad is itself round (width == height, the ordinary case).
std::pair<CGPoint, CGPoint> ringCapsuleForRealPad(CGPoint holePos1, CGPoint holePos2, double padWidthSim,
                                                    double padHeightSim) {
    const double longer = std::max(padWidthSim, padHeightSim);
    const double shorter = std::min(padWidthSim, padHeightSim);
    const double centerlineHalfLength = std::max(0.0, (longer - shorter) / 2.0);

    const double midX = (holePos1.x + holePos2.x) / 2;
    const double midY = (holePos1.y + holePos2.y) / 2;
    double axisX = holePos2.x - holePos1.x;
    double axisY = holePos2.y - holePos1.y;
    const double axisLength = std::hypot(axisX, axisY);
    if (axisLength > 1e-9) {
        axisX /= axisLength;
        axisY /= axisLength;
    } else {
        axisX = 1;
        axisY = 0;
    }

    return {CGPointMake(midX - axisX * centerlineHalfLength, midY - axisY * centerlineHalfLength),
            CGPointMake(midX + axisX * centerlineHalfLength, midY + axisY * centerlineHalfLength)};
}

// Same disc-vs-polygon overlap test as simulation.cpp's own (file-local) _viaIntersectsOutline --
// a real via whose center has been sliced away can still have copper straddling the cutout
// boundary, so this preview needs to keep the same vias Simulation::addVias() actually keeps.
bool pointInPolygon(double x, double y, const std::vector<kiems::Position>& polygon) {
    bool inside = false;
    for (std::size_t i = 0, j = polygon.size() - 1; i < polygon.size(); j = i++) {
        const kiems::Position& pi = polygon[i];
        const kiems::Position& pj = polygon[j];
        const bool crosses = (pi.y() > y) != (pj.y() > y);
        if (crosses) {
            const double xIntersect = pj.x() + (y - pj.y()) * (pi.x() - pj.x()) / (pi.y() - pj.y());
            if (x < xIntersect) {
                inside = !inside;
            }
        }
    }
    return inside;
}

double distanceToPolygonBoundary(double x, double y, const std::vector<kiems::Position>& polygon) {
    double best = std::numeric_limits<double>::infinity();
    for (std::size_t i = 0, j = polygon.size() - 1; i < polygon.size(); j = i++) {
        const kiems::Position& a = polygon[j];
        const kiems::Position& b = polygon[i];
        const double abx = b.x() - a.x();
        const double aby = b.y() - a.y();
        const double lenSq = abx * abx + aby * aby;
        double t = 0;
        if (lenSq > 0) {
            t = ((x - a.x()) * abx + (y - a.y()) * aby) / lenSq;
            t = std::clamp(t, 0.0, 1.0);
        }
        const double px = a.x() + t * abx;
        const double py = a.y() + t * aby;
        best = std::min(best, std::hypot(x - px, y - py));
    }
    return best;
}

bool viaIntersectsOutline(double x, double y, double diameter, const std::vector<kiems::Position>& outline) {
    if (pointInPolygon(x, y, outline)) {
        return true;
    }
    return distanceToPolygonBoundary(x, y, outline) <= diameter / 2;
}

// ---- Component 3D model preview (debug aid -- see EMSGeometryComponentTriangle's own doc comment) ----

// Every footprint auto-discovered as a lumped R/L/C component (see
// kiems::LumpedComponentConfig's own doc comment) -- deliberately NOT every footprint with a
// resolved port/probe pin too (an earlier version of this function unioned both): a port/probe pin
// commonly sits on an IC or connector, not just a passive, and rendering those alongside the
// passives made this debug view's actual point -- eyeballing which physical *passive* got
// auto-discovered -- harder to read, not easier. Insertion order preserved, deduplicated.
std::vector<std::string> includedFootprintReferences(const SimulationConfig& simConfig) {
    std::vector<std::string> refs;
    std::unordered_set<std::string> seen;
    for (const auto& component : simConfig.lumpedComponents()) {
        const std::string& ref = component.reference();
        if (ref.empty() || !seen.insert(ref).second) {
            continue;
        }
        refs.push_back(ref);
    }
    return refs;
}

// Result of exportComponentTriangles(): the real, colored mesh plus every diagnostic KiCad's own
// exporter reported building it (see kiems::libkicad_query::ComponentModelExportResult's own
// doc comment) -- surfaced to the caller so "the mesh is missing/wrong" is distinguishable from
// "this specific component's 3D model file couldn't be resolved," rather than both collapsing to a
// silent empty result.
struct ComponentExportOutcome {
    std::vector<kiems::libkicad_query::ComponentTriangle> triangles;
    std::vector<std::string> messages;
    // The board's real top-copper mounting surface Z, in the same mm frame `triangles`' own
    // vertices are in -- see kiems::libkicad_query::ComponentModelExportResult::topCopperZMm's
    // own doc comment. 0 (a no-op offset) whenever `triangles` is empty too, so a caller doesn't
    // need to separately guard against using a meaningless default.
    double topCopperZMm = 0;
};

// Exports (via libkicad's in-process exportComponentModels(), no board body, just the named
// footprints' own real 3D models, already placed/rotated/offset exactly as KiCad itself would show
// them, each triangle carrying its own real STEP color) one combined, colored mesh for every
// included footprint. `--drill-origin` semantics match every other position this preview already
// uses (see mmToSimUnits's own comment) -- the caller still has to subtract the Edge_Cuts bounding
// box origin itself, same as any other position here. Best-effort: a hard failure (query/subprocess
// error, or the exporter itself reporting failure) returns an empty mesh rather than failing the
// whole geometry preview -- this is a debug visualization aid, never something the real FDTD
// geometry depends on. A per-component failure (e.g. a missing 3D model file) isn't hard-fatal --
// messages carries it, triangles still has every other requested component's mesh.
ComponentExportOutcome exportComponentTriangles(const PathsConfig& paths, const std::vector<std::string>& refs) {
    if (refs.empty()) {
        logInfo("GeometryPreview: no included footprint references, skipping component model export");
        return {};
    }
    std::string refsCsv;
    for (std::size_t i = 0; i < refs.size(); ++i) {
        if (i > 0) {
            refsCsv += ",";
        }
        refsCsv += refs[i];
    }
    // Still written to disk as an incidental debug artifact (see exportComponentModels()'s own doc
    // comment) -- not read back here, the colored mesh comes straight from the query's own result.
    const std::filesystem::path outPath = paths.fabDir / "geometry_preview_components.stl";
    logInfo("GeometryPreview: exporting component models for [" + refsCsv + "]");
    auto exportResult = kiems::libkicad_query::exportComponentModels(paths, refsCsv, outPath.string(),
                                                                             "Rendering component 3D models");
    if (!exportResult) {
        logWarning("GeometryPreview: exportComponentModels failed: " + exportResult.error());
        return {};
    }
    logInfo("GeometryPreview: exportComponentModels returned exportSucceeded=" +
                          std::string(exportResult->exportSucceeded ? "true" : "false") + ", " +
                          std::to_string(exportResult->messages.size()) + " message(s), " +
                          std::to_string(exportResult->triangles.size()) + " triangle(s)");
    for (const std::string& message : exportResult->messages) {
        logWarning("GeometryPreview: " + message);
    }
    ComponentExportOutcome outcome;
    outcome.messages = exportResult->messages;
    outcome.triangles = std::move(exportResult->triangles);
    outcome.topCopperZMm = exportResult->topCopperZMm;
    return outcome;
}

} // namespace

@implementation EMSGeometryTriangle
- (instancetype)initWithA:(CGPoint)a b:(CGPoint)b c:(CGPoint)c {
    self = [super init];
    if (self) {
        _a = a;
        _b = b;
        _c = c;
    }
    return self;
}
@end


@implementation EMSGeometryLayer
- (instancetype)initWithName:(NSString*)name
                    triangles:(NSArray<EMSGeometryTriangle*>*)triangles
                    hexColor:(nullable NSString*)hexColor
                            z:(double)z {
    self = [super init];
    if (self) {
        _name = [name copy];
        _triangles = [triangles copy];
        _hexColor = [hexColor copy];
        _z = z;
    }
    return self;
}
@end

@implementation EMSGeometryVia
- (instancetype)initWithPosition:(CGPoint)position
                        position2:(CGPoint)position2
                     ringPosition:(CGPoint)ringPosition
                    ringPosition2:(CGPoint)ringPosition2
                         diameter:(double)diameter
              annularRingDiameter:(double)annularRingDiameter {
    self = [super init];
    if (self) {
        _position = position;
        _position2 = position2;
        _ringPosition = ringPosition;
        _ringPosition2 = ringPosition2;
        _diameter = diameter;
        _annularRingDiameter = annularRingDiameter;
    }
    return self;
}
@end

@implementation EMSGeometryPort
- (instancetype)initWithName:(NSString*)name
                     position:(CGPoint)position
                        width:(double)width
                       length:(double)length
                 absorbSignal:(BOOL)absorbSignal {
    self = [super init];
    if (self) {
        _name = [name copy];
        _position = position;
        _width = width;
        _length = length;
        _absorbSignal = absorbSignal;
    }
    return self;
}
@end

@implementation EMSGeometryComponentTriangle
- (instancetype)initWithA:(simd_double3)a b:(simd_double3)b c:(simd_double3)c color:(simd_double4)color {
    self = [super init];
    if (self) {
        _a = a;
        _b = b;
        _c = c;
        _color = color;
    }
    return self;
}
@end

@implementation EMSGeometryGridPlane
- (instancetype)initWithPositions:(NSData*)positions colors:(NSData*)colors vertexCount:(NSUInteger)vertexCount {
    self = [super init];
    if (self) {
        _positions = [positions copy];
        _colors = [colors copy];
        _vertexCount = vertexCount;
    }
    return self;
}
@end

@implementation EMSGeometryGridMaterial
- (instancetype)initWithName:(NSString*)name color:(simd_double4)color {
    self = [super init];
    if (self) {
        _name = [name copy];
        _color = color;
    }
    return self;
}
@end

@implementation EMSGeometryGridLayer
- (instancetype)initWithName:(NSString*)name z:(double)z edgeColors:(NSData*)edgeColors {
    self = [super init];
    if (self) {
        _name = [name copy];
        _z = z;
        _edgeColors = [edgeColors copy];
    }
    return self;
}
@end

@implementation EMSGeometryPreview
- (instancetype)initWithLayers:(NSArray<EMSGeometryLayer*>*)layers
                  topSolderMask:(EMSGeometryLayer* _Nullable)topSolderMask
               bottomSolderMask:(EMSGeometryLayer* _Nullable)bottomSolderMask
                        outline:(NSArray<NSValue*>*)outline
                           vias:(NSArray<EMSGeometryVia*>*)vias
              failedViaAttempts:(NSArray<NSValue*>*)failedViaAttempts
                          ports:(NSArray<EMSGeometryPort*>*)ports
                viaMeshTriangles:(NSArray<EMSGeometryComponentTriangle*>*)viaMeshTriangles
         componentMeshTriangles:(NSArray<EMSGeometryComponentTriangle*>*)componentMeshTriangles
   renderedComponentReferences:(NSArray<NSString*>*)renderedComponentReferences
     componentModelExportMessages:(NSArray<NSString*>*)componentModelExportMessages
                     gridLinesX:(NSArray<NSNumber*>*)gridLinesX
                     gridLinesY:(NSArray<NSNumber*>*)gridLinesY
                     gridLinesZ:(NSArray<NSNumber*>*)gridLinesZ
            gridPlaneExcludingX:(EMSGeometryGridPlane* _Nullable)gridPlaneExcludingX
            gridPlaneExcludingY:(EMSGeometryGridPlane* _Nullable)gridPlaneExcludingY
            gridPlaneExcludingZ:(EMSGeometryGridPlane* _Nullable)gridPlaneExcludingZ
                  gridMaterials:(NSArray<EMSGeometryGridMaterial*>*)gridMaterials
                     gridLayers:(NSArray<EMSGeometryGridLayer*>*)gridLayers
                    pmlInnerXMin:(double)pmlInnerXMin
                    pmlInnerXMax:(double)pmlInnerXMax
                    pmlInnerYMin:(double)pmlInnerYMin
                    pmlInnerYMax:(double)pmlInnerYMax
                    pmlInnerZMin:(double)pmlInnerZMin
                    pmlInnerZMax:(double)pmlInnerZMax
                           xMin:(double)xMin
                           yMin:(double)yMin
                          width:(double)width
                         height:(double)height {
    self = [super init];
    if (self) {
        _layers = [layers copy];
        _topSolderMask = topSolderMask;
        _bottomSolderMask = bottomSolderMask;
        _outline = [outline copy];
        _vias = [vias copy];
        _failedViaAttempts = [failedViaAttempts copy];
        _ports = [ports copy];
        _viaMeshTriangles = [viaMeshTriangles copy];
        _componentMeshTriangles = [componentMeshTriangles copy];
        _renderedComponentReferences = [renderedComponentReferences copy];
        _componentModelExportMessages = [componentModelExportMessages copy];
        _gridLinesX = [gridLinesX copy];
        _gridLinesY = [gridLinesY copy];
        _gridLinesZ = [gridLinesZ copy];
        _gridPlaneExcludingX = gridPlaneExcludingX;
        _gridPlaneExcludingY = gridPlaneExcludingY;
        _gridPlaneExcludingZ = gridPlaneExcludingZ;
        _gridMaterials = [gridMaterials copy];
        _gridLayers = [gridLayers copy];
        _pmlInnerXMin = pmlInnerXMin;
        _pmlInnerXMax = pmlInnerXMax;
        _pmlInnerYMin = pmlInnerYMin;
        _pmlInnerYMax = pmlInnerYMax;
        _pmlInnerZMin = pmlInnerZMin;
        _pmlInnerZMax = pmlInnerZMax;
        _xMin = xMin;
        _yMin = yMin;
        _width = width;
        _height = height;
    }
    return self;
}
@end

namespace {

// ---- Real 3D via geometry (see EMSGeometryPreview.viaMeshTriangles' own doc comment) ----
// Placed here, after every @implementation above, rather than in the main anonymous namespace this
// file starts with: it needs EMSGeometryComponentTriangle's own initWithA:b:c:color: (implemented
// above), which Objective-C requires to already be visible at the call site, unlike a plain C++
// function that could be forward-declared -- these helpers are only ever called from
// buildGeometryPreview() just below anyway, so this is also exactly where they're used.

// A consistent copper/gold tone for every via's own barrel tube and annular rings, regardless of
// layer -- matches the old flat-marker preview's own gold "stroke" color. Real per-layer color
// matching (each ring tinted like that specific layer's own assigned UI color) isn't attempted:
// real via copper is coppery regardless of what arbitrary display color a layer's been assigned, and
// this file has no hex-color-string parser to reuse for it (see EMSGeometryLayer.hexColor, parsed
// only on the Swift side today).
constexpr double kViaCopperR = 0xEB / 255.0;
constexpr double kViaCopperG = 0xB5 / 255.0;
constexpr double kViaCopperB = 0x00 / 255.0;

// How finely a via's own round/capsule cross-section is tessellated -- matches GeometryView.swift's
// own circleSegments (20) for a plain round via (segmentsPerHalf*2 total boundary points).
constexpr int kViaBoundarySegmentsPerHalf = 10;

// A tiny Z nudge applied to every annular-ring washer, away from its own exactly-coincident layer
// plane -- board_slicing.cpp only cuts each via's own *drilled hole* diameter out of the shared
// copper (layerTriangles), deliberately not the wider annular-ring diameter this ring is drawn at
// (see viaHolePolygons' own doc comment there for why: that data also feeds the real FDTD
// simulation, where cutting a hole any wider than the via's own real, thin CSXCAD-priority metal
// footprint would remove real copper the simulation never actually gets back). So for any via that
// sits on real copper (virtually every one with a real pad, or a stitching via on a ground pour),
// this ring and the leftover real copper triangles underneath it are genuinely coincident geometry
// at the same Z -- exactly what a real depth buffer can't consistently resolve, seen as flickering
// ("z-fighting"). 1 micron is nowhere near visually perceptible at real board scale but comfortably
// exceeds the depth buffer's own precision at this Z range -- the same "nudge by a tiny fixed
// amount" fix GeometryView.swift's/FieldView.swift's own markerZ already uses for the identical
// reason (vias/ports needing to read as sitting *above* the topmost copper layer, not fighting it).
constexpr double kViaRingZEpsilonSimUnits = 10.0; // 1 micron, at 10000 sim-units/mm

/// One point around a capsule/stadium's own boundary (XY only -- the caller supplies Z). Traces the
/// full closed perimeter (semicircle at (x2,y2), then semicircle at (x1,y1), each `segmentsPerHalf`
/// segments; the two straight sides are the implicit edges between the two semicircles' own end
/// points) starting and ending at the same shared angular parameterization regardless of `radius` --
/// critical so two calls with the same centerline but different radii (a via's hole vs. its own
/// annular ring) produce boundary point arrays that correspond 1:1 by index, letting
/// appendAnnulusRing() below connect outer[i]<->inner[i] without any twist. Degenerates to a plain
/// circle when (x1,y1) == (x2,y2) (every stitching via, and most real ones).
std::vector<CGPoint> capsuleBoundaryPoints(double x1, double y1, double x2, double y2, double radius,
                                             int segmentsPerHalf) {
    const double dx = x2 - x1;
    const double dy = y2 - y1;
    const double len = std::hypot(dx, dy);
    const double alongX = len > 1e-9 ? dx / len : 1.0;
    const double alongY = len > 1e-9 ? dy / len : 0.0;
    const double perpX = -alongY;
    const double perpY = alongX;

    std::vector<CGPoint> points;
    points.reserve(static_cast<std::size_t>(2 * (segmentsPerHalf + 1)));
    for (int i = 0; i <= segmentsPerHalf; ++i) {
        const double t = M_PI * i / segmentsPerHalf;
        const double cx = std::cos(t);
        const double cy = std::sin(t);
        points.push_back(CGPointMake(x2 + radius * (perpX * cx + alongX * cy),
                                       y2 + radius * (perpY * cx + alongY * cy)));
    }
    for (int i = 0; i <= segmentsPerHalf; ++i) {
        const double t = M_PI + M_PI * i / segmentsPerHalf;
        const double cx = std::cos(t);
        const double cy = std::sin(t);
        points.push_back(CGPointMake(x1 + radius * (perpX * cx + alongX * cy),
                                       y1 + radius * (perpY * cx + alongY * cy)));
    }
    return points;
}

/// Appends two triangles forming one vertical quad of an open (uncapped) tube wall, between boundary
/// points `a`/`b` (adjacent points from capsuleBoundaryPoints(), XY only) extruded from `zTop` to
/// `zBottom`. Winding isn't significant here (neither Metal pipeline this feeds into culls
/// back-faces -- see GeometryView.swift's own doc comment on why real depth test/write is enough on
/// its own), so no attempt is made to orient these consistently outward.
void appendTubeQuad(CGPoint a, CGPoint b, double zTop, double zBottom, simd_double4 color,
                     NSMutableArray<EMSGeometryComponentTriangle*>* triangles) {
    const simd_double3 aTop = simd_make_double3(a.x, a.y, zTop);
    const simd_double3 bTop = simd_make_double3(b.x, b.y, zTop);
    const simd_double3 aBottom = simd_make_double3(a.x, a.y, zBottom);
    const simd_double3 bBottom = simd_make_double3(b.x, b.y, zBottom);
    [triangles addObject:[[EMSGeometryComponentTriangle alloc] initWithA:aTop b:bTop c:aBottom color:color]];
    [triangles addObject:[[EMSGeometryComponentTriangle alloc] initWithA:bTop b:bBottom c:aBottom color:color]];
}

/// Appends two triangles forming one flat quad of an annular-ring washer at a fixed `z`, between
/// corresponding boundary-point pairs from the outer (ring) and inner (hole) capsules -- see
/// capsuleBoundaryPoints()'s own doc comment for why `outerA`/`outerB`/`innerA`/`innerB` are safe to
/// connect directly by shared index without any twist.
void appendAnnulusQuad(CGPoint outerA, CGPoint outerB, CGPoint innerA, CGPoint innerB, double z, simd_double4 color,
                       NSMutableArray<EMSGeometryComponentTriangle*>* triangles) {
    const simd_double3 oa = simd_make_double3(outerA.x, outerA.y, z);
    const simd_double3 ob = simd_make_double3(outerB.x, outerB.y, z);
    const simd_double3 ia = simd_make_double3(innerA.x, innerA.y, z);
    const simd_double3 ib = simd_make_double3(innerB.x, innerB.y, z);
    [triangles addObject:[[EMSGeometryComponentTriangle alloc] initWithA:oa b:ob c:ia color:color]];
    [triangles addObject:[[EMSGeometryComponentTriangle alloc] initWithA:ob b:ib c:ia color:color]];
}

/// Real 3D geometry for one via -- see EMSGeometryPreview.viaMeshTriangles' own doc comment for what
/// and why. `metalOffsets` is buildGeometryPreview()'s own per-layer Z list (board top to bottom, in
/// stackup order) -- every via is treated as reaching every layer (see viaHolePolygons' own comment
/// in board_slicing.cpp for why that's the simplifying assumption already in force everywhere else a
/// via is modeled in this codebase), so the tube spans metalOffsets' own full range and a ring is
/// added at every one of its entries, not just some.
void appendViaMesh(const EMSGeometryVia* via, const std::vector<double>& metalOffsets,
                    NSMutableArray<EMSGeometryComponentTriangle*>* triangles) {
    const double holeRadius = via.diameter / 2;
    if (holeRadius <= 0 || metalOffsets.empty()) {
        return;
    }
    const simd_double4 color = simd_make_double4(kViaCopperR, kViaCopperG, kViaCopperB, 1.0);
    const double zTop = metalOffsets.front();
    const double zBottom = metalOffsets.back();

    const std::vector<CGPoint> holeBoundary =
        capsuleBoundaryPoints(via.position.x, via.position.y, via.position2.x, via.position2.y, holeRadius,
                               kViaBoundarySegmentsPerHalf);
    const std::size_t n = holeBoundary.size();

    // Open (uncapped) barrel tube at the drilled hole diameter, spanning the board's full Z extent.
    for (std::size_t i = 0; i < n; ++i) {
        appendTubeQuad(holeBoundary[i], holeBoundary[(i + 1) % n], zTop, zBottom, color, triangles);
    }

    // Annular-ring washer at every metal layer -- skipped entirely if the ring isn't actually wider
    // than the hole (a via with no real/fallback ring size at all, annularRingDiameter <= diameter,
    // would otherwise produce a degenerate or inverted ring).
    const double ringRadius = via.annularRingDiameter / 2;
    if (ringRadius <= holeRadius) {
        return;
    }
    const std::vector<CGPoint> ringBoundary =
        capsuleBoundaryPoints(via.position.x, via.position.y, via.position2.x, via.position2.y, ringRadius,
                               kViaBoundarySegmentsPerHalf);
    for (const double layerZ : metalOffsets) {
        const double z = layerZ + kViaRingZEpsilonSimUnits;
        for (std::size_t i = 0; i < n; ++i) {
            appendAnnulusQuad(ringBoundary[i], ringBoundary[(i + 1) % n], holeBoundary[i], holeBoundary[(i + 1) % n],
                               z, color, triangles);
        }
    }
}

struct PackedGridPosition { float x, y, z; };
struct PackedGridColor { float r, g, b, a; };
static_assert(sizeof(PackedGridPosition) == 12);
static_assert(sizeof(PackedGridColor) == 16);

struct MaterialGridBuffers {
    EMSGeometryGridPlane* excludingX = nil;
    EMSGeometryGridPlane* excludingY = nil;
    EMSGeometryGridPlane* excludingZ = nil;
    NSArray<EMSGeometryGridMaterial*>* materials = @[];
    NSArray<EMSGeometryGridLayer*>* layers = @[];
};

class GridMaterialColors {
public:
    explicit GridMaterialColors(const EMSConfig& config) : _substrates(config.getSubstrates()) {}

    PackedGridColor color(CSProperties* property, bool inPML) {
        if (inPML) return remember("PML", {0.85f, 0.25f, 0.85f, 1.0f});
        if (property == nullptr) return remember("Vacuum", {0.62f, 0.67f, 0.72f, 1.0f});

        const std::string name = property->GetName();
        if ((property->GetType() & CSProperties::METAL) != 0)
            return remember("Copper / PEC", {1.0f, 0.56f, 0.12f, 1.0f});
        if (name == "SolderMaskTop" || name == "SolderMaskBottom")
            return remember("Solder mask", {0.1f, 0.78f, 0.32f, 1.0f});
        if (name == "NPTHVoid") return remember("Vacuum / opening", {0.78f, 0.80f, 0.84f, 1.0f});
        if (name == "ViaFilling") return remember("Via filling", {0.72f, 0.38f, 0.90f, 1.0f});

        constexpr std::string_view prefix = "Substrate_";
        if (name.rfind(prefix, 0) == 0) {
            std::size_t index = 0;
            try { index = static_cast<std::size_t>(std::stoul(name.substr(prefix.size()))); } catch (...) {}
            static constexpr std::array<PackedGridColor, 6> palette = {{
                {0.18f, 0.52f, 0.95f, 1.0f}, {0.16f, 0.72f, 0.86f, 1.0f},
                {0.28f, 0.42f, 0.82f, 1.0f}, {0.20f, 0.66f, 0.62f, 1.0f},
                {0.42f, 0.48f, 0.92f, 1.0f}, {0.20f, 0.58f, 0.76f, 1.0f},
            }};
            const std::string displayName = index < _substrates.size() ? _substrates[index].name() : name;
            return remember(displayName, palette[index % palette.size()]);
        }
        return remember(name, {0.92f, 0.72f, 0.22f, 1.0f});
    }

    NSArray<EMSGeometryGridMaterial*>* legend() const {
        NSMutableArray<EMSGeometryGridMaterial*>* result = [NSMutableArray arrayWithCapacity:_legend.size()];
        for (const auto& [name, color] : _legend) {
            [result addObject:[[EMSGeometryGridMaterial alloc]
                                  initWithName:@(name.c_str())
                                         color:simd_make_double4(color.r, color.g, color.b, color.a)]];
        }
        return result;
    }

private:
    PackedGridColor remember(const std::string& name, PackedGridColor color) {
        if (_seen.insert(name).second) _legend.emplace_back(name, color);
        return color;
    }

    std::vector<kiems::LayerConfig> _substrates;
    std::unordered_set<std::string> _seen;
    std::vector<std::pair<std::string, PackedGridColor>> _legend;
};

std::size_t midpointLineIndex(const std::vector<double>& lines) {
    if (lines.empty()) return 0;
    const double midpoint = (lines.front() + lines.back()) * 0.5;
    const auto it = std::lower_bound(lines.begin(), lines.end(), midpoint);
    if (it == lines.begin()) return 0;
    if (it == lines.end()) return lines.size() - 1;
    const std::size_t upper = static_cast<std::size_t>(it - lines.begin());
    return std::abs(lines[upper] - midpoint) < std::abs(lines[upper - 1] - midpoint) ? upper : upper - 1;
}

bool isInPML(const kiems::ComputedGridLines& grid, double x, double y, double z) {
    return x < grid.pmlInnerXMin || x > grid.pmlInnerXMax || y < grid.pmlInnerYMin || y > grid.pmlInnerYMax ||
           z < grid.pmlInnerZMin || z > grid.pmlInnerZMax;
}

template <typename Place>
EMSGeometryGridPlane* buildMaterialPlane(ContinuousStructure& csx, const kiems::ComputedGridLines& grid,
                                         const std::vector<double>& valuesA, const std::vector<double>& valuesB,
                                         double fixedC, Place place, GridMaterialColors& colors) {
    if (valuesA.empty() || valuesB.empty()) return nil;
    std::vector<PackedGridPosition> positions;
    std::vector<PackedGridColor> edgeColors;
    const std::size_t edgeCount = (valuesA.size() - 1) * valuesB.size() + valuesA.size() * (valuesB.size() - 1);
    positions.reserve(edgeCount * 2);
    edgeColors.reserve(edgeCount * 2);

    const auto append = [&](double a0, double b0, double a1, double b1) {
        const auto p0 = place(a0, b0, fixedC);
        const auto p1 = place(a1, b1, fixedC);
        const double coord[3] = {(p0[0] + p1[0]) * 0.5, (p0[1] + p1[1]) * 0.5, (p0[2] + p1[2]) * 0.5};
        CSProperties* property = csx.GetPropertyByCoordPriority(
            coord, static_cast<CSProperties::PropertyType>(CSProperties::MATERIAL | CSProperties::METAL), false);
        const PackedGridColor color = colors.color(property, isInPML(grid, coord[0], coord[1], coord[2]));
        positions.push_back({static_cast<float>(p0[0]), static_cast<float>(p0[1]), static_cast<float>(p0[2])});
        positions.push_back({static_cast<float>(p1[0]), static_cast<float>(p1[1]), static_cast<float>(p1[2])});
        edgeColors.push_back(color);
        edgeColors.push_back(color);
    };
    for (std::size_t b = 0; b < valuesB.size(); ++b)
        for (std::size_t a = 0; a + 1 < valuesA.size(); ++a)
            append(valuesA[a], valuesB[b], valuesA[a + 1], valuesB[b]);
    for (std::size_t a = 0; a < valuesA.size(); ++a)
        for (std::size_t b = 0; b + 1 < valuesB.size(); ++b)
            append(valuesA[a], valuesB[b], valuesA[a], valuesB[b + 1]);

    NSData* positionData = [NSData dataWithBytes:positions.data() length:positions.size() * sizeof(PackedGridPosition)];
    NSData* colorData = [NSData dataWithBytes:edgeColors.data() length:edgeColors.size() * sizeof(PackedGridColor)];
    return [[EMSGeometryGridPlane alloc] initWithPositions:positionData colors:colorData vertexCount:positions.size()];
}

template <typename Place>
NSData* buildMaterialEdgeColors(ContinuousStructure& csx, const kiems::ComputedGridLines& grid,
                                const std::vector<double>& valuesA, const std::vector<double>& valuesB,
                                double fixedC, Place place, GridMaterialColors& colors) {
    std::vector<PackedGridColor> edgeColors;
    const std::size_t edgeCount = (valuesA.size() - 1) * valuesB.size() + valuesA.size() * (valuesB.size() - 1);
    edgeColors.reserve(edgeCount);
    const auto append = [&](double a0, double b0, double a1, double b1) {
        const auto p0 = place(a0, b0, fixedC);
        const auto p1 = place(a1, b1, fixedC);
        const double coord[3] = {(p0[0] + p1[0]) * 0.5, (p0[1] + p1[1]) * 0.5, (p0[2] + p1[2]) * 0.5};
        CSProperties* property = csx.GetPropertyByCoordPriority(
            coord, static_cast<CSProperties::PropertyType>(CSProperties::MATERIAL | CSProperties::METAL), false);
        edgeColors.push_back(colors.color(property, isInPML(grid, coord[0], coord[1], coord[2])));
    };
    for (std::size_t b = 0; b < valuesB.size(); ++b)
        for (std::size_t a = 0; a + 1 < valuesA.size(); ++a)
            append(valuesA[a], valuesB[b], valuesA[a + 1], valuesB[b]);
    for (std::size_t a = 0; a < valuesA.size(); ++a)
        for (std::size_t b = 0; b + 1 < valuesB.size(); ++b)
            append(valuesA[a], valuesB[b], valuesA[a], valuesB[b + 1]);
    return [NSData dataWithBytes:edgeColors.data() length:edgeColors.size() * sizeof(PackedGridColor)];
}

MaterialGridBuffers buildMaterialGrid(const SlicedBoard& sliced, const SimulationConfig& simConfig,
                                      const EMSConfig& config, const PathsConfig& paths,
                                      const kiems::ComputedGridLines& grid) {
    if (grid.x.empty() || grid.y.empty() || grid.z.empty()) return {};
    SimulationConfig configCopy = simConfig;
    kiems::RunOptions options;
    options.backend = kiems::FDTDBackend::CopperGPU;
    kiems::Simulation simulation(configCopy, config, options, paths);
    simulation.adoptSlicedBoard(sliced);
    simulation.adoptGridLines(grid);
    if (auto result = simulation.populateGeometry(); !result) {
        logWarning("GeometryPreview: could not build material-colored grid: " + result.error());
        return {};
    }
    ContinuousStructure& csx = simulation.csx();
    csx.Update();

    kiems::ComputedGridLines displayGrid = grid;
    // GridGenerator keeps these diagnostic X/Y bounds local to the sliced-board origin, whereas
    // its real grid lines and all CSXCAD geometry are absolute in that frame.
    displayGrid.pmlInnerXMin += sliced.xMin;
    displayGrid.pmlInnerXMax += sliced.xMin;
    displayGrid.pmlInnerYMin += sliced.yMin;
    displayGrid.pmlInnerYMax += sliced.yMin;

    GridMaterialColors colors(config);
    MaterialGridBuffers result;
    const double fixedX = grid.x[midpointLineIndex(grid.x)];
    const double fixedY = grid.y[midpointLineIndex(grid.y)];
    const double fixedZ = grid.z[midpointLineIndex(grid.z)];
    result.excludingZ = buildMaterialPlane(csx, displayGrid, grid.x, grid.y, fixedZ,
        [](double x, double y, double z) { return std::array<double, 3>{x, y, z}; }, colors);
    result.excludingY = buildMaterialPlane(csx, displayGrid, grid.x, grid.z, fixedY,
        [](double x, double z, double y) { return std::array<double, 3>{x, y, z}; }, colors);
    result.excludingX = buildMaterialPlane(csx, displayGrid, grid.y, grid.z, fixedX,
        [](double y, double z, double x) { return std::array<double, 3>{x, y, z}; }, colors);
    NSMutableArray<EMSGeometryGridLayer*>* selectableLayers = [NSMutableArray array];
    double z = 0;
    for (const auto& layer : config.layers()) {
        if (layer.kind() == kiems::LayerKind::Substrate) {
            z -= layer.thickness();
            continue;
        }
        if (layer.kind() != kiems::LayerKind::Metal) continue;
        NSData* edgeColors = buildMaterialEdgeColors(csx, displayGrid, grid.x, grid.y, z,
            [](double x, double y, double fixedZ) { return std::array<double, 3>{x, y, fixedZ}; }, colors);
        [selectableLayers addObject:[[EMSGeometryGridLayer alloc] initWithName:@(layer.name().c_str())
                                                                            z:z
                                                                   edgeColors:edgeColors]];
    }
    result.layers = selectableLayers;
    result.materials = colors.legend();
    return result;
}

} // namespace

EMSGeometryPreview* buildGeometryPreview(const SlicedBoard& sliced, const SimulationConfig& simConfig,
                                          const EMSConfig& scaledConfig, const PathsConfig& paths,
                                          const kiems::ComputedGridLines* gridLines) {
    // Best-effort: the board's own KiCad color theme, if readable (see layerColors's own doc
    // comment for what "readable" means outside a full GUI session) -- a lookup failure here isn't
    // fatal to the geometry step itself, it just leaves every layer's hexColor nil, which callers
    // fall back to their own default palette for.
    std::unordered_map<std::string, std::string> colorsByLayerName;
    if (auto colorsResult = kiems::libkicad_query::layerColors(paths, "Reading layer colors"); colorsResult) {
        for (const auto& layerColor : *colorsResult) {
            colorsByLayerName.emplace(layerColor.name, layerColor.hex);
        }
    }

    const auto metals = scaledConfig.getMetals();
    // One entry per metal layer, in the same stackup order as `metals`/sliced.previewLayerTriangles
    // -- exactly mirrors kiems::Simulation::addGerbers()/getMetalLayerOffset()'s own walk of the
    // full interleaved layer list, so a copper layer here ends up at the identical Z the real FDTD
    // geometry places it at (board top always 0, cumulative substrate thickness subtracted going
    // down) -- not an even-spacing approximation across the board's own extent. Uses
    // previewLayerTriangles (via/NPTH holes cut, for a via's own open barrel to sit in real empty
    // space -- see that field's own doc comment), *not* the plain layerTriangles the real FDTD
    // geometry itself uses (which deliberately skips that cut as wasted, redundant work there).
    std::vector<double> metalOffsets;
    {
        double offset = 0;
        for (const auto& layer : scaledConfig.layers()) {
            if (layer.kind() == kiems::LayerKind::Substrate) {
                offset -= layer.thickness();
            } else if (layer.kind() == kiems::LayerKind::Metal) {
                metalOffsets.push_back(offset);
            }
        }
    }
    NSMutableArray<EMSGeometryLayer*>* layers = [NSMutableArray arrayWithCapacity:sliced.previewLayerTriangles.size()];
    for (std::size_t layerIndex = 0; layerIndex < sliced.previewLayerTriangles.size(); ++layerIndex) {
        NSString* layerName = layerIndex < metals.size()
                                   ? @(metals[layerIndex].name().c_str())
                                   : [NSString stringWithFormat:@"Layer %zu", layerIndex];
        NSString* hexColor = nil;
        if (layerIndex < metals.size()) {
            auto colorIt = colorsByLayerName.find(metals[layerIndex].name());
            if (colorIt != colorsByLayerName.end()) {
                hexColor = @(colorIt->second.c_str());
            }
        }
        const auto& triangles = sliced.previewLayerTriangles[layerIndex];
        NSMutableArray<EMSGeometryTriangle*>* layerTriangles = [NSMutableArray arrayWithCapacity:triangles.size()];
        for (const auto& triangle : triangles) {
            [layerTriangles addObject:[[EMSGeometryTriangle alloc] initWithA:toCGPoint(triangle.a)
                                                                              b:toCGPoint(triangle.b)
                                                                              c:toCGPoint(triangle.c)]];
        }
        const double layerZ = layerIndex < metalOffsets.size() ? metalOffsets[layerIndex] : 0;
        [layers addObject:[[EMSGeometryLayer alloc] initWithName:layerName
                                                          triangles:layerTriangles
                                                          hexColor:hexColor
                                                                  z:layerZ]];
    }

    NSMutableArray<NSValue*>* outline = [NSMutableArray arrayWithCapacity:sliced.outline.size()];
    for (const auto& point : sliced.outline) {
        [outline addObject:[NSValue valueWithPoint:NSMakePoint(point.x(), point.y())]];
    }

    NSMutableArray<NSValue*>* failedViaAttempts =
        [NSMutableArray arrayWithCapacity:sliced.failedStitchingViaAttempts.size()];
    for (const auto& point : sliced.failedStitchingViaAttempts) {
        [failedViaAttempts addObject:[NSValue valueWithPoint:NSMakePoint(point.x(), point.y())]];
    }

    NSMutableArray<EMSGeometryVia*>* vias = [NSMutableArray arrayWithCapacity:sliced.stitchingVias.size()];
    for (const auto& via : sliced.stitchingVias) {
        // Always a plain round hole in a plain round pad -- board-slicing only ever invents round
        // stitching vias (see Simulation::addVias()'s own comment) -- so both the hole's and the
        // ring's "capsule" collapse to the same single point.
        const CGPoint point = CGPointMake(via.x, via.y);
        [vias addObject:[[EMSGeometryVia alloc] initWithPosition:point
                                                            position2:point
                                                        ringPosition:point
                                                       ringPosition2:point
                                                            diameter:via.diameter
                                                annularRingDiameter:via.annularRingDiameter]];
    }

    // Real board vias (from the KiCad board) -- kept only where they still overlap this
    // simulation's sliced outline, exactly like Simulation::addVias() itself (see
    // viaIntersectsOutline's own doc comment for why that's a disc test, not just the via center).
    // These are already baked into the actual FDTD geometry the geometry step just built; without
    // adding them here too, the preview only ever showed the synthetic stitching vias, never the
    // board's own real ones. getVias() needs the same Edge_Cuts-bounding-box re-origin every other
    // coordinate this preview uses already has (see getVias()'s own doc comment) -- re-derived here
    // rather than threaded through, matching sliceBoardForSimulation()'s own internal re-derivation
    // of the identical value.
    if (auto originResult = boardOrigin(paths); originResult) {
        // Queried once, up front, rather than per-via -- see buildRealHoleSizes()'s own comment.
        const std::vector<RealHoleSize> realHoleSizes =
            buildRealHoleSizes(paths, originResult->first, originResult->second);
        if (auto realVias = kiems::getVias(paths, originResult->first, originResult->second); realVias) {
            for (const auto& via : *realVias) {
                // Tested against both ends of the via's own centerline -- for a plain round via
                // (x2==x, y2==y) this is just the same point twice; for an elongated one (see
                // ViaHole's own doc comment) either end can independently straddle the cutout
                // boundary.
                if (!viaIntersectsOutline(via.x, via.y, via.diameter, sliced.outline) &&
                    !viaIntersectsOutline(via.x2, via.y2, via.diameter, sliced.outline)) {
                    continue;
                }
                // Matched against the board's own real pad/ring size (see
                // matchRealHoleSize()/buildRealHoleSizes()) by this via's own centerline midpoint --
                // exactly (via.x, via.y) for a round via, the actual pad/via center for an elongated
                // one, matching how KiCad itself reports a through-hole's position. Falls back to a
                // flat margin over platingThickness (see kPreviewViaAnnularRingMarginSimUnits's own
                // comment), with the ring sharing the hole's own centerline (so a single radius, as
                // before), only if no real size was found for this specific via -- normally just a
                // missing/stale libkicad_smoketest, not something a real board hits.
                const CGPoint holePos = CGPointMake(via.x, via.y);
                const CGPoint holePos2 = CGPointMake(via.x2, via.y2);
                CGPoint ringPos = holePos;
                CGPoint ringPos2 = holePos2;
                double outerDiameter;
                if (auto matched = matchRealHoleSize(realHoleSizes, (via.x + via.x2) / 2, (via.y + via.y2) / 2);
                    matched) {
                    // ringCapsuleForRealPad's own comment explains why the ring needs its own
                    // capsule geometry rather than reusing the hole's -- picking a single "diameter"
                    // (the pad's longer dimension) and applying it as a radius around the hole's own
                    // centerline is what made an oblong SHIELD pad render roughly 1.5x too big on
                    // both axes, large enough to visually overlap unrelated nearby copper.
                    std::tie(ringPos, ringPos2) =
                        ringCapsuleForRealPad(holePos, holePos2, matched->padWidthSim, matched->padHeightSim);
                    outerDiameter = std::min(matched->padWidthSim, matched->padHeightSim);
                } else {
                    outerDiameter = via.diameter +
                                     2 * std::max(scaledConfig.via().platingThickness(), kPreviewViaAnnularRingMarginSimUnits);
                }
                [vias addObject:[[EMSGeometryVia alloc] initWithPosition:holePos
                                                                    position2:holePos2
                                                                ringPosition:ringPos
                                                               ringPosition2:ringPos2
                                                                    diameter:via.diameter
                                                        annularRingDiameter:outerDiameter]];
            }
        }
    }

    // Real 3D geometry for every via just placed above -- see EMSGeometryPreview.viaMeshTriangles'
    // own doc comment. Built from `vias` itself (already-resolved sim-unit positions/diameters, both
    // stitching and real alike), not re-derived from raw via data, and after metalOffsets (computed
    // earlier for EMSGeometryLayer's own Z placement) is already in scope.
    NSMutableArray<EMSGeometryComponentTriangle*>* viaTriangles = [NSMutableArray array];
    for (EMSGeometryVia* via in vias) {
        appendViaMesh(via, metalOffsets, viaTriangles);
    }

    NSMutableArray<EMSGeometryPort*>* ports = [NSMutableArray arrayWithCapacity:simConfig.ports().size()];
    for (const auto& port : simConfig.ports()) {
        if (!port.position().has_value()) {
            continue;
        }
        const auto [x, y] = *port.position();
        [ports addObject:[[EMSGeometryPort alloc] initWithName:@(port.name().c_str())
                                                          position:CGPointMake(x, y)
                                                             width:port.width()
                                                            length:port.length()
                                                      absorbSignal:port.absorbSignal() ? YES : NO]];
    }

    // Real 3D models of every footprint this simulation touches -- see EMSGeometryComponentTriangle's
    // own doc comment. Best-effort throughout (see exportComponentTriangles()'s own comment):
    // rendered/renderedRefs both just come back empty on any failure, never a hard error for the
    // whole geometry preview.
    NSMutableArray<NSString*>* renderedRefs = [NSMutableArray array];
    NSMutableArray<EMSGeometryComponentTriangle*>* componentTriangles = [NSMutableArray array];
    NSMutableArray<NSString*>* componentModelExportMessages = [NSMutableArray array];
    {
        const std::vector<std::string> refs = includedFootprintReferences(simConfig);
        logInfo("GeometryPreview: includedFootprintReferences() -> " + std::to_string(refs.size()) +
                              " reference(s)");
        for (const auto& ref : refs) {
            [renderedRefs addObject:@(ref.c_str())];
        }
        if (auto originResult = boardOrigin(paths); originResult) {
            const ComponentExportOutcome outcome = exportComponentTriangles(paths, refs);
            for (const auto& message : outcome.messages) {
                [componentModelExportMessages addObject:@(message.c_str())];
            }
            componentTriangles = [NSMutableArray arrayWithCapacity:outcome.triangles.size()];
            // Z is deliberately NOT offset by originResult -- Z has no separate per-axis local
            // origin anywhere else in this preview (see the pmlInnerZMin/ZMax property's own doc
            // comment), only X/Y are. libkicad's own STEP/STL Z=0 does NOT line up with this
            // codebase's "board top always 0" convention -- confirmed against a real board:
            // STEP_PCB_MODEL::getBoardBodyZPlacement() (step_pcb_model.cpp) places Z=0 at *bottom*
            // copper (its own wxASSERT(aZPos == 0.0) says as much). A first attempt re-based this
            // using metalOffsets.back() (the bottom metal layer's own idealized, zero-copper-
            // thickness offset, already computed above for the real layer rendering) -- close, but
            // wrong: metalOffsets deliberately omits every copper layer's own real thickness (this
            // preview's FDTD geometry treats copper as infinitesimally thin sheets), while KiCad's
            // own component placement (getModelLocation()) is built on real, physical copper
            // thickness for every internal AND external layer -- a gap of a full board's worth of
            // copper thickness, visibly "still wrong" even after the first fix. outcome.topCopperZMm
            // is libkicad's own already-correct answer for exactly this (see its own doc comment for
            // the precise derivation) -- subtracting it re-bases KiCad's real, physical Z directly
            // onto this preview's own idealized top-copper-at-Z=0 convention, with no re-derivation
            // (and no chance of reproducing the same real-vs-idealized-copper mismatch) needed here.
            const double topCopperZSim = mmToSimUnits(outcome.topCopperZMm);
            const auto toSim = [&](double xMm, double yMm, double zMm) {
                return simd_make_double3(mmToSimUnits(xMm) - originResult->first,
                                          mmToSimUnits(yMm) - originResult->second,
                                          mmToSimUnits(zMm) - topCopperZSim);
            };
            for (const auto& triangle : outcome.triangles) {
                [componentTriangles
                    addObject:[[EMSGeometryComponentTriangle alloc]
                                  initWithA:toSim(triangle.ax, triangle.ay, triangle.az)
                                          b:toSim(triangle.bx, triangle.by, triangle.bz)
                                          c:toSim(triangle.cx, triangle.cy, triangle.cz)
                                      color:simd_make_double4(triangle.r, triangle.g, triangle.b, triangle.a)]];
            }
        } else {
            logWarning("GeometryPreview: board outline query failed, skipping component model "
                                     "export entirely: " + originResult.error());
        }
    }

    // gridLines->x/y come straight out of CSXCAD, which GridGenerator populates in the same
    // absolute, Edge_Cuts-bounding-box-relative frame every other position here (layers/outline/
    // vias/ports/xMin/yMin itself) is in -- GridGeneratorAxis::compileGrid() writes its lines to
    // the real mesh in that same absolute frame (not offset-subtracted; see its own comment), since
    // that's the frame the actual simulation geometry (addSubstrates()/addGerbers()/addMslPort()/
    // etc, none of which subtract this offset) is placed in too. No translation needed here.
    // pmlInner* is the one exception -- it's diagnostic-only (see GridGeneratorAxis::pmlInnerMin()'s
    // own doc comment) and deliberately stays local/offset-subtracted at the source, so it still
    // needs sliced.xMin/yMin added back below.
    NSMutableArray<NSNumber*>* gridLinesX = [NSMutableArray array];
    NSMutableArray<NSNumber*>* gridLinesY = [NSMutableArray array];
    NSMutableArray<NSNumber*>* gridLinesZ = [NSMutableArray array];
    if (gridLines) {
        gridLinesX = [NSMutableArray arrayWithCapacity:gridLines->x.size()];
        for (const double line : gridLines->x) {
            [gridLinesX addObject:@(line)];
        }
        gridLinesY = [NSMutableArray arrayWithCapacity:gridLines->y.size()];
        for (const double line : gridLines->y) {
            [gridLinesY addObject:@(line)];
        }
        gridLinesZ = [NSMutableArray arrayWithCapacity:gridLines->z.size()];
        for (const double line : gridLines->z) {
            [gridLinesZ addObject:@(line)];
        }
    }

    // Solder mask -- see EMSGeometryPreview.topSolderMask/bottomSolderMask's own doc comment for why
    // this reuses EMSGeometryLayer (a flat 2D shape at one shared Z) rather than the 3D
    // EMSGeometryComponentTriangle mesh type vias/components use. z is the mask's own *outer* face
    // (offset from copper's own Z, not coincident with it), matching kiems::Simulation::
    // addSolderMask()'s own real placement -- top mask above F.Cu (Z=0), bottom mask below the last
    // copper layer (sum of every substrate's own thickness, the same computation metalOffsets above
    // already performs one layer at a time).
    double totalSubstrateThickness = 0;
    for (const auto& layer : scaledConfig.layers()) {
        if (layer.kind() == kiems::LayerKind::Substrate) {
            totalSubstrateThickness += layer.thickness();
        }
    }
    EMSGeometryLayer* topSolderMask = nil;
    EMSGeometryLayer* bottomSolderMask = nil;
    for (const auto& mask : scaledConfig.getSolderMasks()) {
        const bool isTop = mask.kind() == kiems::LayerKind::SolderMaskTop;
        const std::vector<kiems::Triangle>& maskTriangles =
            isTop ? sliced.topMaskTriangles : sliced.bottomMaskTriangles;
        if (maskTriangles.empty()) {
            continue;
        }
        NSMutableArray<EMSGeometryTriangle*>* triangles =
            [NSMutableArray arrayWithCapacity:maskTriangles.size()];
        for (const auto& triangle : maskTriangles) {
            [triangles addObject:[[EMSGeometryTriangle alloc] initWithA:toCGPoint(triangle.a)
                                                                          b:toCGPoint(triangle.b)
                                                                          c:toCGPoint(triangle.c)]];
        }
        const double z = isTop ? mask.thickness() : -totalSubstrateThickness - mask.thickness();
        EMSGeometryLayer* layer = [[EMSGeometryLayer alloc] initWithName:@(mask.name().c_str())
                                                                  triangles:triangles
                                                                  hexColor:nil
                                                                          z:z];
        if (isTop) {
            topSolderMask = layer;
        } else {
            bottomSolderMask = layer;
        }
    }

    // Rebuild only the lightweight CSXCAD geometry (no CalcEC/CalcPEC and no timesteps), then
    // sample the same MATERIAL|METAL priority winner CalcPEC uses at every displayed Yee edge.
    // This is deliberately derived here rather than serialized into SimulationGrid: it is preview
    // data, and the packed Metal buffers are far smaller/faster than putting hundreds of thousands
    // of edge classifications into geometry.json.
    const MaterialGridBuffers materialGrid =
        gridLines ? buildMaterialGrid(sliced, simConfig, scaledConfig, paths, *gridLines) : MaterialGridBuffers{};

    return [[EMSGeometryPreview alloc] initWithLayers:layers
                                          topSolderMask:topSolderMask
                                       bottomSolderMask:bottomSolderMask
                                                outline:outline
                                                   vias:vias
                                      failedViaAttempts:failedViaAttempts
                                                  ports:ports
                                       viaMeshTriangles:viaTriangles
                                 componentMeshTriangles:componentTriangles
                           renderedComponentReferences:renderedRefs
                          componentModelExportMessages:componentModelExportMessages
                                             gridLinesX:gridLinesX
                                             gridLinesY:gridLinesY
                                             gridLinesZ:gridLinesZ
                                   gridPlaneExcludingX:materialGrid.excludingX
                                   gridPlaneExcludingY:materialGrid.excludingY
                                   gridPlaneExcludingZ:materialGrid.excludingZ
                                         gridMaterials:materialGrid.materials
                                            gridLayers:materialGrid.layers
                                           pmlInnerXMin:gridLines ? gridLines->pmlInnerXMin + sliced.xMin : 0
                                           pmlInnerXMax:gridLines ? gridLines->pmlInnerXMax + sliced.xMin : 0
                                           pmlInnerYMin:gridLines ? gridLines->pmlInnerYMin + sliced.yMin : 0
                                           pmlInnerYMax:gridLines ? gridLines->pmlInnerYMax + sliced.yMin : 0
                                           pmlInnerZMin:gridLines ? gridLines->pmlInnerZMin : 0
                                           pmlInnerZMax:gridLines ? gridLines->pmlInnerZMax : 0
                                                   xMin:sliced.xMin
                                                   yMin:sliced.yMin
                                                  width:sliced.width
                                                 height:sliced.height];
}
