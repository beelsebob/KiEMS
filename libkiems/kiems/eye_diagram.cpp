#include "eye_diagram.hpp"

#include <algorithm>
#include <cmath>
#include <cstdint>

#include "fft_postprocess.hpp"

namespace kiems {

namespace {

constexpr double kTwoPi = 6.283185307179586476925286766559;

// The channel in polar form with its phase unwrapped along frequency. Interpolating real and
// imaginary parts linearly cuts the chord across each sample's phase rotation (a delayed channel
// rotates quickly), dipping the magnitude between samples; magnitude and unwrapped phase follow
// the actual response.
struct PolarTransfer {
    std::vector<double> frequencies;
    std::vector<double> magnitude;
    std::vector<double> phase;
};

PolarTransfer makePolarTransfer(
    const std::vector<double>& frequencies,
    const std::vector<std::complex<double>>& transferFunction) {
    PolarTransfer polar;
    polar.frequencies = frequencies;
    polar.magnitude.resize(frequencies.size());
    polar.phase.resize(frequencies.size());
    for (std::size_t f = 0; f < frequencies.size(); ++f) {
        polar.magnitude[f] = std::abs(transferFunction[f]);
        double phase = std::arg(transferFunction[f]);
        if (f > 0) {
            phase += kTwoPi * std::round((polar.phase[f - 1] - phase) / kTwoPi);
        }
        polar.phase[f] = phase;
    }

    // Simulated sweeps usually start well above DC, but most of an NRZ pattern's energy sits below
    // the first sample. Holding the first complex value there applies that sample's delay-induced
    // phase to every low-frequency bin, which scrambles the bit history into heavy false ISI.
    // Instead the band below is extended as a pure delay down to a real DC gain, so the phase at
    // the first sample must be the one consistent with the delay: the principal value only fixes
    // it modulo 2*pi, so pick the branch nearest the delay implied by the phase slope.
    if (frequencies.size() >= 2 && frequencies.front() > 0) {
        const std::size_t slopeEnd = std::min<std::size_t>(frequencies.size() - 1, 4);
        const double slope = (polar.phase[slopeEnd] - polar.phase[0]) /
                             (frequencies[slopeEnd] - frequencies[0]);
        if (std::isfinite(slope)) {
            const double expected = slope * frequencies.front();
            const double shift = kTwoPi * std::round((expected - polar.phase.front()) / kTwoPi);
            for (double& phase : polar.phase) {
                phase += shift;
            }
        }
    }
    return polar;
}

std::complex<double> interpolateTransfer(const PolarTransfer& transfer, double frequency) {
    const std::vector<double>& frequencies = transfer.frequencies;
    if (frequency <= frequencies.front()) {
        if (!(frequencies.front() > 0)) {
            return std::polar(transfer.magnitude.front(), transfer.phase.front());
        }
        // Constant magnitude and linear phase from zero at DC: a pure delay matching the first
        // sample. Magnitude is held because loss below the sweep cannot be less than at its start.
        const double fraction = std::max(frequency, 0.0) / frequencies.front();
        return std::polar(transfer.magnitude.front(), transfer.phase.front() * fraction);
    }
    if (frequency >= frequencies.back()) {
        return std::polar(transfer.magnitude.back(), transfer.phase.back());
    }
    const auto upper = std::lower_bound(frequencies.begin(), frequencies.end(), frequency);
    const std::size_t upperIndex = static_cast<std::size_t>(upper - frequencies.begin());
    const std::size_t lowerIndex = upperIndex - 1;
    const double span = frequencies[upperIndex] - frequencies[lowerIndex];
    if (!(span > 0)) {
        return std::polar(transfer.magnitude[lowerIndex], transfer.phase[lowerIndex]);
    }
    const double fraction = (frequency - frequencies[lowerIndex]) / span;
    const double magnitude = transfer.magnitude[lowerIndex] +
                             (transfer.magnitude[upperIndex] - transfer.magnitude[lowerIndex]) * fraction;
    const double phase = transfer.phase[lowerIndex] +
                         (transfer.phase[upperIndex] - transfer.phase[lowerIndex]) * fraction;
    return std::polar(magnitude, phase);
}

} // namespace

std::optional<EyeDiagramData> computeEyeDiagram(
    const std::vector<double>& frequencies,
    const std::vector<std::complex<double>>& transferFunction,
    double bitRate) {
    if (frequencies.empty() || frequencies.size() != transferFunction.size() || !(bitRate > 0) ||
        !std::isfinite(bitRate)) {
        return std::nullopt;
    }

    constexpr std::size_t samplesPerUI = 32;
    // One exact PRBS7 period makes the source periodic at the transform boundary. The old 255-bit
    // buffer was transformed directly at the simulation's frequency samples; those frequencies
    // generally describe a much shorter periodic time window, aliasing the PRBS into an apparently
    // transition-only oscillation after the inverse transform.
    constexpr std::size_t bitCount = 127;
    const double dt = 1.0 / (bitRate * static_cast<double>(samplesPerUI));

    TimeWaveform source;
    source.dt = dt;
    source.samples.resize(bitCount * samplesPerUI);
    std::uint32_t lfsr = 0x7fU;
    for (std::size_t bitIndex = 0; bitIndex < bitCount; ++bitIndex) {
        const double level = (lfsr & 1U) != 0 ? 1.0 : -1.0;
        std::fill_n(source.samples.begin() + static_cast<std::ptrdiff_t>(bitIndex * samplesPerUI),
                    samplesPerUI, level);
        const std::uint32_t feedback = ((lfsr >> 6U) ^ (lfsr >> 5U)) & 1U;
        lfsr = ((lfsr << 1U) & 0x7eU) | feedback;
    }

    // Transform on the waveform's own Fourier grid, then interpolate the simulated channel onto
    // that grid. This makes the forward/inverse pair describe the same 127-UI periodic waveform
    // regardless of the simulation's frequency spacing.
    const double transformDf = 1.0 / (static_cast<double>(source.samples.size()) * dt);
    const double nyquist = 0.5 / dt;
    const double maximumFrequency = std::min(frequencies.back(), nyquist);
    if (!(maximumFrequency >= 0) || !std::isfinite(maximumFrequency)) {
        return std::nullopt;
    }
    const std::size_t transformFrequencyCount =
        static_cast<std::size_t>(std::floor(maximumFrequency / transformDf)) + 1;
    if (transformFrequencyCount < 2) {
        return std::nullopt;
    }
    const PolarTransfer polarTransfer = makePolarTransfer(frequencies, transferFunction);
    std::vector<double> transformFrequencies(transformFrequencyCount);
    std::vector<std::complex<double>> resampledTransfer(transformFrequencyCount);
    for (std::size_t f = 0; f < transformFrequencyCount; ++f) {
        transformFrequencies[f] = static_cast<double>(f) * transformDf;
        resampledTransfer[f] = interpolateTransfer(polarTransfer, transformFrequencies[f]);
    }

    std::vector<std::complex<double>> spectrum = forwardTransform(source, transformFrequencies);
    for (std::size_t f = 0; f < spectrum.size(); ++f) {
        spectrum[f] *= resampledTransfer[f];
    }
    const TimeWaveform received = inverseTransform(transformFrequencies, spectrum, dt, source.samples.size());

    // Recover the phase at which received transitions occur. Scoring the average first
    // difference at each possible sample-within-UI phase handles arbitrary propagation delay and
    // leaves the eye centered on a transition rather than on the source clock's un-delayed phase.
    std::size_t transitionPhase = 0;
    double bestScore = -1;
    for (std::size_t phase = 0; phase < samplesPerUI; ++phase) {
        double score = 0;
        std::size_t count = 0;
        for (std::size_t bit = 0; bit < bitCount; ++bit) {
            const std::size_t sample = bit * samplesPerUI + phase;
            const std::size_t preceding = (sample + received.samples.size() - 1) % received.samples.size();
            score += std::abs(received.samples[sample] - received.samples[preceding]);
            ++count;
        }
        if (count > 0 && score / static_cast<double>(count) > bestScore) {
            bestScore = score / static_cast<double>(count);
            transitionPhase = phase;
        }
    }

    EyeDiagramData result;
    result.bitRate = bitRate;
    result.timeUI.resize(2 * samplesPerUI + 1);
    for (std::size_t i = 0; i < result.timeUI.size(); ++i) {
        result.timeUI[i] = static_cast<double>(i) / static_cast<double>(samplesPerUI) - 0.5;
    }

    for (std::size_t bit = 0; bit < bitCount; ++bit) {
        const std::ptrdiff_t start = static_cast<std::ptrdiff_t>(bit * samplesPerUI + transitionPhase) -
                                     static_cast<std::ptrdiff_t>(samplesPerUI / 2);
        std::vector<double> trace(result.timeUI.size());
        bool finite = true;
        for (std::size_t i = 0; i < trace.size(); ++i) {
            const std::ptrdiff_t unwrapped = start + static_cast<std::ptrdiff_t>(i);
            const std::ptrdiff_t sampleCount = static_cast<std::ptrdiff_t>(received.samples.size());
            const std::size_t wrapped =
                static_cast<std::size_t>((unwrapped % sampleCount + sampleCount) % sampleCount);
            trace[i] = received.samples[wrapped];
            finite = finite && std::isfinite(trace[i]);
        }
        if (finite) {
            result.traces.push_back(std::move(trace));
        }
    }

    if (result.traces.empty()) {
        return std::nullopt;
    }
    return result;
}

} // namespace kiems
