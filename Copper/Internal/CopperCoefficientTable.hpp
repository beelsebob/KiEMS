// The Metal engine's compact form of a CopperYeeGrid's update coefficients. A grid stores twelve
// floats per cell (vv/vi/ii/iv for each axis), but almost all of that is repetition: vv depends only
// on the (quarter-cell averaged) material, and vi only on the material times the cell's geometry --
// vi = dT/C with C = eps*area/length, and on a Cartesian mesh area/length is a product of one
// spacing per axis (see CopperYeeGrid::primaryDelta). Dividing that geometry back out leaves a
// handful of distinct material terms (a few thousand on a real board, mostly from the blends at
// material boundaries), so each cell needs only an index into a table of them, and the kernels
// rebuild vi from three small per-axis arrays.
//
// The rebuilt vi/iv differ from the grid's own by a few float roundings (~3e-7 relative); vv/ii are
// stored exactly.
#pragma once

#include <cstdint>
#include <vector>

#include "CopperCPML.hpp"
#include "CopperDomain.hpp"
#include "CopperYeeGrid.hpp"

namespace copper {

/// One side (E or H) of a grid's coefficients in table form.
struct CopperCoefficientTable {
    /// The distinct material terms: decay[n] is vv[n] (or ii[n]) exactly, material[n] is vi[n] (or
    /// iv[n]) divided by its cell's geometry factor. Laid out to match CopperMaterialCoefficientsGPU.
    struct Entry {
        float decay[3];
        float material[3];
    };
    std::vector<Entry> entries;
    /// Per cell, in copperGridIndex() order: its entry. 0 for cells outside every box.
    std::vector<std::uint32_t> index;
    /// The geometry factor's per-axis terms, as the kernels read them: the component's own spacing
    /// along x, y and z (nx + ny + nz floats), then the reciprocal of the spacing across it along x,
    /// y and z. Component n's factor is own[n][pos n] * inverseAcross[nP][pos nP] *
    /// inverseAcross[nPP][pos nPP]; for E "own" is the primary mesh and "across" the dual, for H the
    /// other way round.
    std::vector<float> geometry;
    /// Worst |rebuilt - original| / |original| over every non-zero vi/iv, rebuilt in float the way
    /// the kernels do it.
    double worstRebuildError = 0.0;
};

enum class CopperCoefficientSide { E, H };

/// Builds `side`'s table over every cell of `boxes` (all z), with `ring` folded in first -- the same
/// coefficients applyRingAbsorber() would leave in a mutable copy of the grid. Throws
/// std::runtime_error if the grid has no mesh spacings or a zero one.
CopperCoefficientTable buildCoefficientTable(const CopperYeeGrid& grid, CopperCoefficientSide side,
                                             const std::vector<CopperDomainMask::DispatchBox>& boxes,
                                             const CopperRingAbsorber& ring);

} // namespace copper
