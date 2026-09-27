// GPU-vs-CPU field parity tests -- the centerpiece "verify backends are correct" checks: run
// Copper's Metal CopperEngine and the real CPU openEMS Engine on the identical grid/stimulus, then
// diff every field cell. These are the tests a future CPU CopperEngine backend must also pass (with
// the real openEMS Engine swapped out for whatever's under test) before it can be trusted as a
// drop-in replacement for the Metal one.
#import <XCTest/XCTest.h>

#include <cmath>

#include "CopperTestFixtures.hpp"
#include "Internal/CopperExcitation.hpp"
#include "Internal/CopperOpenEMSAccess.hpp"
#include "Internal/CopperYeeGrid.hpp"

using namespace copper::test;

@interface CopperEngineParityTests : XCTestCase
@end

@implementation CopperEngineParityTests

/// A single hand-seeded impulse in one Ez cell, stepped forward on both engines with no excitation
/// and no PML (PEC on all 6 faces) -- the pure interior-update-kernel parity check. With nz=3, every
/// H update touches a boundary cell (the "shift" trick), so this exercises the PEC boundary path
/// immediately, not just eventually.
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
    copper::CopperEngine gpuEngine(grid);

    const std::uint32_t seedX = 5, seedY = 5, seedZ = 1;
    gpuEngine.writeFieldCell(copper::CopperEngine::Field::Ez, seedX, seedY, seedZ, 1.0F);
    cpuEngine->SetVolt(2, seedX, seedY, seedZ, 1.0F);

    const std::uint32_t steps = 5;
    gpuEngine.run(steps);
    cpuEngine->IterateTS(steps);

    const FieldParityResult diff = compareGpuCpuFields(gpuEngine, *cpuEngine, grid.dims);
    XCTAssertTrue(diff.anyNonzero, @"CPU reference engine's fields are all still zero -- impulse never propagated");
    // Float-rounding tolerance, not bit-exact: Metal's compiler may fuse the multiply-add
    // differently than the CPU's, even for the exact same operation order.
    const float tolerance = 1e-5F * std::max(diff.maxAbsValue, 1.0F);
    XCTAssertLessThanOrEqual(diff.maxAbsDiff, tolerance);
}

/// No hand seeding this time: both engines start from E=H=0 and get their only nonzero state from
/// apply_excitation_e injecting the real Gaussian-pulse signal each step, the same way
/// Engine_Ext_Excitation::Apply2VoltagesImpl does on the CPU side. The fixture's excitation is
/// soft-E-field-only (Curr_Count==0), so this exercises apply_excitation_e specifically -- the same
/// path a real kiems port excitation uses.
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
    copper::CopperEngine gpuEngine(grid, excitation);

    const std::uint32_t steps = 100;
    gpuEngine.run(steps);
    cpuEngine->IterateTS(steps);

    const FieldParityResult diff = compareGpuCpuFields(gpuEngine, *cpuEngine, grid.dims);
    XCTAssertTrue(diff.anyNonzero, @"fixture excitation never landed on the CPU reference engine");
    const float tolerance = 1e-4F * std::max(diff.maxAbsValue, 1.0F);
    XCTAssertLessThanOrEqual(diff.maxAbsDiff, tolerance);
}

/// A no-op run (steps=0) must leave every field exactly at its zero-initialized state -- the
/// trivial base case every other parity test above implicitly assumes holds before it seeds anything.
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
    copper::CopperEngine gpuEngine(grid);
    gpuEngine.run(0);

    for (const copper::CopperEngine::Field field : kAllFields) {
        for (const float v : gpuEngine.readField(field)) {
            XCTAssertEqual(v, 0.0F);
        }
    }
}

@end
