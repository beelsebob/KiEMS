// CopperOperator's mesh/coefficient/excitation construction, checked against closed forms and
// brute-force CSXCAD queries rather than a second solver: uniform-vacuum and filled-material
// coefficients and CFL timestep, per-axis geometry on a graded mesh, per-edge PEC resolution against
// ContinuousStructure::GetPropertyByCoordPriority(), the Gaussian pulse and its excited edge, and the
// polygon scanline rasterizer against CSPrimitives::IsInside(). No GPU/Metal involvement at all.
#import <XCTest/XCTest.h>

#include <cmath>
#include <iomanip>
#include <memory>
#include <random>
#include <sstream>
#include <string>
#include <vector>

#include <CSPrimBox.h>
#include <CSPrimPolygon.h>
#include <CSPropMaterial.h>
#include <CSPropMetal.h>
#include <CSRectGrid.h>

#include "CopperTestFixtures.hpp"
#include "Internal/CopperExcitation.hpp"
#include "Internal/CopperOperator.hpp"
#include "Internal/CopperPhysicalConstants.hpp"
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

/// Uniform `cells`-cell cube of `spacing` drawing units (1 mm), optionally filled edge to edge (and
/// beyond, so every edge sees the same material) with one material.
std::unique_ptr<ContinuousStructure> buildUniformCube(int cells, double epsR = 1.0, double kappa = 0.0,
                                                      double mueR = 1.0, double sigma = 0.0) {
    auto csx = std::make_unique<ContinuousStructure>();
    CSRectGrid* grid = csx->GetGrid();
    grid->SetDeltaUnit(1e-3);
    for (int axis = 0; axis < 3; ++axis) {
        for (int i = 0; i <= cells; ++i) grid->AddDiscLine(axis, static_cast<double>(i));
    }
    if (epsR != 1.0 || kappa != 0.0 || mueR != 1.0 || sigma != 0.0) {
        auto* material = new CSPropMaterial(csx->GetParameterSet());
        material->SetName("fill");
        material->SetEpsilon(epsR);
        material->SetKappa(kappa);
        material->SetMue(mueR);
        material->SetSigma(sigma);
        csx->AddProperty(material);
        auto* box = new CSPrimBox(material->GetParameterSet(), material);
        for (int axis = 0; axis < 3; ++axis) {
            box->SetCoord(2 * axis, -1.0);
            box->SetCoord(2 * axis + 1, cells + 1.0);
        }
    }
    return csx;
}

/// Checks every interior cell's coefficients against the lossy-capacitor/inductor closed forms
/// vv=(1-dT*G/2C)/(1+dT*G/2C), vi=(dT/C)/(1+dT*G/2C) (and ii/iv with L, R), for a uniform 1 mm cell
/// filled with one material: C = eps*1mm, G = kappa*1mm, L = mu*1mm, R = sigma*1mm. Returns the
/// number of mismatching values.
std::size_t countUniformCoefficientMismatches(const copper::CopperYeeGrid& grid, double epsR, double kappa,
                                              double mueR, double sigma) {
    const double dT = grid.timestepSeconds;
    const double d = 1e-3;
    const double c = epsR * copper::physical::epsilon0 * d, g = kappa * d;
    const double l = mueR * copper::physical::mu0 * d, r = sigma * d;
    const double expected[4] = {(1.0 - dT * g / 2.0 / c) / (1.0 + dT * g / 2.0 / c),
                                (dT / c) / (1.0 + dT * g / 2.0 / c),
                                (1.0 - dT * r / 2.0 / l) / (1.0 + dT * r / 2.0 / l),
                                (dT / l) / (1.0 + dT * r / 2.0 / l)};
    std::size_t mismatches = 0;
    for (int axis = 0; axis < 3; ++axis) {
        const std::vector<float>* arrays[4] = {&grid.vv[axis], &grid.vi[axis], &grid.ii[axis], &grid.iv[axis]};
        for (std::uint32_t z = 1; z + 1 < grid.dims.nz; ++z) {
            for (std::uint32_t y = 1; y + 1 < grid.dims.ny; ++y) {
                for (std::uint32_t x = 1; x + 1 < grid.dims.nx; ++x) {
                    const std::uint32_t i = copper::copperGridIndex(grid.dims, x, y, z);
                    for (int k = 0; k < 4; ++k) {
                        if (std::fabs((*arrays[k])[i] - expected[k]) > 1e-6 * std::fabs(expected[k])) ++mismatches;
                    }
                }
            }
        }
    }
    return mismatches;
}

} // namespace

@interface CopperYeeGridExtractionTests : XCTestCase
@end

@implementation CopperYeeGridExtractionTests

/// Uniform 1 mm vacuum: every interior coefficient is the plain capacitor/inductor value, and the
/// timestep is exactly the 3D Courant limit dx/(c*sqrt(3)) -- what the Var3 criterion reduces to when
/// every cell is identical.
- (void)testUniformVacuumCoefficientsAndTimestepMatchClosedForm {
    const auto csx = buildUniformCube(8);
    const copper::CopperOperator op(*csx, pulseConfig(10, /*pecBox=*/false));
    const copper::CopperYeeGrid& grid = op.grid();
    XCTAssertEqual(grid.dims.nx, 9U);
    XCTAssertEqual(grid.dims.ny, 9U);
    XCTAssertEqual(grid.dims.nz, 9U);

    const double c0 = 1.0 / std::sqrt(copper::physical::epsilon0 * copper::physical::mu0);
    const double courant = 1e-3 / (c0 * std::sqrt(3.0));
    XCTAssertEqualWithAccuracy(grid.timestepSeconds, courant, 1e-9 * courant);
    XCTAssertEqual(countUniformCoefficientMismatches(grid, 1.0, 0.0, 1.0, 0.0), static_cast<std::size_t>(0));
}

/// A lossy dielectric + lossy magnetic fill scales C/G/L/R exactly, and slows the Courant limit by
/// sqrt(epsR*muR).
- (void)testFilledLossyMaterialCoefficientsAndTimestepMatchClosedForm {
    constexpr double epsR = 4.3, kappa = 0.05, mueR = 2.5, sigma = 800.0;
    const auto csx = buildUniformCube(8, epsR, kappa, mueR, sigma);
    const copper::CopperOperator op(*csx, pulseConfig(10, /*pecBox=*/false));
    const copper::CopperYeeGrid& grid = op.grid();

    const double c0 = 1.0 / std::sqrt(copper::physical::epsilon0 * copper::physical::mu0);
    const double courant = 1e-3 * std::sqrt(epsR * mueR) / (c0 * std::sqrt(3.0));
    XCTAssertEqualWithAccuracy(grid.timestepSeconds, courant, 1e-9 * courant);
    XCTAssertEqual(countUniformCoefficientMismatches(grid, epsR, kappa, mueR, sigma), static_cast<std::size_t>(0));
}

/// On a mesh graded differently along each axis, every interior vacuum coefficient must carry its own
/// cell's geometry, one factor per axis: vi[n] = dT*primary[n]/(eps0*dual[nP]*dual[nPP]) and
/// iv[n] = dT*dual[n]/(mu0*primary[nP]*primary[nPP]) -- a transposed or shared factor shows up here
/// and not on any uniform mesh. Also pins the exposed line positions to the CSX's own lines.
- (void)testGradedVacuumCoefficientsCarryEachAxisOwnGeometry {
    auto csx = std::make_unique<ContinuousStructure>();
    CSRectGrid* mesh = csx->GetGrid();
    mesh->SetDeltaUnit(1e-3);
    const double firstSpacing[3] = {0.5, 0.4, 0.3}, growth[3] = {1.08, 1.12, 1.15};
    const int cells[3] = {14, 12, 10};
    std::vector<double> lines[3];
    for (int axis = 0; axis < 3; ++axis) {
        double line = 0.0, spacing = firstSpacing[axis];
        lines[axis].push_back(line);
        for (int i = 0; i < cells[axis]; ++i) {
            line += spacing;
            spacing *= growth[axis];
            lines[axis].push_back(line);
        }
        for (double l : lines[axis]) mesh->AddDiscLine(axis, l);
    }
    const copper::CopperOperator op(*csx, pulseConfig(10, /*pecBox=*/false));
    const copper::CopperYeeGrid& grid = op.grid();
    const double dT = grid.timestepSeconds;
    XCTAssertGreaterThan(dT, 0.0);

    const std::vector<float>* primaryLines[3] = {&grid.lineX, &grid.lineY, &grid.lineZ};
    for (int axis = 0; axis < 3; ++axis) {
        XCTAssertEqual(primaryLines[axis]->size(), lines[axis].size());
        for (std::size_t i = 0; i < lines[axis].size(); ++i) {
            XCTAssertEqual((*primaryLines[axis])[i], static_cast<float>(lines[axis][i] * 1e-3));
        }
        for (std::size_t i = 1; i + 1 < lines[axis].size(); ++i) {
            XCTAssertEqualWithAccuracy(grid.primaryDelta[axis][i], (lines[axis][i + 1] - lines[axis][i]) * 1e-3, 1e-15);
            XCTAssertEqualWithAccuracy(grid.dualDelta[axis][i], 0.5 * (lines[axis][i + 1] - lines[axis][i - 1]) * 1e-3,
                                       1e-15);
        }
    }

    std::size_t checked = 0, mismatches = 0;
    for (std::uint32_t z = 1; z + 1 < grid.dims.nz; ++z) {
        for (std::uint32_t y = 1; y + 1 < grid.dims.ny; ++y) {
            for (std::uint32_t x = 1; x + 1 < grid.dims.nx; ++x) {
                const std::uint32_t pos[3] = {x, y, z};
                const std::uint32_t i = copper::copperGridIndex(grid.dims, x, y, z);
                for (int n = 0; n < 3; ++n) {
                    const int nP = (n + 1) % 3, nPP = (n + 2) % 3;
                    const double vi = dT * grid.primaryDelta[n][pos[n]] /
                                      (copper::physical::epsilon0 * grid.dualDelta[nP][pos[nP]] * grid.dualDelta[nPP][pos[nPP]]);
                    const double iv = dT * grid.dualDelta[n][pos[n]] /
                                      (copper::physical::mu0 * grid.primaryDelta[nP][pos[nP]] *
                                       grid.primaryDelta[nPP][pos[nPP]]);
                    if (grid.vv[n][i] != 1.0F || grid.ii[n][i] != 1.0F) ++mismatches;
                    if (std::fabs(grid.vi[n][i] - vi) > 1e-6 * vi) ++mismatches;
                    if (std::fabs(grid.iv[n][i] - iv) > 1e-6 * iv) ++mismatches;
                    ++checked;
                }
            }
        }
    }
    XCTAssertGreaterThan(checked, static_cast<std::size_t>(0));
    XCTAssertEqual(mismatches, static_cast<std::size_t>(0));
}

/// Every Yee E edge must be PEC (vv=vi=0) exactly when CSXCAD's own priority query at that edge's Yee
/// point resolves to a METAL property -- on a fixture where a higher-priority material masks part of a
/// metal box and a zero-thickness polygon sits in the top plane. Open boundary on every face, so no
/// boundary PEC is mixed in.
- (void)testPECEdgesMatchBruteForcePriorityQuery {
    const std::unique_ptr<ContinuousStructure> csx(buildPecPaintFixture());
    const copper::CopperOperator op(*csx, pulseConfig(10, /*pecBox=*/false));
    const copper::CopperYeeGrid& grid = op.grid();
    const auto pecTypes = static_cast<CSProperties::PropertyType>(CSProperties::MATERIAL | CSProperties::METAL);

    std::size_t metalEdges = 0, maskedEdges = 0, mismatches = 0;
    unsigned int pos[3];
    double coord[3];
    for (pos[2] = 0; pos[2] < grid.dims.nz; ++pos[2]) {
        for (pos[1] = 0; pos[1] < grid.dims.ny; ++pos[1]) {
            for (pos[0] = 0; pos[0] < grid.dims.nx; ++pos[0]) {
                const std::uint32_t i = copper::copperGridIndex(grid.dims, pos[0], pos[1], pos[2]);
                for (int axis = 0; axis < 3; ++axis) {
                    if (!op.yeeCoords(axis, pos, coord, false)) continue;
                    CSProperties* winner = csx->GetPropertyByCoordPriority(coord, pecTypes, false);
                    const bool isMetal = winner != nullptr && winner->GetType() == CSProperties::METAL;
                    const bool isPEC = grid.vv[axis][i] == 0.0F && grid.vi[axis][i] == 0.0F;
                    if (isMetal != isPEC) ++mismatches;
                    if (isMetal) ++metalEdges;
                    if (winner != nullptr && winner->GetType() != CSProperties::METAL) ++maskedEdges;
                }
            }
        }
    }
    XCTAssertGreaterThan(metalEdges, static_cast<std::size_t>(0), @"fixture painted no PEC at all");
    XCTAssertGreaterThan(maskedEdges, static_cast<std::size_t>(0), @"fixture's material mask covered nothing");
    XCTAssertEqual(mismatches, static_cast<std::size_t>(0));
}

/// The Gaussian pulse is cos(2*pi*f0*(t-t0))*exp(-(2*pi*fc*t/3-3)^2) with t0 = 9/(2*pi*fc), sampled
/// at n*dT for E and (n+1/2)*dT for H, sample 0 forced to zero, length ceil(2*t0/dT) clamped to the
/// configured step count; the fixture's z-directed soft source excites exactly its one z edge with
/// amplitude 1 V/m times that edge's length.
- (void)testExcitationSignalAndExcitedEdgeMatchClosedForm {
    const std::unique_ptr<ContinuousStructure> csx(buildTinyVacuumGrid());
    for (const std::uint32_t maxTimesteps : {150U, 20U}) {
        const copper::CopperOperator op(*csx, pulseConfig(maxTimesteps));
        const copper::CopperExcitation& excitation = op.excitation();
        const double dT = op.timestepSeconds();
        const double f0 = 2.5e9, fc = 2.5e9, kPi = copper::physical::pi;
        const double t0 = 9.0 / (2.0 * kPi * fc);
        const auto expectedLength =
            std::min<std::size_t>(static_cast<std::size_t>(std::ceil(2.0 * t0 / dT)), maxTimesteps);
        XCTAssertEqual(excitation.voltageSignal.size(), expectedLength);
        XCTAssertEqual(excitation.currentSignal.size(), expectedLength);
        XCTAssertEqual(excitation.signalPeriodSeconds, 0.0);
        auto pulse = [&](double t) { return std::cos(2 * kPi * f0 * (t - t0)) * std::exp(-std::pow(2 * kPi * fc * t / 3 - 3, 2)); };
        for (std::size_t n = 0; n < expectedLength; ++n) {
            const double v = n == 0 ? 0.0 : pulse(static_cast<double>(n) * dT), c = n == 0 ? 0.0 : pulse((static_cast<double>(n) + 0.5) * dT);
            XCTAssertEqualWithAccuracy(excitation.voltageSignal[n], v, 1e-6);
            XCTAssertEqualWithAccuracy(excitation.currentSignal[n], c, 1e-6);
        }

        XCTAssertEqual(excitation.voltageCells.size(), static_cast<std::size_t>(1));
        XCTAssertTrue(excitation.currentCells.empty());
        const copper::CopperExcitationCell& cell = excitation.voltageCells.front();
        XCTAssertEqual(cell.x, 5U);
        XCTAssertEqual(cell.y, 5U);
        XCTAssertEqual(cell.z, 0U);
        XCTAssertEqual(cell.axis, 2U);
        XCTAssertEqual(cell.delaySteps, 0U);
        XCTAssertEqualWithAccuracy(cell.amplitude, 1e-3F, 1e-9F);
    }
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

/// No excitation properties in the CSX at all -- the operator should tolerate that (a warning, not a
/// hard failure), returning an empty (not garbage) excitation.
- (void)testExcitationIsEmptyNotErrorWhenNoExcitationExists {
    const std::unique_ptr<ContinuousStructure> csx(buildPecCavityNoExcitation());
    const copper::CopperOperator op(*csx, pulseConfig(10));
    XCTAssertTrue(op.excitation().voltageCells.empty());
    XCTAssertTrue(op.excitation().currentCells.empty());
}

@end
