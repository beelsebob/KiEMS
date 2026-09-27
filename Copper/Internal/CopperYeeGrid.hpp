// Extracts openEMS's own already-built Yee grid (mesh lines + leapfrog coefficients) into flat,
// structure-of-arrays buffers ready to hand straight to a Metal MTLBuffer -- no reimplementation of
// grid/coefficient math here, just walking `Operator`'s own public accessors (see
// CopperOpenEMSAccess.hpp's file comment for why: every number here is openEMS's own answer).
//
// Uses the flat (unnamespaced) CSXCAD/openEMS includes -- see CopperOpenEMSAccess.hpp's own
// warning about not mixing those with the installed, namespaced `<CSXCAD/...>` headers.
#pragma once

#include <cstdint>
#include <vector>

class Operator;

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

/// A fully-built Yee grid, ready for Metal: `Operator::GetVV/GetVI/GetII/GetIV`'s own leapfrog
/// coefficients (see engine.cpp's UpdateVoltages/UpdateCurrents for exactly how they're used --
/// Copper's own Metal kernels reimplement that update loop, not this extraction), one flat `float`
/// array per (coefficient, axis) pair, indexed via copperGridIndex(). `vv[n]`/`vi[n]` are the
/// axis-`n` E-update coefficients (`volt(n,...) = vv[n]*volt(n,...) + vi[n]*curl(H)`); `ii[n]`/
/// `iv[n]` are the symmetric H-update coefficients. Primary (E) grid lines are the mesh's own lines
/// verbatim; dual (H) grid lines are openEMS's own already-computed midpoints (`GetDiscLine(n, pos,
/// /*dualMesh=*/true)`), boundary-mirrored by openEMS itself where there's no neighbor to average.
struct CopperYeeGrid {
    CopperGridDims dims;
    std::vector<float> lineX, lineY, lineZ;             // primary (E) mesh lines, metres
    std::vector<float> dualLineX, dualLineY, dualLineZ; // dual (H) mesh lines, metres
    double timestepSeconds = 0.0;                       // Operator::GetTimestep() -- openEMS's own CFL dt

    std::vector<float> vv[3];
    std::vector<float> vi[3];
    std::vector<float> ii[3];
    std::vector<float> iv[3];
};

/// Walks `op`'s already-built grid/coefficients (i.e. `SetGeometryCSX`+`CalcECOperator`, or
/// equivalently `openEMS::SetupFDTD()`, must already have run) into a CopperYeeGrid. `op`'s own
/// `GetDiscLine` returns grid-delta-unit values (not metres) -- multiplied here by
/// `op->GetGridDelta()`-equivalent scaling already baked into openEMS's own coordinate convention;
/// see the .cpp for the exact unit handling.
CopperYeeGrid buildYeeGrid(Operator& op);

} // namespace copper
