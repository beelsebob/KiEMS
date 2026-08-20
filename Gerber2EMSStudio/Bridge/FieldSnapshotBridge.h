// A renderable time series of one completed GPU FDTD run's full field state -- Swift-visible; never
// exposes a C++ type. Populated by EMSSimulationPipelineBridge once its own Results stage has run a
// port on the GPU (see copper::CopperFDTDRunResult::fieldSnapshot's own doc comment for the capture
// cadence -- a handful of frames spread across the run, not one at the end and not every timestep).
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// One captured instant's full-grid energy state -- see EMSFieldSnapshot's own doc comment for the
/// shared grid geometry every frame is read against.
@interface EMSFieldFrame : NSObject

@property (nonatomic, readonly) NSUInteger timestep;
@property (nonatomic, readonly) double timeSeconds;

/// Raw little-endian float32 values, `nx*ny*nz` entries (nx/ny/nz from the owning EMSFieldSnapshot),
/// x-fastest-varying (index = `x + nx*(y + ny*z)`) -- one energy-density value per cell (see
/// copper::CopperFieldFrame::cellEnergy's own doc comment for exactly what it represents and its
/// known simplifications). NSData rather than a boxed NSNumber array since a real board's mesh can
/// be hundreds of thousands of cells.
@property (nonatomic, copy, readonly) NSData *cellEnergyData;

@end

/// Everything a 3D field/energy viewer needs, in the same board-relative simulation-unit frame as
/// EMSGeometryPreview (GeometryPreviewBridge.h) -- converted here from Copper's own metres, so a
/// renderer never has to know that conversion factor exists.
@interface EMSFieldSnapshot : NSObject

@property (nonatomic, readonly) NSUInteger nx;
@property (nonatomic, readonly) NSUInteger ny;
@property (nonatomic, readonly) NSUInteger nz;

/// Primary (E) mesh line positions along each axis -- `lineX.count == nx+1`, etc. (cell
/// *boundaries*, not centers), simulation units, same absolute (Edge_Cuts-relative) frame as
/// EMSGeometryPreview's own gridLinesX/Y.
@property (nonatomic, copy, readonly) NSArray<NSNumber *> *lineX;
@property (nonatomic, copy, readonly) NSArray<NSNumber *> *lineY;
@property (nonatomic, copy, readonly) NSArray<NSNumber *> *lineZ;

/// The board's own top/bottom Z (copper+substrate stack only, not the PML/margin padding beyond
/// it) -- `boardZMax` is always 0, `boardZMin` is negative (board thickness below it), matching
/// GridGenerator's own Z convention. Simulation units, same frame as lineZ.
@property (nonatomic, readonly) double boardZMin;
@property (nonatomic, readonly) double boardZMax;

/// The run's own captured frames, in timestep order -- always at least one. The same mesh geometry
/// (nx/ny/nz, lineX/Y/Z) applies to every frame; only each frame's own cellEnergyData differs.
@property (nonatomic, copy, readonly) NSArray<EMSFieldFrame *> *frames;

/// The minimum and maximum cell-energy values present across *every* frame's cellEnergyData, not
/// just one frame's own -- precomputed here so a renderer maps color consistently across playback
/// (a per-frame min/max would make each frame independently rescale to full brightness, hiding the
/// run's own real growth/decay).
@property (nonatomic, readonly) float minCellEnergy;
@property (nonatomic, readonly) float maxCellEnergy;

@end

NS_ASSUME_NONNULL_END
