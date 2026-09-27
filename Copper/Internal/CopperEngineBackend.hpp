// The interface CopperEngine's two backends (Metal, in CopperEngine.mm; CPU, in CopperCPUEngine.cpp)
// each implement -- CopperEngine.cpp itself is plain, backend-agnostic C++ that just forwards every
// public call to whichever one its constructor picked. Both backends store E/H fields as flat, x
// -fastest-varying float arrays indexed via copperGridIndex() -- exactly the layout a Metal
// MTLStorageModeShared buffer's own `.contents` already is -- so the two are byte-for-byte
// interchangeable: a future feature that runs both backends over disjoint slices of one grid (the
// eventual goal this split exists for) can hand either one a raw pointer/subrange from the other
// without any translation step.
#pragma once

#include <cstdint>
#include <memory>
#include <vector>

#include "CopperCPML.hpp"
#include "CopperEngine.hpp"
#include "CopperExcitation.hpp"
#include "CopperYeeGrid.hpp"

namespace copper {

class EngineBackend {
public:
    virtual ~EngineBackend() = default;

    virtual void run(std::uint32_t steps) = 0;
    virtual void runWithProbeSampling(std::uint32_t steps, const CopperEngine::ProbeSampler& sampler,
                                       const CopperEngine::MidStepCorrection& midStepCorrection) = 0;
    virtual void readField(CopperEngine::Field field, std::vector<float>& destination) const = 0;
    virtual float readFieldCell(CopperEngine::Field field, std::uint32_t x, std::uint32_t y,
                                 std::uint32_t z) const = 0;
    virtual void writeFieldCell(CopperEngine::Field field, std::uint32_t x, std::uint32_t y, std::uint32_t z,
                                 float value) = 0;
    virtual double estimateEnergy() const = 0;
    virtual const CopperGridDims& dims() const = 0;

    /// Current GPU-resident allocation size in bytes (MTLDevice::currentAllocatedSize for the Metal
    /// backend) -- 0 for the CPU backend, which has none. Diagnostic only: lets a caller log real
    /// Metal-driver memory usage over a long run without the overhead of an Instruments GPU trace.
    virtual std::size_t currentAllocatedMetalBytes() const { return 0; }
};

/// Defined in CopperEngine.mm -- the existing Metal leapfrog engine, unchanged in behavior, just
/// moved behind this interface.
std::unique_ptr<EngineBackend> makeMetalEngineBackend(const CopperYeeGrid& grid,
                                                        const CopperExcitation& excitation,
                                                        const std::vector<CopperCPMLShell>& cpmlShells,
                                                        const CopperDomainMask& domainMask);

/// Defined in CopperCPUEngine.cpp -- a from-scratch CPU port of CopperFDTD.metal's own kernels (not
/// openEMS's Engine -- see CopperCPUEngine.cpp's own file comment), sharing this same field-buffer
/// layout so it is a drop-in alternative to the Metal backend above.
std::unique_ptr<EngineBackend> makeCPUEngineBackend(const CopperYeeGrid& grid,
                                                      const CopperExcitation& excitation,
                                                      const std::vector<CopperCPMLShell>& cpmlShells,
                                                      const CopperDomainMask& domainMask);

} // namespace copper
