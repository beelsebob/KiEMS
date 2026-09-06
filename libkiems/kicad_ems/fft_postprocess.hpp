// Frequency-domain synthesis/propagation for the excitation postprocessing feature (see
// excitation_postprocess.hpp). New feature, not ported from any Python source.
//
// Uses direct Riemann-sum quadrature (the same "evaluate a DFT-like sum at exactly the frequencies
// we need" approach already used and validated in this codebase for occasional, small postprocessing
// DSP -- see ports.cpp's dftTimeToFreq) rather than a packed-format FFT library: correctness and
// simplicity matter far more here than raw speed, for a handful of ports/excitations/frequency
// samples. Concretely: X(f) = dt * sum_n x(t_n) * exp(-i*2*pi*f*t_n) approximates the continuous
// Fourier transform, and its inverse (assuming a real time-domain signal, so only positive
// frequencies are needed -- the standard single-sided-spectrum convention) reconstructs x(t) from a
// spectrum known at a finite set of frequencies. Because the analysis-and-synthesis frequency grid
// is exactly Postprocessor's own (EMSConfig::frequency()'s linspace), no interpolation
// between grids is ever needed -- everything here operates directly on that one grid.
#pragma once

#include <complex>
#include <cstddef>
#include <vector>

#include "config.hpp"

namespace kicad_ems {

/// A uniformly-sampled real time-domain waveform: samples[n] at time n*dt, starting at t=0.
struct TimeWaveform {
    double dt = 0;
    std::vector<double> samples;
};

/// Transforms `time` to the frequency domain at exactly `frequencies` (Hz).
std::vector<std::complex<double>> forwardTransform(const TimeWaveform& time, const std::vector<double>& frequencies);

/// Inverse of forwardTransform: reconstructs `sampleCount` real time-domain samples at spacing `dt`
/// from a one-sided spectrum known only at `frequencies` (assumed uniformly spaced).
TimeWaveform inverseTransform(const std::vector<double>& frequencies, const std::vector<std::complex<double>>& spectrum,
                                double dt, std::size_t sampleCount);

/// Synthesizes the "main" excitation's stimulus: openEMS's own modulated-Gaussian-pulse shape
/// (Excitation::CalcGaussianPulsExcitation, openEMS/FDTD/excitation.cpp: cos(2*pi*f0*(t-9/(2*pi*fc)))
/// * exp(-(2*pi*fc*t/3-3)^2), with f0/fc from `freq` exactly as Simulation::setExcitation() derives
/// them -- the same pulse shape actually used during S-parameter extraction), delayed by `startTime`,
/// phase-shifted by `phaseDegrees` (added directly to the cosine's argument), and rectangularly
/// windowed to fade out by `startTime+duration` (the pulse's own natural envelope already decays
/// close to zero well within its natural ~9/(pi*fc)-second length; `duration` only matters if
/// shorter than that, truncating it early). Samples an n-point, dt-spaced timeline starting at t=0.
/// `amplitude` scales the whole waveform (default 1.0, the FDTD's own real per-port drive level) --
/// lets two main excitations on the same net (e.g. a differential pair's two legs) reconstruct as
/// e.g. +1.0/-1.0 of the same pulse shape when their per-port S-parameter responses are superposed
/// in ExcitationPostprocessor::run(), without needing a second, narrowband non-main excitation.
TimeWaveform synthesizeMainStimulus(const Frequency& freq, double startTime, double duration, double phaseDegrees,
                                      double dt, std::size_t sampleCount, double amplitude = 1.0);

/// Synthesizes a "non-main" excitation's stimulus: a Hann-windowed sinusoidal burst at
/// `frequencyHz` and `phaseDegrees` phase offset, amplitude-scaled (relative to the main
/// excitation's unit amplitude), active over [startTime, startTime+duration] -- the standard
/// simplified worst-case aggressor/noise-tone model for this kind of SI/PI analysis. Same timeline
/// convention as synthesizeMainStimulus.
TimeWaveform synthesizeToneBurst(double frequencyHz, double amplitude, double phaseDegrees, double startTime,
                                   double duration, double dt, std::size_t sampleCount);

/// Sums multiple time waveforms sample-by-sample. All inputs must share dt and sample count.
TimeWaveform superpose(const std::vector<TimeWaveform>& waveforms);

} // namespace kicad_ems
