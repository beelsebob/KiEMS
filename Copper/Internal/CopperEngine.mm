#include "CopperEngineBackend.hpp"

#include <algorithm>
#include <array>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <filesystem>
#include <limits>
#include <set>
#include <stdexcept>
#include <string>

#import <Accelerate/Accelerate.h>
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

#include "../Shaders/CopperShaderTypes.h"

#include "CopperCoefficientTable.hpp"
#include "CopperPhysicalConstants.hpp"

namespace copper {

namespace {

// Anchors +[NSBundle bundleForClass:] at Copper's own framework bundle, not the main app's --
// needed since this file is compiled *into* Copper.framework, so its shader library
// (CopperFDTD.metal, compiled into Copper's own default .metallib) lives there too, not wherever
// the eventual host app's bundle is.
} // namespace

} // namespace copper

@interface CopperEngineBundleAnchor : NSObject
@end
@implementation CopperEngineBundleAnchor
@end

namespace copper {

namespace {

id<MTLBuffer> makeZeroedBuffer(id<MTLDevice> device, std::size_t count, std::size_t elementSize = sizeof(float)) {
    id<MTLBuffer> buffer = [device newBufferWithLength:count * elementSize options:MTLResourceStorageModeShared];
    if (buffer == nil) {
        throw std::runtime_error("CopperEngine: failed to allocate a field buffer");
    }
    std::memset(buffer.contents, 0, count * elementSize);
    return buffer;
}

// COPPER_FIELD_Q16 layout (see CopperFDTD.metal's QField): 4x4x1 tiles, x-fastest, each 16
// ushorts (x-fastest within the tile), padded to whole tiles in x and y; then a float (bias, scale)
// header per tile.
struct QTiling {
    std::size_t tilesX = 0, tilesY = 0, tileCount = 0;
    QTiling() = default;
    explicit QTiling(const CopperGridDims& dims)
        : tilesX((dims.nx + 3) / 4), tilesY((dims.ny + 3) / 4), tileCount(tilesX * tilesY * dims.nz) {}
    std::size_t tile(std::size_t x, std::size_t y, std::size_t z) const { return x / 4 + tilesX * (y / 4 + tilesY * z); }
    static std::uint32_t lane(std::size_t x, std::size_t y) { return static_cast<std::uint32_t>((y % 4) * 4 + x % 4); }
};

struct QFieldView {
    QTiling tiling;
    std::uint16_t* n;
    float* header;               // bias, scale interleaved
    float* f = nullptr;          // COPPER_FIELD_MIXED: the fp32 copy of every tile
    const std::uint8_t* format = nullptr; // COPPER_FIELD_MIXED: per tile, 1 when the fp32 copy is live
    bool isFloat(std::size_t tile) const { return format != nullptr && format[tile] != 0; }
    float getStored(std::size_t i) const {
        if (isFloat(i / 16)) return f[i];
        return header[2 * (i / 16) + 1] * (static_cast<float>(n[i]) - header[2 * (i / 16)]);
    }
    float get(std::size_t x, std::size_t y, std::size_t z) const {
        return getStored(tiling.tile(x, y, z) * 16 + QTiling::lane(x, y));
    }
};

// COPPER_FIELD_MIXED's per-tile state buffer (see CopperFDTD.metal's QTileState): two uint peaks and
// their snapshots, then per tile the E and H format bytes, request bytes and pinned bytes, and a
// near-fp32 byte (qNearFloat).
struct QTileStateView {
    std::uint8_t* base = nullptr;
    std::size_t tileCount = 0;
    std::uint8_t* format(int side) const { return base + 16 + static_cast<std::size_t>(side) * tileCount; }
    std::uint8_t* pinned(int side) const { return base + 16 + static_cast<std::size_t>(4 + side) * tileCount; }
};

QFieldView qView(id<MTLBuffer> buffer, const CopperGridDims& dims, const QTileStateView& state = {}, int side = 0) {
    const QTiling tiling(dims);
    auto* base = static_cast<std::uint8_t*>(buffer.contents);
    QFieldView view{tiling, reinterpret_cast<std::uint16_t*>(base), reinterpret_cast<float*>(base + 32 * tiling.tileCount)};
    if (state.base != nullptr) {
        view.f = reinterpret_cast<float*>(base + 40 * tiling.tileCount);
        view.format = state.format(side);
    }
    return view;
}

// Same encoding as CopperFDTD.metal's qStore, for one whole tile; `valid` marks the cells inside the
// grid (padding cells are left alone and don't count towards the range).
void qEncodeTile(QFieldView view, std::size_t tile, const float (&values)[16], const bool (&valid)[16]) {
    float lo = INFINITY, hi = -INFINITY;
    for (std::size_t i = 0; i < 16; ++i) {
        if (!valid[i]) continue;
        lo = std::min(lo, values[i]);
        hi = std::max(hi, values[i]);
    }
    const float span = hi > lo ? hi - lo : std::fabs(hi);
    const float scale = span >= 0x1p-110F ? span * (1.0F / 65534.0F) : 0.0F; // see CopperFDTD.metal's qStore
    const float inverse = scale > 0.0F ? 1.0F / scale : 0.0F;
    const float bias = (lo <= 0.0F && hi >= 0.0F) ? std::ceil(-lo * inverse) : -lo * inverse;
    for (std::size_t i = 0; i < 16; ++i) {
        if (!valid[i]) continue;
        view.n[16 * tile + i] =
            static_cast<std::uint16_t>(std::clamp(std::rint(values[i] * inverse + bias), 0.0F, 65535.0F));
    }
    view.header[2 * tile] = bias;
    view.header[2 * tile + 1] = scale;
}

// A box of cells, [x0, x1) x [y0, y1) x [z0, z1).
struct TileBox {
    std::uint32_t x0, y0, z0, x1, y1, z1;
};

// The Q16 tiles a set of boxes touches, each with the touched cells as a mask -- for the H side
// clipped to update_h_interior's (nx-1, ny-1, nz-1) extent, as the kernels are. Tiles for which
// `skip` returns true are left out.
template <typename Skip>
std::vector<CopperQBlockGPU> buildTileList(const CopperGridDims& dims, const std::vector<TileBox>& boxes, int side,
                                           Skip skip) {
    const QTiling tiling(dims);
    std::vector<std::uint32_t> mask(tiling.tileCount, 0);
    const std::uint32_t limitX = side == 0 ? dims.nx : dims.nx - 1;
    const std::uint32_t limitY = side == 0 ? dims.ny : dims.ny - 1;
    const std::uint32_t limitZ = side == 0 ? dims.nz : dims.nz - 1;
    for (const TileBox& box : boxes) {
        for (std::uint32_t z = box.z0; z < std::min(box.z1, limitZ); ++z) {
            for (std::uint32_t y = box.y0; y < std::min(box.y1, limitY); ++y) {
                for (std::uint32_t x = box.x0; x < std::min(box.x1, limitX); ++x) {
                    mask[tiling.tile(x, y, z)] |= 1U << QTiling::lane(x, y);
                }
            }
        }
    }
    std::vector<CopperQBlockGPU> blocks;
    for (std::size_t tile = 0; tile < mask.size(); ++tile) {
        if (mask[tile] != 0 && !skip(tile)) blocks.push_back({static_cast<std::uint32_t>(tile), mask[tile]});
    }
    return blocks;
}

// Widens `count` half-precision field values to float.
void widenHalf(const void* source, float* destination, std::size_t count) {
    vImage_Buffer from{const_cast<void*>(source), 1, count, count * sizeof(std::uint16_t)};
    vImage_Buffer to{destination, 1, count, count * sizeof(float)};
    vImageConvert_Planar16FtoPlanarF(&from, &to, kvImageNoFlags);
}

id<MTLBuffer> makeUploadedBuffer(id<MTLDevice> device, const std::vector<float>& data) {
    id<MTLBuffer> buffer = [device newBufferWithBytes:data.data()
                                                length:data.size() * sizeof(float)
                                               options:MTLResourceStorageModeShared];
    if (buffer == nil) {
        throw std::runtime_error("CopperEngine: failed to allocate a coefficient buffer");
    }
    return buffer;
}

} // namespace

/// Backend::Metal -- the GPU leapfrog engine. See CopperCPUEngine.cpp's MetalEngineImpl-mirroring
/// CPUEngineImpl for the CPU alternative; both implement copper::EngineBackend.
class MetalEngineImpl final : public EngineBackend {
public:
    MetalEngineImpl(const CopperYeeGrid& grid, const CopperExcitation& excitation,
                     const CopperCPML& cpml, const CopperDomainMask& domainMask);

    void run(std::uint32_t steps) override;
    void runWithProbeSampling(std::uint32_t steps, const CopperEngine::ProbeSampler& sampler,
                               const CopperEngine::MidStepCorrection& midStepCorrection) override;
    void readField(CopperEngine::Field field, std::vector<float>& destination) const override;
    float readFieldCell(CopperEngine::Field field, std::uint32_t x, std::uint32_t y, std::uint32_t z) const override;
    void writeFieldCell(CopperEngine::Field field, std::uint32_t x, std::uint32_t y, std::uint32_t z,
                         float value) override;
    double estimateEnergy() const override;
    const CopperGridDims& dims() const override { return _dims; }
    std::size_t currentAllocatedMetalBytes() const override {
        return static_cast<std::size_t>(_device.currentAllocatedSize);
    }
    void declareMidStepCorrectionCells(const std::vector<CopperLumpedRLCCell>& cells) override {
        _correctedCells = cells;
        _listsDirty = true;
    }
    std::size_t fusedTileCount() const override { return _fused ? _fusedTiles : 0; }
    void setLumpedRLC(const std::vector<CopperLumpedRLCCell>& cells) override {
        _lumpedRLC = cells;
        _listsDirty = true;
    }

private:
    CopperGridDims _dims;
    id<MTLDevice> _device;
    id<MTLCommandQueue> _queue;
    // The interior updates -- their _cpml or _zcpml variants when there's a CPML to fold in.
    id<MTLComputePipelineState> _updateEPipeline;
    id<MTLComputePipelineState> _updateHPipeline;

    id<MTLBuffer> _dimsBuffer;
    std::vector<CopperDomainMask::DispatchBox> _dispatchBoxes;
    // The six field buffers (Ex Ey Ez Hx Hy Hz), in one set -- or, under COPPER_FUSED's ping-pong, two:
    // timestep n reads set n % 2 and writes set (n + 1) % 2.
    id<MTLBuffer> _fields[2][6];
    bool _pingPong = false;
    std::uint32_t _executedTimestep = 0; // the CPU-visible state: which set is live
    bool _inMidStep = false;             // during a mid-step correction E is a step ahead of H
    int readSet() const { return _pingPong ? static_cast<int>(_currentTimestep % 2) : 0; }
    int writeSet() const { return _pingPong ? static_cast<int>((_currentTimestep + 1) % 2) : 0; }
    int liveSet(int side) const {
        return _pingPong ? static_cast<int>((_executedTimestep + (side == 0 && _inMidStep ? 1 : 0)) % 2) : 0;
    }
    // EXPERIMENT (COPPER_FIELD_FP16=1): E/H stored as half to halve field bandwidth; the kernels
    // still compute in float (see CopperFDTD.metal's ld()). Everything else stays float.
    bool _halfFields = false;
    // EXPERIMENT (COPPER_FIELD_Q16=1): E/H as 4x4x1 tiles of ushorts with a float (bias, scale) header
    // each (see CopperFDTD.metal's QField). The update kernels dispatch over the tiles the domain
    // touches instead of the dispatch boxes, so half a SIMD group owns each tile and can re-encode it.
    bool _q16Fields = false;
    // COPPER_Q16_ROUND=stochastic dithers every store instead of rounding to nearest. Measured worse on
    // the board (CTx1/CRx1, 2026-10-03): weak couplings up to ~35 dB further off fp32, and ~13% more
    // steps to converge on the slowest port -- the dither adds noise every step, while nearest's error
    // was already unbiased.
    bool _q16Stochastic = false;
    // EXPERIMENT (COPPER_FIELD_MIXED=1, implies Q16): every tile also has an fp32 copy, and a tile is
    // promoted to it while its amplitude is within COPPER_MIXED_PROMOTE_DB (default 50) of its side's
    // all-time peak tile amplitude, demoted again COPPER_MIXED_HYSTERESIS_DB (default 10) below that.
    // The persistent Q16 error went in almost entirely while the field was strong and concentrated in
    // a few percent of the tiles (snapshot analysis, 2026-10-03), so promoting those tiles while they
    // are hot recovers most of fp32's accuracy at a few percent of its bandwidth. Tiles change format
    // in q_retile_e/q_retile_h every COPPER_MIXED_RETILE_STEPS (default 8) steps.
    bool _mixedFields = false;
    float _mixedPromote = 0.0F, _mixedDemote = 0.0F; // amplitude ratios to the all-time peak
    std::uint32_t _mixedRetileSteps = 8;
    id<MTLBuffer> _qTileState; // Q16: QTileState for both sides (allocated, unused, without MIXED)
    id<MTLComputePipelineState> _retilePipeline[2];
    id<MTLComputePipelineState> _nearFloatPipeline;
    QTileStateView tileStateView() const {
        return _mixedFields ? QTileStateView{static_cast<std::uint8_t*>(_qTileState.contents), QTiling(_dims).tileCount}
                            : QTileStateView{};
    }
    QFieldView fieldView(CopperEngine::Field field) const {
        return qView(fieldBuffer(field), _dims, tileStateView(), static_cast<int>(field) >= 3 ? 1 : 0);
    }
    void printMixedStats(std::uint32_t timestep) const;
    id<MTLBuffer> _qBlocks[2];         // CopperQBlockGPU[], E then H
    NSUInteger _qBlockCount[2] = {0, 0};
    id<MTLBuffer> _qExcitationBlocks[2]; // CopperQExcitationBlockGPU[], voltage then current
    NSUInteger _qExcitationBlockCount[2] = {0, 0};
    NSUInteger _qThreadgroupWidth = 32;
    id<MTLBuffer> fieldBuffer(CopperEngine::Field field) const {
        const int component = static_cast<int>(field);
        return _fields[liveSet(component >= 3 ? 1 : 0)][component];
    }

    // EXPERIMENT (COPPER_FUSED=1, needs Q16/MIXED and a rectangular domain): one fused E+H pass per
    // step over every tile it can take (see CopperFDTD.metal's fusedEH), with the separate kernels for
    // the rest. COPPER_FUSED_CHUNK (default 16) caps the tile planes per segment.
    bool _fused = false;
    // COPPER_FUSED_CORRECTIONS (default 1): the fused kernel applies voltage excitation and GPU lumped
    // RLC itself, so their tiles fuse too; 0 leaves them to the separate kernels.
    bool _fusedCorrections = true;
    id<MTLBuffer> _fusedCorrectionList, _fusedCorrectionOffsets;
    std::uint32_t _fusedChunk = 16;
    id<MTLComputePipelineState> _fusedPipeline;
    id<MTLBuffer> _fusedSegments;
    NSUInteger _fusedSegmentCount = 0;
    std::size_t _fusedTiles = 0;
    // What the dispatch lists depend on beyond the grid: cells that get corrected between the E and H
    // updates. Lists are (re)built lazily, before the first step after a change.
    std::vector<std::uint8_t> _cpmlLine[3]; // per grid line of each axis: 1 inside its CPML slabs
    std::vector<CopperExcitationCell> _excitationCells[2];
    std::vector<CopperLumpedRLCCell> _correctedCells;
    bool _listsDirty = true;
    void prepareDispatchLists();

    // SERIES lumped RLC elements applied on the GPU (CopperEngine::setLumpedRLC), sorted into groups
    // by the cell (flat layouts) or (component, tile) (Q16) they correct, each group owned by one
    // thread or half SIMD group so overlapping elements still apply in order.
    std::vector<CopperLumpedRLCCell> _lumpedRLC;
    id<MTLComputePipelineState> _lumpedPipeline;
    id<MTLBuffer> _lumpedCells, _lumpedState, _lumpedGroups;
    std::vector<CopperLumpedRLCCell> _lumpedSorted;
    NSUInteger _lumpedGroupCount = 0;

    // The update coefficients in table form (see CopperCoefficientTable): [0] the E side, [1] H.
    struct CoefficientBuffers {
        id<MTLBuffer> index;    // per cell: ushort or uint, into `table`
        id<MTLBuffer> table;    // CopperMaterialCoefficientsGPU[]
        id<MTLBuffer> geometry; // float[2 * (nx + ny + nz)]
    };
    CoefficientBuffers _coefficients[2];
    bool _wideIndex[2] = {false, false};

    // EXPERIMENT (COPPER_SNAPSHOT_DIR + COPPER_SNAPSHOT_STEPS=a,b,c): after each listed timestep, dump
    // all six fields decoded to float (flat, x-fastest, Ex Ey Ez Hx Hy Hz) to DIR/step_<n>.f32, plus
    // the grid and coefficient tables once, for offline analysis of the field distributions. A
    // snapshot that already exists is left alone, so only the first port of a run is captured.
    std::filesystem::path _snapshotDir;
    std::set<std::uint32_t> _snapshotSteps;
    void snapshotIfRequested(std::uint32_t timestep) const;

    // The CPML (see CopperCPML), folded into the update kernels: one CopperCPMLLineGPU per grid
    // line, the psi layout (CopperCPMLGPU) and each side's psi. nil buffers when there is none.
    id<MTLBuffer> _cpmlLines, _cpmlPsi[2];
    CopperCPMLGPU _cpmlLayout[2] = {}; // bound per dispatch, with that step's seed
    // EXPERIMENT (COPPER_CPML_PSI=fp32|fp16|bf16|bf16sr): psi's storage format (CopperPsiFormat); fp16
    // stores the E and H sides' psi times 2^e and 2^h, from COPPER_CPML_PSI_SCALE_LOG2=e,h.
    std::uint32_t _psiFormat[2] = {CopperPsiFormatFloat, CopperPsiFormatFloat}; // per side
    std::uint32_t _psiDropBits = 0;
    bool _psiDropStochastic = false;
    int _psiScaleLog2[2] = {0, 0};

    // Excitation (Phase 4 -- see CopperExcitation.hpp). Zero counts mean encodeIterationPhase simply
    // never dispatches the corresponding kernel -- an unexcited run stays at its E=H=0 (or
    // test-seeded, see writeFieldCell) initial condition, same as Phase 2/3.
    id<MTLComputePipelineState> _applyExcitationEPipeline;
    id<MTLComputePipelineState> _applyExcitationHPipeline;
    id<MTLBuffer> _voltageCells;  // CopperExcitationCellGPU[voltageCellCount]
    id<MTLBuffer> _currentCells;  // CopperExcitationCellGPU[currentCellCount]
    id<MTLBuffer> _voltageSignal; // float[signalLength]
    id<MTLBuffer> _currentSignal; // float[signalLength]
    // CopperExcitationParamsGPU is bound via setBytes:length:atIndex:, not an MTLBuffer -- run()
    // encodes every iteration's commands on the CPU *before* any of them actually execute on the
    // GPU (that's what makes the batching work), so a single shared MTLBuffer mutated by CPU-side
    // memcpy between encodeIterationPhase calls would have every dispatch see only the *last*
    // iteration's values once the GPU finally runs (this was a real, confirmed bug in an earlier
    // version of this code -- Phase 4a's smoketest caught it). setBytes: instead copies the given
    // bytes into the command buffer's own storage immediately at encode time, so each dispatch
    // keeps its own snapshot regardless of what a later encodeIterationPhase call does to the local
    // variable afterwards.
    std::uint32_t _voltageCellCount = 0;
    std::uint32_t _currentCellCount = 0;
    std::uint32_t _signalLength = 0;
    double _timestepSeconds = 0.0;      // needed to turn signalPeriodSeconds into a step count
    double _signalPeriodSeconds = 0.0;
    std::uint32_t _currentTimestep = 0; // persists across run()/runWithProbeSampling() calls, mirrors
                                         // Engine::numTS exactly (including *when* it increments)

    enum class IterationPhase { Full, Voltage, Current };

    // Encodes either or both halves of one leapfrog iteration. `Full` preserves run()'s batched
    // fast path; Voltage/Current are committed separately when a CPU correction must land between
    // them. currentTimestep advances only after the Current half.
    // `encoder` may be replaced (ended and a new one begun on _encodingCommandBuffer) under profiling.
    void encodeIterationPhase(__strong id<MTLComputeCommandEncoder>& encoder, IterationPhase phase);
    id<MTLCommandBuffer> _encodingCommandBuffer;

    // EXPERIMENT (COPPER_PROFILE_KERNELS=1): GPU time per kernel category, each category in its own
    // compute encoder with a timestamp sample at its start and end. Forces the serial (one command
    // buffer at a time) loop, so samples from different steps never share the buffer; that adds idle
    // time between command buffers, not to any kernel. Printed every 100 steps.
    // EXPERIMENT (COPPER_GPU_CAPTURE_STEP=n, with MTL_CAPTURE_ENABLED=1): a .gputrace of step n, to
    // COPPER_GPU_CAPTURE_PATH (default /tmp/copper.gputrace), for Xcode.
    struct KernelProfile {
        bool enabled = false;
        id<MTLCounterSampleBuffer> samples;
        std::vector<std::pair<const char*, NSUInteger>> sections; // name, start sample index
        std::vector<std::pair<std::string, double>> totals;      // name, GPU seconds
        std::uint32_t steps = 0;
        MTLTimestamp cpu0 = 0, gpu0 = 0;
        void resolve(id<MTLDevice> device);
        void stepDone(id<MTLDevice> device);
    } _profile;
    std::uint32_t _captureStep = UINT32_MAX;
    std::string _capturePath = "/tmp/copper.gputrace";


    // One timestep's command buffers, encoded before they're needed so the CPU's encoding overlaps
    // the GPU's previous step. `current` is nil for a Full-phase (no mid-step correction) step;
    // otherwise it starts with a wait on _correctionEvent reaching `correctionValue`, which the CPU
    // signals once the correction has written the voltage phase's results.
    struct EncodedStep {
        id<MTLCommandBuffer> first;
        id<MTLCommandBuffer> current;
        std::uint64_t correctionValue = 0;
    };
    EncodedStep encodeStep(bool splitAtCorrection);
    void runWithProbeSamplingPipelined(std::uint32_t steps, const CopperEngine::ProbeSampler& sampler,
                                       const CopperEngine::MidStepCorrection& midStepCorrection);
    id<MTLSharedEvent> _correctionEvent;
    std::uint64_t _correctionEventValue = 0;

    // EXPERIMENT (COPPER_GPU_TIMING=1): per-step GPU busy time and GPU idle gaps between
    // consecutive command buffers, from the command buffers' own GPU timestamps.
    struct StepTiming {
        bool enabled = false;
        double busy[2] = {0, 0}, idle[2] = {0, 0}, lastGPUEnd = 0, sampler = 0;
        std::uint32_t steps = 0;
        std::chrono::steady_clock::time_point start = std::chrono::steady_clock::now();
        void completed(id<MTLCommandBuffer> commandBuffer, int slot) {
            if (lastGPUEnd > 0) idle[slot] += commandBuffer.GPUStartTime - lastGPUEnd;
            busy[slot] += commandBuffer.GPUEndTime - commandBuffer.GPUStartTime;
            lastGPUEnd = commandBuffer.GPUEndTime;
        }
        void stepDone(const char* label);
    } _stepTiming;

    // Irregular domains use a concurrent encoder, relying on the explicit memoryBarrierWithScope
    // calls between stages: a serial encoder drains the GPU between each of their ~1000 small
    // cuboid dispatches. Only safe when no two dispatches within a stage touch the same cell -- true
    // of the disjoint cuboids. A rectangular domain is one dispatch per stage anyway, and stays
    // serial. COPPER_CONCURRENT_DISPATCH=0 forces serial for comparison.
    MTLDispatchType _dispatchType = MTLDispatchTypeSerial;
};

MetalEngineImpl::MetalEngineImpl(const CopperYeeGrid& grid, const CopperExcitation& excitation,
                                  const CopperCPML& cpml, const CopperDomainMask& domainMask) {
    _dims = grid.dims;
    _timestepSeconds = grid.timestepSeconds;
    _signalPeriodSeconds = excitation.signalPeriodSeconds;

    _device = MTLCreateSystemDefaultDevice();
    if (_device == nil) {
        throw std::runtime_error("CopperEngine: no Metal device available");
    }

    NSBundle* bundle = [NSBundle bundleForClass:[CopperEngineBundleAnchor class]];
    NSError* error = nil;
    id<MTLLibrary> library = [_device newDefaultLibraryWithBundle:bundle error:&error];
    if (library == nil) {
        throw std::runtime_error("CopperEngine: failed to load Copper's default Metal library: " +
                                  std::string(error.localizedDescription.UTF8String));
    }

    // Q16 kernels are specialized on COPPER_FIELD_MIXED by function constant (see CopperFDTD.metal's
    // kMixed), and every kernel on COPPER_CPML_PSI's format; filled in once the environment has been
    // read below.
    MTLFunctionConstantValues* constants = [MTLFunctionConstantValues new];
    auto makePipeline = [&](NSString* name) -> id<MTLComputePipelineState> {
        NSError* functionError = nil;
        id<MTLFunction> function = [library newFunctionWithName:name constantValues:constants error:&functionError];
        if (function == nil) {
            throw std::runtime_error("CopperEngine: " + std::string(name.UTF8String) +
                                      " not found in Copper's Metal library");
        }
        NSError* pipelineError = nil;
        id<MTLComputePipelineState> pipeline =
            [_device newComputePipelineStateWithFunction:function error:&pipelineError];
        if (pipeline == nil) {
            throw std::runtime_error("CopperEngine: failed to build " + std::string(name.UTF8String) +
                                      " pipeline state: " + std::string(pipelineError.localizedDescription.UTF8String));
        }
        return pipeline;
    };

    if (const char* halfEnv = std::getenv("COPPER_FIELD_FP16")) {
        _halfFields = std::string(halfEnv) == "1";
    }
    if (const char* qEnv = std::getenv("COPPER_FIELD_Q16")) {
        _q16Fields = std::string(qEnv) == "1";
    }
    if (const char* dir = std::getenv("COPPER_SNAPSHOT_DIR")) {
        _snapshotDir = dir;
        if (const char* steps = std::getenv("COPPER_SNAPSHOT_STEPS")) {
            const std::string list = steps;
            for (std::size_t begin = 0; begin < list.size();) {
                const std::size_t end = std::min(list.find(',', begin), list.size());
                _snapshotSteps.insert(static_cast<std::uint32_t>(std::stoul(list.substr(begin, end - begin))));
                begin = end + 1;
            }
        }
    }
    // Mixed Q16/fp32 tiles are the default: as fast as Q16 with fp32's S-parameters (see
    // docs/copper_field_storage_experiments.md). COPPER_FIELD_MIXED=0 gives plain fp32 fields, and
    // asking for plain Q16 or fp16 fields explicitly turns it off too.
    _mixedFields = !_q16Fields && !_halfFields;
    if (const char* mixedEnv = std::getenv("COPPER_FIELD_MIXED")) {
        _mixedFields = std::string(mixedEnv) == "1";
    }
    _q16Fields = _q16Fields || _mixedFields;
    if (_mixedFields) {
        double promoteDB = 50.0, hysteresisDB = 10.0;
        if (const char* env = std::getenv("COPPER_MIXED_PROMOTE_DB")) promoteDB = std::stod(env);
        if (const char* env = std::getenv("COPPER_MIXED_HYSTERESIS_DB")) hysteresisDB = std::stod(env);
        if (const char* env = std::getenv("COPPER_MIXED_RETILE_STEPS")) {
            _mixedRetileSteps = static_cast<std::uint32_t>(std::max(1, std::stoi(env)));
        }
        // Thresholds are on energy, compared as amplitudes.
        _mixedPromote = static_cast<float>(std::pow(10.0, -promoteDB / 20.0));
        _mixedDemote = static_cast<float>(std::pow(10.0, -(promoteDB + hysteresisDB) / 20.0));
        std::fprintf(stderr, "Copper: mixed Q16/fp32 tiles -- promote within %.0f dB of the peak, demote %.0f dB below "
                             "that, retile every %u steps\n",
                     promoteDB, hysteresisDB, _mixedRetileSteps);
    }
    if (const char* roundEnv = std::getenv("COPPER_Q16_ROUND")) {
        _q16Stochastic = std::string(roundEnv) == "stochastic";
    }
    if (_halfFields && _q16Fields) {
        throw std::runtime_error("CopperEngine: COPPER_FIELD_FP16 and COPPER_FIELD_Q16 are exclusive");
    }
    NSString* fieldSuffix = _halfFields ? @"_f16" : (_q16Fields ? @"_q16" : @"");
    if (const char* env = std::getenv("COPPER_FUSED_CORRECTIONS")) _fusedCorrections = std::string(env) != "0";
    if (_q16Fields) {
        bool mixed = _mixedFields;
        bool corrections = _fusedCorrections;
        [constants setConstantValue:&mixed type:MTLDataTypeBool atIndex:CopperFunctionConstantMixed];
        [constants setConstantValue:&corrections type:MTLDataTypeBool atIndex:CopperFunctionConstantFusedCorrections];
    }
    if (const char* env = std::getenv("COPPER_CPML_PSI")) {
        const std::string format = env;
        std::uint32_t psiFormat = CopperPsiFormatFloat;
        if (format == "fp16") {
            psiFormat = CopperPsiFormatHalf;
        } else if (format == "bf16") {
            psiFormat = CopperPsiFormatBFloat;
        } else if (format == "bf16sr") {
            psiFormat = CopperPsiFormatBFloatStochastic;
        } else if (format.rfind("drop", 0) == 0) { // dropN (round to nearest) or dropNsr
            psiFormat = CopperPsiFormatTruncated;
            _psiDropBits = static_cast<std::uint32_t>(std::stoi(format.substr(4)));
        } else if (format.rfind("fix", 0) == 0 || format.rfind("bfp", 0) == 0) { // fixN[sr], bfpN[sr]: N bits with sign
            psiFormat = format[0] == 'f' ? CopperPsiFormatFixed : CopperPsiFormatBlock;
            _psiDropBits = static_cast<std::uint32_t>(std::stoi(format.substr(3))) - 1;
        } else if (format == "fp24" || format == "fp24sr") {
            psiFormat = CopperPsiFormatFloat24;
        } else if (format == "blk16") {
            psiFormat = CopperPsiFormatBlock16;
            // Its blocks are 16 x-aligned cells of a row, which an irregular domain's cuboids (arbitrary
            // x starts) don't give the fp32 update kernels; the Q16 kernels' blocks are tiles.
            if (!domainMask.empty() && !_q16Fields) {
                std::fprintf(stderr, "Copper: COPPER_CPML_PSI=blk16 needs a rectangular domain or Q16 fields; "
                                     "psi stays fp32\n");
                psiFormat = CopperPsiFormatFloat;
            }
        } else if (format != "fp32") {
            throw std::runtime_error(
                "CopperEngine: COPPER_CPML_PSI must be fp32, fp24[sr], blk16, fp16, bf16, bf16sr, dropN[sr], fixN[sr] or "
                "bfpN[sr]");
        }
        _psiDropStochastic = format.size() > 2 && format.compare(format.size() - 2, 2, "sr") == 0;
        // COPPER_CPML_PSI_SIDE=E, H or EH (default): the sides whose psi uses that format; the
        // other keeps fp32.
        const char* sides = std::getenv("COPPER_CPML_PSI_SIDE");
        for (int side = 0; side < 2; ++side) {
            if (sides == nullptr || std::strchr(sides, side == 0 ? 'E' : 'H') != nullptr) _psiFormat[side] = psiFormat;
        }
        if (const char* scale = std::getenv("COPPER_CPML_PSI_SCALE_LOG2")) {
            const std::string text = scale;
            const std::size_t comma = text.find(',');
            _psiScaleLog2[0] = std::stoi(text.substr(0, comma));
            _psiScaleLog2[1] = comma == std::string::npos ? _psiScaleLog2[0] : std::stoi(text.substr(comma + 1));
        }
    }
    auto setPsiFormat = [&](std::uint32_t psiFormat) {
        [constants setConstantValue:&psiFormat type:MTLDataTypeUInt atIndex:CopperFunctionConstantPsiFormat];
    };
    setPsiFormat(CopperPsiFormatFloat); // only the update kernels touch psi; they set their side's below
    _applyExcitationEPipeline = makePipeline([@"apply_excitation_e" stringByAppendingString:fieldSuffix]);
    _lumpedPipeline = makePipeline([@"apply_lumped_rlc" stringByAppendingString:fieldSuffix]);
    _applyExcitationHPipeline = makePipeline([@"apply_excitation_h" stringByAppendingString:fieldSuffix]);

    _queue = [_device newCommandQueue];
    if (_queue == nil) {
        throw std::runtime_error("CopperEngine: failed to create a Metal command queue");
    }
    _correctionEvent = [_device newSharedEvent];
    if (_correctionEvent == nil) {
        throw std::runtime_error("CopperEngine: failed to create a Metal shared event");
    }
    if (const char* timingEnv = std::getenv("COPPER_GPU_TIMING")) {
        _stepTiming.enabled = std::string(timingEnv) == "1";
    }
    if (const char* env = std::getenv("COPPER_PROFILE_KERNELS"); env != nullptr && std::string(env) == "1") {
        if (![_device supportsCounterSampling:MTLCounterSamplingPointAtStageBoundary]) {
            throw std::runtime_error("CopperEngine: COPPER_PROFILE_KERNELS needs stage-boundary counter sampling");
        }
        id<MTLCounterSet> timestamps = nil;
        for (id<MTLCounterSet> set in _device.counterSets) {
            if ([set.name isEqualToString:MTLCommonCounterSetTimestamp]) timestamps = set;
        }
        MTLCounterSampleBufferDescriptor* descriptor = [MTLCounterSampleBufferDescriptor new];
        descriptor.counterSet = timestamps;
        descriptor.storageMode = MTLStorageModeShared;
        descriptor.sampleCount = 4096;
        NSError* sampleError = nil;
        _profile.samples = [_device newCounterSampleBufferWithDescriptor:descriptor error:&sampleError];
        if (_profile.samples == nil) throw std::runtime_error("CopperEngine: no counter sample buffer");
        _profile.enabled = true;
        [_device sampleTimestamps:&_profile.cpu0 gpuTimestamp:&_profile.gpu0];
    }
    if (const char* env = std::getenv("COPPER_GPU_CAPTURE_STEP")) _captureStep = static_cast<std::uint32_t>(std::stoul(env));
    if (const char* env = std::getenv("COPPER_GPU_CAPTURE_PATH")) _capturePath = env;

    CopperGridDimsGPU dimsGPU{grid.dims.nx, grid.dims.ny, grid.dims.nz};
    _dimsBuffer = [_device newBufferWithBytes:&dimsGPU length:sizeof(dimsGPU) options:MTLResourceStorageModeShared];
    const char* concurrent = std::getenv("COPPER_CONCURRENT_DISPATCH");
    if (!domainMask.empty() && (concurrent == nullptr || std::string(concurrent) != "0")) {
        _dispatchType = MTLDispatchTypeConcurrent;
    }
    if (domainMask.empty()) {
        _dispatchBoxes.push_back(
            {0, 0, grid.dims.nx, grid.dims.ny, CopperDomainMask::Region::Interior});
    } else {
        _dispatchBoxes = domainMask.dispatchBoxes;
    }

    const std::size_t cellCount = grid.dims.cellCount();
    if (const char* fusedEnv = std::getenv("COPPER_FUSED")) {
        _fused = std::string(fusedEnv) == "1";
        if (const char* chunk = std::getenv("COPPER_FUSED_CHUNK")) {
            _fusedChunk = static_cast<std::uint32_t>(std::max(1, std::stoi(chunk)));
        }
    }
    if (_fused && (!_q16Fields || !domainMask.empty())) {
        std::fprintf(stderr, "Copper: COPPER_FUSED needs COPPER_FIELD_Q16/MIXED and a rectangular domain; running "
                             "the separate E and H kernels\n");
        _fused = false;
    }
    _pingPong = _fused;
    for (int set = 0; set < (_pingPong ? 2 : 1); ++set) {
        for (int component = 0; component < 6; ++component) {
            if (_q16Fields) {
                // 32 bytes of ushorts + an 8-byte header per tile, then under MIXED 64 bytes of floats.
                const std::size_t tileBytes = _mixedFields ? 104 : 40;
                _fields[set][component] = makeZeroedBuffer(_device, QTiling(_dims).tileCount, tileBytes);
            } else {
                const std::size_t elementSize = _halfFields ? sizeof(std::uint16_t) : sizeof(float);
                _fields[set][component] = makeZeroedBuffer(_device, cellCount, elementSize);
            }
        }
    }


    // Coefficients as a table of material terms plus the mesh's separable geometry (see
    // CopperCoefficientTable), with the irregular domain's ring absorber folded in as each side's
    // table is built. Indices are 16-bit whenever the table fits, and the kernels are picked to match.
    static_assert(sizeof(CopperCoefficientTable::Entry) == sizeof(CopperMaterialCoefficientsGPU),
                  "CopperCoefficientTable::Entry must stay layout-compatible with CopperMaterialCoefficientsGPU");
    const CopperRingAbsorber ring(domainMask, grid.timestepSeconds, grid.dims);
    NSString* indexSuffix[2];
    for (int side = 0; side < 2; ++side) {
        const CopperCoefficientTable table = buildCoefficientTable(
            grid, side == 0 ? CopperCoefficientSide::E : CopperCoefficientSide::H, _dispatchBoxes, ring);
        const bool wide = table.entries.size() > 65536;
        CoefficientBuffers& buffers = _coefficients[side];
        if (wide) {
            buffers.index = [_device newBufferWithBytes:table.index.data()
                                                 length:table.index.size() * sizeof(std::uint32_t)
                                                options:MTLResourceStorageModeShared];
        } else {
            buffers.index = [_device newBufferWithLength:cellCount * sizeof(std::uint16_t)
                                                 options:MTLResourceStorageModeShared];
            if (buffers.index != nil) {
                auto* narrow = static_cast<std::uint16_t*>(buffers.index.contents);
                for (std::size_t i = 0; i < cellCount; ++i) narrow[i] = static_cast<std::uint16_t>(table.index[i]);
            }
        }
        buffers.table = [_device newBufferWithBytes:table.entries.data()
                                             length:table.entries.size() * sizeof(CopperCoefficientTable::Entry)
                                            options:MTLResourceStorageModeShared];
        buffers.geometry = makeUploadedBuffer(_device, table.geometry);
        if (buffers.index == nil || buffers.table == nil) {
            throw std::runtime_error("CopperEngine: failed to allocate a coefficient table buffer");
        }
        indexSuffix[side] = wide ? @"_u32" : @"_u16";
        _wideIndex[side] = wide;
        std::fprintf(stderr, "Copper: %s coefficient table: %zu entries, %s indices, %s rebuilt to within %.1e\n",
                     side == 0 ? "E" : "H", table.entries.size(), wide ? "32-bit" : "16-bit", side == 0 ? "vi" : "iv",
                     table.worstRebuildError);
    }
    auto sidePipeline = [&](NSString* name, int side) {
        setPsiFormat(_psiFormat[side]);
        id<MTLComputePipelineState> pipeline =
            makePipeline([[name stringByAppendingString:indexSuffix[side]] stringByAppendingString:fieldSuffix]);
        setPsiFormat(CopperPsiFormatFloat);
        return pipeline;
    };
    // The update kernels' CPML variant: all three axes, Z alone (an irregular domain's), or none.
    NSString* cpmlSuffix = @"";
    if (cpml.axes[0].layerCount() + cpml.axes[1].layerCount() > 0) {
        cpmlSuffix = @"_cpml";
    } else if (!cpml.empty()) {
        cpmlSuffix = @"_zcpml";
    }
    _updateEPipeline = sidePipeline([@"update_e_interior" stringByAppendingString:cpmlSuffix], 0);
    _updateHPipeline = sidePipeline([@"update_h_interior" stringByAppendingString:cpmlSuffix], 1);
    if (_fused) {
        _fusedPipeline = makePipeline([[[@"fused_eh" stringByAppendingString:indexSuffix[0]]
            stringByAppendingString:indexSuffix[1]] stringByAppendingString:@"_q16"]);
    }
    if (const char* timingEnv = std::getenv("COPPER_GPU_TIMING"); timingEnv != nullptr && std::string(timingEnv) == "1") {
        // Register pressure shows up as a lower maximum threadgroup size.
        for (const auto& [name, pipeline] : {std::pair("update_e", _updateEPipeline), std::pair("update_h", _updateHPipeline),
                                             std::pair("fused", _fusedPipeline)}) {
            if (pipeline != nil) {
                std::fprintf(stderr, "Copper: %s pipeline: max %lu threads per threadgroup\n", name,
                             static_cast<unsigned long>(pipeline.maxTotalThreadsPerThreadgroup));
            }
        }
    }

    if (_q16Fields) {
        // The domain's own tile lists depend on which tiles the fused kernel takes, and so on the cells
        // corrected mid-step; they're built in prepareDispatchLists().
        const QTiling tiling(_dims);
        _qThreadgroupWidth = std::min<NSUInteger>(256, _updateEPipeline.maxTotalThreadsPerThreadgroup) / 32 * 32;
        // Peaks, then per tile: format, request and pinned bytes per side, and a near-fp32 byte.
        _qTileState = makeZeroedBuffer(_device, 16 + 7 * tiling.tileCount, 1);
        if (_mixedFields) {
            _retilePipeline[0] = makePipeline(@"q_retile_e_q16");
            _retilePipeline[1] = makePipeline(@"q_retile_h_q16");
            _nearFloatPipeline = makePipeline(@"q_near_float_q16");
        }
        if (_updateEPipeline.threadExecutionWidth != 32) {
            throw std::runtime_error("CopperEngine: COPPER_FIELD_Q16 needs 32-wide SIMD groups");
        }
    }

    if (!cpml.empty()) {
        const std::uint32_t lines[3] = {grid.dims.nx, grid.dims.ny, grid.dims.nz};
        std::vector<CopperCPMLLineGPU> lineGPU;
        CopperCPMLGPU layout{};
        std::size_t psiFloats = 0;
        for (int axis = 0; axis < 3; ++axis) {
            const CopperCPML::Axis& graded = cpml.axes[axis];
            if (graded.layerOf.size() != lines[axis]) {
                throw std::runtime_error("CopperEngine: CPML line table doesn't match the grid");
            }
            _cpmlLine[axis].assign(lines[axis], 0);
            for (std::uint32_t line = 0; line < lines[axis]; ++line) {
                const std::uint32_t layer = graded.layerOf[line];
                if (layer == CopperCPML::kNoLayer) {
                    lineGPU.push_back({kCopperCPMLNoLayer, 1.0F, 0.0F, 1.0F, 0.0F});
                } else {
                    lineGPU.push_back({layer, graded.bE[layer], graded.cE[layer], graded.bH[layer], graded.cH[layer]});
                    _cpmlLine[axis][line] = 1;
                }
            }
            const std::size_t count = cpml.psiCount(grid.dims, axis);
            layout.layers[axis] = graded.layerCount();
            layout.psiOffset[axis] = static_cast<std::uint32_t>(psiFloats);
            layout.psiCount[axis] = static_cast<std::uint32_t>(count);
            psiFloats += 2 * count;
        }
        if (psiFloats > std::numeric_limits<std::uint32_t>::max()) {
            throw std::runtime_error("CopperEngine: CPML psi doesn't fit 32-bit indices");
        }
        _cpmlLines = [_device newBufferWithBytes:lineGPU.data()
                                          length:lineGPU.size() * sizeof(CopperCPMLLineGPU)
                                         options:MTLResourceStorageModeShared];
        for (int side = 0; side < 2; ++side) {
            _cpmlLayout[side] = layout;
            _cpmlLayout[side].psiScale = std::ldexp(1.0F, _psiScaleLog2[side]);
            _cpmlLayout[side].psiInverseScale = std::ldexp(1.0F, -_psiScaleLog2[side]);
            const std::uint32_t format = _psiFormat[side];
            const bool study = format == CopperPsiFormatTruncated || format == CopperPsiFormatFixed ||
                               format == CopperPsiFormatBlock;
            _cpmlLayout[side].psiDropBits = study ? _psiDropBits : 0U;
            _cpmlLayout[side].psiStochastic = _psiDropStochastic ? 1U : 0U;
            _cpmlLayout[side].psiTotal = static_cast<std::uint32_t>(psiFloats);
            // Block16's blocks: Q16 tiles, or 16 x-aligned cells of a row.
            const std::size_t blocks =
                _q16Fields ? QTiling(_dims).tileCount
                           : static_cast<std::size_t>((_dims.nx + 15) / 16) * _dims.ny * _dims.nz;
            _cpmlLayout[side].psiBlocks = static_cast<std::uint32_t>(blocks);
            if (format == CopperPsiFormatBlock16) {
                _cpmlPsi[side] = makeZeroedBuffer(_device, 2 * psiFloats + 6 * blocks, 1);
            } else {
                const std::size_t bytes = (format == CopperPsiFormatFloat || study) ? sizeof(float)
                                          : format == CopperPsiFormatFloat24     ? 3
                                                                                  : sizeof(std::uint16_t);
                _cpmlPsi[side] = makeZeroedBuffer(_device, psiFloats, bytes);
            }
        }
    }

    // copper::CopperExcitationCell (CopperExcitation.hpp) is uploaded here by raw bytes, not
    // converted field-by-field -- this static_assert is what makes that safe: it fails loudly if
    // the two ever drift out of layout sync instead of silently misinterpreting bytes on the GPU.
    static_assert(sizeof(CopperExcitationCell) == sizeof(CopperExcitationCellGPU),
                  "copper::CopperExcitationCell must stay layout-compatible with CopperExcitationCellGPU");

    _signalLength = static_cast<std::uint32_t>(excitation.voltageSignal.size());
    _voltageCellCount = static_cast<std::uint32_t>(excitation.voltageCells.size());
    _currentCellCount = static_cast<std::uint32_t>(excitation.currentCells.size());
    // Q16 sorts each list's cells by the (component, tile) they land in, so prepareDispatchLists()
    // can group them for the excitation kernel, one tile per half SIMD group.
    auto sortExcitation = [&](std::vector<CopperExcitationCell> cells) {
        if (!_q16Fields) return cells;
        const QTiling tiling(_dims);
        auto key = [&](const CopperExcitationCell& cell) { return std::pair(cell.axis, tiling.tile(cell.x, cell.y, cell.z)); };
        std::stable_sort(cells.begin(), cells.end(), [&](const auto& a, const auto& b) { return key(a) < key(b); });
        return cells;
    };
    _excitationCells[0] = sortExcitation(excitation.voltageCells);
    _excitationCells[1] = sortExcitation(excitation.currentCells);
    const std::vector<CopperExcitationCell>& voltageCells = _excitationCells[0];
    const std::vector<CopperExcitationCell>& currentCells = _excitationCells[1];
    if (_voltageCellCount > 0) {
        _voltageCells = [_device newBufferWithBytes:voltageCells.data()
                                              length:excitation.voltageCells.size() * sizeof(CopperExcitationCell)
                                             options:MTLResourceStorageModeShared];
        _voltageSignal = makeUploadedBuffer(_device, excitation.voltageSignal);
    }
    if (_currentCellCount > 0) {
        _currentCells = [_device newBufferWithBytes:currentCells.data()
                                              length:excitation.currentCells.size() * sizeof(CopperExcitationCell)
                                             options:MTLResourceStorageModeShared];
        _currentSignal = makeUploadedBuffer(_device, excitation.currentSignal);
    }
}

void MetalEngineImpl::encodeIterationPhase(__strong id<MTLComputeCommandEncoder>& encoder, IterationPhase phase) {
    // COPPER_PROFILE_KERNELS: each kernel category gets its own encoder, timestamped at both ends.
    auto section = [&](const char* name) {
        if (!_profile.enabled) return;
        [encoder endEncoding];
        const NSUInteger start = 2 * _profile.sections.size();
        MTLComputePassDescriptor* pass = [MTLComputePassDescriptor computePassDescriptor];
        pass.dispatchType = _dispatchType;
        pass.sampleBufferAttachments[0].sampleBuffer = _profile.samples;
        pass.sampleBufferAttachments[0].startOfEncoderSampleIndex = start;
        pass.sampleBufferAttachments[0].endOfEncoderSampleIndex = start + 1;
        encoder = [_encodingCommandBuffer computeCommandEncoderWithDescriptor:pass];
        _profile.sections.emplace_back(name, start);
        if (_q16Fields) [encoder setBuffer:_qTileState offset:0 atIndex:CopperBufferIndexQTileState];
    };
    const bool encodeVoltage = phase != IterationPhase::Current;
    const bool encodeCurrent = phase != IterationPhase::Voltage;
    const MTLSize eGrid = MTLSizeMake(_dims.nx, _dims.ny, _dims.nz);
    const MTLSize hGrid = MTLSizeMake(_dims.nx > 0 ? _dims.nx - 1 : 0, _dims.ny > 0 ? _dims.ny - 1 : 0,
                                       _dims.nz > 0 ? _dims.nz - 1 : 0);
    const NSUInteger tgWidth = _updateEPipeline.threadExecutionWidth;
    const MTLSize threadsPerThreadgroup = MTLSizeMake(tgWidth, 1, 1);
    // This step reads one buffer set and writes another (the same one unless COPPER_FUSED).
    const int r = readSet(), w = writeSet();

    // Excitation params for *this* iteration -- numTS read before increment, matching
    // Engine_Ext_Excitation::Apply2VoltagesImpl/Apply2CurrentImpl's own
    // `m_Eng->GetNumberOfTimesteps()` (both stages share this one value, exactly like the CPU
    // engine's Apply2Voltages/Apply2Current do within a single Engine::IterateTS iteration). Bound
    // below via setBytes:, not a shared MTLBuffer -- see the class's own field comment on why.
    const auto numTS = static_cast<std::int32_t>(_currentTimestep);
    const std::int32_t period = (_signalPeriodSeconds > 0.0)
                                     ? static_cast<std::int32_t>(_signalPeriodSeconds / _timestepSeconds)
                                     : numTS + 1;
    const CopperExcitationParamsGPU excitationParams{numTS, period, _signalLength};

    // A distinct dither seed for every Q16 dispatch of every timestep (see CopperQRoundingGPU).
    enum class QStage : std::uint32_t { Update, Excitation };
    auto qRounding = [&](QStage stage, int side, std::uint32_t index) {
        const auto dispatch = static_cast<std::uint32_t>(stage) * 64 + static_cast<std::uint32_t>(side) * 32 + index;
        return CopperQRoundingGPU{_currentTimestep * 256 + dispatch, _q16Stochastic ? 1U : 0U, _mixedPromote,
                                  _mixedDemote};
    };
    if (_q16Fields) {
        [encoder setBuffer:_qTileState offset:0 atIndex:CopperBufferIndexQTileState];
    }

    // Binds the input slots (E from set `eSet`, H from `hSet`) and, for Q16 kernels, the output slots
    // of the side being written (`outSide` from set `outSet`).
    auto bindFields = [&](int eSet, int hSet, int outSide, int outSet) {
        [encoder setBuffer:_dimsBuffer offset:0 atIndex:CopperBufferIndexDims];
        for (int component = 0; component < 6; ++component) {
            [encoder setBuffer:_fields[component < 3 ? eSet : hSet][component]
                        offset:0
                       atIndex:static_cast<NSUInteger>(CopperBufferIndexEx + component)];
        }
        if (_q16Fields) {
            for (int axis = 0; axis < 3; ++axis) {
                [encoder setBuffer:_fields[outSet][3 * outSide + axis]
                            offset:0
                           atIndex:static_cast<NSUInteger>(CopperBufferIndexOutX + axis)];
            }
        }
    };
    auto bindCoefficients = [&](int side) {
        [encoder setBuffer:_coefficients[side].index offset:0 atIndex:CopperBufferIndexMaterialIndex];
        [encoder setBuffer:_coefficients[side].table offset:0 atIndex:CopperBufferIndexMaterialTable];
        [encoder setBuffer:_coefficients[side].geometry offset:0 atIndex:CopperBufferIndexGeometry];
    };

    // COPPER_FIELD_MIXED: bring one side's tiles (in the set this step reads) to the format their last
    // update asked for. Both sides are done at the start of the step, so a tile's format is fixed for
    // the whole step -- under ping-pong the fused kernel writes H before the H stage would start.
    auto dispatchRetile = [&](int side) {
        if (!_mixedFields || _currentTimestep % _mixedRetileSteps != 0) return;
        [encoder setComputePipelineState:_retilePipeline[side]];
        bindFields(r, r, side, r);
        const CopperQRoundingGPU rounding = qRounding(QStage::Update, side, 31);
        [encoder setBytes:&rounding length:sizeof(rounding) atIndex:CopperBufferIndexQRounding];
        [encoder dispatchThreads:MTLSizeMake(16 * QTiling(_dims).tileCount, 1, 1)
             threadsPerThreadgroup:MTLSizeMake(_qThreadgroupWidth, 1, 1)];
    };

    // The interior update of one side: E reads this step's old E and H; H reads the new E and old H.
    auto dispatchUpdate = [&](int side) {
        [encoder setComputePipelineState:side == 0 ? _updateEPipeline : _updateHPipeline];
        if (_cpmlLines != nil) {
            [encoder setBuffer:_cpmlLines offset:0 atIndex:CopperBufferIndexCPMLLines];
            CopperCPMLGPU layout = _cpmlLayout[side];
            layout.seed = 2 * _currentTimestep + static_cast<std::uint32_t>(side);
            [encoder setBytes:&layout length:sizeof(layout) atIndex:CopperBufferIndexCPMLLayout];
            [encoder setBuffer:_cpmlPsi[side] offset:0 atIndex:CopperBufferIndexCPMLPsi];
        }
        bindFields(side == 0 ? r : w, r, side, w);
        bindCoefficients(side);
        if (_q16Fields) {
            if (_qBlockCount[side] == 0) return;
            [encoder setBuffer:_qBlocks[side] offset:0 atIndex:CopperBufferIndexQBlocks];
            const CopperQRoundingGPU rounding = qRounding(QStage::Update, side, 0);
            [encoder setBytes:&rounding length:sizeof(rounding) atIndex:CopperBufferIndexQRounding];
            [encoder dispatchThreads:MTLSizeMake(16 * _qBlockCount[side], 1, 1)
                 threadsPerThreadgroup:MTLSizeMake(_qThreadgroupWidth, 1, 1)];
            return;
        }
        const MTLSize extent = side == 0 ? eGrid : hGrid;
        for (const auto& box : _dispatchBoxes) {
            if (box.startX >= extent.width || box.startY >= extent.height) continue;
            const NSUInteger width = std::min<NSUInteger>(box.width, extent.width - box.startX);
            const NSUInteger height = std::min<NSUInteger>(box.height, extent.height - box.startY);
            if (width == 0 || height == 0 || extent.depth == 0) continue;
            const CopperDispatchOriginGPU origin{box.startX, box.startY, 0};
            [encoder setBytes:&origin length:sizeof(origin) atIndex:CopperBufferIndexDispatchOrigin];
            [encoder dispatchThreads:MTLSizeMake(width, height, extent.depth) threadsPerThreadgroup:threadsPerThreadgroup];
        }
    };

    // Soft excitation of one side, in place in the set this step writes.
    auto dispatchExcitation = [&](int side) {
        const std::uint32_t count = side == 0 ? _voltageCellCount : _currentCellCount;
        // Under Q16 the fused kernel may own every excited tile.
        if (count == 0 || (_q16Fields && _qExcitationBlockCount[side] == 0)) return;
        section(side == 0 ? "excitation E" : "excitation H");
        [encoder setComputePipelineState:side == 0 ? _applyExcitationEPipeline : _applyExcitationHPipeline];
        bindFields(w, w, side, w);
        [encoder setBuffer:side == 0 ? _voltageCells : _currentCells offset:0 atIndex:CopperBufferIndexExcCells];
        [encoder setBuffer:side == 0 ? _voltageSignal : _currentSignal offset:0 atIndex:CopperBufferIndexExcSignal];
        [encoder setBytes:&excitationParams length:sizeof(excitationParams) atIndex:CopperBufferIndexExcParams];
        if (_q16Fields) {
            [encoder setBuffer:_qExcitationBlocks[side] offset:0 atIndex:CopperBufferIndexQBlocks];
            const CopperQRoundingGPU rounding = qRounding(QStage::Excitation, side, 0);
            [encoder setBytes:&rounding length:sizeof(rounding) atIndex:CopperBufferIndexQExcitationRounding];
            [encoder dispatchThreads:MTLSizeMake(16 * _qExcitationBlockCount[side], 1, 1)
                 threadsPerThreadgroup:MTLSizeMake(32, 1, 1)];
        } else {
            [encoder dispatchThreads:MTLSizeMake(count, 1, 1)
                 threadsPerThreadgroup:MTLSizeMake(std::min<NSUInteger>(tgWidth, count), 1, 1)];
        }
        [encoder memoryBarrierWithScope:MTLBarrierScopeBuffers];
    };

    // Each lumped element's six floats of ADE state, per buffer set.
    auto lumpedStateOffset = [&](int set) {
        return static_cast<NSUInteger>(set) * 6 * _lumpedSorted.size() * sizeof(float);
    };

    // --- Voltage (E) update: [retile] -> [fused E+H] -> interior (with its CPML) -> excitation. ---
    if (encodeVoltage) {
        if (_mixedFields && _currentTimestep % _mixedRetileSteps == 0) {
            section("retile");
            dispatchRetile(0);
            dispatchRetile(1);
            [encoder memoryBarrierWithScope:MTLBarrierScopeBuffers];
            [encoder setComputePipelineState:_nearFloatPipeline];
            [encoder setBuffer:_dimsBuffer offset:0 atIndex:CopperBufferIndexDims];
            const NSUInteger tiles = QTiling(_dims).tileCount;
            [encoder dispatchThreads:MTLSizeMake(tiles, 1, 1)
                 threadsPerThreadgroup:MTLSizeMake(std::min<NSUInteger>(_qThreadgroupWidth, tiles), 1, 1)];
            [encoder memoryBarrierWithScope:MTLBarrierScopeBuffers];
        }
        if (_fused && _fusedSegmentCount > 0) {
            section("fused E+H");
            [encoder setComputePipelineState:_fusedPipeline];
            bindFields(r, r, 0, w);
            for (int axis = 0; axis < 3; ++axis) {
                [encoder setBuffer:_fields[w][3 + axis]
                            offset:0
                           atIndex:static_cast<NSUInteger>(CopperBufferIndexOutHx + axis)];
            }
            bindCoefficients(0);
            [encoder setBuffer:_coefficients[1].index offset:0 atIndex:CopperBufferIndexMaterialIndexH];
            [encoder setBuffer:_coefficients[1].table offset:0 atIndex:CopperBufferIndexMaterialTableH];
            [encoder setBuffer:_coefficients[1].geometry offset:0 atIndex:CopperBufferIndexGeometryH];
            [encoder setBuffer:_fusedSegments offset:0 atIndex:CopperBufferIndexQBlocks];
            const CopperQRoundingGPU rounding = qRounding(QStage::Update, 0, 30);
            [encoder setBytes:&rounding length:sizeof(rounding) atIndex:CopperBufferIndexFusedRounding];
            // Its E corrections; any it doesn't have are bound to a stand-in it never reads.
            auto orNone = [&](id<MTLBuffer> buffer) { return buffer != nil ? buffer : _dimsBuffer; };
            [encoder setBuffer:orNone(_voltageCells) offset:0 atIndex:CopperBufferIndexExcCells];
            [encoder setBuffer:orNone(_voltageSignal) offset:0 atIndex:CopperBufferIndexExcSignal];
            [encoder setBytes:&excitationParams length:sizeof(excitationParams) atIndex:CopperBufferIndexExcParams];
            [encoder setBuffer:orNone(_lumpedCells) offset:0 atIndex:CopperBufferIndexFusedLumpedCells];
            [encoder setBuffer:orNone(_lumpedState)
                        offset:_lumpedState != nil ? lumpedStateOffset(r) : 0
                       atIndex:CopperBufferIndexFusedLumpedState];
            [encoder setBuffer:orNone(_lumpedState)
                        offset:_lumpedState != nil ? lumpedStateOffset(w) : 0
                       atIndex:CopperBufferIndexFusedLumpedStateOut];
            [encoder setBuffer:orNone(_fusedCorrectionList) offset:0 atIndex:CopperBufferIndexFusedCorrections];
            [encoder setBuffer:orNone(_fusedCorrectionOffsets) offset:0 atIndex:CopperBufferIndexFusedCorrectionOffsets];
            // One 288-thread threadgroup per segment (see CopperFDTD.metal's fusedEH).
            [encoder dispatchThreadgroups:MTLSizeMake(_fusedSegmentCount, 1, 1)
                    threadsPerThreadgroup:MTLSizeMake(288, 1, 1)];
        }
        section("update E");
        dispatchUpdate(0);

        // Excitation adds to the fields this dispatch just wrote.
        [encoder memoryBarrierWithScope:MTLBarrierScopeBuffers];

        // update_h_interior (next) reads the E buffer this writes into additively.
        dispatchExcitation(0);

        // GPU lumped RLC, in place on the new E -- where a MidStepCorrection would land.
        if (_lumpedGroupCount > 0) {
            section("lumped RLC");
            [encoder setComputePipelineState:_lumpedPipeline];
            bindFields(w, w, 0, w);
            [encoder setBuffer:_lumpedCells offset:0 atIndex:CopperBufferIndexLumpedCells];
            [encoder setBuffer:_lumpedState offset:lumpedStateOffset(r) atIndex:CopperBufferIndexLumpedState];
            [encoder setBuffer:_lumpedState offset:lumpedStateOffset(w) atIndex:CopperBufferIndexLumpedStateOut];
            [encoder setBuffer:_lumpedGroups offset:0 atIndex:CopperBufferIndexLumpedGroups];
            if (_q16Fields) {
                const CopperQRoundingGPU rounding = qRounding(QStage::Excitation, 0, 1);
                [encoder setBytes:&rounding length:sizeof(rounding) atIndex:CopperBufferIndexQExcitationRounding];
                [encoder dispatchThreads:MTLSizeMake(16 * _lumpedGroupCount, 1, 1)
                     threadsPerThreadgroup:MTLSizeMake(32, 1, 1)];
            } else {
                [encoder dispatchThreads:MTLSizeMake(_lumpedGroupCount, 1, 1)
                     threadsPerThreadgroup:MTLSizeMake(std::min<NSUInteger>(tgWidth, _lumpedGroupCount), 1, 1)];
            }
            [encoder memoryBarrierWithScope:MTLBarrierScopeBuffers];
        }
    }

    // --- Current (H) update: interior (with its CPML) -> excitation. ---
    if (encodeCurrent) {
        section("update H");
        dispatchUpdate(1);

        // Excitation adds to the fields this dispatch just wrote.
        [encoder memoryBarrierWithScope:MTLBarrierScopeBuffers];

        dispatchExcitation(1);

        // Next iteration's update_e_interior reads whatever this
        // iteration's H update (and any PML/excitation on top of it) wrote --
        // covered by the barrier below.
        [encoder memoryBarrierWithScope:MTLBarrierScopeBuffers];

        ++_currentTimestep;
    }
}

void MetalEngineImpl::run(std::uint32_t steps) {
    // Copper is normally driven from a long-lived C++ worker thread, which does not establish an
    // AppKit run-loop autorelease pool of its own. Metal returns autoreleased command buffers and
    // encoder-side helper objects; without a local pool those completed objects remain queued in
    // the thread's outer pool for the duration of the simulation.
    prepareDispatchLists();
    @autoreleasepool {
        id<MTLCommandBuffer> commandBuffer = [_queue commandBuffer];
        id<MTLComputeCommandEncoder> encoder = [commandBuffer computeCommandEncoderWithDispatchType:_dispatchType];
        _encodingCommandBuffer = commandBuffer;

        for (std::uint32_t step = 0; step < steps; ++step) {
            encodeIterationPhase(encoder, IterationPhase::Full);
        }

        [encoder endEncoding];
        [commandBuffer commit];
        [commandBuffer waitUntilCompleted];
        _executedTimestep = _currentTimestep;

        if (commandBuffer.error != nil) {
            throw std::runtime_error("CopperEngine::run: Metal command buffer failed: " +
                                     std::string(commandBuffer.error.localizedDescription.UTF8String));
        }
    }
}

void MetalEngineImpl::runWithProbeSampling(std::uint32_t steps, const CopperEngine::ProbeSampler& sampler,
                                            const CopperEngine::MidStepCorrection& midStepCorrection) {
    prepareDispatchLists();
    // EXPERIMENT (COPPER_PIPELINE=0): the original encode-commit-wait loop, for comparison.
    const char* pipelineEnv = std::getenv("COPPER_PIPELINE");
    const bool serial = _profile.enabled || _captureStep != UINT32_MAX;
    if (!serial && (pipelineEnv == nullptr || std::string(pipelineEnv) != "0")) {
        runWithProbeSamplingPipelined(steps, sampler, midStepCorrection);
        return;
    }
    for (std::uint32_t step = 0; step < steps; ++step) {
        bool shouldContinue = true;
        @autoreleasepool {
            const bool capturing = _currentTimestep == _captureStep;
            if (capturing) {
                MTLCaptureDescriptor* capture = [MTLCaptureDescriptor new];
                capture.captureObject = _queue;
                capture.destination = MTLCaptureDestinationGPUTraceDocument;
                capture.outputURL = [NSURL fileURLWithPath:[NSString stringWithUTF8String:_capturePath.c_str()]];
                NSError* captureError = nil;
                if (![[MTLCaptureManager sharedCaptureManager] startCaptureWithDescriptor:capture error:&captureError]) {
                    std::fprintf(stderr, "Copper: GPU capture failed to start: %s\n",
                                 captureError.localizedDescription.UTF8String);
                }
            }
            auto runPhase = [&](IterationPhase phase, const char* phaseName) {
                id<MTLCommandBuffer> commandBuffer = [_queue commandBuffer];
                id<MTLComputeCommandEncoder> encoder = [commandBuffer computeCommandEncoderWithDispatchType:_dispatchType];
                _encodingCommandBuffer = commandBuffer;
                encodeIterationPhase(encoder, phase);
                [encoder endEncoding];
                [commandBuffer commit];
                [commandBuffer waitUntilCompleted];
                if (_profile.enabled) _profile.resolve(_device);
                _stepTiming.completed(commandBuffer, phase == IterationPhase::Current ? 1 : 0);

                if (commandBuffer.error != nil) {
                    throw std::runtime_error(
                        std::string("CopperEngine::runWithProbeSampling ") + phaseName +
                        " command buffer failed: " +
                        std::string(commandBuffer.error.localizedDescription.UTF8String));
                }
            };

            if (midStepCorrection) {
                // Waiting here is the GPU->CPU fence for MTLStorageModeShared field
                // buffers. The CPU correction writes those same shared bytes; committing
                // the Current phase afterward is the corresponding CPU->GPU ordering
                // point, so update_h_interior sees the correction in this timestep rather
                // than one timestep late.
                runPhase(IterationPhase::Voltage, "voltage");
                _inMidStep = true;
                midStepCorrection();
                _inMidStep = false;
                runPhase(IterationPhase::Current, "current");
            } else {
                runPhase(IterationPhase::Full, "full-iteration");
            }
            _executedTimestep = _currentTimestep;
            if (capturing) {
                [[MTLCaptureManager sharedCaptureManager] stopCapture];
                std::fprintf(stderr, "Copper: GPU capture of timestep %u written to %s\n", _captureStep,
                             _capturePath.c_str());
            }
            if (_profile.enabled) _profile.stepDone(_device);

            const auto s0 = std::chrono::steady_clock::now();
            shouldContinue = sampler(_currentTimestep);
            _stepTiming.sampler += std::chrono::duration<double>(std::chrono::steady_clock::now() - s0).count();
            _stepTiming.stepDone("serial");
        }
        if (!shouldContinue) {
            break;
        }
    }
}

MetalEngineImpl::EncodedStep MetalEngineImpl::encodeStep(bool splitAtCorrection) {
    EncodedStep step;
    step.first = [_queue commandBuffer];
    id<MTLComputeCommandEncoder> encoder = [step.first computeCommandEncoderWithDispatchType:_dispatchType];
    _encodingCommandBuffer = step.first;
    encodeIterationPhase(encoder, splitAtCorrection ? IterationPhase::Voltage : IterationPhase::Full);
    [encoder endEncoding];
    if (splitAtCorrection) {
        step.correctionValue = ++_correctionEventValue;
        step.current = [_queue commandBuffer];
        [step.current encodeWaitForEvent:_correctionEvent value:step.correctionValue];
        encoder = [step.current computeCommandEncoderWithDispatchType:_dispatchType];
        _encodingCommandBuffer = step.current;
        encodeIterationPhase(encoder, IterationPhase::Current);
        [encoder endEncoding];
    }
    return step;
}

void MetalEngineImpl::runWithProbeSamplingPipelined(std::uint32_t steps, const CopperEngine::ProbeSampler& sampler,
                                                    const CopperEngine::MidStepCorrection& midStepCorrection) {
    if (steps == 0) return;
    const bool split = static_cast<bool>(midStepCorrection);
    auto check = [](id<MTLCommandBuffer> commandBuffer, const char* phaseName) {
        if (commandBuffer.error != nil) {
            throw std::runtime_error(std::string("CopperEngine::runWithProbeSampling ") + phaseName +
                                     " command buffer failed: " +
                                     std::string(commandBuffer.error.localizedDescription.UTF8String));
        }
    };
    auto commit = [](const EncodedStep& step) {
        [step.first commit];
        // Queued straight away: the event wait holds it until the correction lands.
        if (step.current != nil) [step.current commit];
    };

    // Encoding advances _currentTimestep, so it runs one step ahead of what has executed; the
    // sampler is handed the executed count, as before.
    std::uint32_t completedTimestep = _currentTimestep;
    EncodedStep next;
    @autoreleasepool {
        next = encodeStep(split);
    }
    commit(next);
    for (std::uint32_t step = 0; step < steps; ++step) {
        bool shouldContinue = true;
        @autoreleasepool {
            const EncodedStep current = next;
            next = EncodedStep{};
            if (split) {
                // GPU->CPU: the correction reads and writes the voltage phase's shared-memory
                // results. CPU->GPU: the current phase is already queued behind the event.
                [current.first waitUntilCompleted];
                check(current.first, "voltage");
                _stepTiming.completed(current.first, 0);
                _inMidStep = true;
                midStepCorrection();
                _inMidStep = false;
                _correctionEvent.signaledValue = current.correctionValue;
            }

            // Encode the next step while the GPU works through this one's current phase. It isn't
            // committed until the sampler has seen this step and asked to continue: once committed
            // it can't be withdrawn, and a stopped run must leave the fields at the step it
            // stopped on.
            const bool more = step + 1 < steps;
            if (more) next = encodeStep(split);

            id<MTLCommandBuffer> last = split ? current.current : current.first;
            [last waitUntilCompleted];
            check(last, split ? "current" : "full-iteration");
            _stepTiming.completed(last, split ? 1 : 0);
            ++completedTimestep;
            _executedTimestep = completedTimestep;
            snapshotIfRequested(completedTimestep);
            if (_mixedFields && _stepTiming.enabled && completedTimestep % 1000 == 0) printMixedStats(completedTimestep);

            const auto s0 = std::chrono::steady_clock::now();
            shouldContinue = sampler(completedTimestep);
            _stepTiming.sampler += std::chrono::duration<double>(std::chrono::steady_clock::now() - s0).count();
            _stepTiming.stepDone("pipelined");

            if (more) {
                if (shouldContinue) {
                    commit(next);
                } else {
                    // Drop the uncommitted step; its correction event value is simply never used.
                    next = EncodedStep{};
                    --_currentTimestep;
                }
            }
        }
        if (!shouldContinue) break;
    }
    if (_currentTimestep != completedTimestep) {
        throw std::logic_error("CopperEngine: pipelined run left the encoded and executed timesteps out of step");
    }
}

void MetalEngineImpl::KernelProfile::resolve(id<MTLDevice> device) {
    if (sections.empty()) return;
    NSData* data = [samples resolveCounterRange:NSMakeRange(0, 2 * sections.size())];
    const auto* stamps = static_cast<const MTLCounterResultTimestamp*>(data.bytes);
    MTLTimestamp cpu = 0, gpu = 0;
    [device sampleTimestamps:&cpu gpuTimestamp:&gpu];
    // GPU timestamp ticks to seconds, from how far the CPU (ns) and GPU clocks have run since the start.
    const double secondsPerTick =
        gpu > gpu0 ? 1e-9 * static_cast<double>(cpu - cpu0) / static_cast<double>(gpu - gpu0) : 1e-9;
    for (const auto& [name, start] : sections) {
        const MTLTimestamp begin = stamps[start].timestamp, end = stamps[start + 1].timestamp;
        if (begin == MTLCounterErrorValue || end == MTLCounterErrorValue || end < begin) continue;
        auto it = std::find_if(totals.begin(), totals.end(), [&](const auto& t) { return t.first == name; });
        if (it == totals.end()) it = totals.insert(totals.end(), {name, 0.0});
        it->second += secondsPerTick * static_cast<double>(end - begin);
    }
    sections.clear();
}

void MetalEngineImpl::KernelProfile::stepDone(id<MTLDevice>) {
    if (++steps % 100 != 0) return;
    double total = 0.0;
    for (const auto& [name, seconds] : totals) total += seconds;
    std::string line;
    for (const auto& [name, seconds] : totals) {
        char part[96];
        std::snprintf(part, sizeof(part), " | %s %.3f", name.c_str(), 1e3 * seconds / 100.0);
        line += part;
    }
    std::fprintf(stderr, "Copper: kernel profile over 100 steps (GPU ms/step): total %.3f%s\n", 1e3 * total / 100.0,
                 line.c_str());
    totals.clear();
}

void MetalEngineImpl::StepTiming::stepDone(const char* label) {
    if (!enabled) return;
    if (++steps % 100 != 0) return;
    const double wall = std::chrono::duration<double>(std::chrono::steady_clock::now() - start).count();
    const double n = steps;
    std::fprintf(stderr,
                 "Copper: GPU timing (%s) over %u steps: wall %.2f ms/step | GPU busy %.2f + %.2f | GPU idle before "
                 "first CB %.2f, before current CB %.2f | sampler %.2f (ms/step)\n",
                 label, steps, 1e3 * wall / n, 1e3 * busy[0] / n, 1e3 * busy[1] / n, 1e3 * idle[0] / n,
                 1e3 * idle[1] / n, 1e3 * sampler / n);
    busy[0] = busy[1] = idle[0] = idle[1] = sampler = 0;
    steps = 0;
    start = std::chrono::steady_clock::now();
}

void MetalEngineImpl::prepareDispatchLists() {
    if (!_listsDirty) return;
    _listsDirty = false;
    const QTiling tiling(_dims);
    const std::uint32_t nx = _dims.nx, ny = _dims.ny, nz = _dims.nz;

    std::vector<std::uint8_t> fusedTile(tiling.tileCount, 0);
    std::vector<CopperQSegmentGPU> segments;
    if (_fused) {
        // Cells whose E (side 0) or H (side 1) the fused kernel can't update, nor use as halo: the
        // CPML's, which it doesn't apply, and those corrected between the E and H updates.
        std::vector<std::uint8_t> special[2] = {std::vector<std::uint8_t>(_dims.cellCount(), 0),
                                                std::vector<std::uint8_t>(_dims.cellCount(), 0)};
        if (_cpmlLines != nil) {
            for (std::uint32_t z = 0; z < nz; ++z) {
                for (std::uint32_t y = 0; y < ny; ++y) {
                    for (std::uint32_t x = 0; x < nx; ++x) {
                        if (_cpmlLine[0][x] | _cpmlLine[1][y] | _cpmlLine[2][z]) {
                            special[0][copperGridIndex(_dims, x, y, z)] = 1;
                            special[1][copperGridIndex(_dims, x, y, z)] = 1;
                        }
                    }
                }
            }
        }
        // The fused kernel applies voltage excitation and GPU lumped RLC itself (_fusedCorrections);
        // current excitation and the CPU's mid-step corrections it can't.
        for (int side = _fusedCorrections ? 1 : 0; side < 2; ++side) {
            for (const CopperExcitationCell& cell : _excitationCells[side]) {
                special[side][copperGridIndex(_dims, cell.x, cell.y, cell.z)] = 1;
            }
        }
        for (const CopperLumpedRLCCell& cell : _correctedCells) special[0][copperGridIndex(_dims, cell.x, cell.y, cell.z)] = 1;
        if (!_fusedCorrections) {
            for (const CopperLumpedRLCCell& cell : _lumpedRLC) special[0][copperGridIndex(_dims, cell.x, cell.y, cell.z)] = 1;
        }
        auto isSpecial = [&](int side, std::uint32_t x, std::uint32_t y, std::uint32_t z) {
            return x < nx && y < ny && special[side][copperGridIndex(_dims, x, y, z)] != 0;
        };
        // A tile plane's E can be computed in-kernel if neither the tile nor its +x/+y halo needs a
        // correction; its H if the tile doesn't, and the E of the plane above can be computed too.
        auto plainE = [&](std::uint32_t x0, std::uint32_t y0, std::uint32_t z) {
            for (std::uint32_t j = 0; j < 5; ++j) {
                for (std::uint32_t i = 0; i < 5; ++i) {
                    if (i == 4 && j == 4) continue;
                    if (isSpecial(0, x0 + i, y0 + j, z)) return false;
                }
            }
            return true;
        };
        auto plainH = [&](std::uint32_t x0, std::uint32_t y0, std::uint32_t z) {
            for (std::uint32_t j = 0; j < 4; ++j) {
                for (std::uint32_t i = 0; i < 4; ++i) {
                    if (isSpecial(1, x0 + i, y0 + j, z)) return false;
                }
            }
            return true;
        };
        // Per tile, whether the fused kernel can own it; then per 4x4-tile footprint, runs of planes
        // with the same set of owned tiles become segments.
        std::vector<std::uint8_t> eOK(nz), ok(tiling.tileCount, 0);
        for (std::uint32_t ty = 0; ty < tiling.tilesY; ++ty) {
            for (std::uint32_t tx = 0; tx < tiling.tilesX; ++tx) {
                const std::uint32_t x0 = 4 * tx, y0 = 4 * ty;
                for (std::uint32_t z = 0; z < nz; ++z) eOK[z] = plainE(x0, y0, z);
                for (std::uint32_t z = 0; z < nz; ++z) {
                    ok[tiling.tile(x0, y0, z)] = eOK[z] && plainH(x0, y0, z) && (z + 1 >= nz || eOK[z + 1]);
                }
            }
        }
        auto ownedMask = [&](std::uint32_t fx, std::uint32_t fy, std::uint32_t z) {
            std::uint32_t mask = 0;
            for (std::uint32_t j = 0; j < 4; ++j) {
                for (std::uint32_t i = 0; i < 4; ++i) {
                    const std::uint32_t tx = fx + i, ty = fy + j;
                    if (tx < tiling.tilesX && ty < tiling.tilesY && ok[tiling.tile(4 * tx, 4 * ty, z)]) {
                        mask |= 1U << (i + 4 * j);
                    }
                }
            }
            return mask;
        };
        for (std::uint32_t fy = 0; fy < tiling.tilesY; fy += 4) {
            for (std::uint32_t fx = 0; fx < tiling.tilesX; fx += 4) {
                for (std::uint32_t z = 0; z < nz;) {
                    const std::uint32_t mask = ownedMask(fx, fy, z);
                    if (mask == 0) {
                        ++z;
                        continue;
                    }
                    const std::uint32_t z0 = z;
                    while (z < nz && ownedMask(fx, fy, z) == mask && z - z0 < _fusedChunk) {
                        for (std::uint32_t bit = 0; bit < 16; ++bit) {
                            if ((mask >> bit) & 1U) fusedTile[tiling.tile(4 * (fx + bit % 4), 4 * (fy + bit / 4), z)] = 1;
                        }
                        ++z;
                    }
                    segments.push_back({fx, fy, z0, z, mask});
                }
            }
        }
        _fusedSegmentCount = segments.size();
        _fusedTiles = static_cast<std::size_t>(std::count(fusedTile.begin(), fusedTile.end(), 1));
        _fusedSegments = segments.empty() ? nil
                                          : [_device newBufferWithBytes:segments.data()
                                                                 length:segments.size() * sizeof(CopperQSegmentGPU)
                                                                options:MTLResourceStorageModeShared];
        std::fprintf(stderr, "Copper: fused E+H kernel takes %zu of %zu tiles (%.1f%%) in %zu segments\n", _fusedTiles,
                     tiling.tileCount, 100.0 * static_cast<double>(_fusedTiles) / static_cast<double>(tiling.tileCount),
                     segments.size());
    }

    std::vector<TileBox> domain;
    for (const auto& box : _dispatchBoxes) {
        domain.push_back({box.startX, box.startY, 0, box.startX + box.width, box.startY + box.height, nz});
    }
    for (int side = 0; side < (_q16Fields ? 2 : 0); ++side) {
        const std::vector<CopperQBlockGPU> blocks =
            buildTileList(_dims, domain, side, [&](std::size_t tile) { return fusedTile[tile] != 0; });
        _qBlockCount[side] = blocks.size();
        _qBlocks[side] = blocks.empty() ? nil
                                        : [_device newBufferWithBytes:blocks.data()
                                                               length:blocks.size() * sizeof(CopperQBlockGPU)
                                                              options:MTLResourceStorageModeShared];
    }

    // MIXED: tiles the CPU corrects every step stay fp32 -- a single-cell write is then just a store,
    // not a whole-tile re-encode on the CPU.
    if (_mixedFields) {
        const QTileStateView state = tileStateView();
        std::uint8_t* pinned = state.pinned(0);
        std::fill(pinned, pinned + state.tileCount, 0);
        if (const char* all = std::getenv("COPPER_MIXED_PIN_ALL"); all != nullptr && std::string(all) == "1") {
            std::fill(pinned, pinned + 2 * state.tileCount, 1);
        }
        for (const std::vector<CopperLumpedRLCCell>* cells : {&_correctedCells, &_lumpedRLC}) {
            for (const CopperLumpedRLCCell& cell : *cells) pinned[tiling.tile(cell.x, cell.y, cell.z)] = 1;
        }
    }

    // Whether the fused kernel owns (and corrects) a tile's E, so the separate kernels must skip it.
    auto fusedOwns = [&](std::size_t tile) { return _fused && _fusedCorrections && fusedTile[tile] != 0; };

    // Q16 excitation: the sorted cells grouped by (component, tile), one tile per half SIMD group.
    for (int side = 0; side < (_q16Fields ? 2 : 0); ++side) {
        const std::vector<CopperExcitationCell>& cells = _excitationCells[side];
        std::vector<CopperQExcitationBlockGPU> blocks;
        for (std::uint32_t i = 0; i < cells.size(); ++i) {
            const std::size_t tile = tiling.tile(cells[i].x, cells[i].y, cells[i].z);
            if (side == 0 && fusedOwns(tile)) continue;
            if (blocks.empty() || blocks.back().axis != cells[i].axis || blocks.back().block != tile ||
                blocks.back().first + blocks.back().count != i) {
                blocks.push_back({static_cast<std::uint32_t>(tile), cells[i].axis, i, 0});
            }
            ++blocks.back().count;
        }
        _qExcitationBlockCount[side] = blocks.size();
        _qExcitationBlocks[side] = blocks.empty() ? nil
                                                  : [_device newBufferWithBytes:blocks.data()
                                                                         length:blocks.size() * sizeof(CopperQExcitationBlockGPU)
                                                                        options:MTLResourceStorageModeShared];
    }

    if (_profile.enabled) {
        std::fprintf(stderr, "Copper: profile lists: excitation groups E %lu H %lu, lumped groups %zu, fused segments %lu\n",
                     static_cast<unsigned long>(_qExcitationBlockCount[0]), static_cast<unsigned long>(_qExcitationBlockCount[1]),
                     _lumpedRLC.size(), static_cast<unsigned long>(_fusedSegmentCount));
    }
    // GPU lumped RLC: elements sorted into groups, each with fresh (zero) ADE state -- two copies under
    // ping-pong, one read and one written each step.
    _lumpedGroupCount = 0;
    _lumpedCells = _lumpedState = _lumpedGroups = nil;
    _lumpedSorted.clear();
    if (!_lumpedRLC.empty()) {
        static_assert(sizeof(CopperLumpedRLCCell) == sizeof(CopperLumpedRLCCellGPU),
                      "copper::CopperLumpedRLCCell must stay layout-compatible with CopperLumpedRLCCellGPU");
        auto key = [&](const CopperLumpedRLCCell& cell) {
            const std::size_t place = _q16Fields ? tiling.tile(cell.x, cell.y, cell.z)
                                                 : copperGridIndex(_dims, cell.x, cell.y, cell.z);
            return std::pair(cell.axis, place);
        };
        std::vector<CopperLumpedRLCCell> sorted = _lumpedRLC;
        std::stable_sort(sorted.begin(), sorted.end(), [&](const auto& a, const auto& b) { return key(a) < key(b); });
        _lumpedSorted = sorted;
        std::vector<CopperQExcitationBlockGPU> groups;
        for (std::uint32_t i = 0; i < sorted.size(); ++i) {
            const auto [axis, place] = key(sorted[i]);
            if (_q16Fields && fusedOwns(place)) continue;
            if (groups.empty() || groups.back().axis != axis || groups.back().block != place ||
                groups.back().first + groups.back().count != i) {
                groups.push_back({static_cast<std::uint32_t>(place), axis, i, 0});
            }
            ++groups.back().count;
        }
        _lumpedGroupCount = groups.size();
        _lumpedCells = [_device newBufferWithBytes:sorted.data()
                                            length:sorted.size() * sizeof(CopperLumpedRLCCell)
                                           options:MTLResourceStorageModeShared];
        _lumpedState = makeZeroedBuffer(_device, 6 * sorted.size() * (_pingPong ? 2 : 1));
        _lumpedGroups = groups.empty() ? nil
                                       : [_device newBufferWithBytes:groups.data()
                                                              length:groups.size() * sizeof(CopperQExcitationBlockGPU)
                                                             options:MTLResourceStorageModeShared];
    }

    // The fused kernel's E corrections: every voltage excitation cell and lumped element, by tile --
    // halo lanes need their neighbours' too -- excitation before lumped, as the separate kernels go.
    if (_fused && _fusedCorrections) {
        std::vector<std::pair<std::size_t, CopperFusedCorrectionGPU>> entries;
        for (std::uint32_t i = 0; i < _excitationCells[0].size(); ++i) {
            const CopperExcitationCell& cell = _excitationCells[0][i];
            entries.push_back({tiling.tile(cell.x, cell.y, cell.z), {QTiling::lane(cell.x, cell.y), cell.axis, 0, i}});
        }
        for (std::uint32_t i = 0; i < _lumpedSorted.size(); ++i) {
            const CopperLumpedRLCCell& cell = _lumpedSorted[i];
            entries.push_back({tiling.tile(cell.x, cell.y, cell.z), {QTiling::lane(cell.x, cell.y), cell.axis, 1, i}});
        }
        std::stable_sort(entries.begin(), entries.end(), [](const auto& a, const auto& b) {
            return std::pair(a.first, a.second.kind) < std::pair(b.first, b.second.kind);
        });
        std::vector<std::uint32_t> offsets(tiling.tileCount + 1, 0);
        std::vector<CopperFusedCorrectionGPU> list;
        for (const auto& [tile, entry] : entries) {
            ++offsets[tile + 1];
            list.push_back(entry);
        }
        for (std::size_t t = 0; t < tiling.tileCount; ++t) offsets[t + 1] += offsets[t];
        if (list.empty()) list.push_back({});
        _fusedCorrectionList = [_device newBufferWithBytes:list.data()
                                                    length:list.size() * sizeof(CopperFusedCorrectionGPU)
                                                   options:MTLResourceStorageModeShared];
        _fusedCorrectionOffsets = [_device newBufferWithBytes:offsets.data()
                                                       length:offsets.size() * sizeof(std::uint32_t)
                                                      options:MTLResourceStorageModeShared];
    }
}

void MetalEngineImpl::printMixedStats(std::uint32_t timestep) const {
    const QTileStateView state = tileStateView();
    std::size_t promoted[2] = {0, 0};
    for (int side = 0; side < 2; ++side) {
        const std::uint8_t* format = state.format(side);
        for (std::size_t t = 0; t < state.tileCount; ++t) promoted[side] += format[t] != 0;
    }
    const auto* peak = reinterpret_cast<const float*>(state.base);
    const auto tiles = static_cast<double>(state.tileCount);
    std::fprintf(stderr, "Copper: mixed tiles at step %u: fp32 E %.2f%%, H %.2f%% (peaks E %.3e, H %.3e)\n", timestep,
                 100.0 * static_cast<double>(promoted[0]) / tiles, 100.0 * static_cast<double>(promoted[1]) / tiles,
                 static_cast<double>(peak[0]), static_cast<double>(peak[1]));
}

void MetalEngineImpl::snapshotIfRequested(std::uint32_t timestep) const {
    if (_snapshotDir.empty() || _snapshotSteps.count(timestep) == 0) return;
    std::filesystem::create_directories(_snapshotDir);
    const auto writeFile = [](const std::filesystem::path& path, const void* data, std::size_t bytes) {
        if (FILE* file = std::fopen(path.c_str(), "wb")) {
            std::fwrite(data, 1, bytes, file);
            std::fclose(file);
        }
    };
    const std::filesystem::path grid = _snapshotDir / "grid.txt";
    if (!std::filesystem::exists(grid)) {
        const std::string text = std::to_string(_dims.nx) + " " + std::to_string(_dims.ny) + " " +
                                 std::to_string(_dims.nz) + " " + (_wideIndex[0] ? "u32" : "u16") + " " +
                                 (_wideIndex[1] ? "u32" : "u16") + " " + (_q16Fields ? "q16" : (_halfFields ? "f16" : "f32")) + "\n";
        writeFile(grid, text.data(), text.size());
        for (int side = 0; side < 2; ++side) {
            const char* name = side == 0 ? "E" : "H";
            writeFile(_snapshotDir / (std::string("index_") + name + ".bin"), _coefficients[side].index.contents,
                      _coefficients[side].index.length);
            writeFile(_snapshotDir / (std::string("table_") + name + ".bin"), _coefficients[side].table.contents,
                      _coefficients[side].table.length);
        }
    }
    const std::filesystem::path path = _snapshotDir / ("step_" + std::to_string(timestep) + ".f32");
    if (std::filesystem::exists(path)) return;
    FILE* file = std::fopen(path.c_str(), "wb");
    if (file == nullptr) return;
    std::vector<float> values;
    for (int f = 0; f < 6; ++f) {
        readField(static_cast<CopperEngine::Field>(f), values);
        std::fwrite(values.data(), sizeof(float), values.size(), file);
    }
    std::fclose(file);
    // The CPML's psi as stored, E side then H side, laid out as cpml.bin (a CopperCPMLGPU) says.
    if (_cpmlPsi[0] != nil) {
        writeFile(_snapshotDir / "cpml.bin", &_cpmlLayout[0], sizeof(_cpmlLayout[0]));
        writeFile(_snapshotDir / "cpml_lines.bin", _cpmlLines.contents, _cpmlLines.length);
        const std::filesystem::path psiPath = _snapshotDir / ("psi_" + std::to_string(timestep) + ".bin");
        if (FILE* psiFile = std::fopen(psiPath.c_str(), "wb")) {
            for (id<MTLBuffer> psi : _cpmlPsi) std::fwrite(psi.contents, 1, psi.length, psiFile);
            std::fclose(psiFile);
        }
    }
    std::fprintf(stderr, "Copper: snapshot of timestep %u written to %s\n", timestep, path.c_str());
}

void MetalEngineImpl::readField(CopperEngine::Field field, std::vector<float>& destination) const {
    const void* contents = fieldBuffer(field).contents;
    if (_q16Fields) {
        const QFieldView view = fieldView(field);
        destination.resize(_dims.cellCount());
        std::size_t i = 0;
        for (std::uint32_t z = 0; z < _dims.nz; ++z) {
            for (std::uint32_t y = 0; y < _dims.ny; ++y) {
                for (std::uint32_t x = 0; x < _dims.nx; ++x) destination[i++] = view.get(x, y, z);
            }
        }
        return;
    }
    if (_halfFields) {
        destination.resize(_dims.cellCount());
        widenHalf(contents, destination.data(), destination.size());
        return;
    }
    const auto* data = static_cast<const float*>(contents);
    destination.assign(data, data + _dims.cellCount());
}

float MetalEngineImpl::readFieldCell(CopperEngine::Field field, std::uint32_t x, std::uint32_t y,
                                      std::uint32_t z) const {
    const void* contents = fieldBuffer(field).contents;
    const std::size_t index = copperGridIndex(_dims, x, y, z);
    if (_q16Fields) return fieldView(field).get(x, y, z);
    if (_halfFields) return static_cast<const __fp16*>(contents)[index];
    return static_cast<const float*>(contents)[index];
}

void MetalEngineImpl::writeFieldCell(CopperEngine::Field field, std::uint32_t x, std::uint32_t y, std::uint32_t z,
                                      float value) {
    void* contents = fieldBuffer(field).contents;
    const std::size_t index = copperGridIndex(_dims, x, y, z);
    if (_q16Fields) {
        // Re-encodes the cell's whole tile around the new value -- unless it's a MIXED tile living in
        // fp32, which just takes the value.
        const QFieldView view = fieldView(field);
        const std::size_t tile = view.tiling.tile(x, y, z);
        if (view.isFloat(tile)) {
            view.f[16 * tile + QTiling::lane(x, y)] = value;
            return;
        }
        const std::uint32_t x0 = x & ~3U, y0 = y & ~3U;
        float values[16];
        bool valid[16];
        for (std::uint32_t lane = 0; lane < 16; ++lane) {
            valid[lane] = x0 + lane % 4 < _dims.nx && y0 + lane / 4 < _dims.ny;
            values[lane] = valid[lane] ? view.getStored(16 * tile + lane) : 0.0F;
        }
        values[QTiling::lane(x, y)] = value;
        qEncodeTile(view, tile, values, valid);
    } else if (_halfFields) {
        static_cast<__fp16*>(contents)[index] = static_cast<__fp16>(value);
    } else {
        static_cast<float*>(contents)[index] = value;
    }
}

double MetalEngineImpl::estimateEnergy() const {
    // EXPERIMENT (COPPER_GPU_TIMING=1): how long the GPU sits idle behind this.
    struct Timer {
        bool enabled;
        std::chrono::steady_clock::time_point start = std::chrono::steady_clock::now();
        ~Timer() {
            if (enabled)
                std::fprintf(stderr, "Copper: estimateEnergy took %.1f ms\n",
                             1e3 * std::chrono::duration<double>(std::chrono::steady_clock::now() - start).count());
        }
    } timer{_stepTiming.enabled};
    // vDSP_svesq's own accumulator is float32 -- for a large/energetic grid the true sum of squares
    // legitimately reaches into the 1e38 range (confirmed on a real board: 3.49e38, right at
    // float32's ~3.4e38 ceiling), so a float32 accumulator spuriously overflows to inf/nan even
    // when every individual field value is still perfectly finite and physically reasonable. Convert
    // to double first (vDSP_vspdp) and sum in double (vDSP_svesqD) so this can't happen for any grid
    // size this engine could plausibly be asked to run.
    //
    // This runs inside the probe sampler, and the next timestep isn't committed until the sampler
    // returns, so the GPU sits idle for all of it. The original single-threaded pass over the six
    // fields took ~210 ms on a 100M-cell board -- converting and summing 2.4 GB of floats on one
    // core, not allocating its buffer (reusing that buffer saved ~3 ms). Each field is instead split
    // into a fixed number of blocks summed in parallel, each converting through a stack buffer, so
    // nothing is allocated and the partial sums fit on the stack (~14 ms).
    constexpr std::size_t blocksPerField = 64;
    constexpr std::size_t chunk = 8192;
    const std::size_t n = _dims.cellCount();
    const std::size_t blockLength = (n + blocksPerField - 1) / blocksPerField;
    std::array<const void*, 6> fields{};
    for (std::size_t f = 0; f < 6; ++f) fields[f] = fieldBuffer(static_cast<CopperEngine::Field>(f)).contents;
    const bool halfFields = _halfFields, q16Fields = _q16Fields;
    std::array<QFieldView, 6> qViews{};
    if (q16Fields) {
        for (std::size_t f = 0; f < 6; ++f) qViews[f] = fieldView(static_cast<CopperEngine::Field>(f));
    }
    const QFieldView* const qViewPointer = qViews.data();
    const CopperGridDims dimsCopy = _dims;
    std::array<double, 6 * blocksPerField> partial{};
    double* const partialSums = partial.data();
    dispatch_apply(partial.size(), dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^(std::size_t i) {
        const void* field = fields[i / blocksPerField];
        const std::size_t blockBegin = std::min(n, (i % blocksPerField) * blockLength);
        const std::size_t blockEnd = std::min(n, blockBegin + blockLength);
        double converted[chunk];
        double sum = 0.0;
        for (std::size_t begin = blockBegin; begin < blockEnd; begin += chunk) {
            const auto length = static_cast<vDSP_Length>(std::min(chunk, blockEnd - begin));
            double chunkSum = 0.0;
            const float* source = static_cast<const float*>(field) + begin;
            float widened[chunk];
            if (q16Fields) {
                const QFieldView view = qViewPointer[i / blocksPerField];
                const CopperGridDims& dims = dimsCopy;
                for (std::size_t k = 0; k < length; ++k) {
                    const std::size_t c = begin + k;
                    widened[k] = view.get(c % dims.nx, (c / dims.nx) % dims.ny, c / (dims.nx * dims.ny));
                }
                source = widened;
            } else if (halfFields) {
                widenHalf(static_cast<const std::uint16_t*>(field) + begin, widened, length);
                source = widened;
            }
            vDSP_vspdp(source, 1, converted, 1, length);
            vDSP_svesqD(converted, 1, &chunkSum, length);
            sum += chunkSum;
        }
        partialSums[i] = sum;
    });
    double eSumSq = 0.0;
    double hSumSq = 0.0;
    for (std::size_t i = 0; i < partial.size(); ++i) {
        (i < 3 * blocksPerField ? eSumSq : hSumSq) += partial[i];
    }
    return physical::epsilon0 * eSumSq + physical::mu0 * hSumSq;
}

std::unique_ptr<EngineBackend> makeMetalEngineBackend(const CopperYeeGrid& grid,
                                                       const CopperExcitation& excitation,
                                                       const CopperCPML& cpml,
                                                       const CopperDomainMask& domainMask) {
    return std::make_unique<MetalEngineImpl>(grid, excitation, cpml, domainMask);
}

} // namespace copper
