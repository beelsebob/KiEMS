// A renderable snapshot of one simulation's sliced board geometry -- Swift-visible; never exposes a
// C++ type. Actually running the geometry-building pipeline stage that produces this data is
// EMSSimulationPipelineBridge's job now (see EMSSimulationPipelineBridge.h) -- see
// GeometryPreviewBridge+Private.h's buildGeometryPreview() for how that bridge turns an
// already-sliced kiems::SlicedBoard into one of these.
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <simd/simd.h>

#import "EMSConfigBridge.h"

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, EMSGeometryTriangleKind) {
    EMSGeometryTriangleKindGeneric = 0,
    EMSGeometryTriangleKindTrace,
    EMSGeometryTriangleKindPin,
    EMSGeometryTriangleKindZone,
};

/// One filled triangle, already tessellated on the C++ side (board-slicing's own triangulation) --
/// exposed as three raw points rather than re-deriving polygon outlines from disjoint triangles.
@interface EMSGeometryTriangle : NSObject
@property (nonatomic, readonly) CGPoint a;
@property (nonatomic, readonly) CGPoint b;
@property (nonatomic, readonly) CGPoint c;
/// Per-triangle color override, RGBA -- alpha 0 (the default, via initWithA:b:c:) means "no
/// override, use this triangle's own EMSGeometryLayer.hexColor instead" (real copper is always
/// fully opaque, so alpha 0 can never collide with a real color). Used by both whole-board and
/// simulation-cutout layer previews to color each net's own copper distinctly within one shared
/// per-layer EMSGeometryLayer, rather than exploding the layer list (and GeometryView's own
/// per-layer legend/visibility toggles) into one synthetic layer per net.
@property (nonatomic, readonly) simd_double4 color;
/// Display opacity independent of the color-override sentinel above. Filled zones use 0.7; all
/// other board geometry defaults to 1.0.
@property (nonatomic, readonly) double opacity;
/// Whole-board picking metadata. Simulation-cutout and silkscreen triangles are Generic. A trace
/// selects its complete net; a pin selects one footprint pad; zones are identifiable in the ID
/// pass but deliberately not selectable by the board UI.
@property (nonatomic, readonly) EMSGeometryTriangleKind kind;
@property (nonatomic, copy, readonly, nullable) NSString *netName;
@property (nonatomic, copy, readonly, nullable) NSString *footprintReference;
@property (nonatomic, copy, readonly, nullable) NSString *padNumber;
@end

/// One KiCad layer's triangulated display geometry. Copper layers retain picking metadata; other
/// enabled fabrication/technical/user layers use the same flat-mesh representation.
@interface EMSGeometryLayer : NSObject
@property (nonatomic, copy, readonly) NSString *name;
@property (nonatomic, copy, readonly) NSArray<EMSGeometryTriangle *> *triangles;
/// "#RRGGBB"/"#RRGGBBAA", from the board's active KiCad color theme (see
/// libkicad::layerColors) -- nil if that lookup failed or had no entry for this
/// layer, in which case the caller should fall back to its own default palette.
@property (nonatomic, copy, readonly, nullable) NSString *hexColor;
/// This layer's own real Z position, in the same board-top-at-0 frame as gridLinesZ -- the
/// cumulative substrate thickness above it, exactly matching where the real FDTD simulation places
/// this layer's own copper (see kiems::Simulation::addGerbers()/getMetalLayerOffset(), which
/// this mirrors). A position, not a thickness: copper itself has no Z *extent* in the FDTD model
/// (a metal layer is an infinitesimally thin PEC sheet, not a 3D volume) -- a 3D renderer wanting
/// to lay layers out by real board thickness (rather than approximating with even spacing across
/// the board) should place each layer's own triangles at this Z.
@property (nonatomic, readonly) double z;
/// NO for a catalog placeholder whose expensive contours have not been tessellated yet.
@property (nonatomic, readonly) BOOL geometryGenerated;
+ (instancetype)placeholderWithName:(NSString *)name
                           hexColor:(nullable NSString *)hexColor
                                  z:(double)z;
/// Replaces a catalog placeholder's mesh in-place. Call on the main thread.
- (void)replaceTriangles:(NSArray<EMSGeometryTriangle *> *)triangles;
@end

/// One via -- either a real board via (from the board's own Excellon drill file, kept only where it
/// still overlaps this simulation's sliced outline) or a stitching via board-slicing invented
/// itself to close a cutout edge (see kiems::SlicedBoard's own doc comment). `position`/
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
/// nil for a synthetic stitching via or a per-simulation sliced-board real via (neither call site
/// currently threads a net name through); populated for the whole-board preview, straight from
/// libkicad::throughHoles -- this is what lets a via act as a real graph node bridging two copper
/// layers of the same net (see GeometryView.rebuildActivityBuffers()'s own trace-graph doc comment).
@property (nonatomic, copy, readonly, nullable) NSString *netName;
@end

/// One routed-track centreline segment, real KiCad copper -- unlike EMSGeometryTriangle (its
/// triangulated *fill* shape, no notion of "one continuous routed segment"), this is the raw
/// start/end centerline from libkicad::allTracks (curves arrive as short connected pieces), exactly
/// what a per-net pin/via graph needs for a real edge length between two landmarks. Whole-board
/// preview only -- empty for a per-simulation sliced-board preview.
@interface EMSGeometryTrackSegment : NSObject
@property (nonatomic, copy, readonly) NSString *netName;
@property (nonatomic, copy, readonly) NSString *layerName;
@property (nonatomic, readonly) CGPoint start;
@property (nonatomic, readonly) CGPoint end;
@end

/// One resolved simulation port -- where an excitation/measurement point sits on the board.
@interface EMSGeometryPort : NSObject
@property (nonatomic, copy, readonly) NSString *name;
@property (nonatomic, readonly) CGPoint position;
@property (nonatomic, readonly) double width;
@property (nonatomic, readonly) double length;
/// NO for any non-loading measurement point (a pin-level passive probe or a net-level trace-
/// impedance probe alike -- see kiems::PortConfig::absorbSignal()'s own doc comment); YES for
/// a real, terminating lumped port. GeometryView colors these two cases differently.
@property (nonatomic, readonly) BOOL absorbSignal;
@end

/// One filled triangle of a real KiCad footprint 3D model, from libkicad's in-process
/// exportComponentModels() (KiCad's own EXPORTER_STEP/STEP_PCB_MODEL classes -- the same machinery
/// `kicad-cli pcb export stl` itself uses, run in-process instead of as a subprocess) -- unlike
/// EMSGeometryTriangle, each vertex carries its own real Z (a component's own 3D shape, not a flat,
/// single-Z board layer), still in the same simulation-unit/Edge-Cuts-origin frame as everything
/// else here. See buildGeometryPreview()'s own comment on where these come from and the coordinate
/// transform applied. `color` is the model's own real STEP color (straight from
/// libkicad::ComponentTriangle, itself from XCAFDoc_ColorTool -- the same source
/// WriteSTEP/WriteGLTF preserve), (1,1,1,1) if the model carries none -- shared by all three
/// vertices (one real material per triangle, not interpolated per-vertex).
@interface EMSGeometryComponentTriangle : NSObject
@property (nonatomic, readonly) simd_double3 a;
@property (nonatomic, readonly) simd_double3 b;
@property (nonatomic, readonly) simd_double3 c;
@property (nonatomic, readonly) simd_double4 color;
/// Populated only for whole-board via mesh triangles. Component-model triangles and sliced-board
/// synthetic vias leave it nil. This lets picking/activity treat the plated barrel and annular
/// rings as part of their electrical net rather than stopping the overlay at the surrounding trace.
@property (nonatomic, copy, readonly, nullable) NSString *netName;
/// Owning footprint for real component-model triangles. Via triangles leave this nil.
@property (nonatomic, copy, readonly, nullable) NSString *footprintReference;
@end

/// One camera-facing plane of Yee-grid edges, already split edge-by-edge and colored from the
/// highest-priority CSXCAD MATERIAL/METAL property at each edge midpoint. Packed buffers use the
/// same 12-byte Position3 / 16-byte RGBA layouts GeometryView's Metal shaders consume directly.
@interface EMSGeometryGridPlane : NSObject
@property (nonatomic, copy, readonly) NSData *positions;
@property (nonatomic, copy, readonly) NSData *colors;
@property (nonatomic, readonly) NSUInteger vertexCount;
@end

/// Legend entry for a material color used by one or more grid edges.
@interface EMSGeometryGridMaterial : NSObject
@property (nonatomic, copy, readonly) NSString *name;
@property (nonatomic, readonly) simd_double4 color;
@end

/// One selectable PCB copper-layer slice. `edgeColors` contains one packed RGBA float4 per XY Yee
/// edge (X-directed edges first, then Y-directed edges); positions are reconstructed from the
/// preview's shared X/Y line arrays, avoiding a full duplicate position buffer per PCB layer.
@interface EMSGeometryGridLayer : NSObject
@property (nonatomic, copy, readonly) NSString *name;
@property (nonatomic, readonly) double z;
@property (nonatomic, copy, readonly) NSData *edgeColors;
@end

/// A renderable snapshot of one simulation's sliced board geometry, in simulation units -- everything
/// a geometry-preview view needs to draw it, with no further C++ types involved.
@interface EMSGeometryPreview : NSObject
/// Distinguishes the configuration screen's complete-board preview from a simulation cutout.
/// GeometryView uses this only to choose sensible initial layer visibility.
@property (nonatomic, readonly) BOOL wholeBoard;
@property (nonatomic, copy, readonly) NSArray<EMSGeometryLayer *> *layers;
/// Top/bottom solder mask, if this board's stackup has one on that side -- nil (not an empty
/// EMSGeometryLayer) when absent, e.g. no F_Mask.gbr/B_Mask.gbr was exported. Reuses
/// EMSGeometryLayer's own shape (flat 2D triangles at one shared Z) since the mask, like a copper
/// layer, is naturally a flat sheet at a fixed Z from this preview's point of view -- its real
/// thickness only matters to the FDTD simulation's own extrusion (kiems::Simulation::
/// addSolderMask()), not to this flat-shaded preview. `z` is the mask's own *outer* face (top
/// mask: +thickness above F.Cu; bottom mask: -thickness below the last copper layer), not the
/// copper-facing side, so it renders visibly above/below copper rather than z-fighting it.
@property (nonatomic, strong, readonly, nullable) EMSGeometryLayer *topSolderMask;
@property (nonatomic, strong, readonly, nullable) EMSGeometryLayer *bottomSolderMask;
/// This simulation's own cutout outline, a single closed polygon loop.
@property (nonatomic, copy, readonly) NSArray<NSValue *> *outline; // NSValue-wrapped CGPoint
@property (nonatomic, copy, readonly) NSArray<EMSGeometryVia *> *vias;
/// Every routed-track centreline segment, real KiCad copper -- see EMSGeometryTrackSegment's own
/// doc comment. Empty for a per-simulation sliced-board preview.
@property (nonatomic, copy, readonly) NSArray<EMSGeometryTrackSegment *> *trackSegments;
/// Stitching-via candidate positions board-slicing considered but rejected (no ground copper there,
/// or too close to another via) -- see kiems::SlicedBoard::failedStitchingViaAttempts's own
/// doc comment. NSValue-wrapped CGPoint, same convention as `outline`.
@property (nonatomic, copy, readonly) NSArray<NSValue *> *failedViaAttempts;
@property (nonatomic, copy, readonly) NSArray<EMSGeometryPort *> *ports;
/// Every via's own real 3D geometry -- an open (hollow, uncapped) barrel cylinder at the drilled
/// hole diameter, spanning the board's full Z extent (board top to bottom -- see `vias`' own doc
/// comment on why every via is treated as reaching every layer, no blind/buried distinction), plus
/// a flat annular-ring washer at each metal layer's own Z. Replaces the old flat, single-Z marker
/// discs a 2D top-down view could get away with (see EMSGeometryVia's own doc comment) -- a real 3D
/// view needs real 3D via geometry to look right from any camera angle, and to correctly show empty
/// space where a via's own drilled hole passes through copper it doesn't actually touch (the
/// corresponding hole is already cut out of each EMSGeometryLayer's own `triangles`, so this mesh's
/// tube wall sits in genuine empty space, not visually clipping through solid copper). Reuses
/// EMSGeometryComponentTriangle (not a new type) purely because its shape -- three arbitrary 3D
/// points plus one flat color -- is exactly what this needs too, not because a via has anything to
/// do with a footprint's own 3D model.
@property (nonatomic, copy, readonly) NSArray<EMSGeometryComponentTriangle *> *viaMeshTriangles;
/// Real KiCad 3D models for every footprint auto-discovered as a lumped R/L/C component in this
/// simulation (not every footprint with a resolved port/probe pin too -- see
/// includedFootprintReferences()'s own comment for why). A debug/visualization aid (confirming a
/// lumped-component auto-discovery picked the right physical part), not used by the FDTD simulation
/// itself. Empty if no lumped components are involved, or if the export failed (best-effort,
/// degrades gracefully -- see buildGeometryPreview()).
@property (nonatomic, copy, readonly) NSArray<EMSGeometryComponentTriangle *> *componentMeshTriangles;
/// Exactly which reference designators componentMeshTriangles was requested for -- independent of
/// whether the export actually found/rendered a model for each one, so "the list is empty/wrong" is
/// distinguishable from "the export silently failed."
@property (nonatomic, copy, readonly) NSArray<NSString *> *renderedComponentReferences;
/// Every diagnostic KiCad's own exporter reported while building renderedComponentReferences' shapes
/// -- most commonly "Could not add 3D model for <ref>." / "File not found: <path>" pairs, for a
/// component whose linked 3D model can't be resolved (see
/// libkicad::ComponentModelExportResult's own doc comment). Non-fatal: the rest of
/// componentMeshTriangles is still populated for every other requested component. Empty if every
/// requested component's model resolved cleanly, or if the export itself failed outright (in which
/// case componentMeshTriangles is empty too, not populated-minus-one).
@property (nonatomic, copy, readonly) NSArray<NSString *> *componentModelExportMessages;
/// Grid line positions GridGenerator placed along the X/Y/Z axes (see kiems::ComputedGridLines),
/// in the same board-relative simulation-unit frame as everything else here -- empty (not nil)
/// until the Grid pipeline stage has actually run (see EMSPipelineStageGrid), which the Geometry
/// stage alone doesn't do. gridLinesZ is absolute (board top at 0, same convention as everywhere
/// else Z appears in this codebase -- see grid_gen.cpp's own _generateZ()), not offset by xMin/yMin
/// the way X/Y aren't either (see buildGeometryPreview()'s own comment on why no translation is
/// needed).
@property (nonatomic, copy, readonly) NSArray<NSNumber *> *gridLinesX;
@property (nonatomic, copy, readonly) NSArray<NSNumber *> *gridLinesY;
@property (nonatomic, copy, readonly) NSArray<NSNumber *> *gridLinesZ;
/// Material-colored edge buffers for the three possible camera-facing grid planes. Nil until the
/// Grid stage has run, or if rebuilding the CSXCAD material geometry failed (the view falls back to
/// its conventional cyan/magenta coordinate grid in that case).
@property (nonatomic, strong, readonly, nullable) EMSGeometryGridPlane *gridPlaneExcludingX;
@property (nonatomic, strong, readonly, nullable) EMSGeometryGridPlane *gridPlaneExcludingY;
@property (nonatomic, strong, readonly, nullable) EMSGeometryGridPlane *gridPlaneExcludingZ;
@property (nonatomic, copy, readonly) NSArray<EMSGeometryGridMaterial *> *gridMaterials;
@property (nonatomic, copy, readonly) NSArray<EMSGeometryGridLayer *> *gridLayers;
/// The legacy rectangular core mesh extent on X/Y. The material-coloured grid planes above already
/// contain the authoritative hull-following classification: external edges are absent and the
/// actual offset CPML rings are coloured as PML. These scalar bounds remain for fallback previews
/// that do not have an irregular domain mask. All 0 alongside empty gridLinesX/Y, before the Grid
/// stage has run.
@property (nonatomic, readonly) double pmlInnerXMin;
@property (nonatomic, readonly) double pmlInnerXMax;
@property (nonatomic, readonly) double pmlInnerYMin;
@property (nonatomic, readonly) double pmlInnerYMax;
/// Same idea, for Z -- the substrate stack's own top/bottom extent (board top always 0), before
/// GridGenerator's graded PML/margin cells at either end (see kiems::GridGenerator::
/// pmlInnerZMin()'s own doc comment). Unlike X/Y, no offset re-basing is needed here (Z has no
/// separate per-axis local origin), so buildGeometryPreview() passes these straight through.
@property (nonatomic, readonly) double pmlInnerZMin;
@property (nonatomic, readonly) double pmlInnerZMax;
@property (nonatomic, readonly) double xMin;
@property (nonatomic, readonly) double yMin;
@property (nonatomic, readonly) double width;
@property (nonatomic, readonly) double height;
/// Incorporates the detailed meshes/board furniture of a later preview without replacing this
/// instance (and therefore without losing the user's current layer visibility choices).
- (void)mergeLoadedPreview:(EMSGeometryPreview *)preview;
@end

NS_ASSUME_NONNULL_END
