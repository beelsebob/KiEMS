// Objective-C interface over the full geometry -> simulate -> postprocess pipeline (running a real
// FDTD simulation) and a renderable snapshot of its result. Swift-visible; never exposes a C++
// type. Mirrors GeometryPreviewBridge.h's own shape one stage further down the pipeline.
#import <Foundation/Foundation.h>

#import "EMSConfigBridge.h"

NS_ASSUME_NONNULL_BEGIN

/// One resolved simulation port -- mirrors gerber2ems::PortConfig's display-relevant fields.
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

/// One single-ended trace's group delay vs. frequency.
@interface EMSResultsTrace : NSObject
@property (nonatomic, copy, readonly) NSString *name;
@property (nonatomic, copy, readonly) NSArray<NSNumber *> *delayNs;
@end

/// A renderable snapshot of one simulation's post-processed results -- everything a results view
/// needs to draw charts, with no further C++ types involved.
@interface EMSResultsPreview : NSObject
@property (nonatomic, copy, readonly) NSArray<NSNumber *> *frequenciesGHz;
@property (nonatomic, copy, readonly) NSArray<EMSResultsPort *> *ports;
@property (nonatomic, copy, readonly) NSArray<EMSResultsSParamSet *> *sParamSets;
@property (nonatomic, copy, readonly) NSArray<EMSResultsImpedance *> *impedances;
@property (nonatomic, copy, readonly) NSArray<EMSResultsSmith *> *smithCharts;
@property (nonatomic, copy, readonly) NSArray<EMSResultsDiffPair *> *diffPairs;
@property (nonatomic, copy, readonly) NSArray<EMSResultsTrace *> *traces;
@end

/// Runs the real geometry -> simulate -> postprocess pipeline (kicad-cli gerber export, stackup
/// import, port resolution, GeometryResult::build, a full FDTD run per excited port,
/// PostprocessResult::compute -- the same steps `geber2ems -g -s -p` performs) for one simulation,
/// then derives a renderable snapshot of its result. Synchronous and potentially very slow (a real
/// FDTD run can take minutes to hours, with no progress callback) -- callers must run this off the
/// main thread.
@interface EMSResultsStepBridge : NSObject

+ (nullable EMSResultsPreview *)runResultsStepForSimulationNamed:(NSString *)simulationName
                                                            config:(EMSConfigBridge *)config
                                                        packageDir:(NSString *)packageDir
                                                      kicadCliPath:(NSString *)kicadCliPath
                                              kicadQueryHelperPath:(NSString *)helperPath
                                                    fdtdWorkerPath:(NSString *)workerPath
                                                             error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
