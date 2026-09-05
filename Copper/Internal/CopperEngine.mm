#include "CopperEngine.hpp"

#include <stdexcept>

#import <Accelerate/Accelerate.h>
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

#include "../Shaders/CopperShaderTypes.h"

// Flat include, matching every other Copper/Internal/ file's openEMS-source-checkout convention
// (see CopperOpenEMSAccess.hpp's own file comment) -- gets the real EPS0/MUE0 openEMS itself uses,
// rather than a second, hand-copied pair of constants that could silently drift from them.
#include "tools/constants.h"

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

id<MTLBuffer> makeZeroedBuffer(id<MTLDevice> device, std::size_t floatCount) {
    id<MTLBuffer> buffer = [device newBufferWithLength:floatCount * sizeof(float)
                                                options:MTLResourceStorageModeShared];
    if (buffer == nil) {
        throw std::runtime_error("CopperEngine: failed to allocate a field buffer");
    }
    std::memset(buffer.contents, 0, floatCount * sizeof(float));
    return buffer;
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

// Concatenates a CopperPMLShell coefficient's 3 per-axis arrays into one axis-major buffer (axis n's
// cell `idx` at `n*perAxisCount + idx`) -- see CopperShaderTypes.h's own comment on why the PML
// kernels take one merged buffer per coefficient rather than 3 separate ones.
std::vector<float> concatAxes(const std::vector<float> (&perAxis)[3]) {
    std::vector<float> out;
    out.reserve(perAxis[0].size() + perAxis[1].size() + perAxis[2].size());
    for (const auto& axis : perAxis) {
        out.insert(out.end(), axis.begin(), axis.end());
    }
    return out;
}

} // namespace

struct CopperEngine::Impl {
    CopperGridDims dims;
    id<MTLDevice> device;
    id<MTLCommandQueue> queue;
    id<MTLComputePipelineState> updateEPipeline;
    id<MTLComputePipelineState> updateHPipeline;
    id<MTLComputePipelineState> pmlPreEPipeline;
    id<MTLComputePipelineState> pmlPostEPipeline;
    id<MTLComputePipelineState> pmlPreHPipeline;
    id<MTLComputePipelineState> pmlPostHPipeline;
    id<MTLComputePipelineState> cpmlCorrectEPipeline;
    id<MTLComputePipelineState> cpmlCorrectHPipeline;

    id<MTLBuffer> dimsBuffer;
    id<MTLBuffer> eField[3];
    id<MTLBuffer> hField[3];
    id<MTLBuffer> vv[3];
    id<MTLBuffer> vi[3];
    id<MTLBuffer> ii[3];
    id<MTLBuffer> iv[3];

    // One entry per CopperPMLShell (see CopperPML.hpp) -- empty for a PEC-only or CPML run.
    struct PMLShellBuffers {
        id<MTLBuffer> shellUniform;
        id<MTLBuffer> vv, vvfo, vvfn; // axis-major merged, 3*localCellCount floats each
        id<MTLBuffer> ii, iifo, iifn;
        id<MTLBuffer> voltFlux, currFlux; // zero-initialized, same layout/size as vv et al.
        MTLSize dispatchSize;
    };
    std::vector<PMLShellBuffers> pmlShells;

    // One entry per CopperCPMLShell (see CopperCPML.hpp) -- empty for a PEC-only or UPML run.
    struct CPMLShellBuffers {
        id<MTLBuffer> shellUniform;
        id<MTLBuffer> bE, cE; // axis-major merged by *grading* axis, 3*localCellCount floats each
        id<MTLBuffer> bH, cH;
        id<MTLBuffer> psiE0, psiE1; // axis-major merged by *field-component* axis, zero-initialized
        id<MTLBuffer> psiH0, psiH1;
        MTLSize dispatchSize;
    };
    std::vector<CPMLShellBuffers> cpmlShells;

    // Excitation (Phase 4 -- see CopperExcitation.hpp). Zero counts mean encodeIterationPhase simply
    // never dispatches the corresponding kernel -- an unexcited run stays at its E=H=0 (or
    // test-seeded, see writeFieldCell) initial condition, same as Phase 2/3.
    id<MTLComputePipelineState> applyExcitationEPipeline;
    id<MTLComputePipelineState> applyExcitationHPipeline;
    id<MTLBuffer> voltageCells;  // CopperExcitationCellGPU[voltageCellCount]
    id<MTLBuffer> currentCells;  // CopperExcitationCellGPU[currentCellCount]
    id<MTLBuffer> voltageSignal; // float[signalLength]
    id<MTLBuffer> currentSignal; // float[signalLength]
    // CopperExcitationParamsGPU is bound via setBytes:length:atIndex:, not an MTLBuffer -- run()
    // encodes every iteration's commands on the CPU *before* any of them actually execute on the
    // GPU (that's what makes the batching work), so a single shared MTLBuffer mutated by CPU-side
    // memcpy between encodeIterationPhase calls would have every dispatch see only the *last*
    // iteration's values once the GPU finally runs (this was a real, confirmed bug in an earlier
    // version of this code -- Phase 4a's smoketest caught it). setBytes: instead copies the given
    // bytes into the command buffer's own storage immediately at encode time, so each dispatch
    // keeps its own snapshot regardless of what a later encodeIterationPhase call does to the local
    // variable afterwards.
    std::uint32_t voltageCellCount = 0;
    std::uint32_t currentCellCount = 0;
    std::uint32_t signalLength = 0;
    double timestepSeconds = 0.0;      // needed to turn signalPeriodSeconds into a step count
    double signalPeriodSeconds = 0.0;
    std::uint32_t currentTimestep = 0; // persists across run()/runWithProbeSampling() calls, mirrors
                                        // Engine::numTS exactly (including *when* it increments)

    enum class IterationPhase { Full, Voltage, Current };

    // Encodes either or both halves of one leapfrog iteration. `Full` preserves run()'s batched
    // fast path; Voltage/Current are committed separately when a CPU correction must land between
    // them. currentTimestep advances only after the Current half.
    void encodeIterationPhase(id<MTLComputeCommandEncoder> encoder, IterationPhase phase);
};

CopperEngine::CopperEngine(const CopperYeeGrid& grid, const std::vector<CopperPMLShell>& pmlShells,
                            const CopperExcitation& excitation, const std::vector<CopperCPMLShell>& cpmlShells)
    : _impl(std::make_unique<Impl>()) {
    _impl->dims = grid.dims;
    _impl->timestepSeconds = grid.timestepSeconds;
    _impl->signalPeriodSeconds = excitation.signalPeriodSeconds;

    _impl->device = MTLCreateSystemDefaultDevice();
    if (_impl->device == nil) {
        throw std::runtime_error("CopperEngine: no Metal device available");
    }

    NSBundle* bundle = [NSBundle bundleForClass:[CopperEngineBundleAnchor class]];
    NSError* error = nil;
    id<MTLLibrary> library = [_impl->device newDefaultLibraryWithBundle:bundle error:&error];
    if (library == nil) {
        throw std::runtime_error("CopperEngine: failed to load Copper's default Metal library: " +
                                  std::string(error.localizedDescription.UTF8String));
    }

    auto makePipeline = [&](NSString* name) -> id<MTLComputePipelineState> {
        id<MTLFunction> function = [library newFunctionWithName:name];
        if (function == nil) {
            throw std::runtime_error("CopperEngine: " + std::string(name.UTF8String) +
                                      " not found in Copper's Metal library");
        }
        NSError* pipelineError = nil;
        id<MTLComputePipelineState> pipeline =
            [_impl->device newComputePipelineStateWithFunction:function error:&pipelineError];
        if (pipeline == nil) {
            throw std::runtime_error("CopperEngine: failed to build " + std::string(name.UTF8String) +
                                      " pipeline state: " + std::string(pipelineError.localizedDescription.UTF8String));
        }
        return pipeline;
    };

    _impl->updateEPipeline = makePipeline(@"update_e_interior");
    _impl->updateHPipeline = makePipeline(@"update_h_interior");
    _impl->pmlPreEPipeline = makePipeline(@"pml_pre_e");
    _impl->pmlPostEPipeline = makePipeline(@"pml_post_e");
    _impl->pmlPreHPipeline = makePipeline(@"pml_pre_h");
    _impl->pmlPostHPipeline = makePipeline(@"pml_post_h");
    _impl->cpmlCorrectEPipeline = makePipeline(@"cpml_correct_e");
    _impl->cpmlCorrectHPipeline = makePipeline(@"cpml_correct_h");
    _impl->applyExcitationEPipeline = makePipeline(@"apply_excitation_e");
    _impl->applyExcitationHPipeline = makePipeline(@"apply_excitation_h");

    _impl->queue = [_impl->device newCommandQueue];
    if (_impl->queue == nil) {
        throw std::runtime_error("CopperEngine: failed to create a Metal command queue");
    }

    CopperGridDimsGPU dimsGPU{grid.dims.nx, grid.dims.ny, grid.dims.nz};
    _impl->dimsBuffer = [_impl->device newBufferWithBytes:&dimsGPU
                                                    length:sizeof(dimsGPU)
                                                   options:MTLResourceStorageModeShared];

    const std::size_t cellCount = grid.dims.cellCount();
    for (int axis = 0; axis < 3; ++axis) {
        _impl->eField[axis] = makeZeroedBuffer(_impl->device, cellCount);
        _impl->hField[axis] = makeZeroedBuffer(_impl->device, cellCount);
        _impl->vv[axis] = makeUploadedBuffer(_impl->device, grid.vv[axis]);
        _impl->vi[axis] = makeUploadedBuffer(_impl->device, grid.vi[axis]);
        _impl->ii[axis] = makeUploadedBuffer(_impl->device, grid.ii[axis]);
        _impl->iv[axis] = makeUploadedBuffer(_impl->device, grid.iv[axis]);
    }

    _impl->pmlShells.reserve(pmlShells.size());
    for (const CopperPMLShell& shell : pmlShells) {
        Impl::PMLShellBuffers buffers;
        const CopperPMLShellGPU shellGPU{shell.startX, shell.startY, shell.startZ,
                                          shell.dims.nx, shell.dims.ny, shell.dims.nz};
        buffers.shellUniform = [_impl->device newBufferWithBytes:&shellGPU
                                                            length:sizeof(shellGPU)
                                                           options:MTLResourceStorageModeShared];
        buffers.vv = makeUploadedBuffer(_impl->device, concatAxes(shell.vv));
        buffers.vvfo = makeUploadedBuffer(_impl->device, concatAxes(shell.vvfo));
        buffers.vvfn = makeUploadedBuffer(_impl->device, concatAxes(shell.vvfn));
        buffers.ii = makeUploadedBuffer(_impl->device, concatAxes(shell.ii));
        buffers.iifo = makeUploadedBuffer(_impl->device, concatAxes(shell.iifo));
        buffers.iifn = makeUploadedBuffer(_impl->device, concatAxes(shell.iifn));
        buffers.voltFlux = makeZeroedBuffer(_impl->device, 3 * static_cast<std::size_t>(shell.dims.cellCount()));
        buffers.currFlux = makeZeroedBuffer(_impl->device, 3 * static_cast<std::size_t>(shell.dims.cellCount()));
        buffers.dispatchSize = MTLSizeMake(shell.dims.nx, shell.dims.ny, shell.dims.nz);
        _impl->pmlShells.push_back(buffers);
    }

    _impl->cpmlShells.reserve(cpmlShells.size());
    for (const CopperCPMLShell& shell : cpmlShells) {
        Impl::CPMLShellBuffers buffers;
        const CopperPMLShellGPU shellGPU{shell.startX, shell.startY, shell.startZ,
                                          shell.dims.nx, shell.dims.ny, shell.dims.nz};
        buffers.shellUniform = [_impl->device newBufferWithBytes:&shellGPU
                                                            length:sizeof(shellGPU)
                                                           options:MTLResourceStorageModeShared];
        buffers.bE = makeUploadedBuffer(_impl->device, concatAxes(shell.bE));
        buffers.cE = makeUploadedBuffer(_impl->device, concatAxes(shell.cE));
        buffers.bH = makeUploadedBuffer(_impl->device, concatAxes(shell.bH));
        buffers.cH = makeUploadedBuffer(_impl->device, concatAxes(shell.cH));
        buffers.psiE0 = makeUploadedBuffer(_impl->device, concatAxes(shell.psiE0));
        buffers.psiE1 = makeUploadedBuffer(_impl->device, concatAxes(shell.psiE1));
        buffers.psiH0 = makeUploadedBuffer(_impl->device, concatAxes(shell.psiH0));
        buffers.psiH1 = makeUploadedBuffer(_impl->device, concatAxes(shell.psiH1));
        buffers.dispatchSize = MTLSizeMake(shell.dims.nx, shell.dims.ny, shell.dims.nz);
        _impl->cpmlShells.push_back(buffers);
    }

    // copper::CopperExcitationCell (CopperExcitation.hpp) is uploaded here by raw bytes, not
    // converted field-by-field -- this static_assert is what makes that safe: it fails loudly if
    // the two ever drift out of layout sync instead of silently misinterpreting bytes on the GPU.
    static_assert(sizeof(CopperExcitationCell) == sizeof(CopperExcitationCellGPU),
                  "copper::CopperExcitationCell must stay layout-compatible with CopperExcitationCellGPU");

    _impl->signalLength = static_cast<std::uint32_t>(excitation.voltageSignal.size());
    _impl->voltageCellCount = static_cast<std::uint32_t>(excitation.voltageCells.size());
    _impl->currentCellCount = static_cast<std::uint32_t>(excitation.currentCells.size());
    if (_impl->voltageCellCount > 0) {
        _impl->voltageCells = [_impl->device newBufferWithBytes:excitation.voltageCells.data()
                                                           length:excitation.voltageCells.size() *
                                                                  sizeof(CopperExcitationCell)
                                                          options:MTLResourceStorageModeShared];
        _impl->voltageSignal = makeUploadedBuffer(_impl->device, excitation.voltageSignal);
    }
    if (_impl->currentCellCount > 0) {
        _impl->currentCells = [_impl->device newBufferWithBytes:excitation.currentCells.data()
                                                           length:excitation.currentCells.size() *
                                                                  sizeof(CopperExcitationCell)
                                                          options:MTLResourceStorageModeShared];
        _impl->currentSignal = makeUploadedBuffer(_impl->device, excitation.currentSignal);
    }
}

CopperEngine::~CopperEngine() = default;

void CopperEngine::Impl::encodeIterationPhase(id<MTLComputeCommandEncoder> encoder, IterationPhase phase) {
    const bool encodeVoltage = phase != IterationPhase::Current;
    const bool encodeCurrent = phase != IterationPhase::Voltage;
    const MTLSize eGrid = MTLSizeMake(dims.nx, dims.ny, dims.nz);
    const MTLSize hGrid = MTLSizeMake(dims.nx > 0 ? dims.nx - 1 : 0, dims.ny > 0 ? dims.ny - 1 : 0,
                                       dims.nz > 0 ? dims.nz - 1 : 0);
    const NSUInteger tgWidth = updateEPipeline.threadExecutionWidth;
    const MTLSize threadsPerThreadgroup = MTLSizeMake(tgWidth, 1, 1);

    // Excitation params for *this* iteration -- numTS read before increment, matching
    // Engine_Ext_Excitation::Apply2VoltagesImpl/Apply2CurrentImpl's own
    // `m_Eng->GetNumberOfTimesteps()` (both stages share this one value, exactly like the CPU
    // engine's Apply2Voltages/Apply2Current do within a single Engine::IterateTS iteration). Bound
    // below via setBytes:, not a shared MTLBuffer -- see the Impl field comment on why.
    const auto numTS = static_cast<std::int32_t>(currentTimestep);
    const std::int32_t period = (signalPeriodSeconds > 0.0)
                                     ? static_cast<std::int32_t>(signalPeriodSeconds / timestepSeconds)
                                     : numTS + 1;
    const CopperExcitationParamsGPU excitationParams{numTS, period, signalLength};

    // Binds and dispatches one PML pre/post stage (pml_pre_e/pml_post_e/pml_pre_h/pml_post_h) across
    // every shell -- see CopperPML.hpp for why there can be more than one (up to 6, one per active
    // PML face) -- then barriers so the following interior/PML dispatch sees the result. A no-op
    // (nothing bound, no barrier) when there are no PML shells at all, e.g. an all-PEC run.
    enum class PMLStage { EPre, EPost, HPre, HPost };
    auto dispatchPMLStage = [&](PMLStage stage) {
        if (pmlShells.empty()) {
            return;
        }
        id<MTLComputePipelineState> pipeline = nil;
        id<MTLBuffer> field0 = nil, field1 = nil, field2 = nil;
        NSUInteger fieldIndex0 = 0;
        switch (stage) {
        case PMLStage::EPre:
        case PMLStage::EPost:
            field0 = eField[0];
            field1 = eField[1];
            field2 = eField[2];
            fieldIndex0 = CopperBufferIndexEx;
            pipeline = (stage == PMLStage::EPre) ? pmlPreEPipeline : pmlPostEPipeline;
            break;
        case PMLStage::HPre:
        case PMLStage::HPost:
            field0 = hField[0];
            field1 = hField[1];
            field2 = hField[2];
            fieldIndex0 = CopperBufferIndexHx;
            pipeline = (stage == PMLStage::HPre) ? pmlPreHPipeline : pmlPostHPipeline;
            break;
        }

        for (const Impl::PMLShellBuffers& shell : pmlShells) {
            [encoder setComputePipelineState:pipeline];
            [encoder setBuffer:dimsBuffer offset:0 atIndex:CopperBufferIndexDims];
            [encoder setBuffer:shell.shellUniform offset:0 atIndex:CopperBufferIndexPMLShell];
            [encoder setBuffer:field0 offset:0 atIndex:fieldIndex0];
            [encoder setBuffer:field1 offset:0 atIndex:fieldIndex0 + 1];
            [encoder setBuffer:field2 offset:0 atIndex:fieldIndex0 + 2];
            switch (stage) {
            case PMLStage::EPre:
                [encoder setBuffer:shell.vv offset:0 atIndex:CopperBufferIndexPMLCoeffA];
                [encoder setBuffer:shell.vvfo offset:0 atIndex:CopperBufferIndexPMLCoeffB];
                [encoder setBuffer:shell.voltFlux offset:0 atIndex:CopperBufferIndexPMLFlux];
                break;
            case PMLStage::EPost:
                [encoder setBuffer:shell.vvfn offset:0 atIndex:CopperBufferIndexPMLCoeffC];
                [encoder setBuffer:shell.voltFlux offset:0 atIndex:CopperBufferIndexPMLFlux];
                break;
            case PMLStage::HPre:
                [encoder setBuffer:shell.ii offset:0 atIndex:CopperBufferIndexPMLCoeffA];
                [encoder setBuffer:shell.iifo offset:0 atIndex:CopperBufferIndexPMLCoeffB];
                [encoder setBuffer:shell.currFlux offset:0 atIndex:CopperBufferIndexPMLFlux];
                break;
            case PMLStage::HPost:
                [encoder setBuffer:shell.iifn offset:0 atIndex:CopperBufferIndexPMLCoeffC];
                [encoder setBuffer:shell.currFlux offset:0 atIndex:CopperBufferIndexPMLFlux];
                break;
            }
            [encoder dispatchThreads:shell.dispatchSize threadsPerThreadgroup:threadsPerThreadgroup];
        }
        [encoder memoryBarrierWithScope:MTLBarrierScopeBuffers];
    };

    // Binds and dispatches cpml_correct_e/cpml_correct_h across every CPML shell -- a no-op (nothing
    // bound, no barrier) when there are no CPML shells, e.g. a UPML or PEC-only run. Unlike
    // dispatchPMLStage above, this is a single additive correction, not a pre/post pair -- see
    // CopperCPML.hpp's own doc comment for why.
    enum class CPMLStage { E, H };
    auto dispatchCPMLCorrect = [&](CPMLStage stage) {
        if (cpmlShells.empty()) {
            return;
        }
        id<MTLComputePipelineState> pipeline = stage == CPMLStage::E ? cpmlCorrectEPipeline : cpmlCorrectHPipeline;
        for (const Impl::CPMLShellBuffers& shell : cpmlShells) {
            [encoder setComputePipelineState:pipeline];
            [encoder setBuffer:dimsBuffer offset:0 atIndex:CopperBufferIndexDims];
            [encoder setBuffer:shell.shellUniform offset:0 atIndex:CopperBufferIndexPMLShell];
            [encoder setBuffer:eField[0] offset:0 atIndex:CopperBufferIndexEx];
            [encoder setBuffer:eField[1] offset:0 atIndex:CopperBufferIndexEy];
            [encoder setBuffer:eField[2] offset:0 atIndex:CopperBufferIndexEz];
            [encoder setBuffer:hField[0] offset:0 atIndex:CopperBufferIndexHx];
            [encoder setBuffer:hField[1] offset:0 atIndex:CopperBufferIndexHy];
            [encoder setBuffer:hField[2] offset:0 atIndex:CopperBufferIndexHz];
            if (stage == CPMLStage::E) {
                [encoder setBuffer:vi[0] offset:0 atIndex:CopperBufferIndexVI0];
                [encoder setBuffer:vi[1] offset:0 atIndex:CopperBufferIndexVI1];
                [encoder setBuffer:vi[2] offset:0 atIndex:CopperBufferIndexVI2];
                [encoder setBuffer:shell.bE offset:0 atIndex:CopperBufferIndexCPMLCoeffB];
                [encoder setBuffer:shell.cE offset:0 atIndex:CopperBufferIndexCPMLCoeffC];
                [encoder setBuffer:shell.psiE0 offset:0 atIndex:CopperBufferIndexCPMLPsi0];
                [encoder setBuffer:shell.psiE1 offset:0 atIndex:CopperBufferIndexCPMLPsi1];
            } else {
                [encoder setBuffer:iv[0] offset:0 atIndex:CopperBufferIndexIV0];
                [encoder setBuffer:iv[1] offset:0 atIndex:CopperBufferIndexIV1];
                [encoder setBuffer:iv[2] offset:0 atIndex:CopperBufferIndexIV2];
                [encoder setBuffer:shell.bH offset:0 atIndex:CopperBufferIndexCPMLCoeffB];
                [encoder setBuffer:shell.cH offset:0 atIndex:CopperBufferIndexCPMLCoeffC];
                [encoder setBuffer:shell.psiH0 offset:0 atIndex:CopperBufferIndexCPMLPsi0];
                [encoder setBuffer:shell.psiH1 offset:0 atIndex:CopperBufferIndexCPMLPsi1];
            }
            [encoder dispatchThreads:shell.dispatchSize threadsPerThreadgroup:threadsPerThreadgroup];
        }
        [encoder memoryBarrierWithScope:MTLBarrierScopeBuffers];
    };

    // --- Voltage (E) update: pml_pre_e -> update_e_interior -> pml_post_e ->
    // apply_excitation_e, mirroring Engine::IterateTS's own
    // DoPreVoltageUpdates/UpdateVoltages/DoPostVoltageUpdates/ Apply2Voltages
    // order. ---
    if (encodeVoltage) {
        dispatchPMLStage(PMLStage::EPre);

        [encoder setComputePipelineState:updateEPipeline];
        [encoder setBuffer:dimsBuffer offset:0 atIndex:CopperBufferIndexDims];
        [encoder setBuffer:eField[0] offset:0 atIndex:CopperBufferIndexEx];
        [encoder setBuffer:eField[1] offset:0 atIndex:CopperBufferIndexEy];
        [encoder setBuffer:eField[2] offset:0 atIndex:CopperBufferIndexEz];
        [encoder setBuffer:hField[0] offset:0 atIndex:CopperBufferIndexHx];
        [encoder setBuffer:hField[1] offset:0 atIndex:CopperBufferIndexHy];
        [encoder setBuffer:hField[2] offset:0 atIndex:CopperBufferIndexHz];
        [encoder setBuffer:vv[0] offset:0 atIndex:CopperBufferIndexVV0];
        [encoder setBuffer:vv[1] offset:0 atIndex:CopperBufferIndexVV1];
        [encoder setBuffer:vv[2] offset:0 atIndex:CopperBufferIndexVV2];
        [encoder setBuffer:vi[0] offset:0 atIndex:CopperBufferIndexVI0];
        [encoder setBuffer:vi[1] offset:0 atIndex:CopperBufferIndexVI1];
        [encoder setBuffer:vi[2] offset:0 atIndex:CopperBufferIndexVI2];
        [encoder dispatchThreads:eGrid threadsPerThreadgroup:threadsPerThreadgroup];

        // pml_post_e (next, if there's any PML) reads the E buffers this dispatch
        // just wrote -- Metal doesn't guarantee that ordering/visibility across
        // dispatches within one encoder on its own.
        [encoder memoryBarrierWithScope:MTLBarrierScopeBuffers];

        dispatchPMLStage(PMLStage::EPost);
        dispatchCPMLCorrect(CPMLStage::E);

        if (voltageCellCount > 0) {
            [encoder setComputePipelineState:applyExcitationEPipeline];
            [encoder setBuffer:dimsBuffer offset:0 atIndex:CopperBufferIndexDims];
            [encoder setBuffer:eField[0] offset:0 atIndex:CopperBufferIndexEx];
            [encoder setBuffer:eField[1] offset:0 atIndex:CopperBufferIndexEy];
            [encoder setBuffer:eField[2] offset:0 atIndex:CopperBufferIndexEz];
            [encoder setBuffer:voltageCells offset:0 atIndex:CopperBufferIndexExcCells];
            [encoder setBuffer:voltageSignal offset:0 atIndex:CopperBufferIndexExcSignal];
            [encoder setBytes:&excitationParams length:sizeof(excitationParams) atIndex:CopperBufferIndexExcParams];
            const MTLSize excGrid = MTLSizeMake(voltageCellCount, 1, 1);
            const MTLSize excThreadsPerThreadgroup = MTLSizeMake(std::min<NSUInteger>(tgWidth, voltageCellCount), 1, 1);
            [encoder dispatchThreads:excGrid threadsPerThreadgroup:excThreadsPerThreadgroup];
            // update_h_interior (next) reads the E buffer this just wrote into
            // additively.
            [encoder memoryBarrierWithScope:MTLBarrierScopeBuffers];
        }
    }

    // --- Current (H) update: pml_pre_h -> update_h_interior -> pml_post_h ->
    // apply_excitation_h. ---
    if (encodeCurrent) {
        dispatchPMLStage(PMLStage::HPre);

        [encoder setComputePipelineState:updateHPipeline];
        [encoder setBuffer:dimsBuffer offset:0 atIndex:CopperBufferIndexDims];
        [encoder setBuffer:eField[0] offset:0 atIndex:CopperBufferIndexEx];
        [encoder setBuffer:eField[1] offset:0 atIndex:CopperBufferIndexEy];
        [encoder setBuffer:eField[2] offset:0 atIndex:CopperBufferIndexEz];
        [encoder setBuffer:hField[0] offset:0 atIndex:CopperBufferIndexHx];
        [encoder setBuffer:hField[1] offset:0 atIndex:CopperBufferIndexHy];
        [encoder setBuffer:hField[2] offset:0 atIndex:CopperBufferIndexHz];
        [encoder setBuffer:ii[0] offset:0 atIndex:CopperBufferIndexII0];
        [encoder setBuffer:ii[1] offset:0 atIndex:CopperBufferIndexII1];
        [encoder setBuffer:ii[2] offset:0 atIndex:CopperBufferIndexII2];
        [encoder setBuffer:iv[0] offset:0 atIndex:CopperBufferIndexIV0];
        [encoder setBuffer:iv[1] offset:0 atIndex:CopperBufferIndexIV1];
        [encoder setBuffer:iv[2] offset:0 atIndex:CopperBufferIndexIV2];
        [encoder dispatchThreads:hGrid threadsPerThreadgroup:threadsPerThreadgroup];

        // pml_post_h (next, if there's any PML) reads the H buffers this dispatch
        // just wrote.
        [encoder memoryBarrierWithScope:MTLBarrierScopeBuffers];

        dispatchPMLStage(PMLStage::HPost);
        dispatchCPMLCorrect(CPMLStage::H);

        if (currentCellCount > 0) {
            [encoder setComputePipelineState:applyExcitationHPipeline];
            [encoder setBuffer:dimsBuffer offset:0 atIndex:CopperBufferIndexDims];
            [encoder setBuffer:hField[0] offset:0 atIndex:CopperBufferIndexHx];
            [encoder setBuffer:hField[1] offset:0 atIndex:CopperBufferIndexHy];
            [encoder setBuffer:hField[2] offset:0 atIndex:CopperBufferIndexHz];
            [encoder setBuffer:currentCells offset:0 atIndex:CopperBufferIndexExcCells];
            [encoder setBuffer:currentSignal offset:0 atIndex:CopperBufferIndexExcSignal];
            [encoder setBytes:&excitationParams length:sizeof(excitationParams) atIndex:CopperBufferIndexExcParams];
            const MTLSize excGrid = MTLSizeMake(currentCellCount, 1, 1);
            const MTLSize excThreadsPerThreadgroup = MTLSizeMake(std::min<NSUInteger>(tgWidth, currentCellCount), 1, 1);
            [encoder dispatchThreads:excGrid threadsPerThreadgroup:excThreadsPerThreadgroup];
        }

        // Next iteration's pml_pre_e/update_e_interior reads whatever this
        // iteration's H update (and any PML/excitation on top of it) wrote --
        // covered by whichever of the barriers above ran last (the PML-post
        // barrier if there was no H excitation, since dispatchPMLStage only
        // barriers when it actually dispatches something; here there's always at
        // least the interior H barrier already issued, so the field is visible
        // regardless of which later stages were no-ops).
        [encoder memoryBarrierWithScope:MTLBarrierScopeBuffers];

        ++currentTimestep;
    }
}

void CopperEngine::run(std::uint32_t steps) {
    id<MTLCommandBuffer> commandBuffer = [_impl->queue commandBuffer];
    id<MTLComputeCommandEncoder> encoder = [commandBuffer computeCommandEncoder];

    for (std::uint32_t step = 0; step < steps; ++step) {
        _impl->encodeIterationPhase(encoder, CopperEngine::Impl::IterationPhase::Full);
    }

    [encoder endEncoding];
    [commandBuffer commit];
    [commandBuffer waitUntilCompleted];

    if (commandBuffer.error != nil) {
        throw std::runtime_error("CopperEngine::run: Metal command buffer failed: " +
                                 std::string(commandBuffer.error.localizedDescription.UTF8String));
    }
}

void CopperEngine::runWithProbeSampling(std::uint32_t steps, const ProbeSampler& sampler,
                                        const MidStepCorrection& midStepCorrection) {
    for (std::uint32_t step = 0; step < steps; ++step) {
        auto runPhase = [&](CopperEngine::Impl::IterationPhase phase, const char* phaseName) {
            id<MTLCommandBuffer> commandBuffer = [_impl->queue commandBuffer];
            id<MTLComputeCommandEncoder> encoder = [commandBuffer computeCommandEncoder];
            _impl->encodeIterationPhase(encoder, phase);
            [encoder endEncoding];
            [commandBuffer commit];
            [commandBuffer waitUntilCompleted];

            if (commandBuffer.error != nil) {
                throw std::runtime_error(
                    std::string("CopperEngine::runWithProbeSampling ") + phaseName +
                    " command buffer failed: " + std::string(commandBuffer.error.localizedDescription.UTF8String));
            }
        };

        if (midStepCorrection) {
            // Waiting here is the GPU->CPU fence for MTLStorageModeShared field
            // buffers. The CPU correction writes those same shared bytes; committing
            // the Current phase afterward is the corresponding CPU->GPU ordering
            // point, so update_h_interior sees the correction in this timestep rather
            // than one timestep late.
            runPhase(CopperEngine::Impl::IterationPhase::Voltage, "voltage");
            midStepCorrection();
            runPhase(CopperEngine::Impl::IterationPhase::Current, "current");
        } else {
            runPhase(CopperEngine::Impl::IterationPhase::Full, "full-iteration");
        }

        if (!sampler(_impl->currentTimestep)) {
            break;
        }
    }
}

std::vector<float> CopperEngine::readField(Field field) const {
    std::vector<float> result;
    readField(field, result);
    return result;
}

void CopperEngine::readField(Field field, std::vector<float>& destination) const {
    const int axis = static_cast<int>(field) % 3;
    const bool isH = static_cast<int>(field) >= 3;
    id<MTLBuffer> buffer = isH ? _impl->hField[axis] : _impl->eField[axis];
    const auto* data = static_cast<const float*>(buffer.contents);
    destination.assign(data, data + _impl->dims.cellCount());
}

float CopperEngine::readFieldCell(Field field, std::uint32_t x, std::uint32_t y, std::uint32_t z) const {
    const int axis = static_cast<int>(field) % 3;
    const bool isH = static_cast<int>(field) >= 3;
    id<MTLBuffer> buffer = isH ? _impl->hField[axis] : _impl->eField[axis];
    const auto* data = static_cast<const float*>(buffer.contents);
    return data[copperGridIndex(_impl->dims, x, y, z)];
}

void CopperEngine::writeFieldCell(Field field, std::uint32_t x, std::uint32_t y, std::uint32_t z, float value) {
    const int axis = static_cast<int>(field) % 3;
    const bool isH = static_cast<int>(field) >= 3;
    id<MTLBuffer> buffer = isH ? _impl->hField[axis] : _impl->eField[axis];
    auto* data = static_cast<float*>(buffer.contents);
    data[copperGridIndex(_impl->dims, x, y, z)] = value;
}

double CopperEngine::estimateEnergy() const {
    const vDSP_Length n = _impl->dims.cellCount();
    // vDSP_svesq's own accumulator is float32 -- for a large/energetic grid the true sum of squares
    // legitimately reaches into the 1e38 range (confirmed on a real board: 3.49e38, right at
    // float32's ~3.4e38 ceiling), so a float32 accumulator spuriously overflows to inf/nan even
    // when every individual field value is still perfectly finite and physically reasonable. Convert
    // each field to double first (vDSP_vspdp) and sum in double (vDSP_svesqD) so this can't happen
    // for any grid size this engine could plausibly be asked to run -- only called on the ~4s
    // progress-print cadence, so the extra conversion buffer/pass isn't performance-sensitive.
    std::vector<double> converted(n);
    double eSumSq = 0.0;
    double hSumSq = 0.0;
    for (int axis = 0; axis < 3; ++axis) {
        double axisSumSq = 0.0;
        vDSP_vspdp(static_cast<const float*>(_impl->eField[axis].contents), 1, converted.data(), 1, n);
        vDSP_svesqD(converted.data(), 1, &axisSumSq, n);
        eSumSq += axisSumSq;

        vDSP_vspdp(static_cast<const float*>(_impl->hField[axis].contents), 1, converted.data(), 1, n);
        vDSP_svesqD(converted.data(), 1, &axisSumSq, n);
        hSumSq += axisSumSq;
    }
    return EPS0 * eSumSq + MUE0 * hSumSq;
}

const CopperGridDims& CopperEngine::dims() const { return _impl->dims; }

} // namespace copper
