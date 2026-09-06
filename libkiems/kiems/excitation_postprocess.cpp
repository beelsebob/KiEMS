#include "excitation_postprocess.hpp"

#include <algorithm>
#include <cmath>
#include <fstream>

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

ExcitationPostprocessor::ExcitationPostprocessor(const SimulationConfig& simConfig, const Postprocessor& sParams,
                                                   std::vector<double> frequencies, const Frequency& frequency)
    : _simConfig(simConfig), _sParams(sParams), _frequencies(std::move(frequencies)), _frequency(frequency) {}

double ExcitationPostprocessor::_pickDt() const {
    // 8x oversampling above the highest analysis frequency -- comfortably past Nyquist, giving
    // clean time-domain resolution for the reconstructed waveform.
    const double stopFreq = _frequency.stop();
    return stopFreq > 0 ? 1.0 / (8.0 * stopFreq) : 1e-12;
}

std::size_t ExcitationPostprocessor::_pickSampleCount(double dt) const {
    double latestEnd = 0;
    for (const auto& excitation : _simConfig.excitations()) {
        latestEnd = std::max(latestEnd, excitation.startTime() + excitation.duration());
    }
    latestEnd *= 1.2; // margin past the last excitation's own end, to see its full decay/response
    return static_cast<std::size_t>(std::ceil(latestEnd / dt)) + 1;
}

void ExcitationPostprocessor::run() {
    if (_simConfig.excitations().empty()) {
        return;
    }

    _dt = _pickDt();
    const std::size_t sampleCount = _pickSampleCount(_dt);
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

            contributions.push_back(inverseTransform(_frequencies, productSpectrum, _dt, sampleCount));
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
