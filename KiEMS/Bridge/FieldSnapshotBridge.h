// A renderable time series of one completed GPU FDTD run's full field state -- Swift-visible; never
// exposes a C++ type. Populated by EMSSimulationPipelineBridge once its own Results stage has run a
// port on the GPU (see CopperFDTDRunner's field-series capture cadence -- a handful of frames spread
// across the run, not one at the end and not every timestep).
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// One captured instant's low-resolution playback energy state. Full-resolution detail remains in
/// independently compressed storage tiles and is not decoded by ordinary playback.
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

/// Playback hint. Preview frames are small and currently streamed when displayed, so this is a
/// no-op and—critically—never triggers a full-resolution prefetch.
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

/// The minimum and maximum cell-energy values for the series. Single-ended series use exact
/// precomputed metadata; a differential combination uses a conservative bound derived from its two
/// legs so constructing the lightweight snapshot never decodes every frame. Renderers may refine
/// their display scale incrementally as frames stream in.
@property (nonatomic, readonly) float minCellEnergy;
@property (nonatomic, readonly) float maxCellEnergy;

/// Releases decoded field data while retaining this snapshot's lightweight metadata and open
/// reader. Used when switching away from a series so visiting several excitations cannot accumulate
/// one pair of frame caches per series; displaying it again simply streams its selected frame anew.
- (void)discardCachedFrameData;

@end

NS_ASSUME_NONNULL_END
