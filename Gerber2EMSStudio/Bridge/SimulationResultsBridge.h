// A renderable snapshot of one simulation's post-processed FDTD results (S-parameters, impedance,
// diff-pair/trace delays) -- Swift-visible; never exposes a C++ type. Mirrors GeometryPreviewBridge.h's
// own shape one stage further down the pipeline. Actually running the geometry -> simulate ->
// postprocess pipeline that produces this data is EMSSimulationPipelineBridge's job now (see
// EMSSimulationPipelineBridge.h) -- see SimulationResultsBridge+Private.h's buildResultsPreview()
// for how that bridge turns an already-computed Postprocessor into one of these.
#import <Foundation/Foundation.h>

#import "EMSConfigBridge.h"

NS_ASSUME_NONNULL_BEGIN

/// One resolved simulation port -- mirrors kicad_ems::PortConfig's display-relevant fields.
@interface EMSResultsPort : NSObject
@property (nonatomic, copy, readonly) NSString *name;
@property (nonatomic, readonly) NSInteger index;
@property (nonatomic, readonly) double impedanceOhm;
@property (nonatomic, readonly) double dBMargin;
@property (nonatomic, readonly) BOOL excited;
@end

/// One S_ji curve (magnitude in dB, phase in degrees, both vs. EMSResultsPreview's own
/// frequenciesGHz) -- one instance per measured port `outputPort` in an EMSResultsSParamSet.
@interface EMSResultsSParamCurve : NSObject
@property (nonatomic, readonly) NSInteger outputPort;
/// Display-ready label, e.g. "S₁₁" -- matches postprocess.cpp's own _sLabel convention.
@property (nonatomic, copy, readonly) NSString *label;
@property (nonatomic, copy, readonly) NSArray<NSNumber *> *magnitudeDb;
@property (nonatomic, copy, readonly) NSArray<NSNumber *> *phaseDeg;
@end

/// Every S-parameter curve measured while `excitedPort` was driven -- one instance per excited
/// port, matching renderSParams's own "one file per excited port" structure.
@interface EMSResultsSParamSet : NSObject
@property (nonatomic, readonly) NSInteger excitedPort;
@property (nonatomic, copy, readonly) NSArray<EMSResultsSParamCurve *> *curves;
@end

/// One port's impedance (magnitude/angle vs. frequency) -- one instance per port with valid data.
@interface EMSResultsImpedance : NSObject
@property (nonatomic, readonly) NSInteger port;
@property (nonatomic, copy, readonly) NSArray<NSNumber *> *magnitudeOhm;
@property (nonatomic, copy, readonly) NSArray<NSNumber *> *angleDeg;
@end

/// One port's Smith-chart trace (S_ii's real/imaginary parts vs. frequency) plus the VSWR-margin
/// circle radius derived from that port's own dB margin -- one instance per excited port with a
/// valid self S-parameter.
@interface EMSResultsSmith : NSObject
@property (nonatomic, readonly) NSInteger port;
@property (nonatomic, copy, readonly) NSArray<NSNumber *> *reGamma;
@property (nonatomic, copy, readonly) NSArray<NSNumber *> *imGamma;
@property (nonatomic, readonly) double vswrMarginGamma;
@end

/// One differential pair's mixed-mode results -- every field is nil if that particular quantity
/// couldn't be computed (matching Postprocessor::getDiffPairSdd/getDiffPairImpedance/getDelay's own
/// independent validity conditions), not an all-or-nothing pair.
@interface EMSResultsDiffPair : NSObject
@property (nonatomic, copy, readonly) NSString *name;
@property (nonatomic, copy, readonly, nullable) NSArray<NSNumber *> *sdd11Db;
@property (nonatomic, copy, readonly, nullable) NSArray<NSNumber *> *sdd21Db;
@property (nonatomic, copy, readonly, nullable) NSArray<NSNumber *> *impedanceMagnitudeOhm;
@property (nonatomic, copy, readonly, nullable) NSArray<NSNumber *> *impedanceAngleDeg;
@property (nonatomic, copy, readonly, nullable) NSArray<NSNumber *> *nDelayNs;
@property (nonatomic, copy, readonly, nullable) NSArray<NSNumber *> *pDelayNs;
@end

/// One passive probe's voltage or current magnitude vs. frequency, measured while `excitedPort`
/// was driven -- mirrors EMSResultsSParamCurve's shape, but for a probe with absorbSignal()==false
/// (see kicad_ems::PortConfig::absorbSignal()'s own doc comment), which has no S-parameter of its
/// own to show (no characteristic impedance to normalize against), only raw magnitude vs. frequency.
@interface EMSResultsProbeCurve : NSObject
@property (nonatomic, readonly) NSInteger excitedPort;
@property (nonatomic, copy, readonly) NSArray<NSNumber *> *voltageMagnitude;
@property (nonatomic, copy, readonly) NSArray<NSNumber *> *currentMagnitude;
@end

/// One passive probe's data across every excited port -- mirrors EMSResultsSParamSet's shape,
/// grouped by probe instead of by excited port (a probe is never excited itself, so "one set per
/// excited port" doesn't apply the way it does for EMSResultsSParamSet).
@interface EMSResultsProbe : NSObject
@property (nonatomic, copy, readonly) NSString *name;
@property (nonatomic, readonly) NSInteger index;
@property (nonatomic, copy, readonly) NSArray<EMSResultsProbeCurve *> *curves;
@end

/// One trace-impedance probe's own measured characteristic impedance vs. frequency (magnitude/angle,
/// like EMSResultsImpedance) -- one instance per probe on a net with EMSInvolvedNetBridge.
/// probeImpedance set (see kicad_ems::PortConfig::isTraceProbe()'s own doc comment), grouped under
/// that net's own EMSResultsNetImpedance below.
@interface EMSResultsNetImpedanceCurve : NSObject
@property (nonatomic, copy, readonly) NSString *probeName;
@property (nonatomic, copy, readonly) NSArray<NSNumber *> *magnitudeOhm;
@property (nonatomic, copy, readonly) NSArray<NSNumber *> *angleDeg;
@end

/// Every trace-impedance probe placed on one net -- unlike EMSResultsImpedance (per absorbing port,
/// derived from S11), this is a direct characteristic-impedance measurement, grouped per net rather
/// than per port since a net can carry more than one probe (see InvolvedNetConfig::probeImpedance()'s
/// own doc comment). A results view averages/bands `probes` itself; this just carries the raw
/// per-probe curves.
@interface EMSResultsNetImpedance : NSObject
@property (nonatomic, copy, readonly) NSString *netName;
@property (nonatomic, copy, readonly) NSArray<EMSResultsNetImpedanceCurve *> *probes;
@end

/// One single-ended trace's group delay vs. frequency.
@interface EMSResultsTrace : NSObject
@property (nonatomic, copy, readonly) NSString *name;
@property (nonatomic, copy, readonly) NSArray<NSNumber *> *delayNs;
@end

/// One received PRBS7 eye. `timeUI` is the common -0.5...1.5 unit-interval axis and each nested
/// traces array is one received two-UI segment. Differential eyes contain the mixed-mode received
/// voltage (P minus N), never separate per-leg traces.
@interface EMSResultsEyeDiagram : NSObject
@property (nonatomic, copy, readonly) NSString *name;
@property (nonatomic, readonly) double bitRateGbps;
@property (nonatomic, readonly, getter=isDifferential) BOOL differential;
@property (nonatomic, copy, readonly) NSArray<NSNumber *> *timeUI;
@property (nonatomic, copy, readonly) NSArray<NSArray<NSNumber *> *> *traces;
@end

/// A renderable snapshot of one simulation's post-processed results -- everything a results view
/// needs to draw charts, with no further C++ types involved.
@interface EMSResultsPreview : NSObject
@property (nonatomic, copy, readonly) NSArray<NSNumber *> *frequenciesGHz;
@property (nonatomic, copy, readonly) NSArray<EMSResultsPort *> *ports;
@property (nonatomic, copy, readonly) NSArray<EMSResultsSParamSet *> *sParamSets;
@property (nonatomic, copy, readonly) NSArray<EMSResultsImpedance *> *impedances;
@property (nonatomic, copy, readonly) NSArray<EMSResultsNetImpedance *> *netImpedances;
@property (nonatomic, copy, readonly) NSArray<EMSResultsSmith *> *smithCharts;
@property (nonatomic, copy, readonly) NSArray<EMSResultsDiffPair *> *diffPairs;
@property (nonatomic, copy, readonly) NSArray<EMSResultsTrace *> *traces;
@property (nonatomic, copy, readonly) NSArray<EMSResultsProbe *> *probes;
@property (nonatomic, copy, readonly) NSArray<EMSResultsEyeDiagram *> *eyeDiagrams;
@end

NS_ASSUME_NONNULL_END
