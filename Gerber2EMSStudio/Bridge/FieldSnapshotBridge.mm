#import "FieldSnapshotBridge+Private.h"

#include <algorithm>
#include <limits>

#include "gerber2ems/constants.hpp"

@implementation EMSFieldFrame

- (instancetype)initWithTimestep:(NSUInteger)timestep
                      timeSeconds:(double)timeSeconds
                   cellEnergyData:(NSData*)cellEnergyData {
    self = [super init];
    if (self) {
        _timestep = timestep;
        _timeSeconds = timeSeconds;
        _cellEnergyData = [cellEnergyData copy];
    }
    return self;
}

@end

@implementation EMSFieldSnapshot

- (instancetype)initWithNx:(NSUInteger)nx
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

NSArray<NSNumber*>* convertLine(const std::vector<float>& metres) {
    NSMutableArray<NSNumber*>* out = [NSMutableArray arrayWithCapacity:metres.size()];
    for (const float v : metres) {
        [out addObject:@(static_cast<double>(v) * kMetersToSimUnits)];
    }
    return out;
}

} // namespace

EMSFieldSnapshot* buildFieldSnapshot(const copper::CopperFieldSnapshot& snapshot, double boardZMin, double boardZMax) {
    float minEnergy = std::numeric_limits<float>::infinity();
    float maxEnergy = -std::numeric_limits<float>::infinity();
    NSMutableArray<EMSFieldFrame*>* frames = [NSMutableArray arrayWithCapacity:snapshot.frames.size()];
    for (const copper::CopperFieldFrame& frame : snapshot.frames) {
        for (const float v : frame.cellEnergy) {
            minEnergy = std::min(minEnergy, v);
            maxEnergy = std::max(maxEnergy, v);
        }
        NSData* cellEnergyData = [NSData dataWithBytes:frame.cellEnergy.data()
                                                 length:frame.cellEnergy.size() * sizeof(float)];
        [frames addObject:[[EMSFieldFrame alloc] initWithTimestep:frame.timestep
                                                        timeSeconds:frame.timeSeconds
                                                     cellEnergyData:cellEnergyData]];
    }
    if (snapshot.frames.empty()) {
        minEnergy = 0.0F;
        maxEnergy = 0.0F;
    }

    return [[EMSFieldSnapshot alloc] initWithNx:snapshot.dims.nx
                                              ny:snapshot.dims.ny
                                              nz:snapshot.dims.nz
                                           lineX:convertLine(snapshot.lineX)
                                           lineY:convertLine(snapshot.lineY)
                                           lineZ:convertLine(snapshot.lineZ)
                                       boardZMin:boardZMin
                                       boardZMax:boardZMax
                                          frames:frames
                                   minCellEnergy:minEnergy
                                   maxCellEnergy:maxEnergy];
}
