#include "simulation_result.hpp"

#include <optional>

#include "constants.hpp"
#include "logging.hpp"
#include "simulation.hpp"

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
                                    std::map<std::string, std::unique_ptr<Postprocessor>> postprocessors)
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

void SimulationResult::sparamToFile(const std::string& simulationName, const std::filesystem::path& outputDir) const {
    const Postprocessor* post = _postprocessorFor(simulationName);
    if (post == nullptr) {
        return;
    }
    post->sparamToFile(outputDir);
}

std::expected<SimulationResult, std::string> SimulationResult::run(const GeometryResult& geometry,
                                                                     const RunOptions& options) {
    std::vector<double> frequencies =
        linspace(geometry.config().frequency().start(), geometry.config().frequency().stop(),
                 constants::frequencySampleCount);

    std::map<std::string, std::unique_ptr<Postprocessor>> postprocessors;

    // GeometryResult grants SimulationResult friend access to its owned (shared, address-stable)
    // EMSConfig specifically so Simulation's constructor -- which needs a mutable SimulationConfig&
    // -- can be built here without GeometryResult itself exposing a public mutable accessor.
    for (auto& simConfig : geometry._config->simulations()) {
        if (auto dirResult = createDir(geometry.paths().simulationDir / simConfig.name()); !dirResult) {
            return std::unexpected(dirResult.error());
        }

        std::optional<Simulation> sim;
        auto& ports = simConfig.ports();
        for (std::size_t index = 0; index < ports.size(); ++index) {
            if (!ports[index].excite()) {
                continue;
            }
            sim.emplace(simConfig, geometry.config(), options, geometry.paths());
            logInfo("[" + simConfig.name() + "] Simulating with excitation on port #" + std::to_string(index));
            if (auto result = sim->loadGeometry(); !result) {
                return std::unexpected(result.error());
            }
            sim->setExcitation();
            sim->setupPorts(static_cast<std::int32_t>(index));
            if (auto result = sim->run(static_cast<std::int32_t>(index)); !result) {
                return std::unexpected(result.error());
            }
        }
        if (!sim.has_value()) {
            logError("[" + simConfig.name() + "] No port is configured to excite; nothing to simulate.");
            continue;
        }
        if (sim->ports().empty()) {
            sim->addVirtualPorts();
        }

        auto post = std::make_unique<Postprocessor>(frequencies, simConfig);
        for (std::size_t index = 0; index < ports.size(); ++index) {
            if (!ports[index].excite()) {
                continue;
            }
            auto paramsResult = sim->getPortParameters(static_cast<std::int32_t>(index), frequencies);
            if (!paramsResult) {
                return std::unexpected(paramsResult.error());
            }
            auto& [reflected, incident] = *paramsResult;
            for (std::size_t i = 0; i < ports.size(); ++i) {
                post->addPortData(static_cast<std::int32_t>(i), static_cast<std::int32_t>(index), incident[i],
                                   reflected[i]);
            }
        }
        post->calculateSparams();
        post->sparamToFile(geometry.paths().simulationDir / simConfig.name());
        postprocessors.emplace(simConfig.name(), std::move(post));
    }

    return SimulationResult(geometry, std::move(frequencies), std::move(postprocessors));
}

std::expected<SimulationResult, std::string> SimulationResult::load(const GeometryResult& geometry,
                                                                      const std::filesystem::path& inputDir) {
    std::vector<double> frequencies =
        linspace(geometry.config().frequency().start(), geometry.config().frequency().stop(),
                 constants::frequencySampleCount);

    std::map<std::string, std::unique_ptr<Postprocessor>> postprocessors;
    for (const auto& simConfig : geometry.config().simulations()) {
        auto post = std::make_unique<Postprocessor>(frequencies, simConfig);
        if (auto result = post->loadSparams(inputDir / simConfig.name()); !result) {
            return std::unexpected(result.error());
        }
        postprocessors.emplace(simConfig.name(), std::move(post));
    }

    return SimulationResult(geometry, std::move(frequencies), std::move(postprocessors));
}

} // namespace gerber2ems
