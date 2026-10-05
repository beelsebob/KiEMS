#import "FieldSnapshotBridge+Private.h"

#include <algorithm>
#include <array>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <limits>
#include <mutex>
#include <optional>
#include <thread>
#include <vector>

#include "FieldFrameSeriesReader.hpp"
#include "kiems/constants.hpp"
#include "CopperUtils/logging.hpp"

@interface EMSFieldFrameRefinement ()
- (instancetype)initWithPreviewCellIndex:(NSUInteger)previewCellIndex
                                       nx:(NSUInteger)nx ny:(NSUInteger)ny nz:(NSUInteger)nz
                               energyData:(NSData*)energyData;
@end

@implementation EMSFieldFrameRefinement
- (instancetype)initWithPreviewCellIndex:(NSUInteger)previewCellIndex
                                       nx:(NSUInteger)nx ny:(NSUInteger)ny nz:(NSUInteger)nz
                               energyData:(NSData*)energyData {
    if ((self = [super init])) {
        _previewCellIndex = previewCellIndex;
        _nx = nx; _ny = ny; _nz = nz;
        _cellEnergyData = [energyData copy];
    }
    return self;
}
@end

@interface EMSDecodedFieldFrame ()
- (instancetype)initWithPreviewEnergyData:(NSData*)energyData
                                refinements:(NSArray<EMSFieldFrameRefinement*>*)refinements
                               fullyDecoded:(BOOL)fullyDecoded;
@end

@implementation EMSDecodedFieldFrame
- (instancetype)initWithPreviewEnergyData:(NSData*)energyData
                                refinements:(NSArray<EMSFieldFrameRefinement*>*)refinements
                               fullyDecoded:(BOOL)fullyDecoded {
    if ((self = [super init])) {
        _previewEnergyData = [energyData copy];
        _refinements = [refinements copy];
        _fullyDecoded = fullyDecoded;
    }
    return self;
}
@end

static NSData* energyData(const std::vector<float>& ex, const std::vector<float>& ey,
                          const std::vector<float>& ez, const std::vector<float>& hx,
                          const std::vector<float>& hy, const std::vector<float>& hz) {
    if (ex.size() != ey.size() || ex.size() != ez.size() || ex.size() != hx.size() ||
        ex.size() != hy.size() || ex.size() != hz.size()) return [NSData data];
    NSMutableData* result = [NSMutableData dataWithLength:ex.size() * sizeof(float)];
    auto* values = static_cast<float*>(result.mutableBytes);
    constexpr float kEps0 = 8.8541878128e-12F;
    constexpr float kMu0 = 1.25663706212e-6F;
    for (std::size_t i = 0; i < ex.size(); ++i) {
        values[i] = kEps0 * (ex[i] * ex[i] + ey[i] * ey[i] + ez[i] * ez[i]) +
                    kMu0 * (hx[i] * hx[i] + hy[i] * hy[i] + hz[i] * hz[i]);
    }
    return result;
}

/// Common interface EMSFieldFrame needs from whatever is actually behind it: either a single run's
/// own EMSFieldFrameDataSource, or an EMSCombinedFieldFrameDataSource combining two of them into a
/// differential-mode view. Frame indices are meaningful only within one data source; a combined
/// source's own frame `i` is derived from its two legs' own frame `i`, not looked up by timestep.
@protocol EMSFieldFrameDataSourcing <NSObject>
- (EMSDecodedFieldFrame*)decodedFrameForFrame:(NSUInteger)frameIndex;
- (void)prepareFrame:(NSUInteger)frameIndex budget:(NSTimeInterval)seconds
           completion:(void (^ _Nullable)(BOOL fullyDecoded))completion;
- (void)discardCachedFrameData;
@end

@interface EMSFieldFrameDataSource : NSObject <EMSFieldFrameDataSourcing> {
@private
    std::optional<copper::FieldFrameSeriesReader> _reader;
    std::mutex _mutex;
    NSUInteger _cachedFrameIndex;
    EMSDecodedFieldFrame* _cachedFrame;
    NSUInteger _preparedFrameIndex;
    EMSDecodedFieldFrame* _preparedFrame;
    NSUInteger _preparingFrameIndex;
    dispatch_queue_t _decodeQueue;
    NSUInteger _cacheGeneration;
}
- (instancetype)initWithReader:(copper::FieldFrameSeriesReader&&)reader;
- (EMSDecodedFieldFrame*)decodeFrame:(NSUInteger)frameIndex budget:(NSTimeInterval)seconds
                            resuming:(EMSDecodedFieldFrame* _Nullable)existing;
/// The wrapped reader, for buildFieldSnapshot() to query metadata from (and to refresh, when
/// reusing this data source for a live update of the same series instead of reopening one) --
/// every public FieldFrameSeriesReader method is internally synchronized (see its own doc comment),
/// so handing out this reference doesn't bypass -energyDataForFrame:/-prefetchFrame:'s own safety.
- (copper::FieldFrameSeriesReader&)reader;
@end

@implementation EMSFieldFrameDataSource

- (instancetype)initWithReader:(copper::FieldFrameSeriesReader&&)reader {
    self = [super init];
    if (self) {
        _reader.emplace(std::move(reader));
        _cachedFrameIndex = NSNotFound;
        _preparedFrameIndex = NSNotFound;
        _preparingFrameIndex = NSNotFound;
        _cacheGeneration = 0;
        _decodeQueue = dispatch_queue_create("com.kiems.field-frame-decode", DISPATCH_QUEUE_SERIAL);
    }
    return self;
}

- (EMSDecodedFieldFrame*)decodedFrameForFrame:(NSUInteger)frameIndex {
    bool waitForPreparation = false;
    {
        std::lock_guard lock(_mutex);
        if (_cachedFrameIndex == frameIndex && _cachedFrame != nil) return _cachedFrame;
        if (_preparedFrameIndex == frameIndex && _preparedFrame != nil) {
            _cachedFrameIndex = frameIndex;
            _cachedFrame = _preparedFrame;
            _preparedFrameIndex = NSNotFound;
            _preparedFrame = nil;
            return _cachedFrame;
        }
        waitForPreparation = _preparingFrameIndex == frameIndex;
    }
    // If playback is just reaching a frame whose bounded preparation is still finishing, wait for
    // that one serial decode rather than redundantly reading a cold preview on the UI thread.
    if (waitForPreparation) dispatch_sync(_decodeQueue, ^{});
    {
        std::lock_guard lock(_mutex);
        if (_preparedFrameIndex == frameIndex && _preparedFrame != nil) {
            _cachedFrameIndex = frameIndex;
            _cachedFrame = _preparedFrame;
            _preparedFrameIndex = NSNotFound;
            _preparedFrame = nil;
            return _cachedFrame;
        }
    }
    EMSDecodedFieldFrame* decoded = [self decodeFrame:frameIndex budget:0 resuming:nil];
    std::lock_guard lock(_mutex);
    _cachedFrameIndex = frameIndex;
    _cachedFrame = decoded;
    return decoded;
}

- (EMSDecodedFieldFrame*)decodeFrame:(NSUInteger)frameIndex budget:(NSTimeInterval)seconds
                            resuming:(EMSDecodedFieldFrame*)existing {
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::duration<double>(seconds);
    NSArray<EMSFieldFrameRefinement*>* existingRefinements =
        existing != nil ? existing.refinements : @[];
    NSData* preview = existing.previewEnergyData;
    if (preview == nil) {
        std::vector<float> energy, ex, ey, ez, hx, hy, hz;
        auto read = _reader->readPreviewFrame(static_cast<std::uint32_t>(frameIndex), energy,
                                              ex, ey, ez, hx, hy, hz);
        if (!read) {
            Cu::logError() << "Could not read frame " << std::to_string(frameIndex) << ": " << read.error();
            return [[EMSDecodedFieldFrame alloc] initWithPreviewEnergyData:[NSData data]
                                                                refinements:@[] fullyDecoded:YES];
        }
        preview = [NSData dataWithBytes:energy.data() length:energy.size() * sizeof(float)];
    }
    if (seconds <= 0) return [[EMSDecodedFieldFrame alloc]
        initWithPreviewEnergyData:preview refinements:existingRefinements fullyDecoded:NO];

    auto order = _reader->readRefinementOrder(static_cast<std::uint32_t>(frameIndex));
    if (!order) {
        Cu::logWarning() << "Could not read refinement order for frame " << frameIndex << ": " << order.error();
        return [[EMSDecodedFieldFrame alloc] initWithPreviewEnergyData:preview
                                                            refinements:existingRefinements fullyDecoded:YES];
    }
    NSMutableArray<EMSFieldFrameRefinement*>* refinements =
        [NSMutableArray arrayWithArray:existingRefinements];
    const std::size_t batchSize = std::max<std::size_t>(1, std::thread::hardware_concurrency());
    std::size_t orderIndex = refinements.count;
    while (orderIndex < order->size() && std::chrono::steady_clock::now() < deadline) {
        const std::size_t batchEnd = std::min(orderIndex + batchSize, order->size());
        std::vector<std::uint32_t> cells(order->begin() + static_cast<std::ptrdiff_t>(orderIndex),
                                         order->begin() + static_cast<std::ptrdiff_t>(batchEnd));
        auto details = _reader->readPreviewCellDetails(static_cast<std::uint32_t>(frameIndex), cells);
        if (!details) {
            Cu::logWarning() << "Could not decode field-detail batch: " << details.error();
            break;
        }
        for (auto& detail : *details) {
            [refinements addObject:[[EMSFieldFrameRefinement alloc]
                initWithPreviewCellIndex:detail.previewCellIndex
                nx:detail.nx ny:detail.ny nz:detail.nz
                energyData:energyData(detail.components[0], detail.components[1], detail.components[2],
                                      detail.components[3], detail.components[4], detail.components[5])]];
        }
        orderIndex = batchEnd;
    }
    return [[EMSDecodedFieldFrame alloc] initWithPreviewEnergyData:preview refinements:refinements
                                                       fullyDecoded:refinements.count == order->size()];
}

- (void)prepareFrame:(NSUInteger)frameIndex budget:(NSTimeInterval)seconds
           completion:(void (^)(BOOL))completion {
    NSUInteger generation;
    EMSDecodedFieldFrame* existing = nil;
    {
        std::lock_guard lock(_mutex);
        if (_cachedFrameIndex == frameIndex) existing = _cachedFrame;
        else if (_preparedFrameIndex == frameIndex) existing = _preparedFrame;
        if (existing.fullyDecoded) {
            if (completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(YES); });
            return;
        }
        generation = ++_cacheGeneration;
        _preparingFrameIndex = frameIndex;
    }
    dispatch_async(_decodeQueue, ^{
        {
            std::lock_guard lock(self->_mutex);
            if (generation != self->_cacheGeneration) return;
        }
        EMSDecodedFieldFrame* decoded = [self decodeFrame:frameIndex budget:seconds resuming:existing];
        BOOL accepted = NO;
        {
            std::lock_guard lock(self->_mutex);
            if (self->_preparingFrameIndex == frameIndex) self->_preparingFrameIndex = NSNotFound;
            if (generation == self->_cacheGeneration) {
                if (self->_cachedFrameIndex == frameIndex) self->_cachedFrame = decoded;
                else {
                    self->_preparedFrameIndex = frameIndex;
                    self->_preparedFrame = decoded;
                }
                accepted = YES;
            }
        }
        if (accepted && completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(decoded.fullyDecoded); });
    });
}

- (void)discardCachedFrameData {
    std::lock_guard lock(_mutex);
    ++_cacheGeneration;
    _cachedFrameIndex = NSNotFound;
    _cachedFrame = nil;
    _preparedFrameIndex = NSNotFound;
    _preparedFrame = nil;
    _preparingFrameIndex = NSNotFound;
    _reader->clearFrameCache();
}

- (copper::FieldFrameSeriesReader&)reader {
    return *_reader;
}

@end

/// Weighted superposition of several runs' own EMSFieldFrameDataSource -- a differential pair's two
/// legs (+0.5/-0.5), and/or a primary run plus its adversarial runs. Each coefficient is applied to
/// that leg's raw Ex/Ey/Ez/Hx/Hy/Hz components (not to the legs' own precomputed energies -- see
/// buildCombinedFieldSnapshot()'s own doc comment) before deriving one energy value per cell from
/// the combined field, so the result reflects genuine interference rather than the sum of
/// independent energy maps.
@interface EMSCombinedFieldFrameDataSource : NSObject <EMSFieldFrameDataSourcing> {
@private
    std::vector<EMSFieldFrameDataSource*> _sources;
    std::vector<double> _coefficients;
    std::mutex _mutex;
    NSUInteger _cachedFrameIndex;
    EMSDecodedFieldFrame* _cachedFrame;
    NSUInteger _preparedFrameIndex;
    EMSDecodedFieldFrame* _preparedFrame;
    NSUInteger _preparingFrameIndex;
    dispatch_queue_t _decodeQueue;
    NSUInteger _cacheGeneration;
}
- (instancetype)initWithSources:(std::vector<EMSFieldFrameDataSource*>)sources
                   coefficients:(std::vector<double>)coefficients;
- (EMSDecodedFieldFrame*)decodeFrame:(NSUInteger)frameIndex budget:(NSTimeInterval)seconds
                            resuming:(EMSDecodedFieldFrame* _Nullable)existing;
@end

@implementation EMSCombinedFieldFrameDataSource

- (instancetype)initWithSources:(std::vector<EMSFieldFrameDataSource*>)sources
                   coefficients:(std::vector<double>)coefficients {
    self = [super init];
    if (self) {
        _sources = std::move(sources);
        _coefficients = std::move(coefficients);
        _cachedFrameIndex = NSNotFound;
        _preparedFrameIndex = NSNotFound;
        _preparingFrameIndex = NSNotFound;
        _cacheGeneration = 0;
        _decodeQueue = dispatch_queue_create("com.kiems.combined-field-frame-decode", DISPATCH_QUEUE_SERIAL);
    }
    return self;
}

- (EMSDecodedFieldFrame*)decodedFrameForFrame:(NSUInteger)frameIndex {
    bool waitForPreparation = false;
    {
        std::lock_guard lock(_mutex);
        if (_cachedFrameIndex == frameIndex && _cachedFrame != nil) return _cachedFrame;
        if (_preparedFrameIndex == frameIndex && _preparedFrame != nil) {
            _cachedFrameIndex = frameIndex;
            _cachedFrame = _preparedFrame;
            _preparedFrameIndex = NSNotFound;
            _preparedFrame = nil;
            return _cachedFrame;
        }
        waitForPreparation = _preparingFrameIndex == frameIndex;
    }
    if (waitForPreparation) dispatch_sync(_decodeQueue, ^{});
    {
        std::lock_guard lock(_mutex);
        if (_preparedFrameIndex == frameIndex && _preparedFrame != nil) {
            _cachedFrameIndex = frameIndex;
            _cachedFrame = _preparedFrame;
            _preparedFrameIndex = NSNotFound;
            _preparedFrame = nil;
            return _cachedFrame;
        }
    }
    EMSDecodedFieldFrame* decoded = [self decodeFrame:frameIndex budget:0 resuming:nil];
    std::lock_guard lock(_mutex);
    _cachedFrameIndex = frameIndex;
    _cachedFrame = decoded;
    return decoded;
}

- (EMSDecodedFieldFrame*)decodeFrame:(NSUInteger)frameIndex budget:(NSTimeInterval)seconds
                            resuming:(EMSDecodedFieldFrame*)existing {
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::duration<double>(seconds);
    NSArray<EMSFieldFrameRefinement*>* existingRefinements =
        existing != nil ? existing.refinements : @[];
    constexpr float kEps0 = 8.8541878128e-12F;
    constexpr float kMu0 = 1.25663706212e-6F;
    NSData* result = existing.previewEnergyData;
    if (result == nil) {
        std::array<std::vector<float>, 6> sum;
        for (std::size_t leg = 0; leg < _sources.size(); ++leg) {
            std::vector<float> energy;
            std::array<std::vector<float>, 6> c;
            auto read = _sources[leg].reader.readPreviewFrame(static_cast<std::uint32_t>(frameIndex), energy,
                                                              c[0], c[1], c[2], c[3], c[4], c[5]);
            if (!read || (leg > 0 && c[0].size() != sum[0].size())) {
                Cu::logError() << "Could not combine preview frame " << std::to_string(frameIndex);
                return [[EMSDecodedFieldFrame alloc] initWithPreviewEnergyData:[NSData data]
                                                                    refinements:@[] fullyDecoded:YES];
            }
            const auto k = static_cast<float>(_coefficients[leg]);
            for (std::size_t component = 0; component < 6; ++component) {
                if (leg == 0) sum[component].assign(c[component].size(), 0.0F);
                for (std::size_t i = 0; i < c[component].size(); ++i) sum[component][i] += k * c[component][i];
            }
        }
        NSMutableData* combined = [NSMutableData dataWithLength:sum[0].size() * sizeof(float)];
        auto* energy = static_cast<float*>(combined.mutableBytes);
        for (std::size_t i = 0; i < sum[0].size(); ++i) {
            energy[i] = kEps0 * (sum[0][i] * sum[0][i] + sum[1][i] * sum[1][i] + sum[2][i] * sum[2][i]) +
                        kMu0 * (sum[3][i] * sum[3][i] + sum[4][i] * sum[4][i] + sum[5][i] * sum[5][i]);
        }
        result = combined;
    }
    if (seconds <= 0) return [[EMSDecodedFieldFrame alloc]
        initWithPreviewEnergyData:result refinements:existingRefinements fullyDecoded:NO];

    auto order = _sources.front().reader.readRefinementOrder(static_cast<std::uint32_t>(frameIndex));
    if (!order) return [[EMSDecodedFieldFrame alloc] initWithPreviewEnergyData:result
                                                          refinements:existingRefinements fullyDecoded:YES];
    NSMutableArray<EMSFieldFrameRefinement*>* refinements =
        [NSMutableArray arrayWithArray:existingRefinements];
    const std::size_t batchSize = std::max<std::size_t>(1, std::thread::hardware_concurrency());
    std::size_t orderIndex = refinements.count;
    while (orderIndex < order->size() && std::chrono::steady_clock::now() < deadline) {
        const std::size_t batchEnd = std::min(orderIndex + batchSize, order->size());
        std::vector<std::uint32_t> cells(order->begin() + static_cast<std::ptrdiff_t>(orderIndex),
                                         order->begin() + static_cast<std::ptrdiff_t>(batchEnd));
        auto sumDetails = _sources.front().reader.readPreviewCellDetails(static_cast<std::uint32_t>(frameIndex), cells);
        bool ok = sumDetails.has_value();
        if (ok) {
            const auto k0 = static_cast<float>(_coefficients.front());
            for (auto& detail : *sumDetails) {
                for (auto& component : detail.components) {
                    for (float& v : component) v *= k0;
                }
            }
        }
        for (std::size_t leg = 1; ok && leg < _sources.size(); ++leg) {
            auto details = _sources[leg].reader.readPreviewCellDetails(static_cast<std::uint32_t>(frameIndex), cells);
            if (!details || details->size() != sumDetails->size()) {
                ok = false;
                break;
            }
            const auto k = static_cast<float>(_coefficients[leg]);
            for (std::size_t detailIndex = 0; detailIndex < details->size(); ++detailIndex) {
                auto& into = (*sumDetails)[detailIndex];
                const auto& from = (*details)[detailIndex];
                for (std::size_t component = 0; component < 6; ++component) {
                    if (into.components[component].size() != from.components[component].size()) {
                        ok = false;
                        break;
                    }
                    for (std::size_t i = 0; i < from.components[component].size(); ++i) {
                        into.components[component][i] += k * from.components[component][i];
                    }
                }
            }
        }
        if (!ok) {
            Cu::logWarning() << "Could not decode combined field-detail batch";
            break;
        }
        for (const auto& p : *sumDetails) {
            [refinements addObject:[[EMSFieldFrameRefinement alloc]
                initWithPreviewCellIndex:p.previewCellIndex nx:p.nx ny:p.ny nz:p.nz
                energyData:energyData(p.components[0], p.components[1], p.components[2],
                                      p.components[3], p.components[4], p.components[5])]];
        }
        orderIndex = batchEnd;
    }
    return [[EMSDecodedFieldFrame alloc] initWithPreviewEnergyData:result refinements:refinements
                                                       fullyDecoded:refinements.count == order->size()];
}

- (void)prepareFrame:(NSUInteger)frameIndex budget:(NSTimeInterval)seconds
           completion:(void (^)(BOOL))completion {
    NSUInteger generation;
    EMSDecodedFieldFrame* existing = nil;
    {
        std::lock_guard lock(_mutex);
        if (_cachedFrameIndex == frameIndex) existing = _cachedFrame;
        else if (_preparedFrameIndex == frameIndex) existing = _preparedFrame;
        if (existing.fullyDecoded) {
            if (completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(YES); });
            return;
        }
        generation = ++_cacheGeneration;
        _preparingFrameIndex = frameIndex;
    }
    dispatch_async(_decodeQueue, ^{
        {
            std::lock_guard lock(self->_mutex);
            if (generation != self->_cacheGeneration) return;
        }
        EMSDecodedFieldFrame* decoded = [self decodeFrame:frameIndex budget:seconds resuming:existing];
        BOOL accepted = NO;
        {
            std::lock_guard lock(self->_mutex);
            if (self->_preparingFrameIndex == frameIndex) self->_preparingFrameIndex = NSNotFound;
            if (generation == self->_cacheGeneration) {
                if (self->_cachedFrameIndex == frameIndex) self->_cachedFrame = decoded;
                else {
                    self->_preparedFrameIndex = frameIndex;
                    self->_preparedFrame = decoded;
                }
                accepted = YES;
            }
        }
        if (accepted && completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(decoded.fullyDecoded); });
    });
}

- (void)discardCachedFrameData {
    {
        std::lock_guard lock(_mutex);
        ++_cacheGeneration;
        _cachedFrameIndex = NSNotFound;
        _cachedFrame = nil;
        _preparedFrameIndex = NSNotFound;
        _preparedFrame = nil;
        _preparingFrameIndex = NSNotFound;
    }
    for (EMSFieldFrameDataSource* source : _sources) [source discardCachedFrameData];
}

@end

@interface EMSFieldFrame ()
@property (nonatomic, strong) id<EMSFieldFrameDataSourcing> dataSource;
@property (nonatomic) NSUInteger frameIndex;
- (instancetype)initWithTimestep:(NSUInteger)timestep
                      timeSeconds:(double)timeSeconds
                       frameIndex:(NSUInteger)frameIndex
                       dataSource:(id<EMSFieldFrameDataSourcing>)dataSource;
@end

@implementation EMSFieldFrame

- (instancetype)initWithTimestep:(NSUInteger)timestep
                      timeSeconds:(double)timeSeconds
                       frameIndex:(NSUInteger)frameIndex
                       dataSource:(id<EMSFieldFrameDataSourcing>)dataSource {
    self = [super init];
    if (self) {
        _timestep = timestep;
        _timeSeconds = timeSeconds;
        _frameIndex = frameIndex;
        _dataSource = dataSource;
    }
    return self;
}

- (NSData*)cellEnergyData {
    return self.decodedFrame.previewEnergyData;
}

- (EMSDecodedFieldFrame*)decodedFrame {
    return [_dataSource decodedFrameForFrame:_frameIndex];
}

@end

@implementation EMSFieldFrame (Prefetch)

- (void)prepareWithBudget:(NSTimeInterval)seconds {
    [self prepareWithBudget:seconds completion:nil];
}

- (void)prepareWithBudget:(NSTimeInterval)seconds completion:(void (^)(BOOL))completion {
    [self.dataSource prepareFrame:self.frameIndex budget:seconds completion:completion];
}

@end

@implementation EMSFieldSnapshot

@synthesize withAdversarialSignals = _withAdversarialSignals;

- (instancetype)initWithNx:(NSUInteger)nx
             simulationName:(NSString*)simulationName
                excitedPort:(NSInteger)excitedPort
             excitationName:(NSString*)excitationName
                         ny:(NSUInteger)ny
                         nz:(NSUInteger)nz
                      lineX:(NSArray<NSNumber*>*)lineX
                      lineY:(NSArray<NSNumber*>*)lineY
                      lineZ:(NSArray<NSNumber*>*)lineZ
                     fullNx:(NSUInteger)fullNx fullNy:(NSUInteger)fullNy fullNz:(NSUInteger)fullNz
             previewFactorX:(NSUInteger)previewFactorX
             previewFactorY:(NSUInteger)previewFactorY
             previewFactorZ:(NSUInteger)previewFactorZ
                  fullLineX:(NSArray<NSNumber*>*)fullLineX
                  fullLineY:(NSArray<NSNumber*>*)fullLineY
                  fullLineZ:(NSArray<NSNumber*>*)fullLineZ
      fullDomainXYClassData:(NSData*)fullDomainXYClassData
                  boardZMin:(double)boardZMin
                  boardZMax:(double)boardZMax
                     frames:(NSArray<EMSFieldFrame*>*)frames
              minCellEnergy:(float)minCellEnergy
              maxCellEnergy:(float)maxCellEnergy {
    self = [super init];
    if (self) {
        _simulationName = [simulationName copy];
        _excitedPort = excitedPort;
        _excitationName = [excitationName copy];
        _nx = nx;
        _ny = ny;
        _nz = nz;
        _lineX = [lineX copy];
        _lineY = [lineY copy];
        _lineZ = [lineZ copy];
        _fullNx = fullNx; _fullNy = fullNy; _fullNz = fullNz;
        _previewFactorX = previewFactorX;
        _previewFactorY = previewFactorY;
        _previewFactorZ = previewFactorZ;
        _fullLineX = [fullLineX copy];
        _fullLineY = [fullLineY copy];
        _fullLineZ = [fullLineZ copy];
        _fullDomainXYClassData = [fullDomainXYClassData copy];
        _boardZMin = boardZMin;
        _boardZMax = boardZMax;
        _frames = [frames copy];
        _minCellEnergy = minCellEnergy;
        _maxCellEnergy = maxCellEnergy;
    }
    return self;
}

- (void)discardCachedFrameData {
    EMSFieldFrame* firstFrame = self.frames.firstObject;
    [firstFrame.dataSource discardCachedFrameData];
}

@end

namespace {

// Copper's own field snapshot is in metres (see CopperFieldSnapshot's own doc comment); everything
// else in this app is in simulation units (constants::baseUnit microns, constants::unitMultiplier
// per micron -- see EMSFieldSnapshot's own doc comment on why this bridge does that conversion
// once, here, rather than every caller needing to know it exists). Same derivation as
// GeometryPreviewBridge.mm's own mmToSimUnits().
constexpr double kMetersToSimUnits =
    static_cast<double>(kiems::constants::unitMultiplier) / kiems::constants::baseUnit;

NSArray<NSNumber*>* convertLine(const std::vector<double>& metres) {
    NSMutableArray<NSNumber*>* out = [NSMutableArray arrayWithCapacity:metres.size()];
    for (const double v : metres) {
        [out addObject:@(v * kMetersToSimUnits)];
    }
    return out;
}

} // namespace

EMSFieldSnapshot* buildFieldSnapshot(const std::filesystem::path& seriesPath,
                                     const std::string& excitationName,
                                     EMSFieldSnapshot* previous) {
    // Reusing `previous`'s own data source (rather than reopening the file from scratch) is what
    // lets a live UI refresh pick up newly-published frames without going cold: refresh() is a
    // lightweight SWMR metadata sync (see FieldFrameSeriesReader::refresh()'s own doc comment), and
    // crucially leaves the reader's bounded decode/prefetch frame caches untouched, so a frame already
    // decoded moments ago in the previous snapshot's data source is still warm in this one. The
    // caller (EMSSimulationPipelineBridge.fieldSnapshots) is responsible for only ever passing a
    // `previous` that was itself built from this exact `seriesPath` -- a rerun's ping-ponged path
    // means a stale `previous` naturally won't be offered here at all.
    // previous, when non-nil, is always itself the result of an earlier buildFieldSnapshot() call
    // (see this function's own doc comment) -- buildCombinedFieldSnapshot() never hands its result
    // back in here -- so this data source is always the concrete single-reader kind, never
    // EMSCombinedFieldFrameDataSource.
    EMSFieldFrameDataSource* dataSource = (EMSFieldFrameDataSource*)previous.frames.firstObject.dataSource;
    if (dataSource != nil) {
        if (auto refreshed = dataSource.reader.refresh(); !refreshed) {
            Cu::logError() << "Could not refresh " << seriesPath.string() << ", reopening: " << refreshed.error();
            dataSource = nil;
        }
    }
    if (dataSource == nil) {
        auto opened = copper::FieldFrameSeriesReader::open(seriesPath);
        if (!opened) {
            Cu::logError() << "Could not open " << seriesPath.string() << ": " << opened.error();
            return nil;
        }
        dataSource = [[EMSFieldFrameDataSource alloc] initWithReader:std::move(*opened)];
    }

    copper::FieldFrameSeriesReader& reader = dataSource.reader;
    const copper::FieldFrameSeriesWriter::Header header = reader.previewHeader();
    const copper::FieldFrameSeriesWriter::Header fullHeader = reader.header();
    const std::uint32_t frameCount = reader.frameCount();
    // A newly-created SWMR file is discoverable before its first complete block is published.
    // Keep showing setup/progress until there is an actual frame to display; close() publishes a
    // short final block, so even a run with fewer than 16 captures still appears when complete.
    if (frameCount == 0) {
        return nil;
    }
    float minEnergy = std::numeric_limits<float>::infinity();
    float maxEnergy = -std::numeric_limits<float>::infinity();
    std::vector<std::uint32_t> timesteps(frameCount);
    std::vector<double> times(frameCount);
    for (std::uint32_t i = 0; i < frameCount; ++i) {
        timesteps[i] = reader.timestep(i);
        times[i] = reader.timeSeconds(i);
        minEnergy = std::min(minEnergy, reader.minEnergy(i));
        maxEnergy = std::max(maxEnergy, reader.maxEnergy(i));
    }
    NSMutableArray<EMSFieldFrame*>* frames = [NSMutableArray arrayWithCapacity:frameCount];
    for (std::uint32_t i = 0; i < frameCount; ++i) {
        [frames addObject:[[EMSFieldFrame alloc] initWithTimestep:timesteps[i]
                                                        timeSeconds:times[i]
                                                         frameIndex:i
                                                         dataSource:dataSource]];
    }

    return [[EMSFieldSnapshot alloc] initWithNx:header.nx
                                  simulationName:@(header.simulationName.c_str())
                                     excitedPort:header.excitedPort
                                  excitationName:@(excitationName.c_str())
                                              ny:header.ny
                                              nz:header.nz
                                           lineX:convertLine(header.lineX)
                                           lineY:convertLine(header.lineY)
                                           lineZ:convertLine(header.lineZ)
                                          fullNx:fullHeader.nx fullNy:fullHeader.ny fullNz:fullHeader.nz
                                  previewFactorX:reader.previewFactorX()
                                  previewFactorY:reader.previewFactorY()
                                  previewFactorZ:reader.previewFactorZ()
                                       fullLineX:convertLine(fullHeader.lineX)
                                       fullLineY:convertLine(fullHeader.lineY)
                                       fullLineZ:convertLine(fullHeader.lineZ)
                           fullDomainXYClassData:[NSData dataWithBytes:fullHeader.domainXYClass.data()
                                                                  length:fullHeader.domainXYClass.size()]
                                       boardZMin:header.boardZMin * kMetersToSimUnits
                                       boardZMax:header.boardZMax * kMetersToSimUnits
                                          frames:frames
                                   minCellEnergy:minEnergy
                                   maxCellEnergy:maxEnergy];
}

EMSFieldSnapshot* buildCombinedFieldSnapshot(NSArray<EMSFieldSnapshot*>* legs, const std::vector<double>& coefficients,
                                             NSString* name, NSInteger excitedPort) {
    if (legs.count == 0 || legs.count != coefficients.size()) {
        return nil;
    }
    EMSFieldSnapshot* legP = legs.firstObject;
    std::vector<EMSFieldFrameDataSource*> sources;
    NSUInteger frameCount = NSUIntegerMax;
    for (EMSFieldSnapshot* leg in legs) {
        if (leg.frames.count == 0) {
            return nil;
        }
        if (leg.nx != legP.nx || leg.ny != legP.ny || leg.nz != legP.nz) {
            Cu::logError() << "Field combine '" << name.UTF8String << "': grid mismatch (" << legP.nx << "x"
                            << legP.ny << "x" << legP.nz << " vs " << leg.nx << "x" << leg.ny << "x" << leg.nz << ")";
            return nil;
        }
        // Every leg is always built by buildFieldSnapshot() (see this function's own doc comment and
        // its caller in EMSSimulationPipelineBridge.mm), never by this function, so each leg's own
        // first-frame data source is always the concrete single-reader kind here.
        sources.push_back((EMSFieldFrameDataSource*)leg.frames.firstObject.dataSource);
        frameCount = std::min(frameCount, leg.frames.count);
    }
    EMSCombinedFieldFrameDataSource* combined =
        [[EMSCombinedFieldFrameDataSource alloc] initWithSources:sources coefficients:coefficients];

    NSMutableArray<EMSFieldFrame*>* frames = [NSMutableArray arrayWithCapacity:frameCount];
    for (NSUInteger i = 0; i < frameCount; ++i) {
        EMSFieldFrame* pFrame = legP.frames[i];
        EMSFieldFrame* frame = [[EMSFieldFrame alloc] initWithTimestep:pFrame.timestep
                                                             timeSeconds:pFrame.timeSeconds
                                                              frameIndex:i
                                                              dataSource:combined];
        [frames addObject:frame];
    }

    // Do not decode the differential series merely to populate display metadata. By the weighted
    // triangle inequality, this is a conservative energy upper bound derived from the two legs'
    // cheap precomputed maxima; FieldView derives its tighter on-board scale incrementally as each
    // frame is actually displayed.
    double maxAmplitude = 0;
    for (NSUInteger leg = 0; leg < legs.count; ++leg) {
        maxAmplitude += std::abs(coefficients[leg]) * std::sqrt(std::max(0.0F, legs[leg].maxCellEnergy));
    }
    const float minEnergy = 0.0F;
    const float maxEnergy = static_cast<float>(maxAmplitude * maxAmplitude);

    return [[EMSFieldSnapshot alloc] initWithNx:legP.nx
                                  simulationName:legP.simulationName
                                     excitedPort:excitedPort
                                  excitationName:name
                                              ny:legP.ny
                                              nz:legP.nz
                                           lineX:legP.lineX
                                           lineY:legP.lineY
                                           lineZ:legP.lineZ
                                          fullNx:legP.fullNx fullNy:legP.fullNy fullNz:legP.fullNz
                                  previewFactorX:legP.previewFactorX
                                  previewFactorY:legP.previewFactorY
                                  previewFactorZ:legP.previewFactorZ
                                       fullLineX:legP.fullLineX
                                       fullLineY:legP.fullLineY
                                       fullLineZ:legP.fullLineZ
                           fullDomainXYClassData:legP.fullDomainXYClassData
                                       boardZMin:legP.boardZMin
                                       boardZMax:legP.boardZMax
                                          frames:frames
                                   minCellEnergy:minEnergy
                                   maxCellEnergy:maxEnergy];
}
