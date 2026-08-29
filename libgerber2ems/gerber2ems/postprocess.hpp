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

/// Unwraps a complex series' phase angle (matching `std::arg`'s convention) into a continuous
/// series in degrees -- no +-180 degree jumps where the true phase just happens to cross the
/// branch cut. Shared by renderSParams's phase subplot and any caller (e.g. a GUI) that wants the
/// same continuous phase curve without reimplementing the unwrapping.
std::vector<double> unwrapPhaseDegrees(const std::vector<std::complex<double>>& values);

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

    /// Frequency points every other per-port/per-parameter series here is sampled at, in Hz.
    const std::vector<double>& frequencies() const { return _frequencies; }

    std::optional<std::vector<std::complex<double>>> getImpedance(std::int32_t port) const;
    std::optional<std::vector<std::complex<double>>> getSParam(std::int32_t outputPort, std::int32_t inputPort) const;
    /// Group delay (seconds) looking from `inputPort` to `outputPort` -- nullopt if that S-parameter
    /// wasn't (successfully) computed. Also the right accessor for a trace's or differential pair's
    /// delay: a SingleEndedConfig/DifferentialPairConfig's delay is just this, evaluated at its own
    /// resolved start/stop port indices (see e.g. renderTraceDelays).
    std::optional<std::vector<double>> getDelay(std::int32_t outputPort, std::int32_t inputPort) const;

    /// SDD11 (differential return loss, dB) and SDD21 (differential insertion loss, dB) for one
    /// differential pair, mixed-mode-converted from its 4 constituent single-ended S-parameters.
    /// Each has its own, independent validity condition (matching renderDiffPairSParams): nullopt
    /// for either if the S-parameters it depends on weren't computed.
    struct DiffPairSdd {
        std::optional<std::vector<double>> sdd11Db;
        std::optional<std::vector<double>> sdd21Db;
    };
    /// nullopt if `diffPairIndex` is out of range, the pair isn't `correct()`, or neither SDD11 nor
    /// SDD21 could be computed (matching renderDiffPairSParams's own skip conditions).
    std::optional<DiffPairSdd> getDiffPairSdd(std::int32_t diffPairIndex) const;

    /// Mixed-mode differential impedance for one differential pair -- magnitude in Ohms, angle in
    /// degrees, both derived from the same 4-S-parameter gamma computation renderDiffImpedance uses.
    struct DiffPairImpedance {
        std::vector<double> magnitudeOhm;
        std::vector<double> angleDeg;
    };
    /// nullopt under the same conditions renderDiffImpedance itself skips a pair: out-of-range/
    /// incorrect pair, missing S-parameters, or the 4 ports' reference impedances aren't all equal.
    std::optional<DiffPairImpedance> getDiffPairImpedance(std::int32_t diffPairIndex) const;

    /// Injects an already-computed S-parameter directly, bypassing addPortData()+calculateSparams()
    /// -- lets a caller that already has S-parameter data in memory (e.g. SimulationResult, see
    /// simulation_result.hpp) build a fresh Postprocessor from it without round-tripping through
    /// Sx<port>.csv on disk the way loadSparams() does.
    void setSParam(std::int32_t outputPort, std::int32_t inputPort, std::vector<std::complex<double>> value);

    /// Adds a non-absorbing port's raw (undecomposed) voltage/current -- the passive-probe
    /// equivalent of addPortData(), but never fed into calculateSparams() (a probe has no
    /// characteristic impedance, so it's never a valid S-parameter row or column -- see
    /// getProbeVoltage()/getProbeCurrent()'s own doc comment).
    void addProbeData(std::int32_t probe, std::int32_t excitedPort, const std::vector<std::complex<double>>& voltage,
                       const std::vector<std::complex<double>>& current);
    /// nullopt if `probe` never had addProbeData() called for it at `excitedPort` (e.g. it's an
    /// absorbing port, which never gets probe data at all -- only ever addPortData()).
    std::optional<std::vector<std::complex<double>>> getProbeVoltage(std::int32_t probe, std::int32_t excitedPort) const;
    std::optional<std::vector<std::complex<double>>> getProbeCurrent(std::int32_t probe, std::int32_t excitedPort) const;

    void renderSParams(bool plotPhase, bool transparent, const std::filesystem::path& outputDir) const;
    void renderDiffPairSParams(bool transparent, const std::filesystem::path& outputDir) const;
    void renderDiffImpedance(bool transparent, const std::filesystem::path& outputDir) const;
    void renderImpedance(bool transparent, const std::filesystem::path& outputDir) const;
    void renderSmith(bool transparent, const std::filesystem::path& outputDir) const;
    void renderTraceDelays(bool transparent, const std::filesystem::path& outputDir) const;
    /// |V|/|I| vs. frequency, one curve per excited port, for every probe with data -- the
    /// passive-probe equivalent of renderImpedance().
    void renderProbes(bool transparent, const std::filesystem::path& outputDir) const;

    void saveToFile(const std::filesystem::path& outputDir) const;
    void sparamToFile(const std::filesystem::path& simulationDir) const;
    std::expected<void, std::string> loadSparams(const std::filesystem::path& inputDir);
    /// Persistence for addProbeData()'s data, mirroring sparamToFile()/loadSparams() but with a
    /// simpler, always-re/im CSV shape (no legacy format to sniff -- this is a new file kind).
    void probeToFile(const std::filesystem::path& simulationDir) const;
    std::expected<void, std::string> loadProbes(const std::filesystem::path& inputDir);

private:
    void savePortToFile(std::int32_t portNumber, const std::filesystem::path& path) const;
    void sparamPortToFile(std::int32_t portNumber, const std::filesystem::path& path) const;
    void probePortToFile(std::int32_t probeNumber, const std::filesystem::path& path) const;

    static bool isValid(const std::vector<std::complex<double>>& array);
    static bool isValid(std::complex<double> value);

    const SimulationConfig& _simConfig;
    std::vector<double> _frequencies;
    std::int32_t _count;

    // [measured_port][excited_port][frequency]
    std::vector<std::vector<std::vector<std::complex<double>>>> _incident;
    std::vector<std::vector<std::vector<std::complex<double>>>> _reflected;
    std::vector<double> _referenceZs;

    // [probe][excited_port][frequency] -- same _count x _count x freq shape as _incident/
    // _reflected for consistency, only ever populated at non-absorbing-port row indices.
    std::vector<std::vector<std::vector<std::complex<double>>>> _probeVoltage;
    std::vector<std::vector<std::vector<std::complex<double>>>> _probeCurrent;

    // [output_port][input_port][frequency]
    std::vector<std::vector<std::vector<std::complex<double>>>> _sParams;
    // [port][frequency]
    std::vector<std::vector<std::complex<double>>> _impedances;
    // [output_port][input_port][frequency]
    std::vector<std::vector<std::vector<double>>> _delays;
};

} // namespace gerber2ems
