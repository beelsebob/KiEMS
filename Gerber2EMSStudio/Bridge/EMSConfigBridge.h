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

/// One InvolvedNetConfig entry. Never holds a raw pointer into the parent's C++
/// vector<InvolvedNetConfig> -- see EMSSimulationBridge's identical note; the same index-forwarding
/// approach applies here, one level deeper.
@interface EMSInvolvedNetBridge : NSObject

@property (nonatomic) EMSNetSelectorKind kind;
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
/// nil means "use the board-derived default" (InvolvedNetConfig::width()'s std::optional).
@property (nonatomic, nullable) NSNumber *width;
@property (nonatomic, nullable) NSNumber *dBMargin;

/// Only meaningful for a .Net-kind entry: whether the given pad is excluded from an otherwise-
/// involved net (see gerber2ems::InvolvedNetConfig's own doc comment) -- the source list's per-pin
/// "Included in Simulation" checkbox is really toggling this, not a separate per-pin entry.
- (BOOL)isPinExcludedWithFootprint:(NSString *)footprint pin:(NSString *)pin;
- (void)excludePinWithFootprint:(NSString *)footprint pin:(NSString *)pin;
- (void)includePinWithFootprint:(NSString *)footprint pin:(NSString *)pin;

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
