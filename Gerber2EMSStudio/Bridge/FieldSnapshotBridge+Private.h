// Internal accessor shared only between this bridge's own .mm and EMSSimulationPipelineBridge.mm --
// like GeometryPreviewBridge+Private.h, one of the few places a C++ reference type crosses an
// Objective-C interface boundary, which Swift can't see at all.
#import "FieldSnapshotBridge.h"

#include <filesystem>
#include <string>

NS_ASSUME_NONNULL_BEGIN

/// Opens (or, if `previous` was already built from this exact `seriesPath`, refreshes in place)
/// a Copper field-frame series and builds a lightweight snapshot. Its EMSFieldFrame objects retain
/// only frame metadata; cellEnergyData reads and converts that one raw E/H frame on demand, so the
/// viewer never retains the full time series in memory. Passing the previous call's own snapshot
/// for the same series (or nil, the first time) lets a live SWMR update pick up newly-published
/// frames while keeping that snapshot's decode/prefetch caches warm, instead of reopening the file
/// and going cold on every call -- see this function's own definition for the exact reuse
/// conditions. Returns nil if the series cannot be opened/refreshed.
EMSFieldSnapshot* _Nullable buildFieldSnapshot(const std::filesystem::path& seriesPath,
                                                const std::string& excitationName,
                                                EMSFieldSnapshot* _Nullable previous);

NS_ASSUME_NONNULL_END
