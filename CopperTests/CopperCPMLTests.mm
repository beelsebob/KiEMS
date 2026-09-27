// CopperCPML has no CPU reference to diff against (openEMS itself has no CPML implementation -- see
// Internal/CopperCPML.hpp's own top comment: it's a structurally different formulation from
// openEMS's own UPML, not a generalization of it). So these tests check what the closed-form
// coefficients themselves guarantee (bounds derived directly from the CFS formulas, eq. 7.99/7.102),
// plus that a seeded impulse absorbed by a CPML boundary actually decays instead of exploding.
#import <XCTest/XCTest.h>

#include <cmath>

#include "CopperTestFixtures.hpp"
#include "Internal/CopperCPML.hpp"
#include "Internal/CopperOpenEMSAccess.hpp"
#include "Internal/CopperOperator.hpp"
#include "Internal/CopperYeeGrid.hpp"
#include "tools/constants.h"

using namespace copper::test;

@interface CopperCPMLTests : XCTestCase
@end

@implementation CopperCPMLTests

/// b[w] = exp(-(sigma_w+alpha_w)*dT/EPS0) is a decaying exponential of a non-negative exponent, so
/// it's bounded to (0,1] for every physically real sigma/alpha/dT; c[w] = sigma_w*(b[w]-1)/
/// (sigma_w+alpha_w) is a non-negative fraction times a non-positive term, so it's bounded to
/// [-1,0]. Every value must also be finite. Small tolerance above the exact bounds for float rounding.
- (void)testCPMLShellCoefficientsAreWellFormed {
    copper::CopperOpenEMS fdtd;
    fdtd.SetCSX(buildCpmlCavityNoExcitation());
    fdtd.SetGaussExcite(2.5e9, 2.5e9);
    for (int side = 0; side < 6; ++side) {
        fdtd.Set_BC_Type(side, 2); // MUR -- never Set_BC_PML() for a CPML run, see CopperCPML.hpp
    }
    fdtd.SetNumberOfTimeSteps(30);
    XCTAssertEqual(fdtd.SetupFDTD(), 0);
    Operator* op = fdtd.GetOperatorForGPU();
    XCTAssertTrue(op != nullptr);

    copper::CopperOperator::Config config; // boundary stays Open (MUR) on every face
    config.f0 = 2.5e9;
    config.fc = 2.5e9;
    config.maxTimesteps = 30;
    copper::CopperOperator newOp(*buildCpmlCavityNoExcitation(), config);

    constexpr std::uint32_t kPmlDepthCellsForTest = 8;
    const double alphaMax = 2 * M_PI * 100e6 * EPS0;
    const std::vector<copper::CopperCPMLShell> shells =
        copper::buildCPMLShells(newOp, alphaMax, kPmlDepthCellsForTest);
    XCTAssertEqual(shells.size(), static_cast<std::size_t>(6), @"expected exactly 6 CPML shells (one per face)");

    std::size_t checkedCount = 0;
    for (const copper::CopperCPMLShell& shell : shells) {
        for (int axis = 0; axis < 3; ++axis) {
            const std::vector<float>* arrays[4] = {&shell.bE[axis], &shell.bH[axis], &shell.cE[axis], &shell.cH[axis]};
            for (int a = 0; a < 4; ++a) {
                const bool isB = a < 2;
                for (const float v : *arrays[a]) {
                    ++checkedCount;
                    XCTAssertTrue(std::isfinite(v), @"non-finite CPML coefficient");
                    if (isB) {
                        XCTAssertTrue(v >= -1e-4F && v <= 1.0F + 1e-4F, @"b[w] outside its (0,1] bound: %f", v);
                    } else {
                        XCTAssertTrue(v >= -1.0F - 1e-4F && v <= 1e-4F, @"c[w] outside its [-1,0] bound: %f", v);
                    }
                }
            }
        }
    }
    XCTAssertGreaterThan(checkedCount, static_cast<std::size_t>(0));
}

/// alphaMax=0 and pmlDepthCells=0 are both explicitly documented edge cases -- 0 shells for
/// pmlDepthCells=0 (a caller with no PML on this run shouldn't have to special-case the call away).
- (void)testZeroPmlDepthReturnsNoShells {
    copper::CopperOpenEMS fdtd;
    fdtd.SetCSX(buildCpmlCavityNoExcitation());
    fdtd.SetGaussExcite(2.5e9, 2.5e9);
    for (int side = 0; side < 6; ++side) {
        fdtd.Set_BC_Type(side, 2);
    }
    fdtd.SetNumberOfTimeSteps(10);
    XCTAssertEqual(fdtd.SetupFDTD(), 0);

    copper::CopperOperator::Config config; // boundary stays Open (MUR) on every face
    config.f0 = 2.5e9;
    config.fc = 2.5e9;
    config.maxTimesteps = 10;
    copper::CopperOperator newOp(*buildCpmlCavityNoExcitation(), config);

    const std::vector<copper::CopperCPMLShell> shells = copper::buildCPMLShells(newOp, 0.0, 0);
    XCTAssertTrue(shells.empty());
}

/// A seeded impulse inside the x-min shell's own depth-8 box, comfortably interior on Y/Z, run for
/// several round trips across the domain's own x extent -- energy must not grow (a growing energy
/// means the boundary is amplifying instead of absorbing), and every field value must stay finite
/// (no NaN/Inf from a malformed recursion).
- (void)testCPMLAbsorbsSeededImpulseWithoutGrowingEnergyOrProducingNonFiniteValues {
    copper::CopperOpenEMS fdtd;
    fdtd.SetCSX(buildCpmlCavityNoExcitation());
    fdtd.SetGaussExcite(2.5e9, 2.5e9);
    for (int side = 0; side < 6; ++side) {
        fdtd.Set_BC_Type(side, 2);
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
    copper::CopperEngine engine(grid, {}, shells);

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
    XCTAssertLessThanOrEqual(energyAfter, energyAtStart,
                             @"CPML run's energy grew instead of decaying -- the boundary is amplifying, not absorbing");
}

@end
