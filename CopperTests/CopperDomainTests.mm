#import <XCTest/XCTest.h>

#include <algorithm>
#include <cmath>
#include <cstdint>

#include "CopperFDTDRunner.h"
#include "CopperTestFixtures.hpp"
#include "Internal/CopperCPML.hpp"
#include "Internal/CopperDomain.hpp"
#include "Internal/CopperOperator.hpp"
#include "Internal/CopperPhysicalConstants.hpp"

using namespace copper::test;

@interface CopperDomainTests : XCTestCase
@end

@implementation CopperDomainTests

- (void)testIrregularDomainDecomposesIntoClassPureCuboidsWithoutExternalWork {
    copper::CopperOperator::Config operatorConfig;
    operatorConfig.f0 = 2.5e9;
    operatorConfig.fc = 2.5e9;
    operatorConfig.maxTimesteps = 30;
    copper::CopperOperator op(*buildCpmlCavityNoExcitation(), operatorConfig);

    constexpr std::uint32_t depth = 3;
    const auto nx = op.numberOfLines(0), ny = op.numberOfLines(1);
    XCTAssertGreaterThan(nx, 2 * depth + 6);
    XCTAssertGreaterThan(ny, 2 * depth + 6);

    const std::uint32_t x0 = depth + 3, x1 = nx - depth - 4;
    const std::uint32_t y0 = depth + 3, y1 = ny - depth - 4;
    copper::CopperFDTDPortConfig config;
    config.domainCutoutLoops = {{{op.discLine(0, x0), op.discLine(1, y0)},
                                  {op.discLine(0, x1), op.discLine(1, y0)},
                                  {op.discLine(0, x1), op.discLine(1, y1)},
                                  {op.discLine(0, x0), op.discLine(1, y1)}}};
    config.domainCPMLCellSize = op.discLine(0, 1) - op.discLine(0, 0);

    const copper::CopperDomainMask mask = copper::buildDomainMask(op, config, depth);
    XCTAssertFalse(mask.empty());
    XCTAssertEqual(mask.at(0, 0), 0);
    XCTAssertEqual(mask.at((x0 + x1) / 2, (y0 + y1) / 2), 1);

    std::vector<double> xCoordinates(nx), yCoordinates(ny);
    for (std::uint32_t x = 0; x < nx; ++x) xCoordinates[x] = op.discLine(0, x);
    for (std::uint32_t y = 0; y < ny; ++y) yCoordinates[y] = op.discLine(1, y);
    const copper::CopperDomainMask previewMask =
        copper::buildDomainMask(xCoordinates, yCoordinates, config, depth);
    XCTAssertEqual(previewMask.xyClass.size(), mask.xyClass.size());
    XCTAssertTrue(previewMask.xyClass == mask.xyClass,
                  @"the coordinate-only preview classifier must exactly match the solver classifier");
    XCTAssertEqual(previewMask.dispatchBoxes.size(), mask.dispatchBoxes.size());

    std::size_t cpmlNodes = 0, externalNodes = 0;
    for (const std::uint8_t c : mask.xyClass) {
        if (c == 0) ++externalNodes;
        if (c >= 2) ++cpmlNodes;
    }
    XCTAssertGreaterThan(externalNodes, static_cast<std::size_t>(0));
    XCTAssertGreaterThan(cpmlNodes, static_cast<std::size_t>(0));

    std::vector<std::uint8_t> covered(mask.xyClass.size(), 0);
    std::size_t interiorBoxes = 0, cpmlBoxes = 0;
    for (const auto& box : mask.dispatchBoxes) {
        if (box.region == copper::CopperDomainMask::Region::Interior) ++interiorBoxes;
        else ++cpmlBoxes;
        for (std::uint32_t y = box.startY; y < box.startY + box.height; ++y) {
            for (std::uint32_t x = box.startX; x < box.startX + box.width; ++x) {
                const std::size_t i = static_cast<std::size_t>(x) + static_cast<std::size_t>(mask.nx) * y;
                XCTAssertEqual(covered[i]++, 0, @"dispatch rectangles overlap");
                if (box.region == copper::CopperDomainMask::Region::Interior)
                    XCTAssertEqual(mask.xyClass[i], 1, @"an interior cuboid contains a non-interior node");
                else
                    XCTAssertGreaterThanOrEqual(mask.xyClass[i], 2,
                                                @"a CPML cuboid contains a non-CPML node");
            }
        }
    }
    for (std::size_t i = 0; i < covered.size(); ++i) {
        if (mask.xyClass[i] != 0) {
            XCTAssertEqual(covered[i], 1, @"dispatch rectangles must cover each active node exactly once");
        } else {
            XCTAssertEqual(covered[i], 0, @"external nodes must not be dispatched");
        }
    }
    XCTAssertGreaterThan(interiorBoxes, static_cast<std::size_t>(0));
    XCTAssertGreaterThan(cpmlBoxes, static_cast<std::size_t>(0));
    XCTAssertLessThanOrEqual(mask.dispatchBoxes.size(), mask.xyClass.size(),
                             @"run merging must never produce more cuboids than raster nodes");

    // The irregular form is the Z slabs only (the XY rings are a matched lossy absorber, not a CPML
    // -- see CopperCPML.hpp), graded along Z alone and so stored per plane: `depth` planes at the
    // bottom and one more at the top, whose first plane holds only the H-side half-cell grading.
    const auto nz = op.numberOfLines(2);
    const copper::CopperZCPML zcpml = copper::buildZCPML(op, 2 * M_PI * 100e6 * copper::physical::epsilon0, depth);
    XCTAssertEqual(zcpml.layerOfZ.size(), static_cast<std::size_t>(nz));
    XCTAssertEqual(zcpml.layerCount(), 2 * depth + 1);
    for (std::uint32_t z = 0; z < nz; ++z) {
        const bool graded = z < depth || z >= nz - depth - 1;
        XCTAssertEqual(zcpml.layerOfZ[z] != copper::CopperZCPML::kNoLayer, graded, @"plane %u", z);
    }
    const std::uint32_t upperFirst = zcpml.layerOfZ[nz - depth - 1];
    XCTAssertEqual(zcpml.cE[upperFirst], 0.0F, @"E-side grading is zero on the PML's inner edge");
    XCTAssertLessThan(zcpml.cH[upperFirst], 0.0F, @"H-side grading is not");
    XCTAssertLessThan(zcpml.cE[zcpml.layerOfZ[nz - depth]], 0.0F);
}

/// The ring absorber samples its profile at each Yee component's own staggered XY position: the
/// node sample must agree with xyClass, every sample of a cell strictly inside the cutout must be
/// 0, and every sample of a node outside the outermost ring must read the outermost layer.
- (void)testStaggeredRingLayersAreConsistentWithNodeClasses {
    copper::CopperOperator::Config operatorConfig;
    operatorConfig.f0 = 2.5e9;
    operatorConfig.fc = 2.5e9;
    operatorConfig.maxTimesteps = 30;
    copper::CopperOperator op(*buildCpmlCavityNoExcitation(), operatorConfig);

    constexpr std::uint32_t depth = 3;
    const auto nx = op.numberOfLines(0), ny = op.numberOfLines(1);
    const std::uint32_t x0 = depth + 3, x1 = nx - depth - 4;
    const std::uint32_t y0 = depth + 3, y1 = ny - depth - 4;
    copper::CopperFDTDPortConfig config;
    config.domainCutoutLoops = {{{op.discLine(0, x0), op.discLine(1, y0)},
                                  {op.discLine(0, x1), op.discLine(1, y0)},
                                  {op.discLine(0, x1), op.discLine(1, y1)},
                                  {op.discLine(0, x0), op.discLine(1, y1)}}};
    config.domainCPMLCellSize = op.discLine(0, 1) - op.discLine(0, 0);
    const copper::CopperDomainMask mask = copper::buildDomainMask(op, config, depth);
    XCTAssertEqual(mask.ringLayerMetres, 1e-3, @"one fixture cell (1 mm) per ring layer");

    std::size_t ringSamples = 0;
    for (std::uint32_t y = 0; y < ny; ++y) {
        for (std::uint32_t x = 0; x < nx; ++x) {
            const std::uint8_t cls = mask.at(x, y);
            const std::uint8_t node = mask.layerAt(copper::CopperDomainMask::Node, x, y);
            XCTAssertEqual(node, cls == 0 ? depth : (cls == 1 ? 0 : cls - 1));
            const bool cellInsideCutout = x >= x0 && x < x1 && y >= y0 && y < y1;
            for (const auto position : {copper::CopperDomainMask::HalfX, copper::CopperDomainMask::HalfY,
                                        copper::CopperDomainMask::HalfXY}) {
                const std::uint8_t layer = mask.layerAt(position, x, y);
                XCTAssertLessThanOrEqual(layer, depth);
                if (cellInsideCutout) XCTAssertEqual(layer, 0, @"a sample inside the cutout is absorbing");
                if (x == 0 && y == 0) XCTAssertEqual(layer, depth, @"a sample past the rings isn't outermost");
                if (layer > 0) ++ringSamples;
            }
        }
    }
    XCTAssertGreaterThan(ringSamples, static_cast<std::size_t>(0));
}

/// Regression test for the irregular domain's original ring-graded CPML: grading sigma_x/sigma_y
/// by an outline-following ring is not a valid coordinate stretch (see CopperCPML.hpp), and that
/// version grew this seeded impulse's energy ~10^6-fold within 500 steps and without bound after.
/// The matched ring absorber is passive: energy may only fall (to the impulse's static charge
/// remnant) and must then stay flat.
- (void)testIrregularDomainRemainsStableOverLongRun {
    copper::CopperOperator::Config operatorConfig;
    operatorConfig.f0 = 2.5e9;
    operatorConfig.fc = 2.5e9;
    operatorConfig.maxTimesteps = 30;
    copper::CopperOperator op(*buildCpmlCavityNoExcitation(), operatorConfig);

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
    const copper::CopperZCPML zcpml = copper::buildZCPML(op, 2 * M_PI * 100e6 * copper::physical::epsilon0, depth);

    copper::CopperEngine cpu(op.grid(), {}, {}, copper::CopperEngine::Backend::CPU, mask, zcpml);
    cpu.writeFieldCell(copper::CopperEngine::Field::Ez, nx / 2, ny / 2, nz / 2, 1.0F);
    const double initialEnergy = cpu.estimateEnergy();
    cpu.run(500);
    const double settledEnergy = cpu.estimateEnergy();
    XCTAssertLessThanOrEqual(settledEnergy, initialEnergy);
    cpu.run(2500);
    const double finalEnergy = cpu.estimateEnergy();
    XCTAssertTrue(std::isfinite(finalEnergy));
    XCTAssertLessThanOrEqual(finalEnergy, settledEnergy * 1.001,
                             @"energy grew in a passive domain: %g -> %g", settledEnergy, finalEnergy);
}

- (void)testClassPureCuboidsMatchCPUReferenceWithoutShaderMaskChecks {
    copper::CopperOperator::Config operatorConfig;
    operatorConfig.f0 = 2.5e9;
    operatorConfig.fc = 2.5e9;
    operatorConfig.maxTimesteps = 30;
    copper::CopperOperator op(*buildCpmlCavityNoExcitation(), operatorConfig);

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
    const copper::CopperZCPML zcpml = copper::buildZCPML(op, 2 * M_PI * 100e6 * copper::physical::epsilon0, depth);

    copper::CopperEngine metal(op.grid(), {}, {}, copper::CopperEngine::Backend::Metal, mask, zcpml);
    copper::CopperEngine cpu(op.grid(), {}, {}, copper::CopperEngine::Backend::CPU, mask, zcpml);
    const std::uint32_t seedX = (x0 + x1) / 2, seedY = (y0 + y1) / 2, seedZ = nz / 2;
    metal.writeFieldCell(copper::CopperEngine::Field::Ez, seedX, seedY, seedZ, 1.0F);
    cpu.writeFieldCell(copper::CopperEngine::Field::Ez, seedX, seedY, seedZ, 1.0F);
    metal.run(4);
    cpu.run(4);

    for (const auto field : kAllFields) {
        const std::vector<float> metalValues = metal.readField(field);
        const std::vector<float> cpuValues = cpu.readField(field);
        XCTAssertEqual(metalValues.size(), cpuValues.size());
        float maxValue = 0.0F, maxDifference = 0.0F;
        for (std::size_t i = 0; i < metalValues.size(); ++i) {
            maxValue = std::max(maxValue, std::abs(cpuValues[i]));
            maxDifference = std::max(maxDifference, std::abs(metalValues[i] - cpuValues[i]));
        }
        XCTAssertLessThanOrEqual(maxDifference, 1e-5F * std::max(maxValue, 1.0F));

        for (std::uint32_t y = 0; y < ny; ++y) {
            for (std::uint32_t x = 0; x < nx; ++x) {
                if (mask.at(x, y) != 0) continue;
                for (std::uint32_t z = 0; z < nz; ++z) {
                    const std::size_t i = copper::copperGridIndex(op.grid().dims, x, y, z);
                    XCTAssertEqual(metalValues[i], 0.0F, @"an external cell was updated by Metal");
                }
            }
        }
    }
}

@end
