#import "SimulationResultsBridge.h"
#import "SimulationResultsBridge+Private.h"

#include <algorithm>
#include <cmath>
#include <complex>
#include <string>
#include <vector>

#include "gerber2ems/config.hpp"
#include "gerber2ems/postprocess.hpp"

using gerber2ems::Postprocessor;
using gerber2ems::SimulationConfig;

namespace {

// Non-finite values are a real possibility in this data, not just a theoretical edge case: an
// S-parameter magnitude of exactly 0 makes 20*log10(...) equal to -Infinity, and impedance
// (Z = Z0*(1+S)/(1-S)) diverges toward Infinity as S approaches 1 -- a physically meaningful case
// for a badly-matched or open port, not a computation bug. GerberCharts' own Core Graphics drawing
// doesn't degrade gracefully on NaN/Infinite coordinates -- matplot++'s gnuplot backend (the CLI's
// own PNG renderer, same underlying formulas) evidently tolerates it, but nothing here can assume
// that. Clamped to a bound far outside any value these units (dB/Ohm/degrees/ns) could legitimately
// take, rather than dropped, so the curve still renders with an obvious spike instead of silently
// losing a point.
double sanitizeForChart(double value) {
    if (std::isnan(value)) {
        return 0.0;
    }
    constexpr double kFiniteBound = 1e6;
    return std::clamp(value, -kFiniteBound, kFiniteBound);
}

NSArray<NSNumber*>* toNSArray(const std::vector<double>& values, double scale = 1.0) {
    NSMutableArray<NSNumber*>* result = [NSMutableArray arrayWithCapacity:values.size()];
    for (double v : values) {
        [result addObject:@(sanitizeForChart(v * scale))];
    }
    return result;
}

// "Response at <FootprintRef> pin <PadNumber>" rather than postprocess.cpp's own "S_{ji}" notation
// (see its _sLabel) -- the CLI's plots are read by someone who already knows S-parameter notation;
// this app's results view can't assume that, and the underlying port names (see port_resolution.cpp)
// already carry exactly the identifying information (footprint + pin) needed to name a curve by
// what it physically measures instead.
NSString* responseLabel(const gerber2ems::PortConfig& measuredPort) {
    return [NSString stringWithFormat:@"Response at %s pin %s", measuredPort.footprintRef().c_str(),
                                        measuredPort.padNumber().c_str()];
}

} // namespace

@implementation EMSResultsPort
- (instancetype)initWithName:(NSString*)name
                        index:(NSInteger)index
                 impedanceOhm:(double)impedanceOhm
                     dBMargin:(double)dBMargin
                      excited:(BOOL)excited {
    self = [super init];
    if (self) {
        _name = [name copy];
        _index = index;
        _impedanceOhm = impedanceOhm;
        _dBMargin = dBMargin;
        _excited = excited;
    }
    return self;
}
@end

@implementation EMSResultsSParamCurve
- (instancetype)initWithOutputPort:(NSInteger)outputPort
                              label:(NSString*)label
                        magnitudeDb:(NSArray<NSNumber*>*)magnitudeDb
                           phaseDeg:(NSArray<NSNumber*>*)phaseDeg {
    self = [super init];
    if (self) {
        _outputPort = outputPort;
        _label = [label copy];
        _magnitudeDb = [magnitudeDb copy];
        _phaseDeg = [phaseDeg copy];
    }
    return self;
}
@end

@implementation EMSResultsSParamSet
- (instancetype)initWithExcitedPort:(NSInteger)excitedPort curves:(NSArray<EMSResultsSParamCurve*>*)curves {
    self = [super init];
    if (self) {
        _excitedPort = excitedPort;
        _curves = [curves copy];
    }
    return self;
}
@end

@implementation EMSResultsImpedance
- (instancetype)initWithPort:(NSInteger)port
                magnitudeOhm:(NSArray<NSNumber*>*)magnitudeOhm
                    angleDeg:(NSArray<NSNumber*>*)angleDeg {
    self = [super init];
    if (self) {
        _port = port;
        _magnitudeOhm = [magnitudeOhm copy];
        _angleDeg = [angleDeg copy];
    }
    return self;
}
@end

@implementation EMSResultsSmith
- (instancetype)initWithPort:(NSInteger)port
                      reGamma:(NSArray<NSNumber*>*)reGamma
                      imGamma:(NSArray<NSNumber*>*)imGamma
              vswrMarginGamma:(double)vswrMarginGamma {
    self = [super init];
    if (self) {
        _port = port;
        _reGamma = [reGamma copy];
        _imGamma = [imGamma copy];
        _vswrMarginGamma = vswrMarginGamma;
    }
    return self;
}
@end

@implementation EMSResultsDiffPair
- (instancetype)initWithName:(NSString*)name
                      sdd11Db:(nullable NSArray<NSNumber*>*)sdd11Db
                      sdd21Db:(nullable NSArray<NSNumber*>*)sdd21Db
        impedanceMagnitudeOhm:(nullable NSArray<NSNumber*>*)impedanceMagnitudeOhm
            impedanceAngleDeg:(nullable NSArray<NSNumber*>*)impedanceAngleDeg
                     nDelayNs:(nullable NSArray<NSNumber*>*)nDelayNs
                     pDelayNs:(nullable NSArray<NSNumber*>*)pDelayNs {
    self = [super init];
    if (self) {
        _name = [name copy];
        _sdd11Db = [sdd11Db copy];
        _sdd21Db = [sdd21Db copy];
        _impedanceMagnitudeOhm = [impedanceMagnitudeOhm copy];
        _impedanceAngleDeg = [impedanceAngleDeg copy];
        _nDelayNs = [nDelayNs copy];
        _pDelayNs = [pDelayNs copy];
    }
    return self;
}
@end

@implementation EMSResultsProbeCurve
- (instancetype)initWithExcitedPort:(NSInteger)excitedPort
                    voltageMagnitude:(NSArray<NSNumber*>*)voltageMagnitude
                    currentMagnitude:(NSArray<NSNumber*>*)currentMagnitude {
    self = [super init];
    if (self) {
        _excitedPort = excitedPort;
        _voltageMagnitude = [voltageMagnitude copy];
        _currentMagnitude = [currentMagnitude copy];
    }
    return self;
}
@end

@implementation EMSResultsProbe
- (instancetype)initWithName:(NSString*)name index:(NSInteger)index curves:(NSArray<EMSResultsProbeCurve*>*)curves {
    self = [super init];
    if (self) {
        _name = [name copy];
        _index = index;
        _curves = [curves copy];
    }
    return self;
}
@end

@implementation EMSResultsTrace
- (instancetype)initWithName:(NSString*)name delayNs:(NSArray<NSNumber*>*)delayNs {
    self = [super init];
    if (self) {
        _name = [name copy];
        _delayNs = [delayNs copy];
    }
    return self;
}
@end

@implementation EMSResultsPreview
- (instancetype)initWithFrequenciesGHz:(NSArray<NSNumber*>*)frequenciesGHz
                                  ports:(NSArray<EMSResultsPort*>*)ports
                             sParamSets:(NSArray<EMSResultsSParamSet*>*)sParamSets
                             impedances:(NSArray<EMSResultsImpedance*>*)impedances
                            smithCharts:(NSArray<EMSResultsSmith*>*)smithCharts
                              diffPairs:(NSArray<EMSResultsDiffPair*>*)diffPairs
                                 traces:(NSArray<EMSResultsTrace*>*)traces
                                 probes:(NSArray<EMSResultsProbe*>*)probes {
    self = [super init];
    if (self) {
        _frequenciesGHz = [frequenciesGHz copy];
        _ports = [ports copy];
        _sParamSets = [sParamSets copy];
        _impedances = [impedances copy];
        _smithCharts = [smithCharts copy];
        _diffPairs = [diffPairs copy];
        _traces = [traces copy];
        _probes = [probes copy];
    }
    return self;
}
@end

EMSResultsPreview* buildResultsPreview(Postprocessor& postprocessor, const SimulationConfig& simConfig) {
    const auto portCount = static_cast<std::int32_t>(simConfig.ports().size());

    NSArray<NSNumber*>* freqsGHz = toNSArray(postprocessor.frequencies(), 1e-9);

    NSMutableArray<EMSResultsPort*>* ports = [NSMutableArray arrayWithCapacity:simConfig.ports().size()];
    for (std::int32_t i = 0; i < portCount; ++i) {
        const auto& port = simConfig.ports()[static_cast<std::size_t>(i)];
        [ports addObject:[[EMSResultsPort alloc] initWithName:@(port.name().c_str())
                                                          index:i
                                                   impedanceOhm:port.impedance()
                                                       dBMargin:port.dBMargin()
                                                        excited:port.excite()]];
    }

    NSMutableArray<EMSResultsSParamSet*>* sParamSets = [NSMutableArray array];
    NSMutableArray<EMSResultsSmith*>* smithCharts = [NSMutableArray array];
    for (std::int32_t i = 0; i < portCount; ++i) {
        if (!simConfig.ports()[static_cast<std::size_t>(i)].excite()) {
            continue;
        }
        const auto selfParam = postprocessor.getSParam(i, i);
        if (!selfParam.has_value()) {
            continue;
        }

        NSMutableArray<EMSResultsSParamCurve*>* curves = [NSMutableArray array];
        for (std::int32_t j = 0; j < portCount; ++j) {
            const auto sParam = postprocessor.getSParam(j, i);
            if (!sParam.has_value()) {
                continue;
            }
            std::vector<double> magDb(sParam->size());
            for (std::size_t f = 0; f < sParam->size(); ++f) {
                magDb[f] = 20 * std::log10(std::abs((*sParam)[f]));
            }
            const std::vector<double> phaseDeg = gerber2ems::unwrapPhaseDegrees(*sParam);
            [curves addObject:[[EMSResultsSParamCurve alloc]
                                   initWithOutputPort:j
                                                 label:responseLabel(simConfig.ports()[static_cast<std::size_t>(j)])
                                           magnitudeDb:toNSArray(magDb)
                                              phaseDeg:toNSArray(phaseDeg)]];
        }
        [sParamSets addObject:[[EMSResultsSParamSet alloc] initWithExcitedPort:i curves:curves]];

        // Same 2-line VSWR-margin-circle formula renderSmith (postprocess.cpp) uses -- trivial
        // enough not to warrant its own C++ accessor (see this file's header doc comment).
        std::vector<double> reGamma(selfParam->size());
        std::vector<double> imGamma(selfParam->size());
        for (std::size_t f = 0; f < selfParam->size(); ++f) {
            reGamma[f] = (*selfParam)[f].real();
            imGamma[f] = (*selfParam)[f].imag();
        }
        const double s11Margin = simConfig.ports()[static_cast<std::size_t>(i)].dBMargin();
        const double vswrMargin = (std::pow(10.0, s11Margin / 20.0) + 1) / (std::pow(10.0, s11Margin / 20.0) - 1);
        // A 0dB margin makes vswrMargin's own denominator (and this one) exactly 0 -- Infinity/NaN,
        // not just a large number -- see toNSArray's sanitizeForChart comment for why that can't be
        // handed to Core Graphics as-is.
        const double vswrGamma = sanitizeForChart(std::abs((vswrMargin - 1) / (vswrMargin + 1)));
        [smithCharts addObject:[[EMSResultsSmith alloc] initWithPort:i
                                                               reGamma:toNSArray(reGamma)
                                                               imGamma:toNSArray(imGamma)
                                                       vswrMarginGamma:vswrGamma]];
    }

    NSMutableArray<EMSResultsImpedance*>* impedances = [NSMutableArray array];
    for (std::int32_t i = 0; i < portCount; ++i) {
        const auto impedance = postprocessor.getImpedance(i);
        if (!impedance.has_value()) {
            continue;
        }
        std::vector<double> magOhm(impedance->size());
        std::vector<double> angleDeg(impedance->size());
        for (std::size_t f = 0; f < impedance->size(); ++f) {
            magOhm[f] = std::abs((*impedance)[f]);
            angleDeg[f] = std::arg((*impedance)[f]) * 180.0 / M_PI;
        }
        [impedances addObject:[[EMSResultsImpedance alloc] initWithPort:i
                                                             magnitudeOhm:toNSArray(magOhm)
                                                                 angleDeg:toNSArray(angleDeg)]];
    }

    NSMutableArray<EMSResultsDiffPair*>* diffPairs = [NSMutableArray array];
    for (std::size_t idx = 0; idx < simConfig.diffPairs().size(); ++idx) {
        const auto& pair = simConfig.diffPairs()[idx];
        if (!pair.correct()) {
            continue;
        }
        const auto sdd = postprocessor.getDiffPairSdd(static_cast<std::int32_t>(idx));
        const auto diffZ = postprocessor.getDiffPairImpedance(static_cast<std::int32_t>(idx));

        NSArray<NSNumber*>* sdd11 = (sdd.has_value() && sdd->sdd11Db.has_value()) ? toNSArray(*sdd->sdd11Db) : nil;
        NSArray<NSNumber*>* sdd21 = (sdd.has_value() && sdd->sdd21Db.has_value()) ? toNSArray(*sdd->sdd21Db) : nil;
        NSArray<NSNumber*>* zMag = diffZ.has_value() ? toNSArray(diffZ->magnitudeOhm) : nil;
        NSArray<NSNumber*>* zAngle = diffZ.has_value() ? toNSArray(diffZ->angleDeg) : nil;

        NSArray<NSNumber*>* nDelay = nil;
        if (pair.startN().resolvedIndex().has_value() && pair.stopN().resolvedIndex().has_value()) {
            if (const auto d = postprocessor.getDelay(*pair.stopN().resolvedIndex(), *pair.startN().resolvedIndex());
                d.has_value()) {
                nDelay = toNSArray(*d, 1e9);
            }
        }
        NSArray<NSNumber*>* pDelay = nil;
        if (pair.startP().resolvedIndex().has_value() && pair.stopP().resolvedIndex().has_value()) {
            if (const auto d = postprocessor.getDelay(*pair.stopP().resolvedIndex(), *pair.startP().resolvedIndex());
                d.has_value()) {
                pDelay = toNSArray(*d, 1e9);
            }
        }

        if (sdd11 == nil && sdd21 == nil && zMag == nil && nDelay == nil && pDelay == nil) {
            continue;
        }
        NSString* name = pair.name().has_value() ? @(pair.name()->c_str())
                                                   : [NSString stringWithFormat:@"Diff Pair %zu", idx + 1];
        [diffPairs addObject:[[EMSResultsDiffPair alloc] initWithName:name
                                                                sdd11Db:sdd11
                                                                sdd21Db:sdd21
                                                  impedanceMagnitudeOhm:zMag
                                                      impedanceAngleDeg:zAngle
                                                               nDelayNs:nDelay
                                                               pDelayNs:pDelay]];
    }

    NSMutableArray<EMSResultsProbe*>* probes = [NSMutableArray array];
    for (std::int32_t i = 0; i < portCount; ++i) {
        if (simConfig.ports()[static_cast<std::size_t>(i)].absorbSignal()) {
            continue;
        }
        NSMutableArray<EMSResultsProbeCurve*>* curves = [NSMutableArray array];
        for (std::int32_t exc = 0; exc < portCount; ++exc) {
            const auto voltage = postprocessor.getProbeVoltage(i, exc);
            const auto current = postprocessor.getProbeCurrent(i, exc);
            if (!voltage.has_value() || !current.has_value()) {
                continue;
            }
            std::vector<double> vMag(voltage->size());
            std::vector<double> iMag(current->size());
            for (std::size_t f = 0; f < voltage->size(); ++f) {
                vMag[f] = std::abs((*voltage)[f]);
                iMag[f] = std::abs((*current)[f]);
            }
            [curves addObject:[[EMSResultsProbeCurve alloc] initWithExcitedPort:exc
                                                                 voltageMagnitude:toNSArray(vMag)
                                                                 currentMagnitude:toNSArray(iMag)]];
        }
        if (curves.count == 0) {
            continue;
        }
        const auto& port = simConfig.ports()[static_cast<std::size_t>(i)];
        [probes addObject:[[EMSResultsProbe alloc] initWithName:@(port.name().c_str()) index:i curves:curves]];
    }

    NSMutableArray<EMSResultsTrace*>* traces = [NSMutableArray array];
    for (std::size_t idx = 0; idx < simConfig.traces().size(); ++idx) {
        const auto& trace = simConfig.traces()[idx];
        if (!trace.correct() || !trace.start().resolvedIndex().has_value() || !trace.stop().resolvedIndex().has_value()) {
            continue;
        }
        const auto d = postprocessor.getDelay(*trace.stop().resolvedIndex(), *trace.start().resolvedIndex());
        if (!d.has_value()) {
            continue;
        }
        NSString* name = trace.name().has_value() ? @(trace.name()->c_str())
                                                    : [NSString stringWithFormat:@"Trace %zu", idx + 1];
        [traces addObject:[[EMSResultsTrace alloc] initWithName:name delayNs:toNSArray(*d, 1e9)]];
    }

    return [[EMSResultsPreview alloc] initWithFrequenciesGHz:freqsGHz
                                                        ports:ports
                                                   sParamSets:sParamSets
                                                   impedances:impedances
                                                  smithCharts:smithCharts
                                                    diffPairs:diffPairs
                                                       traces:traces
                                                       probes:probes];
}
