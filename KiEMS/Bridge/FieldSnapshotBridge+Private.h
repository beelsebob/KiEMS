// Internal accessor shared only between this bridge's own .mm and EMSSimulationPipelineBridge.mm --
// like GeometryPreviewBridge+Private.h, one of the few places a C++ reference type crosses an
// Objective-C interface boundary, which Swift can't see at all.
#import "FieldSnapshotBridge.h"

#include <cstdint>
#include <filesystem>
#include <map>
#include <optional>
#include <set>
#include <string>
#include <vector>

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

/// Builds a field snapshot superposing several already-built single-ended snapshots, each weighted
/// by its own entry in `coefficients` -- a differential pair's two legs (+0.5/-0.5, see this app's
/// own mixed-mode S-parameter convention, Postprocessor::getDiffPairSdd()), and/or a primary run
/// plus its adversarial runs. Reuses each leg's own already-open reader (via its first frame's data
/// source) rather than reopening any series file. Combines each frame's raw Ex/Ey/Ez/Hx/Hy/Hz
/// components -- not the legs' own precomputed per-cell energies, which would silently drop the
/// cross terms in |sum E|^2 -- then derives energy once from the combined field, matching
/// buildFieldSnapshot()'s own per-cell energy definition exactly. Frames beyond the shortest leg
/// are dropped.
///
/// Returns nil if any snapshot has zero frames, or if their grids (nx/ny/nz) don't match (they
/// always should, since every excited-port run shares the same simulation mesh, but a real
/// mismatch would otherwise silently misalign cell indices between the legs).
EMSFieldSnapshot* _Nullable buildCombinedFieldSnapshot(NSArray<EMSFieldSnapshot*>* legs,
                                                        const std::vector<double>& coefficients,
                                                        NSString* name, NSInteger excitedPort);

/// How a simulation's per-port field series combine for viewing: each excited port's name, the
/// differential pairs shown as combined series, and which runs are primary or adversarial. Taken
/// from the simulation's config by the pipeline, and saved into each `.kemsf` package
/// (series.json) so the package plays back the same views without that config.
/// A `.kemsf` package's metadata files, beside its per-port `port_N_S.h5` series.
static NSString* const kFieldFramePackageLayoutName = @"series.json";
static NSString* const kFieldFramePackageBoardName = @"board.kemsg";

struct FieldSeriesLayout {
    struct DifferentialPair {
        std::string name;
        NSInteger positivePort = 0;
        NSInteger negativePort = 0;
    };
    std::string simulationName;
    std::map<std::int32_t, std::string> excitationNames;
    std::vector<DifferentialPair> differentialPairs;
    std::set<NSInteger> primaryPorts;
    std::map<NSInteger, double> adversarialAmplitudes;
    /// Each excited port's series file, relative to the package -- empty until the run finishes.
    std::vector<std::pair<std::int32_t, std::string>> seriesFiles;
};

NSData* _Nullable encodeFieldSeriesLayout(const FieldSeriesLayout& layout);
std::optional<FieldSeriesLayout> decodeFieldSeriesLayout(NSData* data);

/// Combined snapshots kept between assembleFieldSnapshots() calls so a live refresh reuses their
/// readers and caches; rebuilt when a leg's frame count changes.
struct FieldSnapshotCombinationCache {
    NSDictionary<NSString*, EMSFieldSnapshot*>* _Nullable differential;
    NSDictionary<NSString*, EMSFieldSnapshot*>* _Nullable adversarial;
};

/// The viewer's series list from already-built single-ended snapshots: one combined entry per
/// differential pair whose legs are both present (listed first), then the single-ended series,
/// each primary (or primary pair) with withAdversarialSignals attached. Updates `cache` in place.
NSArray<EMSFieldSnapshot*>* assembleFieldSnapshots(NSArray<EMSFieldSnapshot*>* singleEnded,
                                                   const FieldSeriesLayout& layout,
                                                   FieldSnapshotCombinationCache& cache);

/// The excited-port key a differential pair's combined series uses -- distinct from every real
/// port index (always >= 0) and from every other pair's.
inline NSInteger differentialSeriesKey(NSInteger positivePort, NSInteger negativePort) {
    return -(positivePort * 100000 + negativePort + 1);
}

@interface EMSFieldSnapshot ()
@property (nonatomic, strong, nullable, readwrite) EMSFieldSnapshot* withAdversarialSignals;
@end

NS_ASSUME_NONNULL_END
