#import "KicadBoardBridge.h"
#import "EMSConfigBridge+Private.h"
#import "GeometryPreviewBridge+Private.h"

#include "kiems/importer.hpp"
#include "kiems/board_slicing.hpp"
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
                     annularRingDiameter:(double)annularRingDiameter {
    self = [super init];
    if (self) {
        _placedPositions = [placedPositions copy];
        _rejectedPositions = [rejectedPositions copy];
        _annularRingDiameter = annularRingDiameter;
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
        config = config.scaledToSimulationUnits();
        const kiems::SimulationConfig& simulation =
            config.simulations()[static_cast<std::size_t>(self.simulationIndex)];
        const PathsConfig paths = pathsForBoard(kicadPcbPath);
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
            copper->ground, existingVias, npthHoles);
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
        return [[KicadStitchingViaPlan alloc]
            initWithPlacedPositions:placed rejectedPositions:rejected
            annularRingDiameter:slicing.stitchingViaAnnularRingDiameter];
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
