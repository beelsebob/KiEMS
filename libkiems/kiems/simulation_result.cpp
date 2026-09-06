#include "simulation_result.hpp"

#include <optional>

#include "constants.hpp"
#include "logging.hpp"
#include "simulation.hpp"
#include "simulation_data.hpp"

namespace kiems {

using namespace Cu;

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

std::expected<void, std::string> createDir(const std::filesystem::path& directoryPath) {
    std::error_code ec;
    std::filesystem::create_directories(directoryPath, ec);
    if (ec) {
        return std::unexpected("Failed to create directory " + directoryPath.string() + ": " + ec.message());
    }
    return {};
}

} // namespace

SimulationResult::SimulationResult(GeometryResult geometry, std::vector<double> frequencies,
                                    std::map<std::string, std::shared_ptr<Postprocessor>> postprocessors)
    : _geometry(std::move(geometry)), _frequencies(std::move(frequencies)), _postprocessors(std::move(postprocessors)) {}

const Postprocessor* SimulationResult::_postprocessorFor(const std::string& simulationName) const {
    const auto it = _postprocessors.find(simulationName);
    return it == _postprocessors.end() ? nullptr : it->second.get();
}

std::optional<std::vector<std::complex<double>>> SimulationResult::getSParam(const std::string& simulationName,
                                                                               std::int32_t outputPort,
                                                                               std::int32_t inputPort) const {
    const Postprocessor* post = _postprocessorFor(simulationName);
    if (post == nullptr) {
        return std::nullopt;
    }
    return post->getSParam(outputPort, inputPort);
}

std::optional<std::vector<std::complex<double>>> SimulationResult::getProbeVoltage(const std::string& simulationName,
                                                                                      std::int32_t probe,
                                                                                      std::int32_t excitedPort) const {
    const Postprocessor* post = _postprocessorFor(simulationName);
    if (post == nullptr) {
        return std::nullopt;
    }
    return post->getProbeVoltage(probe, excitedPort);
}

std::optional<std::vector<std::complex<double>>> SimulationResult::getProbeCurrent(const std::string& simulationName,
                                                                                      std::int32_t probe,
                                                                                      std::int32_t excitedPort) const {
    const Postprocessor* post = _postprocessorFor(simulationName);
    if (post == nullptr) {
        return std::nullopt;
    }
    return post->getProbeCurrent(probe, excitedPort);
}

std::optional<std::vector<std::complex<double>>> SimulationResult::getProbeImpedance(const std::string& simulationName,
                                                                                        std::int32_t probe,
                                                                                        std::int32_t excitedPort) const {
    const Postprocessor* post = _postprocessorFor(simulationName);
    if (post == nullptr) {
        return std::nullopt;
    }
    return post->getProbeImpedance(probe, excitedPort);
}

void SimulationResult::sparamToFile(const std::string& simulationName, const std::filesystem::path& outputDir) const {
    const Postprocessor* post = _postprocessorFor(simulationName);
    if (post == nullptr) {
        return;
    }
    post->sparamToFile(outputDir);
}

void SimulationResult::probeToFile(const std::string& simulationName, const std::filesystem::path& outputDir) const {
    const Postprocessor* post = _postprocessorFor(simulationName);
    if (post == nullptr) {
        return;
    }
    post->probeToFile(outputDir);
}

std::expected<SimulationResult, std::string> SimulationResult::run(const GeometryResult& geometry,
                                                                     const RunOptions& options,
                                                                     const FDTDPortRunner& portRunner) {
    std::vector<double> frequencies =
        linspace(geometry.config().frequency().start(), geometry.config().frequency().stop(),
                 constants::frequencySampleCount);

    std::map<std::string, std::shared_ptr<Postprocessor>> postprocessors;

    // GeometryResult grants SimulationResult friend access to its owned (shared, address-stable)
    // EMSConfig specifically so Simulation's constructor -- which needs a mutable SimulationConfig&
    // -- can be built here without GeometryResult itself exposing a public mutable accessor.
    for (auto& simConfig : geometry._config->simulations()) {
        if (auto dirResult = createDir(geometry.paths().simulationDir / simConfig.name()); !dirResult) {
            return std::unexpected(dirResult.error());
        }

        // Always populated -- build() and load() both produce a real SimulationData<Grid> for
        // every simulation in config() (see GeometryResult::simulationData()'s own doc comment), so
        // there is exactly one code path here regardless of which one produced `geometry`.
        const SimulationData<SimulationStage::Grid>* gridData = geometry.simulationData(simConfig.name());

        // generateResults() below runs every excited port's own FDTD pass internally (see
        // simulation_data.hpp) -- logged here, per port, before the (single) call that actually
        // does the work, so this still reads the same as before that restructure: one line per
        // excited port, not just one for the whole simulation.
        for (std::size_t index = 0; index < simConfig.ports().size(); ++index) {
            if (simConfig.ports()[index].excite()) {
                logInfo("[" + simConfig.name() + "] Simulating with excitation on port #" + std::to_string(index));
            }
        }
        auto resultsResult = generateResults(*gridData, geometry.config(), options, geometry.paths(), frequencies,
                                              portRunner);
        if (!resultsResult) {
            return std::unexpected(resultsResult.error());
        }
        if (resultsResult->byExcitedPort.empty()) {
            logError("[" + simConfig.name() + "] No port is configured to excite; nothing to simulate.");
            continue;
        }

        // The two remaining stages -- see simulation_data.hpp's own doc comment on why
        // SimulationData<Results>/<Postprocessing> carry every earlier stage's data forward too
        // (not needed here, but keeps the chain's own invariant: a SimulationData<Postprocessing>
        // could still answer geometry()/grid()/results() if some future caller wanted them).
        const SimulationData<SimulationStage::Results> resultsData(*gridData, std::move(*resultsResult));
        const SimulationData<SimulationStage::Postprocessing> postprocessingData(
            resultsData, generatePostprocessing(resultsData, frequencies));

        const std::shared_ptr<Postprocessor>& post = postprocessingData.postprocessing().postprocessor;
        post->sparamToFile(geometry.paths().simulationDir / simConfig.name());
        post->probeToFile(geometry.paths().simulationDir / simConfig.name());
        postprocessors.emplace(simConfig.name(), post);
    }

    return SimulationResult(geometry, std::move(frequencies), std::move(postprocessors));
}

std::expected<SimulationResult, std::string> SimulationResult::load(const GeometryResult& geometry,
                                                                      const std::filesystem::path& inputDir) {
    std::vector<double> frequencies =
        linspace(geometry.config().frequency().start(), geometry.config().frequency().stop(),
                 constants::frequencySampleCount);

    std::map<std::string, std::shared_ptr<Postprocessor>> postprocessors;
    for (const auto& simConfig : geometry.config().simulations()) {
        auto post = std::make_shared<Postprocessor>(frequencies, simConfig);
        if (auto result = post->loadSparams(inputDir / simConfig.name()); !result) {
            return std::unexpected(result.error());
        }
        if (auto result = post->loadProbes(inputDir / simConfig.name()); !result) {
            return std::unexpected(result.error());
        }
        postprocessors.emplace(simConfig.name(), std::move(post));
    }

    return SimulationResult(geometry, std::move(frequencies), std::move(postprocessors));
}

} // namespace kiems
