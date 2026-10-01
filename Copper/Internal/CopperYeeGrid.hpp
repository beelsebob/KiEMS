// A built Yee grid (mesh lines + leapfrog coefficients) as flat, structure-of-arrays buffers ready to
// hand straight to a Metal MTLBuffer. CopperOperator builds it.
#pragma once

#include <cstdint>
#include <vector>

namespace copper {

struct CopperGridDims {
    std::uint32_t nx = 0;
    std::uint32_t ny = 0;
    std::uint32_t nz = 0;

    std::uint32_t cellCount() const { return nx * ny * nz; }
};

/// Linear index into every flat per-cell array below -- x fastest-varying, matching Metal's own
/// (x,y,z) threadgroup/dispatch-grid convention, so SIMD-group-adjacent GPU threads (which differ
/// in x) read/write adjacent memory.
inline std::uint32_t copperGridIndex(const CopperGridDims& dims, std::uint32_t x, std::uint32_t y,
                                      std::uint32_t z) {
    return x + dims.nx * (y + dims.ny * z);
}

/// A fully-built Yee grid, ready for Metal: the leapfrog coefficients (see CopperFDTD.metal's
/// update_e_interior/update_h_interior for exactly how they're used), one flat `float` array per
/// (coefficient, axis) pair, indexed via copperGridIndex(). `vv[n]`/`vi[n]` are the
/// axis-`n` E-update coefficients (`volt(n,...) = vv[n]*volt(n,...) + vi[n]*curl(H)`); `ii[n]`/
/// `iv[n]` are the symmetric H-update coefficients. Primary (E) grid lines are the mesh's own lines
/// verbatim; dual (H) grid lines are their midpoints (CopperOperator::discLine(n, pos,
/// /*dualMesh=*/true)), boundary-mirrored where there's no neighbor to average.
struct CopperYeeGrid {
    CopperGridDims dims;
    std::vector<float> lineX, lineY, lineZ;             // primary (E) mesh lines, metres
    std::vector<float> dualLineX, dualLineY, dualLineZ; // dual (H) mesh lines, metres
    double timestepSeconds = 0.0;                       // CFL timestep (CopperOperator's Var3 criterion)

    std::vector<float> vv[3];
    std::vector<float> vi[3];
    std::vector<float> ii[3];
    std::vector<float> iv[3];

    /// Mesh spacing along each axis in metres, kept in double precision (the float lines above lose
    /// most of a fine spacing's digits): primaryDelta[a][i] is the primary-mesh edge length at line
    /// i along axis a (CopperOperator::discDelta(a, i, false) times the grid delta), dualDelta[a][i] the dual
    /// one. Every coefficient's geometry is a product of these, one factor per axis -- with nP/nPP
    /// the other two axes,
    ///   vi[n] = (material term) * primaryDelta[n][pos n] / (dualDelta[nP][pos nP] * dualDelta[nPP][pos nPP])
    ///   iv[n] = (material term) * dualDelta[n][pos n] / (primaryDelta[nP][pos nP] * primaryDelta[nPP][pos nPP])
    /// (C = eps*area/length and L = mu*area/length, with the area the two dual or primary widths
    /// across the edge). Empty if the builder didn't provide them.
    std::vector<double> primaryDelta[3], dualDelta[3];
};

} // namespace copper
