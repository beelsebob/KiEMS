#include "CopperEngine.hpp"

#include "CopperEngineBackend.hpp"

namespace copper {

CopperEngine::CopperEngine(const CopperYeeGrid& grid, const CopperExcitation& excitation,
                            const std::vector<CopperCPMLShell>& cpmlShells,
                            Backend backend, const CopperDomainMask& domainMask, const CopperZCPML& zcpml)
    : _backend(backend == Backend::Metal ? makeMetalEngineBackend(grid, excitation, cpmlShells, domainMask, zcpml)
                                          : makeCPUEngineBackend(grid, excitation, cpmlShells, domainMask, zcpml)) {}

CopperEngine::~CopperEngine() = default;

void CopperEngine::run(std::uint32_t steps) { _backend->run(steps); }

void CopperEngine::runWithProbeSampling(std::uint32_t steps, const ProbeSampler& sampler,
                                         const MidStepCorrection& midStepCorrection) {
    _backend->runWithProbeSampling(steps, sampler, midStepCorrection);
}

std::vector<float> CopperEngine::readField(Field field) const {
    std::vector<float> result;
    readField(field, result);
    return result;
}

void CopperEngine::readField(Field field, std::vector<float>& destination) const {
    _backend->readField(field, destination);
}

float CopperEngine::readFieldCell(Field field, std::uint32_t x, std::uint32_t y, std::uint32_t z) const {
    return _backend->readFieldCell(field, x, y, z);
}

void CopperEngine::writeFieldCell(Field field, std::uint32_t x, std::uint32_t y, std::uint32_t z, float value) {
    _backend->writeFieldCell(field, x, y, z, value);
}

double CopperEngine::estimateEnergy() const { return _backend->estimateEnergy(); }

const CopperGridDims& CopperEngine::dims() const { return _backend->dims(); }

std::size_t CopperEngine::currentAllocatedMetalBytes() const { return _backend->currentAllocatedMetalBytes(); }

} // namespace copper
