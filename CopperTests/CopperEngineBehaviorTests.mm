// CopperEngine's own contracts that don't need a CPU reference to check against -- estimateEnergy()
// against an independent naive computation of the identical formula, runWithProbeSampling()'s
// early-exit contract, and the mid-step voltage-correction hook's exact placement in the leapfrog
// (voltage update -> correction -> current update, not after the current update).
#import <XCTest/XCTest.h>

#include <cmath>
#include <memory>

#include "CopperTestFixtures.hpp"
#include "Internal/CopperExcitation.hpp"
#include "Internal/CopperOperator.hpp"
#include "Internal/CopperPhysicalConstants.hpp"
#include "Internal/CopperYeeGrid.hpp"

using namespace copper::test;

@interface CopperEngineBehaviorTests : XCTestCase
@end

@implementation CopperEngineBehaviorTests

/// estimateEnergy() (vDSP_svesq against GPU-shared memory) vs. a naive full-grid CPU computation of
/// the identical EPS0*sum(E^2)+MUE0*sum(H^2) formula, via a genuinely separate code path (plain loop
/// over readField()'s own full-array copies) -- a bug in either implementation is very unlikely to
/// cancel out and pass both.
- (void)testEstimateEnergyMatchesNaiveFullGridComputation {
    const std::unique_ptr<ContinuousStructure> csx(buildTinyVacuumGrid());
    const copper::CopperOperator op(*csx, pulseConfig(150));
    const copper::CopperYeeGrid& grid = op.grid();
    const copper::CopperExcitation& excitation = op.excitation();

    copper::CopperEngine engine(grid, excitation);
    engine.run(20); // real steps, not just a seeded impulse, so both E and H are nonzero
    const double fastEnergy = engine.estimateEnergy();

    double naiveESumSq = 0.0, naiveHSumSq = 0.0;
    const copper::CopperEngine::Field eFields[3] = {copper::CopperEngine::Field::Ex, copper::CopperEngine::Field::Ey,
                                                      copper::CopperEngine::Field::Ez};
    const copper::CopperEngine::Field hFields[3] = {copper::CopperEngine::Field::Hx, copper::CopperEngine::Field::Hy,
                                                      copper::CopperEngine::Field::Hz};
    for (int axis = 0; axis < 3; ++axis) {
        for (float v : engine.readField(eFields[axis])) {
            naiveESumSq += static_cast<double>(v) * static_cast<double>(v);
        }
        for (float v : engine.readField(hFields[axis])) {
            naiveHSumSq += static_cast<double>(v) * static_cast<double>(v);
        }
    }
    const double naiveEnergy = copper::physical::epsilon0 * naiveESumSq + copper::physical::mu0 * naiveHSumSq;

    XCTAssertGreaterThan(naiveEnergy, 0.0, @"fixture excitation never propagated");
    XCTAssertEqualWithAccuracy(fastEnergy, naiveEnergy, 1e-4 * naiveEnergy);
}

/// A brand-new engine's estimateEnergy() must be exactly zero (E=H=0 initial condition).
- (void)testEstimateEnergyIsZeroBeforeAnyStep {
    const std::unique_ptr<ContinuousStructure> csx(buildPecCavityNoExcitation());
    const copper::CopperOperator op(*csx, pulseConfig(10));
    const copper::CopperYeeGrid& grid = op.grid();
    copper::CopperEngine engine(grid);
    XCTAssertEqualWithAccuracy(engine.estimateEnergy(), 0.0, 0.0);
}

/// runWithProbeSampling()'s early-exit contract: returning false after N calls must leave the
/// engine's field state bit-identical to a plain run(N) -- not run() the full requested step count
/// regardless of what the sampler returns.
- (void)testRunWithProbeSamplingStopsExactlyWhenSamplerReturnsFalse {
    const std::unique_ptr<ContinuousStructure> csx(buildTinyVacuumGrid());
    const copper::CopperOperator op(*csx, pulseConfig(150));
    const copper::CopperYeeGrid& grid = op.grid();
    const copper::CopperExcitation& excitation = op.excitation();

    copper::CopperEngine stoppedEarly(grid, excitation);
    std::uint32_t callCount = 0;
    stoppedEarly.runWithProbeSampling(50, [&](std::uint32_t) -> bool {
        ++callCount;
        return callCount < 7; // stop after the 7th call
    });
    XCTAssertEqual(callCount, 7U);

    copper::CopperEngine ranSeven(grid, excitation);
    ranSeven.run(7);

    for (const copper::CopperEngine::Field field : kAllFields) {
        const std::vector<float> a = stoppedEarly.readField(field);
        const std::vector<float> b = ranSeven.readField(field);
        XCTAssertEqual(a.size(), b.size());
        for (std::size_t i = 0; i < a.size(); ++i) {
            XCTAssertEqual(a[i], b[i], @"early-exit-at-7 field state doesn't bit-match a plain run(7)");
        }
    }
}

/// A mid-step E correction must feed the *same* timestep's H update -- update_h_interior's Hx curl
/// at (1,1,1) directly consumes Ez(1,1,1); with a post-H callback instead of a mid-step one, this
/// write would arrive one timestep too late and Hx would stay zero.
- (void)testMidStepCorrectionFeedsSameTimestepCurrentUpdate {
    const std::unique_ptr<ContinuousStructure> csx(buildPecCavityNoExcitation());
    const copper::CopperOperator op(*csx, pulseConfig(1));
    const copper::CopperYeeGrid& grid = op.grid();

    copper::CopperEngine corrected(grid);
    std::uint32_t correctionCalls = 0;
    corrected.runWithProbeSampling(
        1, [](std::uint32_t) { return true; },
        [&]() {
            ++correctionCalls;
            corrected.writeFieldCell(copper::CopperEngine::Field::Ez, 1, 1, 1, 1.0F);
        });

    XCTAssertEqual(correctionCalls, 1U);
    const float transportedCurrent = corrected.readFieldCell(copper::CopperEngine::Field::Hx, 1, 1, 1);
    XCTAssertNotEqual(transportedCurrent, 0.0F,
                      @"current update did not consume the same timestep's corrected voltage");
}

/// Omitting the mid-step correction entirely (the default, nullptr) must behave exactly like run()
/// for the same step count -- the correction hook must be strictly additive, not change ordinary
/// leapfrog behavior when unused.
- (void)testRunWithProbeSamplingWithoutCorrectionMatchesPlainRun {
    const std::unique_ptr<ContinuousStructure> csx(buildTinyVacuumGrid());
    const copper::CopperOperator op(*csx, pulseConfig(50));
    const copper::CopperYeeGrid& grid = op.grid();
    const copper::CopperExcitation& excitation = op.excitation();

    copper::CopperEngine sampled(grid, excitation);
    sampled.runWithProbeSampling(10, [](std::uint32_t) { return true; });

    copper::CopperEngine plain(grid, excitation);
    plain.run(10);

    for (const copper::CopperEngine::Field field : kAllFields) {
        const std::vector<float> a = sampled.readField(field);
        const std::vector<float> b = plain.readField(field);
        for (std::size_t i = 0; i < a.size(); ++i) {
            XCTAssertEqual(a[i], b[i]);
        }
    }
}

@end
