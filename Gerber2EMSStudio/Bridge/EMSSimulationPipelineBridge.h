// Objective-C interface over one simulation's own gerber2ems::SimulationData<Stage> pipeline (see
// libgerber2ems/gerber2ems/simulation_data.hpp) -- Swift-visible; never exposes a C++ type.
#import <Foundation/Foundation.h>

#import "EMSConfigBridge.h"
#import "GeometryPreviewBridge.h"
#import "SimulationResultsBridge.h"

NS_ASSUME_NONNULL_BEGIN

/// Which of this simulation's pipeline stages a caller wants ready -- mirrors the sections a
/// simulation's source-list row expands into (Geometry, Simulation Results), plus `Grid` for the
/// Geometry screen's own "show grid" overlay (GeometryViewController) -- the only caller that ever
/// needs grid-line placement without also wanting a full FDTD run. ensureStage:Results still
/// computes Grid internally too, as an unavoidable step on the way to a real FDTD run (see
/// gerber2ems::generateGrid()'s own doc comment); either caller reuses the same cached result, so
/// whichever of the two runs first is the one that actually pays for it.
typedef NS_ENUM(NSInteger, EMSPipelineStage) {
    EMSPipelineStageGeometry = 0,
    EMSPipelineStageGrid,
    EMSPipelineStageResults,
};

/// Which part of the overall ensureStage: run a given EMSPipelineProgress report describes --
/// mirrors the Geometry/Simulation Results row split in the source list (SimulationListViewController),
/// so a caller driving those rows' own progress indicators knows which one to update. Geometry
/// covers board-slicing + grid placement (gerber2ems::GeometryPhase, reported only at each phase's
/// own start/end -- there's no finer-grained progress available for those); Simulation covers the
/// real FDTD run(s) (one per excited port) plus postprocessing, with `fraction` driven by actual
/// timestep counts (see copper::CopperFDTDProgress) -- genuinely continuous, not just phase
/// boundaries. A caller only ever sees Simulation-phase reports once every Geometry-phase report
/// for this same ensureStage: call has already landed with fraction 1.0.
typedef NS_ENUM(NSInteger, EMSPipelineProgressPhase) {
    EMSPipelineProgressPhaseGeometry = 0,
    EMSPipelineProgressPhaseSimulation,
};

/// One progress update from an in-flight ensureStage: call. `fraction` is 0...1 *within* `phase`
/// (each phase restarts from 0, it does not continue accumulating across the geometry->simulation
/// boundary) -- see EMSPipelineProgressPhase's own doc comment for why. `energyChangeDB`/
/// `targetEnergyChangeDB`/`absoluteEnergy`/`duringExcitation` are only meaningful when `phase` is
/// Simulation (mirror copper::CopperFDTDProgress's own fields of the same names -- the energy-decay
/// end-criteria's current value and dB target, e.g. for a level-indicator display, the same
/// unnormalized energy reading the dB figures are derived from, and whether the excitation pulse is
/// still actively being injected); all read 0/NO during Geometry.
@interface EMSPipelineProgress : NSObject
@property (nonatomic, readonly) EMSPipelineProgressPhase phase;
@property (nonatomic, readonly) double fraction;
@property (nonatomic, readonly) double energyChangeDB;
@property (nonatomic, readonly) double targetEnergyChangeDB;
@property (nonatomic, readonly) double absoluteEnergy;
@property (nonatomic, readonly) BOOL duringExcitation;
@end

typedef void (^EMSPipelineProgressHandler)(EMSPipelineProgress *progress);

/// Owns one simulation's own progressively-built SimulationData<Stage> chain -- Configured
/// (implicit) -> Geometry -> Grid -> Results -> Postprocessing. Each stage is computed at most once
/// and cached here for as long as this object lives, so the Geometry and Simulation Results source-
/// list rows can share one instance (see Document.swift's own pipeline(forSimulationNamed:)) and
/// never redo work a *different* row already paid for -- e.g. asking for Results after Geometry has
/// already been shown reuses that same sliced board/grid lines instead of re-slicing/re-gridding
/// from scratch, and re-selecting an already-computed row is a pure, instant cache hit.
@interface EMSSimulationPipelineBridge : NSObject

- (instancetype)initWithSimulationName:(NSString *)simulationName NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

/// Whether `stage`'s data is already cached -- a cheap, synchronous, main-thread-safe check that
/// never touches the C++ pipeline. A caller can use this to decide whether a background dispatch
/// (and a "Processing…" spinner) is even needed before calling ensureStage:.
- (BOOL)hasStage:(EMSPipelineStage)stage;

/// Runs whatever's still missing -- kicad-cli gerber export, stackup import, port resolution (once,
/// the first time any stage is computed since construction or the last invalidateFromStage: call),
/// then each pipeline stage up to and including `stage` -- to make that stage's data available. A
/// no-op beyond the hasStage: check if it's already cached. Synchronous and potentially slow
/// (board-slicing, grid placement, or a real FDTD run) -- callers must run this off the main thread.
///
/// `progressHandler`, if given, is invoked synchronously on the calling (i.e. background) thread
/// with an EMSPipelineProgress at every checkpoint this call passes through -- see
/// EMSPipelineProgressPhase's own doc comment. Callers must hop back to the main thread themselves
/// before touching UI from it, the same way they already do for this method's own completion.
- (BOOL)ensureStage:(EMSPipelineStage)stage
             config:(EMSConfigBridge *)config
         packageDir:(NSString *)packageDir
       kicadCliPath:(NSString *)kicadCliPath
kicadQueryHelperPath:(NSString *)helperPath
           progress:(nullable EMSPipelineProgressHandler)progressHandler
              error:(NSError **)error;

/// A renderable geometry preview -- nil unless hasStage:EMSPipelineStageGeometry is true.
- (nullable EMSGeometryPreview *)geometryPreview;

/// A renderable results preview -- nil unless hasStage:EMSPipelineStageResults is true.
- (nullable EMSResultsPreview *)resultsPreview;

/// Discards this stage and every stage after it (e.g. after an edit that could change the sliced
/// geometry or FDTD results) -- the next ensureStage: call recomputes from here on. Cheap,
/// synchronous, main-thread safe.
- (void)invalidateFromStage:(EMSPipelineStage)stage;

@end

NS_ASSUME_NONNULL_END
