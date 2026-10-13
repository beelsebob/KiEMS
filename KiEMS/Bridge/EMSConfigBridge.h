// Objective-C interface over kiems::EMSConfig. This header is Swift-visible (via the
// bridging header) and must never expose a C++ type -- see EMSConfigBridge.mm for how it holds
// the actual kiems::EMSConfig.
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

/// Mirrors kiems::NetInclusionLevel -- the "Simulation Net" vs. "Included in Simulation"
/// source-list checkboxes. SimulationNet is full participation (today's only behavior, pre-dating
/// this distinction): grows the hull, gets probe/absorb/excite ports. GeometryOnly is a strict
/// subset: the net's copper physically exists in the simulated geometry (clipped to whatever hull
/// the SimulationNet-level entries already produced, the same way ground-net copper already is),
/// but never grows the hull itself and is never port/probe/excitation-eligible.
typedef NS_ENUM(NSInteger, EMSNetInclusionLevel) {
    EMSNetInclusionLevelSimulationNet,
    EMSNetInclusionLevelGeometryOnly,
};

typedef NS_ENUM(NSInteger, EMSSimulationSetNetSelectionMode) {
    EMSSimulationSetNetSelectionModeRegularExpression,
    EMSSimulationSetNetSelectionModeList,
};

/// Mirrors kiems::EyeMaskStandard -- which preset a simulation's eye test was taken from.
typedef NS_ENUM(NSInteger, EMSEyeMaskStandard) {
    EMSEyeMaskStandardCustom,
    EMSEyeMaskStandardUSBHighSpeed,
    EMSEyeMaskStandardUSBFullSpeed,
    EMSEyeMaskStandardUSB5Gbps,
    EMSEyeMaskStandardUSB10Gbps,
    EMSEyeMaskStandardUSB20Gbps,
    EMSEyeMaskStandardDDR,
    EMSEyeMaskStandardDDR2,
    EMSEyeMaskStandardDDR3,
    EMSEyeMaskStandardDDR4,
    EMSEyeMaskStandardDDR5,
    EMSEyeMaskStandardFireWireS400,
    EMSEyeMaskStandardFireWireS800,
    EMSEyeMaskStandardFireWireS1600,
    EMSEyeMaskStandardThunderbolt1,
    EMSEyeMaskStandardThunderbolt2,
    EMSEyeMaskStandardThunderbolt3,
    EMSEyeMaskStandardThunderbolt4,
    EMSEyeMaskStandardHDMI10,
    EMSEyeMaskStandardHDMI14,
    EMSEyeMaskStandardHDMI20,
    EMSEyeMaskStandardDisplayPortRBR,
    EMSEyeMaskStandardDisplayPortHBR,
    EMSEyeMaskStandardDisplayPortHBR2,
    EMSEyeMaskStandardDisplayPortHBR3,
    EMSEyeMaskStandardEthernetSGMII,
    EMSEyeMaskStandardEthernetXAUI,
    EMSEyeMaskStandardEthernetSFI,
    EMSEyeMaskStandardPCIExpress1,
    EMSEyeMaskStandardPCIExpress2,
    EMSEyeMaskStandardPCIExpress3,
    EMSEyeMaskStandardPCIExpress4,
    EMSEyeMaskStandardPCIExpress5,
    EMSEyeMaskStandardDDR3CommandAddress,
    EMSEyeMaskStandardDDR4CommandAddress,
    EMSEyeMaskStandardDDR5CommandAddress,
    EMSEyeMaskStandardLPDDR4,
    EMSEyeMaskStandardLPDDR4X,
    EMSEyeMaskStandardLPDDR5,
};

/// One ProbedPin entry -- a plain value snapshot (not index-forwarding like EMSInvolvedNetBridge
/// itself), since kiems::ProbedPin has no separate identity to look up by index; a fresh array
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
/// Per-entry hull expansion in micrometers. Zero still contributes: the hull follows the copper's
/// edge. Ignored while inclusionLevel is GeometryOnly.
@property (nonatomic) double hullPadding;
/// Populated depending on kind: netClass for .NetClass, net for .Net, footprintReference+pins for
/// .FootprintPin. Setting the wrong one for the current kind is harmless (it's just unused until
/// kind changes to match) -- to_json()/kiems only ever reads the field matching kind.
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
/// length is read for this -- see kiems::InvolvedNetConfig::probeImpedance()'s own doc comment.
@property (nonatomic) BOOL probeImpedance;
/// The other net when this entry was added as one half of a differential pair. Pair membership is
/// independent of whether mixed-mode simulation is currently enabled.
@property (nonatomic, copy, nullable) NSString *differentialPairPartner;
@property (nonatomic) BOOL simulateAsDifferentialPair;
/// nil means "use the board-derived default" (InvolvedNetConfig::width()'s std::optional).
@property (nonatomic, nullable) NSNumber *width;
@property (nonatomic, nullable) NSNumber *dBMargin;

/// The MSLPort propagation direction, in degrees (0 = +X, 90 = +Y, ...) -- nil means "derive it
/// automatically from the routed copper departing the pad" (see kiems::_deriveDirection in
/// port_resolution.cpp). Any value is accepted, not just the four cardinal directions -- the app's
/// own direction popup snaps North/South/East/West to 90/270/0/180, but a "Custom" angle can be
/// anything the port_resolution.cpp escape hatch supports.
@property (nonatomic, nullable) NSNumber *direction;

/// Legacy opt-*out* mechanism -- only ever consulted (by kiems's own resolution logic) while
/// hasExplicitPinSelections is NO; superseded by isPinProbed/setPinProbed below for anything edited
/// under the current source-list UI. Kept only so a pre-existing simulation.json keeps resolving
/// exactly as it always did until its pins are first touched under the new UI -- see
/// kiems::InvolvedNetConfig's own doc comment.
- (BOOL)isPinExcludedWithFootprint:(NSString *)footprint pin:(NSString *)pin;
- (void)excludePinWithFootprint:(NSString *)footprint pin:(NSString *)pin;
- (void)includePinWithFootprint:(NSString *)footprint pin:(NSString *)pin;

/// True once any pin under this net has ever been edited via setPinProbed: below -- switches
/// pin-selection resolution from the legacy excludedPins()-based mode to strict, explicit opt-in
/// (see kiems::InvolvedNetConfig's own doc comment). Never goes back to NO.
@property (nonatomic, readonly) BOOL hasExplicitPinSelections;
/// Switches this entry to explicit opt-in mode with no pins selected. Intended for newly-created
/// net entries whose UI defaults Probe to off; existing legacy entries are left untouched unless
/// this is called explicitly.
- (void)useExplicitPinSelections;
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

/// Stores the explicit unprobed Absorbing choice. YES builds a real resistive termination port (so
/// the trace does not behave as an open stub); NO persists an explicit no-port override, distinct
/// from an absent pin whose UI may default to absorbing. Neither state is shown as a measured port
/// in Results or becomes an excitation target. Works on a GeometryOnly entry, unlike Probe.
/// Mutually exclusive with an existing Probe selection for the same pin -- setting one replaces
/// the other.
- (BOOL)isPinAbsorbOnlyWithFootprint:(NSString *)footprint pin:(NSString *)pin;
- (void)setPinAbsorbOnly:(BOOL)enabled withFootprint:(NSString *)footprint pin:(NSString *)pin;

/// A per-pad override for `direction`, checked first when resolving that one pad's own port --
/// see kiems::PinDirectionOverride's own doc comment for why a single net-wide `direction`
/// isn't always enough (opposite ends of a routed net often depart their own pads in different
/// cardinal directions). nil means "no override for this specific pad" -- falls through to
/// `direction`, then auto-derivation, same as before this existed.
- (nullable NSNumber *)directionOverrideWithFootprint:(NSString *)footprint pin:(NSString *)pin;
- (void)setDirectionOverride:(nullable NSNumber *)direction withFootprint:(NSString *)footprint pin:(NSString *)pin;

/// Per-pin port impedance in ohms. nil means to inherit this involved net's impedance.
/// This is independent of the pin's Probe/Absorb/Excite state.
- (nullable NSNumber *)impedanceWithFootprint:(NSString *)footprint pin:(NSString *)pin;
- (void)setImpedance:(nullable NSNumber *)impedance withFootprint:(NSString *)footprint pin:(NSString *)pin;
/// The pin's load (receiver input) capacitance in farads, or nil for none.
- (nullable NSNumber *)loadCapacitanceWithFootprint:(NSString *)footprint pin:(NSString *)pin;
- (void)setLoadCapacitance:(nullable NSNumber *)capacitance withFootprint:(NSString *)footprint pin:(NSString *)pin;

@end

/// One ExcitationConfig entry -- purely a postprocessing input for the pin it's attached to (see
/// kiems::ExcitationConfig's doc comment; it plays no role in the FDTD sweep itself). Same
/// index-forwarding note as EMSInvolvedNetBridge.
@interface EMSExcitationBridge : NSObject

@property (nonatomic, copy) NSString *footprintReference;
@property (nonatomic, copy) NSString *pin;
/// Non-nil for an excitation attached to a hull-cut trace port instead of a component pin.
@property (nonatomic, copy, nullable) NSString *hullCutPortID;

@property (nonatomic) BOOL isMain;
/// Only meaningful while !isMain: YES runs the tone for the longest main excitation's whole FDTD
/// run; NO (Limited) runs it for `duration`. See kiems::ExcitationDurationMode.
@property (nonatomic) BOOL hasContinuousDuration;
@property (nonatomic) double startTime;
@property (nonatomic) double duration;
@property (nonatomic) double phaseDegrees;
/// Required iff !isMain -- nil (unset) is only valid while isMain is YES.
@property (nonatomic, nullable) NSNumber *frequency;
@property (nonatomic, nullable) NSNumber *amplitude;

@end


/// One component included in a simulation -- see kiems::IncludedComponentConfig. Forwards through
/// its simulation by index, like EMSInvolvedNetBridge.
@interface EMSIncludedComponentBridge : NSObject
@property (nonatomic, copy, readonly) NSString *reference;
/// Whether the component's pads grow the simulation hull, by hullPadding.
@property (nonatomic) BOOL contributesToHull;
/// Hull expansion in micrometers. Kept while contributesToHull is off.
@property (nonatomic) double hullPadding;
@end

@interface EMSHullCutPortBridge : NSObject
@property (nonatomic, copy, readonly) NSString *identifier;
@property (nonatomic, copy, readonly) NSString *netName;
@property (nonatomic, copy, readonly) NSString *layerName;
@property (nonatomic, readonly) double x;
@property (nonatomic, readonly) double y;
@property (nonatomic, readonly) double direction;
@property (nonatomic, readonly) double width;
@property (nonatomic, readonly) double length;
@property (nonatomic) NSInteger plane;
@property (nonatomic) double impedance;
@property (nonatomic) BOOL probe;
@property (nonatomic) BOOL absorbSignal;
@end

/// One SimulationConfig within an EMSConfig. Never holds a raw pointer into the parent's C++
/// vector<SimulationConfig> (which reallocates on add/remove) -- every property forwards through
/// the parent by index instead, so this stays valid across mutations elsewhere in the document.
/// One probe of a Simulation Set -- see kiems::SimulationSetProbe. A plain value: edit a copy and
/// assign the owning EMSSimulationSetBridge back to its simulation.
@interface EMSSimulationSetProbeBridge : NSObject
@property (nonatomic, copy) NSString *footprintReference;
@property (nonatomic) BOOL absorbing;
@property (nonatomic) double loadImpedance;
@property (nonatomic, nullable) NSNumber *loadCapacitance;
@end

/// A Simulation Set's own setup -- see kiems::SimulationSetConfig. A plain value snapshot, not a
/// live view: changes take effect only once assigned back to EMSSimulationBridge.simulationSet.
@interface EMSSimulationSetBridge : NSObject
@property (nonatomic, copy, readonly) NSString *identifier;
@property (nonatomic, copy) NSString *excitationFootprintReference;
@property (nonatomic) EMSSimulationSetNetSelectionMode netSelectionMode;
/// A regex the whole primary net name must match.
@property (nonatomic, copy) NSString *netNamePattern;
/// Explicit primary net names, used when netSelectionMode is List.
@property (nonatomic, copy) NSArray<NSString *> *netNames;
/// Regex substitution templates that add nets to each primary-net simulation.
@property (nonatomic, copy) NSArray<NSString *> *additionalNetPatterns;
@property (nonatomic) double phaseDegrees;
@property (nonatomic) double amplitude;
@property (nonatomic) double driveImpedance;
@property (nonatomic) BOOL probed;
@property (nonatomic) BOOL probeNetImpedance;
@property (nonatomic) BOOL absorbing;
@property (nonatomic) double loadImpedance;
@property (nonatomic, nullable) NSNumber *loadCapacitance;
@property (nonatomic, copy) NSArray<EMSSimulationSetProbeBridge *> *probes;
@end

@interface EMSSimulationBridge : NSObject

@property (nonatomic, copy) NSString *name;

@property (nonatomic) EMSGroundSelectorKind groundNetKind;
/// The net or net-class name ground_net selects, depending on groundNetKind.
@property (nonatomic, copy, nullable) NSString *groundNetName;

@property (nonatomic) double viaEdgeDistance;
@property (nonatomic) double viaSpacing;
/// Serial data rate used for eye-diagram synthesis. Existing configurations without an explicit
/// value read as the document's frequency stop; assigning it persists a per-simulation override.
@property (nonatomic) double eyeBitRate;
/// Transmission times the eye samples adversarial noise at. See kiems::EyeNoiseOptions::drawCount.
@property (nonatomic) NSInteger eyeDrawCount;
/// Whether the adversarial sources share a clock. See kiems::EyeNoiseOptions::sharedClock.
@property (nonatomic) BOOL adversarialSharedClock;

/// The eye test -- see kiems::EyeTestConfig and kiems::EyeMask. Times are in unit intervals,
/// voltages in volts; a zero eyeMaskY1 means no keep-out region and a zero eyeMaskY2 no outer limit.
@property (nonatomic) EMSEyeMaskStandard eyeMaskStandard;
/// The +- level the eye's PRBS is launched at (differential for a pair). Must be positive.
@property (nonatomic) double eyeSignalLevel;
@property (nonatomic) double eyeMaskX1;
@property (nonatomic) double eyeMaskX2;
@property (nonatomic) double eyeMaskY1;
@property (nonatomic) double eyeMaskY2;
/// Copies every analysis-only eye setting (bit rate, draw count, shared clock and eye test) from
/// `simulation` -- how a Simulation Set's edits reach the simulations it generated without
/// regenerating them, which would discard their results.
- (void)copyEyeAnalysisSettingsFromSimulation:(EMSSimulationBridge *)simulation
    NS_SWIFT_NAME(copyEyeAnalysisSettings(from:));

/// Whether this simulation is fundamentally about a differential pair -- see
/// kiems::SimulationConfig::isDifferentialPair()'s own doc comment for exactly what toggling this
/// changes (gates whether involvedNets() entries carrying a reciprocal differentialPairPartner
/// pairing actually get turned into a diffPairs() entry, or are left as plain single-ended ports).
@property (nonatomic) BOOL isDifferentialPair;

/// Nets terminated to the ground net along the board-slicing cut -- see
/// kiems::SimulationConfig::edgeTerminatedNets(). Empty strings are rows not yet given a net.
@property (nonatomic, copy) NSArray<NSString *> *edgeTerminatedNets;

/// Non-nil when this simulation is a Simulation Set template (never run itself). Assigning nil is
/// ignored -- a simulation's set-ness is fixed when it's created.
@property (nonatomic, nullable) EMSSimulationSetBridge *simulationSet;
/// The identifier of the Simulation Set this simulation was generated from, if any.
@property (nonatomic, copy, readonly, nullable) NSString *generatedBySetIdentifier;
/// This simulation's saved JSON, for telling whether a regeneration actually changed it.
@property (nonatomic, copy, readonly) NSString *jsonRepresentation;

@property (nonatomic, readonly) NSArray<EMSInvolvedNetBridge *> *involvedNets;
- (EMSInvolvedNetBridge *)addInvolvedNetWithKind:(EMSNetSelectorKind)kind;
- (void)removeInvolvedNetAtIndex:(NSInteger)index;

@property (nonatomic, readonly) NSArray<EMSIncludedComponentBridge *> *includedComponents;
/// Includes the component, or returns its existing entry if it's already included.
- (EMSIncludedComponentBridge *)includeComponentWithReference:(NSString *)reference;
- (void)removeIncludedComponentWithReference:(NSString *)reference;

@property (nonatomic, readonly) NSArray<EMSExcitationBridge *> *excitations;
- (EMSExcitationBridge *)addExcitationForFootprint:(NSString *)footprint pin:(NSString *)pin;
- (EMSExcitationBridge *)addExcitationForHullCutPort:(NSString *)identifier;
- (void)removeExcitationAtIndex:(NSInteger)index;

@property (nonatomic, readonly) NSArray<EMSHullCutPortBridge *> *hullCutPorts;
- (EMSHullCutPortBridge *)addHullCutPortWithIdentifier:(NSString *)identifier
                                                   net:(NSString *)net
                                                 layer:(NSString *)layer
                                                     x:(double)x y:(double)y
                                             direction:(double)direction
                                                 width:(double)width length:(double)length;
- (void)removeHullCutPortAtIndex:(NSInteger)index;

@end

/// A simulation.json document's in-memory model. Always in file units (mm etc.) -- see
/// kiems::EMSConfig::scaledToSimulationUnits()'s doc comment; this bridge never scales
/// anything, it just edits/saves exactly what's in the file.
/// One pin's board-level defaults -- see kiems::BoardPinSetup. A snapshot: edit through
/// EMSBoardSetupBridge's pin setters, which create/prune the underlying entry.
@interface EMSBoardPinSetupBridge : NSObject
@property (nonatomic, copy, readonly) NSString *footprintReference;
@property (nonatomic, copy, readonly) NSString *pin;
/// Ohms; nil inherits the net/net class/default impedance.
@property (nonatomic, readonly, nullable) NSNumber *impedance;
/// BOOL; nil leaves the simulation's automatic termination rule in charge.
@property (nonatomic, readonly, nullable) NSNumber *absorbing;
@property (nonatomic, readonly) BOOL noiseGenerating;
@property (nonatomic, readonly) double noiseFrequency;
@property (nonatomic, readonly) double noiseAmplitude;
@end

/// Board-wide defaults (kiems::BoardSetupConfig), copied into a simulation as its nets are included.
@interface EMSBoardSetupBridge : NSObject
/// The ground net (or net class) new simulations start with; nil when none is chosen.
@property (nonatomic) EMSGroundSelectorKind groundNetKind;
@property (nonatomic, copy, nullable) NSString *groundNetName;
/// The edge-terminated nets new simulations start with.
@property (nonatomic, copy) NSArray<NSString *> *edgeTerminatedNets;
/// The nets and net classes new simulations start with included (geometry only).
@property (nonatomic, copy) NSArray<NSString *> *includedNets;
@property (nonatomic, copy) NSArray<NSString *> *includedNetClasses;
/// The component references new simulations start with included.
@property (nonatomic, copy) NSArray<NSString *> *includedComponents;
@property (nonatomic) double signalImpedance;
@property (nonatomic) double powerImpedance;
/// Default digital bit rate for new simulations; 0 means automatic.
@property (nonatomic) double bitRate;
/// Net class name -> ohms, for classes with their own impedance.
@property (nonatomic, readonly) NSDictionary<NSString *, NSNumber *> *netClassImpedances;
- (nullable NSNumber *)impedanceForNetClass:(NSString *)netClass;
- (void)setImpedance:(nullable NSNumber *)impedance forNetClass:(NSString *)netClass;
- (nullable NSNumber *)impedanceForNet:(NSString *)net;
- (void)setImpedance:(nullable NSNumber *)impedance forNet:(NSString *)net;
/// The impedance `net` resolves to: its own, else its class's, else the signal/power default.
- (double)effectiveImpedanceForNet:(NSString *)net netClass:(nullable NSString *)netClass isPowerNet:(BOOL)isPowerNet;

@property (nonatomic, readonly) NSArray<EMSBoardPinSetupBridge *> *pins;
- (nullable EMSBoardPinSetupBridge *)pinWithFootprint:(NSString *)footprint pin:(NSString *)pin;
- (void)setImpedance:(nullable NSNumber *)impedance forFootprint:(NSString *)footprint pin:(NSString *)pin;
- (void)setAbsorbing:(nullable NSNumber *)absorbing forFootprint:(NSString *)footprint pin:(NSString *)pin;
- (void)setNoiseGenerating:(BOOL)noiseGenerating
                 frequency:(double)frequency
                 amplitude:(double)amplitude
              forFootprint:(NSString *)footprint
                       pin:(NSString *)pin;
@end

@interface EMSConfigBridge : NSObject

+ (instancetype)configWithDefaults;
+ (nullable instancetype)configWithContentsOfFile:(NSString *)path error:(NSError **)error;
- (BOOL)saveToFile:(NSString *)path error:(NSError **)error;

/// The .kicad_pcb this document is linked to -- nil until the board picker sets it. See
/// kiems::EMSConfig::kicadPcbPath()'s doc comment for why this is a stored path rather than a
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

/// The FDTD grid's own base target cell size (kiems::Grid::optimal()), in file-unit
/// micrometers -- the primary "how fine is the mesh" knob (diagonal/perpendicular/max cell sizes
/// scale relative to this one). Document-level (EMSConfig), not per-simulation, same as maxSteps.
@property (nonatomic) double gridDensity;
/// The absorbing boundary's depth in cells on every face of the domain (kiems::Grid::absorbingBoundaryCells()):
/// GridGenerator appends that many dedicated cells beyond the mesh, so changing it changes every
/// simulation's geometry. Document-level, like gridDensity.
@property (nonatomic) NSInteger absorbingBoundaryCells;
/// The vacuum the mesh keeps between the board and the absorbing boundary in X and Y
/// (kiems::Margin::xy()), in file-unit micrometers. Changes every simulation's geometry.
/// Document-level, like gridDensity.
@property (nonatomic) double marginWidth;
/// A quarter of the vacuum wavelength at frequencyStart, in micrometers (kiems::Margin::suggested()):
/// the rule-of-thumb margin, offered as a suggestion only. 0 without a positive start frequency.
@property (nonatomic, readonly) double suggestedMarginWidth;

/// Every copper layer's name, board-top to board-bottom, in the same 0-based order
/// InvolvedNetConfig::plane()/PortConfig::plane() index into (substrate layers don't count towards
/// that index, so they're excluded here too) -- empty until a board's been linked and its stackup
/// imported (see kiems::EMSConfig::loadStackup()).
@property (nonatomic, readonly) NSArray<NSString *> *metalLayerNames;

@property (nonatomic, readonly) NSArray<EMSSimulationBridge *> *simulations;
- (EMSSimulationBridge *)addSimulationNamed:(NSString *)name;
- (void)removeSimulationAtIndex:(NSInteger)index;
/// Adds a simulation exactly as addSimulationNamed: does, made into an empty Simulation Set template.
- (EMSSimulationBridge *)addSimulationSetNamed:(NSString *)name;
/// Writes a copy of the Simulation Set template at `templateIndex`, renamed and marked as generated
/// by it, over the simulation at `targetIndex` -- or appends it when `targetIndex` is out of range.
/// Returns the generated simulation's index.
- (NSInteger)generateSimulationFromSetAtIndex:(NSInteger)templateIndex
                                        named:(NSString *)name
                               replacingIndex:(NSInteger)targetIndex;

/// A live view of this document's board setup; edits apply directly to the config.
@property (nonatomic, readonly) EMSBoardSetupBridge *boardSetup;

@end

/// Which physical quantity a lumped-component Value field string is being checked as -- mirrors
/// kiems::ComponentUnit (component_value.hpp).
typedef NS_ENUM(NSInteger, EMSLumpedComponentUnit) {
    EMSLumpedComponentUnitResistance,
    EMSLumpedComponentUnitInductance,
    EMSLumpedComponentUnitCapacitance,
};

/// Lets the configuration UI flag an R/L/C footprint whose Value field won't produce a usable
/// lumped component -- see kiems::parseComponentValue()'s own doc comment for the text formats
/// this understands ("4k7", "100nF", "0R1", ...). A component with no sensible value here is
/// silently dropped from the simulation entirely. A zero-ohm resistor is deliberately accepted as
/// a physical jumper and simulated as a representative 10 mOhm; zero-valued capacitors and
/// inductors remain invalid.
@interface EMSConfigBridge (LumpedComponentValue)
+ (BOOL)componentValueIsSensible:(NSString *)value unit:(EMSLumpedComponentUnit)unit;
@end

NS_ASSUME_NONNULL_END
