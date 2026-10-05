#include "eye_diagram.hpp"

#include <algorithm>
#include <array>
#include <cmath>
#include <cstdint>
#include <limits>
#include <random>
#include <utility>

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

constexpr std::size_t kSamplesPerUI = 32;
// One exact PRBS7 period makes the source periodic at the transform boundary. The old 255-bit
// buffer was transformed directly at the simulation's frequency samples; those frequencies
// generally describe a much shorter periodic time window, aliasing the PRBS into an apparently
// transition-only oscillation after the inverse transform.
constexpr std::size_t kBitCount = 127;
constexpr std::size_t kTraceLength = 2 * kSamplesPerUI + 1;
// Independently randomized point sets the draws are split across. Eight keeps each replicate's
// own estimate meaningful at the default draw count while giving a usable spread.
constexpr std::size_t kReplicateCount = 8;
// Noisy traces kept for display, as the first few draws of every replicate (each replicate's
// prefix is itself evenly spread). The opening and statistics always use every draw.
constexpr std::size_t kDisplayedDrawsPerReplicate = 8;

// The eye height is taken at the best sampling point within the central half of the UI, as a
// receiver would place its sampling clock; ringing makes the exact centre a poor proxy for that.
constexpr std::size_t kFirstSamplingIndex = kSamplesPerUI * 3 / 4; // 0.25 UI
constexpr std::size_t kSamplingIndexCount = kSamplesPerUI / 2 + 1;  // ...to 0.75 UI

/// Worst-case extremes (and level moments) over some set of folded traces -- mergeable, so
/// per-draw, per-replicate and combined openings all come from the same numbers.
struct EyeExtremes {
    std::array<double, kSamplingIndexCount> lowestOne;
    std::array<double, kSamplingIndexCount> highestZero;
    std::array<double, kSamplingIndexCount> oneSum{};
    std::array<double, kSamplingIndexCount> oneSumSquares{};
    std::array<double, kSamplingIndexCount> zeroSum{};
    std::array<double, kSamplingIndexCount> zeroSumSquares{};
    std::size_t oneCount = 0;
    std::size_t zeroCount = 0;
    double earliestLeftCrossing = std::numeric_limits<double>::infinity();
    double latestLeftCrossing = -std::numeric_limits<double>::infinity();
    double earliestRightCrossing = std::numeric_limits<double>::infinity();
    double latestRightCrossing = -std::numeric_limits<double>::infinity();

    EyeExtremes() {
        lowestOne.fill(std::numeric_limits<double>::infinity());
        highestZero.fill(-std::numeric_limits<double>::infinity());
    }

    void merge(const EyeExtremes& other) {
        for (std::size_t i = 0; i < kSamplingIndexCount; ++i) {
            lowestOne[i] = std::min(lowestOne[i], other.lowestOne[i]);
            highestZero[i] = std::max(highestZero[i], other.highestZero[i]);
            oneSum[i] += other.oneSum[i];
            oneSumSquares[i] += other.oneSumSquares[i];
            zeroSum[i] += other.zeroSum[i];
            zeroSumSquares[i] += other.zeroSumSquares[i];
        }
        oneCount += other.oneCount;
        zeroCount += other.zeroCount;
        earliestLeftCrossing = std::min(earliestLeftCrossing, other.earliestLeftCrossing);
        latestLeftCrossing = std::max(latestLeftCrossing, other.latestLeftCrossing);
        earliestRightCrossing = std::min(earliestRightCrossing, other.earliestRightCrossing);
        latestRightCrossing = std::max(latestRightCrossing, other.latestRightCrossing);
    }

    EyeOpening opening() const {
        EyeOpening result;
        double best = -std::numeric_limits<double>::infinity();
        std::size_t bestIndex = kSamplingIndexCount / 2;
        for (std::size_t i = 0; i < kSamplingIndexCount; ++i) {
            if (std::isfinite(lowestOne[i]) && std::isfinite(highestZero[i]) &&
                lowestOne[i] - highestZero[i] > best) {
                best = lowestOne[i] - highestZero[i];
                bestIndex = i;
            }
        }
        result.heightV = std::isfinite(best) ? best : 0.0;
        // No crossing on a side means no trace transitioned there: the eye is bounded by the
        // nominal transitions at 0 and 1 UI.
        const double left = std::isfinite(latestLeftCrossing) ? latestLeftCrossing : 0.0;
        const double right = std::isfinite(earliestRightCrossing) ? earliestRightCrossing : 1.0;
        result.widthUI = result.heightV > 0 ? std::max(0.0, right - left) : 0.0;

        result.samplingUI = static_cast<double>(kFirstSamplingIndex + bestIndex) /
                                static_cast<double>(kSamplesPerUI) - 0.5;
        double oneSigma = 0, zeroSigma = 0;
        if (oneCount > 0) {
            const double n = static_cast<double>(oneCount);
            result.oneLevelV = oneSum[bestIndex] / n;
            oneSigma = std::sqrt(std::max(0.0, oneSumSquares[bestIndex] / n - result.oneLevelV * result.oneLevelV));
        }
        if (zeroCount > 0) {
            const double n = static_cast<double>(zeroCount);
            result.zeroLevelV = zeroSum[bestIndex] / n;
            zeroSigma = std::sqrt(std::max(0.0, zeroSumSquares[bestIndex] / n - result.zeroLevelV * result.zeroLevelV));
        }
        // Below this relative spread the moments are rounding noise, not a measurable distribution.
        const double sigma = oneSigma + zeroSigma;
        result.qFactor = sigma > 1e-9 * std::abs(result.amplitudeV()) ? result.amplitudeV() / sigma : 0.0;

        const double leftSpread = std::isfinite(earliestLeftCrossing) ? latestLeftCrossing - earliestLeftCrossing : 0.0;
        const double rightSpread = std::isfinite(earliestRightCrossing) ? latestRightCrossing - earliestRightCrossing : 0.0;
        result.jitterUI = std::max(leftSpread, rightSpread);
        return result;
    }
};

/// Adds one folded trace to `extremes`. `isOne` is the transmitted bit at the trace's centre; any
/// threshold crossing before the centre bounds the eye's left edge, any after it the right edge.
void accumulate(EyeExtremes& extremes, const std::vector<double>& trace, bool isOne, double threshold,
                const std::vector<double>& timeUI) {
    for (std::size_t i = 0; i < kSamplingIndexCount; ++i) {
        const double value = trace[kFirstSamplingIndex + i];
        if (isOne) {
            extremes.lowestOne[i] = std::min(extremes.lowestOne[i], value);
            extremes.oneSum[i] += value;
            extremes.oneSumSquares[i] += value * value;
        } else {
            extremes.highestZero[i] = std::max(extremes.highestZero[i], value);
            extremes.zeroSum[i] += value;
            extremes.zeroSumSquares[i] += value * value;
        }
    }
    ++(isOne ? extremes.oneCount : extremes.zeroCount);
    for (std::size_t i = 1; i < trace.size(); ++i) {
        const double before = trace[i - 1] - threshold;
        const double after = trace[i] - threshold;
        if ((before < 0) == (after < 0)) {
            continue;
        }
        const double t = timeUI[i - 1] + (timeUI[i] - timeUI[i - 1]) * before / (before - after);
        if (t < 0.5) {
            extremes.earliestLeftCrossing = std::min(extremes.earliestLeftCrossing, t);
            extremes.latestLeftCrossing = std::max(extremes.latestLeftCrossing, t);
        } else {
            extremes.earliestRightCrossing = std::min(extremes.earliestRightCrossing, t);
            extremes.latestRightCrossing = std::max(extremes.latestRightCrossing, t);
        }
    }
}

/// Best rational approximation p/q of x > 0 with q <= maxDenominator, within relativeTolerance;
/// nullopt if none is that close. Continued-fraction convergents are each the best approximation
/// for their denominator, so the first close-enough one has the smallest such q.
std::optional<std::pair<double, double>> rationalApproximation(double x, double maxDenominator,
                                                                double relativeTolerance) {
    double hPrevious = 1, h = std::floor(x);
    double kPrevious = 0, k = 1;
    double remainder = x - std::floor(x);
    while (true) {
        if (std::abs(x - h / k) <= relativeTolerance * x) {
            return std::pair{h, k};
        }
        if (remainder <= 0) {
            return std::nullopt;
        }
        const double inverse = 1.0 / remainder;
        const double term = std::floor(inverse);
        remainder = inverse - term;
        const double hNext = term * h + hPrevious;
        const double kNext = term * k + kPrevious;
        if (kNext > maxDenominator) {
            return std::nullopt;
        }
        hPrevious = h;
        h = hNext;
        kPrevious = k;
        k = kNext;
    }
}

/// The shortest time after which every frequency has completed a whole number of cycles, if the
/// frequencies are (to typed precision) small-integer ratios of each other; nullopt when they
/// aren't, in which case their joint phase never meaningfully repeats.
std::optional<double> commonPeriod(const std::vector<double>& frequencies) {
    // Ratios within 1e-5 count as exact: a frequency typed as 133.333MHz alongside 100MHz means
    // 4:3, and the residual drift over one common period is then under 1% of a cycle.
    constexpr double tolerance = 1e-5;
    constexpr double maxDenominator = 1000;
    double fundamental = frequencies.front();
    for (std::size_t i = 1; i < frequencies.size(); ++i) {
        const auto ratio = rationalApproximation(frequencies[i] / fundamental, maxDenominator, tolerance);
        if (!ratio.has_value()) {
            return std::nullopt;
        }
        fundamental /= ratio->second;
    }
    return 1.0 / fundamental;
}

/// One aggressor reduced to what evaluating its noise at the output needs.
struct PreparedAggressor {
    bool continuous = true;
    double startTime = 0;
    // Continuous: the steady-state output sinusoid.
    double angularFrequency = 0;
    double outputAmplitude = 0;
    double outputPhase = 0;
    std::size_t phaseGroup = 0;
    // Limited: the burst's full response at the output, from startTime, at responseDt spacing.
    double responseDt = 0;
    std::vector<double> response;

    double value(double t, const std::vector<double>& groupPhases) const {
        const double tau = t - startTime;
        if (continuous) {
            return outputAmplitude * std::sin(angularFrequency * tau + outputPhase + groupPhases[phaseGroup]);
        }
        if (tau < 0 || response.empty()) {
            return 0;
        }
        const double position = tau / responseDt;
        const auto index = static_cast<std::size_t>(position);
        if (index + 1 >= response.size()) {
            return 0;
        }
        const double fraction = position - static_cast<double>(index);
        return response[index] + (response[index + 1] - response[index]) * fraction;
    }
};

/// The R_d low-discrepancy sequence's per-dimension step (Roberts' generalized golden ratio):
/// successive points j*alpha mod 1 stay evenly spread in every dimension and every prefix, for
/// any dimension count -- the property even spacing has in one dimension.
std::vector<double> lowDiscrepancySteps(std::size_t dimensions) {
    double phi = 2.0;
    for (int iteration = 0; iteration < 64; ++iteration) {
        phi = std::pow(1.0 + phi, 1.0 / static_cast<double>(dimensions + 1));
    }
    std::vector<double> steps(dimensions);
    for (std::size_t d = 0; d < dimensions; ++d) {
        const double step = std::pow(1.0 / phi, static_cast<double>(d + 1));
        steps[d] = step - std::floor(step);
    }
    return steps;
}

} // namespace

std::optional<EyeDiagramData> computeEyeDiagram(
    const std::vector<double>& frequencies,
    const std::vector<std::complex<double>>& transferFunction,
    double bitRate,
    const std::vector<EyeAggressor>& aggressors,
    const EyeNoiseOptions& options) {
    if (frequencies.empty() || frequencies.size() != transferFunction.size() || !(bitRate > 0) ||
        !std::isfinite(bitRate)) {
        return std::nullopt;
    }

    const double dt = 1.0 / (bitRate * static_cast<double>(kSamplesPerUI));

    TimeWaveform source;
    source.dt = dt;
    source.samples.resize(kBitCount * kSamplesPerUI);
    std::vector<double> sourceBits(kBitCount);
    std::uint32_t lfsr = 0x7fU;
    for (std::size_t bitIndex = 0; bitIndex < kBitCount; ++bitIndex) {
        const double level = (lfsr & 1U) != 0 ? 1.0 : -1.0;
        sourceBits[bitIndex] = level;
        std::fill_n(source.samples.begin() + static_cast<std::ptrdiff_t>(bitIndex * kSamplesPerUI),
                    kSamplesPerUI, level);
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
    const auto sampleCount = static_cast<std::ptrdiff_t>(received.samples.size());
    const auto receivedAt = [&](std::ptrdiff_t unwrapped) {
        return received.samples[static_cast<std::size_t>((unwrapped % sampleCount + sampleCount) % sampleCount)];
    };

    // Recover the phase at which received transitions occur. Scoring the average first
    // difference at each possible sample-within-UI phase handles arbitrary propagation delay and
    // leaves the eye centered on a transition rather than on the source clock's un-delayed phase.
    std::size_t transitionPhase = 0;
    double bestScore = -1;
    for (std::size_t phase = 0; phase < kSamplesPerUI; ++phase) {
        double score = 0;
        for (std::size_t bit = 0; bit < kBitCount; ++bit) {
            const auto sample = static_cast<std::ptrdiff_t>(bit * kSamplesPerUI + phase);
            score += std::abs(receivedAt(sample) - receivedAt(sample - 1));
        }
        if (score > bestScore) {
            bestScore = score;
            transitionPhase = phase;
        }
    }
    // Trace `bit` spans its UI from half a UI before the transition at its start.
    const auto traceStart = [&](std::size_t bit) {
        return static_cast<std::ptrdiff_t>(bit * kSamplesPerUI + transitionPhase) -
               static_cast<std::ptrdiff_t>(kSamplesPerUI / 2);
    };

    EyeDiagramData result;
    result.bitRate = bitRate;
    result.timeUI.resize(kTraceLength);
    for (std::size_t i = 0; i < result.timeUI.size(); ++i) {
        result.timeUI[i] = static_cast<double>(i) / static_cast<double>(kSamplesPerUI) - 0.5;
    }

    // Which transmitted bit each trace's centre carries: the whole-bit channel delay that best
    // correlates the received centre samples with the source bits. Unlike reading the received
    // sample's own sign, this still labels bits correctly when the eye is closed.
    std::vector<double> centres(kBitCount);
    for (std::size_t bit = 0; bit < kBitCount; ++bit) {
        centres[bit] = receivedAt(traceStart(bit) + static_cast<std::ptrdiff_t>(kSamplesPerUI));
    }
    std::size_t bitDelay = 0;
    double bestCorrelation = -std::numeric_limits<double>::infinity();
    for (std::size_t delay = 0; delay < kBitCount; ++delay) {
        double correlation = 0;
        for (std::size_t bit = 0; bit < kBitCount; ++bit) {
            correlation += centres[bit] * sourceBits[(bit + kBitCount - delay) % kBitCount];
        }
        if (correlation > bestCorrelation) {
            bestCorrelation = correlation;
            bitDelay = delay;
        }
    }
    std::vector<bool> isOne(kBitCount);
    double oneSum = 0, zeroSum = 0;
    std::size_t oneCount = 0, zeroCount = 0;
    for (std::size_t bit = 0; bit < kBitCount; ++bit) {
        isOne[bit] = sourceBits[(bit + kBitCount - bitDelay) % kBitCount] > 0;
        (isOne[bit] ? oneSum : zeroSum) += centres[bit];
        ++(isOne[bit] ? oneCount : zeroCount);
    }
    const double threshold = oneCount > 0 && zeroCount > 0
                                 ? 0.5 * (oneSum / static_cast<double>(oneCount) +
                                          zeroSum / static_cast<double>(zeroCount))
                                 : 0.0;

    EyeExtremes cleanExtremes;
    for (std::size_t bit = 0; bit < kBitCount; ++bit) {
        std::vector<double> trace(kTraceLength);
        bool finite = true;
        for (std::size_t i = 0; i < trace.size(); ++i) {
            trace[i] = receivedAt(traceStart(bit) + static_cast<std::ptrdiff_t>(i));
            finite = finite && std::isfinite(trace[i]);
        }
        if (finite) {
            accumulate(cleanExtremes, trace, isOne[bit], threshold, result.timeUI);
            result.traces.push_back(std::move(trace));
        }
    }
    if (result.traces.empty()) {
        return std::nullopt;
    }
    result.opening = cleanExtremes.opening();

    // ---- Adversarial noise ----
    // Each draw transmits the pattern at one time t0 and adds what every aggressor put on the wire
    // then. Continuous tones are steady-state sinusoids (their own transfer function at their
    // frequency); Limited bursts are their full simulated response, played from their start time.
    std::vector<PreparedAggressor> prepared;
    std::vector<double> groupFrequencies; // one per distinct Continuous frequency
    double limitedStart = std::numeric_limits<double>::infinity();
    double limitedEnd = -std::numeric_limits<double>::infinity();
    const double frequencyStep = frequencies.size() > 1 ? frequencies[1] - frequencies[0] : 0;
    for (const EyeAggressor& aggressor : aggressors) {
        if (aggressor.transferFunction.size() != frequencies.size() || !(aggressor.frequencyHz > 0) ||
            aggressor.amplitude == 0) {
            continue;
        }
        PreparedAggressor entry;
        entry.continuous = aggressor.continuous;
        entry.startTime = aggressor.startTime;
        const double phaseRadians = aggressor.phaseDegrees * kTwoPi / 360.0;
        if (aggressor.continuous) {
            const std::complex<double> transfer =
                interpolateTransfer(makePolarTransfer(frequencies, aggressor.transferFunction), aggressor.frequencyHz);
            entry.angularFrequency = kTwoPi * aggressor.frequencyHz;
            entry.outputAmplitude = aggressor.amplitude * std::abs(transfer);
            entry.outputPhase = phaseRadians + std::arg(transfer);
            // Tones at the same frequency are one oscillator (a differential pair's two legs, say):
            // they share a phase draw, so their configured relative phase is kept.
            const auto group = std::find_if(groupFrequencies.begin(), groupFrequencies.end(), [&](double f) {
                return std::abs(f - aggressor.frequencyHz) <= 1e-9 * aggressor.frequencyHz;
            });
            entry.phaseGroup = static_cast<std::size_t>(group - groupFrequencies.begin());
            if (group == groupFrequencies.end()) {
                groupFrequencies.push_back(aggressor.frequencyHz);
            }
        } else {
            if (!(aggressor.duration > 0)) {
                continue;
            }
            // Band-limited to the simulated sweep, so 16x oversampling of its top frequency makes
            // linear interpolation between response samples accurate to well under 1%.
            entry.responseDt = std::min(dt, 1.0 / (16.0 * frequencies.back()));
            double length = aggressor.duration + std::max(0.0, aggressor.ringDown);
            // The inverse transform is periodic in 1/df; past that its response would wrap round.
            if (frequencyStep > 0) {
                length = std::min(length, 1.0 / frequencyStep);
            }
            const auto count = static_cast<std::size_t>(std::ceil(length / entry.responseDt)) + 1;
            const TimeWaveform burst = synthesizeToneBurst(aggressor.frequencyHz, aggressor.amplitude,
                                                            aggressor.phaseDegrees, 0.0, aggressor.duration,
                                                            entry.responseDt, count);
            std::vector<std::complex<double>> burstSpectrum = forwardTransform(burst, frequencies);
            for (std::size_t f = 0; f < burstSpectrum.size(); ++f) {
                burstSpectrum[f] *= aggressor.transferFunction[f];
            }
            entry.response = inverseTransform(frequencies, burstSpectrum, entry.responseDt, count).samples;
            if (!std::all_of(entry.response.begin(), entry.response.end(), [](double v) { return std::isfinite(v); })) {
                continue;
            }
            limitedStart = std::min(limitedStart, aggressor.startTime);
            limitedEnd = std::max(limitedEnd, aggressor.startTime + length);
        }
        if (entry.continuous && !std::isfinite(entry.outputAmplitude + entry.outputPhase)) {
            continue;
        }
        prepared.push_back(std::move(entry));
    }
    if (prepared.empty()) {
        return result;
    }

    // What a draw samples. With Limited bursts, the transmission time ranges over every start that
    // overlaps any burst's lifetime. Otherwise, shared-clock tones repeat with their common period,
    // so the transmission time ranges over one period. Free-running tones (or shared-clock ones
    // with no practical common period, whose joint phase then fills every combination evenly)
    // instead each get a uniformly distributed phase per distinct frequency.
    const double patternLength = static_cast<double>(kBitCount) / bitRate;
    bool samplesTime = false;
    bool samplesPhases = false;
    double timeOrigin = 0;
    double timeSpan = 0;
    if (std::isfinite(limitedStart)) {
        samplesTime = true;
        samplesPhases = !options.sharedClock && !groupFrequencies.empty();
        timeOrigin = limitedStart - patternLength;
        timeSpan = limitedEnd - timeOrigin;
    } else if (const auto period = options.sharedClock ? commonPeriod(groupFrequencies) : std::nullopt;
               period.has_value()) {
        samplesTime = true;
        timeSpan = *period;
    } else {
        samplesPhases = true;
    }
    const std::size_t phaseDimensions = samplesPhases ? groupFrequencies.size() : 0;
    const std::size_t dimensions = (samplesTime ? 1 : 0) + phaseDimensions;
    const std::vector<double> steps = lowDiscrepancySteps(dimensions);

    // Randomly shifted copies of one low-discrepancy point set (Cranley-Patterson rotation): each
    // replicate covers the space evenly by itself, and independently of the others.
    const std::size_t drawsPerReplicate =
        std::max<std::size_t>(1, (options.drawCount + kReplicateCount - 1) / kReplicateCount);
    std::mt19937_64 random(options.seed);
    std::uniform_real_distribution<double> uniform(0.0, 1.0);
    std::vector<std::vector<double>> shifts(kReplicateCount, std::vector<double>(dimensions));
    for (auto& shift : shifts) {
        for (double& value : shift) {
            value = uniform(random);
        }
    }

    // Noise is evaluated at true (unwrapped) times, so the last traces' overhang past the pattern
    // sees the noise that followed rather than the noise at its start.
    const std::ptrdiff_t noiseFirst = traceStart(0);
    const auto noiseCount = static_cast<std::size_t>(traceStart(kBitCount - 1) - noiseFirst) + kTraceLength;
    std::vector<double> noise(noiseCount);
    std::vector<double> groupPhases(groupFrequencies.size(), 0.0);
    std::vector<double> point(dimensions);
    std::vector<std::vector<EyeExtremes>> drawExtremes(kReplicateCount,
                                                       std::vector<EyeExtremes>(drawsPerReplicate));
    for (std::size_t replicate = 0; replicate < kReplicateCount; ++replicate) {
        for (std::size_t draw = 0; draw < drawsPerReplicate; ++draw) {
            for (std::size_t d = 0; d < dimensions; ++d) {
                const double value = shifts[replicate][d] + static_cast<double>(draw + 1) * steps[d];
                point[d] = value - std::floor(value);
            }
            const double t0 = samplesTime ? timeOrigin + point[0] * timeSpan : 0.0;
            for (std::size_t g = 0; g < phaseDimensions; ++g) {
                groupPhases[g] = kTwoPi * point[(samplesTime ? 1 : 0) + g];
            }
            for (std::size_t n = 0; n < noiseCount; ++n) {
                const double t = t0 + static_cast<double>(noiseFirst + static_cast<std::ptrdiff_t>(n)) * dt;
                double sum = 0;
                for (const PreparedAggressor& aggressor : prepared) {
                    sum += aggressor.value(t, groupPhases);
                }
                noise[n] = sum;
            }

            const bool displayed = draw < kDisplayedDrawsPerReplicate;
            EyeExtremes& extremes = drawExtremes[replicate][draw];
            for (std::size_t bit = 0; bit < kBitCount; ++bit) {
                std::vector<double> trace(kTraceLength);
                bool finite = true;
                for (std::size_t i = 0; i < trace.size(); ++i) {
                    const std::ptrdiff_t unwrapped = traceStart(bit) + static_cast<std::ptrdiff_t>(i);
                    trace[i] = receivedAt(unwrapped) + noise[static_cast<std::size_t>(unwrapped - noiseFirst)];
                    finite = finite && std::isfinite(trace[i]);
                }
                if (!finite) {
                    continue;
                }
                accumulate(extremes, trace, isOne[bit], threshold, result.timeUI);
                if (displayed) {
                    result.noisyTraces.push_back(std::move(trace));
                }
            }
        }
    }

    // Per-replicate openings bound how far a different set of draws could move the answer; the
    // convergence checkpoints show the combined opening (and that spread) as draws accumulate.
    EyeNoiseStatistics statistics;
    statistics.drawCount = kReplicateCount * drawsPerReplicate;
    statistics.replicateCount = kReplicateCount;
    std::vector<EyeExtremes> prefixes(kReplicateCount);
    std::size_t nextCheckpoint = 1;
    for (std::size_t draw = 0; draw < drawsPerReplicate; ++draw) {
        for (std::size_t replicate = 0; replicate < kReplicateCount; ++replicate) {
            prefixes[replicate].merge(drawExtremes[replicate][draw]);
        }
        const std::size_t drawn = draw + 1;
        if (drawn != nextCheckpoint && drawn != drawsPerReplicate) {
            continue;
        }
        nextCheckpoint = std::max(nextCheckpoint + 1, static_cast<std::size_t>(std::ceil(static_cast<double>(nextCheckpoint) * 1.25)));
        EyeExtremes combined;
        double lowestHeight = std::numeric_limits<double>::infinity();
        double highestHeight = -std::numeric_limits<double>::infinity();
        for (const EyeExtremes& prefix : prefixes) {
            combined.merge(prefix);
            lowestHeight = std::min(lowestHeight, prefix.opening().heightV);
            highestHeight = std::max(highestHeight, prefix.opening().heightV);
        }
        statistics.convergenceDraws.push_back(static_cast<double>(drawn * kReplicateCount));
        statistics.convergenceHeightV.push_back(combined.opening().heightV);
        statistics.convergenceHeightLowestV.push_back(lowestHeight);
        statistics.convergenceHeightHighestV.push_back(highestHeight);
        if (drawn == drawsPerReplicate) {
            result.noisyOpening = combined.opening();
        }
    }
    statistics.lowest = prefixes.front().opening();
    statistics.highest = statistics.lowest;
    for (const EyeExtremes& replicate : prefixes) {
        const EyeOpening opening = replicate.opening();
        statistics.lowest.heightV = std::min(statistics.lowest.heightV, opening.heightV);
        statistics.lowest.widthUI = std::min(statistics.lowest.widthUI, opening.widthUI);
        statistics.highest.heightV = std::max(statistics.highest.heightV, opening.heightV);
        statistics.highest.widthUI = std::max(statistics.highest.widthUI, opening.widthUI);
    }
    result.noise = std::move(statistics);
    return result;
}

} // namespace kiems
