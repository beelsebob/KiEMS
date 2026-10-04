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
// COPPER_FIELD_Q16: one 4x4x1 tile (see CopperFDTD.metal's QField) an update kernel re-encodes,
// with `mask` bit n set when the tile's cell n (x-fastest) is in the dispatched domain.
struct CopperQBlockGPU {
    uint32_t block;
    uint32_t mask;
};

// One SERIES lumped RLC Yee edge -- field-for-field identical layout to copper::CopperLumpedRLCCell
// (CopperLumpedRLC.hpp), uploaded by raw bytes like CopperExcitationCellGPU. The seven coefficients
// drive the ADE update in CopperFDTD.metal's lumpedRLCStep.
struct CopperLumpedRLCCellGPU {
    uint32_t x, y, z;
    uint32_t axis;
    float ib0, b1, b2, vv2, vj1, vj2, vvd;
};

// COPPER_FUSED: one E correction the fused kernel applies after its E update -- `index` into the
// voltage excitation cells (kind 0) or lumped RLC elements (kind 1). Sorted by tile, then excitation
// before lumped, the order the separate kernels apply them in; the tile's entries are
// corrections[offsets[tile] .. offsets[tile + 1]).
struct CopperFusedCorrectionGPU {
    uint32_t lane;  // cell within its 4x4 tile, x-fastest
    uint32_t axis;  // E component
    uint32_t kind;  // 0 excitation, 1 lumped RLC
    uint32_t index;
};

// COPPER_FUSED: one threadgroup's share of the fused E+H update -- the 16x16-cell column whose first
// tile is (tileX, tileY), from tile plane z0 up to (not including) z1, storing the tiles of the 4x4
// block set in ownedMask (bit tileX' + 4 tileY', relative). See CopperFDTD.metal's fusedEH.
struct CopperQSegmentGPU {
    uint32_t tileX, tileY, z0, z1, ownedMask;
};

// COPPER_FIELD_Q16: one 4x4x1 tile of field component `axis` holding excitation cells
// cells[first .. first+count).
struct CopperQExcitationBlockGPU {
    uint32_t block;
    uint32_t axis;
    uint32_t first;
    uint32_t count;
};

// COPPER_FIELD_Q16's rounding for one dispatch, bound via setBytes: stochastic (floor(x + u), u
// hashed from the cell, `seed` and the component) unless `stochastic` is 0 (round to nearest).
// `seed` differs per timestep and per dispatch, so no two stores reuse the same dither.
// It also carries COPPER_FIELD_MIXED's promotion thresholds (see CopperFDTD.metal's qRequest): a
// Q16 tile asks for fp32 once its peak amplitude reaches `promote` times its side's all-time peak
// tile amplitude, and an fp32 tile keeps asking while it stays above `demote` times it.
struct CopperQRoundingGPU {
    uint32_t seed;
    uint32_t stochastic;
    float promote;
    float demote;
};

struct CopperExcitationParamsGPU {
    int32_t numTS;
    int32_t period;
    uint32_t signalLength;
};

// One copper::CopperCoefficientTable entry: vv[n] (ii[n]) exactly, and vi[n] (iv[n]) with its cell's
// separable geometry factor divided out. Layout-identical to CopperCoefficientTable::Entry.
struct CopperMaterialCoefficientsGPU {
    float decay[3];
    float material[3];
};

// copper::CopperCPML on the GPU, for the _cpml/_zcpml update kernels. One entry per grid line, x lines
// then y then z: `layer` indexes the psi arrays' layers along that axis, or is kCopperCPMLNoLayer
// outside the axis's slabs, and b/c are eq. (7.99)/(7.102) at the V-side (E update) and I-side (H
// update) positions.
#define kCopperCPMLNoLayer 0xFFFFFFFFu
struct CopperCPMLLineGPU {
    uint32_t layer;
    float bE, cE, bH, cH;
};

// Where a side's psi lives in its buffer. For each graded axis w, two arrays of psiCount[w] cells
// from psiOffset[w]: the psi of component (w+1)%3 (its subtracted curl term), then of component
// (w+2)%3 (its added term), each laid out like the grid with w's extent replaced by layers[w].
// Offsets and counts are in elements of the psi format (see CopperFunctionConstantPsiFormat); fp16
// stores psi times psiScale. Bound per dispatch with setBytes: `seed` differs every step and side,
// for the stochastically rounded format's dither.
struct CopperCPMLGPU {
    uint32_t layers[3];
    uint32_t psiOffset[3];
    uint32_t psiCount[3];
    float psiScale, psiInverseScale;
    uint32_t seed;
    uint32_t psiDropBits, psiStochastic; // the study formats' bit count, and whether they round stochastically
    uint32_t psiTotal;                   // psi elements in the buffer (where Float24's 8-bit array starts)
    uint32_t psiBlocks;                  // Block16: exponents per term (6 terms after the psiTotal mantissas)
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

    // The update coefficients in table form (see copper::CopperCoefficientTable), bound with the
    // E side's buffers for E-update kernels and the H side's for H-update kernels. Indices 10-18
    // once held twelve per-cell coefficient arrays and are now unused.
    CopperBufferIndexMaterialIndex = 7, // per cell: ushort or uint index into the table
    CopperBufferIndexMaterialTable = 8, // array of CopperMaterialCoefficientsGPU
    CopperBufferIndexGeometry = 9,      // float: own spacing along x,y,z, then 1/(across spacing) along x,y,z

    // COPPER_FIELD_MIXED's per-tile state, shared by both sides (see CopperFDTD.metal's QTileState).
    CopperBufferIndexQTileState = 10,
    // Q16 update kernels: where the side being updated is written. The same buffers as that
    // side's input slots, except under COPPER_FUSED's ping-pong, where every step reads one buffer set
    // and writes the other. The fused E+H kernel writes E to OutX..Z and H to OutHx..Hz.
    CopperBufferIndexOutX = 11,
    CopperBufferIndexOutY = 12,
    CopperBufferIndexOutZ = 13,
    CopperBufferIndexOutHx = 14,
    CopperBufferIndexOutHy = 15,
    CopperBufferIndexOutHz = 16,
    // The fused E+H kernel's H-side coefficient table (the E side's is at MaterialIndex..Geometry).
    CopperBufferIndexMaterialIndexH = 17,
    CopperBufferIndexMaterialTableH = 18,
    CopperBufferIndexGeometryH = 19,

    // apply_excitation_e/apply_excitation_h -- dispatched with one thread per excited cell (a tiny
    // dispatch against the excitation box, not the whole grid), reusing CopperBufferIndexDims and
    // the field-buffer indices above.
    CopperBufferIndexExcCells = 20,  // device array of CopperExcitationCellGPU
    CopperBufferIndexExcSignal = 21, // device array of float: openEMS's own precomputed pulse samples
    // CopperExcitationParamsGPU -- bound via setBytes:length:atIndex:, not an uploaded MTLBuffer, so
    // each timestep's dispatch gets its own encode-time snapshot (see CopperEngine.mm's own comment
    // on why a shared, CPU-rewritten buffer doesn't work once several timesteps get batched into one
    // command buffer).
    CopperBufferIndexExcParams = 22,

    // The fused E+H kernel's E corrections (COPPER_FUSED, see CopperFDTD.metal's fusedEH): voltage
    // excitation at ExcCells/ExcSignal/ExcParams, lumped RLC elements and their state in and out, and
    // the per-tile list of which of them land where. Its rounding moves out of ExcParams' way, and
    // the per-tile lists take the CPML's slots: the fused kernel never covers a CPML cell.
    CopperBufferIndexFusedRounding = 23,
    CopperBufferIndexFusedLumpedCells = 24,
    CopperBufferIndexFusedLumpedState = 25,
    CopperBufferIndexFusedLumpedStateOut = 26,
    CopperBufferIndexDispatchOrigin = 27,

    // The _cpml/_zcpml update kernels' CPML (see copper::CopperCPML). Metal's buffer argument table
    // ends at 30.
    CopperBufferIndexCPMLLines = 28,  // device array of CopperCPMLLineGPU, one per grid line
    CopperBufferIndexCPMLLayout = 29, // CopperCPMLGPU
    CopperBufferIndexCPMLPsi = 30,    // the side's psi, laid out as CopperCPMLGPU says, read-write
    CopperBufferIndexFusedCorrections = CopperBufferIndexCPMLLines,
    CopperBufferIndexFusedCorrectionOffsets = CopperBufferIndexCPMLLayout,

    // COPPER_FIELD_Q16's block list (CopperQBlockGPU or CopperQExcitationBlockGPU). Shares
    // DispatchOrigin's slot: the table is full, and the Q16 kernels dispatch over blocks, not boxes.
    CopperBufferIndexQBlocks = CopperBufferIndexDispatchOrigin,
    // COPPER_FIELD_Q16's CopperQRoundingGPU: in ExcParams' slot for the update kernels, which have no
    // excitation, and GeometryH's for the excitation kernel, which isn't fused.
    CopperBufferIndexQRounding = CopperBufferIndexExcParams,
    CopperBufferIndexQExcitationRounding = CopperBufferIndexGeometryH,

    // apply_lumped_rlc: the elements (CopperLumpedRLCCellGPU, grouped by the cell or Q16 tile they
    // land in), each element's ADE state (six floats), and the groups (CopperQExcitationBlockGPU, one
    // per cell or per (component, tile)). Excitation's slots: the two never run in one dispatch.
    // The state is read from LumpedState and written to LumpedStateOut -- the same memory, except
    // under COPPER_FUSED's ping-pong.
    CopperBufferIndexLumpedCells = CopperBufferIndexExcCells,
    CopperBufferIndexLumpedState = CopperBufferIndexExcSignal,
    CopperBufferIndexLumpedStateOut = CopperBufferIndexFusedLumpedStateOut,
    CopperBufferIndexLumpedGroups = CopperBufferIndexQBlocks,
};

enum CopperPsiFormat {
    CopperPsiFormatFloat = 0,
    CopperPsiFormatHalf = 1,
    CopperPsiFormatBFloat = 2,
    CopperPsiFormatBFloatStochastic = 3, // bfloat, stochastically rounded
    CopperPsiFormatTruncated = 4,        // float with its low psiDropBits cleared (precision study)
    CopperPsiFormatFixed = 5,            // fixed point: psiDropBits magnitude bits of LSB psiInverseScale (emulated)
    CopperPsiFormatBlock = 6,            // fixed point under a SIMD group's shared exponent (emulated)
    CopperPsiFormatFloat24 = 7,          // float's top 24 bits: a 16-bit array, then an 8-bit one
    CopperPsiFormatBlock16 = 8,          // int16 under an exponent byte per half SIMD group (block), stochastic
};

// Function constants specializing CopperFDTD.metal's kernels.
enum CopperFunctionConstant {
    // COPPER_FIELD_MIXED: tiles are individually Q16 or fp32 (see CopperFDTD.metal's QField).
    CopperFunctionConstantMixed = 0,
    // COPPER_FUSED: the fused E+H kernel applies voltage excitation and lumped RLC corrections itself.
    CopperFunctionConstantFusedCorrections = 1,
    // COPPER_CPML_PSI: how the CPML's psi is stored -- CopperPsiFormat (uint).
    CopperFunctionConstantPsiFormat = 2,
};

#endif /* CopperShaderTypes_h */
