#pragma once

#include <complex>
#include <cstdint>
#include <optional>
#include <vector>

namespace kiems {

/// One adversarial (non-main) excitation as seen from an eye's output. `transferFunction` is the
/// channel from the adversarial port to the eye's received quantity, sampled at the same
/// frequencies as the eye's own channel. Times are on the excitations' shared timeline (seconds).
struct EyeAggressor {
    std::vector<std::complex<double>> transferFunction;
    double frequencyHz = 0;
    double amplitude = 0;
    double phaseDegrees = 0;
    double startTime = 0;
    /// Continuous tones play forever (`duration`/`ringDown` unused); Limited ones play a
    /// Hann-windowed burst for `duration`, then ring down for `ringDown` before being ignored.
    bool continuous = true;
    double duration = 0;
    double ringDown = 0;
};

/// How adversarial noise is sampled into an eye. Each draw picks one transmission time for the
/// PRBS pattern and adds whatever every aggressor put on the wire at that time.
struct EyeNoiseOptions {
    /// Requested draws; rounded up to a whole number of draws per replicate.
    std::size_t drawCount = 64;
    /// True when the adversarial sources share a clock, so their relative phases are fixed by
    /// their frequencies alone (the transmission time is then sampled over their common period).
    /// False treats each distinct frequency as a free-running oscillator with its own uniformly
    /// distributed phase -- equally aligned tones (a differential pair's legs, say) stay coherent.
    bool sharedClock = false;
    std::uint64_t seed = 0x6b69656d73ULL;
};

/// Worst-case eye opening. `heightV` is the vertical opening (lowest "1" minus highest "0", by the
/// transmitted bit; negative when closed) at the best sampling point in the central half of the
/// UI. `widthUI` is the horizontal opening at the decision threshold, in unit intervals.
struct EyeOpening {
    double heightV = 0;
    double widthUI = 0;
};

/// How settled a noisy eye's opening is. The draws are split into `replicateCount` independently
/// randomized low-discrepancy point sets; each replicate's own worst-case opening is an
/// independent estimate, so their spread (`lowest`/`highest`) shows how much a different set of
/// draws could move the answer. `convergence*` trace the combined opening as draws accumulate.
struct EyeNoiseStatistics {
    std::size_t drawCount = 0;
    std::size_t replicateCount = 0;
    EyeOpening lowest;
    EyeOpening highest;
    std::vector<double> convergenceDraws;
    std::vector<double> convergenceHeightV;
    std::vector<double> convergenceHeightLowestV;
    std::vector<double> convergenceHeightHighestV;
};

/// Display-ready eye diagram synthesized by sending a deterministic PRBS7 NRZ signal through one
/// complex channel transfer function. `timeUI` spans -0.5...1.5 unit intervals; every entry in
/// `traces` is one two-UI slice of the received waveform on that shared axis. When aggressors
/// were supplied, `noisyTraces` is the same eye with their noise added (a representative subset
/// of the draws -- `noise`'s opening covers every draw).
struct EyeDiagramData {
    double bitRate = 0;
    std::vector<double> timeUI;
    std::vector<std::vector<double>> traces;
    EyeOpening opening;
    std::vector<std::vector<double>> noisyTraces;
    std::optional<EyeOpening> noisyOpening;
    std::optional<EyeNoiseStatistics> noise;
};

/// Computes a received eye from frequency-domain channel data. Frequencies and transferFunction
/// must have equal, non-empty lengths and bitRate must be positive; invalid input returns nullopt.
/// The recovered transition phase is selected from the received waveform before it is folded, so
/// propagation delay does not move an otherwise-open eye out of the chart window. Aggressors whose
/// transfer function doesn't match `frequencies` are ignored.
std::optional<EyeDiagramData> computeEyeDiagram(
    const std::vector<double>& frequencies,
    const std::vector<std::complex<double>>& transferFunction,
    double bitRate,
    const std::vector<EyeAggressor>& aggressors = {},
    const EyeNoiseOptions& options = {});

} // namespace kiems
