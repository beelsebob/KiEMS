#include "fft_postprocess.hpp"

#include <cmath>
#include <numbers>

namespace kicad_ems {

std::vector<std::complex<double>> forwardTransform(const TimeWaveform& time, const std::vector<double>& frequencies) {
    std::vector<std::complex<double>> result(frequencies.size());
    for (std::size_t k = 0; k < frequencies.size(); ++k) {
        const double omega = 2.0 * std::numbers::pi * frequencies[k];
        std::complex<double> sum(0.0, 0.0);
        for (std::size_t n = 0; n < time.samples.size(); ++n) {
            const double t = static_cast<double>(n) * time.dt;
            sum += time.samples[n] * std::complex<double>(std::cos(-omega * t), std::sin(-omega * t));
        }
        result[k] = sum * time.dt;
    }
    return result;
}

TimeWaveform inverseTransform(const std::vector<double>& frequencies, const std::vector<std::complex<double>>& spectrum,
                                double dt, std::size_t sampleCount) {
    TimeWaveform result;
    result.dt = dt;
    result.samples.assign(sampleCount, 0.0);
    if (frequencies.size() < 2) {
        return result;
    }
    // Frequencies are Postprocessor's own linspace -- uniformly spaced by construction.
    const double df = frequencies[1] - frequencies[0];
    for (std::size_t n = 0; n < sampleCount; ++n) {
        const double t = static_cast<double>(n) * dt;
        std::complex<double> sum(0.0, 0.0);
        for (std::size_t k = 0; k < frequencies.size(); ++k) {
            const double omega = 2.0 * std::numbers::pi * frequencies[k];
            sum += spectrum[k] * std::complex<double>(std::cos(omega * t), std::sin(omega * t));
        }
        // Single-sided spectrum convention (only positive frequencies given): double the real part,
        // matching the same convention ports.cpp's dftTimeToFreq already uses in the other direction.
        result.samples[n] = 2.0 * sum.real() * df;
    }
    return result;
}

TimeWaveform synthesizeMainStimulus(const Frequency& freq, double startTime, double duration, double phaseDegrees,
                                      double dt, std::size_t sampleCount, double amplitude) {
    TimeWaveform result;
    result.dt = dt;
    result.samples.assign(sampleCount, 0.0);

    const double f0 = (freq.start() + freq.stop()) / 2.0;
    const double fc = (freq.stop() - freq.start()) / 2.0;
    if (fc <= 0) {
        return result;
    }
    const double phaseRadians = phaseDegrees * std::numbers::pi / 180.0;

    for (std::size_t n = 0; n < sampleCount; ++n) {
        const double t = static_cast<double>(n) * dt;
        if (t < startTime || t > startTime + duration) {
            continue;
        }
        const double tau = t - startTime;
        result.samples[n] = amplitude *
            std::cos(2.0 * std::numbers::pi * f0 * (tau - 9.0 / (2.0 * std::numbers::pi * fc)) + phaseRadians) *
            std::exp(-std::pow(2.0 * std::numbers::pi * fc * tau / 3.0 - 3.0, 2));
    }
    return result;
}

TimeWaveform synthesizeToneBurst(double frequencyHz, double amplitude, double phaseDegrees, double startTime,
                                   double duration, double dt, std::size_t sampleCount) {
    TimeWaveform result;
    result.dt = dt;
    result.samples.assign(sampleCount, 0.0);
    if (duration <= 0) {
        return result;
    }
    const double phaseRadians = phaseDegrees * std::numbers::pi / 180.0;

    for (std::size_t n = 0; n < sampleCount; ++n) {
        const double t = static_cast<double>(n) * dt;
        if (t < startTime || t > startTime + duration) {
            continue;
        }
        const double tau = t - startTime;
        const double window = 0.5 * (1.0 - std::cos(2.0 * std::numbers::pi * tau / duration)); // Hann
        result.samples[n] = amplitude * window * std::sin(2.0 * std::numbers::pi * frequencyHz * tau + phaseRadians);
    }
    return result;
}

TimeWaveform superpose(const std::vector<TimeWaveform>& waveforms) {
    TimeWaveform result;
    if (waveforms.empty()) {
        return result;
    }
    result.dt = waveforms.front().dt;
    result.samples.assign(waveforms.front().samples.size(), 0.0);
    for (const auto& waveform : waveforms) {
        for (std::size_t n = 0; n < result.samples.size() && n < waveform.samples.size(); ++n) {
            result.samples[n] += waveform.samples[n];
        }
    }
    return result;
}

} // namespace kicad_ems
