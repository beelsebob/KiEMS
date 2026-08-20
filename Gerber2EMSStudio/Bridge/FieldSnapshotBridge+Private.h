// Internal accessor shared only between this bridge's own .mm and EMSSimulationPipelineBridge.mm --
// like GeometryPreviewBridge+Private.h, one of the few places a C++ reference type crosses an
// Objective-C interface boundary, which Swift can't see at all.
#import "FieldSnapshotBridge.h"

#include "CopperFDTDRunner.h"

NS_ASSUME_NONNULL_BEGIN

/// Builds a renderable EMSFieldSnapshot directly from a completed copper::runFDTDPortOnGPU() result
/// (`snapshot` must be its `.fieldSnapshot`, only meaningful when `.success`) -- converts Copper's
/// own metres to the simulation-unit frame everything else in this app already uses (see
/// EMSFieldSnapshot's own doc comment). `boardZMin`/`boardZMax` are the caller's responsibility to
/// compute (EMSSimulationPipelineBridge.mm does this from its own scaled EMSConfig's substrate
/// stack) since Copper's own field snapshot has no notion of "the board" as distinct from "the
/// mesh" -- only the mesh's own line positions.
EMSFieldSnapshot* buildFieldSnapshot(const copper::CopperFieldSnapshot& snapshot, double boardZMin, double boardZMax);

NS_ASSUME_NONNULL_END
