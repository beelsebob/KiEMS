// A run's excitation: the precomputed Gaussian-pulse sample arrays and the per-edge injection list
// (which cells get excited, along which axis, with what amplitude and per-cell delay).
// CopperOperator::computeExcitation() builds it.
#pragma once

#include <cstdint>
#include <vector>

namespace copper {

/// One excited Yee edge: position + axis (0=x/1=y/2=z) identify which `vv`/`vi` (or `ii`/`iv`) cell
/// this applies to in a CopperYeeGrid; `amplitude` and `delaySteps` come straight from
/// `Operator_Ext_Excitation::Volt_amp`/`Volt_delay` (or the Curr_* equivalents) -- see
/// Engine_Ext_Excitation::Apply2VoltagesImpl/Apply2CurrentImpl (engine_ext_excitation.cpp) for the
/// exact per-timestep formula this is meant to reproduce:
/// `field(axis, pos) += amplitude * signal[clamp(timestep - delaySteps, 0, length-1 or wrapped by
/// signalPeriodSeconds)]`.
struct CopperExcitationCell {
    std::uint32_t x = 0;
    std::uint32_t y = 0;
    std::uint32_t z = 0;
    std::uint32_t axis = 0;
    float amplitude = 0.0F;
    std::uint32_t delaySteps = 0;
};

struct CopperExcitation {
    std::vector<float> voltageSignal; // Excitation::GetVoltageSignal(), length entries
    std::vector<float> currentSignal; // Excitation::GetCurrentSignal(), length entries -- sampled
                                       // half a timestep after voltageSignal, already baked in by
                                       // openEMS itself (see CalcGaussianPulsExcitation)
    double signalPeriodSeconds = 0.0; // Excitation::GetSignalPeriod() -- 0 for a one-shot pulse
                                       // (kiems's only excitation type today), nonzero only
                                       // for a periodic/CW excitation this pipeline doesn't use.

    std::vector<CopperExcitationCell> voltageCells;
    std::vector<CopperExcitationCell> currentCells;
};

} // namespace copper
