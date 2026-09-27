// Backend::CPU coverage, mirroring CopperEngineParityTests.mm's own Backend::Metal-vs-real-CPU-
// openEMS-Engine checks exactly (same fixtures, same tolerances, same methodology) so both backends
// are independently verified against the same ground truth -- plus a direct Copper-vs-Copper check
// (Metal backend vs. CPU backend, on the identical grid/stimulus, no openEMS involved at all) for a
// second, more direct confirmation that the two share the same answer, not just the same reference.
#import <XCTest/XCTest.h>

#include <cmath>
#include <limits>

#include "CopperTestFixtures.hpp"
#include "Internal/CopperCPML.hpp"
#include "Internal/CopperExcitation.hpp"
#include "Internal/CopperLumpedRLC.hpp"
#include "Internal/CopperOpenEMSAccess.hpp"
#include "Internal/CopperOperator.hpp"
#include "Internal/CopperYeeGrid.hpp"
#include "tools/constants.h"

using namespace copper::test;

@interface CopperCPUEngineParityTests : XCTestCase
@end

@implementation CopperCPUEngineParityTests

- (void)testInteriorLeapfrogMatchesCPUEngineAfterHandSeededImpulse {
    copper::CopperOpenEMS fdtd;
    fdtd.SetCSX(buildPecCavityNoExcitation());
    fdtd.SetGaussExcite(2.5e9, 2.5e9);
    for (int side = 0; side < 6; ++side) {
        fdtd.Set_BC_Type(side, 0);
    }
    fdtd.SetNumberOfTimeSteps(10);
    XCTAssertEqual(fdtd.SetupFDTD(), 0);

    Operator* op = fdtd.GetOperatorForGPU();
    Engine* cpuEngine = fdtd.GetEngineForCPU();
    XCTAssertTrue(op != nullptr && cpuEngine != nullptr);

    const copper::CopperYeeGrid grid = copper::buildYeeGrid(*op);
    copper::CopperEngine cpuBackend(grid, {}, {}, copper::CopperEngine::Backend::CPU);

    const std::uint32_t seedX = 5, seedY = 5, seedZ = 1;
    cpuBackend.writeFieldCell(copper::CopperEngine::Field::Ez, seedX, seedY, seedZ, 1.0F);
    cpuEngine->SetVolt(2, seedX, seedY, seedZ, 1.0F);

    const std::uint32_t steps = 5;
    cpuBackend.run(steps);
    cpuEngine->IterateTS(steps);

    const FieldParityResult diff = compareGpuCpuFields(cpuBackend, *cpuEngine, grid.dims);
    XCTAssertTrue(diff.anyNonzero);
    const float tolerance = 1e-5F * std::max(diff.maxAbsValue, 1.0F);
    XCTAssertLessThanOrEqual(diff.maxAbsDiff, tolerance);
}

- (void)testExcitationKernelMatchesCPUEngineOverAFullRun {
    copper::CopperOpenEMS fdtd;
    fdtd.SetCSX(buildTinyVacuumGrid());
    fdtd.SetGaussExcite(2.5e9, 2.5e9);
    for (int side = 0; side < 6; ++side) {
        fdtd.Set_BC_Type(side, 0);
    }
    fdtd.SetNumberOfTimeSteps(150);
    XCTAssertEqual(fdtd.SetupFDTD(), 0);

    Operator* op = fdtd.GetOperatorForGPU();
    Engine* cpuEngine = fdtd.GetEngineForCPU();
    XCTAssertTrue(op != nullptr && cpuEngine != nullptr);

    const copper::CopperYeeGrid grid = copper::buildYeeGrid(*op);
    const copper::CopperExcitation excitation = copper::buildExcitation(*op);
    copper::CopperEngine cpuBackend(grid, excitation, {}, copper::CopperEngine::Backend::CPU);

    const std::uint32_t steps = 100;
    cpuBackend.run(steps);
    cpuEngine->IterateTS(steps);

    const FieldParityResult diff = compareGpuCpuFields(cpuBackend, *cpuEngine, grid.dims);
    XCTAssertTrue(diff.anyNonzero, @"fixture excitation never landed on the CPU reference engine");
    const float tolerance = 1e-4F * std::max(diff.maxAbsValue, 1.0F);
    XCTAssertLessThanOrEqual(diff.maxAbsDiff, tolerance);
}

- (void)testZeroStepsLeavesFieldsAtZeroInitialCondition {
    copper::CopperOpenEMS fdtd;
    fdtd.SetCSX(buildPecCavityNoExcitation());
    fdtd.SetGaussExcite(2.5e9, 2.5e9);
    for (int side = 0; side < 6; ++side) {
        fdtd.Set_BC_Type(side, 0);
    }
    fdtd.SetNumberOfTimeSteps(10);
    XCTAssertEqual(fdtd.SetupFDTD(), 0);
    Operator* op = fdtd.GetOperatorForGPU();
    const copper::CopperYeeGrid grid = copper::buildYeeGrid(*op);
    copper::CopperEngine cpuBackend(grid, {}, {}, copper::CopperEngine::Backend::CPU);
    cpuBackend.run(0);

    for (const copper::CopperEngine::Field field : kAllFields) {
        for (const float v : cpuBackend.readField(field)) {
            XCTAssertEqual(v, 0.0F);
        }
    }
}

/// Direct Copper-vs-Copper check: Metal and CPU backends built from the identical grid/excitation,
/// stepped the same number of iterations, diffed against *each other* -- no openEMS reference
/// involved at all. Both already independently match the real CPU engine (the tests above and in
/// CopperEngineParityTests.mm), so this is a second, more direct confirmation, and the one a future
/// hybrid CPU+GPU run over one grid would need to hold for the two backends' outputs to be
/// interchangeable.
- (void)testMetalAndCPUBackendsAgreeWithEachOtherDirectly {
    copper::CopperOpenEMS fdtd;
    fdtd.SetCSX(buildTinyVacuumGrid());
    fdtd.SetGaussExcite(2.5e9, 2.5e9);
    for (int side = 0; side < 6; ++side) {
        fdtd.Set_BC_Type(side, 0);
    }
    fdtd.SetNumberOfTimeSteps(150);
    XCTAssertEqual(fdtd.SetupFDTD(), 0);
    Operator* op = fdtd.GetOperatorForGPU();
    XCTAssertTrue(op != nullptr);

    const copper::CopperYeeGrid grid = copper::buildYeeGrid(*op);
    const copper::CopperExcitation excitation = copper::buildExcitation(*op);

    copper::CopperEngine metalBackend(grid, excitation, {}, copper::CopperEngine::Backend::Metal);
    copper::CopperEngine cpuBackend(grid, excitation, {}, copper::CopperEngine::Backend::CPU);

    const std::uint32_t steps = 100;
    metalBackend.run(steps);
    cpuBackend.run(steps);

    float maxAbsDiff = 0.0F;
    float maxAbsValue = 0.0F;
    bool anyNonzero = false;
    for (const copper::CopperEngine::Field field : kAllFields) {
        const std::vector<float> metalField = metalBackend.readField(field);
        const std::vector<float> cpuField = cpuBackend.readField(field);
        XCTAssertEqual(metalField.size(), cpuField.size());
        for (std::size_t i = 0; i < metalField.size(); ++i) {
            maxAbsDiff = std::max(maxAbsDiff, std::fabs(metalField[i] - cpuField[i]));
            maxAbsValue = std::max(maxAbsValue, std::fabs(cpuField[i]));
            if (cpuField[i] != 0.0F) {
                anyNonzero = true;
            }
        }
    }
    XCTAssertTrue(anyNonzero, @"both backends' fields are still zero -- excitation never landed");
    const float tolerance = 1e-4F * std::max(maxAbsValue, 1.0F);
    XCTAssertLessThanOrEqual(maxAbsDiff, tolerance);
}

/// CPU counterpart of CopperCPMLTests' own stability check -- no CPU (openEMS) reference exists for
/// CPML at all (see that file's own comment), so this is the same sanity bar: a seeded impulse
/// absorbed by a CPML boundary must decay, not grow, and stay finite throughout.
- (void)testCPMLAbsorbsSeededImpulseWithoutGrowingEnergyOrProducingNonFiniteValues {
    copper::CopperOpenEMS fdtd;
    fdtd.SetCSX(buildCpmlCavityNoExcitation());
    fdtd.SetGaussExcite(2.5e9, 2.5e9);
    for (int side = 0; side < 6; ++side) {
        fdtd.Set_BC_Type(side, 2); // MUR -- never Set_BC_PML() for a CPML run, see CopperCPML.hpp
    }
    fdtd.SetNumberOfTimeSteps(30);
    XCTAssertEqual(fdtd.SetupFDTD(), 0);
    copper::CopperOperator::Config config; // boundary stays Open (MUR) on every face
    config.f0 = 2.5e9;
    config.fc = 2.5e9;
    config.maxTimesteps = 30;
    copper::CopperOperator newOp(*buildCpmlCavityNoExcitation(), config);

    constexpr std::uint32_t kPmlDepthCellsForTest = 8;
    const copper::CopperYeeGrid& grid = newOp.grid();
    const double alphaMax = 2 * M_PI * 100e6 * EPS0;
    const std::vector<copper::CopperCPMLShell> shells =
        copper::buildCPMLShells(newOp, alphaMax, kPmlDepthCellsForTest);
    XCTAssertEqual(shells.size(), static_cast<std::size_t>(6));
    copper::CopperEngine engine(grid, {}, shells, copper::CopperEngine::Backend::CPU);

    const std::uint32_t seedX = 6, seedY = 15, seedZ = 15;
    engine.writeFieldCell(copper::CopperEngine::Field::Ez, seedX, seedY, seedZ, 1.0F);

    const double energyAtStart = engine.estimateEnergy();
    engine.run(60);
    const double energyAfter = engine.estimateEnergy();

    for (const copper::CopperEngine::Field field : kAllFields) {
        for (const float v : engine.readField(field)) {
            XCTAssertTrue(std::isfinite(v), @"CPML run produced a non-finite field value");
        }
    }
    XCTAssertLessThanOrEqual(energyAfter, energyAtStart);
}

/// CPU counterpart of CopperLumpedRLCTests' own backend-parity check -- the mid-step ADE correction
/// (CopperFDTDRunner.cpp's own applyLumpedRLC, reimplemented identically here) exercises
/// runWithProbeSampling()'s midStepCorrection hook, which the CPU backend implements by simply
/// running its voltage phase, calling the correction, then its current phase -- no GPU fence needed,
/// but the same two-phase split as Metal, so this also confirms that split itself is correct on CPU.
- (void)testLumpedRLCCorrectionMatchesCPUEngineOverAFullRun {
    ContinuousStructure* csx = buildSeriesLumpedRLCFixture(50.0, std::numeric_limits<double>::quiet_NaN(),
                                                             std::numeric_limits<double>::quiet_NaN());
    copper::CopperOpenEMS fdtd;
    fdtd.SetCSX(csx);
    fdtd.SetGaussExcite(2.5e9, 2.5e9);
    for (int side = 0; side < 6; ++side) {
        fdtd.Set_BC_Type(side, 0);
    }
    fdtd.SetNumberOfTimeSteps(10);
    XCTAssertEqual(fdtd.SetupFDTD(), 0);
    Engine* cpuEngine = fdtd.GetEngineForCPU();
    XCTAssertTrue(cpuEngine != nullptr);

    copper::CopperOperator::Config config;
    for (int side = 0; side < 6; ++side) {
        config.boundary[static_cast<std::size_t>(side)] = copper::CopperOperator::BoundaryType::PEC;
    }
    config.f0 = 2.5e9;
    config.fc = 2.5e9;
    config.maxTimesteps = 10;
    copper::CopperOperator newOp(*csx, config);
    const copper::CopperYeeGrid& grid = newOp.grid();
    const std::vector<copper::CopperLumpedRLCCell> lumpedRLC = copper::discoverLumpedRLC(*csx, grid, newOp);
    XCTAssertEqual(lumpedRLC.size(), static_cast<std::size_t>(1));

    copper::CopperEngine cpuBackend(grid, {}, {}, copper::CopperEngine::Backend::CPU);
    cpuBackend.writeFieldCell(copper::CopperEngine::Field::Ez, 5, 5, 0, 1.0F);
    cpuEngine->SetVolt(2, 5, 5, 0, 1.0F);

    struct LumpedRLCState {
        double vdn[3] = {0.0, 0.0, 0.0};
        double jn[3] = {0.0, 0.0, 0.0};
    };
    std::vector<LumpedRLCState> state(lumpedRLC.size());
    const copper::CopperEngine::MidStepCorrection applyLumpedRLC = [&]() {
        for (std::size_t i = 0; i < lumpedRLC.size(); ++i) {
            const copper::CopperLumpedRLCCell& cell = lumpedRLC[i];
            LumpedRLCState& s = state[i];
            s.vdn[2] = s.vdn[1];
            s.vdn[1] = s.vdn[0];
            s.jn[2] = s.jn[1];
            s.jn[1] = s.jn[0];

            const auto field = static_cast<copper::CopperEngine::Field>(cell.axis);
            double vdn0 = static_cast<double>(cpuBackend.readFieldCell(field, cell.x, cell.y, cell.z));
            vdn0 = static_cast<double>(cell.vvd) *
                   (vdn0 + static_cast<double>(cell.vv2) * s.vdn[2] + static_cast<double>(cell.vj1) * s.jn[1] +
                    static_cast<double>(cell.vj2) * s.jn[2]);
            s.jn[0] = static_cast<double>(cell.ib0) * (vdn0 - s.vdn[2]) -
                      static_cast<double>(cell.b1) * static_cast<double>(cell.ib0) * s.jn[1] -
                      static_cast<double>(cell.b2) * static_cast<double>(cell.ib0) * s.jn[2];
            s.vdn[0] = vdn0;
            cpuBackend.writeFieldCell(field, cell.x, cell.y, cell.z, static_cast<float>(vdn0));
        }
    };

    const std::uint32_t steps = 8;
    cpuBackend.runWithProbeSampling(
        steps, [](std::uint32_t) { return true; }, applyLumpedRLC);
    cpuEngine->IterateTS(steps);

    const FieldParityResult diff = compareGpuCpuFields(cpuBackend, *cpuEngine, grid.dims);
    XCTAssertTrue(diff.anyNonzero);
    const float tolerance = 1e-4F * std::max(diff.maxAbsValue, 1.0F);
    XCTAssertLessThanOrEqual(diff.maxAbsDiff, tolerance);
}

@end
