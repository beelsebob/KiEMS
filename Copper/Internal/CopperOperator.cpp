#include "CopperOperator.hpp"

#include <algorithm>
#include <cmath>
#include <limits>

#include <CSPropExcitation.h>
#include <CSPropLumpedElement.h>
#include <CSPropMaterial.h>
#include <CSPropMetal.h>
#include <CSPrimBox.h>
#include <CSPrimLinPoly.h>
#include <CSPrimPolygon.h>
#include <CSRectGrid.h>

#include "CopperPhysicalConstants.hpp"

namespace copper {

namespace {

// Ported from Operator::AverageMatQuarterCell's own file-local MaterialValueFromCache -- resolves a
// cached column-paint winner (or the background material, if nothing painted this exact
// corner/tap) into one of the 4 weighted material quantities.
double materialValueFromCache(CSPropMaterial* mat, int matType, int axis, const double coord[3], double bgEpsR,
                               double bgKappa, double bgMueR, double bgSigma) {
    if (mat != nullptr) {
        switch (matType) {
        case 0:
            return mat->GetEpsilonWeighted(axis, coord);
        case 1:
            return mat->GetKappaWeighted(axis, coord);
        case 2:
            return mat->GetMueWeighted(axis, coord);
        case 3:
            return mat->GetSigmaWeighted(axis, coord);
        default:
            return 0.0;
        }
    }
    switch (matType) {
    case 0:
        return bgEpsR;
    case 1:
        return bgKappa;
    case 2:
        return bgMueR;
    case 3:
        return bgSigma;
    default:
        return 0.0;
    }
}

} // namespace

// ---- polygon scanline rasterization -- see this file's own header's top comment for why this
// exists at all (CSPrimitives::IsInside() called once per grid point was the dominant cost of
// CopperOperator's construction on a real board). Reproduces CSPrimPolygon::IsInside()'s own
// winding-number-plus-on-cartesian-edge algorithm exactly, edge by edge, in the same vertex-walk
// order (last-vertex-to-first, matching IsInside()'s own `x1,y1` starting point) -- not a
// re-derivation, a transcription, so it can be checked line-by-line against CSPrimPolygon.cpp's own
// IsInside() ----

bool CopperOperator::tryBuildPolygonRasterShape(CSPrimitives* prim, PolygonRasterShape& outShape) {
    CSPrimPolygon* poly = prim->ToPolygon();
    if (poly == nullptr) {
        poly = prim->ToLinPoly(); // CSPrimLinPoly derives from CSPrimPolygon; ToLinPoly() covers it
    }
    if (poly == nullptr) {
        return false;
    }
    // The rasterizer's callers feed it the mesh's own X/Y (axis 0/1) coordinates as the row/column
    // sweep -- only valid when those are also the polygon's own in-plane (nP,nPP) axes, i.e. its
    // normal is Z (2). libkiems never creates any other orientation (see this file's own top
    // comment), but a primitive that somehow did must fall back to the caller's plain IsInside()
    // loop rather than silently rasterizing the wrong plane.
    if (poly->GetNormDir() != 2) {
        return false;
    }
    if (poly->GetCoordInputType() != CARTESIAN) {
        return false; // IsInside()'s own TransformCoordSystem step would not be a no-op
    }
    if (poly->HasTransform()) {
        return false; // IsInside()'s own TransformCoords step would not be a no-op
    }
    const std::size_t n = poly->GetQtyCoords();
    if (n < 2) {
        return false; // CSPrimitives::IsInside() itself always returns false below this vertex count
    }
    outShape.x.resize(n);
    outShape.y.resize(n);
    for (std::size_t i = 0; i < n; ++i) {
        outShape.x[i] = poly->GetCoord(static_cast<int>(2 * i));
        outShape.y[i] = poly->GetCoord(static_cast<int>(2 * i + 1));
    }
    return true;
}

void CopperOperator::rasterizePolygonRow(const PolygonRasterShape& shape, double rowCoord,
                                           const std::vector<double>& sortedColCoords, std::vector<bool>& outInside) {
    const std::size_t nc = sortedColCoords.size();
    outInside.assign(nc, false);
    const std::size_t np = shape.x.size();
    if (np < 2 || nc == 0) {
        return;
    }

    // Winding-number contribution of every edge that crosses this row, expressed as a difference
    // array over sortedColCoords' indices (see below for why every edge's affected region is always
    // a prefix of the sorted column list) -- summed via one prefix-sum pass at the end instead of
    // per-point winding accumulation.
    std::vector<int> delta(nc + 1, 0);
    int wnBaseline = 0;

    // On-cartesian-edge overrides -- CSPrimitives::IsInside()'s own two special cases for a query
    // point sitting exactly on an axis-aligned edge (a horizontal edge contributes nothing to the
    // crossing count at all, since it never satisfies `startover != endover`; a vertical edge only
    // ever matters for the single column exactly at its own x). Collected once per edge here (independent
    // of which column is being evaluated) and applied per column below.
    std::vector<std::pair<double, double>> forcedOpenIntervals; // (lo, hi), strictly-between
    std::vector<double> forcedExactColumns;

    double x1 = shape.x[np - 1];
    double y1 = shape.y[np - 1];
    bool startover = (y1 >= rowCoord);
    for (std::size_t i = 0; i < np; ++i) {
        const double x2 = shape.x[i];
        const double y2 = shape.y[i];

        if ((x2 == x1) && (((rowCoord < y1) && (rowCoord > y2)) || ((rowCoord > y1) && (rowCoord < y2)))) {
            forcedExactColumns.push_back(x1);
        }
        if ((y2 == y1) && (y1 == rowCoord) && (x1 != x2)) {
            forcedOpenIntervals.emplace_back(std::min(x1, x2), std::max(x1, x2));
        }

        const bool endover = (y2 >= rowCoord);
        if (startover != endover) {
            // y1 != y2 is guaranteed here (equal y1/y2 would force startover == endover above).
            auto condAt = [&](double xv) { return (y2 - rowCoord) * (x2 - x1) <= (y2 - y1) * (x2 - xv); };
            std::size_t lo = 0, hi = nc;
            if (y2 > y1) {
                // condAt(x) is true for a prefix of ascending sortedColCoords, false after -- find
                // the first index where it goes false, via the *exact* same comparison IsInside()
                // itself evaluates, just probed by binary search instead of once per query point.
                while (lo < hi) {
                    const std::size_t mid = lo + (hi - lo) / 2;
                    if (condAt(sortedColCoords[mid])) {
                        lo = mid + 1;
                    } else {
                        hi = mid;
                    }
                }
                wnBaseline += 1;
                if (lo < nc) {
                    delta[lo] -= 1;
                }
            } else {
                // y2 < y1: condAt(x) is false for a prefix, true after -- find the first index
                // where it goes true.
                while (lo < hi) {
                    const std::size_t mid = lo + (hi - lo) / 2;
                    if (!condAt(sortedColCoords[mid])) {
                        lo = mid + 1;
                    } else {
                        hi = mid;
                    }
                }
                wnBaseline -= 1;
                if (lo < nc) {
                    delta[lo] += 1;
                }
            }
        }

        startover = endover;
        x1 = x2;
        y1 = y2;
    }

    int wn = wnBaseline;
    for (std::size_t i = 0; i < nc; ++i) {
        wn += delta[i];
        bool inside = (wn != 0);
        const double xv = sortedColCoords[i];
        if (!inside) {
            for (const auto& interval : forcedOpenIntervals) {
                if (xv > interval.first && xv < interval.second) {
                    inside = true;
                    break;
                }
            }
        }
        if (!inside) {
            for (double fx : forcedExactColumns) {
                if (xv == fx) {
                    inside = true;
                    break;
                }
            }
        }
        outInside[i] = inside;
    }
}

// ---- mesh geometry -- ported from Operator::GetDiscLine/GetDiscDelta/GetRawDiscDelta/GetYeeCoords/
// GetNodeWidth/GetNodeArea/GetEdgeLength/GetEdgeArea (operator.cpp) ----

double CopperOperator::discLine(int axis, unsigned int pos, bool dualMesh) const {
    const auto& lines = _rawLines[axis];
    if (pos >= lines.size()) {
        return 0.0;
    }
    if (!dualMesh) {
        return lines[pos];
    }
    if (pos < lines.size() - 1) {
        return 0.5 * (lines[pos] + lines[pos + 1]);
    }
    // dual node for the last line (outside the field domain) -- extrapolate by half the last cell.
    return lines[pos] + 0.5 * (lines[pos] - lines[pos - 1]);
}

double CopperOperator::rawDiscDelta(int axis, int pos) const {
    const auto& lines = _rawLines[axis];
    const auto n = static_cast<int>(lines.size());
    if (pos < 0) {
        return lines[0] - lines[1];
    }
    if (pos >= n - 1) {
        return lines[static_cast<std::size_t>(n - 2)] - lines[static_cast<std::size_t>(n - 1)];
    }
    return lines[static_cast<std::size_t>(pos + 1)] - lines[static_cast<std::size_t>(pos)];
}

double CopperOperator::discDelta(int axis, int pos, bool dualMesh) const {
    if (!dualMesh) {
        if (static_cast<unsigned int>(pos) < numLines(axis) - 1) {
            return discLine(axis, static_cast<unsigned int>(pos) + 1, false) - discLine(axis, static_cast<unsigned int>(pos), false);
        }
        return discLine(axis, static_cast<unsigned int>(pos), false) - discLine(axis, static_cast<unsigned int>(pos) - 1, false);
    }
    if (pos > 0) {
        return discLine(axis, static_cast<unsigned int>(pos), true) - discLine(axis, static_cast<unsigned int>(pos) - 1, true);
    }
    return discLine(axis, 1, false) - discLine(axis, 0, false);
}

bool CopperOperator::yeeCoords(int axis, const unsigned int pos[3], double coord[3], bool dualMesh) const {
    for (int n = 0; n < 3; ++n) {
        coord[n] = discLine(n, pos[n], dualMesh);
    }
    coord[axis] = discLine(axis, pos[axis], !dualMesh);

    if (!dualMesh) {
        if (pos[axis] >= numLines(axis) - 1) {
            return false;
        }
    } else {
        const int nP = (axis + 1) % 3;
        const int nPP = (axis + 2) % 3;
        if (pos[nP] >= numLines(nP) - 1 || pos[nPP] >= numLines(nPP) - 1) {
            return false;
        }
    }
    return true;
}

double CopperOperator::nodeWidthAt(int axis, const unsigned int pos[3], bool dualMesh) const {
    return edgeLength(axis, pos, !dualMesh);
}

double CopperOperator::nodeAreaAt(int axis, const unsigned int pos[3], bool dualMesh) const {
    const int axisP = (axis + 1) % 3;
    const int axisPP = (axis + 2) % 3;
    return nodeWidthAt(axisP, pos, dualMesh) * nodeWidthAt(axisPP, pos, dualMesh);
}

double CopperOperator::edgeLength(int axis, const unsigned int pos[3], bool dualMesh) const {
    return discDelta(axis, static_cast<int>(pos[axis]), dualMesh) * _gridDeltaMetres;
}

double CopperOperator::edgeArea(int axis, const unsigned int pos[3], bool dualMesh) const {
    return nodeAreaAt(axis, pos, dualMesh); // cartesian: GetEdgeArea is a passthrough to GetNodeArea
}

double CopperOperator::nodeWidth(int axis, const int pos[3]) const {
    // Always dualMesh=true -- the only way AverageMatQuarterCell ever calls GetNodeWidth.
    if (pos[0] < 0 || pos[1] < 0 || pos[2] < 0) {
        return 0.0;
    }
    const unsigned int upos[3] = {static_cast<unsigned int>(pos[0]), static_cast<unsigned int>(pos[1]),
                                    static_cast<unsigned int>(pos[2])};
    return nodeWidthAt(axis, upos, /*dualMesh=*/true);
}

double CopperOperator::nodeArea(int axis, const int pos[3]) const {
    if (pos[0] < 0 || pos[1] < 0 || pos[2] < 0) {
        return 0.0;
    }
    const unsigned int upos[3] = {static_cast<unsigned int>(pos[0]), static_cast<unsigned int>(pos[1]),
                                    static_cast<unsigned int>(pos[2])};
    return nodeAreaAt(axis, upos, /*dualMesh=*/true);
}

void CopperOperator::quarterCellCorner(int axis, int cornerIdx, const unsigned int pos[3], double outCoord[3]) const {
    const int nP = (axis + 1) % 3;
    const int nPP = (axis + 2) % 3;
    const double base[3] = {discLine(0, pos[0]), discLine(1, pos[1]), discLine(2, pos[2])};
    const double delta = rawDiscDelta(axis, static_cast<int>(pos[axis]));
    const double deltaP = rawDiscDelta(nP, static_cast<int>(pos[nP]));
    const double deltaPP = rawDiscDelta(nPP, static_cast<int>(pos[nPP]));
    const double deltaP_M = rawDiscDelta(nP, static_cast<int>(pos[nP]) - 1);
    const double deltaPP_M = rawDiscDelta(nPP, static_cast<int>(pos[nPP]) - 1);

    const bool right = (cornerIdx == 0 || cornerIdx == 2);
    const bool up = (cornerIdx == 0 || cornerIdx == 1);

    outCoord[axis] = base[axis] + delta * 0.5;
    outCoord[nP] = right ? base[nP] + deltaP * 0.25 : base[nP] - deltaP_M * 0.25;
    outCoord[nPP] = up ? base[nPP] + deltaPP * 0.25 : base[nPP] - deltaPP_M * 0.25;
}

void CopperOperator::halfCellTap(int axis, int tapIdx, const unsigned int pos[3], double outCoord[3]) const {
    const int nP = (axis + 1) % 3;
    const int nPP = (axis + 2) % 3;
    const double base[3] = {discLine(0, pos[0]), discLine(1, pos[1]), discLine(2, pos[2])};
    const double delta = rawDiscDelta(axis, static_cast<int>(pos[axis]));
    const double delta_M = rawDiscDelta(axis, static_cast<int>(pos[axis]) - 1);
    const double deltaP = rawDiscDelta(nP, static_cast<int>(pos[nP]));
    const double deltaPP = rawDiscDelta(nPP, static_cast<int>(pos[nPP]));

    outCoord[axis] = (tapIdx == 0) ? base[axis] - delta_M * 0.25 : base[axis] + delta * 0.25;
    outCoord[nP] = base[nP] + deltaP * 0.5;
    outCoord[nPP] = base[nPP] + deltaPP * 0.5;
}

const CopperOperator::PrimitiveTypeCache& CopperOperator::primitiveTypeCache(CSProperties::PropertyType type) const {
    const auto key = static_cast<unsigned int>(type);
    auto it = _primitiveTypeCache.find(key);
    if (it == _primitiveTypeCache.end()) {
        PrimitiveTypeCache cache;
        cache.prims = _csx.GetAllPrimitives(true, type);
        cache.boundBoxes.resize(cache.prims.size());
        for (std::size_t i = 0; i < cache.prims.size(); ++i) {
            // GetBoundBox()'s return value means "this box is exact", not "this box is valid":
            // CSPrimPolygon/CSPrimLinPoly always return false while still filling a correct,
            // conservative box. Treating false as unusable silently dropped every polygon-shaped
            // material (substrates, solder mask, via fill, NPTH voids) from the grid. A box is usable
            // when it was filled in (finite) and has extent on at least one axis; the base class
            // leaves it untouched (NaN) and a degenerate polygon zeroes it.
            auto& entry = cache.boundBoxes[i];
            const bool exact = cache.prims[i]->GetBoundBox(entry.box.data());
            const bool finite = std::all_of(entry.box.begin(), entry.box.end(), [](double v) { return std::isfinite(v); });
            const bool extent = entry.box[0] != entry.box[1] || entry.box[2] != entry.box[3] || entry.box[4] != entry.box[5];
            entry.ok = exact || (finite && extent);
        }
        it = _primitiveTypeCache.emplace(key, std::move(cache)).first;
    }
    return it->second;
}

std::vector<std::size_t> CopperOperator::primitivesBoundBoxIndices(int posX, int posY, int posZ,
                                                                      CSProperties::PropertyType type) const {
    double boundBox[6];
    const int bbPos[3] = {posX, posY, posZ};
    for (int n = 0; n < 3; ++n) {
        const unsigned int nLines = numLines(n);
        if (bbPos[n] < 0) {
            boundBox[2 * n] = discLine(n, 0);
            boundBox[2 * n + 1] = discLine(n, nLines - 1);
        } else {
            const unsigned int lo = bbPos[n] > 0 ? static_cast<unsigned int>(bbPos[n]) - 1 : 0;
            const unsigned int hi = std::min(nLines - 1, static_cast<unsigned int>(bbPos[n]) + 1);
            boundBox[2 * n] = discLine(n, lo);
            boundBox[2 * n + 1] = discLine(n, hi);
        }
    }
    // Filters the once-built-per-type cache (see primitiveTypeCache()'s own doc comment) instead of
    // calling ContinuousStructure::GetPrimitivesByBoundBox(..., sorted=true, ...) directly, which
    // would re-sort every primitive of `type` from scratch on every call -- IsInsideBox() itself is
    // the only genuinely per-column work here, matching GetPrimitivesByBoundBox()'s own filtering
    // step exactly (same predicate, same order-preserving scan, so this returns byte-for-byte the
    // same list openEMS's own PaintMaterialColumn/PaintPECColumn would have gotten).
    const PrimitiveTypeCache& cache = primitiveTypeCache(type);
    std::vector<std::size_t> out;
    for (std::size_t i = 0; i < cache.prims.size(); ++i) {
        if (cache.prims[i]->IsInsideBox(boundBox) >= 0) {
            out.push_back(i);
        }
    }
    return out;
}

std::vector<CSPrimitives*> CopperOperator::primitivesBoundBox(int posX, int posY, int posZ,
                                                                 CSProperties::PropertyType type) const {
    const PrimitiveTypeCache& cache = primitiveTypeCache(type);
    std::vector<CSPrimitives*> out;
    for (std::size_t i : primitivesBoundBoxIndices(posX, posY, posZ, type)) {
        out.push_back(cache.prims[i]);
    }
    return out;
}

// ---- mesh snapping -- ported from Operator::SnapToMeshLine/SnapToMesh/SnapBox2Mesh ----

unsigned int CopperOperator::snapToMeshLine(int axis, double coord, bool& inside, bool dualMesh) const {
    inside = false;
    const unsigned int n = numLines(axis);
    if (coord < discLine(axis, 0)) {
        return 0;
    }
    if (coord > discLine(axis, n - 1)) {
        return n - 1;
    }
    inside = true;
    if (!dualMesh) {
        for (unsigned int i = 0; i < n; ++i) {
            if (coord <= discLine(axis, i, true)) {
                return i;
            }
        }
    } else {
        for (unsigned int i = 1; i < n; ++i) {
            if (coord <= discLine(axis, i, false)) {
                return i - 1;
            }
        }
    }
    return 0; // should not happen
}

bool CopperOperator::snapToMesh(const double coord[3], unsigned int uicoord[3], bool dualMesh, bool* inside) const {
    bool ok = true;
    for (int n = 0; n < 3; ++n) {
        bool meshInside = false;
        uicoord[n] = snapToMeshLine(n, coord[n], meshInside, dualMesh);
        ok = ok && meshInside;
        if (inside != nullptr) {
            inside[n] = meshInside;
        }
    }
    return ok;
}

int CopperOperator::snapBox2Mesh(const double start[3], const double stop[3], unsigned int uiStart[3],
                                   unsigned int uiStop[3], bool dualMesh, int snapMethod, bool* startIn,
                                   bool* stopIn) const {
    double lStart[3], lStop[3];
    for (int n = 0; n < 3; ++n) {
        lStart[n] = std::min(start[n], stop[n]);
        lStop[n] = std::max(start[n], stop[n]);
        const double lo = discLine(n, 0);
        const double hi = discLine(n, numLines(n) - 1);
        if ((lStart[n] < lo && lStop[n] < lo) || (lStart[n] > hi && lStop[n] > hi)) {
            return -2;
        }
    }

    snapToMesh(lStart, uiStart, dualMesh, startIn);
    snapToMesh(lStop, uiStop, dualMesh, stopIn);
    int dims = 0;

    if (snapMethod == 0) {
        for (int n = 0; n < 3; ++n) {
            if (uiStop[n] > uiStart[n]) {
                ++dims;
            }
        }
        return dims;
    }
    if (snapMethod == 1) {
        for (int n = 0; n < 3; ++n) {
            if (uiStop[n] > uiStart[n]) {
                if (discLine(n, uiStart[n], dualMesh) > lStart[n] && uiStart[n] > 0) {
                    --uiStart[n];
                }
                if (discLine(n, uiStop[n], dualMesh) < lStop[n] && uiStop[n] < numLines(n) - 1) {
                    ++uiStop[n];
                }
            }
            if (uiStop[n] > uiStart[n]) {
                ++dims;
            }
        }
        return dims;
    }
    if (snapMethod == 2) {
        for (int n = 0; n < 3; ++n) {
            if (uiStop[n] > uiStart[n]) {
                if (discLine(n, uiStart[n], dualMesh) < lStart[n] && uiStart[n] < numLines(n) - 1) {
                    ++uiStart[n];
                }
                if (discLine(n, uiStop[n], dualMesh) > lStop[n] && uiStop[n] > 0) {
                    --uiStop[n];
                }
            }
            if (uiStop[n] > uiStart[n]) {
                ++dims;
            }
        }
        return dims;
    }
    return -1;
}

// ---- material/PEC resolution -- ported from Operator::PaintMaterialColumn/Calc_EC_Range/
// AverageMatQuarterCell/PaintPECColumn/CalcPEC_Range/ApplyElectricBC ----

void CopperOperator::quarterCellAverage(int axis, const unsigned int pos[3], double effMat[4],
                                          const std::vector<CSPropMaterial*> matCache[3][6]) const {
    const int n = axis;
    const int nP = (n + 1) % 3;
    const int nPP = (n + 2) % 3;
    int locPos[3] = {static_cast<int>(pos[0]), static_cast<int>(pos[1]), static_cast<int>(pos[2])};
    double coord[3] = {0, 0, 0};
    double area = 0.0;

    CSBackgroundMaterial* bg = _csx.GetBackgroundMaterial();
    const double bgEpsR = bg->GetEpsilon();
    const double bgKappa = bg->GetKappa();
    const double bgMueR = bg->GetMue();
    const double bgSigma = bg->GetSigma();

    auto lookupMat = [&](int kindIdx, int matType) -> double {
        return materialValueFromCache(matCache[n][kindIdx][pos[2]], matType, n, coord, bgEpsR, bgKappa, bgMueR,
                                       bgSigma);
    };

    // epsilon, kappa averaging (4 quarter-cell corners)
    double aN;
    quarterCellCorner(n, 0, pos, coord);
    aN = nodeArea(n, locPos);
    effMat[0] = lookupMat(0, 0) * aN;
    effMat[1] = lookupMat(0, 1) * aN;
    area += aN;

    --locPos[nP];
    quarterCellCorner(n, 1, pos, coord);
    aN = nodeArea(n, locPos);
    effMat[0] += lookupMat(1, 0) * aN;
    effMat[1] += lookupMat(1, 1) * aN;
    area += aN;

    ++locPos[nP];
    --locPos[nPP];
    quarterCellCorner(n, 2, pos, coord);
    aN = nodeArea(n, locPos);
    effMat[0] += lookupMat(2, 0) * aN;
    effMat[1] += lookupMat(2, 1) * aN;
    area += aN;

    --locPos[nP];
    quarterCellCorner(n, 3, pos, coord);
    aN = nodeArea(n, locPos);
    effMat[0] += lookupMat(3, 0) * aN;
    effMat[1] += lookupMat(3, 1) * aN;
    area += aN;

    effMat[0] *= physical::epsilon0 / area;
    effMat[1] /= area;

    // mu, sigma averaging (2 half-cell taps)
    locPos[0] = static_cast<int>(pos[0]);
    locPos[1] = static_cast<int>(pos[1]);
    locPos[2] = static_cast<int>(pos[2]);
    double length = 0.0;

    halfCellTap(n, 0, pos, coord);
    --locPos[n];
    double deltaNy = nodeWidth(n, locPos);
    effMat[2] = deltaNy / lookupMat(4, 2);
    double sigma = lookupMat(4, 3);
    effMat[3] = (sigma != 0.0) ? deltaNy / sigma : 0.0;
    length = deltaNy;

    halfCellTap(n, 1, pos, coord);
    ++locPos[n];
    deltaNy = nodeWidth(n, locPos);
    effMat[2] += deltaNy / lookupMat(5, 2);
    sigma = lookupMat(5, 3);
    if (sigma != 0.0) {
        effMat[3] += deltaNy / sigma;
    } else {
        effMat[3] = 0.0;
    }
    length += deltaNy;

    effMat[2] = length * physical::mu0 / effMat[2];
    if (effMat[3] != 0.0) {
        effMat[3] = length / effMat[3];
    }
}

void CopperOperator::computeMaterialCoefficients() {
    const unsigned int nx = numLines(0);
    const unsigned int ny = numLines(1);
    const unsigned int nz = numLines(2);
    const std::size_t cellCount = _grid.dims.cellCount();
    for (int a = 0; a < 3; ++a) {
        _ecC[a].assign(cellCount, 0.0);
        _ecG[a].assign(cellCount, 0.0);
        _ecL[a].assign(cellCount, 0.0);
        _ecR[a].assign(cellCount, 0.0);
    }

    double maxCellWidthX = 0.0;
    for (unsigned int x = 0; x < nx; ++x) {
        maxCellWidthX = std::max(maxCellWidthX, std::abs(rawDiscDelta(0, static_cast<int>(x))));
    }
    double maxCellWidthZ = 0.0;
    for (unsigned int z = 0; z < nz; ++z) {
        maxCellWidthZ = std::max(maxCellWidthZ, std::abs(rawDiscDelta(2, static_cast<int>(z))));
    }
    const auto& xLines = _rawLines[0];
    const auto& zLines = _rawLines[2];

    // quarterCellCorner(m,cornerIdx,pos,_)/halfCellTap(m,tapIdx,pos,_)'s outCoord[k] depends only on
    // pos[k] (for whichever mesh axis k the caller asks about), via one of exactly 3 formula shapes
    // (see arrayFor() below) -- never on the *other* two position components. So instead of deriving
    // one coordinate at a time from a live (x,y,z) triple, precompute each formula shape as a full
    // array over every line index on every mesh axis, once, and let the rasterizer below sweep an
    // entire row of x values (and every z in a primitive's own range) by reading pre-tabulated
    // scalars instead of calling quarterCellCorner()/halfCellTap() at all -- see this file's own top
    // comment for why per-point IsInside() (which this replaces) was the dominant cost otherwise.
    std::vector<double> center[3], quarterRight[3], quarterLeft[3];
    for (int m = 0; m < 3; ++m) {
        const unsigned int n = numLines(m);
        center[m].resize(n);
        quarterRight[m].resize(n);
        quarterLeft[m].resize(n);
        for (unsigned int p = 0; p < n; ++p) {
            const double base = discLine(m, p);
            const double delta = rawDiscDelta(m, static_cast<int>(p));
            const double deltaM = rawDiscDelta(m, static_cast<int>(p) - 1);
            center[m][p] = base + delta * 0.5;
            quarterRight[m][p] = base + delta * 0.25;
            quarterLeft[m][p] = base - deltaM * 0.25;
        }
    }
    // `kind` 0-3 is a quarterCellCorner() cornerIdx, 4-5 a halfCellTap() tapIdx -- matches matCache's
    // own [axis][kind] indexing below. Returns the precomputed array covering mesh axis `m`'s
    // contribution to that (yeeAxis,kind) coordinate -- e.g. arrayFor(2,0,0) is quarterCellCorner(2,
    // 0,pos,_)'s outCoord[0] formula, tabulated over every x line, matching quarterCellCorner()'s
    // own `right ? base[nP]+deltaP*0.25 : base[nP]-deltaP_M*0.25` exactly for m==nP (here nP==0).
    auto arrayFor = [&](int yeeAxis, int kind, int m) -> const std::vector<double>& {
        const int nP = (yeeAxis + 1) % 3;
        if (kind < 4) {
            const bool right = (kind == 0 || kind == 2);
            const bool up = (kind == 0 || kind == 1);
            if (m == yeeAxis) {
                return center[m];
            }
            if (m == nP) {
                return right ? quarterRight[m] : quarterLeft[m];
            }
            return up ? quarterRight[m] : quarterLeft[m]; // m == nPP
        }
        const int tapIdx = kind - 4;
        if (m == yeeAxis) {
            return (tapIdx == 0) ? quarterLeft[m] : quarterRight[m];
        }
        return center[m]; // m == nP or m == nPP
    };

    // Finds the [start,stopEx) line-index range (padded one line each side) that could contain
    // `lo..hi` along `lines` -- matches every other bbox-to-index-range conversion in this file.
    auto boundedRange = [](const std::vector<double>& lines, double lo, double hi,
                            unsigned int n) -> std::pair<unsigned int, unsigned int> {
        auto start = static_cast<unsigned int>(std::lower_bound(lines.begin(), lines.end(), lo) - lines.begin());
        auto stopEx = static_cast<unsigned int>(std::upper_bound(lines.begin(), lines.end(), hi) - lines.begin());
        if (start > 0) {
            --start;
        }
        if (stopEx < n) {
            ++stopEx;
        }
        return {start, stopEx};
    };

    const PrimitiveTypeCache& materialTypeCache = primitiveTypeCache(CSProperties::MATERIAL);

    // rowMatCache[axis][kind][x*nz+z] -- one row's worth of matCache below, widened to cover every
    // column in the row at once (row-major, not column-major, is what lets a CSPrimPolygon/
    // CSPrimLinPoly's coverage be rasterized once per row instead of tested point by point).
    std::vector<CSPropMaterial*> rowMatCache[3][6];
    for (int a = 0; a < 3; ++a) {
        for (int k = 0; k < 6; ++k) {
            rowMatCache[a][k].assign(static_cast<std::size_t>(nx) * nz, nullptr);
        }
    }

    PolygonRasterShape shape;
    std::vector<double> colBuf;
    std::vector<bool> insideMask;
    std::vector<CSPropMaterial*> matCache[3][6]; // one column's slice, extracted from rowMatCache below

    for (unsigned int y = 0; y < ny; ++y) {
        // -- PaintMaterialColumn, widened to a whole row --
        for (int a = 0; a < 3; ++a) {
            for (int k = 0; k < 6; ++k) {
                std::fill(rowMatCache[a][k].begin(), rowMatCache[a][k].end(), nullptr);
            }
        }

        std::vector<std::size_t> vPrimIdx = primitivesBoundBoxIndices(-1, static_cast<int>(y), -1, CSProperties::MATERIAL);

        for (auto it = vPrimIdx.rbegin(); it != vPrimIdx.rend(); ++it) {
            CSPrimitives* prim = materialTypeCache.prims[*it];
            auto* mat = dynamic_cast<CSPropMaterial*>(prim->GetProperty());
            if (mat == nullptr) {
                continue;
            }
            const BoundBoxEntry& bbEntry = materialTypeCache.boundBoxes[*it];
            if (!bbEntry.ok) {
                continue;
            }
            const double* bb = bbEntry.box.data();

            const double zLo = std::min(bb[4], bb[5]) - maxCellWidthZ;
            const double zHi = std::max(bb[4], bb[5]) + maxCellWidthZ;
            const auto [zStart, zStopEx] = boundedRange(zLines, zLo, zHi, nz);
            const double xLo = std::min(bb[0], bb[1]) - maxCellWidthX;
            const double xHi = std::max(bb[0], bb[1]) + maxCellWidthX;
            const auto [xStart, xStopEx] = boundedRange(xLines, xLo, xHi, nx);
            if (xStart >= xStopEx || zStart >= zStopEx) {
                continue;
            }

            const bool canRasterize = tryBuildPolygonRasterShape(prim, shape);
            for (int axis = 0; axis < 3; ++axis) {
                for (int kind = 0; kind < 6; ++kind) {
                    if (canRasterize) {
                        const double rowCoord = arrayFor(axis, kind, 1)[y];
                        const std::vector<double>& fullCols = arrayFor(axis, kind, 0);
                        colBuf.assign(fullCols.begin() + xStart, fullCols.begin() + xStopEx);
                        rasterizePolygonRow(shape, rowCoord, colBuf, insideMask);

                        const std::vector<double>& zArray = arrayFor(axis, kind, 2);
                        for (unsigned int z = zStart; z < zStopEx; ++z) {
                            const double zc = zArray[z];
                            if (zc < bb[4] || zc > bb[5]) {
                                continue; // IsInside()'s own elevation-axis bbox check, done
                                          // separately -- see rasterizePolygonRow()'s doc comment.
                            }
                            for (unsigned int xi = 0; xi < colBuf.size(); ++xi) {
                                if (insideMask[xi]) {
                                    rowMatCache[axis][kind][static_cast<std::size_t>(xStart + xi) * nz + z] = mat;
                                }
                            }
                        }
                    } else {
                        unsigned int pos[3] = {0, y, 0};
                        double coord[3];
                        for (unsigned int z = zStart; z < zStopEx; ++z) {
                            pos[2] = z;
                            for (unsigned int x = xStart; x < xStopEx; ++x) {
                                pos[0] = x;
                                if (kind < 4) {
                                    quarterCellCorner(axis, kind, pos, coord);
                                } else {
                                    halfCellTap(axis, kind - 4, pos, coord);
                                }
                                if (prim->IsInside(coord)) {
                                    rowMatCache[axis][kind][static_cast<std::size_t>(x) * nz + z] = mat;
                                }
                            }
                        }
                    }
                }
            }
        }

        // -- Calc_EC_Range for this row --
        for (unsigned int x = 0; x < nx; ++x) {
            for (int a = 0; a < 3; ++a) {
                for (int k = 0; k < 6; ++k) {
                    matCache[a][k].resize(nz);
                    for (unsigned int z = 0; z < nz; ++z) {
                        matCache[a][k][z] = rowMatCache[a][k][static_cast<std::size_t>(x) * nz + z];
                    }
                }
            }

            unsigned int pos[3] = {x, y, 0};
            for (pos[2] = 0; pos[2] < nz; ++pos[2]) {
                const std::size_t i = index(pos[0], pos[1], pos[2]);
                for (int n = 0; n < 3; ++n) {
                    double effMat[4];
                    quarterCellAverage(n, pos, effMat, matCache);

                    double delta = edgeLength(n, pos, false);
                    double area = edgeArea(n, pos, false);
                    if (delta != 0.0) {
                        _ecC[n][i] = effMat[0] * area / delta;
                        _ecG[n][i] = effMat[1] * area / delta;
                    }

                    delta = edgeLength(n, pos, true);
                    area = edgeArea(n, pos, true);
                    if (delta != 0.0) {
                        _ecL[n][i] = effMat[2] * area / delta;
                        _ecR[n][i] = effMat[3] * area / delta;
                    }
                }
            }
        }
    }
}

void CopperOperator::computeBoundaryPEC() {
    const unsigned int nLines[3] = {numLines(0), numLines(1), numLines(2)};
    for (int n = 0; n < 3; ++n) {
        const int nP = (n + 1) % 3;
        const int nPP = (n + 2) % 3;
        const bool pecLow = _config.boundary[static_cast<std::size_t>(2 * n)] == BoundaryType::PEC;
        const bool pecHigh = _config.boundary[static_cast<std::size_t>(2 * n + 1)] == BoundaryType::PEC;
        if (!pecLow && !pecHigh) {
            continue;
        }
        unsigned int pos[3];
        for (pos[nP] = 0; pos[nP] < nLines[nP]; ++pos[nP]) {
            for (pos[nPP] = 0; pos[nPP] < nLines[nPP]; ++pos[nPP]) {
                if (pecLow) {
                    pos[n] = 0;
                    const std::size_t i = index(pos[0], pos[1], pos[2]);
                    _grid.vv[nP][i] = 0.0F;
                    _grid.vi[nP][i] = 0.0F;
                    _grid.vv[nPP][i] = 0.0F;
                    _grid.vi[nPP][i] = 0.0F;
                }
                if (pecHigh) {
                    pos[n] = nLines[n] - 1;
                    const std::size_t i = index(pos[0], pos[1], pos[2]);
                    _grid.vv[n][i] = 0.0F; // outside the FDTD domain proper, matching ApplyElectricBC's own comment
                    _grid.vi[n][i] = 0.0F;
                    _grid.vv[nP][i] = 0.0F;
                    _grid.vi[nP][i] = 0.0F;
                    _grid.vv[nPP][i] = 0.0F;
                    _grid.vi[nPP][i] = 0.0F;
                }
            }
        }
    }
}

void CopperOperator::computePEC() {
    const unsigned int nx = numLines(0);
    const unsigned int ny = numLines(1);
    const unsigned int nz = numLines(2);
    const auto& xLines = _rawLines[0];
    const auto& zLines = _rawLines[2];

    // coord[] below only ever needs the primary- or dual-mesh line value for the *current* x, y, or
    // z -- none of which depend on which primitive is being tested, or (for x/y) even on z -- so
    // hoist every discLine() call out of the (x,y,z,axis,primitive) loop nest rather than re-deriving
    // the same handful of scalars on every single call.
    std::vector<double> xPrimary(nx), xDual(nx), yPrimary(ny), yDual(ny), zPrimary(nz), zDual(nz);
    for (unsigned int i = 0; i < nx; ++i) {
        xPrimary[i] = discLine(0, i, false);
        xDual[i] = discLine(0, i, true);
    }
    for (unsigned int i = 0; i < ny; ++i) {
        yPrimary[i] = discLine(1, i, false);
        yDual[i] = discLine(1, i, true);
    }
    for (unsigned int i = 0; i < nz; ++i) {
        zPrimary[i] = discLine(2, i, false);
        zDual[i] = discLine(2, i, true);
    }

    // Finds the [start,stopEx) line-index range (padded by one line each side, matching every other
    // bbox-to-index-range conversion in this file) that could contain `lo..hi` along `lines` --
    // `bounded=false` (a non-finite/unusable bbox axis) means "the whole domain", matching every
    // caller's own existing fallback.
    auto boundedRange = [](const std::vector<double>& lines, double lo, double hi, bool bounded,
                            unsigned int n) -> std::pair<unsigned int, unsigned int> {
        if (!bounded) {
            return {0, n};
        }
        auto start = static_cast<unsigned int>(std::lower_bound(lines.begin(), lines.end(), lo) - lines.begin());
        auto stopEx = static_cast<unsigned int>(std::upper_bound(lines.begin(), lines.end(), hi) - lines.begin());
        if (start > 0) {
            --start;
        }
        if (stopEx < n) {
            ++stopEx;
        }
        return {start, stopEx};
    };

    const CSProperties::PropertyType pecType =
        static_cast<CSProperties::PropertyType>(CSProperties::MATERIAL | CSProperties::METAL);
    const PrimitiveTypeCache& pecTypeCache = primitiveTypeCache(pecType);

    // winner[axis][x*nz+z] -- one row's worth of PaintPECColumn's own per-column winnerCache,
    // widened to cover every column in the row at once (row-major, not column-major, is what lets a
    // CSPrimPolygon/CSPrimLinPoly's coverage be rasterized once per row instead of tested point by
    // point -- see this file's own top comment). Reused across rows rather than reallocated.
    std::vector<CSPrimitives*> winner[3];
    for (int a = 0; a < 3; ++a) {
        winner[a].assign(static_cast<std::size_t>(nx) * nz, nullptr);
    }

    PolygonRasterShape shape;
    std::vector<double> colBuf;
    std::vector<bool> insideMask;

    for (unsigned int y = 0; y < ny; ++y) {
        for (int a = 0; a < 3; ++a) {
            std::fill(winner[a].begin(), winner[a].end(), nullptr);
        }

        std::vector<std::size_t> vPrimIdx = primitivesBoundBoxIndices(-1, static_cast<int>(y), -1, pecType);

        for (auto it = vPrimIdx.rbegin(); it != vPrimIdx.rend(); ++it) {
            CSPrimitives* prim = pecTypeCache.prims[*it];
            const double* bb = pecTypeCache.boundBoxes[*it].box.data();
            bool bounded = true;
            for (int n = 0; n < 6; ++n) {
                bounded = bounded && std::isfinite(bb[n]);
            }

            const auto [xStart, xStopEx] = boundedRange(xLines, std::min(bb[0], bb[1]), std::max(bb[0], bb[1]), bounded, nx);
            const auto [zStart, zStopEx] = boundedRange(zLines, std::min(bb[4], bb[5]), std::max(bb[4], bb[5]), bounded, nz);
            if (xStart >= xStopEx || zStart >= zStopEx) {
                continue;
            }

            if (tryBuildPolygonRasterShape(prim, shape)) {
                for (int axis = 0; axis < 3; ++axis) {
                    const double rowCoord = (axis == 1) ? yDual[y] : yPrimary[y];
                    const std::vector<double>& fullCols = (axis == 0) ? xDual : xPrimary;
                    colBuf.assign(fullCols.begin() + xStart, fullCols.begin() + xStopEx);
                    rasterizePolygonRow(shape, rowCoord, colBuf, insideMask);

                    for (unsigned int z = zStart; z < zStopEx; ++z) {
                        const double zc = (axis == 2) ? zDual[z] : zPrimary[z];
                        if (zc < bb[4] || zc > bb[5]) {
                            continue; // IsInside()'s own elevation-axis bbox check, done separately
                                      // since the rasterizer above only ever resolves the in-plane
                                      // (x,y) decision -- see rasterizePolygonRow()'s own doc comment.
                        }
                        for (unsigned int xi = 0; xi < colBuf.size(); ++xi) {
                            if (insideMask[xi]) {
                                winner[axis][static_cast<std::size_t>(xStart + xi) * nz + z] = prim;
                            }
                        }
                    }
                }
            } else {
                double coord[3];
                for (unsigned int z = zStart; z < zStopEx; ++z) {
                    for (int axis = 0; axis < 3; ++axis) {
                        coord[1] = (axis == 1) ? yDual[y] : yPrimary[y];
                        coord[2] = (axis == 2) ? zDual[z] : zPrimary[z];
                        for (unsigned int x = xStart; x < xStopEx; ++x) {
                            coord[0] = (axis == 0) ? xDual[x] : xPrimary[x];
                            if (prim->IsInside(coord)) {
                                winner[axis][static_cast<std::size_t>(x) * nz + z] = prim;
                            }
                        }
                    }
                }
            }
        }

        for (unsigned int x = 0; x < nx; ++x) {
            for (unsigned int z = 0; z < nz; ++z) {
                for (int n = 0; n < 3; ++n) {
                    CSPrimitives* w = winner[n][static_cast<std::size_t>(x) * nz + z];
                    if (w != nullptr && w->GetProperty()->GetType() == CSProperties::METAL) {
                        const std::size_t i = index(x, y, z);
                        _grid.vv[n][i] = 0.0F;
                        _grid.vi[n][i] = 0.0F;
                    }
                }
            }
        }
    }
}

void CopperOperator::zeroOuterHLayer() {
    // The last current (H) line per axis lies outside the actual FDTD domain and can never be
    // iterated by the leapfrog update -- ported from the unconditional tail of
    // Operator::ApplyMagneticBC ("the last current lines are outside the FDTD domain and cannot be
    // iterated by the FDTD engine"), which runs regardless of PMC boundary settings (kiems never
    // requests a PMC boundary at all, but this specific zeroing is not conditional on that -- it's a
    // mesh-domain-shape fact, not a boundary-condition effect).
    const unsigned int nLines[3] = {numLines(0), numLines(1), numLines(2)};
    for (int n = 0; n < 3; ++n) {
        const int nP = (n + 1) % 3;
        const int nPP = (n + 2) % 3;
        unsigned int pos[3];
        pos[n] = nLines[n] - 1;
        for (pos[nP] = 0; pos[nP] < nLines[nP]; ++pos[nP]) {
            for (pos[nPP] = 0; pos[nPP] < nLines[nPP]; ++pos[nPP]) {
                const std::size_t i = index(pos[0], pos[1], pos[2]);
                _grid.ii[n][i] = 0.0F;
                _grid.iv[n][i] = 0.0F;
                _grid.ii[nP][i] = 0.0F;
                _grid.iv[nP][i] = 0.0F;
                _grid.ii[nPP][i] = 0.0F;
                _grid.iv[nPP][i] = 0.0F;
            }
        }
    }
}

// ---- CFL timestep -- ported from Operator::CalcTimestep_Var3. AdrOp::Shift/GetShiftedPos's own
// "reflect to cell" boundary mode (SetReflection2Cell(), used throughout CalcTimestep_Var1/Var3)
// reduces, for the +-1-only steps this formula ever uses, to: an out-of-range shift collapses back
// to the *original* (unshifted) index rather than wrapping or erroring -- algebraically verified
// against AdrOp::GetPos's own reflection formula (`muiIrel=-2*uiIpos-muiIrel-uiTypeOffset` etc, with
// uiTypeOffset=1 for cell reflection) rather than re-deriving AdrOp's own indexing class. ----

double CopperOperator::calcTimestepVar3() const {
    double dT = 1e200;
    const unsigned int nx = numLines(0);
    const unsigned int ny = numLines(1);
    const unsigned int nz = numLines(2);

    // Shifts `base` by `shift[axis]` per axis (each entry in {-1,0,1} only, ever), reflecting an
    // out-of-range result back to `base` itself on that axis -- see this function's own top comment.
    auto shiftedIndex = [&](const unsigned int base[3], const int shift[3]) -> std::size_t {
        unsigned int p[3];
        const unsigned int lineCount[3] = {nx, ny, nz};
        for (int i = 0; i < 3; ++i) {
            const long v = static_cast<long>(base[i]) + shift[i];
            p[i] = (v < 0 || v > static_cast<long>(lineCount[i]) - 1) ? base[i] : static_cast<unsigned int>(v);
        }
        return index(p[0], p[1], p[2]);
    };

    unsigned int pos[3];
    for (int n = 0; n < 3; ++n) {
        const int nP = (n + 1) % 3;
        const int nPP = (n + 2) % 3;

        for (pos[2] = 0; pos[2] < nz; ++pos[2]) {
            for (pos[1] = 0; pos[1] < ny; ++pos[1]) {
                for (pos[0] = 0; pos[0] < nx; ++pos[0]) {
                    const std::size_t ipos0 = index(pos[0], pos[1], pos[2]);
                    int shift[3] = {0, 0, 0};
                    int tmp[3];
                    auto withTemp = [&](int axis, int step) {
                        tmp[0] = shift[0];
                        tmp[1] = shift[1];
                        tmp[2] = shift[2];
                        tmp[axis] += step;
                        return shiftedIndex(pos, tmp);
                    };

                    double wqp = 1.0 / (_ecL[nPP][ipos0] * _ecC[n][withTemp(nP, 1)]) +
                                 1.0 / (_ecL[nPP][ipos0] * _ecC[n][ipos0]);
                    wqp += 1.0 / (_ecL[nP][ipos0] * _ecC[n][withTemp(nPP, 1)]) +
                           1.0 / (_ecL[nP][ipos0] * _ecC[n][ipos0]);

                    shift[nP] = -1;
                    const std::size_t iposA = shiftedIndex(pos, shift);
                    wqp += 1.0 / (_ecL[nPP][iposA] * _ecC[n][withTemp(nP, 1)]) +
                           1.0 / (_ecL[nPP][iposA] * _ecC[n][iposA]);

                    shift[nPP] = -1;
                    const std::size_t iposB = shiftedIndex(pos, shift);
                    wqp += 1.0 / (_ecL[nP][iposB] * _ecC[n][withTemp(nPP, 1)]) +
                           1.0 / (_ecL[nP][iposB] * _ecC[n][iposB]);

                    shift[0] = shift[1] = shift[2] = 0;
                    double wt4[4];
                    wt4[0] = 1.0 / (_ecL[nPP][ipos0] * _ecC[nP][ipos0]);
                    wt4[1] = 1.0 / (_ecL[nPP][withTemp(nP, -1)] * _ecC[nP][ipos0]);
                    wt4[2] = 1.0 / (_ecL[nP][ipos0] * _ecC[nPP][ipos0]);
                    wt4[3] = 1.0 / (_ecL[nP][withTemp(nPP, -1)] * _ecC[nPP][ipos0]);
                    const double wt1 = wt4[0] + wt4[1] + wt4[2] + wt4[3] -
                                        2.0 * *std::min_element(wt4, wt4 + 4);

                    shift[0] = shift[1] = shift[2] = 0;
                    wt4[0] = 1.0 / (_ecL[nPP][ipos0] * _ecC[nP][withTemp(n, 1)]);
                    wt4[1] = 1.0 / (_ecL[nPP][withTemp(nP, -1)] * _ecC[nP][withTemp(n, 1)]);
                    wt4[2] = 1.0 / (_ecL[nP][ipos0] * _ecC[nPP][withTemp(n, 1)]);
                    wt4[3] = 1.0 / (_ecL[nP][withTemp(nPP, -1)] * _ecC[nPP][withTemp(n, 1)]);
                    const double wt2 = wt4[0] + wt4[1] + wt4[2] + wt4[3] -
                                        2.0 * *std::min_element(wt4, wt4 + 4);

                    const double wTotal = wqp + wt1 + wt2;
                    const double newT = 2.0 / std::sqrt(wTotal);
                    if (newT < dT && newT > 0.0) {
                        dT = newT;
                    }
                }
            }
        }
    }
    return dT;
}

// ---- excitation -- ported from Excitation::CalcGaussianPulsExcitation +
// Operator_Ext_Excitation::BuildExtension's soft-E-field (ExcitType 0) branch only ----

void CopperOperator::computeExcitation() {
    const double dT = _grid.timestepSeconds;
    _excitation.signalPeriodSeconds = 0.0; // Gaussian pulse is one-shot, never periodic

    if (dT <= 0.0 || _config.fc <= 0.0) {
        return;
    }

    // -- CalcGaussianPulsExcitation --
    auto length = static_cast<unsigned int>(std::ceil(2.0 * 9.0 / (2.0 * physical::pi * _config.fc) / dT));
    if (length > _config.maxTimesteps) {
        length = _config.maxTimesteps;
    }
    if (length == 0) {
        return;
    }
    _excitation.voltageSignal.assign(length, 0.0F);
    _excitation.currentSignal.assign(length, 0.0F);
    for (unsigned int n = 1; n < length; ++n) {
        double t = static_cast<double>(n) * dT;
        _excitation.voltageSignal[n] = static_cast<float>(
            std::cos(2.0 * physical::pi * _config.f0 *
                     (t - 9.0 / (2.0 * physical::pi * _config.fc))) *
            std::exp(-1.0 * std::pow(2.0 * physical::pi * _config.fc * t / 3.0 - 3.0, 2)));
        t += 0.5 * dT;
        _excitation.currentSignal[n] = static_cast<float>(
            std::cos(2.0 * physical::pi * _config.f0 *
                     (t - 9.0 / (2.0 * physical::pi * _config.fc))) *
            std::exp(-1.0 * std::pow(2.0 * physical::pi * _config.fc * t / 3.0 - 3.0, 2)));
    }

    // -- Operator_Ext_Excitation::BuildExtension, soft-E-field (ExcitType 0) branch only --
    std::vector<CSProperties*> excProps = _csx.GetPropertyByType(CSProperties::EXCITATION);
    if (excProps.empty()) {
        return;
    }

    const unsigned int nx = numLines(0);
    const unsigned int ny = numLines(1);
    const unsigned int nz = numLines(2);
    unsigned int pos[3];
    double coord[3];
    for (pos[2] = 0; pos[2] < nz; ++pos[2]) {
        for (pos[1] = 0; pos[1] < ny; ++pos[1]) {
            std::vector<CSPrimitives*> vPrims =
                primitivesBoundBox(-1, static_cast<int>(pos[1]), static_cast<int>(pos[2]), CSProperties::EXCITATION);

            for (pos[0] = 0; pos[0] < nx; ++pos[0]) {
                for (int n = 0; n < 3; ++n) {
                    if (!yeeCoords(n, pos, coord, false)) {
                        continue;
                    }
                    CSProperties* prop = _csx.GetPropertyByCoordPriority(coord, vPrims, true);
                    if (prop == nullptr) {
                        continue;
                    }
                    CSPropExcitation* elec = prop->ToExcitation();
                    if (elec == nullptr || !elec->GetEnabled() || elec->GetExcitType() != 0 || !elec->GetActiveDir(n)) {
                        continue;
                    }
                    const double amp = elec->GetWeightedExcitation(n, coord) * edgeLength(n, pos, false);
                    if (amp == 0.0) {
                        continue;
                    }
                    CopperExcitationCell cell;
                    cell.x = pos[0];
                    cell.y = pos[1];
                    cell.z = pos[2];
                    cell.axis = static_cast<std::uint32_t>(n);
                    cell.amplitude = static_cast<float>(amp);
                    cell.delaySteps = static_cast<std::uint32_t>(elec->GetDelay() / dT);
                    _excitation.voltageCells.push_back(cell);
                }
            }
        }
    }
}

// ---- lumped elements (PARALLEL only) -- ported from Operator::Calc_LumpedElements' parallel-RC
// path (operator.cpp), which folds directly into EC_C/EC_G then rederives vv/vi for just the
// covered edges. SERIES is handled entirely separately, at runtime, by CopperLumpedRLC.hpp/
// CopperFDTDRunner.cpp -- see that header's own top comment. ----

void CopperOperator::computeParallelLumpedElements() {
    std::vector<CSProperties*> lumpedProps = _csx.GetPropertyByType(CSProperties::LUMPED_ELEMENT);
    const double dT = _grid.timestepSeconds;
    for (CSProperties* prop : lumpedProps) {
        auto* lumped = dynamic_cast<CSPropLumpedElement*>(prop);
        if (lumped == nullptr || lumped->GetLEtype() != CSPropLumpedElement::PARALLEL) {
            continue;
        }
        const int dir = lumped->GetDirection();
        if (dir < 0 || dir > 2) {
            continue;
        }
        const int dirP1 = (dir + 1) % 3;
        const int dirP2 = (dir + 2) % 3;

        const double rawR = lumped->GetResistance();
        const double rawC = lumped->GetCapacity();
        const double R = (std::isnan(rawR) || rawR < 0.0) ? -1.0 : rawR; // -1 sentinel matches "R absent" (NaN) below
        const bool hasC = !std::isnan(rawC) && rawC > 0.0;
        const double C = hasC ? rawC : 0.0;
        for (std::size_t p = 0; p < lumped->GetQtyPrimitives(); ++p) {
            auto* box = dynamic_cast<CSPrimBox*>(lumped->GetPrimitive(p));
            if (box == nullptr) {
                continue;
            }
            double dstart[3], dstop[3];
            for (int n = 0; n < 3; ++n) {
                dstart[n] = box->GetCoord(2 * n);
                dstop[n] = box->GetCoord(2 * n + 1);
            }
            unsigned int uiStart[3], uiStop[3];
            const int snapDim = snapBox2Mesh(dstart, dstop, uiStart, uiStop, /*dualMesh=*/false, /*snapMethod=*/0);
            if (snapDim <= 0 || uiStart[dir] == uiStop[dir]) {
                continue;
            }

            // Transverse edges are parallel branches and longitudinal edges are in series. Weight
            // them using their real A/l geometry, exactly like Operator::Calc_LumpedElements(). A
            // cell-count-only split is valid only on a uniform cubic mesh; on the strongly
            // non-uniform board mesh it made a nominal 45-ohm termination depend on local cell
            // dimensions and could weaken it by orders of magnitude.
            unsigned int pos[3] = {0, 0, 0};
            double inverseUnitGC = 0.0;
            for (pos[dir] = uiStart[dir]; pos[dir] < uiStop[dir]; ++pos[dir]) {
                double unitGCPlane = 0.0;
                for (pos[dirP1] = uiStart[dirP1]; pos[dirP1] <= uiStop[dirP1]; ++pos[dirP1]) {
                    for (pos[dirP2] = uiStart[dirP2]; pos[dirP2] <= uiStop[dirP2]; ++pos[dirP2]) {
                        const double length = edgeLength(dir, pos);
                        if (length > 0.0) unitGCPlane += edgeArea(dir, pos) / length;
                    }
                }
                if (unitGCPlane > 0.0) inverseUnitGC += 1.0 / unitGCPlane;
            }
            if (inverseUnitGC <= 0.0) continue;
            const double unitGC = 1.0 / inverseUnitGC;
            const double conductivity = R > 0.0 ? 1.0 / (R * unitGC) : 0.0;
            const double permittivity = hasC ? C / unitGC : 0.0;

            for (pos[dir] = uiStart[dir]; pos[dir] < uiStop[dir]; ++pos[dir]) {
                for (pos[dirP1] = uiStart[dirP1]; pos[dirP1] <= uiStop[dirP1]; ++pos[dirP1]) {
                    for (pos[dirP2] = uiStart[dirP2]; pos[dirP2] <= uiStop[dirP2]; ++pos[dirP2]) {
                        const std::size_t i = index(pos[0], pos[1], pos[2]);
                        const double length = edgeLength(dir, pos);
                        if (length <= 0.0) continue;
                        const double geometricFactor = edgeArea(dir, pos) / length;
                        const double dG = conductivity * geometricFactor;
                        const double dC = permittivity * geometricFactor;
                        if (dC > 0.0) {
                            _ecC[dir][i] = dC;
                        }
                        // else: keep the natural grid capacitance already computed by
                        // computeMaterialCoefficients() -- the real extension additionally bumps a
                        // too-small natural capacitance upward for ADE stability
                        // (Zmin/Zcd_min/LUMPED_RLC_Z_FACT); not reproduced here since it only
                        // matters for a parallel inductance, which libkiems does not create.

                        if (R >= 0.0) {
                            _ecG[dir][i] = dG;
                        }

                        // vv[dir]/vi[dir] rederived for just this edge from the now-mutated EC_C/EC_G
                        // (EC_L/EC_R untouched) -- mirrors Operator_Ext_LumpedRLC's own immediate
                        // m_Op->Calc_ECOperatorPos(dir,pos) call.
                        const double c = _ecC[dir][i];
                        const double g = _ecG[dir][i];
                        if (c > 0.0) {
                            _grid.vv[dir][i] = static_cast<float>((1.0 - dT * g / 2.0 / c) / (1.0 + dT * g / 2.0 / c));
                            _grid.vi[dir][i] = static_cast<float>((dT / c) / (1.0 + dT * g / 2.0 / c));
                        } else {
                            _grid.vv[dir][i] = 0.0F;
                            _grid.vi[dir][i] = 0.0F;
                        }
                    }
                }
            }

            // LumpedPort requests equipotential metal end caps. These are part of openEMS's
            // parallel-lumped-element semantics and ensure the resistor face really connects to
            // the zero-thickness pad and reference plane across its whole footprint.
            if (lumped->GetCaps()) {
                for (pos[dirP1] = uiStart[dirP1]; pos[dirP1] <= uiStop[dirP1]; ++pos[dirP1]) {
                    for (pos[dirP2] = uiStart[dirP2]; pos[dirP2] <= uiStop[dirP2]; ++pos[dirP2]) {
                        for (const unsigned int end : {uiStart[dir], uiStop[dir]}) {
                            pos[dir] = end;
                            const std::size_t i = index(pos[0], pos[1], pos[2]);
                            if (pos[dirP1] < uiStop[dirP1]) {
                                _grid.vv[dirP1][i] = 0.0F;
                                _grid.vi[dirP1][i] = 0.0F;
                            }
                            if (pos[dirP2] < uiStop[dirP2]) {
                                _grid.vv[dirP2][i] = 0.0F;
                                _grid.vi[dirP2][i] = 0.0F;
                            }
                        }
                    }
                }
            }
        }
    }
}

// ---- construction ----

CopperOperator::CopperOperator(ContinuousStructure& csx, const Config& config) : _csx(csx), _config(config) {
    // openEMS's own Operator::SetGeometryCSX() is only ever reached after openEMS::SetupFDTD() has
    // already called ContinuousStructure::Update() on the whole scene graph -- this constructor is
    // this class's own equivalent entry point, so it must do the same, unconditionally, rather than
    // assume some earlier caller already did. Update() itself is nearly a no-op for every primitive/
    // property whose values are plain doubles (which is everything kiems ever builds -- no string-
    // formula parametrics) -- ParameterScalar::Evaluate() returns immediately whenever ParameterMode
    // is false -- *except* for CSPrimPolygon/CSPrimLinPoly (kiems's own copper trace/pad/plane
    // representation), whose Update() also computes and caches m_BoundBox, which IsInside() then
    // uses as a mandatory quick-reject check before its real point-in-polygon test (see
    // CSPrimPolygon::IsInside()'s own "m_BoundBox[2*n]>Coord[n]" checks -- with m_BoundBoxValid still
    // at its constructed-default false/zeroed state, that check rejects every real-world coordinate
    // unconditionally, making every polygon primitive invisible to computeMaterialCoefficients()/
    // computePEC() below). Confirmed as a real regression this way: skipping the caller's own
    // SetupFDTD() call (once real openEMS's Operator/Engine were no longer needed at all for a CPML
    // run) made every copper trace/plane vanish from the painted geometry -- only CSPrimBox-shaped
    // primitives (whose own IsInside() reads m_Coords directly, unaffected) kept working, which is
    // exactly why a port's own excitation box still worked while the trace it should feed into didn't.
    csx.Update();

    CSRectGrid* csRectGrid = csx.GetGrid();
    for (int axis = 0; axis < 3; ++axis) {
        unsigned int qty = 0;
        double* lines = csRectGrid->GetLines(axis, nullptr, qty, /*sorted=*/true);
        _rawLines[axis].assign(lines, lines + qty);
        delete[] lines;
    }
    _gridDeltaMetres = csRectGrid->GetDeltaUnit();

    _grid.dims = CopperGridDims{numLines(0), numLines(1), numLines(2)};
    const std::size_t cellCount = _grid.dims.cellCount();
    for (int axis = 0; axis < 3; ++axis) {
        _grid.vv[axis].assign(cellCount, 0.0F);
        _grid.vi[axis].assign(cellCount, 0.0F);
        _grid.ii[axis].assign(cellCount, 0.0F);
        _grid.iv[axis].assign(cellCount, 0.0F);
    }
    _grid.lineX.resize(numLines(0));
    _grid.lineY.resize(numLines(1));
    _grid.lineZ.resize(numLines(2));
    _grid.dualLineX.resize(numLines(0));
    _grid.dualLineY.resize(numLines(1));
    _grid.dualLineZ.resize(numLines(2));
    for (unsigned int i = 0; i < numLines(0); ++i) {
        _grid.lineX[i] = static_cast<float>(discLine(0, i, false) * _gridDeltaMetres);
        _grid.dualLineX[i] = static_cast<float>(discLine(0, i, true) * _gridDeltaMetres);
    }
    for (unsigned int i = 0; i < numLines(1); ++i) {
        _grid.lineY[i] = static_cast<float>(discLine(1, i, false) * _gridDeltaMetres);
        _grid.dualLineY[i] = static_cast<float>(discLine(1, i, true) * _gridDeltaMetres);
    }
    for (unsigned int i = 0; i < numLines(2); ++i) {
        _grid.lineZ[i] = static_cast<float>(discLine(2, i, false) * _gridDeltaMetres);
        _grid.dualLineZ[i] = static_cast<float>(discLine(2, i, true) * _gridDeltaMetres);
    }
    for (int axis = 0; axis < 3; ++axis) {
        _grid.primaryDelta[axis].resize(numLines(axis));
        _grid.dualDelta[axis].resize(numLines(axis));
        for (unsigned int i = 0; i < numLines(axis); ++i) {
            _grid.primaryDelta[axis][i] = discDelta(axis, static_cast<int>(i), false) * _gridDeltaMetres;
            _grid.dualDelta[axis][i] = discDelta(axis, static_cast<int>(i), true) * _gridDeltaMetres;
        }
    }

    computeMaterialCoefficients();

    const double dT = calcTimestepVar3();
    _grid.timestepSeconds = dT;

    for (int n = 0; n < 3; ++n) {
        for (unsigned int z = 0; z < numLines(2); ++z) {
            for (unsigned int y = 0; y < numLines(1); ++y) {
                for (unsigned int x = 0; x < numLines(0); ++x) {
                    const std::size_t i = index(x, y, z);
                    const double c = _ecC[n][i];
                    const double g = _ecG[n][i];
                    if (c > 0.0) {
                        _grid.vv[n][i] = static_cast<float>((1.0 - dT * g / 2.0 / c) / (1.0 + dT * g / 2.0 / c));
                        _grid.vi[n][i] = static_cast<float>((dT / c) / (1.0 + dT * g / 2.0 / c));
                    } else {
                        _grid.vv[n][i] = 0.0F;
                        _grid.vi[n][i] = 0.0F;
                    }
                    const double l = _ecL[n][i];
                    const double r = _ecR[n][i];
                    if (l > 0.0) {
                        _grid.ii[n][i] = static_cast<float>((1.0 - dT * r / 2.0 / l) / (1.0 + dT * r / 2.0 / l));
                        _grid.iv[n][i] = static_cast<float>((dT / l) / (1.0 + dT * r / 2.0 / l));
                    } else {
                        _grid.ii[n][i] = 0.0F;
                        _grid.iv[n][i] = 0.0F;
                    }
                }
            }
        }
    }

    computeBoundaryPEC();
    computePEC();
    zeroOuterHLayer();
    computeParallelLumpedElements();
    computeExcitation();
}

} // namespace copper
