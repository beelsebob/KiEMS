// CopperCPML has no independent reference implementation to diff against (see Internal/CopperCPML.hpp's
// own top comment for where its formulation comes from). So these tests check what the closed-form
// coefficients themselves guarantee (bounds derived directly from the CFS formulas, eq. 7.99/7.102),
// plus that a seeded impulse absorbed by a CPML boundary actually decays instead of exploding.
#import <XCTest/XCTest.h>

#include <algorithm>
#include <cmath>
#include <memory>

#include "CopperFDTDRunner.h"
#include "CopperTestFixtures.hpp"
#include "Internal/CopperCPML.hpp"
#include "Internal/CopperDomain.hpp"
#include "Internal/CopperOperator.hpp"
#include "Internal/CopperYeeGrid.hpp"
#include "Internal/CopperPhysicalConstants.hpp"

using namespace copper::test;

@interface CopperCPMLTests : XCTestCase
@end

@implementation CopperCPMLTests

static copper::CopperOperator::Config cpmlTestConfig() {
    copper::CopperOperator::Config config; // boundary stays Open (MUR) on every face
    config.f0 = 2.5e9;
    config.fc = 2.5e9;
    config.maxTimesteps = 30;
    return config;
}

static const double kAlphaMax = 2 * M_PI * 100e6 * copper::physical::epsilon0;

/// b = exp(-(sigma+alpha)*dT/copper::physical::epsilon0) is a decaying exponential of a non-negative exponent, so
/// it's bounded to (0,1] for every physically real sigma/alpha/dT; c = sigma*(b-1)/(sigma+alpha) is
/// a non-negative fraction times a non-positive term, so it's bounded to [-1,0]. Every value must
/// also be finite. Small tolerance above the exact bounds for float rounding.
- (void)testCPMLCoefficientsAreWellFormed {
    copper::CopperOperator newOp(*buildCpmlCavityNoExcitation(), cpmlTestConfig());
    constexpr std::uint32_t kPmlDepthCellsForTest = 8;
    const copper::CopperCPML cpml = copper::buildCPML(newOp, kAlphaMax, kPmlDepthCellsForTest);

    std::size_t checkedCount = 0;
    for (const copper::CopperCPML::Axis& axis : cpml.axes) {
        XCTAssertEqual(axis.layerCount(), 2 * kPmlDepthCellsForTest + 1, @"a lower and an upper slab per axis");
        const std::vector<float>* arrays[4] = {&axis.bE, &axis.bH, &axis.cE, &axis.cH};
        for (int a = 0; a < 4; ++a) {
            const bool isB = a < 2;
            for (const float v : *arrays[a]) {
                ++checkedCount;
                XCTAssertTrue(std::isfinite(v), @"non-finite CPML coefficient");
                if (isB) {
                    XCTAssertTrue(v >= -1e-4F && v <= 1.0F + 1e-4F, @"b outside its (0,1] bound: %f", v);
                } else {
                    XCTAssertTrue(v >= -1.0F - 1e-4F && v <= 1e-4F, @"c outside its [-1,0] bound: %f", v);
                }
            }
        }
    }
    XCTAssertGreaterThan(checkedCount, static_cast<std::size_t>(0));
}

/// pmlDepthCells=0 is an explicitly documented edge case: an empty CPML (a caller with no PML on this
/// run shouldn't have to special-case the call away).
- (void)testZeroPmlDepthReturnsAnEmptyCPML {
    copper::CopperOperator newOp(*buildCpmlCavityNoExcitation(), cpmlTestConfig());
    XCTAssertTrue(copper::buildCPML(newOp, 0.0, 0).empty());
}

/// A seeded impulse inside the x-min slab, comfortably interior on Y/Z, run for several round trips
/// across the domain's own x extent -- energy must not grow (a growing energy means the boundary is
/// amplifying instead of absorbing), and every field value must stay finite (no NaN/Inf from a
/// malformed recursion).
- (void)testCPMLAbsorbsSeededImpulseWithoutGrowingEnergyOrProducingNonFiniteValues {
    copper::CopperOperator newOp(*buildCpmlCavityNoExcitation(), cpmlTestConfig());
    const copper::CopperCPML cpml = copper::buildCPML(newOp, kAlphaMax, 8);
    XCTAssertFalse(cpml.empty());
    copper::CopperEngine engine(newOp.grid(), {}, cpml);

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

/// Each axis is graded on exactly its two slabs, and every line in them on both Yee sides except
/// where the half-cell stagger puts one side on the PML's edge: the upper slab's first line (E on the
/// inner edge, b=1/c=0 exactly) and its last (H half a cell past the outer edge). Checked on a graded
/// mesh too. Depth 9 on the uniform mesh is the regression case: `width - distance * delta`,
/// contracted to an FMA, once left the inner edge at width's rounding error rather than 0, and
/// 9 * 1e-3 rounds up -- so the upper slab's inner edge got sigma's full inner-edge value.
- (void)testCPMLGradesEachAxisOnExactlyItsSlabs {
    struct Case {
        const char* name;
        ContinuousStructure* csx;
        std::uint32_t depth;
    };
    for (const Case& c : {Case{"uniform", buildCpmlCavityNoExcitation(), 8}, Case{"uniform", buildCpmlCavityNoExcitation(), 9},
                          Case{"graded", buildGradedMaterialFixture(), 5}}) {
        const std::unique_ptr<ContinuousStructure> csx(c.csx);
        copper::CopperOperator op(*csx, cpmlTestConfig());
        const copper::CopperCPML cpml = copper::buildCPML(op, kAlphaMax, c.depth);
        for (int w = 0; w < 3; ++w) {
            const copper::CopperCPML::Axis& axis = cpml.axes[w];
            const auto n = static_cast<std::uint32_t>(op.numberOfLines(w));
            XCTAssertEqual(axis.layerOf.size(), static_cast<std::size_t>(n));
            XCTAssertEqual(axis.layerCount(), 2 * c.depth + 1);
            std::uint32_t expectedLayer = 0;
            for (std::uint32_t line = 0; line < n; ++line) {
                const bool inSlab = line < c.depth || line >= n - c.depth - 1;
                if (!inSlab) {
                    XCTAssertEqual(axis.layerOf[line], copper::CopperCPML::kNoLayer, @"%s axis %d line %u", c.name, w, line);
                    continue;
                }
                const std::uint32_t layer = axis.layerOf[line];
                XCTAssertEqual(layer, expectedLayer++, @"%s axis %d line %u", c.name, w, line);
                if (layer == copper::CopperCPML::kNoLayer) continue;
                const bool upperInner = line == n - c.depth - 1, outermost = line == n - 1;
                if (upperInner) {
                    XCTAssertEqual(axis.bE[layer], 1.0F, @"%s axis %d: E graded on the inner edge", c.name, w);
                    XCTAssertEqual(axis.cE[layer], 0.0F, @"%s axis %d: E graded on the inner edge", c.name, w);
                } else {
                    XCTAssertLessThan(axis.cE[layer], 0.0F, @"%s axis %d line %u: E ungraded", c.name, w, line);
                }
                if (outermost) {
                    XCTAssertEqual(axis.bH[layer], 1.0F, @"%s axis %d: H graded past the outer edge", c.name, w);
                    XCTAssertEqual(axis.cH[layer], 0.0F, @"%s axis %d: H graded past the outer edge", c.name, w);
                } else {
                    XCTAssertLessThan(axis.cH[layer], 0.0F, @"%s axis %d line %u: H ungraded", c.name, w, line);
                }
            }
        }
    }
}

/// The irregular domain's Z-only CPML must grade exactly like the full CPML's Z axis, and nothing
/// else.
- (void)testZOnlyCPMLGradesExactlyLikeTheFullCPMLsZAxis {
    copper::CopperOperator op(*buildCpmlCavityNoExcitation(), cpmlTestConfig());
    const copper::CopperCPML all = copper::buildCPML(op, kAlphaMax, 8);
    const copper::CopperCPML zOnly = copper::buildCPML(op, kAlphaMax, 8, copper::CopperCPMLFaces::ZOnly);
    XCTAssertEqual(zOnly.axes[0].layerCount() + zOnly.axes[1].layerCount(), 0U);
    for (int w = 0; w < 2; ++w) {
        XCTAssertEqual(zOnly.axes[w].layerOf.size(), all.axes[w].layerOf.size(), @"x/y line tables still span the grid");
    }
    const copper::CopperCPML::Axis &a = all.axes[2], &z = zOnly.axes[2];
    XCTAssertTrue(a.layerOf == z.layerOf);
    XCTAssertTrue(a.bE == z.bE && a.cE == z.cE && a.bH == z.bH && a.cH == z.cH);
}

/// The Metal backend folds the CPML into its update kernels; the CPU backend applies it as a pass
/// after its own update, cell by cell, as its reference. They must agree for a full CPML and for the
/// irregular domain's Z-only one, with impulses seeded where one, two and three axes' slabs overlap
/// (faces, edges, corners) so every psi term is driven from the first step. A run without any CPML
/// must come out clearly different, or the comparison proves nothing. Q16 tiles get twice the usual
/// allowance: five impulses over 80 steps accumulate their rounding to ~1e-4 of the peak (5e-5 with
/// no CPML at all), where fp32 agrees to 6e-7.
- (void)testFoldedCPMLMatchesTheCPUBackend {
    copper::CopperOperator op(*buildCpmlCavityNoExcitation(), cpmlTestConfig());
    const copper::CopperGridDims dims = op.dims();
    using Engine = copper::CopperEngine;
    for (const auto faces : {copper::CopperCPMLFaces::All, copper::CopperCPMLFaces::ZOnly}) {
        const char* label = faces == copper::CopperCPMLFaces::All ? "all faces" : "Z only";
        const copper::CopperCPML cpml = copper::buildCPML(op, kAlphaMax, 8, faces);
        Engine metal(op.grid(), {}, cpml, Engine::Backend::Metal);
        Engine cpu(op.grid(), {}, cpml, Engine::Backend::CPU);
        Engine unabsorbed(op.grid());
        for (Engine* engine : {&metal, &cpu, &unabsorbed}) {
            engine->writeFieldCell(Engine::Field::Ex, 2, 2, 2, 1.0F);                                // corner
            engine->writeFieldCell(Engine::Field::Ez, dims.nx - 3, dims.ny - 3, dims.nz - 3, 1.0F);  // corner
            engine->writeFieldCell(Engine::Field::Ey, dims.nx / 2, 1, dims.nz - 2, 1.0F);            // edge
            engine->writeFieldCell(Engine::Field::Hy, dims.nx - 4, dims.ny / 2, dims.nz / 2, 0.005F); // face
            engine->writeFieldCell(Engine::Field::Ez, dims.nx / 2, dims.ny / 2, 4, 1.0F);            // face
            engine->run(80);
        }
        const FieldDiff diff = diffFields(metal, cpu);
        const FieldDiff effect = diffFields(metal, unabsorbed);
        NSLog(@"%s: max |field| %g, Metal vs CPU %g, vs no CPML %g", label, diff.maxAbsValue, diff.maxAbsDiff,
              effect.maxAbsDiff);
        XCTAssertGreaterThan(diff.maxAbsValue, 0.0F);
        const float tolerance = environmentFlag("COPPER_FIELD_Q16") ? 2e-4F : fieldParityTolerance(1e-5F);
        XCTAssertLessThanOrEqual(diff.maxAbsDiff, tolerance * diff.maxAbsValue, @"%s", label);
        XCTAssertGreaterThan(effect.maxAbsDiff, 1e-2F * diff.maxAbsValue, @"%s: the CPML had no visible effect", label);
    }
}

@end
