// Unit tests for the pure extraction layer (CopperYeeGrid/CopperExcitation) plus CalcPEC's
// paint-cache cross-check -- the pieces that just walk openEMS's own already-built Operator/
// Excitation into flat buffers, with no GPU/Metal involvement at all. These are exactly the
// functions a future CPU backend would also need to produce identical answers from, so pinning
// their behavior precisely (not just "didn't crash") is what gives confidence a CPU port built on
// top of them still works.
#import <XCTest/XCTest.h>

#include <cmath>
#include <iomanip>
#include <random>
#include <sstream>
#include <string>
#include <vector>

#include <CSPrimPolygon.h>
#include <CSPropMetal.h>

#include "CopperTestFixtures.hpp"
#include "Internal/CopperExcitation.hpp"
#include "Internal/CopperOpenEMSAccess.hpp"
#include "Internal/CopperOperator.hpp"
#include "Internal/CopperYeeGrid.hpp"

using namespace copper::test;

namespace {

// Builds a standalone, Z-normal CSPrimPolygon from a flat x0,y0,x1,y1,... vertex list -- no grid,
// no CSX ownership transfer, just enough (a ParameterSet + a property to hang the primitive off of)
// for CSPrimPolygon::Update()/IsInside()/GetBoundBox() to work standalone. `csx` must outlive the
// returned pointer (it owns the property, which owns the primitive).
CSPrimPolygon* buildTestPolygon(ContinuousStructure& csx, const std::vector<double>& flatCoords, double elevation) {
    auto* metal = new CSPropMetal(csx.GetParameterSet());
    csx.AddProperty(metal);
    auto* poly = new CSPrimPolygon(metal->GetParameterSet(), metal); // constructor already registers poly with metal
    poly->ClearCoords();
    for (double c : flatCoords) {
        poly->AddCoord(c);
    }
    poly->SetNormDir(2);
    poly->SetElevation(elevation);
    poly->Update();
    return poly;
}

// Every point in `xs` x `ys` must agree, bit-for-bit, between CopperOperator::rasterizePolygonRow()
// and a brute-force per-point CSPrimitives::IsInside() call at exactly `poly`'s own elevation (the
// rasterizer deliberately doesn't reproduce IsInside()'s bbox check on the elevation axis -- see its
// own doc comment -- so the equivalence is only meaningful when the query z already matches). Returns
// an empty string if every point matched, otherwise a description of the first mismatch found --
// returning a description rather than asserting directly lets the actual XCTest method report the
// failure with correct file/line attribution (asserting from a free function/helper is unreliable).
std::string firstRasterMismatch(CSPrimPolygon* poly, const std::vector<double>& xs, const std::vector<double>& ys,
                                  double elevation) {
    copper::CopperOperator::PolygonRasterShape shape;
    if (!copper::CopperOperator::tryBuildPolygonRasterShape(poly, shape)) {
        return "tryBuildPolygonRasterShape rejected a plain Z-normal Cartesian polygon";
    }

    std::vector<double> sortedXs = xs;
    std::sort(sortedXs.begin(), sortedXs.end());

    for (double y : ys) {
        std::vector<bool> rasterInside;
        copper::CopperOperator::rasterizePolygonRow(shape, y, sortedXs, rasterInside);
        for (std::size_t i = 0; i < sortedXs.size(); ++i) {
            const double coord[3] = {sortedXs[i], y, elevation};
            const bool bruteForce = poly->IsInside(coord);
            if (rasterInside[i] != bruteForce) {
                std::ostringstream oss;
                oss << "mismatch at x=" << std::setprecision(17) << sortedXs[i] << " y=" << y
                    << " (elevation " << elevation << "): raster=" << rasterInside[i] << " isInside=" << bruteForce;
                return oss.str();
            }
        }
    }
    return "";
}

// A fine grid plus every vertex coordinate itself (and the midpoint between consecutive vertices'
// matching axis, for on-cartesian-edge coverage) -- deliberately including exact boundary values,
// not just interior points, since that's exactly where a hand-transcribed winding-number algorithm
// is most likely to diverge from the original.
std::vector<double> denseProbeValues(const std::vector<double>& vertexValues, double lo, double hi, double step) {
    std::vector<double> out;
    for (double v = lo; v <= hi + 1e-9; v += step) {
        out.push_back(v);
    }
    for (double v : vertexValues) {
        out.push_back(v);
    }
    return out;
}

} // namespace

@interface CopperYeeGridExtractionTests : XCTestCase
@end

@implementation CopperYeeGridExtractionTests

/// CalcPEC's primitive-paint cache (Operator::PaintPECColumn) must pick exactly the same winning
/// primitive per Yee edge as the old per-edge GetPropertyByCoordPriority query it replaced -- ported
/// from Copper_smoketest's own Phase 0b, since that regression is invisible to every other test here
/// (they only ever look at the resulting vv/vi/ii/iv, not which primitive produced them).
- (void)testCalcPECPaintCacheMatchesLegacyPriorityQuery {
    ContinuousStructure* pecCsx = buildPecPaintFixture();
    copper::CopperOpenEMS fdtd;
    fdtd.SetCSX(pecCsx);
    fdtd.SetGaussExcite(2.5e9, 2.5e9);
    for (int side = 0; side < 6; ++side) {
        fdtd.Set_BC_Type(side, 0);
    }
    fdtd.SetNumberOfTimeSteps(10);
    XCTAssertEqual(fdtd.SetupFDTD(), 0);

    Operator* op = fdtd.GetOperatorForGPU();
    XCTAssertTrue(op != nullptr);
    auto* access = static_cast<copper::CopperOperatorAccess*>(op);

    unsigned int paintedMetal[3] = {0, 0, 0};
    unsigned int pos[3] = {0, 0, 0};
    double coord[3];
    OperatorPECColumnCache cache;
    for (pos[0] = 0; pos[0] < op->GetNumberOfLines(0); ++pos[0]) {
        for (pos[1] = 0; pos[1] < op->GetNumberOfLines(1); ++pos[1]) {
            access->PaintPECColumn(pos[0], pos[1], cache);
            const std::vector<CSPrimitives*> candidates = op->GetPrimitivesBoundBox(
                static_cast<int>(pos[0]), static_cast<int>(pos[1]), -1,
                static_cast<CSProperties::PropertyType>(CSProperties::MATERIAL | CSProperties::METAL));
            for (pos[2] = 0; pos[2] < op->GetNumberOfLines(2); ++pos[2]) {
                for (int axis = 0; axis < 3; ++axis) {
                    op->GetYeeCoords(axis, pos, coord, false);
                    CSPrimitives* referenceWinner = nullptr;
                    pecCsx->GetPropertyByCoordPriority(coord, candidates, false, &referenceWinner);
                    XCTAssertEqual(cache.data[axis][pos[2]], referenceWinner,
                                   @"paint-cache winner differs from the legacy priority query");
                    if (referenceWinner != nullptr && referenceWinner->GetProperty()->GetType() == CSProperties::METAL) {
                        ++paintedMetal[axis];
                    }
                }
            }
        }
    }
    for (int axis = 0; axis < 3; ++axis) {
        XCTAssertEqual(paintedMetal[axis], access->m_Nr_PEC[axis],
                       @"CalcPEC's applied PEC count differs from the paint-cache reference (axis %d)", axis);
    }
}

- (void)testYeeGridDimsAndTimestepMatchOperator {
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

    XCTAssertEqual(op->GetNumberOfLines(0), 11U);
    XCTAssertEqual(op->GetNumberOfLines(1), 11U);
    XCTAssertEqual(op->GetNumberOfLines(2), 3U);

    const FDTD_FLOAT vv = op->GetVV(0, 5, 5, 1);
    const FDTD_FLOAT vi = op->GetVI(0, 5, 5, 1);
    XCTAssertTrue(vv > 0.99F && vv <= 1.0F, @"interior vv coefficient outside the expected lossless-vacuum range");
    XCTAssertTrue(std::isfinite(vi) && vi > 0.0F, @"interior vi coefficient not a sane positive finite value");

    const copper::CopperYeeGrid grid = copper::buildYeeGrid(*op);
    XCTAssertEqual(grid.dims.nx, op->GetNumberOfLines(0));
    XCTAssertEqual(grid.dims.ny, op->GetNumberOfLines(1));
    XCTAssertEqual(grid.dims.nz, op->GetNumberOfLines(2));
    XCTAssertEqual(grid.timestepSeconds, op->GetTimestep());
}

/// Every (axis, x, y, z) coefficient, not just a sample -- cheap (363 cells x 3 axes) and this is the
/// whole point of this test: proving the extraction/indexing never silently mismaps a value.
- (void)testYeeGridCoefficientsMatchOperatorExactlyEverywhere {
    copper::CopperOpenEMS fdtd;
    fdtd.SetCSX(buildTinyVacuumGrid());
    fdtd.SetGaussExcite(2.5e9, 2.5e9);
    for (int side = 0; side < 6; ++side) {
        fdtd.Set_BC_Type(side, 0);
    }
    fdtd.SetNumberOfTimeSteps(150);
    XCTAssertEqual(fdtd.SetupFDTD(), 0);
    Operator* op = fdtd.GetOperatorForGPU();
    const copper::CopperYeeGrid grid = copper::buildYeeGrid(*op);

    const unsigned int nx = op->GetNumberOfLines(0);
    const unsigned int ny = op->GetNumberOfLines(1);
    const unsigned int nz = op->GetNumberOfLines(2);
    for (unsigned int axis = 0; axis < 3; ++axis) {
        for (unsigned int z = 0; z < nz; ++z) {
            for (unsigned int y = 0; y < ny; ++y) {
                for (unsigned int x = 0; x < nx; ++x) {
                    const std::uint32_t idx = copper::copperGridIndex(grid.dims, x, y, z);
                    XCTAssertEqual(grid.vv[axis][idx], op->GetVV(axis, x, y, z));
                    XCTAssertEqual(grid.vi[axis][idx], op->GetVI(axis, x, y, z));
                    XCTAssertEqual(grid.ii[axis][idx], op->GetII(axis, x, y, z));
                    XCTAssertEqual(grid.iv[axis][idx], op->GetIV(axis, x, y, z));
                }
            }
        }
    }
}

/// Primary/dual line positions, spot-checked at domain edges where dual-mesh mirroring kicks in.
/// Cast to float before comparing, matching CopperYeeGrid's own double-to-float narrowing.
- (void)testYeeGridLinePositionsMatchOperator {
    copper::CopperOpenEMS fdtd;
    fdtd.SetCSX(buildTinyVacuumGrid());
    fdtd.SetGaussExcite(2.5e9, 2.5e9);
    for (int side = 0; side < 6; ++side) {
        fdtd.Set_BC_Type(side, 0);
    }
    fdtd.SetNumberOfTimeSteps(150);
    XCTAssertEqual(fdtd.SetupFDTD(), 0);
    Operator* op = fdtd.GetOperatorForGPU();
    const copper::CopperYeeGrid grid = copper::buildYeeGrid(*op);
    const unsigned int nx = op->GetNumberOfLines(0);

    XCTAssertEqual(grid.lineX[0], static_cast<float>(op->GetDiscLine(0, 0, false) * op->GetGridDelta()));
    XCTAssertEqual(grid.lineX[nx - 1], static_cast<float>(op->GetDiscLine(0, nx - 1, false) * op->GetGridDelta()));
    XCTAssertEqual(grid.dualLineX[0], static_cast<float>(op->GetDiscLine(0, 0, true) * op->GetGridDelta()));
    XCTAssertEqual(grid.dualLineX[nx - 1],
                   static_cast<float>(op->GetDiscLine(0, nx - 1, true) * op->GetGridDelta()));
}

- (void)testExcitationExtractionMatchesOperatorSignalAndFindsExcitedCell {
    copper::CopperOpenEMS fdtd;
    fdtd.SetCSX(buildTinyVacuumGrid());
    fdtd.SetGaussExcite(2.5e9, 2.5e9);
    for (int side = 0; side < 6; ++side) {
        fdtd.Set_BC_Type(side, 0);
    }
    fdtd.SetNumberOfTimeSteps(150);
    XCTAssertEqual(fdtd.SetupFDTD(), 0);
    Operator* op = fdtd.GetOperatorForGPU();

    const copper::CopperExcitation excitation = copper::buildExcitation(*op);
    Excitation* exc = op->GetExcitationSignal();
    XCTAssertTrue(exc != nullptr, @"SetGaussExcite wasn't honored");
    XCTAssertEqual(excitation.voltageSignal.size(), static_cast<std::size_t>(exc->GetLength()));
    XCTAssertEqual(excitation.currentSignal.size(), static_cast<std::size_t>(exc->GetLength()));
    for (unsigned int i = 0; i < exc->GetLength(); ++i) {
        XCTAssertEqual(excitation.voltageSignal[i], exc->GetVoltageSignal()[i]);
        XCTAssertEqual(excitation.currentSignal[i], exc->GetCurrentSignal()[i]);
    }

    XCTAssertFalse(excitation.voltageCells.empty(), @"the test fixture's excitation box wasn't picked up");
    const copper::CopperExcitationCell& cell = excitation.voltageCells.front();
    XCTAssertEqual(cell.axis, 2U, @"excited cell's axis isn't z, contradicting the fixture's own excitation direction");
    XCTAssertTrue(std::isfinite(cell.amplitude) && cell.amplitude != 0.0F);
}

/// CopperOperator::rasterizePolygonRow() must reproduce CSPrimitives::IsInside()'s winding-number-
/// plus-on-cartesian-edge decision exactly, for every axis-aligned/diagonal/concave shape kiems's
/// own copper-pour/trace geometry can produce -- this is the whole safety net for replacing a
/// per-point IsInside() loop with a per-row scanline sweep in computeMaterialCoefficients()/
/// computePEC() (see CopperOperator.hpp's own top comment for why that replacement exists and must
/// not be reverted).
- (void)testPolygonRasterMatchesIsInsideForHandCraftedShapes {
    struct Shape {
        const char* name;
        std::vector<double> flatCoords;
    };
    const std::vector<Shape> shapes = {
        {"axis-aligned square", {0.5, 0.5, 3.5, 0.5, 3.5, 3.5, 0.5, 3.5}},
        {"right triangle", {0.0, 0.0, 4.0, 0.0, 0.0, 4.0}},
        {"concave chevron", {0.0, 0.0, 4.0, 0.0, 4.0, 4.0, 2.0, 2.0, 0.0, 4.0}},
        {"self-touching bowtie", {0.0, 0.0, 4.0, 4.0, 4.0, 0.0, 0.0, 4.0}},
        {"L-shape with collinear vertex", {0.0, 0.0, 4.0, 0.0, 4.0, 2.0, 2.0, 2.0, 2.0, 4.0, 0.0, 4.0}},
    };
    const double elevation = 1.5;

    for (const Shape& shape : shapes) {
        ContinuousStructure csx;
        CSPrimPolygon* poly = buildTestPolygon(csx, shape.flatCoords, elevation);

        std::vector<double> vertexXs, vertexYs;
        for (std::size_t i = 0; i < shape.flatCoords.size() / 2; ++i) {
            vertexXs.push_back(shape.flatCoords[2 * i]);
            vertexYs.push_back(shape.flatCoords[2 * i + 1]);
        }
        const std::vector<double> xs = denseProbeValues(vertexXs, -1.0, 5.0, 0.2);
        const std::vector<double> ys = denseProbeValues(vertexYs, -1.0, 5.0, 0.2);

        const std::string mismatch = firstRasterMismatch(poly, xs, ys, elevation);
        XCTAssertTrue(mismatch.empty(), @"%s: %s", shape.name, mismatch.c_str());
    }
}

/// Same equivalence check as testPolygonRasterMatchesIsInsideForHandCraftedShapes, but fuzzed over
/// many random polygons (random vertex counts/positions, including duplicate/collinear coordinates
/// that tend to hit the on-cartesian-edge special cases) -- a hand-picked set of shapes can miss
/// combinations a hand-transcribed winding-number algorithm gets subtly wrong.
- (void)testPolygonRasterMatchesIsInsideForRandomizedShapes {
    std::mt19937 rng(0xC0FFEE);
    std::uniform_int_distribution<int> vertexCountDist(3, 10);
    std::uniform_real_distribution<double> coordDist(0.0, 6.0);
    std::uniform_int_distribution<int> snapDist(0, 2); // occasionally snap to a coarse grid to force shared x/y values

    for (int shapeIdx = 0; shapeIdx < 40; ++shapeIdx) {
        const int vertexCount = vertexCountDist(rng);
        std::vector<double> flatCoords;
        std::vector<double> vertexXs, vertexYs;
        for (int v = 0; v < vertexCount; ++v) {
            double x = coordDist(rng);
            double y = coordDist(rng);
            if (snapDist(rng) == 0) {
                x = std::round(x);
            }
            if (snapDist(rng) == 0) {
                y = std::round(y);
            }
            flatCoords.push_back(x);
            flatCoords.push_back(y);
            vertexXs.push_back(x);
            vertexYs.push_back(y);
        }

        ContinuousStructure csx;
        CSPrimPolygon* poly = buildTestPolygon(csx, flatCoords, 1.5);

        const std::vector<double> xs = denseProbeValues(vertexXs, -1.0, 7.0, 0.5);
        const std::vector<double> ys = denseProbeValues(vertexYs, -1.0, 7.0, 0.5);

        const std::string mismatch = firstRasterMismatch(poly, xs, ys, 1.5);
        XCTAssertTrue(mismatch.empty(), @"random shape #%d: %s", shapeIdx, mismatch.c_str());
    }
}

/// No excitation properties in the CSX at all -- buildExcitation() should tolerate that the same way
/// openEMS itself does (a warning, not a hard failure), returning an empty (not garbage) result.
- (void)testExcitationExtractionIsEmptyNotErrorWhenNoExcitationExists {
    copper::CopperOpenEMS fdtd;
    fdtd.SetCSX(buildPecCavityNoExcitation());
    fdtd.SetGaussExcite(2.5e9, 2.5e9);
    for (int side = 0; side < 6; ++side) {
        fdtd.Set_BC_Type(side, 0);
    }
    fdtd.SetNumberOfTimeSteps(10);
    XCTAssertEqual(fdtd.SetupFDTD(), 0);
    Operator* op = fdtd.GetOperatorForGPU();

    const copper::CopperExcitation excitation = copper::buildExcitation(*op);
    XCTAssertTrue(excitation.voltageCells.empty());
    XCTAssertTrue(excitation.currentCells.empty());
}

@end
