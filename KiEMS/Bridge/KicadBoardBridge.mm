#import "KicadBoardBridge.h"
#import "EMSConfigBridge+Private.h"
#import "GeometryPreviewBridge+Private.h"

#include "kiems/importer.hpp"
#include "kiems/board_slicing.hpp"
#include "kiems/grid_gen.hpp"
#include "kiems/constants.hpp"
#include "kiems/net_name.hpp"
#include <unordered_set>
#include "libkicad/libkicad.hpp"
#include "kiems/paths_config.hpp"

using kiems::PathsConfig;

namespace {

NSError* makeError(const std::string& message) {
    return [NSError errorWithDomain:EMSConfigErrorDomain
                                code:1
                            userInfo:@{NSLocalizedDescriptionKey : @(message.c_str())}];
}

// Every field ki/importStackup actually reads is set explicitly here; every other
// PathsConfig field (configFile, fabDir, geometryDir, ...) is left default-constructed (empty) --
// none of them are touched by the functions this bridge calls. This is exactly the "populate a
// PathsConfig by hand" escape hatch paths_config.hpp's own doc comment describes: querying
// wherever the user's board actually lives, not a fab/-directory copy of it.
PathsConfig pathsForBoard(NSString* kicadPcbPath) {
    PathsConfig paths;
    paths.fabBoardFile = std::filesystem::path(kicadPcbPath.UTF8String);
    paths.fabProjectFile = paths.fabBoardFile;
    paths.fabProjectFile.replace_extension(".kicad_pro");
    return paths;
}

NSArray<NSString*>* toNSStringArray(const std::vector<std::string>& values) {
    NSMutableArray<NSString*>* result = [NSMutableArray arrayWithCapacity:values.size()];
    for (const auto& value : values) {
        [result addObject:@(value.c_str())];
    }
    return result;
}

} // namespace

@implementation KicadFootprintPin
- (instancetype)initWithNumber:(NSString*)number
                       function:(NSString*)function
                        netName:(NSString*)netName
                        pinType:(NSString*)pinType {
    self = [super init];
    if (self) {
        _number = [number copy];
        _function = [function copy];
        _netName = [netName copy];
        _pinType = [pinType copy];
    }
    return self;
}
@end

@implementation KicadFootprintInfo
- (instancetype)initWithReference:(NSString*)reference
                             value:(NSString*)value
                              pins:(NSArray<KicadFootprintPin*>*)pins {
    self = [super init];
    if (self) {
        _reference = [reference copy];
        _value = [value copy];
        _pins = [pins copy];
    }
    return self;
}
@end

@implementation KicadStitchingViaPlan
- (instancetype)initWithPlacedPositions:(NSArray<NSValue*>*)placedPositions
                       rejectedPositions:(NSArray<NSValue*>*)rejectedPositions
                     annularRingDiameter:(double)annularRingDiameter
                      hullCutTracePoints:(NSArray<KicadHullCutTracePoint*>*)hullCutTracePoints {
    self = [super init];
    if (self) {
        _placedPositions = [placedPositions copy];
        _rejectedPositions = [rejectedPositions copy];
        _annularRingDiameter = annularRingDiameter;
        _hullCutTracePoints = [hullCutTracePoints copy];
    }
    return self;
}
@end

@implementation KicadHullCutTracePoint
- (instancetype)initWithIdentifier:(NSString*)identifier netName:(NSString*)netName
                         layerName:(NSString*)layerName position:(NSPoint)position
                    inwardDirection:(double)inwardDirection traceWidth:(double)traceWidth {
    self = [super init];
    if (self) {
        _identifier = [identifier copy];
        _netName = [netName copy];
        _layerName = [layerName copy];
        _position = position;
        _inwardDirection = inwardDirection;
        _traceWidth = traceWidth;
    }
    return self;
}
@end

@interface KicadStitchingViaPlanRequest ()
@property (nonatomic, strong) NSValue* configurationPointer;
@property (nonatomic) NSInteger simulationIndex;
@end

@implementation KicadStitchingViaPlanRequest
- (void)dealloc {
    delete static_cast<kiems::EMSConfig*>(self.configurationPointer.pointerValue);
}

- (nullable KicadStitchingViaPlan*)computeForBoard:(NSString*)kicadPcbPath error:(NSError**)error {
    try {
        kiems::EMSConfig config = *static_cast<const kiems::EMSConfig*>(self.configurationPointer.pointerValue);
        if (self.simulationIndex < 0 ||
            static_cast<std::size_t>(self.simulationIndex) >= config.simulations().size()) {
            if (error != nil) *error = makeError("The selected simulation no longer exists");
            return nil;
        }
        const PathsConfig paths = pathsForBoard(kicadPcbPath);
        // Saved app documents intentionally do not persist the imported stackup. The real geometry
        // pipeline imports it before slicing, but this lightweight setup-screen planning path used
        // the document config directly. That left SlicingConfig::layerNames empty after reopening a
        // document, so otherwise correctly-classified copper was never examined on any layer and
        // the whole plan failed with "Involved nets have no copper on any layer".
        if (auto imported = kiems::importStackup(paths, config); !imported) {
            if (error != nil) *error = makeError(imported.error());
            return nil;
        }
        config = config.scaledToSimulationUnits();
        const kiems::SimulationConfig& simulation =
            config.simulations()[static_cast<std::size_t>(self.simulationIndex)];
        auto geometry = libkicad::boardGeometry(paths.kicadBoardPaths());
        if (!geometry) {
            if (error != nil) *error = makeError(geometry.error());
            return nil;
        }
        auto copper = kiems::classifyCopperForSimulation(simulation, *geometry, paths);
        if (!copper) {
            if (error != nil) *error = makeError(copper.error());
            return nil;
        }
        auto origin = kiems::boardBoundsInSimulationUnits(*geometry);
        if (!origin) {
            if (error != nil) *error = makeError(origin.error());
            return nil;
        }
        std::vector<kiems::ViaHole> existingVias;
        if (auto vias = kiems::getVias(paths, origin->xMin, origin->yMin); vias) {
            existingVias = std::move(*vias);
        }
        std::vector<kiems::NPTHHole> npthHoles;
        if (auto holes = kiems::getNPTHHoles(paths, origin->xMin, origin->yMin); holes) {
            npthHoles = std::move(*holes);
        }
        const kiems::SlicingConfig slicing = kiems::SlicingConfig::from(simulation, config);
        auto sliced = kiems::sliceBoardForSimulation(
            slicing, *geometry, copper->involved, copper->geometryOnly,
            copper->ground, copper->hullContributions, existingVias, npthHoles);
        if (!sliced) {
            if (error != nil) *error = makeError(sliced.error());
            return nil;
        }
        NSMutableArray<NSValue*>* placed = [NSMutableArray arrayWithCapacity:sliced->stitchingVias.size()];
        for (const kiems::StitchingVia& via : sliced->stitchingVias) {
            [placed addObject:[NSValue valueWithPoint:NSMakePoint(via.x, via.y)]];
        }
        NSMutableArray<NSValue*>* rejected =
            [NSMutableArray arrayWithCapacity:sliced->failedStitchingViaAttempts.size()];
        for (const kiems::Position& position : sliced->failedStitchingViaAttempts) {
            [rejected addObject:[NSValue valueWithPoint:NSMakePoint(position.x(), position.y())]];
        }
        std::unordered_set<kiems::NetName, kiems::NetNameHash> includedNets;
        for (const kiems::InvolvedNetConfig& entry : simulation.involvedNets()) {
            auto names = kiems::resolveInvolvedNetNames(paths, entry);
            if (!names) {
                if (error != nil) *error = makeError(names.error());
                return nil;
            }
            for (const std::string& name : *names) {
                includedNets.insert(kiems::NetName(name));
            }
        }
        auto groundNames = kiems::resolveGroundNetNames(paths, simulation.groundNet());
        if (!groundNames) {
            if (error != nil) *error = makeError(groundNames.error());
            return nil;
        }
        std::unordered_set<kiems::NetName, kiems::NetNameHash> groundNets;
        for (const std::string& name : *groundNames) {
            groundNets.insert(kiems::NetName(name));
        }
        auto tracks = libkicad::allTracks(paths.kicadBoardPaths());
        if (!tracks) {
            if (error != nil) *error = makeError(tracks.error());
            return nil;
        }
        std::vector<kiems::grid_detail::HullCutTrace> traceInputs;
        for (const auto& [netName, track] : *tracks) {
            const kiems::NetName normalizedNet(netName);
            if (!includedNets.contains(normalizedNet) || groundNets.contains(normalizedNet)) continue;
            auto point = [&](double xMm, double yMm) {
                return Cu::Position(xMm * 10000.0 - origin->xMin, yMm * 10000.0 - origin->yMin);
            };
            traceInputs.push_back({kiems::TraceSegment(point(track.startXMm, track.startYMm),
                                                       point(track.endXMm, track.endYMm), "",
                                                       track.widthMm * 10000.0),
                                   netName, track.copperLayerName});
        }
        const auto cutPoints = kiems::grid_detail::hullCutTracePoints(traceInputs, sliced->cutoutLoops, 10.0);
        NSMutableArray<KicadHullCutTracePoint*>* bridgedCutPoints =
            [NSMutableArray arrayWithCapacity:cutPoints.size()];
        for (const auto& point : cutPoints) {
            const long long roundedX = std::llround(point.position.x());
            const long long roundedY = std::llround(point.position.y());
            const std::string identifier = point.netName + "|" + point.layerName + "|" +
                std::to_string(roundedX) + "|" + std::to_string(roundedY);
            [bridgedCutPoints addObject:[[KicadHullCutTracePoint alloc]
                initWithIdentifier:@(identifier.c_str()) netName:@(point.netName.c_str())
                layerName:@(point.layerName.c_str())
                position:NSMakePoint(point.position.x(), point.position.y())
                inwardDirection:point.inwardDirectionDegrees traceWidth:point.width]];
        }
        return [[KicadStitchingViaPlan alloc]
            initWithPlacedPositions:placed rejectedPositions:rejected
            annularRingDiameter:slicing.stitchingViaAnnularRingDiameter
            hullCutTracePoints:bridgedCutPoints];
    } catch (const std::exception& exception) {
        if (error != nil) *error = makeError(exception.what());
        return nil;
    }
}
@end

@implementation KicadBoardBridge

+ (nullable KicadStitchingViaPlanRequest*)stitchingViaPlanRequestForConfig:(EMSConfigBridge*)config
                                                           simulationIndex:(NSInteger)simulationIndex {
    if (simulationIndex < 0 || static_cast<std::size_t>(simulationIndex) >= config.cxxConfig.simulations().size()) {
        return nil;
    }
    KicadStitchingViaPlanRequest* request = [[KicadStitchingViaPlanRequest alloc] init];
    request.configurationPointer = [NSValue valueWithPointer:new kiems::EMSConfig(config.cxxConfig)];
    request.simulationIndex = simulationIndex;
    return request;
}

+ (BOOL)prepareRuntime:(NSError**)error {
    auto result = libkicad::initialize();
    if (!result) {
        if (error != nil) *error = makeError(result.error());
        return NO;
    }
    return YES;
}

+ (nullable NSArray<NSString*>*)netClassesForBoard:(NSString*)kicadPcbPath
                                               error:(NSError**)error {
    const PathsConfig paths = pathsForBoard(kicadPcbPath);
    auto result = libkicad::netClasses(paths.kicadBoardPaths());
    if (!result) {
        if (error != nil) *error = makeError(result.error());
        return nil;
    }
    return toNSStringArray(*result);
}

+ (nullable NSArray<NSString*>*)allNetsForBoard:(NSString*)kicadPcbPath
                                           error:(NSError**)error {
    const PathsConfig paths = pathsForBoard(kicadPcbPath);
    auto result = libkicad::allNets(paths.kicadBoardPaths());
    if (!result) {
        if (error != nil) *error = makeError(result.error());
        return nil;
    }
    return toNSStringArray(*result);
}

+ (nullable NSString*)netClassForNet:(NSString*)netName
                               board:(NSString*)kicadPcbPath
                               error:(NSError**)error {
    const PathsConfig paths = pathsForBoard(kicadPcbPath);
    auto result = libkicad::netClassForNet(paths.kicadBoardPaths(), netName.UTF8String);
    if (!result) {
        if (error != nil) *error = makeError(result.error());
        return nil;
    }
    return @(result->c_str());
}

+ (nullable NSArray<NSString*>*)netsInNetClassForBoard:(NSString*)kicadPcbPath
                                                netClass:(NSString*)netClass
                                                   error:(NSError**)error {
    const PathsConfig paths = pathsForBoard(kicadPcbPath);
    auto result = libkicad::netsInNetClass(paths.kicadBoardPaths(), netClass.UTF8String);
    if (!result) {
        if (error != nil) *error = makeError(result.error());
        return nil;
    }
    return toNSStringArray(*result);
}

+ (nullable NSArray<KicadFootprintInfo*>*)footprintsForBoard:(NSString*)kicadPcbPath
                                                         error:(NSError**)error {
    const PathsConfig paths = pathsForBoard(kicadPcbPath);
    auto result = libkicad::footprints(paths.kicadBoardPaths());
    if (!result) {
        if (error != nil) *error = makeError(result.error());
        return nil;
    }
    NSMutableArray<KicadFootprintInfo*>* footprints = [NSMutableArray arrayWithCapacity:result->size()];
    for (const auto& footprint : *result) {
        NSMutableArray<KicadFootprintPin*>* pins = [NSMutableArray arrayWithCapacity:footprint.pins.size()];
        for (const auto& pin : footprint.pins) {
            [pins addObject:[[KicadFootprintPin alloc] initWithNumber:@(pin.number.c_str())
                                                               function:@(pin.function.c_str())
                                                                netName:@(pin.netName.c_str())
                                                                pinType:@(pin.pinType.c_str())]];
        }
        [footprints addObject:[[KicadFootprintInfo alloc] initWithReference:@(footprint.reference.c_str())
                                                                          value:@(footprint.value.c_str())
                                                                           pins:pins]];
    }
    return footprints;
}

+ (nullable EMSGeometryPreview*)wholeBoardPreviewForBoard:(NSString*)kicadPcbPath
                                                      error:(NSError**)error {
    const PathsConfig paths = pathsForBoard(kicadPcbPath);
    auto result = buildWholeBoardPreview(paths);
    if (!result) {
        if (error != nil) *error = makeError(result.error());
        return nil;
    }
    return *result;
}

+ (nullable EMSGeometryPreview*)layerCatalogPreviewForBoard:(NSString*)kicadPcbPath
                                                 wholeBoard:(BOOL)wholeBoard
                                                      error:(NSError**)error {
    auto result = buildBoardLayerCatalogPreview(pathsForBoard(kicadPcbPath), wholeBoard);
    if (!result) {
        if (error != nil) *error = makeError(result.error());
        return nil;
    }
    return *result;
}

+ (nullable EMSGeometryLayer*)layerPreviewForBoard:(NSString*)kicadPcbPath
                                               name:(NSString*)layerName
                                              error:(NSError**)error {
    auto result = buildBoardLayerPreview(pathsForBoard(kicadPcbPath), layerName.UTF8String);
    if (!result) {
        if (error != nil) *error = makeError(result.error());
        return nil;
    }
    return *result;
}

+ (BOOL)linkKicadPCB:(NSString*)kicadPcbPath
               config:(EMSConfigBridge*)config
                error:(NSError**)error {
    const PathsConfig paths = pathsForBoard(kicadPcbPath);
    if (auto result = kiems::importStackup(paths, config.cxxConfig); !result) {
        if (error != nil) *error = makeError(result.error());
        return NO;
    }
    config.kicadPcbPath = kicadPcbPath;
    return YES;
}

@end
