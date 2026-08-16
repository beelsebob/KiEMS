#include "postprocess_result.hpp"

#include "constants.hpp"

namespace gerber2ems {

namespace {

std::vector<double> linspace(double start, double stop, std::int32_t num) {
    std::vector<double> result(static_cast<std::size_t>(num));
    if (num == 1) {
        result[0] = start;
        return result;
    }
    for (std::int32_t i = 0; i < num; ++i) {
        result[static_cast<std::size_t>(i)] = start + static_cast<double>(i) * (stop - start) / (num - 1);
    }
    return result;
}

} // namespace

PostprocessResult::PostprocessResult(GeometryResult geometry,
                                      std::map<std::string, std::unique_ptr<Postprocessor>> postprocessors)
    : _geometry(std::move(geometry)), _postprocessors(std::move(postprocessors)) {}

const Postprocessor* PostprocessResult::postprocessorFor(const std::string& simulationName) const {
    const auto it = _postprocessors.find(simulationName);
    return it == _postprocessors.end() ? nullptr : it->second.get();
}

std::expected<PostprocessResult, std::string> PostprocessResult::compute(const SimulationResult& simulation) {
    const std::vector<double> frequencies =
        linspace(simulation.config().frequency().start(), simulation.config().frequency().stop(),
                 constants::frequencySampleCount);

    std::map<std::string, std::unique_ptr<Postprocessor>> postprocessors;
    for (const auto& simConfig : simulation.config().simulations()) {
        auto post = std::make_unique<Postprocessor>(frequencies, simConfig);
        const auto portCount = static_cast<std::int32_t>(simConfig.ports().size());
        for (std::int32_t output = 0; output < portCount; ++output) {
            for (std::int32_t input = 0; input < portCount; ++input) {
                if (auto sParam = simulation.getSParam(simConfig.name(), output, input); sParam.has_value()) {
                    post->setSParam(output, input, std::move(*sParam));
                }
            }
        }
        post->processData();
        postprocessors.emplace(simConfig.name(), std::move(post));
    }

    return PostprocessResult(simulation.geometry(), std::move(postprocessors));
}

std::optional<std::vector<std::complex<double>>> PostprocessResult::getImpedance(const std::string& simulationName,
                                                                                   std::int32_t port) const {
    const Postprocessor* post = postprocessorFor(simulationName);
    return post == nullptr ? std::nullopt : post->getImpedance(port);
}

std::optional<std::vector<std::complex<double>>> PostprocessResult::getSParam(const std::string& simulationName,
                                                                                std::int32_t outputPort,
                                                                                std::int32_t inputPort) const {
    const Postprocessor* post = postprocessorFor(simulationName);
    return post == nullptr ? std::nullopt : post->getSParam(outputPort, inputPort);
}

std::optional<std::vector<double>> PostprocessResult::frequencies(const std::string& simulationName) const {
    const Postprocessor* post = postprocessorFor(simulationName);
    return post == nullptr ? std::nullopt : std::optional(post->frequencies());
}

std::optional<std::vector<double>> PostprocessResult::getDelay(const std::string& simulationName,
                                                                 std::int32_t outputPort, std::int32_t inputPort) const {
    const Postprocessor* post = postprocessorFor(simulationName);
    return post == nullptr ? std::nullopt : post->getDelay(outputPort, inputPort);
}

std::optional<Postprocessor::DiffPairSdd> PostprocessResult::getDiffPairSdd(const std::string& simulationName,
                                                                             std::int32_t diffPairIndex) const {
    const Postprocessor* post = postprocessorFor(simulationName);
    return post == nullptr ? std::nullopt : post->getDiffPairSdd(diffPairIndex);
}

std::optional<Postprocessor::DiffPairImpedance> PostprocessResult::getDiffPairImpedance(
    const std::string& simulationName, std::int32_t diffPairIndex) const {
    const Postprocessor* post = postprocessorFor(simulationName);
    return post == nullptr ? std::nullopt : post->getDiffPairImpedance(diffPairIndex);
}

void PostprocessResult::saveToFile(const std::string& simulationName, const std::filesystem::path& outputDir) const {
    if (const Postprocessor* post = postprocessorFor(simulationName); post != nullptr) {
        post->saveToFile(outputDir);
    }
}

void PostprocessResult::renderSParams(const std::string& simulationName, bool plotPhase, bool transparent,
                                       const std::filesystem::path& outputDir) const {
    if (const Postprocessor* post = postprocessorFor(simulationName); post != nullptr) {
        post->renderSParams(plotPhase, transparent, outputDir);
    }
}

void PostprocessResult::renderDiffPairSParams(const std::string& simulationName, bool transparent,
                                               const std::filesystem::path& outputDir) const {
    if (const Postprocessor* post = postprocessorFor(simulationName); post != nullptr) {
        post->renderDiffPairSParams(transparent, outputDir);
    }
}

void PostprocessResult::renderDiffImpedance(const std::string& simulationName, bool transparent,
                                             const std::filesystem::path& outputDir) const {
    if (const Postprocessor* post = postprocessorFor(simulationName); post != nullptr) {
        post->renderDiffImpedance(transparent, outputDir);
    }
}

void PostprocessResult::renderImpedance(const std::string& simulationName, bool transparent,
                                         const std::filesystem::path& outputDir) const {
    if (const Postprocessor* post = postprocessorFor(simulationName); post != nullptr) {
        post->renderImpedance(transparent, outputDir);
    }
}

void PostprocessResult::renderSmith(const std::string& simulationName, bool transparent,
                                     const std::filesystem::path& outputDir) const {
    if (const Postprocessor* post = postprocessorFor(simulationName); post != nullptr) {
        post->renderSmith(transparent, outputDir);
    }
}

void PostprocessResult::renderTraceDelays(const std::string& simulationName, bool transparent,
                                           const std::filesystem::path& outputDir) const {
    if (const Postprocessor* post = postprocessorFor(simulationName); post != nullptr) {
        post->renderTraceDelays(transparent, outputDir);
    }
}

} // namespace gerber2ems
