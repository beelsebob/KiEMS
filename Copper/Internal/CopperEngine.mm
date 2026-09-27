#include "CopperEngineBackend.hpp"

#include <stdexcept>

#import <Accelerate/Accelerate.h>
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

#include "../Shaders/CopperShaderTypes.h"

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

// Concatenates a CPML shell coefficient's 3 per-axis arrays into one axis-major buffer.
std::vector<float> concatAxes(const std::vector<float> (&perAxis)[3]) {
    std::vector<float> out;
    out.reserve(perAxis[0].size() + perAxis[1].size() + perAxis[2].size());
    for (const auto& axis : perAxis) {
        out.insert(out.end(), axis.begin(), axis.end());
    }
    return out;
}

} // namespace

/// Backend::Metal -- the GPU leapfrog engine. See CopperCPUEngine.cpp's MetalEngineImpl-mirroring
/// CPUEngineImpl for the CPU alternative; both implement copper::EngineBackend.
class MetalEngineImpl final : public EngineBackend {
public:
    MetalEngineImpl(const CopperYeeGrid& grid, const CopperExcitation& excitation,
                     const std::vector<CopperCPMLShell>& cpmlShells);

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

private:
    CopperGridDims _dims;
    id<MTLDevice> _device;
    id<MTLCommandQueue> _queue;
    id<MTLComputePipelineState> _updateEPipeline;
    id<MTLComputePipelineState> _updateHPipeline;
    id<MTLComputePipelineState> _cpmlCorrectEPipeline;
    id<MTLComputePipelineState> _cpmlCorrectHPipeline;

    id<MTLBuffer> _dimsBuffer;
    id<MTLBuffer> _eField[3];
    id<MTLBuffer> _hField[3];
    id<MTLBuffer> _vv[3];
    id<MTLBuffer> _vi[3];
    id<MTLBuffer> _ii[3];
    id<MTLBuffer> _iv[3];

    // One entry per CopperCPMLShell (see CopperCPML.hpp) -- empty for a PEC-only run.
    struct CPMLShellBuffers {
        id<MTLBuffer> shellUniform;
        id<MTLBuffer> bE, cE; // axis-major merged by *grading* axis, 3*localCellCount floats each
        id<MTLBuffer> bH, cH;
        id<MTLBuffer> psiE0, psiE1; // axis-major merged by *field-component* axis, zero-initialized
        id<MTLBuffer> psiH0, psiH1;
        MTLSize dispatchSize;
    };
    std::vector<CPMLShellBuffers> _cpmlShells;

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
    void encodeIterationPhase(id<MTLComputeCommandEncoder> encoder, IterationPhase phase);
};

MetalEngineImpl::MetalEngineImpl(const CopperYeeGrid& grid, const CopperExcitation& excitation,
                                  const std::vector<CopperCPMLShell>& cpmlShells) {
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

    auto makePipeline = [&](NSString* name) -> id<MTLComputePipelineState> {
        id<MTLFunction> function = [library newFunctionWithName:name];
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

    _updateEPipeline = makePipeline(@"update_e_interior");
    _updateHPipeline = makePipeline(@"update_h_interior");
    _cpmlCorrectEPipeline = makePipeline(@"cpml_correct_e");
    _cpmlCorrectHPipeline = makePipeline(@"cpml_correct_h");
    _applyExcitationEPipeline = makePipeline(@"apply_excitation_e");
    _applyExcitationHPipeline = makePipeline(@"apply_excitation_h");

    _queue = [_device newCommandQueue];
    if (_queue == nil) {
        throw std::runtime_error("CopperEngine: failed to create a Metal command queue");
    }

    CopperGridDimsGPU dimsGPU{grid.dims.nx, grid.dims.ny, grid.dims.nz};
    _dimsBuffer = [_device newBufferWithBytes:&dimsGPU length:sizeof(dimsGPU) options:MTLResourceStorageModeShared];

    const std::size_t cellCount = grid.dims.cellCount();
    for (int axis = 0; axis < 3; ++axis) {
        _eField[axis] = makeZeroedBuffer(_device, cellCount);
        _hField[axis] = makeZeroedBuffer(_device, cellCount);
        _vv[axis] = makeUploadedBuffer(_device, grid.vv[axis]);
        _vi[axis] = makeUploadedBuffer(_device, grid.vi[axis]);
        _ii[axis] = makeUploadedBuffer(_device, grid.ii[axis]);
        _iv[axis] = makeUploadedBuffer(_device, grid.iv[axis]);
    }

    _cpmlShells.reserve(cpmlShells.size());
    for (const CopperCPMLShell& shell : cpmlShells) {
        CPMLShellBuffers buffers;
        const CopperCPMLShellGPU shellGPU{shell.startX, shell.startY, shell.startZ, shell.dims.nx, shell.dims.ny,
                                          shell.dims.nz};
        buffers.shellUniform = [_device newBufferWithBytes:&shellGPU
                                                      length:sizeof(shellGPU)
                                                     options:MTLResourceStorageModeShared];
        buffers.bE = makeUploadedBuffer(_device, concatAxes(shell.bE));
        buffers.cE = makeUploadedBuffer(_device, concatAxes(shell.cE));
        buffers.bH = makeUploadedBuffer(_device, concatAxes(shell.bH));
        buffers.cH = makeUploadedBuffer(_device, concatAxes(shell.cH));
        buffers.psiE0 = makeUploadedBuffer(_device, concatAxes(shell.psiE0));
        buffers.psiE1 = makeUploadedBuffer(_device, concatAxes(shell.psiE1));
        buffers.psiH0 = makeUploadedBuffer(_device, concatAxes(shell.psiH0));
        buffers.psiH1 = makeUploadedBuffer(_device, concatAxes(shell.psiH1));
        buffers.dispatchSize = MTLSizeMake(shell.dims.nx, shell.dims.ny, shell.dims.nz);
        _cpmlShells.push_back(buffers);
    }

    // copper::CopperExcitationCell (CopperExcitation.hpp) is uploaded here by raw bytes, not
    // converted field-by-field -- this static_assert is what makes that safe: it fails loudly if
    // the two ever drift out of layout sync instead of silently misinterpreting bytes on the GPU.
    static_assert(sizeof(CopperExcitationCell) == sizeof(CopperExcitationCellGPU),
                  "copper::CopperExcitationCell must stay layout-compatible with CopperExcitationCellGPU");

    _signalLength = static_cast<std::uint32_t>(excitation.voltageSignal.size());
    _voltageCellCount = static_cast<std::uint32_t>(excitation.voltageCells.size());
    _currentCellCount = static_cast<std::uint32_t>(excitation.currentCells.size());
    if (_voltageCellCount > 0) {
        _voltageCells = [_device newBufferWithBytes:excitation.voltageCells.data()
                                              length:excitation.voltageCells.size() * sizeof(CopperExcitationCell)
                                             options:MTLResourceStorageModeShared];
        _voltageSignal = makeUploadedBuffer(_device, excitation.voltageSignal);
    }
    if (_currentCellCount > 0) {
        _currentCells = [_device newBufferWithBytes:excitation.currentCells.data()
                                              length:excitation.currentCells.size() * sizeof(CopperExcitationCell)
                                             options:MTLResourceStorageModeShared];
        _currentSignal = makeUploadedBuffer(_device, excitation.currentSignal);
    }
}

void MetalEngineImpl::encodeIterationPhase(id<MTLComputeCommandEncoder> encoder, IterationPhase phase) {
    const bool encodeVoltage = phase != IterationPhase::Current;
    const bool encodeCurrent = phase != IterationPhase::Voltage;
    const MTLSize eGrid = MTLSizeMake(_dims.nx, _dims.ny, _dims.nz);
    const MTLSize hGrid = MTLSizeMake(_dims.nx > 0 ? _dims.nx - 1 : 0, _dims.ny > 0 ? _dims.ny - 1 : 0,
                                       _dims.nz > 0 ? _dims.nz - 1 : 0);
    const NSUInteger tgWidth = _updateEPipeline.threadExecutionWidth;
    const MTLSize threadsPerThreadgroup = MTLSizeMake(tgWidth, 1, 1);

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

    // Binds and dispatches cpml_correct_e/cpml_correct_h across every CPML shell -- a no-op (nothing
    // bound, no barrier) when there are no CPML shells, e.g. a PEC-only run.
    enum class CPMLStage { E, H };
    auto dispatchCPMLCorrect = [&](CPMLStage stage) {
        if (_cpmlShells.empty()) {
            return;
        }
        id<MTLComputePipelineState> pipeline = stage == CPMLStage::E ? _cpmlCorrectEPipeline : _cpmlCorrectHPipeline;
        for (const CPMLShellBuffers& shell : _cpmlShells) {
            [encoder setComputePipelineState:pipeline];
            [encoder setBuffer:_dimsBuffer offset:0 atIndex:CopperBufferIndexDims];
            [encoder setBuffer:shell.shellUniform offset:0 atIndex:CopperBufferIndexCPMLShell];
            [encoder setBuffer:_eField[0] offset:0 atIndex:CopperBufferIndexEx];
            [encoder setBuffer:_eField[1] offset:0 atIndex:CopperBufferIndexEy];
            [encoder setBuffer:_eField[2] offset:0 atIndex:CopperBufferIndexEz];
            [encoder setBuffer:_hField[0] offset:0 atIndex:CopperBufferIndexHx];
            [encoder setBuffer:_hField[1] offset:0 atIndex:CopperBufferIndexHy];
            [encoder setBuffer:_hField[2] offset:0 atIndex:CopperBufferIndexHz];
            if (stage == CPMLStage::E) {
                [encoder setBuffer:_vi[0] offset:0 atIndex:CopperBufferIndexVI0];
                [encoder setBuffer:_vi[1] offset:0 atIndex:CopperBufferIndexVI1];
                [encoder setBuffer:_vi[2] offset:0 atIndex:CopperBufferIndexVI2];
                [encoder setBuffer:shell.bE offset:0 atIndex:CopperBufferIndexCPMLCoeffB];
                [encoder setBuffer:shell.cE offset:0 atIndex:CopperBufferIndexCPMLCoeffC];
                [encoder setBuffer:shell.psiE0 offset:0 atIndex:CopperBufferIndexCPMLPsi0];
                [encoder setBuffer:shell.psiE1 offset:0 atIndex:CopperBufferIndexCPMLPsi1];
            } else {
                [encoder setBuffer:_iv[0] offset:0 atIndex:CopperBufferIndexIV0];
                [encoder setBuffer:_iv[1] offset:0 atIndex:CopperBufferIndexIV1];
                [encoder setBuffer:_iv[2] offset:0 atIndex:CopperBufferIndexIV2];
                [encoder setBuffer:shell.bH offset:0 atIndex:CopperBufferIndexCPMLCoeffB];
                [encoder setBuffer:shell.cH offset:0 atIndex:CopperBufferIndexCPMLCoeffC];
                [encoder setBuffer:shell.psiH0 offset:0 atIndex:CopperBufferIndexCPMLPsi0];
                [encoder setBuffer:shell.psiH1 offset:0 atIndex:CopperBufferIndexCPMLPsi1];
            }
            [encoder dispatchThreads:shell.dispatchSize threadsPerThreadgroup:threadsPerThreadgroup];
        }
        [encoder memoryBarrierWithScope:MTLBarrierScopeBuffers];
    };

    // --- Voltage (E) update: interior -> CPML correction -> excitation. ---
    if (encodeVoltage) {
        [encoder setComputePipelineState:_updateEPipeline];
        [encoder setBuffer:_dimsBuffer offset:0 atIndex:CopperBufferIndexDims];
        [encoder setBuffer:_eField[0] offset:0 atIndex:CopperBufferIndexEx];
        [encoder setBuffer:_eField[1] offset:0 atIndex:CopperBufferIndexEy];
        [encoder setBuffer:_eField[2] offset:0 atIndex:CopperBufferIndexEz];
        [encoder setBuffer:_hField[0] offset:0 atIndex:CopperBufferIndexHx];
        [encoder setBuffer:_hField[1] offset:0 atIndex:CopperBufferIndexHy];
        [encoder setBuffer:_hField[2] offset:0 atIndex:CopperBufferIndexHz];
        [encoder setBuffer:_vv[0] offset:0 atIndex:CopperBufferIndexVV0];
        [encoder setBuffer:_vv[1] offset:0 atIndex:CopperBufferIndexVV1];
        [encoder setBuffer:_vv[2] offset:0 atIndex:CopperBufferIndexVV2];
        [encoder setBuffer:_vi[0] offset:0 atIndex:CopperBufferIndexVI0];
        [encoder setBuffer:_vi[1] offset:0 atIndex:CopperBufferIndexVI1];
        [encoder setBuffer:_vi[2] offset:0 atIndex:CopperBufferIndexVI2];
        [encoder dispatchThreads:eGrid threadsPerThreadgroup:threadsPerThreadgroup];

        // CPML reads the fields this dispatch just wrote.
        [encoder memoryBarrierWithScope:MTLBarrierScopeBuffers];

        dispatchCPMLCorrect(CPMLStage::E);

        if (_voltageCellCount > 0) {
            [encoder setComputePipelineState:_applyExcitationEPipeline];
            [encoder setBuffer:_dimsBuffer offset:0 atIndex:CopperBufferIndexDims];
            [encoder setBuffer:_eField[0] offset:0 atIndex:CopperBufferIndexEx];
            [encoder setBuffer:_eField[1] offset:0 atIndex:CopperBufferIndexEy];
            [encoder setBuffer:_eField[2] offset:0 atIndex:CopperBufferIndexEz];
            [encoder setBuffer:_voltageCells offset:0 atIndex:CopperBufferIndexExcCells];
            [encoder setBuffer:_voltageSignal offset:0 atIndex:CopperBufferIndexExcSignal];
            [encoder setBytes:&excitationParams length:sizeof(excitationParams) atIndex:CopperBufferIndexExcParams];
            const MTLSize excGrid = MTLSizeMake(_voltageCellCount, 1, 1);
            const MTLSize excThreadsPerThreadgroup =
                MTLSizeMake(std::min<NSUInteger>(tgWidth, _voltageCellCount), 1, 1);
            [encoder dispatchThreads:excGrid threadsPerThreadgroup:excThreadsPerThreadgroup];
            // update_h_interior (next) reads the E buffer this just wrote into
            // additively.
            [encoder memoryBarrierWithScope:MTLBarrierScopeBuffers];
        }
    }

    // --- Current (H) update: interior -> CPML correction -> excitation. ---
    if (encodeCurrent) {
        [encoder setComputePipelineState:_updateHPipeline];
        [encoder setBuffer:_dimsBuffer offset:0 atIndex:CopperBufferIndexDims];
        [encoder setBuffer:_eField[0] offset:0 atIndex:CopperBufferIndexEx];
        [encoder setBuffer:_eField[1] offset:0 atIndex:CopperBufferIndexEy];
        [encoder setBuffer:_eField[2] offset:0 atIndex:CopperBufferIndexEz];
        [encoder setBuffer:_hField[0] offset:0 atIndex:CopperBufferIndexHx];
        [encoder setBuffer:_hField[1] offset:0 atIndex:CopperBufferIndexHy];
        [encoder setBuffer:_hField[2] offset:0 atIndex:CopperBufferIndexHz];
        [encoder setBuffer:_ii[0] offset:0 atIndex:CopperBufferIndexII0];
        [encoder setBuffer:_ii[1] offset:0 atIndex:CopperBufferIndexII1];
        [encoder setBuffer:_ii[2] offset:0 atIndex:CopperBufferIndexII2];
        [encoder setBuffer:_iv[0] offset:0 atIndex:CopperBufferIndexIV0];
        [encoder setBuffer:_iv[1] offset:0 atIndex:CopperBufferIndexIV1];
        [encoder setBuffer:_iv[2] offset:0 atIndex:CopperBufferIndexIV2];
        [encoder dispatchThreads:hGrid threadsPerThreadgroup:threadsPerThreadgroup];

        // CPML reads the fields this dispatch just wrote.
        [encoder memoryBarrierWithScope:MTLBarrierScopeBuffers];

        dispatchCPMLCorrect(CPMLStage::H);

        if (_currentCellCount > 0) {
            [encoder setComputePipelineState:_applyExcitationHPipeline];
            [encoder setBuffer:_dimsBuffer offset:0 atIndex:CopperBufferIndexDims];
            [encoder setBuffer:_hField[0] offset:0 atIndex:CopperBufferIndexHx];
            [encoder setBuffer:_hField[1] offset:0 atIndex:CopperBufferIndexHy];
            [encoder setBuffer:_hField[2] offset:0 atIndex:CopperBufferIndexHz];
            [encoder setBuffer:_currentCells offset:0 atIndex:CopperBufferIndexExcCells];
            [encoder setBuffer:_currentSignal offset:0 atIndex:CopperBufferIndexExcSignal];
            [encoder setBytes:&excitationParams length:sizeof(excitationParams) atIndex:CopperBufferIndexExcParams];
            const MTLSize excGrid = MTLSizeMake(_currentCellCount, 1, 1);
            const MTLSize excThreadsPerThreadgroup =
                MTLSizeMake(std::min<NSUInteger>(tgWidth, _currentCellCount), 1, 1);
            [encoder dispatchThreads:excGrid threadsPerThreadgroup:excThreadsPerThreadgroup];
        }

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
    @autoreleasepool {
        id<MTLCommandBuffer> commandBuffer = [_queue commandBuffer];
        id<MTLComputeCommandEncoder> encoder = [commandBuffer computeCommandEncoder];

        for (std::uint32_t step = 0; step < steps; ++step) {
            encodeIterationPhase(encoder, IterationPhase::Full);
        }

        [encoder endEncoding];
        [commandBuffer commit];
        [commandBuffer waitUntilCompleted];

        if (commandBuffer.error != nil) {
            throw std::runtime_error("CopperEngine::run: Metal command buffer failed: " +
                                     std::string(commandBuffer.error.localizedDescription.UTF8String));
        }
    }
}

void MetalEngineImpl::runWithProbeSampling(std::uint32_t steps, const CopperEngine::ProbeSampler& sampler,
                                            const CopperEngine::MidStepCorrection& midStepCorrection) {
    for (std::uint32_t step = 0; step < steps; ++step) {
        bool shouldContinue = true;
        @autoreleasepool {
            auto runPhase = [&](IterationPhase phase, const char* phaseName) {
                id<MTLCommandBuffer> commandBuffer = [_queue commandBuffer];
                id<MTLComputeCommandEncoder> encoder = [commandBuffer computeCommandEncoder];
                encodeIterationPhase(encoder, phase);
                [encoder endEncoding];
                [commandBuffer commit];
                [commandBuffer waitUntilCompleted];

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
                midStepCorrection();
                runPhase(IterationPhase::Current, "current");
            } else {
                runPhase(IterationPhase::Full, "full-iteration");
            }

            shouldContinue = sampler(_currentTimestep);
        }
        if (!shouldContinue) {
            break;
        }
    }
}

void MetalEngineImpl::readField(CopperEngine::Field field, std::vector<float>& destination) const {
    const int axis = static_cast<int>(field) % 3;
    const bool isH = static_cast<int>(field) >= 3;
    id<MTLBuffer> buffer = isH ? _hField[axis] : _eField[axis];
    const auto* data = static_cast<const float*>(buffer.contents);
    destination.assign(data, data + _dims.cellCount());
}

float MetalEngineImpl::readFieldCell(CopperEngine::Field field, std::uint32_t x, std::uint32_t y,
                                      std::uint32_t z) const {
    const int axis = static_cast<int>(field) % 3;
    const bool isH = static_cast<int>(field) >= 3;
    id<MTLBuffer> buffer = isH ? _hField[axis] : _eField[axis];
    const auto* data = static_cast<const float*>(buffer.contents);
    return data[copperGridIndex(_dims, x, y, z)];
}

void MetalEngineImpl::writeFieldCell(CopperEngine::Field field, std::uint32_t x, std::uint32_t y, std::uint32_t z,
                                      float value) {
    const int axis = static_cast<int>(field) % 3;
    const bool isH = static_cast<int>(field) >= 3;
    id<MTLBuffer> buffer = isH ? _hField[axis] : _eField[axis];
    auto* data = static_cast<float*>(buffer.contents);
    data[copperGridIndex(_dims, x, y, z)] = value;
}

double MetalEngineImpl::estimateEnergy() const {
    const vDSP_Length n = _dims.cellCount();
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
        vDSP_vspdp(static_cast<const float*>(_eField[axis].contents), 1, converted.data(), 1, n);
        vDSP_svesqD(converted.data(), 1, &axisSumSq, n);
        eSumSq += axisSumSq;

        vDSP_vspdp(static_cast<const float*>(_hField[axis].contents), 1, converted.data(), 1, n);
        vDSP_svesqD(converted.data(), 1, &axisSumSq, n);
        hSumSq += axisSumSq;
    }
    return physical::epsilon0 * eSumSq + physical::mu0 * hSumSq;
}

std::unique_ptr<EngineBackend> makeMetalEngineBackend(const CopperYeeGrid& grid,
                                                       const CopperExcitation& excitation,
                                                       const std::vector<CopperCPMLShell>& cpmlShells) {
    return std::make_unique<MetalEngineImpl>(grid, excitation, cpmlShells);
}

} // namespace copper
