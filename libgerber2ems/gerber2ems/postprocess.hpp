// Post-processing simulation data into S-parameters/impedance/delay, and plotting them. Ported
// from gerber2ems/postprocess.py.
//
// NOTE on plotting fidelity: the Python source styles matplotlib plots with a custom
// "antmicro.mplstyle" stylesheet and draws Smith charts via scikit-rf (skrf.Network.plot_s_smith).
// matplot++ (a gnuplot-backed plotting library, the closest std-library-friendly C++ equivalent)
// cannot reproduce that exact styling or skrf's Smith chart grid renderer. This port produces
// functionally equivalent plots (same data, axes, legends) with matplot++'s own default styling,
// and a hand-drawn simplified Smith chart (unit circle + axes + VSWR circle + the S11(f) trace)
// rather than skrf's full constant-R/X grid. The underlying numeric results (S-parameters,
// impedances, delays, and the CSV files written) are ported with full fidelity.
#pragma once

#include <complex>
#include <cstdint>
#include <expected>
#include <filesystem>
#include <optional>
#include <string>
#include <vector>

#include "config.hpp"

namespace gerber2ems {

/// Post-processes and displays simulation data.
class Postprocessor {
public:
    /// Port count/reference impedances/traces/differential-pairs all come from `simConfig`, which
    /// must outlive this Postprocessor (kept by reference, not copied).
    Postprocessor(std::vector<double> frequencies, const SimulationConfig& simConfig);

    /// Adds port data (incident/reflected phasors vs. frequency) from a simulation run.
    void addPortData(std::int32_t port, std::int32_t excitedPort, const std::vector<std::complex<double>>& incident,
                      const std::vector<std::complex<double>>& reflected);

    /// Calculates S-parameters. Should be called after all port data has been added.
    void calculateSparams();
    /// Calculates impedance & group delay. Should be called after calculateSparams().
    void processData();

    std::optional<std::vector<std::complex<double>>> getImpedance(std::int32_t port) const;
    std::optional<std::vector<std::complex<double>>> getSParam(std::int32_t outputPort, std::int32_t inputPort) const;

    /// Injects an already-computed S-parameter directly, bypassing addPortData()+calculateSparams()
    /// -- lets a caller that already has S-parameter data in memory (e.g. SimulationResult, see
    /// simulation_result.hpp) build a fresh Postprocessor from it without round-tripping through
    /// Sx<port>.csv on disk the way loadSparams() does.
    void setSParam(std::int32_t outputPort, std::int32_t inputPort, std::vector<std::complex<double>> value);

    void renderSParams(bool plotPhase, bool transparent, const std::filesystem::path& outputDir) const;
    void renderDiffPairSParams(bool transparent, const std::filesystem::path& outputDir) const;
    void renderDiffImpedance(bool transparent, const std::filesystem::path& outputDir) const;
    void renderImpedance(bool transparent, const std::filesystem::path& outputDir) const;
    void renderSmith(bool transparent, const std::filesystem::path& outputDir) const;
    void renderTraceDelays(bool transparent, const std::filesystem::path& outputDir) const;

    void saveToFile(const std::filesystem::path& outputDir) const;
    void sparamToFile(const std::filesystem::path& simulationDir) const;
    std::expected<void, std::string> loadSparams(const std::filesystem::path& inputDir);

private:
    void savePortToFile(std::int32_t portNumber, const std::filesystem::path& path) const;
    void sparamPortToFile(std::int32_t portNumber, const std::filesystem::path& path) const;

    static bool isValid(const std::vector<std::complex<double>>& array);
    static bool isValid(std::complex<double> value);

    const SimulationConfig& _simConfig;
    std::vector<double> _frequencies;
    std::int32_t _count;

    // [measured_port][excited_port][frequency]
    std::vector<std::vector<std::vector<std::complex<double>>>> _incident;
    std::vector<std::vector<std::vector<std::complex<double>>>> _reflected;
    std::vector<double> _referenceZs;

    // [output_port][input_port][frequency]
    std::vector<std::vector<std::vector<std::complex<double>>>> _sParams;
    // [port][frequency]
    std::vector<std::vector<std::complex<double>>> _impedances;
    // [output_port][input_port][frequency]
    std::vector<std::vector<std::vector<double>>> _delays;
};

} // namespace gerber2ems
