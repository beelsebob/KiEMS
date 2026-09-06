#include "eye_diagram.hpp"

#include <algorithm>
#include <cmath>
#include <cstdint>

#include "fft_postprocess.hpp"

namespace kicad_ems {

std::optional<EyeDiagramData> computeEyeDiagram(
    const std::vector<double>& frequencies,
    const std::vector<std::complex<double>>& transferFunction,
    double bitRate) {
    if (frequencies.empty() || frequencies.size() != transferFunction.size() || !(bitRate > 0) ||
        !std::isfinite(bitRate)) {
        return std::nullopt;
    }

    constexpr std::size_t samplesPerUI = 32;
    constexpr std::size_t bitCount = 255; // two complete PRBS7 periods plus one bit
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

    std::vector<std::complex<double>> spectrum = forwardTransform(source, frequencies);
    for (std::size_t f = 0; f < spectrum.size(); ++f) {
        spectrum[f] *= transferFunction[f];
    }
    const TimeWaveform received = inverseTransform(frequencies, spectrum, dt, source.samples.size());

    // Recover the phase at which received transitions occur. Scoring the average first
    // difference at each possible sample-within-UI phase handles arbitrary propagation delay and
    // leaves the eye centered on a transition rather than on the source clock's un-delayed phase.
    std::size_t transitionPhase = 0;
    double bestScore = -1;
    for (std::size_t phase = 0; phase < samplesPerUI; ++phase) {
        double score = 0;
        std::size_t count = 0;
        for (std::size_t bit = 16; bit + 16 < bitCount; ++bit) {
            const std::size_t sample = bit * samplesPerUI + phase;
            if (sample > 0 && sample < received.samples.size()) {
                score += std::abs(received.samples[sample] - received.samples[sample - 1]);
                ++count;
            }
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

    for (std::size_t bit = 16; bit + 16 < bitCount; ++bit) {
        const std::ptrdiff_t start = static_cast<std::ptrdiff_t>(bit * samplesPerUI + transitionPhase) -
                                     static_cast<std::ptrdiff_t>(samplesPerUI / 2);
        const std::ptrdiff_t end = start + static_cast<std::ptrdiff_t>(2 * samplesPerUI);
        if (start < 0 || end >= static_cast<std::ptrdiff_t>(received.samples.size())) {
            continue;
        }
        std::vector<double> trace(result.timeUI.size());
        bool finite = true;
        for (std::size_t i = 0; i < trace.size(); ++i) {
            trace[i] = received.samples[static_cast<std::size_t>(start + static_cast<std::ptrdiff_t>(i))];
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

} // namespace kicad_ems
