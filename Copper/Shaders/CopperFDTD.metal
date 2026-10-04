// Interior Yee-grid leapfrog update kernels -- a direct GPU port of openEMS's own
// Engine::UpdateVoltages/UpdateCurrents (engine.cpp), cyclically permuted per axis. Every neighbor
// offset and boundary-safety trick below is copied verbatim from that source, not re-derived, so
// there's one place (this comment) documenting the correspondence rather than trusting it was
// transcribed correctly by eye:
//
//   update_e_interior <-> Engine::UpdateVoltages. Rectangular-domain callers dispatch the full
//   (nx,ny,nz) grid; irregular-board runs dispatch the non-overlapping active cuboids produced by
//   CopperDomain instead. Each kernel also comes in a _cpml and a _zcpml variant applying the CPML
//   along all three axes or Z alone (see computeE below). Coefficients come from a per-cell index
//   into a table of material terms times the mesh's separable geometry (see curlCoefficients() and
//   copper::CopperCoefficientTable). The lower-index neighbor in each curl term is guarded by
//   `shift = (pos != 0)`: at pos==0, shift is 0, so `pos - shift` reads the *same* cell instead of
//   underflowing -- and since both terms of that difference then read the identical value, they
//   cancel to exactly zero. That's not a special case bolted on top; it's openEMS's own boundary
//   treatment, baked into the same formula that runs everywhere else.
//
//   update_h_interior <-> Engine::UpdateCurrents, over the equivalent active subset of
//   (nx-1,ny-1,nz-1) (openEMS's
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

// Field storage is float or half (COPPER_FIELD_FP16); every load widens to float and all arithmetic
// is fp32 -- only the bytes in the E/H buffers are narrowed, on store.
template <typename P>
inline float ld(P field, uint32_t i) {
    return float(field[i]);
}

inline uint32_t copperIndex(constant CopperGridDimsGPU& dims, uint32_t x, uint32_t y, uint32_t z) {
    return x + dims.nx * (y + dims.ny * z);
}

// Where (x, y, z) of a field lives in its buffer. float/half fields are stored flat, exactly like
// the per-cell coefficient index; a QField is tiled (below).
template <typename P>
inline uint32_t fieldIndex(constant CopperGridDimsGPU& dims, P, uint32_t x, uint32_t y, uint32_t z) {
    return copperIndex(dims, x, y, z);
}

// COPPER_FIELD_Q16: block floating point over 4x4x1 tiles. Each tile's 16 cells are stored
// contiguously (tiles x-fastest, then y, then z; cells x-fastest within the tile) as a ushort n
// each, with one float (bias, scale) header per tile, decoding to scale * (n - bias) -- min +
// scale * n with min = -scale * bias, kept in this form so that whenever the tile's range spans zero,
// bias is a whole number and zero (every PEC and out-of-domain cell) decodes exactly. The grid is
// padded up to whole tiles in x and y; padding cells are never written or read. The n array comes
// first in the field's buffer, then the headers -- they can't have buffer slots of their own,
// Metal's argument table is full.
//
// COPPER_FIELD_MIXED (kMixed) adds an fp32 copy of every tile after the headers, and a per-tile
// format byte (QTileState) saying which copy is live: tiles holding the run's energetic fields are
// promoted to fp32 while they are, which is where nearly all of Q16's persistent error went in. A
// tile living in fp32 also has a negative scale in its header (a Q16 scale never is), so reads --
// which load the header anyway -- needn't also load the format byte.
constant bool kMixedValue [[function_constant(CopperFunctionConstantMixed)]];
constant bool kMixed = is_function_constant_defined(kMixedValue) && kMixedValue;

struct QField {
    device ushort* n;
    device float2* header;
};

inline uint32_t qTilesX(constant CopperGridDimsGPU& dims) { return (dims.nx + 3u) / 4u; }
inline uint32_t qTilesY(constant CopperGridDimsGPU& dims) { return (dims.ny + 3u) / 4u; }
inline uint32_t qTileCount(constant CopperGridDimsGPU& dims) { return qTilesX(dims) * qTilesY(dims) * dims.nz; }

// COPPER_FIELD_MIXED's per-tile state, one buffer for both sides: each side's all-time peak tile
// amplitude (as float bits, so atomic max works) and a plain snapshot of it, then per side a format
// byte (live copy), a request byte (what the last update asked for) and a pinned byte (set by the
// host: always fp32). Updates compare against the snapshot, which the retile kernel refreshes,
// rather than every tile atomically loading the one shared word every step.
struct QTileState {
    device atomic_uint* peak;
    device float* peakSnapshot;
    device uchar* format;
    device uchar* request;
    device const uchar* pinned;
};

inline QTileState qTileState(device uchar* base, constant CopperGridDimsGPU& dims, uint32_t side) {
    const uint32_t tiles = qTileCount(dims);
    return QTileState{reinterpret_cast<device atomic_uint*>(base) + side, reinterpret_cast<device float*>(base + 8u) + side,
                      base + 16u + side * tiles, base + 16u + (2u + side) * tiles, base + 16u + (4u + side) * tiles};
}

inline QField qField(device uchar* base, constant CopperGridDimsGPU& dims) {
    return QField{reinterpret_cast<device ushort*>(base), reinterpret_cast<device float2*>(base + 32u * qTileCount(dims))};
}

// COPPER_FIELD_MIXED: a field's fp32 copy, 40 bytes per tile into its buffer -- derived from the
// n/header pointers (32 bytes per tile apart) rather than carried in QField.
inline device float* qFloats(QField field) {
    device uchar* header = reinterpret_cast<device uchar*>(field.header);
    return reinterpret_cast<device float*>(header + (header - reinterpret_cast<device uchar*>(field.n)) / 4);
}

// COPPER_FIELD_MIXED: whether this side's tile is living in fp32 this step.
inline bool qIsFloat(device uchar* state, constant CopperGridDimsGPU& dims, uint32_t side, uint32_t tile) {
    return kMixed && qTileState(state, dims, side).format[tile] != 0;
}

// COPPER_FIELD_MIXED: whether any tile within one tile of this one (on either side) lives in fp32 --
// every tile an update of this one can read from, the fused kernel's halo included. Kept per tile
// after the formats, refreshed by q_near_float after every retile.
inline device uchar* qNearFloatBytes(device uchar* state, constant CopperGridDimsGPU& dims) {
    return state + 16u + 6u * qTileCount(dims);
}
inline bool qNearFloat(device uchar* state, constant CopperGridDimsGPU& dims, uint32_t tile) {
    return kMixed && qNearFloatBytes(state, dims)[tile] != 0;
}

inline uint32_t fieldIndex(constant CopperGridDimsGPU& dims, QField, uint32_t x, uint32_t y, uint32_t z) {
    const uint32_t tile = (x >> 2) + qTilesX(dims) * ((y >> 2) + qTilesY(dims) * z);
    return tile * 16u + (y & 3u) * 4u + (x & 3u);
}

inline float qDecode(QField field, uint32_t i) {
    const float2 h = field.header[i >> 4];
    return h.y * (float(field.n[i]) - h.x);
}

// The header COPPER_FIELD_MIXED gives a tile living in fp32.
constant float2 kFloatTileHeader = float2(0.0f, -1.0f);

inline float ld(QField field, uint32_t i) {
    const float2 h = field.header[i >> 4];
    if (kMixed && h.y < 0.0f) return qFloats(field)[i];
    return h.y * (float(field.n[i]) - h.x);
}

// A QField known to be all-Q16 wherever it's read: COPPER_FIELD_MIXED's fast path. The fp32 branch
// in ld(QField) -- though almost never taken -- costs ~25% of a step at ten-odd reads per update, so
// the update kernels test once per tile (qNearFloat) and run with these when nothing nearby is fp32.
struct QFieldQ {
    QField field;
};

inline float ld(QFieldQ q, uint32_t i) { return qDecode(q.field, i); }

inline uint32_t fieldIndex(constant CopperGridDimsGPU& dims, QFieldQ q, uint32_t x, uint32_t y, uint32_t z) {
    return fieldIndex(dims, q.field, x, y, z);
}

// One thread of a Q16 kernel: 16 consecutive threads (half a SIMD group) cover one listed tile.
struct QCell {
    uint32_t tile, lane, x, y, z, index; // index = fieldIndex(...) = tile * 16 + lane
    bool valid;                          // false for the tile's padding cells past nx/ny
};

inline QCell qCell(constant CopperGridDimsGPU& dims, uint32_t tile, uint gid) {
    QCell cell;
    cell.tile = tile;
    cell.lane = gid & 15u;
    const uint32_t tilesX = qTilesX(dims), tilesY = qTilesY(dims);
    cell.x = (tile % tilesX) * 4u + (cell.lane & 3u);
    cell.y = ((tile / tilesX) % tilesY) * 4u + (cell.lane >> 2);
    cell.z = tile / (tilesX * tilesY);
    cell.index = tile * 16u + cell.lane;
    cell.valid = cell.x < dims.nx && cell.y < dims.ny;
    return cell;
}

// Min/max across the 16 lanes of this thread's tile (half of the SIMD group).
inline float qTileMin(float value) {
    for (ushort offset = 8; offset > 0; offset >>= 1) value = min(value, simd_shuffle_xor(value, offset));
    return value;
}
inline float qTileMax(float value) {
    for (ushort offset = 8; offset > 0; offset >>= 1) value = max(value, simd_shuffle_xor(value, offset));
    return value;
}

// Uniform in [0, 1) from a hash of (a, b, c) -- the dither for stochastic rounding.
inline float qDither(uint32_t a, uint32_t b, uint32_t c) {
    uint32_t h = a * 0x9E3779B1u ^ (b + 0x7F4A7C15u) * 0x85EBCA77u ^ c * 0xC2B2AE3Du;
    h ^= h >> 15;
    h *= 0x2C1B3C6Du;
    h ^= h >> 12;
    h *= 0x297A2D39u;
    h ^= h >> 15;
    return float(h >> 8) * 0x1p-24f;
}

// Encodes one tile as Q16: each of its 16 lanes holds one cell's new value. Every lane of the tile
// must call this -- it's a reduction over the tile's half of the SIMD group. Stochastic rounding
// (COPPER_Q16_ROUND=stochastic) dithers each store; zero stays exact either way, since bias is then
// whole and the dither under 1. `component` decorrelates a cell's three stores.
inline void qEncode(QField field, QCell cell, float value, constant CopperQRoundingGPU& rounding,
                    uint32_t component) {
    const float lo = qTileMin(cell.valid ? value : INFINITY);
    const float hi = qTileMax(cell.valid ? value : -INFINITY);
    // 65534 steps, not 65535: rounding bias up to a whole number can stretch the range by one.
    // A constant tile still needs a nonzero scale to represent its value. A tile spanning less
    // than 2^-110 (the far tail of a wavefront) is flushed to zero: its scale would be subnormal.
    // Metal flushes that to zero anyway, but the CPU encoder (CopperEngine.mm's qEncodeTile, behind
    // writeFieldCell) doesn't -- there 1/scale was infinite and the bias 0 * inf = NaN -- so both
    // sides flush at the same threshold and encode identically.
    const float span = hi > lo ? hi - lo : abs(hi);
    const float scale = span >= 0x1p-110f ? span * (1.0f / 65534.0f) : 0.0f;
    const float inverse = scale > 0.0f ? 1.0f / scale : 0.0f;
    const float bias = (lo <= 0.0f && hi >= 0.0f) ? ceil(-lo * inverse) : -lo * inverse;
    if (cell.valid) {
        const float position = value * inverse + bias;
        const float n = rounding.stochastic ? floor(position + qDither(cell.index, rounding.seed, component))
                                            : rint(position);
        field.n[cell.index] = ushort(clamp(n, 0.0f, 65535.0f));
    }
    if (cell.lane == 0) {
        field.header[cell.tile] = float2(bias, scale);
    }
}

// Stores one tile in whichever form is live for it (`isFloat`, from qIsFloat). Every lane of the
// tile must call this; the format is the same for all of them, so the branch is uniform.
inline void qStore(QField field, QCell cell, float value, constant CopperQRoundingGPU& rounding,
                   uint32_t component, bool isFloat) {
    if (kMixed && isFloat) {
        if (cell.valid) qFloats(field)[cell.index] = value;
        if (cell.lane == 0) field.header[cell.tile] = kFloatTileHeader;
        return;
    }
    qEncode(field, cell, value, rounding, component);
}

// COPPER_FIELD_MIXED: records whether this tile wants fp32, from the peak amplitude `amplitude` of
// its freshly updated cells (reduced across the tile by the caller; every lane passes the same
// value, lane 0 writes). The side's all-time peak only ever rises, so an atomic max is needed only
// on the rare stores that raise it past the snapshot.
inline void qRequest(QTileState state, QCell cell, float amplitude, constant CopperQRoundingGPU& rounding) {
    if (cell.lane != 0) return;
    float peak = *state.peakSnapshot;
    if (amplitude > peak) {
        atomic_fetch_max_explicit(state.peak, as_type<uint>(amplitude), memory_order_relaxed);
        peak = amplitude;
    }
    const bool promoted = state.format[cell.tile] != 0;
    const bool want = amplitude > 0.0f && amplitude >= peak * (promoted ? rounding.demote : rounding.promote);
    state.request[cell.tile] = want ? 1 : 0;
}

// vi (E kernels) or iv (H kernels) of all three components at (x, y, z): the cell's table entry's
// material terms times the mesh's separable geometry -- component n's own spacing times the
// reciprocal spacing across it along the other two axes (see copper::CopperCoefficientTable).
inline float3 curlCoefficients(constant CopperGridDimsGPU& dims, device const float* geometry,
                               thread const CopperMaterialCoefficientsGPU& c, uint32_t x, uint32_t y, uint32_t z) {
    const uint32_t yOffset = dims.nx, zOffset = dims.nx + dims.ny, inverse = dims.nx + dims.ny + dims.nz;
    const float ownX = geometry[x], ownY = geometry[yOffset + y], ownZ = geometry[zOffset + z];
    const float invX = geometry[inverse + x], invY = geometry[inverse + yOffset + y],
                invZ = geometry[inverse + zOffset + z];
    return float3(c.material[0] * ownX * invY * invZ, c.material[1] * ownY * invZ * invX,
                  c.material[2] * ownZ * invX * invY);
}

// COPPER_CPML_PSI: psi is stored as float (default), as half scaled by cpml.psiScale, or as bfloat --
// rounded to nearest, or stochastically. Round to nearest stagnates: where b is close to 1, a step's
// change to psi is often under half an ulp, so it is lost every step and psi freezes off zero. The
// stochastic form adds a dither below the kept 16 bits before truncating, so on average every change
// survives -- as long as the dither is fresh every step (hashed from the cell and cpml.seed). Hashed
// from the value instead, rounding is a fixed function of it, and b * psi can round straight back to
// psi forever, just as with round to nearest.
constant uint kPsiFormatValue [[function_constant(CopperFunctionConstantPsiFormat)]];
constant uint kPsiFormat = is_function_constant_defined(kPsiFormatValue) ? kPsiFormatValue : 0u;

// COPPER_CPML_PSI=blk16: which block a lane's psi belongs to -- half a SIMD group, whose lanes share
// an exponent per term. A Q16 tile, or 16 x-aligned cells of a rectangular domain's row.
struct CPMLBlock {
    uint32_t index;
    bool upper; // the upper 16 lanes of the SIMD group
};

// Block16's shared exponent for term `term` of `block`: values are below 2^exponent.
inline device uchar* psiExponent(device float* psi, constant CopperCPMLGPU& cpml, CPMLBlock block, uint32_t term) {
    return reinterpret_cast<device uchar*>(psi) + 2u * cpml.psiTotal + term * cpml.psiBlocks + block.index;
}

inline float psiLoad(device float* psi, uint32_t i, constant CopperCPMLGPU& cpml, CPMLBlock block, uint32_t term) {
    if (kPsiFormat == CopperPsiFormatHalf) return float(reinterpret_cast<device half*>(psi)[i]) * cpml.psiInverseScale;
    if (kPsiFormat == CopperPsiFormatBlock16) {
        const int exponent = int(*psiExponent(psi, cpml, block, term)) - 128;
        return float(reinterpret_cast<device short*>(psi)[i]) * ldexp(1.0f, exponent - 15);
    }
    if (kPsiFormat == CopperPsiFormatFloat24) {
        const uint32_t hi = reinterpret_cast<device ushort*>(psi)[i];
        const uint32_t lo = reinterpret_cast<device uchar*>(psi)[2u * cpml.psiTotal + i];
        return as_type<float>((hi << 16) | (lo << 8));
    }
    if (kPsiFormat == CopperPsiFormatBFloat || kPsiFormat == CopperPsiFormatBFloatStochastic) {
        return float(reinterpret_cast<device bfloat*>(psi)[i]);
    }
    return psi[i];
}

// A dither for psi element i, fresh every step and side (cpml.seed).
inline uint32_t psiDither(uint32_t i, constant CopperCPMLGPU& cpml) {
    uint32_t h = (i * 0x9E3779B1u) ^ (cpml.seed * 0x85EBCA77u);
    h ^= h >> 15;
    h *= 0x2C1B3C6Du;
    h ^= h >> 13;
    h *= 0xC2B2AE3Du;
    h ^= h >> 16;
    return h;
}

inline void psiStore(device float* psi, uint32_t i, float value, constant CopperCPMLGPU& cpml, CPMLBlock block,
                     uint32_t term) {
    if (kPsiFormat == CopperPsiFormatBlock16) {
        // The block's largest |psi| over its active lanes (the other half's lanes count as 0).
        const float magnitude = abs(value);
        const float lowMax = simd_max(block.upper ? 0.0f : magnitude);
        const float highMax = simd_max(block.upper ? magnitude : 0.0f);
        const float blockMax = block.upper ? highMax : lowMax;
        int exponent = -128;
        if (blockMax > 0.0f) frexp(blockMax, exponent); // blockMax < 2^exponent
        exponent = clamp(exponent, -128, 127);
        const float q = value * ldexp(1.0f, 15 - exponent);
        const float n = floor(q + float(psiDither(i, cpml) >> 8) * 0x1p-24f);
        reinterpret_cast<device short*>(psi)[i] = short(clamp(n, -32767.0f, 32767.0f));
        *psiExponent(psi, cpml, block, term) = uchar(exponent + 128); // every lane of the block writes the same
        return;
    }
    if (kPsiFormat == CopperPsiFormatHalf) {
        reinterpret_cast<device half*>(psi)[i] = half(value * cpml.psiScale);
    } else if (kPsiFormat == CopperPsiFormatBFloat) {
        reinterpret_cast<device bfloat*>(psi)[i] = bfloat(value);
    } else if (kPsiFormat == CopperPsiFormatBFloatStochastic || kPsiFormat == CopperPsiFormatTruncated ||
               kPsiFormat == CopperPsiFormatFloat24) {
        // Sign-magnitude, so adding the dither to the magnitude's low bits rounds either sign alike.
        const uint32_t bits = as_type<uint32_t>(value);
        const uint32_t h = psiDither(i, cpml);
        if (kPsiFormat == CopperPsiFormatBFloatStochastic) {
            reinterpret_cast<device ushort*>(psi)[i] = ushort((bits + (h & 0xFFFFu)) >> 16);
        } else if (kPsiFormat == CopperPsiFormatFloat24) {
            const uint32_t rounded = (bits + (cpml.psiStochastic ? (h & 0xFFu) : 0x80u)) & ~0xFFu;
            reinterpret_cast<device ushort*>(psi)[i] = ushort(rounded >> 16);
            reinterpret_cast<device uchar*>(psi)[2u * cpml.psiTotal + i] = uchar(rounded >> 8);
        } else {
            const uint32_t mask = (1u << cpml.psiDropBits) - 1u;
            const uint32_t round = cpml.psiStochastic ? (h & mask) : (mask >> 1) + 1u;
            psi[i] = cpml.psiDropBits == 0 ? value : as_type<float>((bits + round) & ~mask);
        }
    } else if (kPsiFormat == CopperPsiFormatFixed || kPsiFormat == CopperPsiFormatBlock) {
        // Emulated in float storage: value as a whole number of LSBs, |n| < 2^psiDropBits. Fixed has
        // one LSB per side; Block an LSB under the exponent of the largest value across the SIMD
        // group's lanes storing the same term.
        float lsb = cpml.psiInverseScale;
        if (kPsiFormat == CopperPsiFormatBlock) {
            const float blockMax = simd_max(abs(value));
            int exponent = 0;
            frexp(blockMax, exponent); // blockMax < 2^exponent
            lsb = blockMax > 0.0f ? ldexp(1.0f, exponent - int(cpml.psiDropBits)) : 1.0f;
        }
        const float limit = ldexp(1.0f, int(cpml.psiDropBits)) - 1.0f;
        const float q = value / lsb;
        const float n = cpml.psiStochastic ? floor(q + float(psiDither(i, cpml) >> 8) * 0x1p-24f) : rint(q);
        psi[i] = clamp(n, -limit, limit) * lsb;
    } else {
        psi[i] = value;
    }
}

// The CPML (real CFS-PML, Roden & Gedney 2000; copper::CopperCPML) -- a direct port of Taflove &
// Hagness, *Computational Electrodynamics* 3rd ed., eq. (7.101)/(7.105)/(7.106) for E and eq.
// (7.101)/(7.110)/(7.108) for H, read from the actual text (see CopperCPML.hpp's top comment). It
// never replaces a field value, only adds to the curl term the update already formed, scaled by
// the same host-medium vi/iv and driven by the same raw curl differences (same shift guard
// included), so psi's units stay consistent with the ordinary update by construction.
//
// cpmlAxis applies it along one axis W: if this cell lies in W's slabs, it advances the psi of the
// two components transverse to W (eq. 7.101) and adds each to `sum`, which collects psi0 - psi1 per
// component. t0/t1 are each component's two curl differences as the update forms them (first,
// added; second, subtracted): component n's first is driven along axis (n+1)%3 and its second along
// (n+2)%3, so W drives component (W+1)%3's second and component (W+2)%3's first.
template <uint W, bool kH>
inline void cpmlAxis(uint3 pos, constant CopperGridDimsGPU& dims, device const CopperCPMLLineGPU* lines,
                     constant CopperCPMLGPU& cpml, device float* psi, float3 t0, float3 t1, thread float3& sum,
                     CPMLBlock block) {
    constexpr uint A = (W + 1) % 3, B = (W + 2) % 3;
    const uint32_t lineBase = W == 0 ? 0u : (W == 1 ? dims.nx : dims.nx + dims.ny);
    const CopperCPMLLineGPU line = lines[lineBase + pos[W]];
    if (line.layer == kCopperCPMLNoLayer) return;
    const uint32_t p = W == 0   ? line.layer + cpml.layers[0] * (pos.y + dims.ny * pos.z)
                       : W == 1 ? pos.x + dims.nx * (line.layer + cpml.layers[1] * pos.z)
                                : pos.x + dims.nx * (pos.y + dims.ny * line.layer);
    const float b = kH ? line.bH : line.bE, c = kH ? line.cH : line.cE;
    const uint32_t iA = cpml.psiOffset[W] + p, iB = iA + cpml.psiCount[W];
    const float a = b * psiLoad(psi, iA, cpml, block, 2 * W) + c * t1[A];
    const float bb = b * psiLoad(psi, iB, cpml, block, 2 * W + 1) + c * t0[B];
    psiStore(psi, iA, a, cpml, block, 2 * W);
    psiStore(psi, iB, bb, cpml, block, 2 * W + 1);
    sum[A] -= a;
    sum[B] += bb;
}

// psi0 - psi1 for all three components, over the axes in kAxes (bit w for axis w). The axes run in
// order x, y, z, so each component's sum rounds exactly as psi0 - psi1 would.
template <uint kAxes, bool kH>
inline float3 cpmlTerms(uint3 pos, constant CopperGridDimsGPU& dims, device const CopperCPMLLineGPU* lines,
                        constant CopperCPMLGPU& cpml, device float* psi, float3 t0, float3 t1, CPMLBlock block) {
    float3 sum = 0.0f;
    if (kAxes & 1u) cpmlAxis<0, kH>(pos, dims, lines, cpml, psi, t0, t1, sum, block);
    if (kAxes & 2u) cpmlAxis<1, kH>(pos, dims, lines, cpml, psi, t0, t1, sum, block);
    if (kAxes & 4u) cpmlAxis<2, kH>(pos, dims, lines, cpml, psi, t0, t1, sum, block);
    return sum;
}

// update_e_interior's body. kCPML -- bit w for axis w -- folds the CPML along those axes into the
// update (cpmlTerms): 0 outside any CPML, 4 for an irregular domain's Z slabs, 7 for a rectangular
// domain's six faces. It needs only curl differences the update already reads, so it costs each
// graded cell its psi read-modify-writes and nothing more: no second pass over the CPML.
template <uint kCPML, typename Index, typename FE, typename FH>
inline float3 computeE(uint3 gid, constant CopperGridDimsGPU& dims, FE Ex, FE Ey, FE Ez, FH Hx, FH Hy, FH Hz,
                       device const Index* materialIndex, device const CopperMaterialCoefficientsGPU* table,
                       device const float* geometry, device const CopperCPMLLineGPU* lines,
                       constant CopperCPMLGPU* cpml, device float* psi, CPMLBlock block) {
    const uint32_t x = gid.x, y = gid.y, z = gid.z;
    const uint32_t sx = (x != 0) ? 1 : 0;
    const uint32_t sy = (y != 0) ? 1 : 0;
    const uint32_t sz = (z != 0) ? 1 : 0;
    const uint32_t idx = copperIndex(dims, x, y, z); // into materialIndex; f/xM1/yM1/zM1 into the fields
    const uint32_t f = fieldIndex(dims, Hx, x, y, z);
    const uint32_t xM1 = fieldIndex(dims, Hx, x - sx, y, z);
    const uint32_t yM1 = fieldIndex(dims, Hx, x, y - sy, z);
    const uint32_t zM1 = fieldIndex(dims, Hx, x, y, z - sz);
    const CopperMaterialCoefficientsGPU c = table[materialIndex[idx]];
    const float3 vi = curlCoefficients(dims, geometry, c, x, y, z);

    // Ex: curl term is (Hz - Hz[y-1] - Hy + Hy[z-1]).
    float ex = c.decay[0] * ld(Ex, f) + vi.x * (ld(Hz, f) - ld(Hz, yM1) - ld(Hy, f) + ld(Hy, zM1));
    // Ey: curl term is (Hx - Hx[z-1] - Hz + Hz[x-1]).
    float ey = c.decay[1] * ld(Ey, f) + vi.y * (ld(Hx, f) - ld(Hx, zM1) - ld(Hz, f) + ld(Hz, xM1));
    // Ez: curl term is (Hy - Hy[x-1] - Hx + Hx[y-1]).
    float ez = c.decay[2] * ld(Ez, f) + vi.z * (ld(Hy, f) - ld(Hy, xM1) - ld(Hx, f) + ld(Hx, yM1));

    if (kCPML != 0) {
        const float3 t0(ld(Hz, f) - ld(Hz, yM1), ld(Hx, f) - ld(Hx, zM1), ld(Hy, f) - ld(Hy, xM1));
        const float3 t1(ld(Hy, f) - ld(Hy, zM1), ld(Hz, f) - ld(Hz, xM1), ld(Hx, f) - ld(Hx, yM1));
        const float3 terms = cpmlTerms<kCPML, false>(gid, dims, lines, *cpml, psi, t0, t1, block);
        // A component's terms come from the two axes other than its own.
        if (kCPML & 6u) ex += vi.x * terms.x;
        if (kCPML & 5u) ey += vi.y * terms.y;
        if (kCPML & 3u) ez += vi.z * terms.z;
    }

    return float3(ex, ey, ez);
}

template <uint kCPML, typename Index, typename F>
inline void updateE(uint3 gid, constant CopperGridDimsGPU& dims, device F* Ex, device F* Ey,
                    device F* Ez, device const F* Hx, device const F* Hy, device const F* Hz,
                    device const Index* materialIndex, device const CopperMaterialCoefficientsGPU* table,
                    device const float* geometry, device const CopperCPMLLineGPU* lines,
                    constant CopperCPMLGPU* cpml, device float* psi) {
    if (gid.x >= dims.nx || gid.y >= dims.ny || gid.z >= dims.nz) {
        return;
    }
    // Block16: 16 x-aligned cells of a row (a rectangular domain's threadgroups start at x = 0).
    const CPMLBlock block{gid.x / 16u + (dims.nx + 15u) / 16u * (gid.y + dims.ny * gid.z), ((gid.x >> 4) & 1u) != 0};
    const float3 e = computeE<kCPML>(gid, dims, Ex, Ey, Ez, Hx, Hy, Hz, materialIndex, table, geometry, lines,
                                     cpml, psi, block);
    const uint32_t idx = copperIndex(dims, gid.x, gid.y, gid.z);
    Ex[idx] = F(e.x);
    Ey[idx] = F(e.y);
    Ez[idx] = F(e.z);
}

// update_h_interior's body, with the CPML folded in exactly like computeE above.
template <uint kCPML, typename Index, typename FE, typename FH>
inline float3 computeH(uint3 gid, constant CopperGridDimsGPU& dims, FE Ex, FE Ey, FE Ez, FH Hx, FH Hy, FH Hz,
                       device const Index* materialIndex, device const CopperMaterialCoefficientsGPU* table,
                       device const float* geometry, device const CopperCPMLLineGPU* lines,
                       constant CopperCPMLGPU* cpml, device float* psi, CPMLBlock block) {
    const uint32_t x = gid.x, y = gid.y, z = gid.z;
    const uint32_t idx = copperIndex(dims, x, y, z); // into materialIndex; f/xP1/yP1/zP1 into the fields
    const uint32_t f = fieldIndex(dims, Ex, x, y, z);
    const uint32_t xP1 = fieldIndex(dims, Ex, x + 1, y, z);
    const uint32_t yP1 = fieldIndex(dims, Ex, x, y + 1, z);
    const uint32_t zP1 = fieldIndex(dims, Ex, x, y, z + 1);
    const CopperMaterialCoefficientsGPU c = table[materialIndex[idx]];
    const float3 iv = curlCoefficients(dims, geometry, c, x, y, z);

    // Hx: curl term is (Ez - Ez[y+1] - Ey + Ey[z+1]).
    float hx = c.decay[0] * ld(Hx, f) + iv.x * (ld(Ez, f) - ld(Ez, yP1) - ld(Ey, f) + ld(Ey, zP1));
    // Hy: curl term is (Ex - Ex[z+1] - Ez + Ez[x+1]).
    float hy = c.decay[1] * ld(Hy, f) + iv.y * (ld(Ex, f) - ld(Ex, zP1) - ld(Ez, f) + ld(Ez, xP1));
    // Hz: curl term is (Ey - Ey[x+1] - Ex + Ex[y+1]).
    float hz = c.decay[2] * ld(Hz, f) + iv.z * (ld(Ey, f) - ld(Ey, xP1) - ld(Ex, f) + ld(Ex, yP1));

    if (kCPML != 0) {
        const float3 t0(ld(Ez, f) - ld(Ez, yP1), ld(Ex, f) - ld(Ex, zP1), ld(Ey, f) - ld(Ey, xP1));
        const float3 t1(ld(Ey, f) - ld(Ey, zP1), ld(Ez, f) - ld(Ez, xP1), ld(Ex, f) - ld(Ex, yP1));
        const float3 terms = cpmlTerms<kCPML, true>(gid, dims, lines, *cpml, psi, t0, t1, block);
        if (kCPML & 6u) hx += iv.x * terms.x;
        if (kCPML & 5u) hy += iv.y * terms.y;
        if (kCPML & 3u) hz += iv.z * terms.z;
    }

    return float3(hx, hy, hz);
}

template <uint kCPML, typename Index, typename F>
inline void updateH(uint3 gid, constant CopperGridDimsGPU& dims, device const F* Ex, device const F* Ey,
                    device const F* Ez, device F* Hx, device F* Hy, device F* Hz,
                    device const Index* materialIndex, device const CopperMaterialCoefficientsGPU* table,
                    device const float* geometry, device const CopperCPMLLineGPU* lines,
                    constant CopperCPMLGPU* cpml, device float* psi) {
    // Dispatched over exactly (nx-1, ny-1, nz-1) -- every pos+1 read below is guaranteed in bounds
    // by that dispatch size alone; this guard is defensive belt-and-suspenders, not load-bearing.
    if (gid.x + 1 >= dims.nx || gid.y + 1 >= dims.ny || gid.z + 1 >= dims.nz) {
        return;
    }
    // Block16: 16 x-aligned cells of a row (a rectangular domain's threadgroups start at x = 0).
    const CPMLBlock block{gid.x / 16u + (dims.nx + 15u) / 16u * (gid.y + dims.ny * gid.z), ((gid.x >> 4) & 1u) != 0};
    const float3 h = computeH<kCPML>(gid, dims, Ex, Ey, Ez, Hx, Hy, Hz, materialIndex, table, geometry, lines,
                                     cpml, psi, block);
    const uint32_t idx = copperIndex(dims, gid.x, gid.y, gid.z);
    Hx[idx] = F(h.x);
    Hy[idx] = F(h.y);
    Hz[idx] = F(h.z);
}

// The COPPER_FIELD_Q16 update: 16 threads per listed tile (see CopperQBlockGPU), so a tile is owned
// by half a SIMD group outright, which can re-encode it. Cells of the tile outside the active domain
// just carry their decoded value through. Under COPPER_FIELD_MIXED it also records whether the tile
// wants fp32 (qRequest).
template <bool kH, uint kCPML, typename Index>
inline void updateQ(uint gid, constant CopperGridDimsGPU& dims, QField Ex, QField Ey, QField Ez, QField Hx,
                    QField Hy, QField Hz, QField out0, QField out1, QField out2, device const Index* materialIndex,
                    device const CopperMaterialCoefficientsGPU* table, device const float* geometry,
                    device const CopperCPMLLineGPU* lines, constant CopperCPMLGPU* cpml, device float* psi,
                    device const CopperQBlockGPU* blocks, constant CopperQRoundingGPU& rounding,
                    device uchar* tileState) {
    const CopperQBlockGPU block = blocks[gid >> 4];
    const QCell cell = qCell(dims, block.block, gid);
    const QField in0 = kH ? Hx : Ex, in1 = kH ? Hy : Ey, in2 = kH ? Hz : Ez;
    float3 value = 0.0f;
    if (cell.valid && ((block.mask >> cell.lane) & 1u)) {
        const uint3 pos(cell.x, cell.y, cell.z);
        const CPMLBlock cpmlBlock{cell.tile, ((gid >> 4) & 1u) != 0}; // Block16: a tile
        if (qNearFloat(tileState, dims, cell.tile)) {
            value = kH ? computeH<kCPML>(pos, dims, Ex, Ey, Ez, Hx, Hy, Hz, materialIndex, table, geometry, lines,
                                         cpml, psi, cpmlBlock)
                       : computeE<kCPML>(pos, dims, Ex, Ey, Ez, Hx, Hy, Hz, materialIndex, table, geometry, lines,
                                         cpml, psi, cpmlBlock);
        } else {
            const QFieldQ ex{Ex}, ey{Ey}, ez{Ez}, hx{Hx}, hy{Hy}, hz{Hz};
            value = kH ? computeH<kCPML>(pos, dims, ex, ey, ez, hx, hy, hz, materialIndex, table, geometry, lines,
                                         cpml, psi, cpmlBlock)
                       : computeE<kCPML>(pos, dims, ex, ey, ez, hx, hy, hz, materialIndex, table, geometry, lines,
                                         cpml, psi, cpmlBlock);
        }
    } else if (cell.valid) {
        value = float3(ld(in0, cell.index), ld(in1, cell.index), ld(in2, cell.index));
    }
    if (kMixed) {
        const float3 magnitude = abs(value);
        const float amplitude = qTileMax(cell.valid ? max(magnitude.x, max(magnitude.y, magnitude.z)) : 0.0f);
        qRequest(qTileState(tileState, dims, kH ? 1u : 0u), cell, amplitude, rounding);
    }
    const bool isFloat = qIsFloat(tileState, dims, kH ? 1u : 0u, cell.tile);
    qStore(out0, cell, value.x, rounding, 0u, isFloat);
    qStore(out1, cell, value.y, rounding, 1u, isFloat);
    qStore(out2, cell, value.z, rounding, 2u, isFloat);
}

// SERIES lumped RLC: the ADE update CopperFDTDRunner's CPU correction used to apply between the E
// and H updates (Engine_Ext_LumpedRLC::Apply2VoltagesImpl's SERIES branch), on one element. Takes
// the element's freshly updated cell voltage and returns the corrected one. The element's state --
// its last three vdn then its last three jn -- is read from `state` and, if `commit`, the advanced
// state written to `stateOut` (the same memory but under COPPER_FUSED's ping-pong, where the fused
// kernel's halo lanes compute a neighbour's corrected E from the old state while its owner may
// already be writing the new one).
inline float lumpedRLCStep(constant CopperLumpedRLCCellGPU& element, float voltage, device const float* state,
                           device float* stateOut, bool commit) {
    const float vdn0Old = state[0], vdn1Old = state[1], jn0Old = state[3], jn1Old = state[4];
    const float vdn2 = vdn1Old, jn1 = jn0Old, jn2 = jn1Old; // after the history shift
    const float vdn0 = element.vvd * (voltage + element.vv2 * vdn2 + element.vj1 * jn1 + element.vj2 * jn2);
    if (commit) {
        const float jn0 =
            element.ib0 * (vdn0 - vdn2) - element.b1 * element.ib0 * jn1 - element.b2 * element.ib0 * jn2;
        stateOut[0] = vdn0;
        stateOut[1] = vdn0Old;
        stateOut[2] = vdn1Old;
        stateOut[3] = jn0;
        stateOut[4] = jn0Old;
        stateOut[5] = jn1Old;
    }
    return vdn0;
}

// One excitation cell's contribution this step -- applyExcitationCell's exc_pos formula.
inline float excitationSample(constant CopperExcitationCellGPU& cell, device const float* signal,
                              constant CopperExcitationParamsGPU& params) {
    int32_t excPos = params.numTS - int32_t(cell.delaySteps);
    excPos *= (excPos > 0);
    excPos %= params.period;
    excPos *= (excPos < int32_t(params.signalLength));
    return cell.amplitude * signal[uint32_t(excPos)];
}

// COPPER_FUSED with E corrections (the default; COPPER_FUSED_CORRECTIONS=0 compiles them out and
// leaves excitation and lumped tiles to the separate kernels).
constant bool kFusedCorrectionsValue [[function_constant(CopperFunctionConstantFusedCorrections)]];
constant bool kFusedCorrections = is_function_constant_defined(kFusedCorrectionsValue) && kFusedCorrectionsValue;

// The fused kernel's view of the E corrections (see CopperFusedCorrectionGPU).
struct FusedCorrections {
    constant CopperExcitationCellGPU* excitationCells;
    device const float* signal;
    constant CopperExcitationParamsGPU* params;
    constant CopperLumpedRLCCellGPU* lumpedCells;
    device const float* lumpedState;
    device float* lumpedStateOut;
    device const CopperFusedCorrectionGPU* corrections;
    device const uint32_t* offsets;
};

// Applies every correction landing on cell (x, y, z) to its new E, in the separate kernels' order:
// excitation, then lumped RLC. Only the cell's owner (`owner`) advances lumped state. Returns
// whether any excitation landed here.
inline bool applyFusedCorrections(constant CopperGridDimsGPU& dims, thread const FusedCorrections& fc, uint32_t x,
                                  uint32_t y, uint32_t z, bool owner, thread float3& e) {
    const uint32_t tile = (x >> 2) + qTilesX(dims) * ((y >> 2) + qTilesY(dims) * z);
    const uint32_t cellLane = (y & 3u) * 4u + (x & 3u);
    bool excited = false;
    for (uint32_t i = fc.offsets[tile]; i < fc.offsets[tile + 1u]; ++i) {
        const CopperFusedCorrectionGPU correction = fc.corrections[i];
        if (correction.lane != cellLane) continue;
        if (correction.kind == 0u) {
            e[correction.axis] += excitationSample(fc.excitationCells[correction.index], fc.signal, *fc.params);
            excited = true;
        } else {
            const uint32_t element = correction.index;
            e[correction.axis] = lumpedRLCStep(fc.lumpedCells[element], e[correction.axis],
                                               fc.lumpedState + 6u * element, fc.lumpedStateOut + 6u * element,
                                               owner);
        }
    }
    return excited;
}

// COPPER_FUSED: one timestep's E and H updates in a single pass. A threadgroup of 288 threads owns
// a segment of a 16x16-cell column (a 4x4 block of tiles, CopperQSegmentGPU) and marches down it a
// plane at a time. Threads 0-255 are the footprint's cells, 16 per tile so a tile is still half a
// SIMD group; threads 256-271 are the column just past it in +x and 272-287 the row just past it in
// +y -- cells of neighbouring footprints whose new E the footprint's H update needs, so they compute
// it too (and discard it). Per plane:
//   1. every thread publishes its own old H(z) to threadgroup memory: its +x/+y neighbours' E
//      updates need it as their x-1/y-1 term, so only the footprint's -x/-y edge reads that from
//      memory;
//   2. every thread computes its new E(z) -- own H(z) and H(z-1) both from registers: H(z-1) is
//      loaded once, here, and becomes the next plane's own H;
//   3. new E is published, and the footprint's H(z) is updated from its own E, its +x/+y
//      neighbours' (threadgroup memory) and the plane above's (a register from the previous plane).
// Each field is read once and written once per step, against twice each for the separate kernels;
// reads come from one buffer set and writes go to the other (ping-pong), since a neighbouring group
// may already have written its new values. Only tiles marked in the segment's ownedMask are stored --
// those whose cells and halo need no correction between the E and H updates the kernel can't make
// (CPML, current excitation, CPU corrections); the rest of the footprint computes E only as halo
// for them, and runs the separate kernels. With kFusedCorrections voltage excitation and lumped RLC
// are applied here.
constant uint32_t kFusedThreads = 288;

// fusedEH's E update -- computeE's arithmetic exactly, with the H terms passed in rather than read.
template <typename IE, typename FE>
inline float3 fusedComputeE(constant CopperGridDimsGPU& dims, uint32_t x, uint32_t y, uint32_t z, FE Ex, FE Ey,
                            FE Ez, float3 h, float3 hXm1, float3 hYm1, float3 hZm1, device const IE* indexE,
                            device const CopperMaterialCoefficientsGPU* tableE, device const float* geometryE) {
    const uint32_t f = fieldIndex(dims, Ex, x, y, z);
    const CopperMaterialCoefficientsGPU c = tableE[indexE[copperIndex(dims, x, y, z)]];
    const float3 vi = curlCoefficients(dims, geometryE, c, x, y, z);
    // Ex: (Hz - Hz[y-1] - Hy + Hy[z-1]); Ey: (Hx - Hx[z-1] - Hz + Hz[x-1]); Ez: (Hy - Hy[x-1] - Hx + Hx[y-1]).
    return float3(c.decay[0] * ld(Ex, f) + vi.x * (h.z - hYm1.z - h.y + hZm1.y),
                  c.decay[1] * ld(Ey, f) + vi.y * (h.x - hZm1.x - h.z + hXm1.z),
                  c.decay[2] * ld(Ez, f) + vi.z * (h.y - hXm1.y - h.x + hYm1.x));
}

// The three H components at field index i, through the fast all-Q16 path unless fp32 tiles are near.
inline float3 fusedLoadH(QField Hx, QField Hy, QField Hz, uint32_t i, bool nearFloat) {
    return nearFloat ? float3(ld(Hx, i), ld(Hy, i), ld(Hz, i)) : float3(qDecode(Hx, i), qDecode(Hy, i), qDecode(Hz, i));
}

// Threadgroup slot of footprint cell (lx, ly): tile-major, 16 cells per tile, x-fastest within it.
inline uint32_t fusedSlot(uint32_t lx, uint32_t ly) {
    return ((lx >> 2) + 4u * (ly >> 2)) * 16u + (ly & 3u) * 4u + (lx & 3u);
}

template <typename IE, typename IH>
inline void fusedEH(uint segmentIndex, uint t, constant CopperGridDimsGPU& dims, QField Ex, QField Ey, QField Ez,
                    QField Hx, QField Hy, QField Hz, QField outEx, QField outEy, QField outEz, QField outHx,
                    QField outHy, QField outHz, device const IE* indexE,
                    device const CopperMaterialCoefficientsGPU* tableE, device const float* geometryE,
                    device const IH* indexH, device const CopperMaterialCoefficientsGPU* tableH,
                    device const float* geometryH, device const CopperQSegmentGPU* segments,
                    constant CopperQRoundingGPU& rounding, device uchar* tileState, thread const FusedCorrections& fc,
                    threadgroup float3* sharedH, threadgroup float3* sharedE) {
    const CopperQSegmentGPU segment = segments[segmentIndex];
    const uint32_t x0 = segment.tileX * 4u, y0 = segment.tileY * 4u;
    // This thread's cell (lx, ly relative to the footprint), and where its x-1/y-1 neighbours'
    // H(z) and its x+1/y+1 neighbours' new E(z) are published (~0u: not published, read memory).
    uint32_t lx, ly, fromXm1 = ~0u, fromYm1 = ~0u, fromXp1 = ~0u, fromYp1 = ~0u;
    const bool footprint = t < 256u;
    if (footprint) {
        const uint32_t tileLocal = t >> 4, lane = t & 15u;
        lx = (tileLocal & 3u) * 4u + (lane & 3u);
        ly = (tileLocal >> 2) * 4u + (lane >> 2);
        if (lx > 0u) fromXm1 = fusedSlot(lx - 1u, ly);
        if (ly > 0u) fromYm1 = fusedSlot(lx, ly - 1u);
        fromXp1 = lx < 15u ? fusedSlot(lx + 1u, ly) : 256u + ly;
        fromYp1 = ly < 15u ? fusedSlot(lx, ly + 1u) : 272u + lx;
    } else if (t < 272u) {
        lx = 16u;
        ly = t - 256u;
        fromXm1 = fusedSlot(15u, ly);
        if (ly > 0u) fromYm1 = t - 1u;
    } else {
        lx = t - 272u;
        ly = 16u;
        if (lx > 0u) fromXm1 = t - 1u;
        fromYm1 = fusedSlot(lx, 15u);
    }
    const uint32_t x = x0 + lx, y = y0 + ly;
    const bool active = x < dims.nx && y < dims.ny;
    const uint32_t tileLocal = t >> 4;
    const bool owned = footprint && ((segment.ownedMask >> tileLocal) & 1u) != 0u;
    const uint32_t tilesX = qTilesX(dims), tilesPerPlane = tilesX * qTilesY(dims);
    const uint32_t columnTile = (x >> 2) + tilesX * (y >> 2); // this cell's tile, plane 0

    // A segment ending below the top of the grid starts on the plane just above it, computing only
    // that plane's E for its own H -- the plane belongs to another segment and isn't stored.
    const uint32_t top = segment.z1 < dims.nz ? segment.z1 : segment.z1 - 1u;
    float3 hCur = 0.0f, eAbove = 0.0f;
    if (active) hCur = fusedLoadH(Hx, Hy, Hz, fieldIndex(dims, Hx, x, y, top), true);

    for (uint32_t z = top + 1u; z-- > segment.z0;) {
        const bool haloPlane = z == segment.z1;
        const bool nearFloat = active && qNearFloat(tileState, dims, columnTile + tilesPerPlane * z);

        // 1. Publish own old H(z) for the neighbours' x-1/y-1 terms.
        sharedH[t] = hCur;
        threadgroup_barrier(mem_flags::mem_threadgroup);

        // 2. New E(z). H(z-1) is loaded once here and carried down as the next plane's own H.
        float3 e = 0.0f, hBelow = hCur;
        bool excited = false;
        if (active) {
            if (z > 0u) hBelow = fusedLoadH(Hx, Hy, Hz, fieldIndex(dims, Hx, x, y, z - 1u), nearFloat);
            // Below plane 0 and left of x/y = 0 the update reads its own cell (computeE's shift trick).
            float3 hXm1 = hCur, hYm1 = hCur;
            if (x > 0u) {
                hXm1 = fromXm1 != ~0u ? sharedH[fromXm1]
                                      : fusedLoadH(Hx, Hy, Hz, fieldIndex(dims, Hx, x - 1u, y, z), nearFloat);
            }
            if (y > 0u) {
                hYm1 = fromYm1 != ~0u ? sharedH[fromYm1]
                                      : fusedLoadH(Hx, Hy, Hz, fieldIndex(dims, Hx, x, y - 1u, z), nearFloat);
            }
            if (!haloPlane || footprint) {
                if (nearFloat) {
                    e = fusedComputeE(dims, x, y, z, Ex, Ey, Ez, hCur, hXm1, hYm1, hBelow, indexE, tableE, geometryE);
                } else {
                    e = fusedComputeE(dims, x, y, z, QFieldQ{Ex}, QFieldQ{Ey}, QFieldQ{Ez}, hCur, hXm1, hYm1, hBelow,
                                      indexE, tableE, geometryE);
                }
                if (kFusedCorrections) excited = applyFusedCorrections(dims, fc, x, y, z, owned && !haloPlane, e);
            }
        }

        // 3. Publish new E(z); the footprint's H(z) needs its +x/+y neighbours'.
        sharedE[t] = e;
        threadgroup_barrier(mem_flags::mem_threadgroup);
        if (!haloPlane && owned) {
            const uint32_t lane = t & 15u;
            QCell cell;
            cell.tile = columnTile + tilesPerPlane * z;
            cell.lane = lane;
            cell.x = x;
            cell.y = y;
            cell.z = z;
            cell.index = cell.tile * 16u + lane;
            cell.valid = active;
            float3 h = hCur;
            // update_h_interior's extent: H on the last plane of each axis isn't updated.
            if (active && x + 1u < dims.nx && y + 1u < dims.ny && z + 1u < dims.nz) {
                const float3 eX1 = sharedE[fromXp1], eY1 = sharedE[fromYp1];
                const CopperMaterialCoefficientsGPU c = tableH[indexH[copperIndex(dims, x, y, z)]];
                const float3 iv = curlCoefficients(dims, geometryH, c, x, y, z);
                // computeH's curl terms, with the new E from registers and threadgroup memory.
                h = float3(c.decay[0] * hCur.x + iv.x * (e.z - eY1.z - e.y + eAbove.y),
                           c.decay[1] * hCur.y + iv.y * (e.x - eAbove.x - e.z + eX1.z),
                           c.decay[2] * hCur.z + iv.z * (e.y - eX1.y - e.x + eY1.x));
            }
            if (kMixed) {
                const float3 me = abs(e), mh = abs(h);
                const float amplitudeE = qTileMax(active ? max(me.x, max(me.y, me.z)) : 0.0f);
                const float amplitudeH = qTileMax(active ? max(mh.x, max(mh.y, mh.z)) : 0.0f);
                qRequest(qTileState(tileState, dims, 0u), cell, amplitudeE, rounding);
                qRequest(qTileState(tileState, dims, 1u), cell, amplitudeH, rounding);
                // As apply_excitation_e_q16 does: a tile being driven stays fp32 while the signal runs.
                if (kFusedCorrections && qTileMax(excited ? 1.0f : 0.0f) > 0.0f && lane == 0u &&
                    fc.params->numTS < int32_t(fc.params->signalLength)) {
                    qTileState(tileState, dims, 0u).request[cell.tile] = 1;
                }
            }
            const bool floatE = qIsFloat(tileState, dims, 0u, cell.tile);
            const bool floatH = qIsFloat(tileState, dims, 1u, cell.tile);
            qStore(outEx, cell, e.x, rounding, 0u, floatE);
            qStore(outEy, cell, e.y, rounding, 1u, floatE);
            qStore(outEz, cell, e.z, rounding, 2u, floatE);
            qStore(outHx, cell, h.x, rounding, 0u, floatH);
            qStore(outHy, cell, h.y, rounding, 1u, floatH);
            qStore(outHz, cell, h.z, rounding, 2u, floatH);
        }
        eAbove = e;
        hCur = hBelow;
    }
}

} // namespace

// Kernel entry points. Each comes in a _u16 and a _u32 variant, for a coefficient table whose
// per-cell indices fit in 16 bits (every board so far) or need 32, and each of those in an _f16
// variant storing E/H as half (COPPER_FIELD_FP16 -- see ld() above).
#define COPPER_FIELD_ARGS(FIELD, E_ACCESS, H_ACCESS)                                                           \
    constant CopperGridDimsGPU &dims [[buffer(CopperBufferIndexDims)]],                                 \
        device E_ACCESS FIELD *Ex [[buffer(CopperBufferIndexEx)]],                                      \
        device E_ACCESS FIELD *Ey [[buffer(CopperBufferIndexEy)]],                                      \
        device E_ACCESS FIELD *Ez [[buffer(CopperBufferIndexEz)]],                                      \
        device H_ACCESS FIELD *Hx [[buffer(CopperBufferIndexHx)]],                                      \
        device H_ACCESS FIELD *Hy [[buffer(CopperBufferIndexHy)]],                                      \
        device H_ACCESS FIELD *Hz [[buffer(CopperBufferIndexHz)]]

#define COPPER_COEFFICIENT_ARGS(INDEX)                                                                  \
    device const INDEX *materialIndex [[buffer(CopperBufferIndexMaterialIndex)]],                       \
        device const CopperMaterialCoefficientsGPU *table [[buffer(CopperBufferIndexMaterialTable)]],   \
        device const float *geometry [[buffer(CopperBufferIndexGeometry)]]

#define COPPER_ORIGIN_ARGS                                                                              \
    constant CopperDispatchOriginGPU &origin [[buffer(CopperBufferIndexDispatchOrigin)]],               \
        uint3 gid [[thread_position_in_grid]]

#define COPPER_CPML_ARGS                                                                                \
    device const CopperCPMLLineGPU *lines [[buffer(CopperBufferIndexCPMLLines)]],                       \
        constant CopperCPMLGPU *cpml [[buffer(CopperBufferIndexCPMLLayout)]],                           \
        device float *psi [[buffer(CopperBufferIndexCPMLPsi)]]

// One update kernel per CPML variant: none, all three axes (_cpml) and Z alone (_zcpml).
#define COPPER_UPDATE_KERNELS(NAME, UPDATE, E_ACCESS, H_ACCESS, SUFFIX, INDEX, FIELD)                          \
    kernel void NAME##SUFFIX(COPPER_FIELD_ARGS(FIELD, E_ACCESS, H_ACCESS), COPPER_COEFFICIENT_ARGS(INDEX),     \
                             COPPER_ORIGIN_ARGS) {                                                      \
        UPDATE<0u, INDEX, FIELD>(gid + uint3(origin.x, origin.y, origin.z), dims, Ex, Ey, Ez, Hx, Hy, Hz,       \
                                 materialIndex, table, geometry, nullptr, nullptr, nullptr);            \
    }                                                                                                   \
    kernel void NAME##_cpml##SUFFIX(COPPER_FIELD_ARGS(FIELD, E_ACCESS, H_ACCESS), COPPER_COEFFICIENT_ARGS(INDEX), \
                                    COPPER_ORIGIN_ARGS, COPPER_CPML_ARGS) {                             \
        UPDATE<7u, INDEX, FIELD>(gid + uint3(origin.x, origin.y, origin.z), dims, Ex, Ey, Ez, Hx, Hy, Hz,       \
                                 materialIndex, table, geometry, lines, cpml, psi);                     \
    }                                                                                                   \
    kernel void NAME##_zcpml##SUFFIX(COPPER_FIELD_ARGS(FIELD, E_ACCESS, H_ACCESS), COPPER_COEFFICIENT_ARGS(INDEX), \
                                     COPPER_ORIGIN_ARGS, COPPER_CPML_ARGS) {                            \
        UPDATE<4u, INDEX, FIELD>(gid + uint3(origin.x, origin.y, origin.z), dims, Ex, Ey, Ez, Hx, Hy, Hz,       \
                                 materialIndex, table, geometry, lines, cpml, psi);                     \
    }

#define COPPER_KERNELS(SUFFIX, INDEX, FIELD)                                                            \
    COPPER_UPDATE_KERNELS(update_e_interior, updateE, , const, SUFFIX, INDEX, FIELD)                    \
    COPPER_UPDATE_KERNELS(update_h_interior, updateH, const, , SUFFIX, INDEX, FIELD)

COPPER_KERNELS(_u16, ushort, float)
COPPER_KERNELS(_u32, uint, float)
COPPER_KERNELS(_u16_f16, ushort, half)
COPPER_KERNELS(_u32_f16, uint, half)

#define COPPER_Q_FIELD_ARGS                                                                             \
    constant CopperGridDimsGPU &dims [[buffer(CopperBufferIndexDims)]],                                 \
        device uchar *ExBase [[buffer(CopperBufferIndexEx)]], device uchar *EyBase [[buffer(CopperBufferIndexEy)]], \
        device uchar *EzBase [[buffer(CopperBufferIndexEz)]], device uchar *HxBase [[buffer(CopperBufferIndexHx)]], \
        device uchar *HyBase [[buffer(CopperBufferIndexHy)]], device uchar *HzBase [[buffer(CopperBufferIndexHz)]], \
        device const CopperQBlockGPU *blocks [[buffer(CopperBufferIndexQBlocks)]],                       \
        constant CopperQRoundingGPU &rounding [[buffer(CopperBufferIndexQRounding)]],                    \
        device uchar *tileState [[buffer(CopperBufferIndexQTileState)]],                                 \
        device uchar *OutXBase [[buffer(CopperBufferIndexOutX)]],                                        \
        device uchar *OutYBase [[buffer(CopperBufferIndexOutY)]],                                        \
        device uchar *OutZBase [[buffer(CopperBufferIndexOutZ)]],                                        \
        uint gid [[thread_position_in_grid]]

#define COPPER_Q_FIELDS                                                                                 \
    qField(ExBase, dims), qField(EyBase, dims),                           \
        qField(EzBase, dims), qField(HxBase, dims),                       \
        qField(HyBase, dims), qField(HzBase, dims)

// The side a Q16 update kernel writes (SIDE 0 for E, 1 for H).
#define COPPER_Q_OUT_FIELDS(SIDE)                                                                       \
    qField(OutXBase, dims), qField(OutYBase, dims),                   \
        qField(OutZBase, dims)

#define COPPER_Q_KERNEL_VARIANT(NAME, H, CPML, SUFFIX, INDEX)                                          \
    kernel void NAME##SUFFIX(COPPER_Q_FIELD_ARGS, COPPER_COEFFICIENT_ARGS(INDEX), COPPER_CPML_ARGS) {   \
        updateQ<H, CPML, INDEX>(gid, dims, COPPER_Q_FIELDS, COPPER_Q_OUT_FIELDS(H ? 1u : 0u), materialIndex, table, \
                                geometry, lines, cpml, psi, blocks, rounding, tileState);               \
    }

#define COPPER_Q_KERNEL(NAME, H, SUFFIX, INDEX)                                                         \
    kernel void NAME##SUFFIX(COPPER_Q_FIELD_ARGS, COPPER_COEFFICIENT_ARGS(INDEX)) {                     \
        updateQ<H, 0u, INDEX>(gid, dims, COPPER_Q_FIELDS, COPPER_Q_OUT_FIELDS(H ? 1u : 0u), materialIndex, table, \
                              geometry, nullptr, nullptr, nullptr, blocks, rounding, tileState);        \
    }                                                                                                   \
    COPPER_Q_KERNEL_VARIANT(NAME##_cpml, H, 7u, SUFFIX, INDEX)                                          \
    COPPER_Q_KERNEL_VARIANT(NAME##_zcpml, H, 4u, SUFFIX, INDEX)

COPPER_Q_KERNEL(update_e_interior, false, _u16_q16, ushort)
COPPER_Q_KERNEL(update_e_interior, false, _u32_q16, uint)
COPPER_Q_KERNEL(update_h_interior, true, _u16_q16, ushort)
COPPER_Q_KERNEL(update_h_interior, true, _u32_q16, uint)

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

template <typename F>
inline void applyExcitationCell(constant CopperGridDimsGPU& dims, device F* field0, device F* field1,
                                 device F* field2, constant CopperExcitationCellGPU* cells,
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
        field0[idx] = F(float(field0[idx]) + value);
    } else if (cell.axis == 1) {
        field1[idx] = F(float(field1[idx]) + value);
    } else {
        field2[idx] = F(float(field2[idx]) + value);
    }
}

#define COPPER_EXCITATION_KERNEL(NAME, FIELD, F0, F1, F2)                                              \
    kernel void NAME(constant CopperGridDimsGPU &dims [[buffer(CopperBufferIndexDims)]],                \
                     device FIELD *field0 [[buffer(CopperBufferIndex##F0)]],                            \
                     device FIELD *field1 [[buffer(CopperBufferIndex##F1)]],                            \
                     device FIELD *field2 [[buffer(CopperBufferIndex##F2)]],                            \
                     constant CopperExcitationCellGPU *cells [[buffer(CopperBufferIndexExcCells)]],     \
                     device const float *signal [[buffer(CopperBufferIndexExcSignal)]],                 \
                     constant CopperExcitationParamsGPU &params [[buffer(CopperBufferIndexExcParams)]], \
                     uint tid [[thread_position_in_grid]]) {                                            \
        applyExcitationCell(dims, field0, field1, field2, cells, signal, params, tid);                  \
    }

COPPER_EXCITATION_KERNEL(apply_excitation_e, float, Ex, Ey, Ez)
COPPER_EXCITATION_KERNEL(apply_excitation_h, float, Hx, Hy, Hz)
COPPER_EXCITATION_KERNEL(apply_excitation_e_f16, half, Ex, Ey, Ez)
COPPER_EXCITATION_KERNEL(apply_excitation_h_f16, half, Hx, Hy, Hz)

// COPPER_FIELD_Q16's excitation: 16 threads per excited tile of one component (see
// CopperQExcitationBlockGPU), adding every excitation cell that lands in it before re-encoding.
inline void applyExcitationQ(constant CopperGridDimsGPU& dims, QField field0, QField field1, QField field2,
                             device const CopperQExcitationBlockGPU* blocks, constant CopperExcitationCellGPU* cells,
                             device const float* signal, constant CopperExcitationParamsGPU& params,
                             constant CopperQRoundingGPU& rounding, QTileState state, uint gid) {
    const CopperQExcitationBlockGPU block = blocks[gid >> 4];
    const QCell cell = qCell(dims, block.block, gid);
    const QField field = block.axis == 0 ? field0 : (block.axis == 1 ? field1 : field2);
    float value = cell.valid ? ld(field, cell.index) : 0.0f;
    for (uint32_t i = block.first; i < block.first + block.count; ++i) {
        const CopperExcitationCellGPU excited = cells[i];
        if (excited.x != cell.x || excited.y != cell.y || excited.z != cell.z) continue;
        int32_t excPos = params.numTS - int32_t(excited.delaySteps);
        excPos *= (excPos > 0);
        excPos %= params.period;
        excPos *= (excPos < int32_t(params.signalLength));
        value += excited.amplitude * signal[uint32_t(excPos)];
    }
    qStore(field, cell, value, rounding, block.axis, kMixed && state.format[cell.tile] != 0);
    // COPPER_FIELD_MIXED: a tile being driven stays fp32 for as long as the signal runs.
    if (kMixed && cell.lane == 0 && params.numTS < int32_t(params.signalLength)) state.request[cell.tile] = 1;
}

#define COPPER_Q_EXCITATION_KERNEL(NAME, F0, F1, F2, SIDE)                                              \
    kernel void NAME(constant CopperGridDimsGPU &dims [[buffer(CopperBufferIndexDims)]],                \
                     device uchar *base0 [[buffer(CopperBufferIndex##F0)]],                             \
                     device uchar *base1 [[buffer(CopperBufferIndex##F1)]],                             \
                     device uchar *base2 [[buffer(CopperBufferIndex##F2)]],                             \
                     device const CopperQExcitationBlockGPU *blocks [[buffer(CopperBufferIndexQBlocks)]], \
                     constant CopperExcitationCellGPU *cells [[buffer(CopperBufferIndexExcCells)]],     \
                     device const float *signal [[buffer(CopperBufferIndexExcSignal)]],                 \
                     constant CopperExcitationParamsGPU &params [[buffer(CopperBufferIndexExcParams)]], \
                     constant CopperQRoundingGPU &rounding [[buffer(CopperBufferIndexQExcitationRounding)]], \
                     device uchar *tileState [[buffer(CopperBufferIndexQTileState)]],                   \
                     uint gid [[thread_position_in_grid]]) {                                            \
        applyExcitationQ(dims, qField(base0, dims), qField(base1, dims), \
                         qField(base2, dims), blocks, cells, signal, params, rounding, \
                         qTileState(tileState, dims, SIDE), gid);                                       \
    }

COPPER_Q_EXCITATION_KERNEL(apply_excitation_e_q16, Ex, Ey, Ez, 0u)
COPPER_Q_EXCITATION_KERNEL(apply_excitation_h_q16, Hx, Hy, Hz, 1u)

// COPPER_FIELD_MIXED: brings every tile of one side to the format it wants -- the last update's
// request, or fp32 if the host pinned it -- converting just the tiles that change. 16 threads per
// tile over the whole grid; the format byte only changes here, between stages.
inline void retileQ(constant CopperGridDimsGPU& dims, QField field0, QField field1, QField field2,
                    QTileState state, constant CopperQRoundingGPU& rounding, uint gid) {
    const QCell cell = qCell(dims, gid >> 4, gid);
    if (gid == 0) *state.peakSnapshot = as_type<float>(atomic_load_explicit(state.peak, memory_order_relaxed));
    const uchar live = state.format[cell.tile];
    const uchar want = (state.request[cell.tile] | state.pinned[cell.tile]) != 0 ? 1 : 0;
    if (live == want) return; // uniform across the tile
    const QField fields[3] = {field0, field1, field2};
    for (uint32_t component = 0; component < 3; ++component) {
        const QField field = fields[component];
        if (want != 0) {
            if (cell.valid) qFloats(field)[cell.index] = qDecode(field, cell.index);
            simdgroup_barrier(mem_flags::mem_device); // every lane has decoded before the header changes
            if (cell.lane == 0) field.header[cell.tile] = kFloatTileHeader;
        } else {
            qEncode(field, cell, cell.valid ? qFloats(field)[cell.index] : 0.0f, rounding, component);
        }
    }
    if (cell.lane == 0) state.format[cell.tile] = want;
}

// COPPER_FIELD_MIXED: after a retile, marks each tile with whether any tile within one of it (on
// either side) lives in fp32 -- see qNearFloat. One thread per tile.
kernel void q_near_float_q16(constant CopperGridDimsGPU& dims [[buffer(CopperBufferIndexDims)]],
                             device uchar* tileState [[buffer(CopperBufferIndexQTileState)]],
                             uint tile [[thread_position_in_grid]]) {
    const uint32_t tilesX = qTilesX(dims), tilesY = qTilesY(dims);
    if (tile >= tilesX * tilesY * dims.nz) return;
    const int32_t tx = int32_t(tile % tilesX), ty = int32_t((tile / tilesX) % tilesY), tz = int32_t(tile / (tilesX * tilesY));
    device const uchar* formatE = qTileState(tileState, dims, 0u).format;
    device const uchar* formatH = qTileState(tileState, dims, 1u).format;
    uchar near = 0;
    for (int32_t dz = -1; dz <= 1; ++dz) {
        for (int32_t dy = -1; dy <= 1; ++dy) {
            for (int32_t dx = -1; dx <= 1; ++dx) {
                const int32_t x = tx + dx, y = ty + dy, z = tz + dz;
                if (x < 0 || y < 0 || z < 0 || x >= int32_t(tilesX) || y >= int32_t(tilesY) || z >= int32_t(dims.nz)) {
                    continue;
                }
                const uint32_t neighbour = uint32_t(x) + tilesX * (uint32_t(y) + tilesY * uint32_t(z));
                near |= formatE[neighbour] | formatH[neighbour];
            }
        }
    }
    qNearFloatBytes(tileState, dims)[tile] = near;
}

#define COPPER_Q_RETILE_KERNEL(NAME, F0, F1, F2, SIDE)                                                  \
    kernel void NAME(constant CopperGridDimsGPU &dims [[buffer(CopperBufferIndexDims)]],                \
                     device uchar *base0 [[buffer(CopperBufferIndex##F0)]],                             \
                     device uchar *base1 [[buffer(CopperBufferIndex##F1)]],                             \
                     device uchar *base2 [[buffer(CopperBufferIndex##F2)]],                             \
                     constant CopperQRoundingGPU &rounding [[buffer(CopperBufferIndexQRounding)]],      \
                     device uchar *tileState [[buffer(CopperBufferIndexQTileState)]],                   \
                     uint gid [[thread_position_in_grid]]) {                                            \
        retileQ(dims, qField(base0, dims), qField(base1, dims),       \
                qField(base2, dims), qTileState(tileState, dims, SIDE), rounding, gid); \
    }

COPPER_Q_RETILE_KERNEL(q_retile_e_q16, Ex, Ey, Ez, 0u)
COPPER_Q_RETILE_KERNEL(q_retile_h_q16, Hx, Hy, Hz, 1u)

#define COPPER_FUSED_KERNEL(SUFFIX, IE, IH)                                                             \
    kernel void fused_eh##SUFFIX(                                                                       \
        constant CopperGridDimsGPU &dims [[buffer(CopperBufferIndexDims)]],                             \
        device uchar *ExBase [[buffer(CopperBufferIndexEx)]], device uchar *EyBase [[buffer(CopperBufferIndexEy)]], \
        device uchar *EzBase [[buffer(CopperBufferIndexEz)]], device uchar *HxBase [[buffer(CopperBufferIndexHx)]], \
        device uchar *HyBase [[buffer(CopperBufferIndexHy)]], device uchar *HzBase [[buffer(CopperBufferIndexHz)]], \
        device uchar *OutXBase [[buffer(CopperBufferIndexOutX)]],                                       \
        device uchar *OutYBase [[buffer(CopperBufferIndexOutY)]],                                       \
        device uchar *OutZBase [[buffer(CopperBufferIndexOutZ)]],                                       \
        device uchar *OutHxBase [[buffer(CopperBufferIndexOutHx)]],                                     \
        device uchar *OutHyBase [[buffer(CopperBufferIndexOutHy)]],                                     \
        device uchar *OutHzBase [[buffer(CopperBufferIndexOutHz)]],                                     \
        device const IE *indexE [[buffer(CopperBufferIndexMaterialIndex)]],                             \
        device const CopperMaterialCoefficientsGPU *tableE [[buffer(CopperBufferIndexMaterialTable)]],  \
        device const float *geometryE [[buffer(CopperBufferIndexGeometry)]],                            \
        device const IH *indexH [[buffer(CopperBufferIndexMaterialIndexH)]],                            \
        device const CopperMaterialCoefficientsGPU *tableH [[buffer(CopperBufferIndexMaterialTableH)]], \
        device const float *geometryH [[buffer(CopperBufferIndexGeometryH)]],                           \
        device const CopperQSegmentGPU *segments [[buffer(CopperBufferIndexQBlocks)]],                  \
        constant CopperQRoundingGPU &rounding [[buffer(CopperBufferIndexFusedRounding)]],               \
        device uchar *tileState [[buffer(CopperBufferIndexQTileState)]],                                \
        constant CopperExcitationCellGPU *excitationCells [[buffer(CopperBufferIndexExcCells)]],        \
        device const float *signal [[buffer(CopperBufferIndexExcSignal)]],                              \
        constant CopperExcitationParamsGPU &params [[buffer(CopperBufferIndexExcParams)]],              \
        constant CopperLumpedRLCCellGPU *lumpedCells [[buffer(CopperBufferIndexFusedLumpedCells)]],     \
        device const float *lumpedState [[buffer(CopperBufferIndexFusedLumpedState)]],                  \
        device float *lumpedStateOut [[buffer(CopperBufferIndexFusedLumpedStateOut)]],                  \
        device const CopperFusedCorrectionGPU *corrections [[buffer(CopperBufferIndexFusedCorrections)]], \
        device const uint32_t *correctionOffsets [[buffer(CopperBufferIndexFusedCorrectionOffsets)]],   \
        uint segmentIndex [[threadgroup_position_in_grid]], uint t [[thread_index_in_threadgroup]]) {   \
        const FusedCorrections fc{excitationCells, signal, &params, lumpedCells, lumpedState, lumpedStateOut, \
                                  corrections, correctionOffsets};                                      \
        threadgroup float3 sharedH[kFusedThreads], sharedE[kFusedThreads];                              \
        fusedEH<IE, IH>(segmentIndex, t, dims, COPPER_Q_FIELDS, COPPER_Q_OUT_FIELDS(0u),                            \
                        qField(OutHxBase, dims), qField(OutHyBase, dims), \
                        qField(OutHzBase, dims), indexE, tableE, geometryE, indexH, tableH, \
                        geometryH, segments, rounding, tileState, fc, sharedH, sharedE);                \
    }

COPPER_FUSED_KERNEL(_u16_u16_q16, ushort, ushort)
COPPER_FUSED_KERNEL(_u16_u32_q16, ushort, uint)
COPPER_FUSED_KERNEL(_u32_u16_q16, uint, ushort)
COPPER_FUSED_KERNEL(_u32_u32_q16, uint, uint)

// One thread per corrected cell (`block` its flat index): its elements, in order, as the CPU did.
template <typename F>
inline void applyLumpedCell(device F* field0, device F* field1, device F* field2,
                            constant CopperLumpedRLCCellGPU* elements, device const float* state,
                            device float* stateOut, device const CopperQExcitationBlockGPU* groups, uint gid) {
    const CopperQExcitationBlockGPU group = groups[gid];
    device F* field = group.axis == 0 ? field0 : (group.axis == 1 ? field1 : field2);
    float value = float(field[group.block]);
    for (uint32_t i = group.first; i < group.first + group.count; ++i) {
        value = lumpedRLCStep(elements[i], value, state + 6u * i, stateOut + 6u * i, true);
    }
    field[group.block] = F(value);
}

#define COPPER_LUMPED_KERNEL(NAME, FIELD)                                                               \
    kernel void NAME(device FIELD *Ex [[buffer(CopperBufferIndexEx)]],                                  \
                     device FIELD *Ey [[buffer(CopperBufferIndexEy)]],                                  \
                     device FIELD *Ez [[buffer(CopperBufferIndexEz)]],                                  \
                     constant CopperLumpedRLCCellGPU *elements [[buffer(CopperBufferIndexLumpedCells)]], \
                     device const float *state [[buffer(CopperBufferIndexLumpedState)]],                \
                     device float *stateOut [[buffer(CopperBufferIndexLumpedStateOut)]],                \
                     device const CopperQExcitationBlockGPU *groups [[buffer(CopperBufferIndexLumpedGroups)]], \
                     uint gid [[thread_position_in_grid]]) {                                            \
        applyLumpedCell(Ex, Ey, Ez, elements, state, stateOut, groups, gid);                            \
    }

COPPER_LUMPED_KERNEL(apply_lumped_rlc, float)
COPPER_LUMPED_KERNEL(apply_lumped_rlc_f16, half)

// Q16: 16 threads per (component, tile) group, like the Q16 excitation kernel.
kernel void apply_lumped_rlc_q16(constant CopperGridDimsGPU& dims [[buffer(CopperBufferIndexDims)]],
                                 device uchar* base0 [[buffer(CopperBufferIndexEx)]],
                                 device uchar* base1 [[buffer(CopperBufferIndexEy)]],
                                 device uchar* base2 [[buffer(CopperBufferIndexEz)]],
                                 constant CopperLumpedRLCCellGPU* elements [[buffer(CopperBufferIndexLumpedCells)]],
                                 device const float* state [[buffer(CopperBufferIndexLumpedState)]],
                                 device float* stateOut [[buffer(CopperBufferIndexLumpedStateOut)]],
                                 device const CopperQExcitationBlockGPU* groups [[buffer(CopperBufferIndexLumpedGroups)]],
                                 constant CopperQRoundingGPU& rounding [[buffer(CopperBufferIndexQExcitationRounding)]],
                                 device uchar* tileState [[buffer(CopperBufferIndexQTileState)]],
                                 uint gid [[thread_position_in_grid]]) {
    const CopperQExcitationBlockGPU group = groups[gid >> 4];
    const QCell cell = qCell(dims, group.block, gid);
    const QField field = qField(group.axis == 0 ? base0 : (group.axis == 1 ? base1 : base2), dims);
    float value = cell.valid ? ld(field, cell.index) : 0.0f;
    for (uint32_t i = group.first; i < group.first + group.count; ++i) {
        const constant CopperLumpedRLCCellGPU& element = elements[i];
        if (element.x != cell.x || element.y != cell.y || element.z != cell.z) continue;
        value = lumpedRLCStep(element, value, state + 6u * i, stateOut + 6u * i, true);
    }
    qStore(field, cell, value, rounding, group.axis, qIsFloat(tileState, dims, 0u, cell.tile));
}
