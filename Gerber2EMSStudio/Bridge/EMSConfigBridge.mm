#import "EMSConfigBridge.h"
#import "EMSConfigBridge+Private.h"

#include <algorithm>

using gerber2ems::EMSConfig;
using gerber2ems::ExcitationConfig;
using gerber2ems::GroundSelectorKind;
using gerber2ems::InvolvedNetConfig;
using gerber2ems::NetSelectorKind;
using gerber2ems::ProbedPin;
using gerber2ems::SimulationConfig;

NSErrorDomain const EMSConfigErrorDomain = @"EMSConfigErrorDomain";

// Forward declarations so EMSSimulationBridge and EMSInvolvedNetBridge's implementations (below)
// can reference each other's ivars/private methods regardless of which is defined first.
@interface EMSSimulationBridge () {
@public
    __weak EMSConfigBridge* _parent;
    NSInteger _index;
}
- (SimulationConfig&)cxxSim;
@end

@interface EMSInvolvedNetBridge () {
@public
    // Strong, not weak: unlike EMSSimulationBridge's own _parent (EMSConfigBridge, which is
    // document-lifetime-stable -- see Document.swift's stored `config` property), the
    // EMSSimulationBridge this points to is itself a fresh, uncached object returned by
    // EMSConfigBridge.simulations/EMSSimulationBridge.involvedNets on every access (see their own
    // implementations below) -- nothing else keeps it alive. A weak reference here let the parent
    // deallocate out from under a still-live EMSInvolvedNetBridge/EMSExcitationBridge (most visibly
    // when a caller only keeps the leaf wrapper past the statement that produced its parent, e.g.
    // `selectedSimulation!.excitations[$0]` in SourceListViewController.swift), producing a
    // message-to-nil on a method returning a C++ reference (cxxSim) -- undefined behaviour, not the
    // "safely zero" convention ordinary ObjC message-to-nil gets, and a real crash reproduced via
    // SourceListViewController's outline-row expand path. No retain-cycle risk in making this
    // strong: a parent never stores a reference back to its children.
    EMSSimulationBridge* _parentSim;
    NSInteger _index;
}
- (InvolvedNetConfig&)cxxNet;
@end

@interface EMSExcitationBridge () {
@public
    // Strong, not weak -- see EMSInvolvedNetBridge's own _parentSim comment above; identical
    // reasoning and identical crash.
    EMSSimulationBridge* _parentSim;
    NSInteger _index;
}
- (ExcitationConfig&)cxxExcitation;
@end

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

std::vector<std::string> toStdStringVector(NSArray<NSString*>* values) {
    std::vector<std::string> result;
    result.reserve(values.count);
    for (NSString* value in values) {
        result.emplace_back(value.UTF8String);
    }
    return result;
}

} // namespace

@implementation EMSProbedPinBridge {
    std::string _footprintStorage;
    std::string _pinStorage;
}

- (instancetype)initWithProbedPin:(const ProbedPin&)probedPin {
    if ((self = [super init])) {
        _footprintStorage = probedPin.footprint;
        _pinStorage = probedPin.pin;
        _absorbSignal = probedPin.absorbSignal ? YES : NO;
    }
    return self;
}

- (NSString*)footprintReference {
    return @(_footprintStorage.c_str());
}

- (NSString*)pin {
    return @(_pinStorage.c_str());
}

@end

// Not cached (unlike EMSSimulationBridge's own wrappers): involved nets are removable, and a
// removal shifts every later index -- a cache would need to be re-indexed on every removal for no
// real benefit, since callers (the Phase 7 source list) already re-fetch involvedNets() fresh on
// every reload rather than holding these across mutations.
@implementation EMSInvolvedNetBridge

- (InvolvedNetConfig&)cxxNet {
    return _parentSim.cxxSim.involvedNets().at(static_cast<std::size_t>(_index));
}

- (EMSNetSelectorKind)kind {
    switch (self.cxxNet.kind()) {
        case NetSelectorKind::NetClass: return EMSNetSelectorKindNetClass;
        case NetSelectorKind::Net: return EMSNetSelectorKindNet;
        case NetSelectorKind::FootprintPin: return EMSNetSelectorKindFootprintPin;
    }
    return EMSNetSelectorKindNet;
}
- (void)setKind:(EMSNetSelectorKind)kind {
    switch (kind) {
        case EMSNetSelectorKindNetClass: self.cxxNet.setKind(NetSelectorKind::NetClass); break;
        case EMSNetSelectorKindNet: self.cxxNet.setKind(NetSelectorKind::Net); break;
        case EMSNetSelectorKindFootprintPin: self.cxxNet.setKind(NetSelectorKind::FootprintPin); break;
    }
}

- (nullable NSString*)netClass {
    const auto& value = self.cxxNet.netClass();
    return value.has_value() ? @(value->c_str()) : nil;
}
- (void)setNetClass:(nullable NSString*)value {
    self.cxxNet.setNetClass(value != nil ? std::optional<std::string>(value.UTF8String) : std::nullopt);
}

- (nullable NSString*)net {
    const auto& value = self.cxxNet.net();
    return value.has_value() ? @(value->c_str()) : nil;
}
- (void)setNet:(nullable NSString*)value {
    self.cxxNet.setNet(value != nil ? std::optional<std::string>(value.UTF8String) : std::nullopt);
}

- (nullable NSString*)footprintReference {
    const auto& value = self.cxxNet.footprint();
    return value.has_value() ? @(value->c_str()) : nil;
}
- (void)setFootprintReference:(nullable NSString*)value {
    self.cxxNet.setFootprint(value != nil ? std::optional<std::string>(value.UTF8String) : std::nullopt);
}

- (NSArray<NSString*>*)pins {
    return toNSStringArray(self.cxxNet.pins());
}
- (void)setPins:(NSArray<NSString*>*)pins {
    self.cxxNet.pins() = toStdStringVector(pins);
}

- (double)impedance {
    return self.cxxNet.impedance();
}
- (void)setImpedance:(double)value {
    self.cxxNet.setImpedance(value);
}

- (double)length {
    return self.cxxNet.length();
}
- (void)setLength:(double)value {
    self.cxxNet.setLength(value);
}

- (NSInteger)plane {
    return self.cxxNet.plane();
}
- (void)setPlane:(NSInteger)value {
    self.cxxNet.setPlane(static_cast<std::int32_t>(value));
}

- (nullable NSNumber*)width {
    const auto& value = self.cxxNet.width();
    return value.has_value() ? @(*value) : nil;
}
- (void)setWidth:(nullable NSNumber*)value {
    self.cxxNet.setWidth(value != nil ? std::optional<double>(value.doubleValue) : std::nullopt);
}

- (nullable NSNumber*)dBMargin {
    const auto& value = self.cxxNet.dBMargin();
    return value.has_value() ? @(*value) : nil;
}
- (void)setDBMargin:(nullable NSNumber*)value {
    self.cxxNet.setDBMargin(value != nil ? std::optional<double>(value.doubleValue) : std::nullopt);
}

- (nullable NSNumber*)direction {
    const auto& value = self.cxxNet.direction();
    return value.has_value() ? @(*value) : nil;
}
- (void)setDirection:(nullable NSNumber*)value {
    self.cxxNet.setDirection(value != nil ? std::optional<double>(value.doubleValue) : std::nullopt);
}

- (BOOL)isPinExcludedWithFootprint:(NSString*)footprint pin:(NSString*)pin {
    return self.cxxNet.isPinExcluded(footprint.UTF8String, pin.UTF8String) ? YES : NO;
}
- (void)excludePinWithFootprint:(NSString*)footprint pin:(NSString*)pin {
    if (self.cxxNet.isPinExcluded(footprint.UTF8String, pin.UTF8String)) {
        return;
    }
    self.cxxNet.excludedPins().push_back(gerber2ems::ExcludedPin{footprint.UTF8String, pin.UTF8String});
}
- (void)includePinWithFootprint:(NSString*)footprint pin:(NSString*)pin {
    auto& excluded = self.cxxNet.excludedPins();
    excluded.erase(std::remove(excluded.begin(), excluded.end(),
                                 gerber2ems::ExcludedPin{footprint.UTF8String, pin.UTF8String}),
                    excluded.end());
}

- (BOOL)hasExplicitPinSelections {
    return self.cxxNet.hasExplicitPinSelections() ? YES : NO;
}
- (BOOL)isPinProbedWithFootprint:(NSString*)footprint pin:(NSString*)pin {
    return self.cxxNet.probedPinAbsorbs(footprint.UTF8String, pin.UTF8String).has_value() ? YES : NO;
}
- (BOOL)pinAbsorbsSignalWithFootprint:(NSString*)footprint pin:(NSString*)pin {
    const auto value = self.cxxNet.probedPinAbsorbs(footprint.UTF8String, pin.UTF8String);
    return value.value_or(true) ? YES : NO;
}
- (void)setPinProbed:(BOOL)probed
       absorbSignal:(BOOL)absorbSignal
      withFootprint:(NSString*)footprint
                pin:(NSString*)pin {
    self.cxxNet.setPinProbed(footprint.UTF8String, pin.UTF8String,
                              probed ? std::optional<bool>(absorbSignal ? true : false) : std::nullopt);
}
- (NSArray<EMSProbedPinBridge*>*)probedPins {
    const auto& probed = self.cxxNet.probedPins();
    NSMutableArray<EMSProbedPinBridge*>* result = [NSMutableArray arrayWithCapacity:probed.size()];
    for (const auto& p : probed) {
        [result addObject:[[EMSProbedPinBridge alloc] initWithProbedPin:p]];
    }
    return result;
}

- (nullable NSNumber*)directionOverrideWithFootprint:(NSString*)footprint pin:(NSString*)pin {
    const auto value = self.cxxNet.pinDirectionOverride(footprint.UTF8String, pin.UTF8String);
    return value.has_value() ? @(*value) : nil;
}
- (void)setDirectionOverride:(nullable NSNumber*)direction withFootprint:(NSString*)footprint pin:(NSString*)pin {
    self.cxxNet.setPinDirectionOverride(footprint.UTF8String, pin.UTF8String,
                                         direction != nil ? std::optional<double>(direction.doubleValue) : std::nullopt);
}

@end

// Not cached, for the same reason as EMSInvolvedNetBridge.
@implementation EMSExcitationBridge

- (ExcitationConfig&)cxxExcitation {
    return _parentSim.cxxSim.excitations().at(static_cast<std::size_t>(_index));
}

- (NSString*)footprintReference {
    return @(self.cxxExcitation.footprint().c_str());
}
- (void)setFootprintReference:(NSString*)value {
    self.cxxExcitation.setFootprint(value.UTF8String);
}

- (NSString*)pin {
    return @(self.cxxExcitation.pin().c_str());
}
- (void)setPin:(NSString*)value {
    self.cxxExcitation.setPin(value.UTF8String);
}

- (BOOL)isMain {
    return self.cxxExcitation.isMain();
}
- (void)setIsMain:(BOOL)value {
    self.cxxExcitation.setIsMain(value);
}

- (double)startTime {
    return self.cxxExcitation.startTime();
}
- (void)setStartTime:(double)value {
    self.cxxExcitation.setStartTime(value);
}

- (double)duration {
    return self.cxxExcitation.duration();
}
- (void)setDuration:(double)value {
    self.cxxExcitation.setDuration(value);
}

- (double)phaseDegrees {
    return self.cxxExcitation.phaseDegrees();
}
- (void)setPhaseDegrees:(double)value {
    self.cxxExcitation.setPhaseDegrees(value);
}

- (nullable NSNumber*)frequency {
    const auto& value = self.cxxExcitation.frequency();
    return value.has_value() ? @(*value) : nil;
}
- (void)setFrequency:(nullable NSNumber*)value {
    self.cxxExcitation.setFrequency(value != nil ? std::optional<double>(value.doubleValue) : std::nullopt);
}

- (nullable NSNumber*)amplitude {
    const auto& value = self.cxxExcitation.amplitude();
    return value.has_value() ? @(*value) : nil;
}
- (void)setAmplitude:(nullable NSNumber*)value {
    self.cxxExcitation.setAmplitude(value != nil ? std::optional<double>(value.doubleValue) : std::nullopt);
}

@end

@implementation EMSSimulationBridge

- (SimulationConfig&)cxxSim {
    return _parent.cxxConfig.simulations().at(static_cast<std::size_t>(_index));
}

- (NSString*)name {
    return @(self.cxxSim.name().c_str());
}
- (void)setName:(NSString*)name {
    self.cxxSim.setName(name.UTF8String);
}

- (EMSGroundSelectorKind)groundNetKind {
    return self.cxxSim.groundNet().kind() == GroundSelectorKind::NetClass ? EMSGroundSelectorKindNetClass
                                                                            : EMSGroundSelectorKindNet;
}
- (void)setGroundNetKind:(EMSGroundSelectorKind)kind {
    self.cxxSim.groundNet().setKind(kind == EMSGroundSelectorKindNetClass ? GroundSelectorKind::NetClass
                                                                            : GroundSelectorKind::Net);
}

- (nullable NSString*)groundNetName {
    auto& ground = self.cxxSim.groundNet();
    const auto& name = ground.kind() == GroundSelectorKind::NetClass ? ground.netClass() : ground.net();
    return name.has_value() ? @(name->c_str()) : nil;
}
- (void)setGroundNetName:(nullable NSString*)name {
    auto& ground = self.cxxSim.groundNet();
    // Dereferenced unconditionally by to_json() for the active kind -- never leave it nullopt, an
    // empty string is a safe "not picked yet" placeholder (see EMSConfigBridge.mm's
    // addSimulationNamed: for why this matters).
    const std::string value = name != nil ? std::string(name.UTF8String) : std::string();
    if (ground.kind() == GroundSelectorKind::NetClass) {
        ground.setNetClass(value);
    } else {
        ground.setNet(value);
    }
}

- (double)hullPadding {
    return self.cxxSim.hullPadding();
}
- (void)setHullPadding:(double)value {
    self.cxxSim.setHullPadding(value);
}

- (double)viaEdgeDistance {
    return self.cxxSim.viaEdgeDistance();
}
- (void)setViaEdgeDistance:(double)value {
    self.cxxSim.setViaEdgeDistance(value);
}

- (double)viaSpacing {
    return self.cxxSim.viaSpacing();
}
- (void)setViaSpacing:(double)value {
    self.cxxSim.setViaSpacing(value);
}

- (EMSInvolvedNetBridge*)_wrapperForInvolvedNetIndex:(NSInteger)index {
    EMSInvolvedNetBridge* wrapper = [[EMSInvolvedNetBridge alloc] init];
    wrapper->_parentSim = self;
    wrapper->_index = index;
    return wrapper;
}

- (NSArray<EMSInvolvedNetBridge*>*)involvedNets {
    NSMutableArray<EMSInvolvedNetBridge*>* result =
            [NSMutableArray arrayWithCapacity:self.cxxSim.involvedNets().size()];
    for (std::size_t i = 0; i < self.cxxSim.involvedNets().size(); ++i) {
        [result addObject:[self _wrapperForInvolvedNetIndex:static_cast<NSInteger>(i)]];
    }
    return result;
}

- (EMSInvolvedNetBridge*)addInvolvedNetWithKind:(EMSNetSelectorKind)kind {
    InvolvedNetConfig net;
    switch (kind) {
        case EMSNetSelectorKindNetClass:
            net.setKind(NetSelectorKind::NetClass);
            net.setNetClass(std::string());
            break;
        case EMSNetSelectorKindNet:
            net.setKind(NetSelectorKind::Net);
            net.setNet(std::string());
            break;
        case EMSNetSelectorKindFootprintPin:
            net.setKind(NetSelectorKind::FootprintPin);
            net.setFootprint(std::string());
            break;
    }
    self.cxxSim.involvedNets().push_back(std::move(net));
    return [self _wrapperForInvolvedNetIndex:static_cast<NSInteger>(self.cxxSim.involvedNets().size() - 1)];
}

- (void)removeInvolvedNetAtIndex:(NSInteger)index {
    auto& nets = self.cxxSim.involvedNets();
    if (index < 0 || static_cast<std::size_t>(index) >= nets.size()) {
        return;
    }
    nets.erase(nets.begin() + index);
}

- (EMSExcitationBridge*)_wrapperForExcitationIndex:(NSInteger)index {
    EMSExcitationBridge* wrapper = [[EMSExcitationBridge alloc] init];
    wrapper->_parentSim = self;
    wrapper->_index = index;
    return wrapper;
}

- (NSArray<EMSExcitationBridge*>*)excitations {
    NSMutableArray<EMSExcitationBridge*>* result =
            [NSMutableArray arrayWithCapacity:self.cxxSim.excitations().size()];
    for (std::size_t i = 0; i < self.cxxSim.excitations().size(); ++i) {
        [result addObject:[self _wrapperForExcitationIndex:static_cast<NSInteger>(i)]];
    }
    return result;
}

- (EMSExcitationBridge*)addExcitationForFootprint:(NSString*)footprint pin:(NSString*)pin {
    ExcitationConfig excitation;
    excitation.setFootprint(footprint.UTF8String);
    excitation.setPin(pin.UTF8String);
    // Defaults to a non-main excitation with frequency/amplitude set: from_json() rejects a
    // non-main excitation missing either, so a freshly-added one needs both present to survive a
    // save+reparse round trip (matching addSimulationNamed:'s identical involved_nets concern).
    excitation.setIsMain(false);
    excitation.setFrequency(0.0);
    excitation.setAmplitude(1.0);
    // Long enough for 5 full cycles at the sweep's lowest frequency (period = 1/f) -- the slowest
    // waveform component the excitation needs to represent, so 5 periods is a reasonable amount of
    // settling/ramp-up time regardless of which frequency within the sweep dominates. min(), not
    // start(), since nothing here guarantees start <= stop.
    const double lowestFrequency = std::min(_parent.frequencyStart, _parent.frequencyStop);
    excitation.setDuration(lowestFrequency > 0 ? 5.0 / lowestFrequency : 0.0);
    self.cxxSim.excitations().push_back(std::move(excitation));
    return [self _wrapperForExcitationIndex:static_cast<NSInteger>(self.cxxSim.excitations().size() - 1)];
}

- (void)removeExcitationAtIndex:(NSInteger)index {
    auto& excitations = self.cxxSim.excitations();
    if (index < 0 || static_cast<std::size_t>(index) >= excitations.size()) {
        return;
    }
    excitations.erase(excitations.begin() + index);
}

@end

// EMSSimulationBridge wrappers are not cached here (unlike an earlier version of this file) --
// same reasoning as EMSInvolvedNetBridge/EMSExcitationBridge: a cache indexed by position would
// need re-indexing on every removeSimulationAtIndex:, for no real benefit, since every Swift call
// site already re-fetches `simulations` fresh rather than holding a wrapper across mutations.
@implementation EMSConfigBridge {
    EMSConfig _config;
}

- (EMSConfig&)cxxConfig {
    return _config;
}

+ (instancetype)configWithDefaults {
    return [[EMSConfigBridge alloc] init];
}

+ (nullable instancetype)configWithContentsOfFile:(NSString*)path error:(NSError**)error {
    auto result = EMSConfig::parse(std::filesystem::path(path.UTF8String), false);
    if (!result) {
        if (error != nil) {
            *error = makeError(result.error());
        }
        return nil;
    }
    EMSConfigBridge* bridge = [[EMSConfigBridge alloc] init];
    bridge->_config = std::move(*result);
    return bridge;
}

- (BOOL)saveToFile:(NSString*)path error:(NSError**)error {
    auto result = _config.save(std::filesystem::path(path.UTF8String));
    if (!result) {
        if (error != nil) {
            *error = makeError(result.error());
        }
        return NO;
    }
    return YES;
}

- (nullable NSString*)kicadPcbPath {
    const auto& value = _config.kicadPcbPath();
    return value.has_value() ? @(value->c_str()) : nil;
}
- (void)setKicadPcbPath:(nullable NSString*)value {
    _config.setKicadPcbPath(value != nil ? std::optional<std::filesystem::path>(value.UTF8String) : std::nullopt);
}

- (double)viaPlatingThickness {
    return _config.via().platingThickness();
}
- (void)setViaPlatingThickness:(double)value {
    _config.via().setPlatingThickness(value);
}

- (NSArray<NSString*>*)metalLayerNames {
    NSMutableArray<NSString*>* names = [NSMutableArray array];
    for (const gerber2ems::LayerConfig& layer : _config.layers()) {
        if (layer.kind() == gerber2ems::LayerKind::Metal) {
            [names addObject:@(layer.name().c_str())];
        }
    }
    return names;
}

- (double)viaFillingEpsilon {
    return _config.via().fillingEpsilon();
}
- (void)setViaFillingEpsilon:(double)value {
    _config.via().setFillingEpsilon(value);
}

// gerber2ems::Frequency has no in-place setters on EMSConfig::frequency()'s own reference (it
// returns by value on the const accessor, and there's no mutable frequency() overload) -- so each
// setter here round-trips through a local copy, same shape as the Via ones would need if Via didn't
// happen to expose a mutable via() reference.
- (double)frequencyStart {
    return _config.frequency().start();
}
- (void)setFrequencyStart:(double)value {
    gerber2ems::Frequency frequency = _config.frequency();
    frequency.setStart(value);
    _config.setFrequency(frequency);
}
- (double)frequencyStop {
    return _config.frequency().stop();
}
- (void)setFrequencyStop:(double)value {
    gerber2ems::Frequency frequency = _config.frequency();
    frequency.setStop(value);
    _config.setFrequency(frequency);
}
- (NSInteger)maxSteps {
    return _config.maxSteps();
}
- (void)setMaxSteps:(NSInteger)value {
    _config.setMaxSteps(static_cast<std::int32_t>(value));
}

- (EMSSimulationBridge*)_wrapperForSimulationIndex:(NSInteger)index {
    EMSSimulationBridge* wrapper = [[EMSSimulationBridge alloc] init];
    wrapper->_parent = self;
    wrapper->_index = index;
    return wrapper;
}

- (NSArray<EMSSimulationBridge*>*)simulations {
    NSMutableArray<EMSSimulationBridge*>* result = [NSMutableArray arrayWithCapacity:_config.simulations().size()];
    for (std::size_t i = 0; i < _config.simulations().size(); ++i) {
        [result addObject:[self _wrapperForSimulationIndex:static_cast<NSInteger>(i)]];
    }
    return result;
}

- (EMSSimulationBridge*)addSimulationNamed:(NSString*)name {
    SimulationConfig sim;
    sim.setName(name.UTF8String);
    // A placeholder, not a real selection -- to_json() dereferences groundNet's active-kind
    // optional unconditionally, so it can never be left unset. involvedNets() is deliberately left
    // empty here: SimulationConfig::from_json() rejects an empty involved_nets list, so a document
    // saved before the user adds at least one (Phase 7's source list) won't re-parse -- callers
    // driving the UI should be aware a brand-new simulation isn't yet in a savable state until then.
    sim.groundNet().setKind(GroundSelectorKind::Net);
    sim.groundNet().setNet(std::string());
    _config.simulations().push_back(std::move(sim));
    return [self _wrapperForSimulationIndex:static_cast<NSInteger>(_config.simulations().size() - 1)];
}

- (void)removeSimulationAtIndex:(NSInteger)index {
    auto& simulations = _config.simulations();
    if (index < 0 || static_cast<std::size_t>(index) >= simulations.size()) {
        return;
    }
    simulations.erase(simulations.begin() + index);
}

@end
