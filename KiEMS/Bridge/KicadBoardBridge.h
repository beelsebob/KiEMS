// Objective-C interface over ki's net/footprint listing queries and stackup import.
// Swift-visible; never exposes a C++ type.
#import <Foundation/Foundation.h>

#import "EMSConfigBridge.h"
#import "GeometryPreviewBridge.h"

NS_ASSUME_NONNULL_BEGIN

@class KicadBoardBridge;
@class KicadHullCutTracePoint;

@interface KicadFootprintPin : NSObject
@property (nonatomic, copy, readonly) NSString* number;
/// Empty if the pad has no assigned schematic pin function.
@property (nonatomic, copy, readonly) NSString* function;
/// Empty if the pad isn't connected to any net.
@property (nonatomic, copy, readonly) NSString* netName;
/// KiCad's canonical schematic electrical type; empty when unavailable.
@property (nonatomic, copy, readonly) NSString* pinType;
@end

@interface KicadFootprintInfo : NSObject
@property (nonatomic, copy, readonly) NSString* reference;
/// KiCad's "Value" field text (e.g. "100nF", "10k") -- empty if unset.
@property (nonatomic, copy, readonly) NSString* value;
@property (nonatomic, copy, readonly) NSArray<KicadFootprintPin*>* pins;
@end

/// Whether KiEMS can simulate one footprint from the SPICE model KiCad's simulator resolves for it
/// -- see kiems::assessComponentSimModel().
@interface KicadComponentSimModel : NSObject
@property (nonatomic, copy, readonly) NSString* reference;
@property (nonatomic, readonly) BOOL supported;
/// Empty when supported; otherwise why not, for display.
@property (nonatomic, copy, readonly) NSString* reason;
@end

/// Candidate stitching-via positions computed with the same slicing pass the Geometry stage uses.
/// Accepted positions become gold dots in Setup; rejected positions become black crosses.
@interface KicadStitchingViaPlan : NSObject
@property (nonatomic, copy, readonly) NSArray<NSValue*>* placedPositions;
@property (nonatomic, copy, readonly) NSArray<NSValue*>* rejectedPositions;
@property (nonatomic, readonly) double annularRingDiameter;
@property (nonatomic, copy, readonly) NSArray<KicadHullCutTracePoint*>* hullCutTracePoints;
@end

/// A routed trace centreline crossing the simulation hull. Position is the visible/clickable
/// boundary point; inwardDirection points along retained copper.
@interface KicadHullCutTracePoint : NSObject
@property (nonatomic, copy, readonly) NSString* identifier;
@property (nonatomic, copy, readonly) NSString* netName;
@property (nonatomic, copy, readonly) NSString* layerName;
@property (nonatomic, readonly) NSPoint position;
@property (nonatomic, readonly) double inwardDirection;
@property (nonatomic, readonly) double traceWidth;
@end

/// Immutable configuration snapshot created cheaply on the main thread, then evaluated off-thread.
@interface KicadStitchingViaPlanRequest : NSObject
/// Identifies everything the plan depends on: involved/geometry-only net selectors and their hull
/// padding, hull-contributing components and their padding, the ground selector, and via placement
/// settings. Two requests with equal keys against
/// the same (unchanged) board produce the same plan, so ports, probes, absorbing/excitation state
/// and other settings that can't move the cut or its vias never trigger a recompute.
@property (nonatomic, copy, readonly) NSString* inputsKey;
- (nullable KicadStitchingViaPlan*)computeWithBoard:(KicadBoardBridge*)board error:(NSError**)error;
@end

/// KiCad's process-wide runtime, and the lock serializing every board query against it. Create
/// one on the main thread at launch, before any board query is dispatched to a worker queue. Every
/// KicadBoardBridge and EMSSimulationPipelineBridge holding it keeps it alive for as long as its
/// own board.
@interface KicadRuntime : NSObject
+ (nullable KicadRuntime*)startWithError:(NSError**)error;
- (instancetype)init NS_UNAVAILABLE;
@end

/// One KiCad board, queried directly wherever the user's KiCad project actually lives -- never a
/// copy (see EMSConfigBridge's kicadPcbPath doc comment). Owns the loaded board: the first query
/// parses it, later queries reuse it, and it reparses when the .kicad_pcb or .kicad_pro changes on
/// disk. The sibling .kicad_pro path is derived from `kicadPcbPath` the same way KiCad itself does
/// (same directory, same base name). Queries are safe to run on any queue.
@interface KicadBoardBridge : NSObject

- (instancetype)initWithRuntime:(KicadRuntime*)runtime
                    kicadPcbPath:(NSString*)kicadPcbPath NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

@property (nonatomic, copy, readonly) NSString* kicadPcbPath;

- (nullable NSArray<NSString*>*)netClassesWithError:(NSError**)error;

- (nullable NSArray<NSString*>*)allNetsWithError:(NSError**)error;

- (nullable NSString*)netClassForNet:(NSString*)netName error:(NSError**)error;

- (nullable NSArray<NSString*>*)netsInNetClass:(NSString*)netClass error:(NSError**)error;

- (nullable NSArray<KicadFootprintInfo*>*)footprintsWithError:(NSError**)error;

/// One entry per footprint, resolved through the project's schematic (which is reloaded on every
/// call -- it isn't one of the files this bridge watches). Fails if the schematic is missing or
/// unreadable.
- (nullable NSArray<KicadComponentSimModel*>*)componentSimModelsWithError:(NSError**)error;

/// Every net's own copper, on every copper layer, at its own real stackup Z -- the whole board,
/// not clipped down to any one simulation's involved-nets hull the way EMSSimulationPipelineBridge.
/// geometryPreview is (see GeometryPreviewBridge+Private.h's buildWholeBoardPreview()'s own doc
/// comment). Meant for a board-wide preview shown independent of any particular simulation
/// selection -- e.g. WholeBoardViewController -- reusing the same EMSGeometryPreview shape (and so
/// the same GeometryView rendering code) as a per-simulation preview. Its copper uses KiCad's
/// explicit-net/effective-net-class/layer color precedence, and its component mesh contains every
/// footprint model KiCad can resolve; only simulation-specific vias/ports/grid fields are empty.
- (nullable EMSGeometryPreview*)wholeBoardPreviewWithError:(NSError**)error;

/// Fast layer-name/color/bounds preview. Meshes are empty until layerPreviewNamed:error: is
/// scheduled; this is what lets the layer UI appear without waiting for hidden geometry.
- (nullable EMSGeometryPreview*)layerCatalogPreviewForWholeBoard:(BOOL)wholeBoard error:(NSError**)error;

- (nullable EMSGeometryLayer*)layerPreviewNamed:(NSString*)layerName error:(NSError**)error;

/// Captures the selected simulation's current settings without retaining the mutable document
/// model. Call the returned request's computeWithBoard:error: on a worker queue.
+ (nullable KicadStitchingViaPlanRequest*)stitchingViaPlanRequestForConfig:(EMSConfigBridge*)config
                                                           simulationIndex:(NSInteger)simulationIndex;

/// Stores this board's path on `config` (EMSConfigBridge.kicadPcbPath) and imports the board's
/// stackup into it. Purely a read-only query against the board plus an in-memory config edit --
/// touches no filesystem location other than `kicadPcbPath`/its sibling .kicad_pro, so it works
/// equally well on a document that's never been saved.
- (BOOL)linkToConfig:(EMSConfigBridge*)config error:(NSError**)error;

@end

NS_ASSUME_NONNULL_END
