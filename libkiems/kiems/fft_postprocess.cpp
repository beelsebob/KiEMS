#include "fft_postprocess.hpp"

#include <cmath>
#include <numbers>

#if defined(__APPLE__)
#include <Accelerate/Accelerate.h>
#endif

namespace kiems {

#if defined(__APPLE__)

// Both transforms below are the same shape of computation -- for each output sample, a dot product
// of some fixed vector (the time-domain samples, or the spectrum's real/imaginary parts) against a
// per-output-sample cosine/sine table -- just with the roles of "outer loop" and "table" swapped
// between forwardTransform() (outer: frequency, table: cos/sin(-omega_k * t_n) over samples) and
// inverseTransform() (outer: time sample, table: cos/sin(omega_k * t) over frequencies). Building
// each table via vvcos()/vvsin() (vectorized transcendental functions) and reducing it with
// vDSP_dotprD() (vectorized multiply-accumulate) is a straight vectorization of the exact same
// direct-quadrature sum the portable #else loop computes -- not a different (e.g. packed-FFT)
// algorithm, so results match to floating-point rounding, just faster on real hardware.
std::vector<std::complex<double>> forwardTransform(const TimeWaveform& time, const std::vector<double>& frequencies) {
    const auto n = static_cast<int>(time.samples.size());
    std::vector<std::complex<double>> result(frequencies.size());
    if (n == 0) {
        return result;
    }

    std::vector<double> t(static_cast<std::size_t>(n));
    for (int i = 0; i < n; ++i) {
        t[static_cast<std::size_t>(i)] = static_cast<double>(i) * time.dt;
    }

    std::vector<double> theta(static_cast<std::size_t>(n));
    std::vector<double> cosTheta(static_cast<std::size_t>(n));
    std::vector<double> sinTheta(static_cast<std::size_t>(n));
    for (std::size_t k = 0; k < frequencies.size(); ++k) {
        double negOmega = -2.0 * std::numbers::pi * frequencies[k];
        vDSP_vsmulD(t.data(), 1, &negOmega, theta.data(), 1, static_cast<vDSP_Length>(n));
        vvcos(cosTheta.data(), theta.data(), &n);
        vvsin(sinTheta.data(), theta.data(), &n);

        double real = 0.0;
        double imag = 0.0;
        vDSP_dotprD(time.samples.data(), 1, cosTheta.data(), 1, &real, static_cast<vDSP_Length>(n));
        vDSP_dotprD(time.samples.data(), 1, sinTheta.data(), 1, &imag, static_cast<vDSP_Length>(n));
        result[k] = std::complex<double>(real, imag) * time.dt;
    }
    return result;
}

TimeWaveform inverseTransform(const std::vector<double>& frequencies, const std::vector<std::complex<double>>& spectrum,
                                double dt, std::size_t sampleCount) {
    TimeWaveform result;
    result.dt = dt;
    result.samples.assign(sampleCount, 0.0);
    const auto k = static_cast<int>(frequencies.size());
    if (k < 2) {
        return result;
    }
    // Frequencies are Postprocessor's own linspace -- uniformly spaced by construction.
    const double df = frequencies[1] - frequencies[0];

    std::vector<double> omega(static_cast<std::size_t>(k));
    std::vector<double> specReal(static_cast<std::size_t>(k));
    std::vector<double> specImag(static_cast<std::size_t>(k));
    for (int i = 0; i < k; ++i) {
        omega[static_cast<std::size_t>(i)] = 2.0 * std::numbers::pi * frequencies[static_cast<std::size_t>(i)];
        specReal[static_cast<std::size_t>(i)] = spectrum[static_cast<std::size_t>(i)].real();
        specImag[static_cast<std::size_t>(i)] = spectrum[static_cast<std::size_t>(i)].imag();
    }

    std::vector<double> theta(static_cast<std::size_t>(k));
    std::vector<double> cosTheta(static_cast<std::size_t>(k));
    std::vector<double> sinTheta(static_cast<std::size_t>(k));
    for (std::size_t n = 0; n < sampleCount; ++n) {
        double t = static_cast<double>(n) * dt;
        vDSP_vsmulD(omega.data(), 1, &t, theta.data(), 1, static_cast<vDSP_Length>(k));
        vvcos(cosTheta.data(), theta.data(), &k);
        vvsin(sinTheta.data(), theta.data(), &k);

        // real(spectrum[i] * (cos(theta_i) + i*sin(theta_i))) = specReal*cos - specImag*sin, summed
        // over i -- the same real(sum) the portable loop below takes at the end, just accumulated as
        // two dot products instead of one complex running sum.
        double cosDot = 0.0;
        double sinDot = 0.0;
        vDSP_dotprD(specReal.data(), 1, cosTheta.data(), 1, &cosDot, static_cast<vDSP_Length>(k));
        vDSP_dotprD(specImag.data(), 1, sinTheta.data(), 1, &sinDot, static_cast<vDSP_Length>(k));
        // Single-sided spectrum convention (only positive frequencies given): double the real part,
        // matching the same convention ports.cpp's dftTimeToFreq already uses in the other direction.
        result.samples[n] = 2.0 * (cosDot - sinDot) * df;
    }
    return result;
}

#else

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

#endif

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

} // namespace kiems
