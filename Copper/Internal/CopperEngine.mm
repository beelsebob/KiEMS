#include "CopperEngineBackend.hpp"

#include <algorithm>
#include <array>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
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
                     const std::vector<CopperCPMLShell>& cpmlShells, const CopperDomainMask& domainMask,
                     const CopperZCPML& zcpml);

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
    std::vector<CopperDomainMask::DispatchBox> _dispatchBoxes;
    id<MTLBuffer> _eField[3];
    id<MTLBuffer> _hField[3];

    // The update coefficients in table form (see CopperCoefficientTable): [0] the E side, [1] H.
    struct CoefficientBuffers {
        id<MTLBuffer> index;    // per cell: ushort or uint, into `table`
        id<MTLBuffer> table;    // CopperMaterialCoefficientsGPU[]
        id<MTLBuffer> geometry; // float[2 * (nx + ny + nz)]
    };
    CoefficientBuffers _coefficients[2];

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

    // An irregular domain's Z-only CPML (see CopperZCPML), applied by the _zcpml interior kernels.
    // nil buffers when there is none.
    id<MTLComputePipelineState> _updateEZCPMLPipeline;
    id<MTLComputePipelineState> _updateHZCPMLPipeline;
    id<MTLBuffer> _zcpmlPlanes;  // CopperZCPMLPlaneGPU[nz]
    id<MTLBuffer> _zcpmlPsi[4];  // Ex, Ey, Hx, Hy d/dz-driven psi, nx*ny per graded plane

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
    // of the disjoint cuboids, not of the rectangular CPML faces (which overlap at edges), so a
    // rectangular domain stays serial. COPPER_CONCURRENT_DISPATCH=0 forces serial for comparison.
    MTLDispatchType _dispatchType = MTLDispatchTypeSerial;
};

MetalEngineImpl::MetalEngineImpl(const CopperYeeGrid& grid, const CopperExcitation& excitation,
                                  const std::vector<CopperCPMLShell>& cpmlShells,
                                  const CopperDomainMask& domainMask, const CopperZCPML& zcpml) {
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

    _applyExcitationEPipeline = makePipeline(@"apply_excitation_e");
    _applyExcitationHPipeline = makePipeline(@"apply_excitation_h");

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
    for (int axis = 0; axis < 3; ++axis) {
        _eField[axis] = makeZeroedBuffer(_device, cellCount);
        _hField[axis] = makeZeroedBuffer(_device, cellCount);
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
        std::fprintf(stderr, "Copper: %s coefficient table: %zu entries, %s indices, %s rebuilt to within %.1e\n",
                     side == 0 ? "E" : "H", table.entries.size(), wide ? "32-bit" : "16-bit", side == 0 ? "vi" : "iv",
                     table.worstRebuildError);
    }
    auto sidePipeline = [&](NSString* name, int side) {
        return makePipeline([name stringByAppendingString:indexSuffix[side]]);
    };
    _updateEPipeline = sidePipeline(@"update_e_interior", 0);
    _updateHPipeline = sidePipeline(@"update_h_interior", 1);
    if (!zcpml.empty()) {
        _updateEZCPMLPipeline = sidePipeline(@"update_e_interior_zcpml", 0);
        _updateHZCPMLPipeline = sidePipeline(@"update_h_interior_zcpml", 1);
    }
    _cpmlCorrectEPipeline = sidePipeline(@"cpml_correct_e", 0);
    _cpmlCorrectHPipeline = sidePipeline(@"cpml_correct_h", 1);

    if (!zcpml.empty()) {
        if (zcpml.layerOfZ.size() != grid.dims.nz) {
            throw std::runtime_error("CopperEngine: Z-only CPML plane table doesn't match the grid");
        }
        std::vector<CopperZCPMLPlaneGPU> planes(grid.dims.nz);
        for (std::uint32_t z = 0; z < grid.dims.nz; ++z) {
            const std::uint32_t layer = zcpml.layerOfZ[z];
            planes[z] = layer == CopperZCPML::kNoLayer
                            ? CopperZCPMLPlaneGPU{kCopperZCPMLNoLayer, 1.0F, 0.0F, 1.0F, 0.0F}
                            : CopperZCPMLPlaneGPU{layer, zcpml.bE[layer], zcpml.cE[layer], zcpml.bH[layer],
                                                  zcpml.cH[layer]};
        }
        _zcpmlPlanes = [_device newBufferWithBytes:planes.data()
                                            length:planes.size() * sizeof(CopperZCPMLPlaneGPU)
                                           options:MTLResourceStorageModeShared];
        const std::size_t psiCount =
            static_cast<std::size_t>(grid.dims.nx) * grid.dims.ny * zcpml.layerCount();
        for (auto& psi : _zcpmlPsi) psi = makeZeroedBuffer(_device, psiCount);
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

    auto bindCoefficients = [&](int side) {
        [encoder setBuffer:_coefficients[side].index offset:0 atIndex:CopperBufferIndexMaterialIndex];
        [encoder setBuffer:_coefficients[side].table offset:0 atIndex:CopperBufferIndexMaterialTable];
        [encoder setBuffer:_coefficients[side].geometry offset:0 atIndex:CopperBufferIndexGeometry];
    };

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
                bindCoefficients(0);
                [encoder setBuffer:shell.bE offset:0 atIndex:CopperBufferIndexCPMLCoeffB];
                [encoder setBuffer:shell.cE offset:0 atIndex:CopperBufferIndexCPMLCoeffC];
                [encoder setBuffer:shell.psiE0 offset:0 atIndex:CopperBufferIndexCPMLPsi0];
                [encoder setBuffer:shell.psiE1 offset:0 atIndex:CopperBufferIndexCPMLPsi1];
            } else {
                bindCoefficients(1);
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
        [encoder setComputePipelineState:_zcpmlPlanes != nil ? _updateEZCPMLPipeline : _updateEPipeline];
        if (_zcpmlPlanes != nil) {
            [encoder setBuffer:_zcpmlPlanes offset:0 atIndex:CopperBufferIndexZCPMLPlanes];
            [encoder setBuffer:_zcpmlPsi[0] offset:0 atIndex:CopperBufferIndexZCPMLPsiX];
            [encoder setBuffer:_zcpmlPsi[1] offset:0 atIndex:CopperBufferIndexZCPMLPsiY];
        }
        [encoder setBuffer:_dimsBuffer offset:0 atIndex:CopperBufferIndexDims];
        [encoder setBuffer:_eField[0] offset:0 atIndex:CopperBufferIndexEx];
        [encoder setBuffer:_eField[1] offset:0 atIndex:CopperBufferIndexEy];
        [encoder setBuffer:_eField[2] offset:0 atIndex:CopperBufferIndexEz];
        [encoder setBuffer:_hField[0] offset:0 atIndex:CopperBufferIndexHx];
        [encoder setBuffer:_hField[1] offset:0 atIndex:CopperBufferIndexHy];
        [encoder setBuffer:_hField[2] offset:0 atIndex:CopperBufferIndexHz];
        bindCoefficients(0);
        for (const auto& box : _dispatchBoxes) {
            const CopperDispatchOriginGPU origin{box.startX, box.startY, 0};
            [encoder setBytes:&origin length:sizeof(origin) atIndex:CopperBufferIndexDispatchOrigin];
            [encoder dispatchThreads:MTLSizeMake(box.width, box.height, eGrid.depth)
                 threadsPerThreadgroup:threadsPerThreadgroup];
        }

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
        [encoder setComputePipelineState:_zcpmlPlanes != nil ? _updateHZCPMLPipeline : _updateHPipeline];
        if (_zcpmlPlanes != nil) {
            [encoder setBuffer:_zcpmlPlanes offset:0 atIndex:CopperBufferIndexZCPMLPlanes];
            [encoder setBuffer:_zcpmlPsi[2] offset:0 atIndex:CopperBufferIndexZCPMLPsiX];
            [encoder setBuffer:_zcpmlPsi[3] offset:0 atIndex:CopperBufferIndexZCPMLPsiY];
        }
        [encoder setBuffer:_dimsBuffer offset:0 atIndex:CopperBufferIndexDims];
        [encoder setBuffer:_eField[0] offset:0 atIndex:CopperBufferIndexEx];
        [encoder setBuffer:_eField[1] offset:0 atIndex:CopperBufferIndexEy];
        [encoder setBuffer:_eField[2] offset:0 atIndex:CopperBufferIndexEz];
        [encoder setBuffer:_hField[0] offset:0 atIndex:CopperBufferIndexHx];
        [encoder setBuffer:_hField[1] offset:0 atIndex:CopperBufferIndexHy];
        [encoder setBuffer:_hField[2] offset:0 atIndex:CopperBufferIndexHz];
        bindCoefficients(1);
        for (const auto& box : _dispatchBoxes) {
            if (box.startX >= hGrid.width || box.startY >= hGrid.height) continue;
            const NSUInteger width = std::min<NSUInteger>(box.width, hGrid.width - box.startX);
            const NSUInteger height = std::min<NSUInteger>(box.height, hGrid.height - box.startY);
            if (width == 0 || height == 0 || hGrid.depth == 0) continue;
            const CopperDispatchOriginGPU origin{box.startX, box.startY, 0};
            [encoder setBytes:&origin length:sizeof(origin) atIndex:CopperBufferIndexDispatchOrigin];
            [encoder dispatchThreads:MTLSizeMake(width, height, hGrid.depth)
                 threadsPerThreadgroup:threadsPerThreadgroup];
        }

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
        id<MTLComputeCommandEncoder> encoder = [commandBuffer computeCommandEncoderWithDispatchType:_dispatchType];

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
    // EXPERIMENT (COPPER_PIPELINE=0): the original encode-commit-wait loop, for comparison.
    const char* pipelineEnv = std::getenv("COPPER_PIPELINE");
    if (pipelineEnv == nullptr || std::string(pipelineEnv) != "0") {
        runWithProbeSamplingPipelined(steps, sampler, midStepCorrection);
        return;
    }
    for (std::uint32_t step = 0; step < steps; ++step) {
        bool shouldContinue = true;
        @autoreleasepool {
            auto runPhase = [&](IterationPhase phase, const char* phaseName) {
                id<MTLCommandBuffer> commandBuffer = [_queue commandBuffer];
                id<MTLComputeCommandEncoder> encoder = [commandBuffer computeCommandEncoderWithDispatchType:_dispatchType];
                encodeIterationPhase(encoder, phase);
                [encoder endEncoding];
                [commandBuffer commit];
                [commandBuffer waitUntilCompleted];
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
                midStepCorrection();
                runPhase(IterationPhase::Current, "current");
            } else {
                runPhase(IterationPhase::Full, "full-iteration");
            }

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
    encodeIterationPhase(encoder, splitAtCorrection ? IterationPhase::Voltage : IterationPhase::Full);
    [encoder endEncoding];
    if (splitAtCorrection) {
        step.correctionValue = ++_correctionEventValue;
        step.current = [_queue commandBuffer];
        [step.current encodeWaitForEvent:_correctionEvent value:step.correctionValue];
        encoder = [step.current computeCommandEncoderWithDispatchType:_dispatchType];
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
                midStepCorrection();
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
    const std::array<const float*, 6> fields = {
        static_cast<const float*>(_eField[0].contents), static_cast<const float*>(_eField[1].contents),
        static_cast<const float*>(_eField[2].contents), static_cast<const float*>(_hField[0].contents),
        static_cast<const float*>(_hField[1].contents), static_cast<const float*>(_hField[2].contents)};
    std::array<double, 6 * blocksPerField> partial{};
    double* const partialSums = partial.data();
    dispatch_apply(partial.size(), dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^(std::size_t i) {
        const float* field = fields[i / blocksPerField];
        const std::size_t blockBegin = std::min(n, (i % blocksPerField) * blockLength);
        const std::size_t blockEnd = std::min(n, blockBegin + blockLength);
        double converted[chunk];
        double sum = 0.0;
        for (std::size_t begin = blockBegin; begin < blockEnd; begin += chunk) {
            const auto length = static_cast<vDSP_Length>(std::min(chunk, blockEnd - begin));
            double chunkSum = 0.0;
            vDSP_vspdp(field + begin, 1, converted, 1, length);
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
                                                       const std::vector<CopperCPMLShell>& cpmlShells,
                                                       const CopperDomainMask& domainMask,
                                                       const CopperZCPML& zcpml) {
    return std::make_unique<MetalEngineImpl>(grid, excitation, cpmlShells, domainMask, zcpml);
}

} // namespace copper
