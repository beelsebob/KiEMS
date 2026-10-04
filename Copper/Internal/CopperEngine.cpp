#include "CopperEngine.hpp"

#include "CopperEngineBackend.hpp"

namespace copper {

CopperEngine::CopperEngine(const CopperYeeGrid& grid, const CopperExcitation& excitation, const CopperCPML& cpml,
                            Backend backend, const CopperDomainMask& domainMask)
    : _backend(backend == Backend::Metal ? makeMetalEngineBackend(grid, excitation, cpml, domainMask)
                                          : makeCPUEngineBackend(grid, excitation, cpml, domainMask)) {}

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

std::size_t CopperEngine::fusedTileCount() const { return _backend->fusedTileCount(); }

void CopperEngine::setLumpedRLC(const std::vector<CopperLumpedRLCCell>& cells) { _backend->setLumpedRLC(cells); }

void CopperEngine::declareMidStepCorrectionCells(const std::vector<CopperLumpedRLCCell>& cells) {
    _backend->declareMidStepCorrectionCells(cells);
}

} // namespace copper
