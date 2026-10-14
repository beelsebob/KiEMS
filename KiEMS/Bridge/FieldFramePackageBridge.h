// A `.kemsf` field-frame package opened on its own, without the simulation document that wrote it
// -- see EMSSimulationPipelineBridge's fieldFrameDirectory for how one is written.
#import <Foundation/Foundation.h>

#import "FieldSnapshotBridge.h"
#import "GeometryPreviewBridge.h"

NS_ASSUME_NONNULL_BEGIN

@interface EMSFieldFramePackage : NSObject

/// Fails if the package has no readable field series.
+ (nullable instancetype)packageWithURL:(NSURL *)url error:(NSError **)error;
- (instancetype)init NS_UNAVAILABLE;

@property (nonatomic, copy, readonly) NSString *simulationName;
/// The same series list a document's Field Viewer shows: differential pairs, then each excited
/// port, primaries carrying their adversarial variants.
@property (nonatomic, copy, readonly) NSArray<EMSFieldSnapshot *> *fieldSnapshots;
/// The board the fields were simulated over; nil for a package written without one.
@property (nonatomic, strong, readonly, nullable) EMSGeometryPreview *geometryPreview;

@end

NS_ASSUME_NONNULL_END
