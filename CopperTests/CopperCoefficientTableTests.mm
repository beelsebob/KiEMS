// The Metal engine keeps the update coefficients as a per-cell index into a table of material terms,
// rebuilding vi/iv from the mesh's separable geometry (see Internal/CopperCoefficientTable.hpp). The
// CPU backend still uses the grid's own per-cell arrays, so it is the reference here. The graded
// fixture is what makes these checks mean something: on the uniform 1 mm meshes every other fixture
// uses, a geometry factor applied to the wrong axis would still come out right.
#import <XCTest/XCTest.h>

#include <algorithm>
#include <cmath>
#include <unordered_set>

#include "CopperFDTDRunner.h"
#include "CopperTestFixtures.hpp"
#include "Internal/CopperCPML.hpp"
#include "Internal/CopperCoefficientTable.hpp"
#include "Internal/CopperDomain.hpp"
#include "Internal/CopperOperator.hpp"

using namespace copper::test;

namespace {

copper::CopperOperator::Config fixtureConfig() {
    copper::CopperOperator::Config config;
    config.f0 = 2.5e9;
    config.fc = 2.5e9;
    config.maxTimesteps = 30;
    return config;
}

struct FieldComparison {
    float maxValue = 0.0F;
    float maxDifference = 0.0F;
};

FieldComparison compareFields(const copper::CopperEngine& a, const copper::CopperEngine& b) {
    FieldComparison result;
    for (const auto field : kAllFields) {
        const std::vector<float> va = a.readField(field), vb = b.readField(field);
        for (std::size_t i = 0; i < va.size(); ++i) {
            result.maxValue = std::max(result.maxValue, std::abs(vb[i]));
            result.maxDifference = std::max(result.maxDifference, std::abs(va[i] - vb[i]));
        }
    }
    return result;
}

} // namespace

@interface CopperCoefficientTableTests : XCTestCase
@end

@implementation CopperCoefficientTableTests

/// Every cell's vv/ii must come back exactly and its vi/iv to within float rounding, while the table
/// stays far smaller than the set of distinct raw vi/iv values -- i.e. the geometry really is what
/// made them distinct.
- (void)testTableReproducesEveryCoefficientOfAGradedMaterialMesh {
    copper::CopperOperator op(*buildGradedMaterialFixture(), fixtureConfig());
    const copper::CopperYeeGrid& grid = op.grid();
    const copper::CopperGridDims dims = grid.dims;
    const std::vector<copper::CopperDomainMask::DispatchBox> wholeGrid = {
        {0, 0, dims.nx, dims.ny, copper::CopperDomainMask::Region::Interior}};
    const copper::CopperDomainMask noMask;
    const copper::CopperRingAbsorber noRing(noMask, grid.timestepSeconds, dims);

    for (const auto side : {copper::CopperCoefficientSide::E, copper::CopperCoefficientSide::H}) {
        const bool electric = side == copper::CopperCoefficientSide::E;
        const copper::CopperCoefficientTable table = copper::buildCoefficientTable(grid, side, wholeGrid, noRing);
        const std::vector<float>* decay = electric ? grid.vv : grid.ii;
        const std::vector<float>* curl = electric ? grid.vi : grid.iv;
        const auto& own = electric ? grid.primaryDelta : grid.dualDelta;
        const auto& across = electric ? grid.dualDelta : grid.primaryDelta;

        std::unordered_set<float> distinctRawCurl;
        std::size_t decayMismatches = 0, nonZeroCurl = 0;
        double worstCurlError = 0.0;
        for (std::uint32_t z = 0; z < dims.nz; ++z) {
            for (std::uint32_t y = 0; y < dims.ny; ++y) {
                for (std::uint32_t x = 0; x < dims.nx; ++x) {
                    const std::size_t i = copper::copperGridIndex(dims, x, y, z);
                    const std::uint32_t pos[3] = {x, y, z};
                    const auto& entry = table.entries[table.index[i]];
                    for (std::size_t n = 0; n < 3; ++n) {
                        const std::size_t nP = (n + 1) % 3, nPP = (n + 2) % 3;
                        if (entry.decay[n] != decay[n][i]) ++decayMismatches;
                        if (curl[n][i] == 0.0F) continue;
                        ++nonZeroCurl;
                        distinctRawCurl.insert(curl[n][i]);
                        const double rebuilt = entry.material[n] * own[n][pos[n]] / (across[nP][pos[nP]] * across[nPP][pos[nPP]]);
                        worstCurlError = std::max(worstCurlError, std::abs(rebuilt - curl[n][i]) / std::abs(curl[n][i]));
                    }
                }
            }
        }
        NSLog(@"%s table: %zu entries for %zu distinct raw values, worst rebuild %g (kernel arithmetic %g)",
              electric ? "E" : "H", table.entries.size(), distinctRawCurl.size(), worstCurlError,
              table.worstRebuildError);
        XCTAssertGreaterThan(nonZeroCurl, static_cast<std::size_t>(0));
        XCTAssertEqual(decayMismatches, static_cast<std::size_t>(0), @"vv/ii must be stored exactly");
        XCTAssertLessThanOrEqual(worstCurlError, 1e-6);
        XCTAssertLessThanOrEqual(table.worstRebuildError, 1e-6);
        XCTAssertLessThan(10 * table.entries.size(), distinctRawCurl.size(),
                          @"factoring out the geometry should collapse the coefficients to a few material terms");
    }
}

/// The Metal backend's table-driven kernels against the CPU backend's per-cell arrays, through
/// dielectric, magnetic and metal boundaries on a graded mesh -- to the same tolerance as the other
/// backend parity tests, even though the rebuilt vi/iv each carry a few float roundings.
- (void)testMetalTableKernelsMatchPerCellCoefficientsOnAGradedMaterialMesh {
    copper::CopperOperator op(*buildGradedMaterialFixture(), fixtureConfig());
    const copper::CopperYeeGrid& grid = op.grid();
    const copper::CopperGridDims dims = grid.dims;

    copper::CopperEngine metal(grid, {}, {}, copper::CopperEngine::Backend::Metal);
    copper::CopperEngine cpu(grid, {}, {}, copper::CopperEngine::Backend::CPU);
    for (copper::CopperEngine* engine : {&metal, &cpu}) {
        engine->writeFieldCell(copper::CopperEngine::Field::Ez, dims.nx / 3, dims.ny / 2, dims.nz / 4, 1.0F);
        engine->writeFieldCell(copper::CopperEngine::Field::Ex, 2 * dims.nx / 3, dims.ny / 3, dims.nz / 2, 1.0F);
        engine->run(60);
    }
    const FieldComparison comparison = compareFields(metal, cpu);
    NSLog(@"graded mesh, 60 steps: max |field| %g, Metal vs CPU %g", comparison.maxValue, comparison.maxDifference);
    XCTAssertGreaterThan(comparison.maxValue, 0.0F);
    XCTAssertLessThanOrEqual(comparison.maxDifference, fieldParityTolerance(1e-5F) * comparison.maxValue);
}

/// The table folds the irregular domain's ring absorber in cell by cell (CopperRingAbsorber); the
/// CPU backend applies it to its whole coefficient arrays (applyRingAbsorber). An impulse seeded
/// inside the ring must evolve the same way under both.
- (void)testRingAbsorberFoldedIntoTheTableMatchesPerCellCoefficients {
    copper::CopperOperator op(*buildCpmlCavityNoExcitation(), fixtureConfig());
    constexpr std::uint32_t depth = 3;
    const auto nx = op.numberOfLines(0), ny = op.numberOfLines(1), nz = op.numberOfLines(2);
    const std::uint32_t x0 = depth + 3, x1 = nx - depth - 4;
    const std::uint32_t y0 = depth + 3, y1 = ny - depth - 4;
    copper::CopperFDTDPortConfig config;
    config.domainCutoutLoops = {{{op.discLine(0, x0), op.discLine(1, y0)},
                                  {op.discLine(0, x1), op.discLine(1, y0)},
                                  {op.discLine(0, x1), op.discLine(1, y1)},
                                  {op.discLine(0, x0), op.discLine(1, y1)}}};
    config.domainCPMLCellSize = op.discLine(0, 1) - op.discLine(0, 0);
    const copper::CopperDomainMask mask = copper::buildDomainMask(op, config, depth);
    const std::uint32_t seedX = x0 - 1, seedY = (y0 + y1) / 2, seedZ = nz / 2;
    XCTAssertGreaterThanOrEqual(mask.at(seedX, seedY), 2, @"the seed must sit in the absorbing ring");

    copper::CopperEngine metal(op.grid(), {}, {}, copper::CopperEngine::Backend::Metal, mask);
    copper::CopperEngine cpu(op.grid(), {}, {}, copper::CopperEngine::Backend::CPU, mask);
    copper::CopperDomainMask ringless = mask; // same dispatch cuboids, absorber switched off
    ringless.ringLayerMetres = 0.0;
    copper::CopperEngine unabsorbed(op.grid(), {}, {}, copper::CopperEngine::Backend::Metal, ringless);
    for (copper::CopperEngine* engine : {&metal, &cpu, &unabsorbed}) {
        engine->writeFieldCell(copper::CopperEngine::Field::Ez, seedX, seedY, seedZ, 1.0F);
        engine->run(30);
    }
    const FieldComparison comparison = compareFields(metal, cpu);
    const FieldComparison ringEffect = compareFields(metal, unabsorbed);
    NSLog(@"ring absorber, 30 steps: max |field| %g, Metal vs CPU %g, vs no absorber %g", comparison.maxValue,
          comparison.maxDifference, ringEffect.maxDifference);
    XCTAssertLessThanOrEqual(comparison.maxDifference, fieldParityTolerance(1e-5F) * comparison.maxValue);
    XCTAssertGreaterThan(ringEffect.maxDifference, 1e-2F * comparison.maxValue, @"the ring had no visible effect");
}

@end
