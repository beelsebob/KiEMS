#include "excitation_postprocess.hpp"

#include <algorithm>
#include <cmath>
#include <fstream>
#include <numbers>
#include <optional>
#include <sstream>

#include <matplot/matplot.h>

#include "logging.hpp"

namespace kiems {

using namespace Cu;

namespace {

// Port names are "<net>@<footprintRef>.<padNumber>" (port_resolution.cpp) -- net names routinely
// contain '/' (KiCad hierarchical net paths, e.g. "/MCU/USB/Upstream/Tx_{2}+"), which would
// otherwise be read as bogus path separators in an output filename.
std::string _sanitizeForFilename(std::string name) {
    for (char& c : name) {
        if (c == '/' || c == '\\' || c == ':') {
            c = '_';
        }
    }
    return name;
}

matplot::figure_handle _newFigure() { return matplot::figure(true); }

void _saveFigure(const matplot::figure_handle& fig, const std::filesystem::path& path, bool transparent) {
    if (transparent) {
        fig->color({0.0F, 1.0F, 1.0F, 1.0F});
    }
    fig->save(path.string());
}

} // namespace

double primaryRunDuration(const SimulationConfig& simConfig, const std::map<std::int32_t, double>& runDurations) {
    double longest = 0;
    for (const auto& excitation : simConfig.excitations()) {
        if (!excitation.isMain() || !excitation.drivenPortIndex().has_value()) {
            continue;
        }
        if (const auto it = runDurations.find(*excitation.drivenPortIndex()); it != runDurations.end()) {
            longest = std::max(longest, it->second);
        }
    }
    return longest;
}

double excitationRecordEnd(const ExcitationConfig& excitation, const SimulationConfig& simConfig,
                           const std::map<std::int32_t, double>& runDurations, const Frequency& frequency) {
    const double primary = primaryRunDuration(simConfig, runDurations);
    // Margin past a configured end when no FDTD run length is known, to see its decay/response.
    const double configuredEnd = 1.2 * (excitation.startTime() + excitation.duration());
    if (excitation.isMain() || excitation.durationMode() == ExcitationDurationMode::Continuous) {
        return primary > 0 ? primary : configuredEnd;
    }
    // Limited: the tone's end plus however long this port's own FDTD run took to decay once its
    // own (Gaussian) excitation stopped -- the same structure ringing down from the same port --
    // capped at the primary run's length.
    const auto run = excitation.drivenPortIndex().has_value() ? runDurations.find(*excitation.drivenPortIndex())
                                                               : runDurations.end();
    if (run == runDurations.end()) {
        return primary > 0 ? std::min(primary, configuredEnd) : configuredEnd;
    }
    const double fc = (frequency.stop() - frequency.start()) / 2.0;
    const double pulseLength = fc > 0 ? 9.0 / (std::numbers::pi * fc) : 0.0; // CalcGaussianPulsExcitation's
    const double decay = std::max(0.0, run->second - pulseLength);
    const double end = excitation.startTime() + excitation.duration() + decay;
    return primary > 0 ? std::min(primary, end) : end;
}

ExcitationPostprocessor::ExcitationPostprocessor(const SimulationConfig& simConfig, const Postprocessor& sParams,
                                                   std::vector<double> frequencies, const Frequency& frequency,
                                                   std::map<std::int32_t, double> runDurations)
    : _simConfig(simConfig),
      _sParams(sParams),
      _frequencies(std::move(frequencies)),
      _frequency(frequency),
      _runDurations(std::move(runDurations)) {}

std::map<std::int32_t, double> ExcitationPostprocessor::loadRunDurations(const std::filesystem::path& simulationDir,
                                                                          const SimulationConfig& simConfig) {
    std::map<std::int32_t, double> durations;
    for (std::size_t index = 0; index < simConfig.ports().size(); ++index) {
        if (!simConfig.ports()[index].excite()) {
            continue;
        }
        const std::filesystem::path runDir = simulationDir / std::to_string(index);
        std::error_code error;
        for (const auto& entry : std::filesystem::directory_iterator(runDir, error)) {
            // Every port's voltage probe ("<prefix>port_ut_<n>[suffix]", see Port::_label) spans the
            // whole run, so any one of them gives its length.
            if (!entry.is_regular_file() || entry.path().filename().string().find("port_ut_") == std::string::npos) {
                continue;
            }
            std::ifstream file(entry.path());
            std::string line;
            std::optional<double> lastTime;
            while (std::getline(file, line)) {
                if (line.empty() || line[0] == '%') {
                    continue;
                }
                std::istringstream iss(line);
                double t = 0;
                if (iss >> t) {
                    lastTime = t;
                }
            }
            if (lastTime.has_value()) {
                durations[static_cast<std::int32_t>(index)] = *lastTime;
                break;
            }
        }
    }
    return durations;
}

double ExcitationPostprocessor::_pickDt() const {
    // 8x oversampling above the highest analysis frequency -- comfortably past Nyquist, giving
    // clean time-domain resolution for the reconstructed waveform.
    const double stopFreq = _frequency.stop();
    return stopFreq > 0 ? 1.0 / (8.0 * stopFreq) : 1e-12;
}

void ExcitationPostprocessor::run() {
    if (_simConfig.excitations().empty()) {
        return;
    }

    _dt = _pickDt();
    double latestEnd = 0;
    for (const auto& excitation : _simConfig.excitations()) {
        latestEnd = std::max(latestEnd, excitationRecordEnd(excitation, _simConfig, _runDurations, _frequency));
    }
    const std::size_t sampleCount = static_cast<std::size_t>(std::ceil(latestEnd / _dt)) + 1;
    const std::size_t portCount = _simConfig.ports().size();
    _responses.assign(portCount, TimeWaveform{_dt, std::vector<double>(sampleCount, 0.0)});

    for (std::size_t outputPort = 0; outputPort < portCount; ++outputPort) {
        std::vector<TimeWaveform> contributions;

        for (const auto& excitation : _simConfig.excitations()) {
            if (!excitation.drivenPortIndex().has_value()) {
                continue; // Should never happen post-resolveSimulationPorts(); skip defensively.
            }
            const auto drivenPort = static_cast<std::int32_t>(*excitation.drivenPortIndex());

            const TimeWaveform stimulus =
                excitation.isMain()
                    // amplitude() defaults to 1.0 (the FDTD's own real per-port drive level) when
                    // unset -- a plain, single main excitation never needs to set it explicitly; it
                    // only matters once a second main excitation on the same net (e.g. a
                    // differential pair's other leg) needs a different relative level/sign.
                    ? synthesizeMainStimulus(_frequency, excitation.startTime(), excitation.duration(),
                                              excitation.phaseDegrees(), _dt, sampleCount,
                                              excitation.amplitude().value_or(1.0))
                : excitation.durationMode() == ExcitationDurationMode::Continuous
                    ? synthesizeContinuousTone(*excitation.frequency(), *excitation.amplitude(),
                                                excitation.phaseDegrees(), excitation.startTime(), _dt, sampleCount)
                    : synthesizeToneBurst(*excitation.frequency(), *excitation.amplitude(), excitation.phaseDegrees(),
                                           excitation.startTime(), excitation.duration(), _dt, sampleCount);

            const std::optional<std::vector<std::complex<double>>> transferFn =
                _sParams.getSParam(static_cast<std::int32_t>(outputPort), drivenPort);
            if (!transferFn.has_value()) {
                continue; // No S-parameter data for this port pair (e.g. never excited/measured).
            }

            const std::vector<std::complex<double>> stimulusSpectrum = forwardTransform(stimulus, _frequencies);
            std::vector<std::complex<double>> productSpectrum(_frequencies.size());
            for (std::size_t k = 0; k < _frequencies.size(); ++k) {
                productSpectrum[k] = stimulusSpectrum[k] * (*transferFn)[k];
            }

            TimeWaveform contribution = inverseTransform(_frequencies, productSpectrum, _dt, sampleCount);
            const auto recordedSamples =
                std::min(sampleCount, static_cast<std::size_t>(std::ceil(excitationRecordEnd(excitation, _simConfig, _runDurations, _frequency) / _dt)) + 1);
            std::fill(contribution.samples.begin() + static_cast<std::ptrdiff_t>(recordedSamples),
                      contribution.samples.end(), 0.0);
            contributions.push_back(std::move(contribution));
        }

        if (!contributions.empty()) {
            _responses[outputPort] = superpose(contributions);
        }
    }
}

const TimeWaveform& ExcitationPostprocessor::responseFor(std::int32_t portIndex) const {
    return _responses.at(static_cast<std::size_t>(portIndex));
}

void ExcitationPostprocessor::saveToFile(const std::filesystem::path& outputDir) const {
    const auto& ports = _simConfig.ports();
    for (std::size_t i = 0; i < _responses.size() && i < ports.size(); ++i) {
        if (_responses[i].samples.empty()) {
            continue;
        }
        const std::filesystem::path path =
            outputDir / (_sanitizeForFilename(ports[i].name()) + "_response.csv");
        std::ofstream file(path);
        file << "time_s,voltage_v\n";
        for (std::size_t n = 0; n < _responses[i].samples.size(); ++n) {
            file << (static_cast<double>(n) * _responses[i].dt) << "," << _responses[i].samples[n] << "\n";
        }
        logInfo("Saved excitation response to " + path.string());
    }
}

void ExcitationPostprocessor::renderPlots(const std::filesystem::path& outputDir, bool transparent) const {
    const auto& ports = _simConfig.ports();
    for (std::size_t i = 0; i < _responses.size() && i < ports.size(); ++i) {
        const TimeWaveform& response = _responses[i];
        if (response.samples.empty()) {
            continue;
        }
        std::vector<double> timeNs(response.samples.size());
        for (std::size_t n = 0; n < timeNs.size(); ++n) {
            timeNs[n] = static_cast<double>(n) * response.dt * 1e9;
        }

        auto fig = _newFigure();
        matplot::plot(timeNs, response.samples);
        matplot::xlabel("Time [ns]");
        matplot::ylabel("Voltage [V]");
        matplot::title(ports[i].name());
        matplot::grid(true);
        _saveFigure(fig, outputDir / (_sanitizeForFilename(ports[i].name()) + "_response.png"), transparent);
    }
}

} // namespace kiems
