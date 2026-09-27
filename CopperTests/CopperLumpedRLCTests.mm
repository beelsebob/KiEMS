// Internal/CopperLumpedRLC.hpp is a clean-room reimplementation of Operator_Ext_LumpedRLC's own
// protected SERIES-branch math (see that header's own top comment for why it can't just read the
// vendor extension's already-computed state) -- so unlike CopperYeeGrid/CopperExcitation,
// there's no "read openEMS's own answer back" cross-check available for discoverLumpedRLC() itself.
// What these tests check instead: (1) discoverLumpedRLC()'s output matches the exact closed-form
// coefficients derived by hand from the same R/L/C values and the Cd=dT/vi relation the header
// documents, and (2) applying CopperFDTDRunner.cpp's own per-timestep ADE correction (reimplemented
// here identically, mirroring that file) to the GPU engine reproduces the real CPU openEMS Engine's
// own Engine_Ext_LumpedRLC correction -- a genuine backend-parity check for the one Copper subsystem
// the existing Copper_smoketest never covered at all.
#import <XCTest/XCTest.h>

#include <cmath>
#include <limits>

#include <CSPrimBox.h>
#include <CSPropLumpedElement.h>

#include "CopperTestFixtures.hpp"
#include "Internal/CopperEngine.hpp"
#include "Internal/CopperLumpedRLC.hpp"
#include "Internal/CopperOpenEMSAccess.hpp"
#include "Internal/CopperOperator.hpp"
#include "Internal/CopperYeeGrid.hpp"

namespace {
copper::CopperOperator::Config allPecConfig(double maxTimesteps) {
    copper::CopperOperator::Config config;
    for (int side = 0; side < 6; ++side) {
        config.boundary[static_cast<std::size_t>(side)] = copper::CopperOperator::BoundaryType::PEC;
    }
    config.f0 = 2.5e9;
    config.fc = 2.5e9;
    config.maxTimesteps = static_cast<std::uint32_t>(maxTimesteps);
    return config;
}
} // namespace

using namespace copper::test;

@interface CopperLumpedRLCTests : XCTestCase
@end

@implementation CopperLumpedRLCTests

- (void)testParallelResistorKeepsRequestedResistanceOnNonuniformMesh {
    constexpr double resistance = 45.0;
    auto* csx = new ContinuousStructure();
    CSRectGrid* mesh = csx->GetGrid();
    mesh->SetDeltaUnit(1e-3);
    for (double line : {0.0, 0.7, 2.4, 6.0}) mesh->AddDiscLine(0, line);
    for (double line : {0.0, 1.1, 4.0}) mesh->AddDiscLine(1, line);
    for (double line : {0.0, 0.25, 2.0}) mesh->AddDiscLine(2, line);

    auto* lumped = new CSPropLumpedElement(csx->GetParameterSet());
    lumped->SetName("nonuniform_parallel");
    lumped->SetDirection(2);
    lumped->SetLEtype(CSPropLumpedElement::PARALLEL);
    lumped->SetCaps(false);
    lumped->SetResistance(resistance);
    csx->AddProperty(lumped);
    auto* box = new CSPrimBox(lumped->GetParameterSet(), lumped);
    box->SetCoord(0, 0.0);
    box->SetCoord(1, 6.0);
    box->SetCoord(2, 0.0);
    box->SetCoord(3, 4.0);
    box->SetCoord(4, 0.0);
    box->SetCoord(5, 2.0);

    copper::CopperOperator::Config config;
    config.f0 = 2.5e9;
    config.fc = 2.5e9;
    config.maxTimesteps = 10;
    copper::CopperOperator op(*csx, config);
    const copper::CopperYeeGrid& grid = op.grid();

    double inverseEquivalentConductance = 0.0;
    for (std::uint32_t z = 0; z < 2; ++z) {
        double planeConductance = 0.0;
        for (std::uint32_t y = 0; y < 3; ++y) {
            for (std::uint32_t x = 0; x < 4; ++x) {
                const std::uint32_t i = copper::copperGridIndex(grid.dims, x, y, z);
                const double vi = grid.vi[2][i];
                if (vi == 0.0) continue;
                // vv=(1-dt*g/2c)/(1+dt*g/2c), vi=(dt/c)/(1+dt*g/2c), hence g=(1-vv)/vi.
                planeConductance += (1.0 - grid.vv[2][i]) / vi;
            }
        }
        XCTAssertGreaterThan(planeConductance, 0.0);
        inverseEquivalentConductance += 1.0 / planeConductance;
    }
    const double equivalentResistance = inverseEquivalentConductance;
    XCTAssertEqualWithAccuracy(equivalentResistance, resistance, resistance * 2e-5);
    delete csx;
}

- (void)testParallelResistorCapsConnectBothFaces {
    auto* csx = new ContinuousStructure();
    CSRectGrid* mesh = csx->GetGrid();
    mesh->SetDeltaUnit(1e-3);
    for (int axis = 0; axis < 3; ++axis) {
        for (double line : {0.0, 1.0, 2.0}) mesh->AddDiscLine(axis, line);
    }

    auto* lumped = new CSPropLumpedElement(csx->GetParameterSet());
    lumped->SetName("capped_parallel");
    lumped->SetDirection(2);
    lumped->SetLEtype(CSPropLumpedElement::PARALLEL);
    lumped->SetCaps(true);
    lumped->SetResistance(45.0);
    csx->AddProperty(lumped);
    auto* box = new CSPrimBox(lumped->GetParameterSet(), lumped);
    for (int axis = 0; axis < 3; ++axis) {
        box->SetCoord(2 * axis, 0.0);
        box->SetCoord(2 * axis + 1, 2.0);
    }

    copper::CopperOperator::Config config;
    config.f0 = 2.5e9;
    config.fc = 2.5e9;
    config.maxTimesteps = 10;
    copper::CopperOperator op(*csx, config);
    const copper::CopperYeeGrid& grid = op.grid();

    for (std::uint32_t z : {0U, 2U}) {
        const std::uint32_t i = copper::copperGridIndex(grid.dims, 0, 0, z);
        XCTAssertEqual(grid.vv[0][i], 0.0F);
        XCTAssertEqual(grid.vi[0][i], 0.0F);
        XCTAssertEqual(grid.vv[1][i], 0.0F);
        XCTAssertEqual(grid.vi[1][i], 0.0F);
    }
    delete csx;
}

- (void)testParallelResistorActuallyDampsAFieldDuringTimeStepping {
    auto buildFixture = [](bool addResistor) {
        auto csx = std::make_unique<ContinuousStructure>();
        CSRectGrid* mesh = csx->GetGrid();
        mesh->SetDeltaUnit(1e-3);
        for (int axis = 0; axis < 3; ++axis) {
            for (double line = 0.0; line <= 6.0; line += 1.0) mesh->AddDiscLine(axis, line);
        }
        if (addResistor) {
            auto* lumped = new CSPropLumpedElement(csx->GetParameterSet());
            lumped->SetName("dynamic_parallel");
            lumped->SetDirection(2);
            lumped->SetLEtype(CSPropLumpedElement::PARALLEL);
            lumped->SetCaps(true);
            lumped->SetResistance(45.0);
            csx->AddProperty(lumped);
            auto* box = new CSPrimBox(lumped->GetParameterSet(), lumped);
            box->SetCoord(0, 3.0);
            box->SetCoord(1, 3.0);
            box->SetCoord(2, 3.0);
            box->SetCoord(3, 3.0);
            box->SetCoord(4, 2.0);
            box->SetCoord(5, 4.0);
        }
        return csx;
    };

    auto controlCsx = buildFixture(false);
    auto absorbedCsx = buildFixture(true);
    copper::CopperOperator controlOp(*controlCsx, allPecConfig(10));
    copper::CopperOperator absorbedOp(*absorbedCsx, allPecConfig(10));
    copper::CopperEngine control(controlOp.grid(), {}, {}, copper::CopperEngine::Backend::CPU);
    copper::CopperEngine absorbed(absorbedOp.grid(), {}, {}, copper::CopperEngine::Backend::CPU);

    constexpr std::uint32_t x = 3, y = 3, z = 2;
    control.writeFieldCell(copper::CopperEngine::Field::Ez, x, y, z, 1.0F);
    absorbed.writeFieldCell(copper::CopperEngine::Field::Ez, x, y, z, 1.0F);
    control.run(1);
    absorbed.run(1);

    const float controlField = std::fabs(control.readFieldCell(copper::CopperEngine::Field::Ez, x, y, z));
    const float absorbedField = std::fabs(absorbed.readFieldCell(copper::CopperEngine::Field::Ez, x, y, z));
    XCTAssertGreaterThan(controlField, 0.99F, @"the undamped control field unexpectedly changed before any H field existed");
    XCTAssertLessThan(absorbedField, controlField * 0.9F,
                      @"the 45-ohm parallel element was present in the coefficients but did not drain the field");
    XCTAssertLessThan(absorbed.estimateEnergy(), control.estimateEnergy());
}

- (void)testDiscoverLumpedRLCCoefficientsMatchHandDerivedFormula {
    const double resistance = 50.0;
    ContinuousStructure* csx = buildSeriesLumpedRLCFixture(resistance, std::numeric_limits<double>::quiet_NaN(),
                                                             std::numeric_limits<double>::quiet_NaN());
    copper::CopperOpenEMS fdtd;
    fdtd.SetCSX(csx);
    fdtd.SetGaussExcite(2.5e9, 2.5e9);
    for (int side = 0; side < 6; ++side) {
        fdtd.Set_BC_Type(side, 0);
    }
    fdtd.SetNumberOfTimeSteps(10);
    XCTAssertEqual(fdtd.SetupFDTD(), 0);

    copper::CopperOperator newOp(*csx, allPecConfig(10));
    const copper::CopperYeeGrid& grid = newOp.grid();
    const std::vector<copper::CopperLumpedRLCCell> cells = copper::discoverLumpedRLC(*csx, grid, newOp);
    XCTAssertEqual(cells.size(), static_cast<std::size_t>(1),
                   @"expected exactly 1 discovered cell -- the fixture's box is a single point in x/y "
                   @"and a single cell in z");
    const copper::CopperLumpedRLCCell& cell = cells.front();
    XCTAssertEqual(cell.x, 5U);
    XCTAssertEqual(cell.y, 5U);
    XCTAssertEqual(cell.z, 0U);
    XCTAssertEqual(cell.axis, 2U);

    // A single-cell box means nPar=nCells0=1, so dR=resistance, dL=0, dC=0 exactly -- the plain
    // resistor (dC==0) branch of _discoverForProperty's own formula (CopperLumpedRLC.cpp).
    const double dT = newOp.timestepSeconds();
    const std::uint32_t idx = copper::copperGridIndex(grid.dims, cell.x, cell.y, cell.z);
    const double vi = static_cast<double>(grid.vi[2][idx]);
    XCTAssertNotEqual(vi, 0.0);
    const double cd = dT / vi;

    const double expectedIb0 = dT / (dT * resistance);
    const double expectedB1 = 0.0;
    const double expectedB2 = -resistance;
    const double expectedVv2 = 0.5 * dT * expectedIb0 / cd;
    const double expectedVj1 = 0.5 * dT * (expectedB1 * expectedIb0 - 1.0) / cd;
    const double expectedVj2 = 0.5 * dT * expectedB2 * expectedIb0 / cd;
    const double expectedVvd = 1.0 / (1.0 + 0.5 * dT * expectedIb0 / cd);

    XCTAssertEqualWithAccuracy(cell.ib0, expectedIb0, 1e-6 * std::fabs(expectedIb0));
    XCTAssertEqualWithAccuracy(cell.b1, expectedB1, 1e-9);
    XCTAssertEqualWithAccuracy(cell.b2, expectedB2, 1e-6 * std::fabs(expectedB2));
    XCTAssertEqualWithAccuracy(cell.vv2, expectedVv2, 1e-6 * std::max(std::fabs(expectedVv2), 1e-12));
    XCTAssertEqualWithAccuracy(cell.vj1, expectedVj1, 1e-6 * std::fabs(expectedVj1));
    XCTAssertEqualWithAccuracy(cell.vj2, expectedVj2, 1e-6 * std::max(std::fabs(expectedVj2), 1e-12));
    XCTAssertEqualWithAccuracy(cell.vvd, expectedVvd, 1e-6 * std::fabs(expectedVvd));
}

/// PARALLEL-type lumped elements have no SERIES-branch equivalent here -- their static effect is
/// already baked into the shared Operator's own vv/vi by the time buildYeeGrid() reads it (see
/// CopperLumpedRLC.hpp's own top comment), so discoverLumpedRLC() must skip them entirely rather
/// than double-applying a dynamic correction on top of an already-static one.
- (void)testDiscoverLumpedRLCSkipsParallelTypeElements {
    ContinuousStructure* csx = buildPecCavityNoExcitation();
    // addLumpedElement()'s own default LEtype is PARALLEL (see csx_helpers.hpp) -- build one
    // directly here to keep this test self-contained rather than depending on that default.
    auto* lumped = new CSPropLumpedElement(csx->GetParameterSet());
    lumped->SetName("test_parallel");
    lumped->SetDirection(2);
    lumped->SetLEtype(CSPropLumpedElement::PARALLEL);
    lumped->SetCaps(true);
    lumped->SetResistance(50.0);
    csx->AddProperty(lumped);
    auto* box = new CSPrimBox(lumped->GetParameterSet(), lumped);
    box->SetCoord(0, 5.0);
    box->SetCoord(1, 5.0);
    box->SetCoord(2, 5.0);
    box->SetCoord(3, 5.0);
    box->SetCoord(4, 0.0);
    box->SetCoord(5, 1.0);

    copper::CopperOpenEMS fdtd;
    fdtd.SetCSX(csx);
    fdtd.SetGaussExcite(2.5e9, 2.5e9);
    for (int side = 0; side < 6; ++side) {
        fdtd.Set_BC_Type(side, 0);
    }
    fdtd.SetNumberOfTimeSteps(10);
    XCTAssertEqual(fdtd.SetupFDTD(), 0);

    copper::CopperOperator newOp(*csx, allPecConfig(10));
    const copper::CopperYeeGrid& grid = newOp.grid();

    const std::vector<copper::CopperLumpedRLCCell> cells = copper::discoverLumpedRLC(*csx, grid, newOp);
    XCTAssertTrue(cells.empty());
}

- (void)testDiscoverLumpedRLCFindsNothingWhenNoLumpedElementExists {
    ContinuousStructure* csx = buildPecCavityNoExcitation();
    copper::CopperOpenEMS fdtd;
    fdtd.SetCSX(csx);
    fdtd.SetGaussExcite(2.5e9, 2.5e9);
    for (int side = 0; side < 6; ++side) {
        fdtd.Set_BC_Type(side, 0);
    }
    fdtd.SetNumberOfTimeSteps(10);
    XCTAssertEqual(fdtd.SetupFDTD(), 0);

    copper::CopperOperator newOp(*csx, allPecConfig(10));
    const copper::CopperYeeGrid& grid = newOp.grid();

    ContinuousStructure emptyCsx; // no SetCSX() involved -- discoverLumpedRLC only reads csx directly
    const std::vector<copper::CopperLumpedRLCCell> cells = copper::discoverLumpedRLC(emptyCsx, grid, newOp);
    XCTAssertTrue(cells.empty());
}

/// Backend parity: applying CopperFDTDRunner.cpp's own per-timestep ADE correction (reimplemented
/// identically here) to the GPU engine via runWithProbeSampling()'s midStepCorrection hook must
/// reproduce the real CPU openEMS Engine's own Engine_Ext_LumpedRLC correction -- which runs
/// automatically inside IterateTS(), no extra code needed on the CPU side.
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

    copper::CopperOperator newOp(*csx, allPecConfig(10));
    const copper::CopperYeeGrid& grid = newOp.grid();
    const std::vector<copper::CopperLumpedRLCCell> lumpedRLC = copper::discoverLumpedRLC(*csx, grid, newOp);
    XCTAssertEqual(lumpedRLC.size(), static_cast<std::size_t>(1));

    copper::CopperEngine gpuEngine(grid);
    gpuEngine.writeFieldCell(copper::CopperEngine::Field::Ez, 5, 5, 0, 1.0F);
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
            double vdn0 = static_cast<double>(gpuEngine.readFieldCell(field, cell.x, cell.y, cell.z));
            vdn0 = static_cast<double>(cell.vvd) *
                   (vdn0 + static_cast<double>(cell.vv2) * s.vdn[2] + static_cast<double>(cell.vj1) * s.jn[1] +
                    static_cast<double>(cell.vj2) * s.jn[2]);
            s.jn[0] = static_cast<double>(cell.ib0) * (vdn0 - s.vdn[2]) -
                      static_cast<double>(cell.b1) * static_cast<double>(cell.ib0) * s.jn[1] -
                      static_cast<double>(cell.b2) * static_cast<double>(cell.ib0) * s.jn[2];
            s.vdn[0] = vdn0;
            gpuEngine.writeFieldCell(field, cell.x, cell.y, cell.z, static_cast<float>(vdn0));
        }
    };

    const std::uint32_t steps = 8;
    gpuEngine.runWithProbeSampling(
        steps, [](std::uint32_t) { return true; }, applyLumpedRLC);
    cpuEngine->IterateTS(steps);

    const FieldParityResult diff = compareGpuCpuFields(gpuEngine, *cpuEngine, grid.dims);
    XCTAssertTrue(diff.anyNonzero, @"CPU reference engine's fields are all still zero -- impulse never propagated");
    const float tolerance = 1e-4F * std::max(diff.maxAbsValue, 1.0F);
    XCTAssertLessThanOrEqual(diff.maxAbsDiff, tolerance);
}

@end
