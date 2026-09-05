#pragma once

#include <complex>
#include <optional>
#include <vector>

namespace gerber2ems {

/// Display-ready eye diagram synthesized by sending a deterministic PRBS7 NRZ signal through one
/// complex channel transfer function. `timeUI` spans -0.5...1.5 unit intervals; every entry in
/// `traces` is one two-UI slice of the received waveform on that shared axis.
struct EyeDiagramData {
    double bitRate = 0;
    std::vector<double> timeUI;
    std::vector<std::vector<double>> traces;
};

/// Computes a received eye from frequency-domain channel data. Frequencies and transferFunction
/// must have equal, non-empty lengths and bitRate must be positive; invalid input returns nullopt.
/// The recovered transition phase is selected from the received waveform before it is folded, so
/// propagation delay does not move an otherwise-open eye out of the chart window.
std::optional<EyeDiagramData> computeEyeDiagram(
    const std::vector<double>& frequencies,
    const std::vector<std::complex<double>>& transferFunction,
    double bitRate);

} // namespace gerber2ems
