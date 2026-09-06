// A renderable time series of one completed GPU FDTD run's full field state -- Swift-visible; never
// exposes a C++ type. Populated by EMSSimulationPipelineBridge once its own Results stage has run a
// port on the GPU (see CopperFDTDRunner's field-series capture cadence -- a handful of frames spread
// across the run, not one at the end and not every timestep).
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// One captured instant's full-grid energy state -- see EMSFieldSnapshot's own doc comment for the
/// shared grid geometry every frame is read against.
@interface EMSFieldFrame : NSObject

@property (nonatomic, readonly) NSUInteger timestep;
@property (nonatomic, readonly) double timeSeconds;

/// Lazily-read float32 values, `nx*ny*nz` entries (nx/ny/nz from the owning EMSFieldSnapshot),
/// x-fastest-varying (index = `x + nx*(y + ny*z)`) -- one energy-density value per cell (see
/// Copper's field-frame format for the raw components used to derive it). NSData rather than a
/// boxed NSNumber array since a real board's mesh can be hundreds of thousands of cells. The data
/// is loaded from disk for this frame only; accessing another frame does not retain this one.
@property (nonatomic, copy, readonly) NSData *cellEnergyData;

@end

/// Asynchronously warms the on-disk chunk containing this frame, on a background queue, without
/// blocking the caller or evicting whatever chunk `cellEnergyData` is currently being served from --
/// call this on the frame index playback is about to reach next, so that by the time
/// `cellEnergyData` is actually requested for it, decoding has likely already finished. A no-op if
/// this chunk is already cached or already being prefetched.
@interface EMSFieldFrame (Prefetch)
- (void)prefetch;
@end

/// Everything a 3D field/energy viewer needs, in the same board-relative simulation-unit frame as
/// EMSGeometryPreview (GeometryPreviewBridge.h) -- converted here from Copper's own metres, so a
/// renderer never has to know that conversion factor exists.
@interface EMSFieldSnapshot : NSObject

/// Identity of the run represented by this series. `excitationName` is the resolved, human-readable
/// port label; `excitedPort` is its stable index within the simulation's resolved port list.
@property (nonatomic, copy, readonly) NSString *simulationName;
@property (nonatomic, readonly) NSInteger excitedPort;
@property (nonatomic, copy, readonly) NSString *excitationName;

@property (nonatomic, readonly) NSUInteger nx;
@property (nonatomic, readonly) NSUInteger ny;
@property (nonatomic, readonly) NSUInteger nz;

/// Primary (E) mesh sample positions along each axis -- `lineX.count == nx`, etc., simulation
/// units, same absolute (Edge_Cuts-relative) frame as EMSGeometryPreview's own gridLinesX/Y.
@property (nonatomic, copy, readonly) NSArray<NSNumber *> *lineX;
@property (nonatomic, copy, readonly) NSArray<NSNumber *> *lineY;
@property (nonatomic, copy, readonly) NSArray<NSNumber *> *lineZ;

/// The board's own top/bottom Z (copper+substrate stack only, not the PML/margin padding beyond
/// it) -- `boardZMax` is always 0, `boardZMin` is negative (board thickness below it), matching
/// GridGenerator's own Z convention. Simulation units, same frame as lineZ.
@property (nonatomic, readonly) double boardZMin;
@property (nonatomic, readonly) double boardZMax;

/// Lightweight handles for the run's captured frames, in timestep order -- always at least one.
/// The same mesh geometry applies to every frame; field data remains in the series file until that
/// frame's cellEnergyData is requested.
@property (nonatomic, copy, readonly) NSArray<EMSFieldFrame *> *frames;

/// The minimum and maximum cell-energy values present across *every* frame's cellEnergyData, not
/// just one frame's own -- precomputed here so a renderer maps color consistently across playback
/// (a per-frame min/max would make each frame independently rescale to full brightness, hiding the
/// run's own real growth/decay).
@property (nonatomic, readonly) float minCellEnergy;
@property (nonatomic, readonly) float maxCellEnergy;

@end

NS_ASSUME_NONNULL_END
