#import "KicadBoardBridge+Private.h"
#import "EMSConfigBridge+Private.h"
#import "GeometryPreviewBridge+Private.h"

#include "kiems/component_sim_model.hpp"
#include "kiems/importer.hpp"
#include "kiems/board_slicing.hpp"
#include "kiems/grid_gen.hpp"
#include "kiems/constants.hpp"
#include "kiems/net_name.hpp"
#include <unordered_set>
#include "libkicad/libkicad.hpp"
#include <filesystem>
#include <optional>

namespace {

NSError* makeError(const std::string& message) {
    return [NSError errorWithDomain:EMSConfigErrorDomain
                                code:1
                            userInfo:@{NSLocalizedDescriptionKey : @(message.c_str())}];
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

@implementation KicadComponentSimModel
- (instancetype)initWithReference:(NSString*)reference supported:(BOOL)supported reason:(NSString*)reason {
    self = [super init];
    if (self) {
        _reference = [reference copy];
        _supported = supported;
        _reason = [reason copy];
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
@property (nonatomic, copy, readwrite) NSString* inputsKey;
@end

namespace {

// Only the fields planning actually reads (see computeWithBoard:error:) -- deliberately not the whole
// SimulationConfig/InvolvedNetConfig JSON, which also carries port, probe, absorbing and excitation
// settings that never move the cut or its stitching vias.
std::string stitchingViaPlanInputsKey(const kiems::EMSConfig& config, const kiems::SimulationConfig& simulation) {
    nlohmann::json nets = nlohmann::json::array();
    for (const kiems::InvolvedNetConfig& entry : simulation.involvedNets()) {
        nlohmann::json selector;
        switch (entry.kind()) {
            case kiems::NetSelectorKind::Net: selector["net"] = *entry.net(); break;
            case kiems::NetSelectorKind::NetClass: selector["net_class"] = *entry.netClass(); break;
            case kiems::NetSelectorKind::FootprintPin:
                selector["footprint"] = *entry.footprint();
                selector["pins"] = entry.pins();
                break;
        }
        selector["geometry_only"] = entry.inclusionLevel() == kiems::NetInclusionLevel::GeometryOnly;
        selector["hull_padding"] = entry.hullPadding();
        nets.push_back(std::move(selector));
    }
    // Only components that grow the hull can move the cut; including one otherwise doesn't.
    nlohmann::json components = nlohmann::json::array();
    for (const kiems::IncludedComponentConfig& component : simulation.includedComponents()) {
        if (component.contributesToHull) components.push_back(component);
    }
    const nlohmann::json key{{"involved_nets", nets},
                             {"hull_components", components},
                             {"ground_net", simulation.groundNet()},
                             {"via_edge_distance", simulation.viaEdgeDistance()},
                             {"via_spacing", simulation.viaSpacing()},
                             {"via", config.via()},
                             {"pixel_size", config.pixelSize()}};
    return key.dump();
}

} // namespace

@implementation KicadStitchingViaPlanRequest
- (void)dealloc {
    delete static_cast<kiems::EMSConfig*>(self.configurationPointer.pointerValue);
}

- (nullable KicadStitchingViaPlan*)computeWithBoard:(KicadBoardBridge*)boardBridge error:(NSError**)error {
    try {
        kiems::EMSConfig config = *static_cast<const kiems::EMSConfig*>(self.configurationPointer.pointerValue);
        if (self.simulationIndex < 0 ||
            static_cast<std::size_t>(self.simulationIndex) >= config.simulations().size()) {
            if (error != nil) *error = makeError("The selected simulation no longer exists");
            return nil;
        }
        const libkicad::Board& board = boardBridge.cxxBoard;
        // Saved app documents intentionally do not persist the imported stackup. The real geometry
        // pipeline imports it before slicing, but this lightweight setup-screen planning path used
        // the document config directly. That left SlicingConfig::layerNames empty after reopening a
        // document, so otherwise correctly-classified copper was never examined on any layer and
        // the whole plan failed with "Involved nets have no copper on any layer".
        if (auto imported = kiems::importStackup(board, config); !imported) {
            if (error != nil) *error = makeError(imported.error());
            return nil;
        }
        config = config.scaledToSimulationUnits();
        const kiems::SimulationConfig& simulation =
            config.simulations()[static_cast<std::size_t>(self.simulationIndex)];
        auto geometry = board.boardGeometry();
        if (!geometry) {
            if (error != nil) *error = makeError(geometry.error());
            return nil;
        }
        auto copper = kiems::classifyCopperForSimulation(simulation, *geometry, board);
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
        if (auto vias = kiems::getVias(board, origin->xMin, origin->yMin); vias) {
            existingVias = std::move(*vias);
        }
        const kiems::SlicingConfig slicing = kiems::SlicingConfig::from(simulation, config);
        // Only the cut and the stitching-via placement are shown here -- the full slice's per-layer
        // Booleans, solder mask preparation and triangulation are geometry-stage-only work.
        auto sliced = kiems::planSlicedBoardForSimulation(
            slicing, *geometry, copper->involved, copper->ground, copper->hullContributions, existingVias);
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
            auto names = kiems::resolveInvolvedNetNames(board, entry);
            if (!names) {
                if (error != nil) *error = makeError(names.error());
                return nil;
            }
            for (const std::string& name : *names) {
                includedNets.insert(kiems::NetName(name));
            }
        }
        auto groundNames = kiems::resolveGroundNetNames(board, simulation.groundNet());
        if (!groundNames) {
            if (error != nil) *error = makeError(groundNames.error());
            return nil;
        }
        std::unordered_set<kiems::NetName, kiems::NetNameHash> groundNets;
        for (const std::string& name : *groundNames) {
            groundNets.insert(kiems::NetName(name));
        }
        auto tracks = board.allTracks();
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

@implementation KicadRuntime {
    std::optional<libkicad::Runtime> _runtime;
}

+ (nullable KicadRuntime*)startWithError:(NSError**)error {
    auto runtime = libkicad::Runtime::create();
    if (!runtime) {
        if (error != nil) *error = makeError(runtime.error());
        return nil;
    }
    return [[KicadRuntime alloc] initWithRuntime:std::move(*runtime)];
}

- (instancetype)initWithRuntime:(libkicad::Runtime&&)runtime {
    self = [super init];
    if (self) {
        _runtime.emplace(std::move(runtime));
    }
    return self;
}

- (libkicad::Runtime&)cxxRuntime {
    return *_runtime;
}

@end

@implementation KicadBoardBridge {
    // Declared before _board: ivars are destroyed in reverse order, so the board is torn down while
    // its runtime is still alive.
    KicadRuntime* _runtime;
    std::optional<libkicad::Board> _board;
}

- (instancetype)initWithRuntime:(KicadRuntime*)runtime kicadPcbPath:(NSString*)kicadPcbPath {
    self = [super init];
    if (self) {
        _runtime = runtime;
        _kicadPcbPath = [kicadPcbPath copy];
        std::filesystem::path projectPath(kicadPcbPath.UTF8String);
        projectPath.replace_extension(".kicad_pro");
        _board.emplace(runtime.cxxRuntime, projectPath.string(), kicadPcbPath.UTF8String);
    }
    return self;
}

- (const libkicad::Board&)cxxBoard {
    return *_board;
}

+ (nullable KicadStitchingViaPlanRequest*)stitchingViaPlanRequestForConfig:(EMSConfigBridge*)config
                                                           simulationIndex:(NSInteger)simulationIndex {
    if (simulationIndex < 0 || static_cast<std::size_t>(simulationIndex) >= config.cxxConfig.simulations().size()) {
        return nil;
    }
    KicadStitchingViaPlanRequest* request = [[KicadStitchingViaPlanRequest alloc] init];
    request.configurationPointer = [NSValue valueWithPointer:new kiems::EMSConfig(config.cxxConfig)];
    request.simulationIndex = simulationIndex;
    const kiems::EMSConfig& cxxConfig = config.cxxConfig;
    request.inputsKey = @(stitchingViaPlanInputsKey(
        cxxConfig, cxxConfig.simulations()[static_cast<std::size_t>(simulationIndex)]).c_str());
    return request;
}

- (nullable NSArray<NSString*>*)netClassesWithError:(NSError**)error {
    auto result = _board->netClasses();
    if (!result) {
        if (error != nil) *error = makeError(result.error());
        return nil;
    }
    return toNSStringArray(*result);
}

- (nullable NSArray<NSString*>*)allNetsWithError:(NSError**)error {
    auto result = _board->allNets();
    if (!result) {
        if (error != nil) *error = makeError(result.error());
        return nil;
    }
    return toNSStringArray(*result);
}

- (nullable NSString*)netClassForNet:(NSString*)netName error:(NSError**)error {
    auto result = _board->netClassForNet(netName.UTF8String);
    if (!result) {
        if (error != nil) *error = makeError(result.error());
        return nil;
    }
    return @(result->c_str());
}

- (nullable NSArray<NSString*>*)netsInNetClass:(NSString*)netClass error:(NSError**)error {
    auto result = _board->netsInNetClass(netClass.UTF8String);
    if (!result) {
        if (error != nil) *error = makeError(result.error());
        return nil;
    }
    return toNSStringArray(*result);
}

- (nullable NSArray<KicadFootprintInfo*>*)footprintsWithError:(NSError**)error {
    auto result = _board->footprints();
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

- (nullable NSArray<KicadComponentSimModel*>*)componentSimModelsWithError:(NSError**)error {
    auto result = _board->componentSimModels();
    if (!result) {
        if (error != nil) *error = makeError(result.error());
        return nil;
    }
    NSMutableArray<KicadComponentSimModel*>* models = [NSMutableArray arrayWithCapacity:result->size()];
    for (const auto& model : *result) {
        const kiems::ComponentSimModelSupport support = kiems::assessComponentSimModel(model);
        [models addObject:[[KicadComponentSimModel alloc] initWithReference:@(model.reference.c_str())
                                                                    supported:support.supported
                                                                       reason:@(support.reason.c_str())]];
    }
    return models;
}

- (nullable EMSGeometryPreview*)wholeBoardPreviewWithError:(NSError**)error {
    auto result = buildWholeBoardPreview(*_board);
    if (!result) {
        if (error != nil) *error = makeError(result.error());
        return nil;
    }
    return *result;
}

- (nullable EMSGeometryPreview*)layerCatalogPreviewForWholeBoard:(BOOL)wholeBoard error:(NSError**)error {
    auto result = buildBoardLayerCatalogPreview(*_board, wholeBoard);
    if (!result) {
        if (error != nil) *error = makeError(result.error());
        return nil;
    }
    return *result;
}

- (nullable EMSGeometryLayer*)layerPreviewNamed:(NSString*)layerName error:(NSError**)error {
    auto result = buildBoardLayerPreview(*_board, layerName.UTF8String);
    if (!result) {
        if (error != nil) *error = makeError(result.error());
        return nil;
    }
    return *result;
}

- (BOOL)linkToConfig:(EMSConfigBridge*)config error:(NSError**)error {
    if (auto result = kiems::importStackup(*_board, config.cxxConfig); !result) {
        if (error != nil) *error = makeError(result.error());
        return NO;
    }
    config.kicadPcbPath = _kicadPcbPath;
    return YES;
}

@end
