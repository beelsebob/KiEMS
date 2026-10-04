// Synthesizes each of a simulation's excitations' time-domain stimulus, propagates it through the
// already-extracted S-parameter matrix (Postprocessor::getSParam), and superposes the contributions
// at every port -- entirely a postprocessing step, never touches openEMS. See fft_postprocess.hpp
// for the underlying DSP and the "board slicing + net-driven ports and excitations" plan for why
// this is a postprocessing concept rather than a literal FDTD engine excitation.
#pragma once

#include <cstdint>
#include <filesystem>
#include <map>
#include <vector>

#include "config.hpp"
#include "fft_postprocess.hpp"
#include "postprocess.hpp"

namespace kiems {

/// The longest main excitation's own FDTD run (seconds) among `runDurations` (see
/// ExcitationPostprocessor::loadRunDurations()); 0 if none is known.
double primaryRunDuration(const SimulationConfig& simConfig, const std::map<std::int32_t, double>& runDurations);

/// When an excitation's response stops being recorded, on the excitations' shared timeline. A main
/// or Continuous excitation lasts the primary run. A Limited one lasts its tone plus however long
/// its own port's FDTD run took to ring down after its Gaussian pulse, capped at the primary run.
/// Without run lengths, falls back to 1.2x its configured startTime()+duration().
double excitationRecordEnd(const ExcitationConfig& excitation, const SimulationConfig& simConfig,
                           const std::map<std::int32_t, double>& runDurations, const Frequency& frequency);

class ExcitationPostprocessor {
public:
    /// `runDurations` is each excited port's own FDTD run length in seconds (see
    /// loadRunDurations()) -- what sizes non-main excitations' tones and record windows. A port
    /// missing from it falls back to the excitation's own configured startTime()+duration().
    ExcitationPostprocessor(const SimulationConfig& simConfig, const Postprocessor& sParams,
                             std::vector<double> frequencies, const Frequency& frequency,
                             std::map<std::int32_t, double> runDurations = {});

    /// Reads each excited port's FDTD run length (its last recorded probe sample's time) back from
    /// `simulationDir`/<port index>/, where Simulation::getPortParameters() also reads them. Ports
    /// with no readable probe file are simply absent.
    static std::map<std::int32_t, double> loadRunDurations(const std::filesystem::path& simulationDir,
                                                            const SimulationConfig& simConfig);

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

    const SimulationConfig& _simConfig;
    const Postprocessor& _sParams;
    std::vector<double> _frequencies;
    const Frequency& _frequency;
    std::map<std::int32_t, double> _runDurations;
    double _dt = 0;
    std::vector<TimeWaveform> _responses; // indexed like _simConfig.ports(); empty until run()
};

} // namespace kiems
