// Objective-C interface over gerber2ems::EMSConfig. This header is Swift-visible (via the
// bridging header) and must never expose a C++ type -- see EMSConfigBridge.mm for how it holds
// the actual gerber2ems::EMSConfig.
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

extern NSErrorDomain const EMSConfigErrorDomain;

typedef NS_ENUM(NSInteger, EMSGroundSelectorKind) {
    EMSGroundSelectorKindNetClass,
    EMSGroundSelectorKindNet,
};

typedef NS_ENUM(NSInteger, EMSNetSelectorKind) {
    EMSNetSelectorKindNetClass,
    EMSNetSelectorKindNet,
    EMSNetSelectorKindFootprintPin,
};

/// Mirrors gerber2ems::NetInclusionLevel -- the "Simulation Net" vs. "Included in Simulation"
/// source-list checkboxes. SimulationNet is full participation (today's only behavior, pre-dating
/// this distinction): grows the hull, gets probe/absorb/excite ports. GeometryOnly is a strict
/// subset: the net's copper physically exists in the simulated geometry (clipped to whatever hull
/// the SimulationNet-level entries already produced, the same way ground-net copper already is),
/// but never grows the hull itself and is never port/probe/excitation-eligible.
typedef NS_ENUM(NSInteger, EMSNetInclusionLevel) {
    EMSNetInclusionLevelSimulationNet,
    EMSNetInclusionLevelGeometryOnly,
};

/// One ProbedPin entry -- a plain value snapshot (not index-forwarding like EMSInvolvedNetBridge
/// itself), since gerber2ems::ProbedPin has no separate identity to look up by index; a fresh array
/// of these is built from InvolvedNetConfig::probedPins() on every read of
/// EMSInvolvedNetBridge.probedPins.
@interface EMSProbedPinBridge : NSObject
@property (nonatomic, copy, readonly) NSString *footprintReference;
@property (nonatomic, copy, readonly) NSString *pin;
@property (nonatomic, readonly) BOOL absorbSignal;
/// NO means this entry is absorb-only (see EMSInvolvedNetBridge's setPinAbsorbOnly:below): a real
/// resistive termination, but never a named/selectable thing in Results. Defaults YES.
@property (nonatomic, readonly) BOOL probe;
@end

/// One InvolvedNetConfig entry. Never holds a raw pointer into the parent's C++
/// vector<InvolvedNetConfig> -- see EMSSimulationBridge's identical note; the same index-forwarding
/// approach applies here, one level deeper.
@interface EMSInvolvedNetBridge : NSObject

@property (nonatomic) EMSNetSelectorKind kind;
/// Defaults to SimulationNet -- see EMSNetInclusionLevel's own doc comment. Every other property on
/// this class (impedance/length/probeImpedance/differentialPairPartner/direction/etc.) is
/// meaningless for a GeometryOnly entry, the same way footprintReference/pins are already meaningless
/// until kind is .FootprintPin -- port_resolution.cpp simply never reaches this entry to read them,
/// with one exception: setPinAbsorbOnly:/isPinAbsorbOnlyWithFootprint:pin: below works on a
/// GeometryOnly entry too, specifically so one of its pins can still get a real resistive
/// termination (see that method's own doc comment) without the net itself becoming
/// port/probe/excitation-eligible or entering resolvedNets().
@property (nonatomic) EMSNetInclusionLevel inclusionLevel;
/// Populated depending on kind: netClass for .NetClass, net for .Net, footprintReference+pins for
/// .FootprintPin. Setting the wrong one for the current kind is harmless (it's just unused until
/// kind changes to match) -- to_json()/gerber2ems only ever reads the field matching kind.
@property (nonatomic, copy, nullable) NSString *netClass;
@property (nonatomic, copy, nullable) NSString *net;
@property (nonatomic, copy, nullable) NSString *footprintReference;
@property (nonatomic, copy) NSArray<NSString *> *pins;

@property (nonatomic) double impedance;
@property (nonatomic) double length;
@property (nonatomic) NSInteger plane;
/// Net/NetClass-kind entries only -- when YES, auto-places a handful of non-loading, trace-anchored
/// impedance-measurement probes along this net's own straight routed copper, independent of
/// whatever ports its own pads resolve to via probedPins()/excludedPins(). Neither impedance nor
/// length is read for this -- see gerber2ems::InvolvedNetConfig::probeImpedance()'s own doc comment.
@property (nonatomic) BOOL probeImpedance;
/// The other net when this entry was added as one half of a differential pair. Pair membership is
/// independent of whether mixed-mode simulation is currently enabled.
@property (nonatomic, copy, nullable) NSString *differentialPairPartner;
@property (nonatomic) BOOL simulateAsDifferentialPair;
/// nil means "use the board-derived default" (InvolvedNetConfig::width()'s std::optional).
@property (nonatomic, nullable) NSNumber *width;
@property (nonatomic, nullable) NSNumber *dBMargin;

/// The MSLPort propagation direction, in degrees (0 = +X, 90 = +Y, ...) -- nil means "derive it
/// automatically from the routed copper departing the pad" (see gerber2ems::_deriveDirection in
/// port_resolution.cpp). Any value is accepted, not just the four cardinal directions -- the app's
/// own direction popup snaps North/South/East/West to 90/270/0/180, but a "Custom" angle can be
/// anything the port_resolution.cpp escape hatch supports.
@property (nonatomic, nullable) NSNumber *direction;

/// Legacy opt-*out* mechanism -- only ever consulted (by gerber2ems's own resolution logic) while
/// hasExplicitPinSelections is NO; superseded by isPinProbed/setPinProbed below for anything edited
/// under the current source-list UI. Kept only so a pre-existing simulation.json keeps resolving
/// exactly as it always did until its pins are first touched under the new UI -- see
/// gerber2ems::InvolvedNetConfig's own doc comment.
- (BOOL)isPinExcludedWithFootprint:(NSString *)footprint pin:(NSString *)pin;
- (void)excludePinWithFootprint:(NSString *)footprint pin:(NSString *)pin;
- (void)includePinWithFootprint:(NSString *)footprint pin:(NSString *)pin;

/// True once any pin under this net has ever been edited via setPinProbed: below -- switches
/// pin-selection resolution from the legacy excludedPins()-based mode to strict, explicit opt-in
/// (see gerber2ems::InvolvedNetConfig's own doc comment). Never goes back to NO.
@property (nonatomic, readonly) BOOL hasExplicitPinSelections;
/// Only meaningful once hasExplicitPinSelections is YES.
- (BOOL)isPinProbedWithFootprint:(NSString *)footprint pin:(NSString *)pin;
/// Only meaningful if isPinProbedWithFootprint:pin: is YES for the same pin -- defaults to YES.
- (BOOL)pinAbsorbsSignalWithFootprint:(NSString *)footprint pin:(NSString *)pin;
/// Sets (probed=YES) or clears (probed=NO) this pin's probed state, and its absorb-signal choice
/// when probed=YES. Always sets hasExplicitPinSelections to YES, even when clearing -- see that
/// property's own doc comment.
- (void)setPinProbed:(BOOL)probed absorbSignal:(BOOL)absorbSignal withFootprint:(NSString *)footprint pin:(NSString *)pin;
/// Every explicitly probed pin on this net -- only ever non-empty once hasExplicitPinSelections is
/// YES (a legacy net's implicit "every pad probed by default" isn't enumerated here at all, since
/// it isn't a bounded list -- see InvolvedNetsViewController, the one place this is read, for why
/// that distinction matters for a "compact summary" view).
@property (nonatomic, readonly) NSArray<EMSProbedPinBridge *> *probedPins;

/// Absorb-only: a real resistive termination port gets built for this pin (so it doesn't behave as
/// an open, fully-reflecting stub in the FDTD field -- see gerber2ems::PortConfig::absorbSignal()'s
/// own doc comment), but it's never shown as a measured port in Results and never becomes an
/// excitation target on its own. Meant for a pin whose real destination (an IC input, a resistor to
/// ground, ...) isn't itself part of this simulation, so the trace leading to it would otherwise
/// dangle unterminated. Works on a GeometryOnly entry, unlike isPinProbedWithFootprint:pin:/
/// setPinProbed:absorbSignal:withFootprint:pin: above, which are meaningless there. Mutually
/// exclusive with an existing Probe selection for the same pin -- setting one clears the other.
- (BOOL)isPinAbsorbOnlyWithFootprint:(NSString *)footprint pin:(NSString *)pin;
- (void)setPinAbsorbOnly:(BOOL)enabled withFootprint:(NSString *)footprint pin:(NSString *)pin;

/// A per-pad override for `direction`, checked first when resolving that one pad's own port --
/// see gerber2ems::PinDirectionOverride's own doc comment for why a single net-wide `direction`
/// isn't always enough (opposite ends of a routed net often depart their own pads in different
/// cardinal directions). nil means "no override for this specific pad" -- falls through to
/// `direction`, then auto-derivation, same as before this existed.
- (nullable NSNumber *)directionOverrideWithFootprint:(NSString *)footprint pin:(NSString *)pin;
- (void)setDirectionOverride:(nullable NSNumber *)direction withFootprint:(NSString *)footprint pin:(NSString *)pin;

@end

/// One ExcitationConfig entry -- purely a postprocessing input for the pin it's attached to (see
/// gerber2ems::ExcitationConfig's doc comment; it plays no role in the FDTD sweep itself). Same
/// index-forwarding note as EMSInvolvedNetBridge.
@interface EMSExcitationBridge : NSObject

@property (nonatomic, copy) NSString *footprintReference;
@property (nonatomic, copy) NSString *pin;

@property (nonatomic) BOOL isMain;
@property (nonatomic) double startTime;
@property (nonatomic) double duration;
@property (nonatomic) double phaseDegrees;
/// Required iff !isMain -- nil (unset) is only valid while isMain is YES.
@property (nonatomic, nullable) NSNumber *frequency;
@property (nonatomic, nullable) NSNumber *amplitude;

@end

/// One SimulationConfig within an EMSConfig. Never holds a raw pointer into the parent's C++
/// vector<SimulationConfig> (which reallocates on add/remove) -- every property forwards through
/// the parent by index instead, so this stays valid across mutations elsewhere in the document.
@interface EMSSimulationBridge : NSObject

@property (nonatomic, copy) NSString *name;

@property (nonatomic) EMSGroundSelectorKind groundNetKind;
/// The net or net-class name ground_net selects, depending on groundNetKind.
@property (nonatomic, copy, nullable) NSString *groundNetName;

@property (nonatomic) double hullPadding;
@property (nonatomic) double viaEdgeDistance;
@property (nonatomic) double viaSpacing;
/// Serial data rate used for eye-diagram synthesis. Existing configurations without an explicit
/// value read as the document's frequency stop; assigning it persists a per-simulation override.
@property (nonatomic) double eyeBitRate;

@property (nonatomic, readonly) NSArray<EMSInvolvedNetBridge *> *involvedNets;
- (EMSInvolvedNetBridge *)addInvolvedNetWithKind:(EMSNetSelectorKind)kind;
- (void)removeInvolvedNetAtIndex:(NSInteger)index;

@property (nonatomic, readonly) NSArray<EMSExcitationBridge *> *excitations;
- (EMSExcitationBridge *)addExcitationForFootprint:(NSString *)footprint pin:(NSString *)pin;
- (void)removeExcitationAtIndex:(NSInteger)index;

@end

/// A simulation.json document's in-memory model. Always in file units (mm etc.) -- see
/// gerber2ems::EMSConfig::scaledToSimulationUnits()'s doc comment; this bridge never scales
/// anything, it just edits/saves exactly what's in the file.
@interface EMSConfigBridge : NSObject

+ (instancetype)configWithDefaults;
+ (nullable instancetype)configWithContentsOfFile:(NSString *)path error:(NSError **)error;
- (BOOL)saveToFile:(NSString *)path error:(NSError **)error;

/// The .kicad_pcb this document is linked to -- nil until the board picker sets it. See
/// gerber2ems::EMSConfig::kicadPcbPath()'s doc comment for why this is a stored path rather than a
/// copied file.
@property (nonatomic, copy, nullable) NSString *kicadPcbPath;

/// Via plating thickness/filling epsilon are document-level (EMSConfig), not per-simulation.
@property (nonatomic) double viaPlatingThickness;
@property (nonatomic) double viaFillingEpsilon;

/// The overall FDTD frequency sweep range, in Hz -- the bandwidth the simulation's single broadband
/// (Gaussian) main excitation pulse covers. Document-level (EMSConfig), not per-simulation, same as
/// the via fields above.
@property (nonatomic) double frequencyStart;
@property (nonatomic) double frequencyStop;

/// The FDTD engine's hard cap on timesteps for every port's run -- the run stops here even if
/// openEMS's own -60dB energy-decay end criteria hasn't been met yet (RunFDTD logs a warning to that
/// effect when it happens). Document-level (EMSConfig), not per-simulation, same as the fields above.
/// Too low a value truncates the recorded time-domain signal before it's decayed, which shows up as
/// spurious ripple/rapid phase rotation in the post-processed S-parameters.
@property (nonatomic) NSInteger maxSteps;

/// The FDTD grid's own base target cell size (gerber2ems::Grid::optimal()), in file-unit
/// micrometers -- the primary "how fine is the mesh" knob (diagonal/perpendicular/max cell sizes
/// scale relative to this one). Document-level (EMSConfig), not per-simulation, same as maxSteps.
@property (nonatomic) double gridDensity;

/// Every copper layer's name, board-top to board-bottom, in the same 0-based order
/// InvolvedNetConfig::plane()/PortConfig::plane() index into (substrate layers don't count towards
/// that index, so they're excluded here too) -- empty until a board's been linked and its stackup
/// imported (see gerber2ems::EMSConfig::loadStackup()).
@property (nonatomic, readonly) NSArray<NSString *> *metalLayerNames;

@property (nonatomic, readonly) NSArray<EMSSimulationBridge *> *simulations;
- (EMSSimulationBridge *)addSimulationNamed:(NSString *)name;
- (void)removeSimulationAtIndex:(NSInteger)index;

@end

NS_ASSUME_NONNULL_END
