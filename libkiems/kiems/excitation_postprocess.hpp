// Synthesizes each of a simulation's excitations' time-domain stimulus, propagates it through the
// already-extracted S-parameter matrix (Postprocessor::getSParam), and superposes the contributions
// at every port -- entirely a postprocessing step, never touches openEMS. See fft_postprocess.hpp
// for the underlying DSP and the "board slicing + net-driven ports and excitations" plan for why
// this is a postprocessing concept rather than a literal FDTD engine excitation.
#pragma once

#include <cstdint>
#include <filesystem>
#include <vector>

#include "config.hpp"
#include "fft_postprocess.hpp"
#include "postprocess.hpp"

namespace kiems {

class ExcitationPostprocessor {
public:
    ExcitationPostprocessor(const SimulationConfig& simConfig, const Postprocessor& sParams,
                             std::vector<double> frequencies, const Frequency& frequency);

    /// Synthesizes+propagates+superposes every excitation's contribution to every port in
    /// simConfig.ports(). No-op if the simulation has no excitations configured.
    void run();

    const TimeWaveform& responseFor(std::int32_t portIndex) const;

    /// Writes `<portName>_response.csv` (header "time_s,voltage_v") per port with a non-empty
    /// response into outputDir.
    void saveToFile(const std::filesystem::path& outputDir) const;
    /// Writes `<portName>_response.png` (a time-domain line plot) per port with a non-empty
    /// response into outputDir.
    void renderPlots(const std::filesystem::path& outputDir, bool transparent) const;

private:
    double _pickDt() const;
    std::size_t _pickSampleCount(double dt) const;

    const SimulationConfig& _simConfig;
    const Postprocessor& _sParams;
    std::vector<double> _frequencies;
    const Frequency& _frequency;
    double _dt = 0;
    std::vector<TimeWaveform> _responses; // indexed like _simConfig.ports(); empty until run()
};

} // namespace kiems
