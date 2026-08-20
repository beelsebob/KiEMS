#import "GeometryPreviewBridge.h"
#import "GeometryPreviewBridge+Private.h"

#include <algorithm>
#include <cmath>
#include <limits>
#include <optional>
#include <string>
#include <tuple>
#include <unordered_map>
#include <utility>
#include <vector>

#include "gerber2ems/board_slicing.hpp"
#include "gerber2ems/config.hpp"
#include "gerber2ems/constants.hpp"
#include "gerber2ems/gerber_composite.hpp"
#include "gerber2ems/importer.hpp"
#include "gerber2ems/libkicad_query.hpp"
#include "gerber2ems/paths_config.hpp"

using gerber2ems::EMSConfig;
using gerber2ems::PathsConfig;
using gerber2ems::SimulationConfig;
using gerber2ems::SlicedBoard;

namespace {

CGPoint toCGPoint(const gerber2ems::Position& position) {
    return CGPointMake(position.x(), position.y());
}

// Matches port_resolution.cpp's own (private) _mmToSimUnits exactly -- gerber2ems::libkicad_query's
// results (like every other libkicad_query position) come back in millimetres, board-auxiliary-
// origin-relative; this pipeline's own native frame is simulation units, further re-origined to the
// board's Edge_Cuts bounding box (see getVias()'s own doc comment) -- the bounding-box shift still
// needs applying by the caller, this just handles the unit conversion.
double mmToSimUnits(double mm) { return mm / 1000.0 / gerber2ems::constants::baseUnit * gerber2ems::constants::unitMultiplier; }

// A real via's *actual* copper pad is already drawn separately, as part of that layer's composited
// copper (read straight from the Gerbers) -- Simulation::addVia() only needs its own ring to be
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
// gerber2ems::libkicad_query::ThroughHole's own doc comment) once per geometry build, converting
// each into this preview's frame. Best-effort: an empty result (query failure, or just an older
// libkicad_smoketest that doesn't support the command yet) leaves every via falling back to
// kPreviewViaAnnularRingMarginSimUnits instead, not a hard error -- the ring is a cosmetic preview
// detail, never worth failing the whole geometry step over.
std::vector<RealHoleSize> buildRealHoleSizes(const gerber2ems::PathsConfig& paths, double originX, double originY) {
    std::vector<RealHoleSize> sizes;
    auto holesResult = gerber2ems::libkicad_query::throughHoles(paths, "Reading real via/pad sizes");
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
// nowhere near enough to need one. `sizes` and `getVias()`'s own Excellon-derived positions are two
// *independently* computed representations of the same real board data (one read straight from
// KiCad's internal model, the other reconstructed by parsing an exported drill file) -- a tolerance
// (not exact equality) accounts for the small floating-point/rounding differences between them,
// tight enough that a match still can't accidentally cross to a genuinely different, merely nearby,
// via.
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
bool pointInPolygon(double x, double y, const std::vector<gerber2ems::Position>& polygon) {
    bool inside = false;
    for (std::size_t i = 0, j = polygon.size() - 1; i < polygon.size(); j = i++) {
        const gerber2ems::Position& pi = polygon[i];
        const gerber2ems::Position& pj = polygon[j];
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

double distanceToPolygonBoundary(double x, double y, const std::vector<gerber2ems::Position>& polygon) {
    double best = std::numeric_limits<double>::infinity();
    for (std::size_t i = 0, j = polygon.size() - 1; i < polygon.size(); j = i++) {
        const gerber2ems::Position& a = polygon[j];
        const gerber2ems::Position& b = polygon[i];
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

bool viaIntersectsOutline(double x, double y, double diameter, const std::vector<gerber2ems::Position>& outline) {
    if (pointInPolygon(x, y, outline)) {
        return true;
    }
    return distanceToPolygonBoundary(x, y, outline) <= diameter / 2;
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
- (instancetype)initWithName:(NSString*)name position:(CGPoint)position width:(double)width length:(double)length {
    self = [super init];
    if (self) {
        _name = [name copy];
        _position = position;
        _width = width;
        _length = length;
    }
    return self;
}
@end

@implementation EMSGeometryPreview
- (instancetype)initWithLayers:(NSArray<EMSGeometryLayer*>*)layers
                        outline:(NSArray<NSValue*>*)outline
                           vias:(NSArray<EMSGeometryVia*>*)vias
              failedViaAttempts:(NSArray<NSValue*>*)failedViaAttempts
                          ports:(NSArray<EMSGeometryPort*>*)ports
                     gridLinesX:(NSArray<NSNumber*>*)gridLinesX
                     gridLinesY:(NSArray<NSNumber*>*)gridLinesY
                     gridLinesZ:(NSArray<NSNumber*>*)gridLinesZ
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
        _outline = [outline copy];
        _vias = [vias copy];
        _failedViaAttempts = [failedViaAttempts copy];
        _ports = [ports copy];
        _gridLinesX = [gridLinesX copy];
        _gridLinesY = [gridLinesY copy];
        _gridLinesZ = [gridLinesZ copy];
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

EMSGeometryPreview* buildGeometryPreview(const SlicedBoard& sliced, const SimulationConfig& simConfig,
                                          const EMSConfig& scaledConfig, const PathsConfig& paths,
                                          const gerber2ems::ComputedGridLines* gridLines) {
    // Best-effort: the board's own KiCad color theme, if readable (see layerColors's own doc
    // comment for what "readable" means outside a full GUI session) -- a lookup failure here isn't
    // fatal to the geometry step itself, it just leaves every layer's hexColor nil, which callers
    // fall back to their own default palette for.
    std::unordered_map<std::string, std::string> colorsByLayerName;
    if (auto colorsResult = gerber2ems::libkicad_query::layerColors(paths, "Reading layer colors"); colorsResult) {
        for (const auto& layerColor : *colorsResult) {
            colorsByLayerName.emplace(layerColor.name, layerColor.hex);
        }
    }

    const auto metals = scaledConfig.getMetals();
    // One entry per metal layer, in the same stackup order as `metals`/sliced.layerTriangles --
    // exactly mirrors gerber2ems::Simulation::addGerbers()/getMetalLayerOffset()'s own walk of the
    // full interleaved layer list, so a copper layer here ends up at the identical Z the real FDTD
    // geometry places it at (board top always 0, cumulative substrate thickness subtracted going
    // down) -- not an even-spacing approximation across the board's own extent.
    std::vector<double> metalOffsets;
    {
        double offset = 0;
        for (const auto& layer : scaledConfig.layers()) {
            if (layer.kind() == gerber2ems::LayerKind::Substrate) {
                offset -= layer.thickness();
            } else if (layer.kind() == gerber2ems::LayerKind::Metal) {
                metalOffsets.push_back(offset);
            }
        }
    }
    NSMutableArray<EMSGeometryLayer*>* layers = [NSMutableArray arrayWithCapacity:sliced.layerTriangles.size()];
    for (std::size_t layerIndex = 0; layerIndex < sliced.layerTriangles.size(); ++layerIndex) {
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
        const auto& triangles = sliced.layerTriangles[layerIndex];
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

    // Real board vias (from the board's own drill file) -- kept only where they still overlap this
    // simulation's sliced outline, exactly like Simulation::addVias() itself (see
    // viaIntersectsOutline's own doc comment for why that's a disc test, not just the via center).
    // These are already baked into the actual FDTD geometry the geometry step just built; without
    // adding them here too, the preview only ever showed the synthetic stitching vias, never the
    // board's own real ones. getVias() needs the same Edge_Cuts-bounding-box re-origin every other
    // coordinate this preview uses already has (see getVias()'s own doc comment) -- re-derived here
    // rather than threaded through, matching sliceBoardForSimulation()'s own internal re-derivation
    // of the identical value.
    if (auto originResult = gerber2ems::edgeCutsBoundingBox(
            paths.fabDir, static_cast<double>(scaledConfig.pixelSize()) * gerber2ems::constants::unitMultiplier);
        originResult) {
        // Queried once, up front, rather than per-via -- see buildRealHoleSizes()'s own comment.
        const std::vector<RealHoleSize> realHoleSizes =
            buildRealHoleSizes(paths, originResult->xMin, originResult->yMin);
        if (auto realVias = gerber2ems::getVias(paths, originResult->xMin, originResult->yMin); realVias) {
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

    NSMutableArray<EMSGeometryPort*>* ports = [NSMutableArray arrayWithCapacity:simConfig.ports().size()];
    for (const auto& port : simConfig.ports()) {
        if (!port.position().has_value()) {
            continue;
        }
        const auto [x, y] = *port.position();
        [ports addObject:[[EMSGeometryPort alloc] initWithName:@(port.name().c_str())
                                                          position:CGPointMake(x, y)
                                                             width:port.width()
                                                            length:port.length()]];
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

    return [[EMSGeometryPreview alloc] initWithLayers:layers
                                                outline:outline
                                                   vias:vias
                                      failedViaAttempts:failedViaAttempts
                                                  ports:ports
                                             gridLinesX:gridLinesX
                                             gridLinesY:gridLinesY
                                             gridLinesZ:gridLinesZ
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
