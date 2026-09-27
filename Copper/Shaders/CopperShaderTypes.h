// Plain C types shared between CopperEngine.mm (dispatch/buffer setup) and CopperFDTD.metal (the
// kernels themselves) -- the buffer-index contract lives here once, so the two sides can never
// silently disagree about which MTLBuffer a given kernel argument refers to. Same convention as
// this project's existing GeometryShaders.metal/GeometryView.swift Metal usage.
#ifndef CopperShaderTypes_h
#define CopperShaderTypes_h

#include <simd/simd.h>

struct CopperGridDimsGPU {
    uint32_t nx;
    uint32_t ny;
    uint32_t nz;
};

struct CopperDispatchOriginGPU { uint32_t x, y, z; };

// One CPML shell's box: its origin in global grid coordinates, plus its local dimensions.
struct CopperCPMLShellGPU {
    uint32_t startX, startY, startZ;
    uint32_t nx, ny, nz;
};

// One excited Yee edge -- field-for-field identical layout to copper::CopperExcitationCell
// (CopperExcitation.hpp), which CopperEngine.mm uploads directly via newBufferWithBytes without a
// separate host-side conversion step (see the static_assert next to where it's used).
struct CopperExcitationCellGPU {
    uint32_t x, y, z;
    uint32_t axis;
    float amplitude;
    uint32_t delaySteps;
};

// apply_excitation_e/apply_excitation_h's per-timestep parameters -- everything here (`numTS`,
// `period`) changes every timestep (see Engine_Ext_Excitation::Apply2VoltagesImpl's own `p =
// numTS+1` for an aperiodic signal), so CopperEngine.mm passes a fresh one via setBytes: on every
// dispatch rather than uploading it once at construction like the cell/signal buffers below.
struct CopperExcitationParamsGPU {
    int32_t numTS;
    int32_t period;
    uint32_t signalLength;
};

// A rectangular run uses the full (nx,ny,nz)/(nx-1,ny-1,nz-1) extents. An irregular run uses an
// origin plus a set of active cuboids within those same bounds; see CopperEngine.mm.
enum CopperBufferIndex {
    CopperBufferIndexDims = 0,
    CopperBufferIndexEx = 1,
    CopperBufferIndexEy = 2,
    CopperBufferIndexEz = 3,
    CopperBufferIndexHx = 4,
    CopperBufferIndexHy = 5,
    CopperBufferIndexHz = 6,
    CopperBufferIndexVV0 = 7,
    CopperBufferIndexVV1 = 8,
    CopperBufferIndexVV2 = 9,
    CopperBufferIndexVI0 = 10,
    CopperBufferIndexVI1 = 11,
    CopperBufferIndexVI2 = 12,
    CopperBufferIndexII0 = 13,
    CopperBufferIndexII1 = 14,
    CopperBufferIndexII2 = 15,
    CopperBufferIndexIV0 = 16,
    CopperBufferIndexIV1 = 17,
    CopperBufferIndexIV2 = 18,

    CopperBufferIndexCPMLShell = 19,

    // apply_excitation_e/apply_excitation_h -- dispatched with one thread per excited cell (a tiny
    // dispatch against the excitation box, not the whole grid), reusing CopperBufferIndexDims and
    // the field-buffer indices above like the PML kernels do.
    CopperBufferIndexExcCells = 20,  // device array of CopperExcitationCellGPU
    CopperBufferIndexExcSignal = 21, // device array of float: openEMS's own precomputed pulse samples
    // CopperExcitationParamsGPU -- bound via setBytes:length:atIndex:, not an uploaded MTLBuffer, so
    // each timestep's dispatch gets its own encode-time snapshot (see CopperEngine.mm's own comment
    // on why a shared, CPU-rewritten buffer doesn't work once several timesteps get batched into one
    // command buffer).
    CopperBufferIndexExcParams = 22,

    // cpml_correct_e/cpml_correct_h -- see CopperCPML.hpp's own doc comment for why this is a
    // separate, purely-additive kernel pair. Reuses CopperBufferIndexDims/CPMLShell and the
    // field/VI/IV buffer indices above. "CoeffB"/"CoeffC" hold the
    // per-*grading*-axis b[w]/c[w] coefficients (axis-major merged, 3 axes); "Psi0"/"Psi1" hold the
    // per-*field-component* auxiliary convolution state (also axis-major merged, but over the 3
    // field-component axes) -- see CopperCPMLShell's own doc comment for why these are two distinct
    // "axis-major" meanings sharing the same buffer layout convention.
    CopperBufferIndexCPMLCoeffB = 23, // b[w], axis-major merged by grading axis
    CopperBufferIndexCPMLCoeffC = 24, // c[w], axis-major merged by grading axis
    CopperBufferIndexCPMLPsi0 = 25,   // psi driven by the nP-axis curl term, axis-major by component, read-write
    CopperBufferIndexCPMLPsi1 = 26,   // psi driven by the nPP-axis curl term, axis-major by component, read-write
    CopperBufferIndexDispatchOrigin = 27,
};

#endif /* CopperShaderTypes_h */
