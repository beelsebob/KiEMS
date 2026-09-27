// Interior Yee-grid leapfrog update kernels -- a direct GPU port of openEMS's own
// Engine::UpdateVoltages/UpdateCurrents (engine.cpp), cyclically permuted per axis. Every neighbor
// offset and boundary-safety trick below is copied verbatim from that source, not re-derived, so
// there's one place (this comment) documenting the correspondence rather than trusting it was
// transcribed correctly by eye:
//
//   update_e_interior <-> Engine::UpdateVoltages, dispatched over the FULL (nx,ny,nz) grid. The
//   lower-index neighbor in each curl term is guarded by `shift = (pos != 0)`: at pos==0, shift is
//   0, so `pos - shift` reads the *same* cell instead of underflowing -- and since both terms of
//   that difference then read the identical value, they cancel to exactly zero. That's not a
//   special case bolted on top; it's openEMS's own boundary treatment, baked into the same formula
//   that runs everywhere else.
//
//   update_h_interior <-> Engine::UpdateCurrents, dispatched over (nx-1,ny-1,nz-1) only (openEMS's
//   own IterateTS calls `UpdateCurrents(0, numLines[0]-1)`, one less than UpdateVoltages's full
//   range, and UpdateCurrents' own y/z loops are separately bounded to numLines-1 too) -- H
//   physically exists on a grid one cell smaller than E per axis (the dual/staggered mesh has one
//   fewer line than the primary mesh), so every pos+1 neighbor read here stays in bounds by
//   construction; no shift trick is needed on this side.
//
// PEC boundary handling is deliberately NOT a separate kernel here (see the Copper implementation
// plan's Phase 2 scope): a PEC wall needs no extra state or update pass, unlike MUR or PML, both of
// which store their own auxiliary field history across timesteps. It falls out for free from
// openEMS's own per-cell vv/vi/ii/iv coefficients (computed by CopperYeeGrid's extraction, not
// re-derived here) already encoding each cell's actual material/boundary condition -- this kernel
// just applies whatever coefficient it's handed, uniformly, everywhere.

#include <metal_stdlib>

#include "CopperShaderTypes.h"

using namespace metal;

namespace {

inline uint32_t copperIndex(constant CopperGridDimsGPU& dims, uint32_t x, uint32_t y, uint32_t z) {
    return x + dims.nx * (y + dims.ny * z);
}

} // namespace

kernel void update_e_interior(constant CopperGridDimsGPU& dims [[buffer(CopperBufferIndexDims)]],
                               device float* Ex [[buffer(CopperBufferIndexEx)]],
                               device float* Ey [[buffer(CopperBufferIndexEy)]],
                               device float* Ez [[buffer(CopperBufferIndexEz)]],
                               device const float* Hx [[buffer(CopperBufferIndexHx)]],
                               device const float* Hy [[buffer(CopperBufferIndexHy)]],
                               device const float* Hz [[buffer(CopperBufferIndexHz)]],
                               device const float* vv0 [[buffer(CopperBufferIndexVV0)]],
                               device const float* vv1 [[buffer(CopperBufferIndexVV1)]],
                               device const float* vv2 [[buffer(CopperBufferIndexVV2)]],
                               device const float* vi0 [[buffer(CopperBufferIndexVI0)]],
                               device const float* vi1 [[buffer(CopperBufferIndexVI1)]],
                               device const float* vi2 [[buffer(CopperBufferIndexVI2)]],
                               uint3 gid [[thread_position_in_grid]]) {
    if (gid.x >= dims.nx || gid.y >= dims.ny || gid.z >= dims.nz) {
        return;
    }
    const uint32_t x = gid.x, y = gid.y, z = gid.z;
    const uint32_t sx = (x != 0) ? 1 : 0;
    const uint32_t sy = (y != 0) ? 1 : 0;
    const uint32_t sz = (z != 0) ? 1 : 0;
    const uint32_t idx = copperIndex(dims, x, y, z);

    // Ex: curl term is (Hz - Hz[y-1] - Hy + Hy[z-1]).
    Ex[idx] = vv0[idx] * Ex[idx] + vi0[idx] * (Hz[copperIndex(dims, x, y, z)] -
                                                 Hz[copperIndex(dims, x, y - sy, z)] -
                                                 Hy[copperIndex(dims, x, y, z)] +
                                                 Hy[copperIndex(dims, x, y, z - sz)]);

    // Ey: curl term is (Hx - Hx[z-1] - Hz + Hz[x-1]).
    Ey[idx] = vv1[idx] * Ey[idx] + vi1[idx] * (Hx[copperIndex(dims, x, y, z)] -
                                                 Hx[copperIndex(dims, x, y, z - sz)] -
                                                 Hz[copperIndex(dims, x, y, z)] +
                                                 Hz[copperIndex(dims, x - sx, y, z)]);

    // Ez: curl term is (Hy - Hy[x-1] - Hx + Hx[y-1]).
    Ez[idx] = vv2[idx] * Ez[idx] + vi2[idx] * (Hy[copperIndex(dims, x, y, z)] -
                                                 Hy[copperIndex(dims, x - sx, y, z)] -
                                                 Hx[copperIndex(dims, x, y, z)] +
                                                 Hx[copperIndex(dims, x, y - sy, z)]);
}

kernel void update_h_interior(constant CopperGridDimsGPU& dims [[buffer(CopperBufferIndexDims)]],
                               device const float* Ex [[buffer(CopperBufferIndexEx)]],
                               device const float* Ey [[buffer(CopperBufferIndexEy)]],
                               device const float* Ez [[buffer(CopperBufferIndexEz)]],
                               device float* Hx [[buffer(CopperBufferIndexHx)]],
                               device float* Hy [[buffer(CopperBufferIndexHy)]],
                               device float* Hz [[buffer(CopperBufferIndexHz)]],
                               device const float* ii0 [[buffer(CopperBufferIndexII0)]],
                               device const float* ii1 [[buffer(CopperBufferIndexII1)]],
                               device const float* ii2 [[buffer(CopperBufferIndexII2)]],
                               device const float* iv0 [[buffer(CopperBufferIndexIV0)]],
                               device const float* iv1 [[buffer(CopperBufferIndexIV1)]],
                               device const float* iv2 [[buffer(CopperBufferIndexIV2)]],
                               uint3 gid [[thread_position_in_grid]]) {
    // Dispatched over exactly (nx-1, ny-1, nz-1) -- every pos+1 read below is guaranteed in bounds
    // by that dispatch size alone; this guard is defensive belt-and-suspenders, not load-bearing.
    if (gid.x + 1 >= dims.nx || gid.y + 1 >= dims.ny || gid.z + 1 >= dims.nz) {
        return;
    }
    const uint32_t x = gid.x, y = gid.y, z = gid.z;
    const uint32_t idx = copperIndex(dims, x, y, z);

    // Hx: curl term is (Ez - Ez[y+1] - Ey + Ey[z+1]).
    Hx[idx] = ii0[idx] * Hx[idx] + iv0[idx] * (Ez[copperIndex(dims, x, y, z)] -
                                                 Ez[copperIndex(dims, x, y + 1, z)] -
                                                 Ey[copperIndex(dims, x, y, z)] +
                                                 Ey[copperIndex(dims, x, y, z + 1)]);

    // Hy: curl term is (Ex - Ex[z+1] - Ez + Ez[x+1]).
    Hy[idx] = ii1[idx] * Hy[idx] + iv1[idx] * (Ex[copperIndex(dims, x, y, z)] -
                                                 Ex[copperIndex(dims, x, y, z + 1)] -
                                                 Ez[copperIndex(dims, x, y, z)] +
                                                 Ez[copperIndex(dims, x + 1, y, z)]);

    // Hz: curl term is (Ey - Ey[x+1] - Ex + Ex[y+1]).
    Hz[idx] = ii2[idx] * Hz[idx] + iv2[idx] * (Ey[copperIndex(dims, x, y, z)] -
                                                 Ey[copperIndex(dims, x + 1, y, z)] -
                                                 Ex[copperIndex(dims, x, y, z)] +
                                                 Ex[copperIndex(dims, x, y + 1, z)]);
}

// CPML (real CFS-PML, Roden & Gedney 2000) correction kernels -- a direct port of Taflove & Hagness,
// *Computational Electrodynamics* 3rd ed., eq. (7.101)/(7.105)/(7.106) for E and eq. (7.101)/(7.110)/
// (7.108) for H, read from the actual text (see CopperCPML.hpp's own top comment for why this is a
// convolutional perfectly matched layer. These are dispatched *after*
// update_e_interior/update_h_interior (either order
// relative to each other is fine -- neither reads a buffer the other writes) and never swap/replace a
// field value: they only ever add a correction, using the exact same host-medium vi/iv coefficient
// and the exact same two raw curl-difference terms (same shift-guard included) update_e_interior/
// update_h_interior already compute internally, so psi's own units/scaling stay consistent with the
// ordinary update by construction rather than by re-deriving a separate normalization.
//
// b/c are axis-major merged by *grading* axis (x,y,z); psi0/psi1 are axis-major merged by *field
// component* axis (Ex/Ey/Ez or Hx/Hy/Hz) -- see CopperCPMLShell's own doc comment. For component n,
// psi0[n] is driven by the same curl term that's positive/first in update_e_interior's own formula
// for that component (grading axis nP=(n+1)%3), psi1[n] by the second/negative term (grading axis
// nPP=(n+2)%3) -- mirrored exactly below, including which raw difference feeds which slot.

kernel void cpml_correct_e(constant CopperGridDimsGPU& dims [[buffer(CopperBufferIndexDims)]],
                            constant CopperCPMLShellGPU& shell [[buffer(CopperBufferIndexCPMLShell)]],
                            device float* Ex [[buffer(CopperBufferIndexEx)]],
                            device float* Ey [[buffer(CopperBufferIndexEy)]],
                            device float* Ez [[buffer(CopperBufferIndexEz)]],
                            device const float* Hx [[buffer(CopperBufferIndexHx)]],
                            device const float* Hy [[buffer(CopperBufferIndexHy)]],
                            device const float* Hz [[buffer(CopperBufferIndexHz)]],
                            device const float* vi0 [[buffer(CopperBufferIndexVI0)]],
                            device const float* vi1 [[buffer(CopperBufferIndexVI1)]],
                            device const float* vi2 [[buffer(CopperBufferIndexVI2)]],
                            device const float* bCoef [[buffer(CopperBufferIndexCPMLCoeffB)]],
                            device const float* cCoef [[buffer(CopperBufferIndexCPMLCoeffC)]],
                            device float* psi0 [[buffer(CopperBufferIndexCPMLPsi0)]],
                            device float* psi1 [[buffer(CopperBufferIndexCPMLPsi1)]],
                            uint3 lid [[thread_position_in_grid]]) {
    if (lid.x >= shell.nx || lid.y >= shell.ny || lid.z >= shell.nz) {
        return;
    }
    const uint32_t localCellCount = shell.nx * shell.ny * shell.nz;
    const uint32_t localIdx = lid.x + shell.nx * (lid.y + shell.ny * lid.z);
    const uint32_t x = lid.x + shell.startX, y = lid.y + shell.startY, z = lid.z + shell.startZ;
    const uint32_t sx = (x != 0) ? 1 : 0;
    const uint32_t sy = (y != 0) ? 1 : 0;
    const uint32_t sz = (z != 0) ? 1 : 0;
    const uint32_t globalIdx = copperIndex(dims, x, y, z);

    // Ex: same two terms as update_e_interior's own (Hz-diff, then -Hy-diff) -- grading axes y (nP),
    // z (nPP).
    {
        const uint32_t bc0 = 1u * localCellCount + localIdx; // y-axis coefficient slot
        const uint32_t bc1 = 2u * localCellCount + localIdx; // z-axis coefficient slot
        const uint32_t p = 0u * localCellCount + localIdx;   // Ex's own psi0/psi1 slot
        const float hzDiff = Hz[copperIndex(dims, x, y, z)] - Hz[copperIndex(dims, x, y - sy, z)];
        const float hyDiff = Hy[copperIndex(dims, x, y, z)] - Hy[copperIndex(dims, x, y, z - sz)];
        psi0[p] = bCoef[bc0] * psi0[p] + cCoef[bc0] * hzDiff;
        psi1[p] = bCoef[bc1] * psi1[p] + cCoef[bc1] * hyDiff;
        Ex[globalIdx] += vi0[globalIdx] * (psi0[p] - psi1[p]);
    }
    // Ey: (Hx-diff, then -Hz-diff) -- grading axes z (nP), x (nPP).
    {
        const uint32_t bc0 = 2u * localCellCount + localIdx;
        const uint32_t bc1 = 0u * localCellCount + localIdx;
        const uint32_t p = 1u * localCellCount + localIdx;
        const float hxDiff = Hx[copperIndex(dims, x, y, z)] - Hx[copperIndex(dims, x, y, z - sz)];
        const float hzDiff = Hz[copperIndex(dims, x, y, z)] - Hz[copperIndex(dims, x - sx, y, z)];
        psi0[p] = bCoef[bc0] * psi0[p] + cCoef[bc0] * hxDiff;
        psi1[p] = bCoef[bc1] * psi1[p] + cCoef[bc1] * hzDiff;
        Ey[globalIdx] += vi1[globalIdx] * (psi0[p] - psi1[p]);
    }
    // Ez: (Hy-diff, then -Hx-diff) -- grading axes x (nP), y (nPP).
    {
        const uint32_t bc0 = 0u * localCellCount + localIdx;
        const uint32_t bc1 = 1u * localCellCount + localIdx;
        const uint32_t p = 2u * localCellCount + localIdx;
        const float hyDiff = Hy[copperIndex(dims, x, y, z)] - Hy[copperIndex(dims, x - sx, y, z)];
        const float hxDiff = Hx[copperIndex(dims, x, y, z)] - Hx[copperIndex(dims, x, y - sy, z)];
        psi0[p] = bCoef[bc0] * psi0[p] + cCoef[bc0] * hyDiff;
        psi1[p] = bCoef[bc1] * psi1[p] + cCoef[bc1] * hxDiff;
        Ez[globalIdx] += vi2[globalIdx] * (psi0[p] - psi1[p]);
    }
}

kernel void cpml_correct_h(constant CopperGridDimsGPU& dims [[buffer(CopperBufferIndexDims)]],
                            constant CopperCPMLShellGPU& shell [[buffer(CopperBufferIndexCPMLShell)]],
                            device const float* Ex [[buffer(CopperBufferIndexEx)]],
                            device const float* Ey [[buffer(CopperBufferIndexEy)]],
                            device const float* Ez [[buffer(CopperBufferIndexEz)]],
                            device float* Hx [[buffer(CopperBufferIndexHx)]],
                            device float* Hy [[buffer(CopperBufferIndexHy)]],
                            device float* Hz [[buffer(CopperBufferIndexHz)]],
                            device const float* iv0 [[buffer(CopperBufferIndexIV0)]],
                            device const float* iv1 [[buffer(CopperBufferIndexIV1)]],
                            device const float* iv2 [[buffer(CopperBufferIndexIV2)]],
                            device const float* bCoef [[buffer(CopperBufferIndexCPMLCoeffB)]],
                            device const float* cCoef [[buffer(CopperBufferIndexCPMLCoeffC)]],
                            device float* psi0 [[buffer(CopperBufferIndexCPMLPsi0)]],
                            device float* psi1 [[buffer(CopperBufferIndexCPMLPsi1)]],
                            uint3 lid [[thread_position_in_grid]]) {
    // Dispatched over the shell's own local box, but only cells satisfying update_h_interior's own
    // (nx-1,ny-1,nz-1) dispatch bound have a meaningful H value to correct -- guard identically.
    if (lid.x >= shell.nx || lid.y >= shell.ny || lid.z >= shell.nz) {
        return;
    }
    const uint32_t x = lid.x + shell.startX, y = lid.y + shell.startY, z = lid.z + shell.startZ;
    if (x + 1 >= dims.nx || y + 1 >= dims.ny || z + 1 >= dims.nz) {
        return;
    }
    const uint32_t localCellCount = shell.nx * shell.ny * shell.nz;
    const uint32_t localIdx = lid.x + shell.nx * (lid.y + shell.ny * lid.z);
    const uint32_t globalIdx = copperIndex(dims, x, y, z);

    // Hx: same two terms as update_h_interior's own (Ez-diff, then -Ey-diff) -- grading axes y (nP),
    // z (nPP).
    {
        const uint32_t bc0 = 1u * localCellCount + localIdx;
        const uint32_t bc1 = 2u * localCellCount + localIdx;
        const uint32_t p = 0u * localCellCount + localIdx;
        const float ezDiff = Ez[copperIndex(dims, x, y, z)] - Ez[copperIndex(dims, x, y + 1, z)];
        const float eyDiff = Ey[copperIndex(dims, x, y, z)] - Ey[copperIndex(dims, x, y, z + 1)];
        psi0[p] = bCoef[bc0] * psi0[p] + cCoef[bc0] * ezDiff;
        psi1[p] = bCoef[bc1] * psi1[p] + cCoef[bc1] * eyDiff;
        Hx[globalIdx] += iv0[globalIdx] * (psi0[p] - psi1[p]);
    }
    // Hy: (Ex-diff, then -Ez-diff) -- grading axes z (nP), x (nPP).
    {
        const uint32_t bc0 = 2u * localCellCount + localIdx;
        const uint32_t bc1 = 0u * localCellCount + localIdx;
        const uint32_t p = 1u * localCellCount + localIdx;
        const float exDiff = Ex[copperIndex(dims, x, y, z)] - Ex[copperIndex(dims, x, y, z + 1)];
        const float ezDiff = Ez[copperIndex(dims, x, y, z)] - Ez[copperIndex(dims, x + 1, y, z)];
        psi0[p] = bCoef[bc0] * psi0[p] + cCoef[bc0] * exDiff;
        psi1[p] = bCoef[bc1] * psi1[p] + cCoef[bc1] * ezDiff;
        Hy[globalIdx] += iv1[globalIdx] * (psi0[p] - psi1[p]);
    }
    // Hz: (Ey-diff, then -Ex-diff) -- grading axes x (nP), y (nPP).
    {
        const uint32_t bc0 = 0u * localCellCount + localIdx;
        const uint32_t bc1 = 1u * localCellCount + localIdx;
        const uint32_t p = 2u * localCellCount + localIdx;
        const float eyDiff = Ey[copperIndex(dims, x, y, z)] - Ey[copperIndex(dims, x + 1, y, z)];
        const float exDiff = Ex[copperIndex(dims, x, y, z)] - Ex[copperIndex(dims, x, y + 1, z)];
        psi0[p] = bCoef[bc0] * psi0[p] + cCoef[bc0] * eyDiff;
        psi1[p] = bCoef[bc1] * psi1[p] + cCoef[bc1] * exDiff;
        Hz[globalIdx] += iv2[globalIdx] * (psi0[p] - psi1[p]);
    }
}

// Soft excitation -- a direct port of Engine_Ext_Excitation::Apply2VoltagesImpl/Apply2CurrentImpl
// (engine_ext_excitation.cpp), dispatched with exactly one thread per excited cell (not over the
// grid at all -- the excitation box is typically a handful of cells against a grid of potentially
// millions). Both kernels apply the identical clamp/wrap formula to `params.numTS`; only the target
// field buffers and which of CopperExcitation's two cell lists/signal arrays get bound differ
// (voltage/E vs current/H) -- see CopperEngine.mm's own comment on why both stages share one
// `params` uniform, rewritten once per timestep rather than twice.
//
// The exc_pos formula below is ported *exactly*, multiply-by-boolean tricks included, rather than
// rewritten as more obviously-equivalent branches -- see CopperExcitationCell's own doc comment:
// "clamp(timestep - delaySteps, 0, length-1 or wrapped by signalPeriodSeconds)" is the intent, but
// the actual openEMS behavior when exc_pos falls outside [0, length) is to read signal[0], not
// signal[length-1] -- reproducing that quirk exactly (not the "more correct" clamp) is the point.

inline void applyExcitationCell(constant CopperGridDimsGPU& dims, device float* field0, device float* field1,
                                 device float* field2, constant CopperExcitationCellGPU* cells,
                                 device const float* signal, constant CopperExcitationParamsGPU& params,
                                 uint tid) {
    const CopperExcitationCellGPU cell = cells[tid];

    int32_t excPos = params.numTS - int32_t(cell.delaySteps);
    excPos *= (excPos > 0);
    excPos %= params.period;
    excPos *= (excPos < int32_t(params.signalLength));

    const float value = cell.amplitude * signal[uint32_t(excPos)];
    const uint32_t idx = copperIndex(dims, cell.x, cell.y, cell.z);
    if (cell.axis == 0) {
        field0[idx] += value;
    } else if (cell.axis == 1) {
        field1[idx] += value;
    } else {
        field2[idx] += value;
    }
}

kernel void apply_excitation_e(constant CopperGridDimsGPU& dims [[buffer(CopperBufferIndexDims)]],
                                device float* Ex [[buffer(CopperBufferIndexEx)]],
                                device float* Ey [[buffer(CopperBufferIndexEy)]],
                                device float* Ez [[buffer(CopperBufferIndexEz)]],
                                constant CopperExcitationCellGPU* cells [[buffer(CopperBufferIndexExcCells)]],
                                device const float* signal [[buffer(CopperBufferIndexExcSignal)]],
                                constant CopperExcitationParamsGPU& params [[buffer(CopperBufferIndexExcParams)]],
                                uint tid [[thread_position_in_grid]]) {
    applyExcitationCell(dims, Ex, Ey, Ez, cells, signal, params, tid);
}

kernel void apply_excitation_h(constant CopperGridDimsGPU& dims [[buffer(CopperBufferIndexDims)]],
                                device float* Hx [[buffer(CopperBufferIndexHx)]],
                                device float* Hy [[buffer(CopperBufferIndexHy)]],
                                device float* Hz [[buffer(CopperBufferIndexHz)]],
                                constant CopperExcitationCellGPU* cells [[buffer(CopperBufferIndexExcCells)]],
                                device const float* signal [[buffer(CopperBufferIndexExcSignal)]],
                                constant CopperExcitationParamsGPU& params [[buffer(CopperBufferIndexExcParams)]],
                                uint tid [[thread_position_in_grid]]) {
    applyExcitationCell(dims, Hx, Hy, Hz, cells, signal, params, tid);
}
