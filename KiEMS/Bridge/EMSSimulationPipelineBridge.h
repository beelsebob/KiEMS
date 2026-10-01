// Objective-C interface over one simulation's own kiems::SimulationData<Stage> pipeline (see
// libkiems/kiems/simulation_data.hpp) -- Swift-visible; never exposes a C++ type.
#import <Foundation/Foundation.h>

#import "EMSConfigBridge.h"
#import "FieldSnapshotBridge.h"
#import "GeometryPreviewBridge.h"
#import "KicadBoardBridge.h"
#import "SimulationResultsBridge.h"

NS_ASSUME_NONNULL_BEGIN

/// Which of this simulation's pipeline stages a caller wants ready -- mirrors the sections a
/// simulation's source-list row expands into (Geometry, Simulation Results), plus `Grid` for the
/// Geometry screen's own "show grid" overlay (GeometryViewController) -- the only caller that ever
/// needs grid-line placement without also wanting a full FDTD run. ensureStage:Results still
/// computes Grid internally too, as an unavoidable step on the way to a real FDTD run (see
/// kiems::generateGrid()'s own doc comment); either caller reuses the same cached result, so
/// whichever of the two runs first is the one that actually pays for it.
typedef NS_ENUM(NSInteger, EMSPipelineStage) {
    EMSPipelineStageGeometry = 0,
    EMSPipelineStageGrid,
    EMSPipelineStageResults,
};

/// Which part of the overall ensureStage: run a given EMSPipelineProgress report describes --
/// mirrors the Geometry/Simulation Results row split in the source list (SimulationListViewController),
/// so a caller driving those rows' own progress indicators knows which one to update. Geometry
/// covers board-slicing + grid placement (kiems::GeometryPhase, reported only at each phase's
/// own start/end -- there's no finer-grained progress available for those); SettingUp covers
/// output-directory preparation and Copper operator construction. This reports once at the start,
/// with no useful fractional estimate, so a caller should show an
/// indeterminate ("barber pole") indicator for this phase rather than attempt to predict how long
/// it'll take); Simulation covers the real FDTD run(s) (one per excited port) plus postprocessing,
/// with `fraction` driven by actual timestep counts (see copper::CopperFDTDProgress) -- genuinely
/// continuous, not just phase boundaries. A caller only ever sees SettingUp/Simulation-phase reports
/// once every Geometry-phase report for this same ensureStage: call has already landed with fraction
/// 1.0, and Simulation only once SettingUp's own (single) report has landed.
typedef NS_ENUM(NSInteger, EMSPipelineProgressPhase) {
    EMSPipelineProgressPhaseGeometry = 0,
    EMSPipelineProgressPhaseSettingUp,
    EMSPipelineProgressPhaseSimulation,
};

/// One progress update from an in-flight ensureStage: call. `fraction` is 0...1 *within* `phase`
/// (each phase restarts from 0, it does not continue accumulating across phase boundaries) -- see
/// EMSPipelineProgressPhase's own doc comment for why (always 0 for SettingUp, which has no real
/// advancing fraction to report at all -- deliberately not estimated either, see that phase's own
/// doc comment). `energyChangeDB`/`targetEnergyChangeDB`/`absoluteEnergy`/`duringExcitation`/
/// `simulationTimeSeconds`/`excitationEndTimeSeconds`/`plannedSimulationTimeSeconds` are only
/// meaningful when `phase` is Simulation (mirror
/// copper::CopperFDTDProgress's own fields of the same
/// names -- the energy-decay end-criteria's current value and dB target, e.g. for a level-indicator
/// display, the same unnormalized energy reading the dB figures are derived from, and whether the
/// the run is still before the Gaussian pulse's maximum-amplitude/decay boundary, and the physical
/// time reached by the solver);
/// all read 0/NO otherwise.
@interface EMSPipelineProgress : NSObject
@property (nonatomic, readonly) EMSPipelineProgressPhase phase;
@property (nonatomic, readonly) double fraction;
@property (nonatomic, readonly) double energyChangeDB;
@property (nonatomic, readonly) double targetEnergyChangeDB;
@property (nonatomic, readonly) double absoluteEnergy;
@property (nonatomic, readonly) BOOL duringExcitation;
@property (nonatomic, readonly) double simulationTimeSeconds;
@property (nonatomic, readonly) double excitationEndTimeSeconds;
@property (nonatomic, readonly) double plannedSimulationTimeSeconds;
@property (nonatomic, readonly) double excitationF0Hz;
@property (nonatomic, readonly) double excitationFcHz;
/// Display name of the net driven by this setup/FDTD pass; nil during geometry generation.
@property (nonatomic, copy, readonly, nullable) NSString *excitedNetName;
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

/// `runtime` is held for the bridge's lifetime -- it owns the KiCad board this pipeline loads.
- (instancetype)initWithSimulationName:(NSString *)simulationName
                               runtime:(KicadRuntime *)runtime NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

/// Whether `stage`'s data is already cached -- a cheap, synchronous, main-thread-safe check that
/// never touches the C++ pipeline. A caller can use this to decide whether a background dispatch
/// (and a "Processing…" spinner) is even needed before calling ensureStage:.
- (BOOL)hasStage:(EMSPipelineStage)stage;

/// Whether the most recent ensureStage: call generated files that should be saved into the document
/// package. False for an in-memory cache hit and for restoring an already-saved stage after reopen.
/// JobScheduler uses this to mark the document edited only for genuinely new pipeline output.
- (BOOL)lastEnsureStageWroteOutput;

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
///
/// -requestCancellation is checked before each major phase (stackup import/port resolution,
/// geometry, grid, each excited port's own FDTD run) and, within an FDTD run itself, once per
/// timestep (via runFDTDPortOnGPU's own `isCancelled`) -- so cancellation during the dominant cost,
/// an FDTD run, takes effect within a timestep or two, while geometry/grid-phase cancellation is
/// checkpoint-based (takes effect at the next phase boundary, not mid-tessellation). On
/// cancellation this returns NO with an error -isCancellationError: recognizes, distinguishable
/// from a genuine failure.
- (BOOL)ensureStage:(EMSPipelineStage)stage
             config:(EMSConfigBridge *)config
         packageDir:(NSString *)packageDir
       kicadCliPath:(NSString *)kicadCliPath
           progress:(nullable EMSPipelineProgressHandler)progressHandler
              error:(NSError **)error;

/// Requests that an in-flight ensureStage: call on this pipeline stop as soon as possible --
/// callable from any thread (JobScheduler calls it from the main thread while ensureStage: itself
/// runs on its own background queue). Just sets a flag; ensureStage: itself is what actually checks
/// it and unwinds early -- see that method's own doc comment on where. A no-op if nothing is
/// currently running (harmlessly consumed and cleared at the start of the next ensureStage: call).
- (void)requestCancellation;

/// True iff `error` is the specific sentinel ensureStage: returns when it stopped early because of
/// -requestCancellation, rather than a genuine failure -- lets a caller (JobScheduler) tell the two
/// apart without a magic string leaking across the bridge boundary.
+ (BOOL)isCancellationError:(NSError *)error;

/// A renderable geometry preview -- nil unless hasStage:EMSPipelineStageGeometry is true.
- (nullable EMSGeometryPreview *)geometryPreview;

/// One display-only KiCad layer, cropped to this simulation's already-built cutout. Nil until the
/// Geometry stage exists; callers schedule these serially behind the initial preview.
- (nullable EMSGeometryLayer *)geometryLayerNamed:(NSString *)layerName error:(NSError **)error;

/// A renderable results preview -- nil unless hasStage:EMSPipelineStageResults is true.
- (nullable EMSResultsPreview *)resultsPreview;

/// Updates the analysis-only eye rate in an already-prepared simulation snapshot and drops only
/// the renderable preview cache. The expensive FDTD/Postprocessor data remains valid.
- (void)updateEyeBitRate:(double)bitRate;

/// One renderable field/energy series for every excitation completed by the Results stage, in port
/// execution order. The array contains lightweight metadata/lazy frame handles; field grids remain
/// on disk until a selected frame is displayed.
- (NSArray<EMSFieldSnapshot *> *)fieldSnapshots;

/// Discards this stage and every stage after it (e.g. after an edit that could change the sliced
/// geometry or FDTD results) -- the next ensureStage: call recomputes from here on. Cheap,
/// synchronous, main-thread safe.
- (void)invalidateFromStage:(EMSPipelineStage)stage;

@end

NS_ASSUME_NONNULL_END
