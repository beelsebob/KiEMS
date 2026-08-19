// A renderable snapshot of one simulation's sliced board geometry -- Swift-visible; never exposes a
// C++ type. Actually running the geometry-building pipeline stage that produces this data is
// EMSSimulationPipelineBridge's job now (see EMSSimulationPipelineBridge.h) -- see
// GeometryPreviewBridge+Private.h's buildGeometryPreview() for how that bridge turns an
// already-sliced gerber2ems::SlicedBoard into one of these.
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

#import "EMSConfigBridge.h"

NS_ASSUME_NONNULL_BEGIN

/// One filled triangle, already tessellated on the C++ side (board-slicing's own triangulation) --
/// exposed as three raw points rather than re-deriving polygon outlines from disjoint triangles.
@interface EMSGeometryTriangle : NSObject
@property (nonatomic, readonly) CGPoint a;
@property (nonatomic, readonly) CGPoint b;
@property (nonatomic, readonly) CGPoint c;
@end

/// One copper layer's final (post-slicing) triangulated geometry, board-top to board-bottom in the
/// same order as EMSConfigBridge.metalLayerNames.
@interface EMSGeometryLayer : NSObject
@property (nonatomic, copy, readonly) NSString *name;
@property (nonatomic, copy, readonly) NSArray<EMSGeometryTriangle *> *triangles;
/// "#RRGGBB"/"#RRGGBBAA", from the board's active KiCad color theme (see
/// gerber2ems::libkicad_query::layerColors) -- nil if that lookup failed or had no entry for this
/// layer, in which case the caller should fall back to its own default palette.
@property (nonatomic, copy, readonly, nullable) NSString *hexColor;
@end

/// One via -- either a real board via (from the board's own Excellon drill file, kept only where it
/// still overlaps this simulation's sliced outline) or a stitching via board-slicing invented
/// itself to close a cutout edge (see gerber2ems::SlicedBoard's own doc comment). `position`/
/// `position2` + `diameter` are the drilled hole's own capsule/stadium centerline+width; `ringPosition`/
/// `ringPosition2` + `annularRingDiameter` are the copper pad/ring's own, *independently* sized and
/// positioned capsule -- not necessarily sharing the hole's centerline length at all. They're only
/// forced equal (both pairs identical, single-radius rendering) for a plain round via -- every
/// stitching via, and most real ones -- or when a real via's true pad shape isn't known and this
/// falls back to a flat margin around the hole. A real oblong pad (e.g. a connector's SHIELD pin,
/// whose 0.8x1.4mm pad is not just "the 0.5x1.2mm drilled slot plus a fixed margin all around")
/// gets its own correctly proportioned ring capsule instead -- see GeometryPreviewBridge.mm's
/// ringPositionsForRealPad() for why reusing the hole's own centerline for the ring badly
/// oversized it (both too wide *and* too long), enough to visually overlap unrelated nearby copper.
@interface EMSGeometryVia : NSObject
@property (nonatomic, readonly) CGPoint position;
@property (nonatomic, readonly) CGPoint position2;
@property (nonatomic, readonly) CGPoint ringPosition;
@property (nonatomic, readonly) CGPoint ringPosition2;
@property (nonatomic, readonly) double diameter;
@property (nonatomic, readonly) double annularRingDiameter;
@end

/// One resolved simulation port -- where an excitation/measurement point sits on the board.
@interface EMSGeometryPort : NSObject
@property (nonatomic, copy, readonly) NSString *name;
@property (nonatomic, readonly) CGPoint position;
@property (nonatomic, readonly) double width;
@property (nonatomic, readonly) double length;
@end

/// A renderable snapshot of one simulation's sliced board geometry, in simulation units -- everything
/// a geometry-preview view needs to draw it, with no further C++ types involved.
@interface EMSGeometryPreview : NSObject
@property (nonatomic, copy, readonly) NSArray<EMSGeometryLayer *> *layers;
/// This simulation's own cutout outline, a single closed polygon loop.
@property (nonatomic, copy, readonly) NSArray<NSValue *> *outline; // NSValue-wrapped CGPoint
@property (nonatomic, copy, readonly) NSArray<EMSGeometryVia *> *vias;
/// Stitching-via candidate positions board-slicing considered but rejected (no ground copper there,
/// or too close to another via) -- see gerber2ems::SlicedBoard::failedStitchingViaAttempts's own
/// doc comment. NSValue-wrapped CGPoint, same convention as `outline`.
@property (nonatomic, copy, readonly) NSArray<NSValue *> *failedViaAttempts;
@property (nonatomic, copy, readonly) NSArray<EMSGeometryPort *> *ports;
/// Grid line positions GridGenerator placed along the X/Y axes (see gerber2ems::ComputedGridLines),
/// in the same board-relative simulation-unit frame as everything else here -- empty (not nil)
/// until the Grid pipeline stage has actually run (see EMSPipelineStageGrid), which the Geometry
/// stage alone doesn't do. Z isn't exposed: this preview is a flattened top-down view, and a
/// per-layer Z line wouldn't correspond to anything drawable on it.
@property (nonatomic, copy, readonly) NSArray<NSNumber *> *gridLinesX;
@property (nonatomic, copy, readonly) NSArray<NSNumber *> *gridLinesY;
/// The core mesh's own extent on X/Y -- everywhere *inside* these bounds is the regular densified
/// mesh; everywhere outside is the PML band GridGenerator appends beyond it (see
/// gerber2ems::ComputedGridLines's own doc comment). All 0 alongside empty gridLinesX/Y, before the
/// Grid stage has run.
@property (nonatomic, readonly) double pmlInnerXMin;
@property (nonatomic, readonly) double pmlInnerXMax;
@property (nonatomic, readonly) double pmlInnerYMin;
@property (nonatomic, readonly) double pmlInnerYMax;
@property (nonatomic, readonly) double xMin;
@property (nonatomic, readonly) double yMin;
@property (nonatomic, readonly) double width;
@property (nonatomic, readonly) double height;
@end

NS_ASSUME_NONNULL_END
