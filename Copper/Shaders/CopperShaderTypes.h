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

// One PML shell's box: its origin in *global* grid coordinates, plus its own *local* dimensions.
// pml_pre_e/pml_post_e/pml_pre_h/pml_post_h are each dispatched once per shell, over (nx,ny,nz)
// threads in the shell's *local* index space -- see CopperPML.hpp for why there can be several of
// these (one per active PML face, not one shared box for the whole boundary).
struct CopperPMLShellGPU {
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

// update_e_interior is dispatched over the full (nx,ny,nz) grid; update_h_interior over
// (nx-1,ny-1,nz-1) -- see CopperEngine.mm's own comment on why (openEMS's own H/dual-mesh update
// loop bounds, ported verbatim: H only physically exists on a grid one cell smaller per axis than
// E, so every pos+1 neighbor read update_h_interior does stays in bounds by construction).
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

    // PML kernels (pml_pre_e/pml_post_e/pml_pre_h/pml_post_h) reuse CopperBufferIndexDims (the
    // *global* grid dims, needed to index into the full-size Ex/Ey/Ez/Hx/Hy/Hz buffers, which they
    // also share via the indices above) plus these PML-only slots. "CoeffA/B/C" hold whichever
    // shell-local coefficient triplet that particular kernel needs (vv/vvfo/vvfn for the E-side
    // pre/post pair, ii/iifo/iifn for the H-side pair) -- never more than one triplet is bound at
    // once, so E-side and H-side dispatches safely reuse the same three index slots at different
    // points in the per-timestep dispatch sequence (see CopperEngine.mm's run()).
    CopperBufferIndexPMLShell = 19,
    CopperBufferIndexPMLCoeffA = 20, // vv (E pre/post) or ii (H pre/post)
    CopperBufferIndexPMLCoeffB = 21, // vvfo (E pre) or iifo (H pre) -- unused by the post kernels
    CopperBufferIndexPMLCoeffC = 22, // vvfn (E post) or iifn (H post) -- unused by the pre kernels
    CopperBufferIndexPMLFlux = 23,   // volt_flux (E-side) or curr_flux (H-side), shell-local

    // apply_excitation_e/apply_excitation_h -- dispatched with one thread per excited cell (a tiny
    // dispatch against the excitation box, not the whole grid), reusing CopperBufferIndexDims and
    // the field-buffer indices above like the PML kernels do.
    CopperBufferIndexExcCells = 24,  // device array of CopperExcitationCellGPU
    CopperBufferIndexExcSignal = 25, // device array of float: openEMS's own precomputed pulse samples
    // CopperExcitationParamsGPU -- bound via setBytes:length:atIndex:, not an uploaded MTLBuffer, so
    // each timestep's dispatch gets its own encode-time snapshot (see CopperEngine.mm's own comment
    // on why a shared, CPU-rewritten buffer doesn't work once several timesteps get batched into one
    // command buffer).
    CopperBufferIndexExcParams = 26,

    // cpml_correct_e/cpml_correct_h -- see CopperCPML.hpp's own doc comment for why this is a
    // separate, purely-additive kernel pair rather than a pre/post swap like PMLCoeffA/B/C above.
    // Reuses CopperBufferIndexDims/PMLShell (the shell-box uniform is the identical
    // CopperPMLShellGPU shape) and the field/VI/IV buffer indices above. "CoeffB"/"CoeffC" hold the
    // per-*grading*-axis b[w]/c[w] coefficients (axis-major merged, 3 axes); "Psi0"/"Psi1" hold the
    // per-*field-component* auxiliary convolution state (also axis-major merged, but over the 3
    // field-component axes) -- see CopperCPMLShell's own doc comment for why these are two distinct
    // "axis-major" meanings sharing the same buffer layout convention. Never bound at the same time
    // as the PMLCoeffA/PMLFlux slots (CPML and UPML are mutually exclusive per run), so reusing
    // PMLCoeffB/PMLCoeffC's own index numbers would also have been safe, but distinct names/slots
    // keep the two kernel families easier to read independently.
    CopperBufferIndexCPMLCoeffB = 27, // b[w], axis-major merged by grading axis
    CopperBufferIndexCPMLCoeffC = 28, // c[w], axis-major merged by grading axis
    CopperBufferIndexCPMLPsi0 = 29,   // psi driven by the nP-axis curl term, axis-major by component, read-write
    CopperBufferIndexCPMLPsi1 = 30,   // psi driven by the nPP-axis curl term, axis-major by component, read-write
};

#endif /* CopperShaderTypes_h */
