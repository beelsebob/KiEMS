#import "FieldSnapshotBridge+Private.h"

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <limits>
#include <mutex>
#include <optional>

#include "FieldFrameSeriesReader.hpp"
#include "kiems/constants.hpp"
#include "CopperUtils/logging.hpp"

/// Common interface EMSFieldFrame needs from whatever is actually behind it: either a single run's
/// own EMSFieldFrameDataSource, or an EMSCombinedFieldFrameDataSource combining two of them into a
/// differential-mode view. Frame indices are meaningful only within one data source; a combined
/// source's own frame `i` is derived from its two legs' own frame `i`, not looked up by timestep.
@protocol EMSFieldFrameDataSourcing <NSObject>
- (NSData*)energyDataForFrame:(NSUInteger)frameIndex;
- (void)prefetchFrame:(NSUInteger)frameIndex;
- (void)discardCachedFrameData;
@end

@interface EMSFieldFrameDataSource : NSObject <EMSFieldFrameDataSourcing> {
@private
    std::optional<copper::FieldFrameSeriesReader> _reader;
    std::mutex _mutex;
    NSUInteger _cachedFrameIndex;
    NSData* _cachedEnergyData;
}
- (instancetype)initWithReader:(copper::FieldFrameSeriesReader&&)reader;
- (NSData*)energyDataForFrame:(NSUInteger)frameIndex;
- (void)prefetchFrame:(NSUInteger)frameIndex;
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
    }
    return self;
}

- (NSData*)energyDataForFrame:(NSUInteger)frameIndex {
    std::lock_guard lock(_mutex);
    if (_cachedFrameIndex == frameIndex && _cachedEnergyData != nil) {
        return _cachedEnergyData;
    }
    std::vector<float> energy, ex, ey, ez, hx, hy, hz;
    auto read = _reader->readPreviewFrame(static_cast<std::uint32_t>(frameIndex), energy,
                                          ex, ey, ez, hx, hy, hz);
    if (!read) {
        Cu::logError() << "Could not read frame " << std::to_string(frameIndex) << ": " << read.error();
        return [NSData data];
    }

    NSData* result = [NSData dataWithBytes:energy.data() length:energy.size() * sizeof(float)];
    _cachedFrameIndex = frameIndex;
    _cachedEnergyData = result;
    return _cachedEnergyData;
}

- (void)prefetchFrame:(NSUInteger)frameIndex {
    // Preview frames are deliberately small and streamed synchronously when displayed. Do not
    // invoke the full-resolution prefetch path: that is reserved for a future zoomed tile request.
}

- (void)discardCachedFrameData {
    std::lock_guard lock(_mutex);
    _cachedFrameIndex = NSNotFound;
    _cachedEnergyData = nil;
    _reader->clearFrameCache();
}

- (copper::FieldFrameSeriesReader&)reader {
    return *_reader;
}

@end

/// Differential-mode view over two legs' own EMSFieldFrameDataSource: `coefficientP`/`coefficientN`
/// applied to each leg's raw Ex/Ey/Ez/Hx/Hy/Hz components (not to the legs' own precomputed
/// energies -- see buildCombinedFieldSnapshot()'s own doc comment) before deriving one energy value
/// per cell from the combined field, so the result reflects genuine differential-mode interference
/// rather than the sum of two independent single-ended energy maps.
@interface EMSCombinedFieldFrameDataSource : NSObject <EMSFieldFrameDataSourcing> {
@private
    EMSFieldFrameDataSource* _sourceP;
    EMSFieldFrameDataSource* _sourceN;
    double _coefficientP;
    double _coefficientN;
    std::mutex _mutex;
    NSUInteger _cachedFrameIndex;
    NSData* _cachedEnergyData;
}
- (instancetype)initWithSourceP:(EMSFieldFrameDataSource*)sourceP
                        sourceN:(EMSFieldFrameDataSource*)sourceN
                    coefficientP:(double)coefficientP
                    coefficientN:(double)coefficientN;
@end

@implementation EMSCombinedFieldFrameDataSource

- (instancetype)initWithSourceP:(EMSFieldFrameDataSource*)sourceP
                        sourceN:(EMSFieldFrameDataSource*)sourceN
                    coefficientP:(double)coefficientP
                    coefficientN:(double)coefficientN {
    self = [super init];
    if (self) {
        _sourceP = sourceP;
        _sourceN = sourceN;
        _coefficientP = coefficientP;
        _coefficientN = coefficientN;
        _cachedFrameIndex = NSNotFound;
    }
    return self;
}

- (NSData*)energyDataForFrame:(NSUInteger)frameIndex {
    std::lock_guard lock(_mutex);
    if (_cachedFrameIndex == frameIndex && _cachedEnergyData != nil) {
        return _cachedEnergyData;
    }
    std::vector<float> pEx, pEy, pEz, pHx, pHy, pHz;
    std::vector<float> nEx, nEy, nEz, nHx, nHy, nHz;
    std::vector<float> pEnergy;
    auto readP = _sourceP.reader.readPreviewFrame(static_cast<std::uint32_t>(frameIndex), pEnergy,
                                                  pEx, pEy, pEz, pHx, pHy, pHz);
    if (!readP) {
        Cu::logError() << "Could not read P-leg frame " << std::to_string(frameIndex) << ": " << readP.error();
        return [NSData data];
    }
    std::vector<float> nEnergy;
    auto readN = _sourceN.reader.readPreviewFrame(static_cast<std::uint32_t>(frameIndex), nEnergy,
                                                  nEx, nEy, nEz, nHx, nHy, nHz);
    if (!readN) {
        Cu::logError() << "Could not read N-leg frame " << std::to_string(frameIndex) << ": " << readN.error();
        return [NSData data];
    }
    if (pEx.size() != nEx.size()) {
        Cu::logError() << "Differential field combine: leg cell counts differ (" << pEx.size() << " vs "
                        << nEx.size() << ") at frame " << std::to_string(frameIndex);
        return [NSData data];
    }

    NSMutableData* result = [NSMutableData dataWithLength:pEx.size() * sizeof(float)];
    auto* energy = static_cast<float*>(result.mutableBytes);
    constexpr float kEps0 = 8.8541878128e-12F;
    constexpr float kMu0 = 1.25663706212e-6F;
    const auto cP = static_cast<float>(_coefficientP);
    const auto cN = static_cast<float>(_coefficientN);
    for (std::size_t i = 0; i < pEx.size(); ++i) {
        const float ex = cP * pEx[i] + cN * nEx[i];
        const float ey = cP * pEy[i] + cN * nEy[i];
        const float ez = cP * pEz[i] + cN * nEz[i];
        const float hx = cP * pHx[i] + cN * nHx[i];
        const float hy = cP * pHy[i] + cN * nHy[i];
        const float hz = cP * pHz[i] + cN * nHz[i];
        energy[i] = kEps0 * (ex * ex + ey * ey + ez * ez) + kMu0 * (hx * hx + hy * hy + hz * hz);
    }
    _cachedFrameIndex = frameIndex;
    _cachedEnergyData = result;
    return _cachedEnergyData;
}

- (void)prefetchFrame:(NSUInteger)frameIndex {
    [_sourceP prefetchFrame:frameIndex];
    [_sourceN prefetchFrame:frameIndex];
}

- (void)discardCachedFrameData {
    {
        std::lock_guard lock(_mutex);
        _cachedFrameIndex = NSNotFound;
        _cachedEnergyData = nil;
    }
    [_sourceP discardCachedFrameData];
    [_sourceN discardCachedFrameData];
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
    return [_dataSource energyDataForFrame:_frameIndex];
}

@end

@implementation EMSFieldFrame (Prefetch)

- (void)prefetch {
    [self.dataSource prefetchFrame:self.frameIndex];
}

@end

@implementation EMSFieldSnapshot

- (instancetype)initWithNx:(NSUInteger)nx
             simulationName:(NSString*)simulationName
                excitedPort:(NSInteger)excitedPort
             excitationName:(NSString*)excitationName
                         ny:(NSUInteger)ny
                         nz:(NSUInteger)nz
                      lineX:(NSArray<NSNumber*>*)lineX
                      lineY:(NSArray<NSNumber*>*)lineY
                      lineZ:(NSArray<NSNumber*>*)lineZ
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
                                       boardZMin:header.boardZMin * kMetersToSimUnits
                                       boardZMax:header.boardZMax * kMetersToSimUnits
                                          frames:frames
                                   minCellEnergy:minEnergy
                                   maxCellEnergy:maxEnergy];
}

EMSFieldSnapshot* buildCombinedFieldSnapshot(EMSFieldSnapshot* legP, EMSFieldSnapshot* legN, NSString* name,
                                             NSInteger excitedPort, double coefficientP, double coefficientN) {
    if (legP.frames.count == 0 || legN.frames.count == 0) {
        return nil;
    }
    if (legP.nx != legN.nx || legP.ny != legN.ny || legP.nz != legN.nz) {
        Cu::logError() << "Differential field combine '" << name.UTF8String << "': grid mismatch ("
                        << legP.nx << "x" << legP.ny << "x" << legP.nz << " vs " << legN.nx << "x" << legN.ny
                        << "x" << legN.nz << ")";
        return nil;
    }

    // previous is always built by buildFieldSnapshot() (see this function's own doc comment
    // and its caller in EMSSimulationPipelineBridge.mm), never by this function, so both legs'
    // own first-frame data sources are always the concrete single-reader kind here.
    EMSFieldFrameDataSource* sourceP = (EMSFieldFrameDataSource*)legP.frames.firstObject.dataSource;
    EMSFieldFrameDataSource* sourceN = (EMSFieldFrameDataSource*)legN.frames.firstObject.dataSource;
    EMSCombinedFieldFrameDataSource* combined =
        [[EMSCombinedFieldFrameDataSource alloc] initWithSourceP:sourceP
                                                          sourceN:sourceN
                                                     coefficientP:coefficientP
                                                     coefficientN:coefficientN];

    const NSUInteger frameCount = std::min(legP.frames.count, legN.frames.count);
    if (legP.frames.count != legN.frames.count) {
        Cu::logDebug() << "Differential field combine '" << name.UTF8String << "': leg frame counts differ ("
                        << legP.frames.count << " vs " << legN.frames.count << "), using first "
                        << frameCount;
    }

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
    const double maxAmplitude = std::abs(coefficientP) * std::sqrt(std::max(0.0F, legP.maxCellEnergy)) +
                                std::abs(coefficientN) * std::sqrt(std::max(0.0F, legN.maxCellEnergy));
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
                                       boardZMin:legP.boardZMin
                                       boardZMax:legP.boardZMax
                                          frames:frames
                                   minCellEnergy:minEnergy
                                   maxCellEnergy:maxEnergy];
}
