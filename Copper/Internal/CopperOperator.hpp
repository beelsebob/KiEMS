// Copper's own from-scratch FDTD mesh/coefficient engine -- replaces openEMS's Operator/Excitation/
// Operator_Ext_Excitation/the PARALLEL branch of Operator_Ext_LumpedRLC. Every formula here is
// transcribed directly from this project's own (locally patched) openEMS fork -- see the doc
// comments on each method below for exactly which openEMS/FDTD/operator.cpp (or
// openEMS/FDTD/extensions/*.cpp) function it mirrors -- not re-derived from first principles.
//
// CSXCAD (ContinuousStructure/CSProperties/CSPrimitives/CSRectGrid) stays exactly as-is: this class
// consumes it the same way Operator::SetGeometryCSX()/CalcECOperator() does, including reusing
// CSXCAD's own bounding-box-filtered primitive query (ContinuousStructure::GetPrimitivesByBoundBox)
// via the same per-column candidate-gathering strategy openEMS's own PaintMaterialColumn/
// PaintPECColumn use -- a naive per-edge GetPropertyByCoordPriority() call was confirmed too slow on
// a real board, which is why that candidate-gathering pass exists at all.
//
// computeMaterialCoefficients()/computePEC() do NOT, however, call CSPrimitives::IsInside() once
// per (x,y,z,axis) query point the way openEMS's own PaintMaterialColumn/PaintPECColumn (and this
// port's own first draft) do -- that is a genuine per-point O(vertices) winding-number scan, and for
// a many-vertex copper pour or board-outline polygon whose bounding box covers a large fraction of
// the board, repeating it at nearly every grid point inside that box was confirmed to dominate this
// class's whole construction time on a real board (see PolygonRasterShape/rasterizePolygonRow()
// below). Do not "simplify" this back to a per-point IsInside() loop -- that regression has already
// happened once. Instead, CSPrimPolygon/CSPrimLinPoly primitives (see eligibility rules on
// tryBuildPolygonRasterShape()) get their (x,y)-plane coverage computed once per row via a proper
// edge-crossing scanline sweep, reproducing CSPrimitives::IsInside()'s exact winding-number-plus-
// on-edge decision bit-for-bit (verified by CopperYeeGridExtractionTests' randomized equivalence
// coverage against brute-force IsInside()) but sharing the O(vertices) edge work across an entire
// row of grid points instead of paying it per point. Primitives that don't qualify for the fast
// path (CSPrimBox, whose IsInside() is already O(1); any transformed/non-Cartesian/non-Z-normal
// primitive, which libkiems never creates but which must still be handled safely) fall back to the
// original per-point IsInside() call unchanged.
//
// Deliberately narrower than openEMS's own Operator:
//  - Only QuarterCell material averaging is implemented (openEMS's own default, and the only mode
//    libkiems ever requests -- confirmed no CellConstantMaterial/SetCellCenter call anywhere in
//    libkiems).
//  - Only Gaussian-pulse excitation (ExciteType 0, soft E-field only) is implemented -- the only
//    excitation type/mode libkiems ever creates (confirmed: every CSPropExcitation libkiems builds
//    uses SetExcitType(0); SetSinusExcite()/CalcSinusExcitation is dead code, never called).
//  - Curve primitives (CSPrimCurve, "treated as wires") are not supported -- libkiems only ever
//    creates CSPrimBox/CSPrimPolygon/CSPrimLinPoly.
//  - No UPML/MUR absorbing-boundary math -- Copper's own from-scratch CPML (CopperCPML.hpp) already
//    handles boundary absorption independently of anything this class computes. `BoundaryType::Open`
//    here means only "don't force PEC", not "actually absorb": a real run always adds a CPML shell
//    (built separately, from this object's own grid/PEC info) on top.
#pragma once

#include <array>
#include <cstdint>
#include <limits>
#include <span>
#include <unordered_map>
#include <utility>
#include <vector>

#include <ContinuousStructure.h>

#include "CopperExcitation.hpp"
#include "CopperYeeGrid.hpp"

namespace copper {

class CopperOperator {
public:
    enum class BoundaryType { PEC, Open };

    struct Config {
        // Face order matches openEMS convention: 0=xmin,1=xmax,2=ymin,3=ymax,4=zmin,
        // 5=zmax. Defaults to Open on every face (a caller wanting a closed PEC box, e.g. test
        // fixtures, must set all 6 explicitly -- mirrors every existing CopperOperator caller/fixture
        // needing to state its own boundary intent rather than inheriting a "closed box" default that
        // would silently swallow a real board's own open (CPML) edges).
        std::array<BoundaryType, 6> boundary = {BoundaryType::Open, BoundaryType::Open, BoundaryType::Open,
                                                  BoundaryType::Open, BoundaryType::Open, BoundaryType::Open};
        double f0 = 0.0;                // Gaussian pulse center frequency, Hz (openEMS::SetGaussExcite's f0)
        double fc = 0.0;                // Gaussian pulse half-bandwidth, Hz (openEMS::SetGaussExcite's fc)
        std::uint32_t maxTimesteps = 0; // clamps the excitation signal length -- mirrors
                                         // openEMS::SetupFDTD()'s own m_Exc->buildExcitationSignal(NrTS)
                                         // call, NrTS coming from SetNumberOfTimeSteps()
    };

    // A CSPrimPolygon/CSPrimLinPoly's vertex list, extracted once via its own public GetQtyCoords()/
    // GetCoord() accessors -- x[i],y[i] are the Cartesian coordinates of vertex i in the primitive's
    // own (nP,nPP) in-plane axes (same order as CSPrimitives::IsInside()'s own vCoords walk).
    // Public (and the two functions below static) purely so CopperYeeGridExtractionTests can pin
    // rasterizePolygonRow() to brute-force CSPrimitives::IsInside() equivalence directly -- see this
    // file's own top comment for why that equivalence is load-bearing, not incidental.
    struct PolygonRasterShape {
        std::vector<double> x, y;
    };

    /// Extracts `prim`'s vertex list into `outShape` if it's eligible for the scanline fast path:
    /// a CSPrimPolygon or CSPrimLinPoly, Cartesian, untransformed, with normal direction Z (2) --
    /// the only shape libkiems itself ever creates for copper/dielectric geometry (see this file's
    /// own top comment). Returns false (leaving `outShape` unspecified) for anything else, including
    /// CSPrimBox (whose IsInside() is already O(1) and doesn't need this) -- callers must fall back
    /// to a plain `prim->IsInside()` loop in that case.
    static bool tryBuildPolygonRasterShape(CSPrimitives* prim, PolygonRasterShape& outShape);

    /// Computes, for every coordinate in `sortedColCoords` (must be sorted ascending), whether the
    /// point `(sortedColCoords[i], rowCoord)` is inside `shape` -- reproducing
    /// CSPrimitives::IsInside()'s winding-number-plus-on-cartesian-edge decision bit-for-bit (the
    /// bounding-box quick-reject that IsInside() does first is mathematically redundant with a
    /// correct winding-number result for points outside the box, so it is not reproduced here;
    /// callers are still responsible for their own equivalent of IsInside()'s bbox check on any axis
    /// *not* covered by `sortedColCoords`/`rowCoord`, e.g. elevation for a flat CSPrimPolygon), but
    /// shares each edge's O(1)-per-probe crossing test across the whole row via binary search
    /// (O(vertices log columns)) instead of a fresh O(vertices) scan per column
    /// (O(vertices * columns)). `outInside[i]` corresponds to `sortedColCoords[i]`.
    static void rasterizePolygonRow(const PolygonRasterShape& shape, double rowCoord,
                                      const std::vector<double>& sortedColCoords, std::vector<bool>& outInside);

    /// Builds the full mesh, per-edge material/PEC resolution, vv/vi/ii/iv coefficients, CFL
    /// timestep, PARALLEL-type lumped-element folding, and Gaussian-pulse excitation signal/cell
    /// discovery from `csx`'s own CSRectGrid and property/primitive scene graph -- equivalent to
    /// openEMS's SetGeometryCSX()+CalcECOperator()+SetGaussExcite()+buildExcitationSignal() sequence,
    /// done here in one pass. `csx` must outlive this object (probe/SERIES-lumped-element discovery,
    /// done separately by CopperProbes.hpp/CopperLumpedRLC.hpp, re-scan it against this object's own
    /// mesh afterward).
    CopperOperator(ContinuousStructure& csx, const Config& config);

    const CopperYeeGrid& grid() const { return _grid; }
    const CopperExcitation& excitation() const { return _excitation; }
    const CopperGridDims& dims() const { return _grid.dims; }
    double timestepSeconds() const { return _grid.timestepSeconds; }

    /// Ported from Operator::SnapToMesh (operator.cpp) -- snaps `coord` to the nearest mesh line per
    /// axis (primary mesh if `dualMesh` is false, dual mesh otherwise). `inside[n]`, if given,
    /// reports whether `coord[n]` was actually within the mesh's own extent on that axis (false
    /// means clamped to the nearest domain edge instead of a genuine nearest-line match). Returns
    /// true only if every axis was inside. Coordinates are in the same native CSX drawing units as
    /// every CSPrimitives::SetCoord() call (not metres -- matches CSXCAD's own convention).
    bool snapToMesh(const double coord[3], unsigned int uicoord[3], bool dualMesh, bool* inside = nullptr) const;

    /// Ported from Operator::SnapBox2Mesh (operator.cpp) -- snaps an axis-aligned box (`start`/`stop`,
    /// either ordering) to mesh-line indices. `snapMethod` 0 = nearest line per corner, no expansion
    /// (voltage probes' and SERIES lumped elements' own convention); 1 = expand outward so the
    /// snapped box fully contains the original (current probes' own convention, per
    /// CopperProbes.hpp's existing doc comments). Returns the number of axes with nonzero extent
    /// after snapping, or -2 if the box doesn't intersect the mesh at all.
    int snapBox2Mesh(const double start[3], const double stop[3], unsigned int uiStart[3], unsigned int uiStop[3],
                      bool dualMesh, int snapMethod, bool* startIn = nullptr, bool* stopIn = nullptr) const;

    /// Ported from Operator::GetYeeCoords (operator.cpp) -- the real-world (native CSX unit)
    /// coordinate of Yee edge `pos` in direction `axis`, on the primary (`dualMesh=false`) or dual
    /// (`true`) mesh. Returns false if `pos` lies outside the field domain along the axes transverse
    /// to `axis` (the caller should skip that edge entirely -- matches
    /// Operator_Ext_Excitation::BuildExtension()'s own `if (GetYeeCoords(...)==false) continue;`).
    bool yeeCoords(int axis, const unsigned int pos[3], double coord[3], bool dualMesh) const;

    /// Ported from Operator::GetEdgeLength (operator.cpp) -- the physical length (metres) of Yee edge
    /// `pos` in direction `axis`, primary or dual mesh.
    double edgeLength(int axis, const unsigned int pos[3], bool dualMesh = false) const;

    /// Native-CSX-unit (unscaled) mesh line, primary or dual -- ported from Operator::GetDiscLine.
    /// CopperCPML.hpp's own buildCPML() needs this directly (matching what it read off a real
    /// Operator before).
    double discLine(int axis, unsigned int pos, bool dualMesh = false) const;

    /// Ported from Operator::GetNumberOfLines -- the cartesian implementation ignores its own `full`
    /// parameter entirely (only cylindrical/multi-grid derived operators, which kiems never uses,
    /// care about it), so this has none either.
    unsigned int numberOfLines(int axis) const { return numLines(axis); }

    /// Ported from Operator::GetGridDelta -- native-CSX-unit-to-metres scale factor
    /// (CSRectGrid::GetDeltaUnit()). CopperCPML.hpp's own buildCPML() needs this directly.
    double gridDeltaMetres() const { return _gridDeltaMetres; }

private:
    struct PolygonRasterScratch {
        std::vector<std::pair<std::size_t, int>> windingEvents;
        std::vector<std::pair<std::size_t, int>> forcedEvents;
    };
    static void rasterizePolygonRowBytes(const PolygonRasterShape& shape, double rowCoord,
                                         std::span<const double> sortedColCoords, std::span<std::uint8_t> outInside,
                                         PolygonRasterScratch& scratch);

    // -- mesh --
    unsigned int numLines(int axis) const { return static_cast<unsigned int>(_rawLines[axis].size()); }
    double discDelta(int axis, int pos, bool dualMesh) const; // ported from Operator::GetDiscDelta (unsigned pos there;
                                                                 // int here is always >=0 from every caller)
    // ported from Operator::GetRawDiscDelta -- a second, distinct delta convention (signed pos,
    // never dualMesh-aware, sign-flips at the two domain-edge special cases) used only by
    // quarterCellCorner/halfCellTap, never by discDelta/edgeLength.
    double rawDiscDelta(int axis, int pos) const;
    unsigned int snapToMeshLine(int axis, double coord, bool& inside, bool dualMesh) const;
    // ported from Operator::GetNodeWidth/GetNodeArea's general (unsigned pos, explicit dualMesh)
    // overloads -- used by edgeArea (Calc_ECPos's own primary-then-dual area/delta pass).
    double nodeWidthAt(int axis, const unsigned int pos[3], bool dualMesh) const;
    double nodeAreaAt(int axis, const unsigned int pos[3], bool dualMesh) const;
    double edgeArea(int axis, const unsigned int pos[3], bool dualMesh = false) const; // ported from Operator::GetEdgeArea
    // ported from Operator::GetPrimitivesBoundBox -- thin wrapper over primitivesBoundBoxIndices()
    // for the one caller (computeExcitation) that only ever wants the primitive pointers themselves.
    std::vector<CSPrimitives*> primitivesBoundBox(int posX, int posY, int posZ, CSProperties::PropertyType type) const;
    // Same O(N) filter as primitivesBoundBox() above (see primitiveTypeCache()'s own doc comment for
    // why the underlying per-`type` primitive list itself is cached rather than re-sorted per
    // column), but returns indices into primitiveTypeCache(type) instead of primitive pointers, so
    // computeMaterialCoefficients()/computePEC() can also read each surviving primitive's bound box
    // via cache.boundBoxes[idx] -- an O(1) array read -- instead of asking the primitive itself
    // (CSPrimPolygon/CSPrimLinPoly::GetBoundBox() recomputes from every vertex on every call).
    std::vector<std::size_t> primitivesBoundBoxIndices(int posX, int posY, int posZ, CSProperties::PropertyType type) const;

    struct BoundBoxEntry {
        bool ok = false;
        std::array<double, 6> box = {std::numeric_limits<double>::quiet_NaN(), std::numeric_limits<double>::quiet_NaN(),
                                       std::numeric_limits<double>::quiet_NaN(), std::numeric_limits<double>::quiet_NaN(),
                                       std::numeric_limits<double>::quiet_NaN(), std::numeric_limits<double>::quiet_NaN()};
    };
    // ContinuousStructure::GetPrimitivesByBoundBox(..., sorted=true, type) re-sorts *every* primitive
    // of `type` by priority from scratch on every call (ContinuousStructure::GetAllPrimitives(),
    // O(N log N) with no memoization of its own) -- calling that once per (x,y) column, as
    // primitivesBoundBoxIndices() above must (matching PaintMaterialColumn/PaintPECColumn's own call
    // pattern -- see this file's own top comment on why that rasterization strategy is kept), would
    // make the whole column pass O(nx*ny*N log N) instead of O(nx*ny*N): confirmed in practice this
    // dominates CopperOperator's construction time on a real board. `_csx`'s own primitive set is
    // fixed for this object's whole construction (nothing inserts/removes a primitive mid-build), so
    // the sorted-by-priority list for a given `type` bitmask -- along with each primitive's bound
    // box, computed here in the same single O(N) pass rather than looked up again per column via a
    // hash map keyed by primitive pointer (measured: the hashing/probing cost of that per-column
    // per-primitive lookup rivals the vertex-walk it was replacing) -- is cached the first time it's
    // asked for and reused by every later column; only the O(N) IsInsideBox() filter itself still
    // runs per column, now over a plain aligned array instead of a hash table.
    struct PrimitiveTypeCache {
        std::vector<CSPrimitives*> prims;
        std::vector<BoundBoxEntry> boundBoxes;
    };
    const PrimitiveTypeCache& primitiveTypeCache(CSProperties::PropertyType type) const;

    // -- material/PEC resolution (column rasterization, ported from PaintMaterialColumn/
    // PaintPECColumn/Calc_EC_Range/CalcPEC_Range) --
    void computeMaterialCoefficients(); // fills _ecC/_ecG/_ecL/_ecR
    void computePEC();                  // zeroes vv/vi wherever a column resolves to METAL
    void computeBoundaryPEC();          // ported from Operator::ApplyElectricBC
    void zeroOuterHLayer();              // ported from the unconditional tail of Operator::ApplyMagneticBC
    // ported from Operator::AverageMatQuarterCell -- effMat[0..3] = eps (absolute, F/m), kappa (S/m),
    // mu (absolute, H/m), sigma (magnetic loss, matching EffMat's own units in the source).
    void quarterCellAverage(int axis, const unsigned int pos[3], double effMat[4],
                              const std::vector<CSPropMaterial*> matCache[3][6]) const;
    void quarterCellCorner(int axis, int cornerIdx, const unsigned int pos[3], double outCoord[3]) const;
    void halfCellTap(int axis, int tapIdx, const unsigned int pos[3], double outCoord[3]) const;
    // ported from Operator::GetNodeWidth/GetNodeArea's signed-pos overloads -- always dualMesh=true
    // (the only way AverageMatQuarterCell ever calls them), returns 0 for any out-of-domain axis.
    double nodeArea(int axis, const int pos[3]) const;
    double nodeWidth(int axis, const int pos[3]) const;

    // -- excitation (ported from Excitation::CalcGaussianPulsExcitation +
    // Operator_Ext_Excitation::BuildExtension's soft-E-field branch) --
    void computeExcitation();

    // -- lumped elements (ported from Operator_Ext_LumpedRLC::BuildExtension's PARALLEL branch) --
    void computeParallelLumpedElements();

    // -- timestep (ported from Operator::CalcTimestep_Var3) --
    double calcTimestepVar3() const;

    std::size_t index(unsigned int x, unsigned int y, unsigned int z) const { return copperGridIndex(_grid.dims, x, y, z); }

    ContinuousStructure& _csx;
    Config _config;
    std::vector<double> _rawLines[3]; // native CSX units, sorted ascending -- the primary mesh
    double _gridDeltaMetres = 1.0;
    // See primitiveTypeCache()'s own doc comment -- keyed by the raw CSProperties::PropertyType
    // bitmask value each caller passes (MATERIAL, MATERIAL|METAL, EXCITATION today).
    mutable std::unordered_map<unsigned int, PrimitiveTypeCache> _primitiveTypeCache;

    // EC_C/EC_G (voltage/E-side effective capacitance+conductance) and EC_L/EC_R (current/H-side
    // effective inductance+resistance), one flat cellCount-sized array per axis -- matches
    // Operator::EC_C/EC_G/EC_L/EC_R exactly, kept only for the duration of construction (unlike
    // openEMS, which frees them at the end of CalcECOperator() too).
    std::vector<double> _ecC[3], _ecG[3], _ecL[3], _ecR[3];

    CopperYeeGrid _grid;
    CopperExcitation _excitation;
};

} // namespace copper
