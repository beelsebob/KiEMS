// CopperCPML has no CPU reference to diff against (openEMS itself has no CPML implementation -- see
// Internal/CopperCPML.hpp's own top comment: it's a structurally different formulation from
// openEMS's own UPML, not a generalization of it). So these tests check what the closed-form
// coefficients themselves guarantee (bounds derived directly from the CFS formulas, eq. 7.99/7.102),
// plus that a seeded impulse absorbed by a CPML boundary actually decays instead of exploding.
#import <XCTest/XCTest.h>

#include <algorithm>
#include <cmath>

#include "CopperFDTDRunner.h"
#include "CopperTestFixtures.hpp"
#include "Internal/CopperCPML.hpp"
#include "Internal/CopperDomain.hpp"
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

/// A stretched-coordinate PML is only stable when each axis's stretch depends on that axis alone
/// (see CopperCPML.hpp): a grading that varies along another axis drives exponential or late-time
/// growth pinned to where it varies. Checks every cell of the grid -- including cells no shell
/// covers, whose grading is implicitly zero -- so both a missing plane at a face's inner edge and an
/// outline-following grading fail it.
- (void)testCPMLGradingOfEachAxisDependsOnThatAxisAlone {
    copper::CopperOperator::Config config;
    config.f0 = 2.5e9;
    config.fc = 2.5e9;
    config.maxTimesteps = 30;
    copper::CopperOperator op(*buildCpmlCavityNoExcitation(), config);
    constexpr std::uint32_t depth = 8;
    const copper::CopperGridDims dims = op.dims();

    auto checkSeparable = [&](const std::vector<copper::CopperCPMLShell>& shells, NSString* label) {
        std::vector<float> grading[2][3]; // [E/H][axis] -> c per global cell, 0 where no shell
        for (auto& side : grading) {
            for (auto& axis : side) axis.assign(dims.cellCount(), 0.0F);
        }
        for (const auto& shell : shells) {
            for (std::uint32_t lz = 0; lz < shell.dims.nz; ++lz) {
                for (std::uint32_t ly = 0; ly < shell.dims.ny; ++ly) {
                    for (std::uint32_t lx = 0; lx < shell.dims.nx; ++lx) {
                        const std::size_t local = copper::copperGridIndex(shell.dims, lx, ly, lz);
                        const std::size_t global = copper::copperGridIndex(dims, lx + shell.startX, ly + shell.startY,
                                                                           lz + shell.startZ);
                        for (int axis = 0; axis < 3; ++axis) {
                            grading[0][axis][global] += shell.cE[axis][local];
                            grading[1][axis][global] += shell.cH[axis][local];
                        }
                    }
                }
            }
        }
        const std::uint32_t n[3] = {dims.nx, dims.ny, dims.nz};
        std::size_t mismatches = 0;
        for (int side = 0; side < 2; ++side) {
            for (int axis = 0; axis < 3; ++axis) {
                for (std::uint32_t z = 0; z < dims.nz; ++z) {
                    for (std::uint32_t y = 0; y < dims.ny; ++y) {
                        for (std::uint32_t x = 0; x < dims.nx; ++x) {
                            const std::uint32_t pos[3] = {x, y, z};
                            // Reference: the cell with the same coordinate along `axis` at the
                            // domain's centre on the other two.
                            std::uint32_t ref[3] = {n[0] / 2, n[1] / 2, n[2] / 2};
                            ref[axis] = pos[axis];
                            const float value = grading[side][axis][copper::copperGridIndex(dims, x, y, z)];
                            const float expected =
                                grading[side][axis][copper::copperGridIndex(dims, ref[0], ref[1], ref[2])];
                            if (value != expected) ++mismatches;
                        }
                    }
                }
            }
        }
        XCTAssertEqual(mismatches, static_cast<std::size_t>(0), @"%@: a CPML axis's grading varies off-axis", label);
    };

    checkSeparable(copper::buildCPMLShells(op, 2 * M_PI * 100e6 * EPS0, depth), @"rectangular");

}

/// The irregular domain's Z-only CPML keeps one coefficient set per plane, so it can't vary off-axis;
/// what it must do is grade exactly like the rectangular CPML's Z faces. Compared at the domain
/// centre, where no X or Y face claims the column.
- (void)testZOnlyCPMLGradesExactlyLikeTheRectangularZFaces {
    copper::CopperOperator::Config config;
    config.f0 = 2.5e9;
    config.fc = 2.5e9;
    config.maxTimesteps = 30;
    copper::CopperOperator op(*buildCpmlCavityNoExcitation(), config);
    constexpr std::uint32_t depth = 8;
    const double alphaMax = 2 * M_PI * 100e6 * EPS0;
    const copper::CopperGridDims dims = op.dims();
    const std::uint32_t cx = dims.nx / 2, cy = dims.ny / 2;

    std::vector<float> bE(dims.nz, 1.0F), cE(dims.nz, 0.0F), bH(dims.nz, 1.0F), cH(dims.nz, 0.0F);
    for (const auto& shell : copper::buildCPMLShells(op, alphaMax, depth)) {
        if (cx < shell.startX || cx >= shell.startX + shell.dims.nx || cy < shell.startY ||
            cy >= shell.startY + shell.dims.ny) {
            continue;
        }
        for (std::uint32_t lz = 0; lz < shell.dims.nz; ++lz) {
            const std::size_t local = copper::copperGridIndex(shell.dims, cx - shell.startX, cy - shell.startY, lz);
            bE[shell.startZ + lz] = shell.bE[2][local];
            cE[shell.startZ + lz] = shell.cE[2][local];
            bH[shell.startZ + lz] = shell.bH[2][local];
            cH[shell.startZ + lz] = shell.cH[2][local];
        }
    }

    const copper::CopperZCPML zcpml = copper::buildZCPML(op, alphaMax, depth);
    for (std::uint32_t z = 0; z < dims.nz; ++z) {
        const std::uint32_t layer = zcpml.layerOfZ[z];
        const bool graded = layer != copper::CopperZCPML::kNoLayer;
        XCTAssertEqual(graded ? zcpml.bE[layer] : 1.0F, bE[z], @"bE at z=%u", z);
        XCTAssertEqual(graded ? zcpml.cE[layer] : 0.0F, cE[z], @"cE at z=%u", z);
        XCTAssertEqual(graded ? zcpml.bH[layer] : 1.0F, bH[z], @"bH at z=%u", z);
        XCTAssertEqual(graded ? zcpml.cH[layer] : 0.0F, cH[z], @"cH at z=%u", z);
        if (graded) XCTAssertTrue(cE[z] != 0.0F || cH[z] != 0.0F, @"a Z-only CPML plane with no grading at z=%u", z);
    }
}

/// The general per-shell CPML equivalent of `zcpml`: one slab per run of graded planes, spanning the
/// whole XY extent and grading Z with zcpml's own coefficients (X/Y slots inert, b=1/c=0).
static std::vector<copper::CopperCPMLShell> generalShellsFor(const copper::CopperZCPML& zcpml,
                                                             const copper::CopperGridDims& dims) {
    std::vector<copper::CopperCPMLShell> shells;
    for (std::uint32_t z = 0; z < dims.nz;) {
        if (zcpml.layerOfZ[z] == copper::CopperZCPML::kNoLayer) {
            ++z;
            continue;
        }
        std::uint32_t end = z;
        while (end < dims.nz && zcpml.layerOfZ[end] != copper::CopperZCPML::kNoLayer) ++end;
        copper::CopperCPMLShell shell;
        shell.startZ = z;
        shell.dims = {dims.nx, dims.ny, end - z};
        const std::size_t count = shell.dims.cellCount();
        const std::size_t plane = static_cast<std::size_t>(dims.nx) * dims.ny;
        for (int a = 0; a < 3; ++a) {
            shell.bE[a].assign(count, 1.0F);
            shell.cE[a].assign(count, 0.0F);
            shell.bH[a].assign(count, 1.0F);
            shell.cH[a].assign(count, 0.0F);
            shell.psiE0[a].assign(count, 0.0F);
            shell.psiE1[a].assign(count, 0.0F);
            shell.psiH0[a].assign(count, 0.0F);
            shell.psiH1[a].assign(count, 0.0F);
        }
        for (std::uint32_t lz = 0; lz < shell.dims.nz; ++lz) {
            const std::uint32_t layer = zcpml.layerOfZ[z + lz];
            std::fill_n(shell.bE[2].data() + lz * plane, plane, zcpml.bE[layer]);
            std::fill_n(shell.cE[2].data() + lz * plane, plane, zcpml.cE[layer]);
            std::fill_n(shell.bH[2].data() + lz * plane, plane, zcpml.bH[layer]);
            std::fill_n(shell.cH[2].data() + lz * plane, plane, zcpml.cH[layer]);
        }
        shells.push_back(std::move(shell));
        z = end;
    }
    return shells;
}

/// The Z-only CPML folded into update_e/h_interior_zcpml must do exactly what the general
/// cpml_correct_e/h kernels do with the same grading (up to fast-math rounding), and the CPU
/// backend's separate pass must agree with both. Impulses seeded inside both slabs drive the psi
/// terms from the first step; a run without any CPML must come out clearly different, or the
/// comparison proves nothing.
- (void)testZOnlyCPMLFoldedIntoInteriorUpdateMatchesGeneralCPMLKernels {
    copper::CopperOperator::Config config;
    config.f0 = 2.5e9;
    config.fc = 2.5e9;
    config.maxTimesteps = 30;
    copper::CopperOperator op(*buildCpmlCavityNoExcitation(), config);
    constexpr std::uint32_t depth = 8;
    const copper::CopperGridDims dims = op.dims();
    const copper::CopperZCPML zcpml = copper::buildZCPML(op, 2 * M_PI * 100e6 * EPS0, depth);
    XCTAssertFalse(zcpml.empty());
    const auto shells = generalShellsFor(zcpml, dims);
    XCTAssertEqual(shells.size(), static_cast<std::size_t>(2));

    using Engine = copper::CopperEngine;
    Engine folded(op.grid(), {}, {}, Engine::Backend::Metal, {}, zcpml);
    Engine general(op.grid(), {}, shells, Engine::Backend::Metal);
    Engine cpu(op.grid(), {}, {}, Engine::Backend::CPU, {}, zcpml);
    Engine unabsorbed(op.grid());
    for (Engine* engine : {&folded, &general, &cpu, &unabsorbed}) {
        engine->writeFieldCell(Engine::Field::Ez, dims.nx / 2, dims.ny / 2, depth / 2, 1.0F);
        engine->writeFieldCell(Engine::Field::Ex, dims.nx / 2, dims.ny / 2, dims.nz - 1 - depth / 2, 1.0F);
        engine->run(40);
    }

    float maxValue = 0.0F, generalDiff = 0.0F, cpuDiff = 0.0F, unabsorbedDiff = 0.0F;
    for (const auto field : kAllFields) {
        const auto a = folded.readField(field), b = general.readField(field), c = cpu.readField(field),
                   d = unabsorbed.readField(field);
        for (std::size_t i = 0; i < a.size(); ++i) {
            XCTAssertTrue(std::isfinite(a[i]));
            maxValue = std::max(maxValue, std::abs(a[i]));
            generalDiff = std::max(generalDiff, std::abs(a[i] - b[i]));
            cpuDiff = std::max(cpuDiff, std::abs(a[i] - c[i]));
            unabsorbedDiff = std::max(unabsorbedDiff, std::abs(a[i] - d[i]));
        }
    }
    NSLog(@"Z-only CPML: max |field| %g, vs general kernels %g, vs CPU %g, vs no CPML %g", maxValue, generalDiff,
          cpuDiff, unabsorbedDiff);
    XCTAssertLessThanOrEqual(generalDiff, 1e-6F * maxValue);
    XCTAssertLessThanOrEqual(cpuDiff, 1e-5F * maxValue);
    XCTAssertGreaterThan(unabsorbedDiff, 1e-2F * maxValue, @"the CPML had no visible effect");
}

@end
