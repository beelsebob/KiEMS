#import "GeometryPreviewBridge.h"
#import "GeometryPreviewBridge+Private.h"

#include <dispatch/dispatch.h>

#include <algorithm>
#include <array>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <filesystem>
#include <functional>
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
#include "libkicad/libkicad.hpp"
#include "libkicad/board_load_timing.hpp"
#include "logging.hpp"
#include "kiems/paths_config.hpp"

#include "CopperFDTDRunner.h"
#include "Copper/Internal/CopperDomain.hpp"

using kiems::EMSConfig;
using namespace Cu;
using kiems::PathsConfig;
using kiems::SimulationConfig;
using kiems::SlicedBoard;

namespace {

CGPoint toCGPoint(const kiems::Position& position) {
    return CGPointMake(position.x(), position.y());
}

// Matches port_resolution.cpp's own (private) _mmToSimUnits exactly -- kiems::ki's
// results (like every other ki position) come back in millimetres, board-auxiliary-
// origin-relative; this pipeline's own native frame is simulation units, further re-origined to the
// board's Edge_Cuts bounding box (see getVias()'s own doc comment) -- the bounding-box shift still
// needs applying by the caller, this just handles the unit conversion.
double mmToSimUnits(double mm) { return mm / 1000.0 / kiems::constants::baseUnit * kiems::constants::unitMultiplier; }

std::expected<std::pair<double, double>, std::string> boardOrigin(const libkicad::Board& board) {
    auto geometry = board.boardGeometry();
    if (!geometry) {
        return std::unexpected(std::move(geometry).error());
    }
    double xMin = std::numeric_limits<double>::infinity();
    double yMin = std::numeric_limits<double>::infinity();
    for (const libkicad::PolygonLoop& loop : geometry->outline) {
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

Polygon previewPolygonLoop(const libkicad::PolygonLoop& loop, double originX, double originY) {
    Polygon path;
    path.reserve(loop.pointsMm.size());
    for (const auto& [xMm, yMm] : loop.pointsMm) {
        path.emplace_back(mmToSimUnits(xMm) - originX, mmToSimUnits(yMm) - originY);
    }
    const bool shouldBePositive = !loop.hole;
    if (path.size() >= 3 && isPositive(path) != shouldBePositive) {
        std::reverse(path.begin(), path.end());
    }
    return path;
}

PolygonSet previewPolygonLoops(const std::vector<libkicad::PolygonLoop>& loops,
                               double originX, double originY) {
    PolygonSet result;
    result.reserve(loops.size());
    for (const auto& loop : loops) {
        Polygon path = previewPolygonLoop(loop, originX, originY);
        if (path.size() >= 3) result.push_back(std::move(path));
    }
    return result;
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
// libkicad::ThroughHole's own doc comment) once per geometry build, converting
// each into this preview's frame. Best-effort: an empty result leaves every via falling back to
// kPreviewViaAnnularRingMarginSimUnits instead, not a hard error -- the ring is a cosmetic preview
// detail, never worth failing the whole geometry step over.
std::vector<RealHoleSize> buildRealHoleSizes(const libkicad::Board& board, double originX, double originY) {
    std::vector<RealHoleSize> sizes;
    auto holesResult = board.throughHoles();
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

// Every footprint modelled as a lumped R/L/C component (see
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
// exporter reported building it (see libkicad::ComponentModelExportResult's own
// doc comment) -- surfaced to the caller so "the mesh is missing/wrong" is distinguishable from
// "this specific component's 3D model file couldn't be resolved," rather than both collapsing to a
// silent empty result.
struct ComponentExportOutcome {
    std::vector<libkicad::ComponentTriangle> triangles;
    std::vector<std::string> messages;
    // The board's real top-copper mounting surface Z, in the same mm frame `triangles`' own
    // vertices are in -- see libkicad::ComponentModelExportResult::topCopperZMm's
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
ComponentExportOutcome exportComponentTriangles(const libkicad::Board& board, const std::vector<std::string>& refs) {
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
    // Never next to the board itself: a whole-board preview queries the user's own KiCad project
    // directory directly.
    std::error_code tempError;
    std::filesystem::path artifactDir = std::filesystem::temp_directory_path(tempError);
    if (tempError) artifactDir = "/tmp";
    const std::size_t artifactKey = std::hash<std::string>{}(board.paths().boardPath + "\n" + refsCsv);
    const std::filesystem::path outPath =
        artifactDir / ("kiems_geometry_preview_components_" + std::to_string(artifactKey) + ".stl");
    logInfo("GeometryPreview: exporting component models for [" + refsCsv + "]");
    auto exportResult = board.exportComponentModels(refsCsv, outPath.string());
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
    return [self initWithA:a b:b c:c color:simd_make_double4(0, 0, 0, 0) opacity:1.0
                      kind:EMSGeometryTriangleKindGeneric netName:nil footprintReference:nil padNumber:nil];
}

- (instancetype)initWithA:(CGPoint)a b:(CGPoint)b c:(CGPoint)c color:(simd_double4)color {
    return [self initWithA:a b:b c:c color:color opacity:1.0 kind:EMSGeometryTriangleKindGeneric
                   netName:nil footprintReference:nil padNumber:nil];
}

- (instancetype)initWithA:(CGPoint)a b:(CGPoint)b c:(CGPoint)c
                     color:(simd_double4)color opacity:(double)opacity {
    return [self initWithA:a b:b c:c color:color opacity:opacity kind:EMSGeometryTriangleKindGeneric
                   netName:nil footprintReference:nil padNumber:nil];
}

- (instancetype)initWithA:(CGPoint)a b:(CGPoint)b c:(CGPoint)c
                     color:(simd_double4)color opacity:(double)opacity
                      kind:(EMSGeometryTriangleKind)kind
                   netName:(nullable NSString*)netName
        footprintReference:(nullable NSString*)footprintReference
                 padNumber:(nullable NSString*)padNumber {
    self = [super init];
    if (self) {
        _a = a;
        _b = b;
        _c = c;
        _color = color;
        _opacity = opacity;
        _kind = kind;
        _netName = [netName copy];
        _footprintReference = [footprintReference copy];
        _padNumber = [padNumber copy];
    }
    return self;
}
@end


@implementation EMSGeometryLayer
+ (instancetype)placeholderWithName:(NSString*)name hexColor:(nullable NSString*)hexColor z:(double)z {
    EMSGeometryLayer* layer = [[self alloc] initWithName:name triangles:@[] hexColor:hexColor z:z];
    layer->_geometryGenerated = NO;
    return layer;
}
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
        _geometryGenerated = YES;
    }
    return self;
}
- (void)replaceTriangles:(NSArray<EMSGeometryTriangle*>*)triangles {
    _triangles = [triangles copy];
    _geometryGenerated = YES;
    _revision++;
}
- (void)replaceTriangles:(NSArray<EMSGeometryTriangle*>*)triangles z:(double)z {
    [self replaceTriangles:triangles];
    _z = z;
}
@end

@implementation EMSGeometryVia
- (instancetype)initWithPosition:(CGPoint)position
                        position2:(CGPoint)position2
                     ringPosition:(CGPoint)ringPosition
                    ringPosition2:(CGPoint)ringPosition2
                         diameter:(double)diameter
              annularRingDiameter:(double)annularRingDiameter
                          netName:(NSString* _Nullable)netName {
    self = [super init];
    if (self) {
        _position = position;
        _position2 = position2;
        _ringPosition = ringPosition;
        _ringPosition2 = ringPosition2;
        _diameter = diameter;
        _annularRingDiameter = annularRingDiameter;
        _netName = [netName copy];
    }
    return self;
}
@end

@implementation EMSGeometryTrackSegment
- (instancetype)initWithNetName:(NSString*)netName
                        layerName:(NSString*)layerName
                            start:(CGPoint)start
                              end:(CGPoint)end {
    self = [super init];
    if (self) {
        _netName = [netName copy];
        _layerName = [layerName copy];
        _start = start;
        _end = end;
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
    return [self initWithA:a b:b c:c color:color netName:nil footprintReference:nil];
}

- (instancetype)initWithA:(simd_double3)a b:(simd_double3)b c:(simd_double3)c
                     color:(simd_double4)color netName:(nullable NSString*)netName {
    return [self initWithA:a b:b c:c color:color netName:netName footprintReference:nil];
}

- (instancetype)initWithA:(simd_double3)a b:(simd_double3)b c:(simd_double3)c
                     color:(simd_double4)color netName:(nullable NSString*)netName
        footprintReference:(nullable NSString*)footprintReference {
    self = [super init];
    if (self) {
        _a = a;
        _b = b;
        _c = c;
        _color = color;
        _netName = [netName copy];
        _footprintReference = [footprintReference copy];
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
                     wholeBoard:(BOOL)wholeBoard
                  topSolderMask:(EMSGeometryLayer* _Nullable)topSolderMask
               bottomSolderMask:(EMSGeometryLayer* _Nullable)bottomSolderMask
                        outline:(NSArray<NSValue*>*)outline
                           vias:(NSArray<EMSGeometryVia*>*)vias
                  trackSegments:(NSArray<EMSGeometryTrackSegment*>*)trackSegments
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
        _wholeBoard = wholeBoard;
        _layers = [layers copy];
        _topSolderMask = topSolderMask;
        _bottomSolderMask = bottomSolderMask;
        _outline = [outline copy];
        _vias = [vias copy];
        _trackSegments = [trackSegments copy];
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
- (void)mergeLoadedPreview:(EMSGeometryPreview*)preview {
    _revision++;
    NSMutableDictionary<NSString*, EMSGeometryLayer*>* incoming = [NSMutableDictionary dictionary];
    for (EMSGeometryLayer* layer in preview.layers) incoming[layer.name] = layer;
    for (EMSGeometryLayer* layer in _layers) {
        EMSGeometryLayer* loaded = incoming[layer.name];
        if (loaded != nil && loaded.geometryGenerated) {
            [layer replaceTriangles:loaded.triangles z:loaded.z];
        }
    }
    _topSolderMask = preview.topSolderMask;
    _bottomSolderMask = preview.bottomSolderMask;
    _outline = [preview.outline copy];
    _vias = [preview.vias copy];
    _trackSegments = [preview.trackSegments copy];
    _failedViaAttempts = [preview.failedViaAttempts copy];
    _ports = [preview.ports copy];
    _viaMeshTriangles = [preview.viaMeshTriangles copy];
    _componentMeshTriangles = [preview.componentMeshTriangles copy];
    _renderedComponentReferences = [preview.renderedComponentReferences copy];
    _componentModelExportMessages = [preview.componentModelExportMessages copy];
    _gridLinesX = [preview.gridLinesX copy];
    _gridLinesY = [preview.gridLinesY copy];
    _gridLinesZ = [preview.gridLinesZ copy];
    _gridPlaneExcludingX = preview.gridPlaneExcludingX;
    _gridPlaneExcludingY = preview.gridPlaneExcludingY;
    _gridPlaneExcludingZ = preview.gridPlaneExcludingZ;
    _gridMaterials = [preview.gridMaterials copy];
    _gridLayers = [preview.gridLayers copy];
    _pmlInnerXMin = preview.pmlInnerXMin;
    _pmlInnerXMax = preview.pmlInnerXMax;
    _pmlInnerYMin = preview.pmlInnerYMin;
    _pmlInnerYMax = preview.pmlInnerYMax;
    _pmlInnerZMin = preview.pmlInnerZMin;
    _pmlInnerZMax = preview.pmlInnerZMax;
    _xMin = preview.xMin;
    _yMin = preview.yMin;
    _width = preview.width;
    _height = preview.height;
}
@end

namespace {

// ---- Real 3D via geometry (see EMSGeometryPreview.viaMeshTriangles' own doc comment) ----
// Placed here, after every @implementation above, rather than in the main anonymous namespace this
// file starts with: it needs EMSGeometryComponentTriangle's own initWithA:b:c:color: (implemented
// above), which Objective-C requires to already be visible at the call site, unlike a plain C++
// function that could be forward-declared -- these helpers are only ever called from
// buildGeometryPreview() just below anyway, so this is also exactly where they're used.

// A consistent ENIG-like gold tone for every via's own barrel tube and annular rings, regardless of
// layer. The muted red/blue-balanced #C69B3C avoids the pure-yellow appearance of the old #EBB500
// flat-marker stroke while still reading as exposed gold-plated copper under the PBR lighting.
// Real per-layer color
// matching (each ring tinted like that specific layer's own assigned UI color) isn't attempted:
// real via copper is coppery regardless of what arbitrary display color a layer's been assigned, and
// this file has no hex-color-string parser to reuse for it (see EMSGeometryLayer.hexColor, parsed
// only on the Swift side today).
constexpr double kViaCopperR = 0xC6 / 255.0;
constexpr double kViaCopperG = 0x9B / 255.0;
constexpr double kViaCopperB = 0x3C / 255.0;

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
                     NSString* _Nullable netName,
                     NSMutableArray<EMSGeometryComponentTriangle*>* triangles) {
    const simd_double3 aTop = simd_make_double3(a.x, a.y, zTop);
    const simd_double3 bTop = simd_make_double3(b.x, b.y, zTop);
    const simd_double3 aBottom = simd_make_double3(a.x, a.y, zBottom);
    const simd_double3 bBottom = simd_make_double3(b.x, b.y, zBottom);
    [triangles addObject:[[EMSGeometryComponentTriangle alloc]
                             initWithA:aTop b:bTop c:aBottom color:color netName:netName]];
    [triangles addObject:[[EMSGeometryComponentTriangle alloc]
                             initWithA:bTop b:bBottom c:aBottom color:color netName:netName]];
}

/// Appends two triangles forming one flat quad of an annular-ring washer at a fixed `z`, between
/// corresponding boundary-point pairs from the outer (ring) and inner (hole) capsules -- see
/// capsuleBoundaryPoints()'s own doc comment for why `outerA`/`outerB`/`innerA`/`innerB` are safe to
/// connect directly by shared index without any twist.
void appendAnnulusQuad(CGPoint outerA, CGPoint outerB, CGPoint innerA, CGPoint innerB, double z, simd_double4 color,
                       NSString* _Nullable netName,
                       NSMutableArray<EMSGeometryComponentTriangle*>* triangles) {
    const simd_double3 oa = simd_make_double3(outerA.x, outerA.y, z);
    const simd_double3 ob = simd_make_double3(outerB.x, outerB.y, z);
    const simd_double3 ia = simd_make_double3(innerA.x, innerA.y, z);
    const simd_double3 ib = simd_make_double3(innerB.x, innerB.y, z);
    [triangles addObject:[[EMSGeometryComponentTriangle alloc]
                             initWithA:oa b:ob c:ia color:color netName:netName]];
    [triangles addObject:[[EMSGeometryComponentTriangle alloc]
                             initWithA:ob b:ib c:ia color:color netName:netName]];
}

struct IndexedHoleCutout {
    PolygonSet polygons;
    BoundingBox<double> bounds;
};

BoundingBox<double> polygonSetBounds(const PolygonSet& polygons) {
    BoundingBox<double> result;
    for (const Polygon& polygon : polygons) {
        const BoundingBox<double> polygonBounds = bounds(polygon);
        result.xMin = std::min(result.xMin, polygonBounds.xMin);
        result.xMax = std::max(result.xMax, polygonBounds.xMax);
        result.yMin = std::min(result.yMin, polygonBounds.yMin);
        result.yMax = std::max(result.yMax, polygonBounds.yMax);
    }
    return result;
}

BoundingBox<double> capsuleBounds(CGPoint a, CGPoint b, double radius) {
    BoundingBox<double> result;
    result.xMin = std::min(a.x, b.x) - radius;
    result.xMax = std::max(a.x, b.x) + radius;
    result.yMin = std::min(a.y, b.y) - radius;
    result.yMax = std::max(a.y, b.y) + radius;
    return result;
}

bool boundsOverlap(const BoundingBox<double>& a, const BoundingBox<double>& b) {
    return a.xMin <= b.xMax && a.xMax >= b.xMin && a.yMin <= b.yMax && a.yMax >= b.yMin;
}

std::vector<std::size_t> overlappingCutoutIndices(const std::vector<IndexedHoleCutout>& cutouts,
                                                   const BoundingBox<double>& target) {
    std::vector<std::size_t> result;
    for (std::size_t i = 0; i < cutouts.size(); ++i) {
        if (boundsOverlap(cutouts[i].bounds, target)) result.push_back(i);
    }
    return result;
}

std::vector<std::size_t> overlappingCutoutIndices(const std::vector<IndexedHoleCutout>& cutouts,
                                                   const PolygonSet& targets) {
    std::vector<BoundingBox<double>> targetBounds;
    targetBounds.reserve(targets.size());
    for (const Polygon& target : targets) {
        // A negative loop is a void within a positive shell, not copper that needs drilling.
        if (target.size() >= 3 && isPositive(target)) targetBounds.push_back(bounds(target));
    }
    // Preserve the standalone-clockwise behavior supported by the polygon adapter.
    if (targetBounds.empty()) {
        for (const Polygon& target : targets) {
            if (target.size() >= 3) targetBounds.push_back(bounds(target));
        }
    }

    std::vector<std::size_t> result;
    for (std::size_t i = 0; i < cutouts.size(); ++i) {
        if (std::any_of(targetBounds.begin(), targetBounds.end(), [&](const BoundingBox<double>& target) {
                return boundsOverlap(cutouts[i].bounds, target);
            })) {
            result.push_back(i);
        }
    }
    return result;
}

PolygonSet gatherCutouts(const std::vector<IndexedHoleCutout>& cutouts,
                         const std::vector<std::size_t>& indices) {
    PolygonSet result;
    std::size_t loopCount = 0;
    for (const std::size_t index : indices) loopCount += cutouts[index].polygons.size();
    result.reserve(loopCount);
    for (const std::size_t index : indices) {
        result.insert(result.end(), cutouts[index].polygons.begin(), cutouts[index].polygons.end());
    }
    return result;
}

struct WholeBoardCopperGroup {
    std::string key;
    std::string netName;
    std::string footprintReference;
    std::string padNumber;
    EMSGeometryTriangleKind kind = EMSGeometryTriangleKindTrace;
    PolygonSet rawPolygons;
    std::vector<Triangle> triangles;
    std::string error;
};

void buildWholeBoardCopperGroup(WholeBoardCopperGroup& group, const std::string& layerName,
                                const std::vector<IndexedHoleCutout>& platedHoleCutouts,
                                const PolygonSet& allPlatedHoleCutouts, double tessellationTolerance) {
    try {
        // A single positive KiCad contour is already a valid composited polygon. Larger groups use
        // GEOS's disjoint-subset union, which identifies disconnected pad/track clusters and only
        // overlays members that can interact.
        PolygonSet visibleCopper =
            group.rawPolygons.size() == 1 && isPositive(group.rawPolygons.front())
                ? group.rawPolygons
                : unionDisjointSubsets(group.rawPolygons);

        if (!platedHoleCutouts.empty() && !visibleCopper.empty()) {
            // Compare against every source copper shell rather than the enclosing box of a whole,
            // potentially board-spanning net. A drill can affect the union only if it can affect at
            // least one of its inputs, so this tighter filter cannot discard a real intersection.
            const std::vector<std::size_t> candidates =
                overlappingCutoutIndices(platedHoleCutouts, group.rawPolygons);
            if (!candidates.empty()) {
                PolygonSet localCutouts;
                const PolygonSet* clip = &allPlatedHoleCutouts;
                if (candidates.size() != platedHoleCutouts.size()) {
                    localCutouts = gatherCutouts(platedHoleCutouts, candidates);
                    if (candidates.size() > 1) localCutouts = unionDisjointSubsets(localCutouts);
                    clip = &localCutouts;
                }
                visibleCopper = differenceCompositedPolygons(visibleCopper, *clip);
            }
        }

        group.triangles =
            triangulateComposited(visibleCopper, tessellationTolerance, layerName + " (" + group.netName + ")");
    } catch (const std::exception& exception) {
        group.error = exception.what();
    }
}

/// Real 3D geometry for one via -- see EMSGeometryPreview.viaMeshTriangles' own doc comment for what
/// and why. `metalOffsets` is buildGeometryPreview()'s own per-layer Z list (board top to bottom, in
/// stackup order) -- every via is treated as reaching every layer (see viaHolePolygons' own comment
/// in board_slicing.cpp for why that's the simplifying assumption already in force everywhere else a
/// via is modeled in this codebase), so the tube spans metalOffsets' own full range and a ring is
/// added at every one of its entries, not just some. When `ringCutouts` is supplied, the flat ring
/// surfaces are polygon-triangulated after subtracting the spatially-selected drills that can touch
/// it, so a neighbouring via can punch through a large mounting-hole annulus as it does in KiCad.
void appendViaMesh(const EMSGeometryVia* via, const std::vector<double>& metalOffsets,
                    NSMutableArray<EMSGeometryComponentTriangle*>* triangles,
                    const PolygonSet* ringCutouts = nullptr, double tessellationTolerance = 0) {
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
        appendTubeQuad(holeBoundary[i], holeBoundary[(i + 1) % n], zTop, zBottom, color,
                       via.netName, triangles);
    }

    // Annular-ring washer at every metal layer -- skipped entirely if the ring isn't actually wider
    // than the hole (a via with no real/fallback ring size at all, annularRingDiameter <= diameter,
    // would otherwise produce a degenerate or inverted ring).
    const double ringRadius = via.annularRingDiameter / 2;
    if (ringRadius <= holeRadius) {
        return;
    }

    if (ringCutouts != nullptr) {
        const Polygon ringCenterline = {
            {via.ringPosition.x, via.ringPosition.y},
            {via.ringPosition2.x, via.ringPosition2.y},
        };
        const PolygonSet outerRing = bufferOpenPaths({ringCenterline}, ringRadius, tessellationTolerance);
        const PolygonSet visibleRing = differenceCompositedPolygons(outerRing, *ringCutouts);
        const std::vector<Triangle> ringTriangles =
            triangulateComposited(visibleRing, tessellationTolerance, "whole-board via annular ring");
        for (const double layerZ : metalOffsets) {
            const double z = layerZ + kViaRingZEpsilonSimUnits;
            for (const Triangle& triangle : ringTriangles) {
                [triangles addObject:[[EMSGeometryComponentTriangle alloc]
                                         initWithA:simd_make_double3(triangle.a.x(), triangle.a.y(), z)
                                                 b:simd_make_double3(triangle.b.x(), triangle.b.y(), z)
                                             c:simd_make_double3(triangle.c.x(), triangle.c.y(), z)
                                             color:color
                                           netName:via.netName]];
            }
        }
        return;
    }

    const std::vector<CGPoint> ringBoundary =
        capsuleBoundaryPoints(via.ringPosition.x, via.ringPosition.y,
                               via.ringPosition2.x, via.ringPosition2.y, ringRadius,
                               kViaBoundarySegmentsPerHalf);
    for (const double layerZ : metalOffsets) {
        const double z = layerZ + kViaRingZEpsilonSimUnits;
        for (std::size_t i = 0; i < n; ++i) {
            appendAnnulusQuad(ringBoundary[i], ringBoundary[(i + 1) % n], holeBoundary[i], holeBoundary[(i + 1) % n],
                               z, color, via.netName, triangles);
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

enum class GridDomainRegion { External, Interior, CPML };

std::size_t nearestLineIndex(const std::vector<double>& lines, double coordinate) {
    const auto upper = std::lower_bound(lines.begin(), lines.end(), coordinate);
    if (upper == lines.begin()) return 0;
    if (upper == lines.end()) return lines.size() - 1;
    const std::size_t upperIndex = static_cast<std::size_t>(upper - lines.begin());
    return std::abs(lines[upperIndex] - coordinate) < std::abs(lines[upperIndex - 1] - coordinate)
        ? upperIndex : upperIndex - 1;
}

GridDomainRegion gridDomainRegion(const kiems::ComputedGridLines& grid,
                                  const copper::CopperDomainMask& domain,
                                  const std::array<double, 3>& p0,
                                  const std::array<double, 3>& p1) {
    // A missing irregular mask is the legacy rectangular-domain case. Preserve its old display
    // exactly, including conventional rectangular X/Y PML bands.
    if (domain.empty()) {
        const double x = (p0[0] + p1[0]) * 0.5;
        const double y = (p0[1] + p1[1]) * 0.5;
        const double z = (p0[2] + p1[2]) * 0.5;
        return x < grid.pmlInnerXMin || x > grid.pmlInnerXMax ||
                       y < grid.pmlInnerYMin || y > grid.pmlInnerYMax ||
                       z < grid.pmlInnerZMin || z > grid.pmlInnerZMax
            ? GridDomainRegion::CPML : GridDomainRegion::Interior;
    }

    const auto pointClass = [&](const std::array<double, 3>& p) {
        const std::size_t x = nearestLineIndex(grid.x, p[0]);
        const std::size_t y = nearestLineIndex(grid.y, p[1]);
        return domain.at(static_cast<std::uint32_t>(x), static_cast<std::uint32_t>(y));
    };
    const std::uint8_t c0 = pointClass(p0);
    const std::uint8_t c1 = pointClass(p1);
    if (c0 == 0 && c1 == 0) return GridDomainRegion::External;

    const double z = (p0[2] + p1[2]) * 0.5;
    if (z < grid.pmlInnerZMin || z > grid.pmlInnerZMax || c0 >= 2 || c1 >= 2)
        return GridDomainRegion::CPML;
    return GridDomainRegion::Interior;
}

template <typename Place>
EMSGeometryGridPlane* buildMaterialPlane(ContinuousStructure& csx, const kiems::ComputedGridLines& grid,
                                         const copper::CopperDomainMask& domain,
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
        const GridDomainRegion region = gridDomainRegion(grid, domain, p0, p1);
        if (region == GridDomainRegion::External) return;
        const double coord[3] = {(p0[0] + p1[0]) * 0.5, (p0[1] + p1[1]) * 0.5, (p0[2] + p1[2]) * 0.5};
        CSProperties* property = csx.GetPropertyByCoordPriority(
            coord, static_cast<CSProperties::PropertyType>(CSProperties::MATERIAL | CSProperties::METAL), false);
        const PackedGridColor color = colors.color(property, region == GridDomainRegion::CPML);
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
                                const copper::CopperDomainMask& domain,
                                const std::vector<double>& valuesA, const std::vector<double>& valuesB,
                                double fixedC, Place place, GridMaterialColors& colors) {
    std::vector<PackedGridColor> edgeColors;
    const std::size_t edgeCount = (valuesA.size() - 1) * valuesB.size() + valuesA.size() * (valuesB.size() - 1);
    edgeColors.reserve(edgeCount);
    const auto append = [&](double a0, double b0, double a1, double b1) {
        const auto p0 = place(a0, b0, fixedC);
        const auto p1 = place(a1, b1, fixedC);
        const GridDomainRegion region = gridDomainRegion(grid, domain, p0, p1);
        if (region == GridDomainRegion::External) {
            edgeColors.push_back({0, 0, 0, 0});
            return;
        }
        const double coord[3] = {(p0[0] + p1[0]) * 0.5, (p0[1] + p1[1]) * 0.5, (p0[2] + p1[2]) * 0.5};
        CSProperties* property = csx.GetPropertyByCoordPriority(
            coord, static_cast<CSProperties::PropertyType>(CSProperties::MATERIAL | CSProperties::METAL), false);
        edgeColors.push_back(colors.color(property, region == GridDomainRegion::CPML));
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
                                      const EMSConfig& config, const kiems::PathsConfig& paths,
                                      const libkicad::Board& board, const kiems::ComputedGridLines& grid) {
    if (grid.x.empty() || grid.y.empty() || grid.z.empty()) return {};
    SimulationConfig configCopy = simConfig;
    kiems::RunOptions options;
    options.backend = kiems::FDTDBackend::CopperGPU;
    kiems::Simulation simulation(configCopy, config, options, paths, board);
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
    displayGrid.pmlInnerXMin += sliced.bounds.xMin;
    displayGrid.pmlInnerXMax += sliced.bounds.xMin;
    displayGrid.pmlInnerYMin += sliced.bounds.yMin;
    displayGrid.pmlInnerYMax += sliced.bounds.yMin;

    copper::CopperFDTDPortConfig domainConfig;
    for (const auto& loop : sliced.cutoutLoops) {
        std::vector<copper::CopperFDTDPortConfig::DomainPoint> outputLoop;
        outputLoop.reserve(loop.size());
        for (const auto& point : loop) outputLoop.push_back({point.x(), point.y()});
        domainConfig.domainCutoutLoops.push_back(std::move(outputLoop));
    }
    const auto pmlDepth = static_cast<std::size_t>(config.grid().absorbingBoundaryCells());
    if (grid.x.size() > 2 * pmlDepth && grid.y.size() > 2 * pmlDepth) {
        domainConfig.domainPadding = std::max({sliced.bounds.xMin - grid.x[pmlDepth],
                                               grid.x[grid.x.size() - pmlDepth - 1] - sliced.bounds.xMax,
                                               sliced.bounds.yMin - grid.y[pmlDepth],
                                               grid.y[grid.y.size() - pmlDepth - 1] - sliced.bounds.yMax});
    }
    domainConfig.domainCPMLCellSize = config.grid().max();
    const copper::CopperDomainMask domain =
        copper::buildDomainMask(grid.x, grid.y, domainConfig, static_cast<std::uint32_t>(pmlDepth));

    GridMaterialColors colors(config);
    MaterialGridBuffers result;
    const double fixedX = grid.x[midpointLineIndex(grid.x)];
    const double fixedY = grid.y[midpointLineIndex(grid.y)];
    const double fixedZ = grid.z[midpointLineIndex(grid.z)];
    result.excludingZ = buildMaterialPlane(csx, displayGrid, domain, grid.x, grid.y, fixedZ,
        [](double x, double y, double z) { return std::array<double, 3>{x, y, z}; }, colors);
    result.excludingY = buildMaterialPlane(csx, displayGrid, domain, grid.x, grid.z, fixedY,
        [](double x, double z, double y) { return std::array<double, 3>{x, y, z}; }, colors);
    result.excludingX = buildMaterialPlane(csx, displayGrid, domain, grid.y, grid.z, fixedX,
        [](double y, double z, double x) { return std::array<double, 3>{x, y, z}; }, colors);
    NSMutableArray<EMSGeometryGridLayer*>* selectableLayers = [NSMutableArray array];
    double z = 0;
    for (const auto& layer : config.layers()) {
        if (layer.kind() == kiems::LayerKind::Substrate) {
            z -= layer.thickness();
            continue;
        }
        if (layer.kind() != kiems::LayerKind::Metal) continue;
        NSData* edgeColors = buildMaterialEdgeColors(csx, displayGrid, domain, grid.x, grid.y, z,
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
                                          const EMSConfig& scaledConfig, const kiems::PathsConfig& paths,
                                          const libkicad::Board& board,
                                          const kiems::ComputedGridLines* gridLines) {
    // Best-effort: the board's own KiCad color theme, if readable (see layerColors's own doc
    // comment for what "readable" means outside a full GUI session) -- a lookup failure here isn't
    // fatal to the geometry step itself, it just leaves every layer's hexColor nil, which callers
    // fall back to their own default palette for.
    std::unordered_map<std::string, std::string> colorsByLayerName;
    if (auto colorsResult = board.layerColors(); colorsResult) {
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
    NSMutableArray<EMSGeometryLayer*>* layers = [NSMutableArray arrayWithCapacity:sliced.previewLayerTriangles.size() + 2];
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
                                                annularRingDiameter:via.annularRingDiameter
                                                             netName:nil]];
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
    if (auto originResult = boardOrigin(board); originResult) {
        // Queried once, up front, rather than per-via -- see buildRealHoleSizes()'s own comment.
        const std::vector<RealHoleSize> realHoleSizes =
            buildRealHoleSizes(board, originResult->first, originResult->second);
        if (auto realVias = kiems::getVias(board, originResult->first, originResult->second); realVias) {
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
                // before), only if no real size was found for this specific via.
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
                                                        annularRingDiameter:outerDiameter
                                                                     netName:nil]];
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

    // Absorbing pins only have meaning inside the region actually sent to the simulator.  Keep
    // using the complete cutout here (rather than `outline`, which is only its largest loop), so
    // markers are also hidden correctly for disjoint hulls and holes.  Probe markers retain their
    // existing whole-board behaviour.
    const PolygonSet cutout = sliced.cutoutLoops.empty() ? PolygonSet{sliced.outline} : sliced.cutoutLoops;
    NSMutableArray<EMSGeometryPort*>* ports = [NSMutableArray arrayWithCapacity:simConfig.ports().size()];
    for (const auto& port : simConfig.ports()) {
        // SimulationNet resolution creates pad-port candidates even when a pin is neither loaded,
        // excited nor measured. They are bookkeeping for later excitation/pair resolution, not a
        // visible indicator. Only expose ports that represent a real action selected by the user.
        if (!port.position().has_value() ||
            !(port.absorbSignal() || port.excite() || port.probe() || port.isTraceProbe())) {
            continue;
        }
        const auto [x, y] = *port.position();
        if (port.absorbSignal() && !containsPoint(cutout, Position{x, y})) {
            continue;
        }
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
        if (auto originResult = boardOrigin(board); originResult) {
            const ComponentExportOutcome outcome = exportComponentTriangles(board, refs);
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
                                      color:simd_make_double4(triangle.r, triangle.g, triangle.b, triangle.a)
                                    netName:nil
                         footprintReference:@(triangle.footprintReference.c_str())]];
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
    // needs sliced.bounds.xMin/yMin added back below.
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
        gridLines ? buildMaterialGrid(sliced, simConfig, scaledConfig, paths, board, *gridLines) : MaterialGridBuffers{};

    return [[EMSGeometryPreview alloc] initWithLayers:layers
                                           wholeBoard:NO
                                          topSolderMask:topSolderMask
                                       bottomSolderMask:bottomSolderMask
                                                outline:outline
                                                   vias:vias
                                          trackSegments:@[]
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
                                           pmlInnerXMin:gridLines ? gridLines->pmlInnerXMin + sliced.bounds.xMin : 0
                                           pmlInnerXMax:gridLines ? gridLines->pmlInnerXMax + sliced.bounds.xMin : 0
                                           pmlInnerYMin:gridLines ? gridLines->pmlInnerYMin + sliced.bounds.yMin : 0
                                           pmlInnerYMax:gridLines ? gridLines->pmlInnerYMax + sliced.bounds.yMin : 0
                                           pmlInnerZMin:gridLines ? gridLines->pmlInnerZMin : 0
                                           pmlInnerZMax:gridLines ? gridLines->pmlInnerZMax : 0
                                                   xMin:sliced.bounds.xMin
                                                   yMin:sliced.bounds.yMin
                                                  width:sliced.bounds.xMax - sliced.bounds.xMin
                                                 height:sliced.bounds.yMax - sliced.bounds.yMin];
}

namespace {

// Default tessellation coarseness for the whole-board preview -- there's no SimulationConfig here
// to read a real SlicingConfig::pixelSize from, so this just matches that field's own default (5,
// at constants::unitMultiplier sim-units/micron): plenty fine for a cosmetic board preview, same
// as every sliced-board preview already gets when a simulation hasn't overridden pixelSize itself.
constexpr double kWholeBoardTessellationToleranceSimUnits = 5.0 * kiems::constants::unitMultiplier;

// Mirrors board_slicing.cpp's own (private) _polygonLoopToPolygon/_copperOnLayer exactly -- small
// enough, and different enough in what they're fed (every net's own copper across the whole board,
// not one SimulationConfig's already-cutout-clipped composite), that duplicating them here reads
// more clearly than exporting board_slicing.cpp's own internals just for this one caller.
Polygon wholeBoardPolygonLoopToPolygon(const libkicad::PolygonLoop& loop, double originX, double originY) {
    return previewPolygonLoop(loop, originX, originY);
}

std::optional<simd_double4> previewColorFromHex(const std::string& hex) {
    if ((hex.size() != 7 && hex.size() != 9) || hex.front() != '#') return std::nullopt;
    try {
        const auto channel = [&](std::size_t offset) {
            return static_cast<double>(std::stoul(hex.substr(offset, 2), nullptr, 16)) / 255.0;
        };
        return simd_make_double4(channel(1), channel(3), channel(5), hex.size() == 9 ? channel(7) : 1.0);
    } catch (...) {
        return std::nullopt;
    }
}

std::unordered_map<std::string, simd_double4> previewNetColors(const libkicad::Board& board) {
    std::unordered_map<std::string, simd_double4> colorsByNetName;
    // libkicad resolves KiCad's two project-file colour sources with the PCB editor's precedence:
    // explicit net colour, then effective net-class colour. Nets with neither deliberately remain
    // absent so GeometryView falls back to the copper layer's own theme colour.
    if (auto colorsResult = board.netColors(); colorsResult) {
        for (const auto& netColor : *colorsResult) {
            if (auto color = previewColorFromHex(netColor.hex)) {
                colorsByNetName.emplace(netColor.name, *color);
            }
        }
    } else {
        logWarning("GeometryPreview: net color query failed, falling back to layer colors: " +
                   colorsResult.error());
    }
    return colorsByNetName;
}

} // namespace

namespace {

struct PreviewLayerPlacement {
    std::unordered_map<std::string, double> zByName;
    double top = 0;
    double bottom = 0;
};

/// Copper Z positions from the board's stackup, the same walk buildWholeBoardPreview() makes.
/// Board::stackup() reads the snapshot taken at load, so this doesn't wait on the KiCad lock.
PreviewLayerPlacement previewLayerPlacement(const libkicad::Board& board) {
    PreviewLayerPlacement result;
    kiems::EMSConfig config;
    if (!kiems::importStackup(board, config)) return result;
    double z = 0;
    for (const auto& layer : config.layers()) {
        if (layer.kind() == kiems::LayerKind::Substrate) z -= layer.thickness();
        if (layer.kind() == kiems::LayerKind::Metal) result.zByName[layer.name()] = z;
    }
    result.bottom = z;
    return result;
}

double displayZForLayer(const std::string& name, const PreviewLayerPlacement& placement) {
    if (const auto found = placement.zByName.find(name); found != placement.zByName.end()) {
        return found->second;
    }
    // Give mask a small, explicit display separation behind its adjacent copper. This is large
    // enough to remain distinct in the depth buffer at whole-board scale, unlike the earlier
    // coplanar/depth-comparison approach, while still being visually negligible (100 simulation
    // units = 10 microns).
    constexpr double displayLayerSeparation = 100.0;
    if (name == "F.Mask") {
        if (const auto copper = placement.zByName.find("F.Cu"); copper != placement.zByName.end()) {
            return copper->second - displayLayerSeparation;
        }
        return placement.top - displayLayerSeparation;
    }
    if (name == "B.Mask") {
        if (const auto copper = placement.zByName.find("B.Cu"); copper != placement.zByName.end()) {
            return copper->second - displayLayerSeparation;
        }
        return placement.bottom - displayLayerSeparation;
    }
    if (name.starts_with("B.")) return placement.bottom - 20.0;
    if (name.starts_with("F.")) return placement.top + 20.0;
    return (placement.top + placement.bottom) / 2.0;
}

struct PreviewOutlineFrame {
    double originX = 0;
    double originY = 0;
    double width = 1;
    double height = 1;
    NSMutableArray<NSValue*>* points = [NSMutableArray array];
};

PreviewOutlineFrame previewOutlineFrame(const std::vector<libkicad::PolygonLoop>& loops) {
    PreviewOutlineFrame frame;
    double minX = std::numeric_limits<double>::infinity();
    double minY = std::numeric_limits<double>::infinity();
    double maxX = -std::numeric_limits<double>::infinity();
    double maxY = -std::numeric_limits<double>::infinity();
    for (const auto& loop : loops) {
        for (const auto& [xMm, yMm] : loop.pointsMm) {
            const double x = mmToSimUnits(xMm);
            const double y = mmToSimUnits(yMm);
            minX = std::min(minX, x); minY = std::min(minY, y);
            maxX = std::max(maxX, x); maxY = std::max(maxY, y);
        }
    }
    if (!std::isfinite(minX)) return frame;
    frame.originX = minX;
    frame.originY = minY;
    frame.width = std::max(1.0, maxX - minX);
    frame.height = std::max(1.0, maxY - minY);
    const libkicad::PolygonLoop* outer = nullptr;
    for (const auto& loop : loops) if (!loop.hole) { outer = &loop; break; }
    if (outer == nullptr && !loops.empty()) outer = &loops.front();
    if (outer != nullptr) {
        for (const auto& [xMm, yMm] : outer->pointsMm) {
            [frame.points addObject:[NSValue valueWithPoint:NSMakePoint(
                mmToSimUnits(xMm) - minX, mmToSimUnits(yMm) - minY)]];
        }
    }
    return frame;
}

} // namespace

std::expected<EMSGeometryPreview*, std::string> buildBoardLayerCatalogPreview(
    const libkicad::Board& board, bool wholeBoard) {
    auto catalog = board.boardLayers();
    if (!catalog) return std::unexpected(std::move(catalog).error());
    auto edge = board.boardLayerGeometry("Edge.Cuts");
    if (!edge) return std::unexpected(std::move(edge).error());
    const PreviewOutlineFrame frame = previewOutlineFrame(edge->boardOutline);
    const PreviewLayerPlacement placement = previewLayerPlacement(board);

    std::unordered_map<std::string, std::string> colors;
    if (auto result = board.layerColors(); result) {
        for (const auto& color : *result) colors[color.name] = color.hex;
    }
    NSMutableArray<EMSGeometryLayer*>* layers = [NSMutableArray arrayWithCapacity:catalog->size()];
    for (const auto& info : *catalog) {
        NSString* hex = nil;
        if (const auto found = colors.find(info.name); found != colors.end()) hex = @(found->second.c_str());
        // Every layer needs its Z here. The detailed preview's mergeLoadedPreview: only replaces
        // the layers it builds (copper and silkscreen); the lazy loader keeps this Z for the rest.
        [layers addObject:[EMSGeometryLayer placeholderWithName:@(info.name.c_str())
                                                        hexColor:hex
                                                               z:displayZForLayer(info.name, placement)]];
    }
    return [[EMSGeometryPreview alloc] initWithLayers:layers wholeBoard:wholeBoard
        topSolderMask:nil bottomSolderMask:nil outline:frame.points vias:@[] trackSegments:@[]
        failedViaAttempts:@[] ports:@[] viaMeshTriangles:@[] componentMeshTriangles:@[]
        renderedComponentReferences:@[] componentModelExportMessages:@[] gridLinesX:@[] gridLinesY:@[]
        gridLinesZ:@[] gridPlaneExcludingX:nil gridPlaneExcludingY:nil gridPlaneExcludingZ:nil
        gridMaterials:@[] gridLayers:@[] pmlInnerXMin:0 pmlInnerXMax:0 pmlInnerYMin:0 pmlInnerYMax:0
        pmlInnerZMin:0 pmlInnerZMax:0 xMin:0 yMin:0 width:frame.width height:frame.height];
}

static std::expected<EMSGeometryLayer*, std::string> buildBoardLayerPreviewImpl(
    const libkicad::Board& board, const std::string& layerName,
    const PolygonSet* clip, double tessellationTolerance) {
    auto result = board.boardLayerGeometry(layerName);
    if (!result) return std::unexpected(std::move(result).error());
    const PreviewOutlineFrame frame = previewOutlineFrame(result->boardOutline);
    // Both callers install these triangles into an existing preview layer. The layer catalog (for
    // the whole-board view) or the initial simulation preview already owns its theme colour and
    // real Z position; replaceTriangles: deliberately changes only geometry. Resolving either one
    // again here once per lazy layer queued layerColors()/stackup() behind long
    // boardLayerGeometry() holds without changing anything displayed.
    //
    // Whole-board copper comes from buildWholeBoardPreview(), not this lazy loader (the controller
    // excludes .Cu names), so its non-copper work also needs no per-net palette. Sliced copper is
    // still coloured by net when it is loaded on demand.
    const std::unordered_map<std::string, simd_double4> colorsByNetName =
        clip != nullptr ? previewNetColors(board) : std::unordered_map<std::string, simd_double4>{};

    NSMutableArray<EMSGeometryTriangle*>* triangles = [NSMutableArray array];
    if (result->layer.copper) {
        for (const auto& polygon : result->copper) {
            Polygon path = wholeBoardPolygonLoopToPolygon(polygon.loop, frame.originX, frame.originY);
            if (path.size() < 3) continue;
            PolygonSet shape{path};
            if (clip != nullptr) shape = intersectPolygons(shape, *clip);
            const auto mesh = triangulateComposited(shape, tessellationTolerance, layerName);
            const bool pin = !polygon.footprintRef.empty();
            const EMSGeometryTriangleKind kind = polygon.zone ? EMSGeometryTriangleKindZone
                                                    : pin ? EMSGeometryTriangleKindPin
                                                          : EMSGeometryTriangleKindTrace;
            // Alpha zero is GeometryView's "no override" sentinel. This exactly matches the Setup
            // board preview: configured net colour wins, then configured net-class colour (already
            // resolved by libkicad), with the layer colour as the fallback.
            simd_double4 color = simd_make_double4(0, 0, 0, 0);
            if (const auto colorIt = colorsByNetName.find(polygon.netName); colorIt != colorsByNetName.end()) {
                color = colorIt->second;
            }
            for (const auto& triangle : mesh) {
                [triangles addObject:[[EMSGeometryTriangle alloc]
                    initWithA:toCGPoint(triangle.a) b:toCGPoint(triangle.b) c:toCGPoint(triangle.c)
                    color:color opacity:polygon.zone ? 0.7 : 1.0 kind:kind
                    netName:polygon.netName.empty() ? nil : @(polygon.netName.c_str())
                    footprintReference:polygon.footprintRef.empty() ? nil : @(polygon.footprintRef.c_str())
                    padNumber:polygon.padNumber.empty() ? nil : @(polygon.padNumber.c_str())]];
            }
        }
    } else {
        const PolygonSet shapes = previewPolygonLoops(result->contours, frame.originX, frame.originY);
        PolygonSet coverage = shapes;
        if (result->layer.solderMask) {
            const PolygonSet outline = previewPolygonLoops(result->boardOutline, frame.originX, frame.originY);
            coverage = differencePolygons(outline, unionPolygons(shapes));

        }
        if (clip != nullptr) coverage = intersectPolygons(coverage, *clip);
        const auto mesh = triangulateComposited(coverage, tessellationTolerance, layerName);
        for (const auto& triangle : mesh) {
            [triangles addObject:[[EMSGeometryTriangle alloc] initWithA:toCGPoint(triangle.a)
                b:toCGPoint(triangle.b) c:toCGPoint(triangle.c)
                color:simd_make_double4(0, 0, 0, 0) opacity:result->layer.solderMask ? 0.45 : 1.0]];
        }
    }
    return [[EMSGeometryLayer alloc] initWithName:@(layerName.c_str()) triangles:triangles
        hexColor:nil z:0]; // Metadata stays on the destination layer above.
}

std::expected<EMSGeometryLayer*, std::string> buildBoardLayerPreview(
    const libkicad::Board& board, const std::string& layerName) {
    return buildBoardLayerPreviewImpl(board, layerName, nullptr,
                                      kWholeBoardTessellationToleranceSimUnits);
}

std::expected<EMSGeometryLayer*, std::string> buildSlicedBoardLayerPreview(
    const libkicad::Board& board, const std::string& layerName,
    const kiems::SlicedBoard& sliced, double tessellationTolerance) {
    const PolygonSet clip = sliced.cutoutLoops.empty() ? PolygonSet{sliced.outline} : sliced.cutoutLoops;
    return buildBoardLayerPreviewImpl(board, layerName, &clip, tessellationTolerance);
}

std::expected<EMSGeometryPreview*, std::string> buildWholeBoardPreview(const libkicad::Board& board) {
    libkicad::BoardLoadTiming previewTiming("Whole-board preview");
    libkicad::BoardLoadTiming extractionTiming("Board geometry extraction");
    const auto previewStartedAt = std::chrono::steady_clock::now();
    auto geometryResult = board.boardGeometry();
    if (!geometryResult) return std::unexpected(std::move(geometryResult).error());
    extractionTiming.end();
    const libkicad::BoardGeometry& geometry = *geometryResult;

    auto boundsResult = kiems::boardBoundsInSimulationUnits(geometry);
    if (!boundsResult) return std::unexpected(std::move(boundsResult).error());
    const double originX = boundsResult->xMin;
    const double originY = boundsResult->yMin;

    // Only used here to get real, correctly-scaled per-layer Z offsets (LayerConfig's own
    // constructor already converts thicknessMm to simulation units -- see its own doc comment) the
    // exact same way the real FDTD geometry places them (kiems::Simulation::addGerbers()) -- not
    // for anything sliced/simulated. A throwaway config, never a real SimulationConfig's own.
    kiems::EMSConfig stackupConfig;
    if (auto stackupImported = kiems::importStackup(board, stackupConfig); !stackupImported) {
        return std::unexpected(std::move(stackupImported).error());
    }

    std::unordered_map<std::string, std::string> colorsByLayerName;
    if (auto colorsResult = board.layerColors(); colorsResult) {
        for (const auto& layerColor : *colorsResult) {
            colorsByLayerName.emplace(layerColor.name, layerColor.hex);
        }
    }

    const std::unordered_map<std::string, simd_double4> colorsByNetName = previewNetColors(board);

    const std::vector<kiems::LayerConfig> metals = stackupConfig.getMetals();
    std::vector<double> metalOffsets;
    {
        double offset = 0;
        for (const auto& layer : stackupConfig.layers()) {
            if (layer.kind() == kiems::LayerKind::Substrate) {
                offset -= layer.thickness();
            } else if (layer.kind() == kiems::LayerKind::Metal) {
                metalOffsets.push_back(offset);
            }
        }
    }

    // Resolve plated holes before triangulating the copper.  The via mesh deliberately has an
    // open centre, but without also removing that drill shape from the independently-rendered
    // zone/pad/track polygons, translucent zone copper remains visible through the opening.
    // Preserve each cutout separately for cheap bounds filtering, plus one shared union for copper
    // groups spanning the whole board, so the visible board agrees with the barrel/ring geometry
    // below without rebuilding the entire drill geometry for every via and small copper group.
    NSMutableArray<EMSGeometryVia*>* vias = [NSMutableArray array];
    NSMutableArray<EMSGeometryComponentTriangle*>* viaTriangles = [NSMutableArray array];
    std::vector<IndexedHoleCutout> platedHoleCutouts;
    PolygonSet allPlatedHoleCutouts;
    if (auto holes = board.throughHoles(); holes) {
        platedHoleCutouts.reserve(holes->size());
        for (const auto& hole : *holes) {
            const double cx = mmToSimUnits(hole.xMm) - originX;
            const double cy = mmToSimUnits(hole.yMm) - originY;
            const double drillLong = mmToSimUnits(std::max(hole.drillWidthMm, hole.drillHeightMm));
            const double drillShort = mmToSimUnits(std::min(hole.drillWidthMm, hole.drillHeightMm));
            const double padLong = mmToSimUnits(std::max(hole.padWidthMm, hole.padHeightMm));
            const double padShort = mmToSimUnits(std::min(hole.padWidthMm, hole.padHeightMm));
            double angle = -hole.orientationDeg * M_PI / 180.0;
            if (hole.drillHeightMm > hole.drillWidthMm) angle -= M_PI / 2.0;
            const double ux = std::cos(angle);
            const double uy = std::sin(angle);
            const double drillHalfLine = std::max(0.0, (drillLong - drillShort) / 2.0);
            const double padHalfLine = std::max(0.0, (padLong - padShort) / 2.0);
            const CGPoint p1 = CGPointMake(cx - ux * drillHalfLine, cy - uy * drillHalfLine);
            const CGPoint p2 = CGPointMake(cx + ux * drillHalfLine, cy + uy * drillHalfLine);
            const CGPoint r1 = CGPointMake(cx - ux * padHalfLine, cy - uy * padHalfLine);
            const CGPoint r2 = CGPointMake(cx + ux * padHalfLine, cy + uy * padHalfLine);

            const PolygonSet cutout = bufferOpenPaths(
                {{{p1.x, p1.y}, {p2.x, p2.y}}}, drillShort / 2.0,
                kWholeBoardTessellationToleranceSimUnits);
            allPlatedHoleCutouts.insert(allPlatedHoleCutouts.end(), cutout.begin(), cutout.end());
            platedHoleCutouts.push_back({cutout, polygonSetBounds(cutout)});

            EMSGeometryVia* via = [[EMSGeometryVia alloc] initWithPosition:p1 position2:p2
                                                              ringPosition:r1 ringPosition2:r2
                                                                   diameter:drillShort
                                                        annularRingDiameter:padShort
                                                                     netName:hole.netName.empty()
                                                                         ? nil
                                                                         : @(hole.netName.c_str())];
            [vias addObject:via];
        }
        allPlatedHoleCutouts = unionDisjointSubsets(allPlatedHoleCutouts);
        for (std::size_t viaIndex = 0; viaIndex < vias.count; ++viaIndex) {
            EMSGeometryVia* via = vias[viaIndex];
            const double ringRadius = via.annularRingDiameter / 2;
            const BoundingBox<double> ringBounds =
                capsuleBounds(via.ringPosition, via.ringPosition2, ringRadius);
            std::vector<std::size_t> candidates = overlappingCutoutIndices(platedHoleCutouts, ringBounds);
            const bool intersectsAnotherHole =
                std::any_of(candidates.begin(), candidates.end(),
                            [viaIndex](const std::size_t candidate) { return candidate != viaIndex; });
            if (!intersectsAnotherHole) {
                // The overwhelmingly common case: appendViaMesh's direct annulus quads already
                // leave this via's own drilled centre open, so avoid GEOS altogether.
                appendViaMesh(via, metalOffsets, viaTriangles);
                continue;
            }
            if (std::find(candidates.begin(), candidates.end(), viaIndex) == candidates.end()) {
                candidates.push_back(viaIndex);
            }
            const PolygonSet localCutouts = unionDisjointSubsets(gatherCutouts(platedHoleCutouts, candidates));
            appendViaMesh(via, metalOffsets, viaTriangles, &localCutouts,
                          kWholeBoardTessellationToleranceSimUnits);
        }
    } else {
        logWarning("GeometryPreview: plated-hole query failed, copper drill cutouts omitted: " +
                   holes.error());
    }

    // The remaining KiCad queries run now, so the component export -- the slowest part of this
    // preview, and single-threaded inside KiCad -- can overlap the GEOS copper work below. Every
    // libkicad query takes the same process-wide lock, so queries issued after the export started
    // would just queue behind it.
    auto tracksResult = board.allTracks();
    std::vector<std::string> componentRefs;
    NSMutableArray<NSString*>* renderedRefs = [NSMutableArray array];
    if (auto footprintsResult = board.footprints(); footprintsResult) {
        componentRefs.reserve(footprintsResult->size());
        for (const auto& footprint : *footprintsResult) {
            componentRefs.push_back(footprint.reference);
            [renderedRefs addObject:@(footprint.reference.c_str())];
        }
    } else {
        logWarning("GeometryPreview: footprint listing failed, skipping whole-board component model "
                   "export: " + footprintsResult.error());
    }
    auto componentOutcome = std::make_shared<ComponentExportOutcome>();
    dispatch_group_t componentExport = dispatch_group_create();
    const libkicad::Board* boardForExport = &board;
    dispatch_group_async(componentExport, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        try {
            libkicad::BoardLoadTiming timing("Component export");
            *componentOutcome = exportComponentTriangles(*boardForExport, componentRefs);
        } catch (const std::exception& exception) {
            logWarning(std::string("GeometryPreview: component model export failed: ") + exception.what());
        }
    });
    // Every return below must first wait for the export, which still uses `board` and these locals.
    struct WaitForComponentExport {
        dispatch_group_t group;
        ~WaitForComponentExport() { dispatch_group_wait(group, DISPATCH_TIME_FOREVER); }
    } waitForComponentExport{componentExport};

    std::vector<std::vector<WholeBoardCopperGroup>> groupsByLayer(metals.size());
    for (std::size_t layerIndex = 0; layerIndex < metals.size(); ++layerIndex) {
        const std::string& layerName = metals[layerIndex].name();

        // Grouped by net (not unioned across the whole layer the way buildGeometryPreview's own
        // per-layer triangulation is) so each net's own copper can be triangulated, and colored,
        // separately -- see EMSGeometryTriangle.color's own doc comment for why that identity has
        // to survive past triangulation rather than collapsing into one flat per-layer color.
        std::unordered_map<std::string, WholeBoardCopperGroup> groupsByIdentity;
        for (const libkicad::CopperPolygon& polygon : geometry.copper) {
            if (polygon.copperLayerName != layerName) continue;
            Polygon path = wholeBoardPolygonLoopToPolygon(polygon.loop, originX, originY);
            if (path.size() >= 3) {
                const bool isPin = !polygon.zone && !polygon.footprintRef.empty();
                const EMSGeometryTriangleKind kind = polygon.zone ? EMSGeometryTriangleKindZone
                                                     : isPin ? EMSGeometryTriangleKindPin
                                                             : EMSGeometryTriangleKindTrace;
                const std::string key = polygon.zone
                    ? "zone\x1f" + polygon.netName
                    : isPin
                        ? "pin\x1f" + polygon.footprintRef + "\x1f" + polygon.padNumber
                        : "trace\x1f" + polygon.netName;
                WholeBoardCopperGroup& group = groupsByIdentity[key];
                group.key = key;
                group.netName = polygon.netName;
                group.footprintReference = polygon.footprintRef;
                group.padNumber = polygon.padNumber;
                group.kind = kind;
                group.rawPolygons.push_back(std::move(path));
            }
        }

        std::vector<WholeBoardCopperGroup>& copperGroups = groupsByLayer[layerIndex];
        copperGroups.reserve(groupsByIdentity.size());
        for (auto& entry : groupsByIdentity) {
            copperGroups.push_back(std::move(entry.second));
        }
        // Equal-depth ID fragments use lessEqual, so later geometry wins. Make pads win over
        // tracks where their copper overlaps, while zones remain the lowest-priority hit.
        const auto pickingPriority = [](EMSGeometryTriangleKind kind) {
            switch (kind) {
                case EMSGeometryTriangleKindZone: return 0;
                case EMSGeometryTriangleKindTrace: return 1;
                case EMSGeometryTriangleKindPin: return 2;
                default: return -1;
            }
        };
        std::sort(copperGroups.begin(), copperGroups.end(), [&](const auto& lhs, const auto& rhs) {
            const int lhsPriority = pickingPriority(lhs.kind);
            const int rhsPriority = pickingPriority(rhs.kind);
            return lhsPriority == rhsPriority ? lhs.key < rhs.key : lhsPriority < rhsPriority;
        });

    }

    // Build every layer's groups in one parallel pass rather than one pass per layer: a per-layer
    // pass waits on that layer's slowest group (typically a large pour) with the other cores idle.
    // Starting the most expensive groups first lets them overlap with everything else.
    struct CopperTask {
        WholeBoardCopperGroup* group;
        const std::string* layerName;
        std::size_t cost;
    };
    std::vector<CopperTask> copperTasks;
    for (std::size_t layerIndex = 0; layerIndex < metals.size(); ++layerIndex) {
        for (WholeBoardCopperGroup& group : groupsByLayer[layerIndex]) {
            std::size_t cost = 0;
            for (const Polygon& polygon : group.rawPolygons) cost += polygon.size();
            copperTasks.push_back({&group, &metals[layerIndex].name(), cost});
        }
    }
    std::stable_sort(copperTasks.begin(), copperTasks.end(),
                     [](const CopperTask& lhs, const CopperTask& rhs) { return lhs.cost > rhs.cost; });

    // GEOS re-entrant contexts are thread-local in polygon_geometry.cpp. Each task writes only
    // its own result slot; Cocoa object creation remains on this calling thread below.
    const CopperTask* taskData = copperTasks.data();
    const std::vector<IndexedHoleCutout>* cutoutsForTasks = &platedHoleCutouts;
    const PolygonSet* allCutoutsForTasks = &allPlatedHoleCutouts;
    libkicad::BoardLoadTiming copperTiming("Copper parallel pass");
    dispatch_apply(copperTasks.size(), dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0),
                   ^(std::size_t index) {
        const CopperTask& task = taskData[index];
        libkicad::BoardLoadTiming timing("Copper group",
            (*task.layerName + " / " + task.group->key).c_str(),
            task.cost, task.group->rawPolygons.size());
        buildWholeBoardCopperGroup(*task.group, *task.layerName, *cutoutsForTasks, *allCutoutsForTasks,
                                   kWholeBoardTessellationToleranceSimUnits);
    });

    copperTiming.end();
    libkicad::BoardLoadTiming materializationTiming("Copper Cocoa objects");
    NSMutableArray<EMSGeometryLayer*>* layers = [NSMutableArray arrayWithCapacity:metals.size()];
    for (std::size_t layerIndex = 0; layerIndex < metals.size(); ++layerIndex) {
        const std::string& layerName = metals[layerIndex].name();
        const std::vector<WholeBoardCopperGroup>& copperGroups = groupsByLayer[layerIndex];

        NSString* hexColor = nil;
        if (const auto colorIt = colorsByLayerName.find(layerName); colorIt != colorsByLayerName.end()) {
            hexColor = @(colorIt->second.c_str());
        }

        NSMutableArray<EMSGeometryTriangle*>* layerTriangles = [NSMutableArray array];
        for (const WholeBoardCopperGroup& group : copperGroups) {
            if (!group.error.empty()) {
                return std::unexpected("Building " + layerName + " copper: " + group.error);
            }
            const bool isZone = group.kind == EMSGeometryTriangleKindZone;
            // Alpha zero is GeometryView's "no override" sentinel: any net without a configured
            // net/net-class color therefore falls back to this copper layer's own theme color.
            simd_double4 color = simd_make_double4(0, 0, 0, 0);
            if (const auto colorIt = colorsByNetName.find(group.netName); colorIt != colorsByNetName.end()) {
                color = colorIt->second;
            }
            NSString* netName = group.netName.empty() ? nil : @(group.netName.c_str());
            NSString* footprintReference = group.footprintReference.empty()
                ? nil : @(group.footprintReference.c_str());
            NSString* padNumber = group.padNumber.empty() ? nil : @(group.padNumber.c_str());
            for (const auto& triangle : group.triangles) {
                [layerTriangles addObject:[[EMSGeometryTriangle alloc] initWithA:toCGPoint(triangle.a)
                                                                                  b:toCGPoint(triangle.b)
                                                                                  c:toCGPoint(triangle.c)
                                                                              color:color
                                                                            opacity:isZone ? 0.7 : 1.0
                                                                               kind:group.kind
                                                                            netName:netName
                                                                 footprintReference:footprintReference
                                                                          padNumber:padNumber]];
            }
        }
        const double layerZ = layerIndex < metalOffsets.size() ? metalOffsets[layerIndex] : 0;
        [layers addObject:[[EMSGeometryLayer alloc] initWithName:@(layerName.c_str())
                                                          triangles:layerTriangles
                                                          hexColor:hexColor
                                                                  z:layerZ]];
    }

    materializationTiming.end();
    libkicad::BoardLoadTiming maskTiming("Solder mask geometry");
    // Build the complete board's solder-mask coverage from its Edge.Cuts shape minus KiCad's mask
    // openings. The configuration screen uses the same flat mask-layer representation as a
    // simulation preview; these layers are display geometry only.
    const PolygonSet boardOutline = previewPolygonLoops(geometry.outline, originX, originY);
    double totalSubstrateThickness = 0;
    for (const auto& layer : stackupConfig.getSubstrates()) totalSubstrateThickness += layer.thickness();
    EMSGeometryLayer* topSolderMask = nil;
    EMSGeometryLayer* bottomSolderMask = nil;
    for (const auto& mask : stackupConfig.getSolderMasks()) {
        const bool isTop = mask.kind() == kiems::LayerKind::SolderMaskTop;
        const PolygonSet openings = previewPolygonLoops(
            isTop ? geometry.frontMaskOpenings : geometry.backMaskOpenings, originX, originY);
        const PolygonSet coverage = differencePolygons(boardOutline, unionPolygons(openings));
        const std::vector<Triangle> maskTriangles = triangulateComposited(
            coverage, kWholeBoardTessellationToleranceSimUnits, isTop ? "F.Mask" : "B.Mask");
        NSMutableArray<EMSGeometryTriangle*>* triangles =
            [NSMutableArray arrayWithCapacity:maskTriangles.size()];
        for (const auto& triangle : maskTriangles) {
            [triangles addObject:[[EMSGeometryTriangle alloc] initWithA:toCGPoint(triangle.a)
                                                                      b:toCGPoint(triangle.b)
                                                                      c:toCGPoint(triangle.c)]];
        }
        const double z = isTop ? mask.thickness() : -totalSubstrateThickness - mask.thickness();
        EMSGeometryLayer* layer = [[EMSGeometryLayer alloc] initWithName:@(mask.name().c_str())
                                                               triangles:triangles hexColor:nil z:z];
        if (isTop) topSolderMask = layer;
        else bottomSolderMask = layer;
    }

    maskTiming.end();
    libkicad::BoardLoadTiming silkTiming("Silkscreen geometry");
    // KiCad has already expanded every text glyph and stroked board/footprint graphic into these
    // contours. Keep each side as a real layer so it gets its own legend visibility control.
    const auto appendSilkscreenLayer = [&](const std::vector<libkicad::SilkscreenPolygon>& polygons,
                                            NSString* name, double z) {
        std::map<std::string, PolygonSet> polygonsByFootprint;
        for (const auto& polygon : polygons) {
            Polygon path = wholeBoardPolygonLoopToPolygon(polygon.loop, originX, originY);
            if (path.size() >= 3) polygonsByFootprint[polygon.footprintRef].push_back(std::move(path));
        }
        NSMutableArray<EMSGeometryTriangle*>* silkTriangles = [NSMutableArray array];
        const simd_double4 white = simd_make_double4(0.92, 0.92, 0.88, 1.0);
        for (auto& [footprintReference, rawPolygons] : polygonsByFootprint) {
            const PolygonSet unioned = rawPolygons.size() == 1 && isPositive(rawPolygons.front())
                ? rawPolygons
                : unionDisjointSubsets(rawPolygons);
            const std::vector<Triangle> triangles = triangulateComposited(
                unioned, kWholeBoardTessellationToleranceSimUnits, name.UTF8String);
            NSString* reference = footprintReference.empty() ? nil : @(footprintReference.c_str());
            for (const auto& triangle : triangles) {
                [silkTriangles addObject:[[EMSGeometryTriangle alloc]
                    initWithA:toCGPoint(triangle.a) b:toCGPoint(triangle.b) c:toCGPoint(triangle.c)
                         color:white opacity:1.0 kind:EMSGeometryTriangleKindGeneric netName:nil
            footprintReference:reference padNumber:nil]];
            }
        }
        [layers addObject:[[EMSGeometryLayer alloc] initWithName:name triangles:silkTriangles
                                                        hexColor:@"#EBEBE0" z:z]];
    };
    double topMaskThickness = 0;
    double bottomMaskThickness = 0;
    for (const auto& mask : stackupConfig.getSolderMasks()) {
        if (mask.kind() == kiems::LayerKind::SolderMaskTop) topMaskThickness = mask.thickness();
        if (mask.kind() == kiems::LayerKind::SolderMaskBottom) bottomMaskThickness = mask.thickness();
    }
    const double silkOffset = 20.0; // 2 microns clear of the outer solder-mask face.
    appendSilkscreenLayer(geometry.frontSilkscreen, @"F.Silkscreen",
                           (metalOffsets.empty() ? 0 : metalOffsets.front()) + topMaskThickness + silkOffset);
    appendSilkscreenLayer(geometry.backSilkscreen, @"B.Silkscreen",
                           (metalOffsets.empty() ? 0 : metalOffsets.back()) - bottomMaskThickness - silkOffset);

    // Cosmetic reference outline only -- picks the board's own outer boundary loop, ignoring any
    // interior Edge.Cuts cutout loops (a board with a physical hole in it), unlike the layer
    // triangulation above (which correctly includes every loop, outer and interior holes alike, via
    // triangulate()'s own hole handling).
    const libkicad::PolygonLoop* outerLoop = nullptr;
    for (const libkicad::PolygonLoop& loop : geometry.outline) {
        if (!loop.hole) {
            outerLoop = &loop;
            break;
        }
    }
    if (outerLoop == nullptr && !geometry.outline.empty()) {
        outerLoop = &geometry.outline.front();
    }
    NSMutableArray<NSValue*>* outline = [NSMutableArray array];
    if (outerLoop != nullptr) {
        for (const auto& [xMm, yMm] : outerLoop->pointsMm) {
            const double x = mmToSimUnits(xMm) - originX;
            const double y = mmToSimUnits(yMm) - originY;
            [outline addObject:[NSValue valueWithPoint:NSMakePoint(x, y)]];
        }
    }

    silkTiming.end();
    // Real 3D models of *every* footprint on the board -- unlike buildGeometryPreview's own
    // includedFootprintReferences() (just this simulation's lumped components),
    // there's no simulation here to narrow the list at all. Best-effort throughout, same as
    // buildGeometryPreview's own identically-shaped block: a query/export failure just leaves these
    // three arrays empty rather than failing the whole whole-board preview.
    NSMutableArray<EMSGeometryComponentTriangle*>* componentTriangles = [NSMutableArray array];
    NSMutableArray<NSString*>* componentModelExportMessages = [NSMutableArray array];
    {
        // Started above, alongside the copper work.
        libkicad::BoardLoadTiming waitTiming("Component export remaining wait");
        dispatch_group_wait(componentExport, DISPATCH_TIME_FOREVER);
        waitTiming.end();
        libkicad::BoardLoadTiming componentTiming("Component Cocoa objects");
        const ComponentExportOutcome& outcome = *componentOutcome;
        for (const auto& message : outcome.messages) {
            [componentModelExportMessages addObject:@(message.c_str())];
        }
        componentTriangles = [NSMutableArray arrayWithCapacity:outcome.triangles.size()];
        // Same re-basing as buildGeometryPreview's own identical block -- see its doc comment for
        // why Z needs topCopperZMm subtracted (libkicad's own Z=0 is board-bottom-copper, not this
        // preview's "board top always 0" convention) while X/Y only need originX/originY.
        const double topCopperZSim = mmToSimUnits(outcome.topCopperZMm);
        const auto toSim = [&](double xMm, double yMm, double zMm) {
            return simd_make_double3(mmToSimUnits(xMm) - originX, mmToSimUnits(yMm) - originY,
                                      mmToSimUnits(zMm) - topCopperZSim);
        };
        for (const auto& triangle : outcome.triangles) {
            [componentTriangles addObject:[[EMSGeometryComponentTriangle alloc]
                                               initWithA:toSim(triangle.ax, triangle.ay, triangle.az)
                                                       b:toSim(triangle.bx, triangle.by, triangle.bz)
                                                       c:toSim(triangle.cx, triangle.cy, triangle.cz)
                                                   color:simd_make_double4(triangle.r, triangle.g, triangle.b,
                                                                            triangle.a)
                                                 netName:nil
                                      footprintReference:@(triangle.footprintReference.c_str())]];
        }
    }

    // Real routed-track topology (including libkicad's flattened arc pieces) -- see
    // EMSGeometryTrackSegment's own doc comment. Used by
    // GeometryView's board-activity overlay to build a real pin/via/trace graph (Dijkstra edges
    // weighted by each segment's own physical length) rather than approximating "distance along the
    // copper" from triangulated fill geometry alone.
    NSMutableArray<EMSGeometryTrackSegment*>* trackSegments = [NSMutableArray array];
    if (tracksResult) {
        trackSegments = [NSMutableArray arrayWithCapacity:tracksResult->size()];
        for (const auto& [netName, segment] : *tracksResult) {
            const CGPoint start = CGPointMake(mmToSimUnits(segment.startXMm) - originX,
                                               mmToSimUnits(segment.startYMm) - originY);
            const CGPoint end = CGPointMake(mmToSimUnits(segment.endXMm) - originX,
                                             mmToSimUnits(segment.endYMm) - originY);
            [trackSegments addObject:[[EMSGeometryTrackSegment alloc] initWithNetName:@(netName.c_str())
                                                                              layerName:@(segment.copperLayerName.c_str())
                                                                                  start:start
                                                                                    end:end]];
        }
    } else {
        logWarning("GeometryPreview: whole-board track query failed, board-activity overlay will fall back to "
                   "triangulated fill geometry: " + tracksResult.error());
    }

    EMSGeometryPreview* preview = [[EMSGeometryPreview alloc] initWithLayers:layers
                                           wholeBoard:YES
                                          topSolderMask:topSolderMask
                                       bottomSolderMask:bottomSolderMask
                                                outline:outline
                                                   vias:vias
                                          trackSegments:trackSegments
                                      failedViaAttempts:@[]
                                                  ports:@[]
                                       viaMeshTriangles:viaTriangles
                                 componentMeshTriangles:componentTriangles
                           renderedComponentReferences:renderedRefs
                          componentModelExportMessages:componentModelExportMessages
                                             gridLinesX:@[]
                                             gridLinesY:@[]
                                             gridLinesZ:@[]
                                   gridPlaneExcludingX:nil
                                   gridPlaneExcludingY:nil
                                   gridPlaneExcludingZ:nil
                                         gridMaterials:@[]
                                            gridLayers:@[]
                                           pmlInnerXMin:0
                                           pmlInnerXMax:0
                                           pmlInnerYMin:0
                                           pmlInnerYMax:0
                                           pmlInnerZMin:0
                                           pmlInnerZMax:0
                                                   xMin:0
                                                   yMin:0
                                                  width:boundsResult->xMax - boundsResult->xMin
                                                 height:boundsResult->yMax - boundsResult->yMin];
    const auto elapsedMs = std::chrono::duration_cast<std::chrono::milliseconds>(
        std::chrono::steady_clock::now() - previewStartedAt).count();
    logInfo() << "Whole-board preview built in " << elapsedMs << " ms";
    return preview;
}
