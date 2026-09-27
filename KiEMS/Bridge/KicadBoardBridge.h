// Objective-C interface over ki's net/footprint listing queries and stackup import.
// Swift-visible; never exposes a C++ type.
#import <Foundation/Foundation.h>

#import "EMSConfigBridge.h"
#import "GeometryPreviewBridge.h"

NS_ASSUME_NONNULL_BEGIN

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

/// Candidate stitching-via positions computed with the same slicing pass the Geometry stage uses.
/// Accepted positions become gold dots in Setup; rejected positions become black crosses.
@interface KicadStitchingViaPlan : NSObject
@property (nonatomic, copy, readonly) NSArray<NSValue*>* placedPositions;
@property (nonatomic, copy, readonly) NSArray<NSValue*>* rejectedPositions;
@property (nonatomic, readonly) double annularRingDiameter;
@end

/// Immutable configuration snapshot created cheaply on the main thread, then evaluated off-thread.
@interface KicadStitchingViaPlanRequest : NSObject
- (nullable KicadStitchingViaPlan*)computeForBoard:(NSString*)kicadPcbPath
                                               error:(NSError**)error;
@end

/// Board-browsing operations, queried directly against wherever the user's KiCad project actually
/// lives -- never against a copy (see EMSConfigBridge's kicadPcbPath doc comment). Every method
/// here derives the sibling .kicad_pro path from `kicadPcbPath` the same way KiCad itself does
/// (same directory, same base name). All parsing happens in-process through libkicad.
@interface KicadBoardBridge : NSObject

/// Initializes KiCad's process-global runtime. Call once on the application's main thread before
/// any of the board-query methods are dispatched to worker queues.
+ (BOOL)prepareRuntime:(NSError**)error;

+ (nullable NSArray<NSString*>*)netClassesForBoard:(NSString*)kicadPcbPath
                                               error:(NSError**)error;

+ (nullable NSArray<NSString*>*)allNetsForBoard:(NSString*)kicadPcbPath
                                           error:(NSError**)error;

+ (nullable NSString*)netClassForNet:(NSString*)netName
                               board:(NSString*)kicadPcbPath
                               error:(NSError**)error;

+ (nullable NSArray<NSString*>*)netsInNetClassForBoard:(NSString*)kicadPcbPath
                                                netClass:(NSString*)netClass
                                                   error:(NSError**)error;

+ (nullable NSArray<KicadFootprintInfo*>*)footprintsForBoard:(NSString*)kicadPcbPath
                                                         error:(NSError**)error;

/// Every net's own copper, on every copper layer, at its own real stackup Z -- the whole board,
/// not clipped down to any one simulation's involved-nets hull the way EMSSimulationPipelineBridge.
/// geometryPreview is (see GeometryPreviewBridge+Private.h's buildWholeBoardPreview()'s own doc
/// comment). Meant for a board-wide preview shown independent of any particular simulation
/// selection -- e.g. WholeBoardViewController -- reusing the same EMSGeometryPreview shape (and so
/// the same GeometryView rendering code) as a per-simulation preview. Its copper uses KiCad's
/// explicit-net/effective-net-class/layer color precedence, and its component mesh contains every
/// footprint model KiCad can resolve; only simulation-specific vias/ports/grid fields are empty.
+ (nullable EMSGeometryPreview*)wholeBoardPreviewForBoard:(NSString*)kicadPcbPath
                                                      error:(NSError**)error;

/// Fast layer-name/color/bounds preview. Meshes are empty until layerPreviewForBoard:name:error:
/// is scheduled; this is what lets the layer UI appear without waiting for hidden geometry.
+ (nullable EMSGeometryPreview*)layerCatalogPreviewForBoard:(NSString*)kicadPcbPath
                                                 wholeBoard:(BOOL)wholeBoard
                                                      error:(NSError**)error;

+ (nullable EMSGeometryLayer*)layerPreviewForBoard:(NSString*)kicadPcbPath
                                               name:(NSString*)layerName
                                              error:(NSError**)error;

/// Captures the selected simulation's current settings without retaining the mutable document
/// model. Call the returned request's computeForBoard:error: on a worker queue.
+ (nullable KicadStitchingViaPlanRequest*)stitchingViaPlanRequestForConfig:(EMSConfigBridge*)config
                                                           simulationIndex:(NSInteger)simulationIndex;

/// Stores `kicadPcbPath` on `config` (EMSConfigBridge.kicadPcbPath) and imports the board's
/// stackup into it. Purely a read-only query against the board plus an in-memory config edit --
/// touches no filesystem location other than `kicadPcbPath`/its sibling .kicad_pro, so it works
/// equally well on a document that's never been saved.
+ (BOOL)linkKicadPCB:(NSString*)kicadPcbPath
               config:(EMSConfigBridge*)config
                error:(NSError**)error;

@end

NS_ASSUME_NONNULL_END
