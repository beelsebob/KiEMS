#import "FieldSnapshotBridge+Private.h"

#include <algorithm>
#include <cstdio>
#include <limits>
#include <mutex>
#include <optional>

#include "FieldFrameSeriesReader.hpp"
#include "gerber2ems/constants.hpp"
#include "CopperUtils/logging.hpp"

@interface EMSFieldFrameDataSource : NSObject {
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
    std::vector<float> ex, ey, ez, hx, hy, hz;
    auto read = _reader->readFrame(static_cast<std::uint32_t>(frameIndex), ex, ey, ez, hx, hy, hz);
    if (!read) {
        Cu::logError() << "Could not read frame " << std::to_string(frameIndex) << ": " << read.error();
        return [NSData data];
    }

    NSMutableData* result = [NSMutableData dataWithLength:ex.size() * sizeof(float)];
    auto* energy = static_cast<float*>(result.mutableBytes);
    constexpr float kEps0 = 8.8541878128e-12F;
    constexpr float kMu0 = 1.25663706212e-6F;
    for (std::size_t i = 0; i < ex.size(); ++i) {
        const float eSq = ex[i] * ex[i] + ey[i] * ey[i] + ez[i] * ez[i];
        const float hSq = hx[i] * hx[i] + hy[i] * hy[i] + hz[i] * hz[i];
        energy[i] = kEps0 * eSq + kMu0 * hSq;
    }
    _cachedFrameIndex = frameIndex;
    _cachedEnergyData = result;
    return _cachedEnergyData;
}

- (void)prefetchFrame:(NSUInteger)frameIndex {
    // Dispatched onto a global background queue rather than a queue owned by this object --
    // FieldFrameSeriesReader::prefetchFrame()/readFrame() serialize themselves internally (see
    // FieldFrameSeriesReader.hpp's own doc comment), so concurrent calls from this queue and from
    // whatever thread calls -energyDataForFrame: (normally the main thread, during playback) are
    // already safe without a dedicated serial queue here.
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        self->_reader->prefetchFrame(static_cast<std::uint32_t>(frameIndex));
    });
}

- (copper::FieldFrameSeriesReader&)reader {
    return *_reader;
}

@end

@interface EMSFieldFrame ()
@property (nonatomic, strong) EMSFieldFrameDataSource* dataSource;
@property (nonatomic) NSUInteger frameIndex;
- (instancetype)initWithTimestep:(NSUInteger)timestep
                      timeSeconds:(double)timeSeconds
                       frameIndex:(NSUInteger)frameIndex
                       dataSource:(EMSFieldFrameDataSource*)dataSource;
@end

@implementation EMSFieldFrame

- (instancetype)initWithTimestep:(NSUInteger)timestep
                      timeSeconds:(double)timeSeconds
                       frameIndex:(NSUInteger)frameIndex
                       dataSource:(EMSFieldFrameDataSource*)dataSource {
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

@end

namespace {

// Copper's own field snapshot is in metres (see CopperFieldSnapshot's own doc comment); everything
// else in this app is in simulation units (constants::baseUnit microns, constants::unitMultiplier
// per micron -- see EMSFieldSnapshot's own doc comment on why this bridge does that conversion
// once, here, rather than every caller needing to know it exists). Same derivation as
// GeometryPreviewBridge.mm's own mmToSimUnits().
constexpr double kMetersToSimUnits =
    static_cast<double>(gerber2ems::constants::unitMultiplier) / gerber2ems::constants::baseUnit;

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
    // crucially leaves the reader's decode/prefetch chunk caches untouched, so a frame already
    // decoded moments ago in the previous snapshot's data source is still warm in this one. The
    // caller (EMSSimulationPipelineBridge.fieldSnapshots) is responsible for only ever passing a
    // `previous` that was itself built from this exact `seriesPath` -- a rerun's ping-ponged path
    // means a stale `previous` naturally won't be offered here at all.
    EMSFieldFrameDataSource* dataSource = previous.frames.firstObject.dataSource;
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
    const copper::FieldFrameSeriesWriter::Header header = reader.header();
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
