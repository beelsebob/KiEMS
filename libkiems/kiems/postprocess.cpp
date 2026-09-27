#include "postprocess.hpp"

#include <algorithm>
#include <array>
#include <cmath>
#include <cstdlib>
#include <fstream>
#include <limits>
#include <map>
#include <regex>
#include <sstream>

#include <matplot/matplot.h>

#include "config.hpp"
#include "logging.hpp"

namespace kiems {

using namespace Cu;

namespace {

constexpr double kNaN = std::numeric_limits<double>::quiet_NaN();
const std::complex<double> kComplexNaN(kNaN, kNaN);

std::string _sparamPath(std::int32_t port) { return "Sx" + std::to_string(port) + ".csv"; }
std::string _probePath(std::int32_t probe) { return "Probe" + std::to_string(probe) + ".csv"; }

std::vector<double> _unwrap(std::vector<double> phase) {
    for (std::size_t i = 1; i < phase.size(); ++i) {
        double d = phase[i] - phase[i - 1];
        while (d > M_PI) {
            phase[i] -= 2 * M_PI;
            d = phase[i] - phase[i - 1];
        }
        while (d < -M_PI) {
            phase[i] += 2 * M_PI;
            d = phase[i] - phase[i - 1];
        }
    }
    return phase;
}

std::vector<double> _angles(const std::vector<std::complex<double>>& v) {
    std::vector<double> result(v.size());
    for (std::size_t i = 0; i < v.size(); ++i) {
        result[i] = std::arg(v[i]);
    }
    return result;
}

std::vector<double> _magnitudesDb(const std::vector<std::complex<double>>& v) {
    std::vector<double> result(v.size());
    for (std::size_t i = 0; i < v.size(); ++i) {
        result[i] = 20 * std::log10(std::abs(v[i]));
    }
    return result;
}

std::vector<double> _scaleFreqGHz(const std::vector<double>& freq) {
    std::vector<double> result(freq.size());
    for (std::size_t i = 0; i < freq.size(); ++i) {
        result[i] = freq[i] / 1e9;
    }
    return result;
}

matplot::figure_handle _newFigure() { return matplot::figure(true); }

void _saveFigure(const matplot::figure_handle& fig, const std::filesystem::path& path, bool transparent) {
    if (transparent) {
        // Best-effort: matplot++'s gnuplot backend doesn't expose an explicit "transparent
        // background" flag the way matplotlib's savefig(transparent=True) does; setting an
        // alpha=0 figure colour approximates it when the PNG terminal supports alpha.
        fig->color({0.0F, 1.0F, 1.0F, 1.0F});
    }
    fig->save(path.string());
}

std::string _sLabel(std::int32_t j, std::int32_t i) {
    if (i > 9 || j > 9) {
        return "S_{" + std::to_string(j + 1) + "," + std::to_string(i + 1) + "}";
    }
    return "S_{" + std::to_string(j + 1) + std::to_string(i + 1) + "}";
}

} // namespace

std::vector<double> unwrapPhaseDegrees(const std::vector<std::complex<double>>& values) {
    std::vector<double> phaseDeg = _unwrap(_angles(values));
    for (double& v : phaseDeg) {
        v = v * 180.0 / M_PI;
    }
    return phaseDeg;
}

Postprocessor::Postprocessor(std::vector<double> frequencies, const SimulationConfig& simConfig)
    : _simConfig(simConfig),
      _frequencies(std::move(frequencies)),
      _count(static_cast<std::int32_t>(simConfig.ports().size())) {
    const std::size_t n = _frequencies.size();
    const auto make3 = [&](std::complex<double> fillValue) {
        return std::vector<std::vector<std::vector<std::complex<double>>>>(
            static_cast<std::size_t>(_count),
            std::vector<std::vector<std::complex<double>>>(static_cast<std::size_t>(_count),
                                                             std::vector<std::complex<double>>(n, fillValue)));
    };
    _incident = make3(kComplexNaN);
    _reflected = make3(kComplexNaN);
    _probeVoltage = make3(kComplexNaN);
    _probeCurrent = make3(kComplexNaN);
    _probeImpedance = make3(kComplexNaN);
    _sParams = make3(kComplexNaN);
    _delays = std::vector<std::vector<std::vector<double>>>(
        static_cast<std::size_t>(_count),
        std::vector<std::vector<double>>(static_cast<std::size_t>(_count), std::vector<double>(n, kNaN)));
    _impedances = std::vector<std::vector<std::complex<double>>>(static_cast<std::size_t>(_count),
                                                                    std::vector<std::complex<double>>(n, kComplexNaN));

    _referenceZs.reserve(_simConfig.ports().size());
    for (const auto& p : _simConfig.ports()) {
        _referenceZs.push_back(p.impedance());
    }
}

bool Postprocessor::isValid(const std::vector<std::complex<double>>& array) {
    // `none_of` is vacuously true for an empty vector, but an empty series means that no result was
    // produced (not a valid, zero-length curve). Treating it as valid lets disabled/missing probes
    // leak into the results preview as fixed-height charts with nothing to draw.
    return !array.empty() &&
           std::none_of(array.begin(), array.end(), [](std::complex<double> v) { return isValid(v) == false; });
}

bool Postprocessor::isValid(std::complex<double> value) { return !std::isnan(value.real()) && !std::isnan(value.imag()); }

void Postprocessor::addPortData(std::int32_t port, std::int32_t excitedPort,
                                 const std::vector<std::complex<double>>& incident,
                                 const std::vector<std::complex<double>>& reflected) {
    auto& existing = _incident[static_cast<std::size_t>(port)][static_cast<std::size_t>(excitedPort)];
    if (isValid(existing)) {
        logWarning("This port data has already been supplied, overwriting");
    }
    existing = incident;
    _reflected[static_cast<std::size_t>(port)][static_cast<std::size_t>(excitedPort)] = reflected;
}

void Postprocessor::addProbeData(std::int32_t probe, std::int32_t excitedPort,
                                  const std::vector<std::complex<double>>& voltage,
                                  const std::vector<std::complex<double>>& current) {
    _probeVoltage[static_cast<std::size_t>(probe)][static_cast<std::size_t>(excitedPort)] = voltage;
    _probeCurrent[static_cast<std::size_t>(probe)][static_cast<std::size_t>(excitedPort)] = current;
}

std::optional<std::vector<std::complex<double>>> Postprocessor::getProbeVoltage(std::int32_t probe,
                                                                                   std::int32_t excitedPort) const {
    if (probe >= _count || excitedPort >= _count) {
        return std::nullopt;
    }
    const auto& v = _probeVoltage[static_cast<std::size_t>(probe)][static_cast<std::size_t>(excitedPort)];
    return isValid(v) ? std::optional(v) : std::nullopt;
}

std::optional<std::vector<std::complex<double>>> Postprocessor::getProbeCurrent(std::int32_t probe,
                                                                                   std::int32_t excitedPort) const {
    if (probe >= _count || excitedPort >= _count) {
        return std::nullopt;
    }
    const auto& i = _probeCurrent[static_cast<std::size_t>(probe)][static_cast<std::size_t>(excitedPort)];
    return isValid(i) ? std::optional(i) : std::nullopt;
}

void Postprocessor::addProbeImpedance(std::int32_t probe, std::int32_t excitedPort,
                                        const std::vector<std::complex<double>>& zRef) {
    _probeImpedance[static_cast<std::size_t>(probe)][static_cast<std::size_t>(excitedPort)] = zRef;
}

std::optional<std::vector<std::complex<double>>> Postprocessor::getProbeImpedance(std::int32_t probe,
                                                                                     std::int32_t excitedPort) const {
    if (probe >= _count || excitedPort >= _count) {
        return std::nullopt;
    }
    const auto& z = _probeImpedance[static_cast<std::size_t>(probe)][static_cast<std::size_t>(excitedPort)];
    return isValid(z) ? std::optional(z) : std::nullopt;
}

void Postprocessor::calculateSparams() {
    logInfo("Processing all data from simulation. Calculating S-parameters and impedance");
    for (std::int32_t i = 0; i < _count; ++i) {
        if (!isValid(_incident[static_cast<std::size_t>(i)][static_cast<std::size_t>(i)])) {
            continue;
        }
        for (std::int32_t j = 0; j < _count; ++j) {
            if (!isValid(_reflected[static_cast<std::size_t>(j)][static_cast<std::size_t>(i)])) {
                continue;
            }
            for (std::size_t f = 0; f < _frequencies.size(); ++f) {
                _sParams[static_cast<std::size_t>(j)][static_cast<std::size_t>(i)][f] =
                    _reflected[static_cast<std::size_t>(j)][static_cast<std::size_t>(i)][f] /
                    _incident[static_cast<std::size_t>(i)][static_cast<std::size_t>(i)][f];
            }
        }
    }
}

void Postprocessor::processData() {
    logInfo("Processing all data from simulation. Calculating Delay & Impedance");

    for (std::size_t i = 0; i < _referenceZs.size(); ++i) {
        const double referenceZ = _referenceZs[i];
        const auto& sParam = _sParams[i][i];
        if (!std::isnan(referenceZ) && isValid(sParam)) {
            for (std::size_t f = 0; f < _frequencies.size(); ++f) {
                _impedances[i][f] = referenceZ * (1.0 + sParam[f]) / (1.0 - sParam[f]);
            }
        }
    }

    for (std::int32_t i = 0; i < _count; ++i) {
        if (!isValid(_sParams[static_cast<std::size_t>(i)][static_cast<std::size_t>(i)])) {
            continue;
        }
        for (std::int32_t j = 0; j < _count; ++j) {
            const auto& sParam = _sParams[static_cast<std::size_t>(j)][static_cast<std::size_t>(i)];
            if (!isValid(sParam)) {
                continue;
            }
            const std::vector<double> phase = _unwrap(_angles(sParam));
            std::vector<double> groupDelay(_frequencies.size());
            for (std::size_t f = 0; f + 1 < _frequencies.size(); ++f) {
                const double dPhase = phase[f + 1] - phase[f];
                const double dFreq = _frequencies[f + 1] - _frequencies[f];
                groupDelay[f] = -(dPhase / dFreq) / 2 / M_PI;
            }
            if (_frequencies.size() >= 2) {
                groupDelay[_frequencies.size() - 1] = groupDelay[_frequencies.size() - 2];
            }
            _delays[static_cast<std::size_t>(j)][static_cast<std::size_t>(i)] = groupDelay;
        }
    }
}

std::optional<std::vector<std::complex<double>>> Postprocessor::getImpedance(std::int32_t port) const {
    if (port >= _count) {
        logError("Port no. " + std::to_string(port) + " doesn't exist");
        return std::nullopt;
    }
    // NOTE deliberate deviation from the Python source, whose equivalent condition is inverted (it
    // errors out precisely when the impedance *was* successfully calculated, and would otherwise
    // silently return the all-NaN placeholder). This method isn't called anywhere in kiems's
    // own CLI flow, so the bug is unreachable there, but the correct condition is used here.
    if (!isValid(_impedances[static_cast<std::size_t>(port)])) {
        logError("Impedance for port " + std::to_string(port) + " wasn't calculated");
        return std::nullopt;
    }
    return _impedances[static_cast<std::size_t>(port)];
}

std::optional<std::vector<std::complex<double>>> Postprocessor::getSParam(std::int32_t outputPort,
                                                                            std::int32_t inputPort) const {
    if (outputPort >= _count || inputPort >= _count) {
        logError("Port no. " + std::to_string(outputPort) + " doesn't exist");
        return std::nullopt;
    }
    const auto& sParam = _sParams[static_cast<std::size_t>(outputPort)][static_cast<std::size_t>(inputPort)];
    if (isValid(sParam)) {
        return sParam;
    }
    logError("S" + std::to_string(outputPort) + std::to_string(inputPort) + " wasn't calculated");
    return std::nullopt;
}

std::optional<std::vector<double>> Postprocessor::getDelay(std::int32_t outputPort, std::int32_t inputPort) const {
    if (outputPort >= _count || inputPort >= _count) {
        logError("Port no. " + std::to_string(outputPort) + " doesn't exist");
        return std::nullopt;
    }
    const auto& delay = _delays[static_cast<std::size_t>(outputPort)][static_cast<std::size_t>(inputPort)];
    if (std::any_of(delay.begin(), delay.end(), [](double v) { return std::isnan(v); })) {
        logError("Delay " + std::to_string(inputPort) + ">" + std::to_string(outputPort) + " wasn't calculated");
        return std::nullopt;
    }
    return delay;
}

void Postprocessor::setSParam(std::int32_t outputPort, std::int32_t inputPort, std::vector<std::complex<double>> value) {
    _sParams[static_cast<std::size_t>(outputPort)][static_cast<std::size_t>(inputPort)] = std::move(value);
}

void Postprocessor::renderSParams(bool plotPhase, bool transparent, const std::filesystem::path& outputDir) const {
    logInfo("Rendering S-parameter plots");
    const std::vector<double> freqGHz = _scaleFreqGHz(_frequencies);

    for (std::int32_t i = 0; i < _count; ++i) {
        if (!isValid(_sParams[static_cast<std::size_t>(i)][static_cast<std::size_t>(i)])) {
            continue;
        }
        auto fig = _newFigure();
        std::vector<std::string> labels;

        matplot::axes_handle ax1 = plotPhase ? matplot::subplot(2, 1, 0) : matplot::gca();
        matplot::hold(ax1, true);
        for (std::int32_t j = 0; j < _count; ++j) {
            const auto& sParam = _sParams[static_cast<std::size_t>(j)][static_cast<std::size_t>(i)];
            if (!isValid(sParam)) {
                continue;
            }
            matplot::plot(ax1, freqGHz, _magnitudesDb(sParam));
            labels.push_back("$" + _sLabel(j, i) + "$");
        }
        matplot::legend(ax1, labels);
        matplot::ylabel(ax1, "Magnitude [dB]");
        matplot::grid(ax1, true);
        const auto currentYlim = ax1->ylim();
        ax1->ylim({std::min(currentYlim[0], -60.0), std::max(currentYlim[1], 5.0)});
        matplot::xlabel(ax1, "Frequency [GHz]");

        if (plotPhase) {
            matplot::axes_handle ax2 = matplot::subplot(2, 1, 1);
            matplot::hold(ax2, true);
            for (std::int32_t j = 0; j < _count; ++j) {
                const auto& sParam = _sParams[static_cast<std::size_t>(j)][static_cast<std::size_t>(i)];
                if (!isValid(sParam)) {
                    continue;
                }
                matplot::plot(ax2, freqGHz, unwrapPhaseDegrees(sParam));
            }
            matplot::ylabel(ax2, "Phase [°]");
            matplot::grid(ax2, true);
            matplot::xlabel(ax2, "Frequency [GHz]");
        }

        _saveFigure(fig, outputDir / ("S_x" + std::to_string(i + 1) + ".png"), transparent);
    }
}

std::optional<Postprocessor::DiffPairSdd> Postprocessor::getDiffPairSdd(std::int32_t diffPairIndex) const {
    const auto& pairs = _simConfig.diffPairs();
    if (diffPairIndex < 0 || static_cast<std::size_t>(diffPairIndex) >= pairs.size()) {
        return std::nullopt;
    }
    const auto& pair = pairs[static_cast<std::size_t>(diffPairIndex)];
    if (!pair.correct()) {
        return std::nullopt;
    }
    const auto sp = static_cast<std::size_t>(*pair.positiveExcitation().resolvedIndex());
    const auto sn = static_cast<std::size_t>(*pair.negativeExcitation().resolvedIndex());
    const auto ep = static_cast<std::size_t>(*pair.positiveProbe().resolvedIndex());
    const auto en = static_cast<std::size_t>(*pair.negativeProbe().resolvedIndex());
    if (!isValid(_sParams[sp][sp]) || !isValid(_sParams[sn][sn])) {
        return std::nullopt;
    }

    DiffPairSdd result;
    if (isValid(_sParams[sp][sp]) && isValid(_sParams[sn][sp]) && isValid(_sParams[sp][sn]) &&
        isValid(_sParams[sn][sn])) {
        std::vector<double> sdd11(_frequencies.size());
        for (std::size_t f = 0; f < _frequencies.size(); ++f) {
            const std::complex<double> v =
                0.5 * (_sParams[sp][sp][f] - _sParams[sn][sp][f] - _sParams[sp][sn][f] + _sParams[sn][sn][f]);
            sdd11[f] = 20 * std::log10(std::abs(v));
        }
        result.sdd11Db = std::move(sdd11);
    }
    if (isValid(_sParams[ep][sp]) && isValid(_sParams[ep][sn]) && isValid(_sParams[en][sp]) &&
        isValid(_sParams[en][sn])) {
        std::vector<double> sdd21(_frequencies.size());
        for (std::size_t f = 0; f < _frequencies.size(); ++f) {
            const std::complex<double> v =
                0.5 * (_sParams[ep][sp][f] - _sParams[ep][sn][f] - _sParams[en][sp][f] + _sParams[en][sn][f]);
            sdd21[f] = 20 * std::log10(std::abs(v));
        }
        result.sdd21Db = std::move(sdd21);
    }
    if (!result.sdd11Db.has_value() && !result.sdd21Db.has_value()) {
        return std::nullopt;
    }
    return result;
}

std::optional<Postprocessor::DiffPairImpedance> Postprocessor::getDiffPairImpedance(std::int32_t diffPairIndex) const {
    const auto& pairs = _simConfig.diffPairs();
    if (diffPairIndex < 0 || static_cast<std::size_t>(diffPairIndex) >= pairs.size()) {
        return std::nullopt;
    }
    const auto& pair = pairs[static_cast<std::size_t>(diffPairIndex)];
    if (!pair.correct()) {
        return std::nullopt;
    }
    const auto sp = static_cast<std::size_t>(*pair.positiveExcitation().resolvedIndex());
    const auto sn = static_cast<std::size_t>(*pair.negativeExcitation().resolvedIndex());
    const auto ep = static_cast<std::size_t>(*pair.positiveProbe().resolvedIndex());
    const auto en = static_cast<std::size_t>(*pair.negativeProbe().resolvedIndex());
    if (!isValid(_sParams[sp][sp]) || !isValid(_sParams[sn][sn])) {
        return std::nullopt;
    }

    if (!(_referenceZs[sp] == _referenceZs[sn] && _referenceZs[sn] == _referenceZs[ep] &&
          _referenceZs[ep] == _referenceZs[en])) {
        logError("Reference impedances for ports in differential pair " + pair.name().value_or("") +
                  " are not all equal. Cannot calculate impedance");
        return std::nullopt;
    }

    const double z0 = _referenceZs[sp];
    DiffPairImpedance result;
    result.magnitudeOhm.resize(_frequencies.size());
    result.angleDeg.resize(_frequencies.size());
    for (std::size_t f = 0; f < _frequencies.size(); ++f) {
        // Mixed-mode reflection for an ideal odd-mode incident wave. Each single-ended port is
        // normalized to z0, therefore the differential reference impedance is 2*z0 (not z0).
        const std::complex<double> gamma =
            0.5 * (_sParams[sp][sp][f] - _sParams[sn][sp][f] - _sParams[sp][sn][f] + _sParams[sn][sn][f]);
        const std::complex<double> impedance = (2.0 * z0) * (1.0 + gamma) / (1.0 - gamma);
        result.magnitudeOhm[f] = std::abs(impedance);
        result.angleDeg[f] = std::arg(impedance) * 180.0 / M_PI;
    }
    return result;
}

void Postprocessor::renderDiffPairSParams(bool transparent, const std::filesystem::path& outputDir) const {
    logInfo("Rendering differential pair S-parameter plots");
    const std::vector<double> freqGHz = _scaleFreqGHz(_frequencies);

    for (std::size_t idx = 0; idx < _simConfig.diffPairs().size(); ++idx) {
        const std::optional<DiffPairSdd> sdd = getDiffPairSdd(static_cast<std::int32_t>(idx));
        if (!sdd.has_value()) {
            continue;
        }

        auto fig = _newFigure();
        matplot::hold(true);
        if (sdd->sdd11Db.has_value()) {
            matplot::plot(freqGHz, *sdd->sdd11Db)->display_name("$SDD_{11}$");
        }
        if (sdd->sdd21Db.has_value()) {
            matplot::plot(freqGHz, *sdd->sdd21Db)->display_name("$SDD_{21}$");
        }

        matplot::legend();
        matplot::xlabel("Frequency [GHz]");
        matplot::ylabel("Magnitude [dB]");
        matplot::grid(true);
        const auto currentYlim = matplot::gca()->ylim();
        matplot::gca()->ylim({std::min(currentYlim[0], -60.0), std::max(currentYlim[1], 5.0)});
        _saveFigure(fig, outputDir / "SDD_Diff", transparent);
    }
}

void Postprocessor::renderDiffImpedance(bool transparent, const std::filesystem::path& outputDir) const {
    logInfo("Rendering differential pair impedance plots");
    const std::vector<double> freqGHz = _scaleFreqGHz(_frequencies);
    for (std::size_t idx = 0; idx < _simConfig.diffPairs().size(); ++idx) {
        const std::optional<DiffPairImpedance> impedance = getDiffPairImpedance(static_cast<std::int32_t>(idx));
        if (!impedance.has_value()) {
            continue;
        }

        auto fig = _newFigure();
        matplot::axes_handle ax0 = matplot::subplot(2, 1, 0);
        matplot::plot(ax0, freqGHz, impedance->magnitudeOhm);
        ax0->ylabel("Magnitude, $|Z_{diff}| [\\Omega]$");
        matplot::grid(ax0, true);
        const auto ylim0 = ax0->ylim();
        ax0->ylim({std::min(ylim0[0], 0.0), std::max(ylim0[1], 200.0)});

        matplot::axes_handle ax1 = matplot::subplot(2, 1, 1);
        matplot::plot(ax1, freqGHz, impedance->angleDeg)->line_style("--").color("orange");
        ax1->ylabel("Angle, $arg(Z_{diff}) [^\\circ]$");
        ax1->xlabel("Frequency [GHz]");
        matplot::grid(ax1, true);
        const auto ylim1 = ax1->ylim();
        ax1->ylim({std::min(ylim1[0], -90.0), std::max(ylim1[1], 90.0)});

        _saveFigure(fig, outputDir / "Z_diff.png", transparent);
    }
}

void Postprocessor::renderImpedance(bool transparent, const std::filesystem::path& outputDir) const {
    logInfo("Rendering impedance plots");
    const std::vector<double> freqGHz = _scaleFreqGHz(_frequencies);
    for (std::int32_t port = 0; port < _count; ++port) {
        const auto& impedance = _impedances[static_cast<std::size_t>(port)];
        if (!isValid(impedance)) {
            continue;
        }
        std::vector<double> mag(impedance.size());
        std::vector<double> angleDeg(impedance.size());
        for (std::size_t f = 0; f < impedance.size(); ++f) {
            mag[f] = std::abs(impedance[f]);
            angleDeg[f] = std::arg(impedance[f]) * 180.0 / M_PI;
        }

        auto fig = _newFigure();
        matplot::axes_handle ax0 = matplot::subplot(2, 1, 0);
        matplot::plot(ax0, freqGHz, mag);
        ax0->ylabel("Magnitude, $|Z_{" + std::to_string(port) + "}| [\\Omega]$");
        matplot::grid(ax0, true);
        const auto ylim0 = ax0->ylim();
        ax0->ylim({std::min(ylim0[0], 0.0), std::max(ylim0[1], 100.0)});

        matplot::axes_handle ax1 = matplot::subplot(2, 1, 1);
        matplot::plot(ax1, freqGHz, angleDeg)->line_style("--").color("orange");
        ax1->ylabel("Angle, $arg(Z_{" + std::to_string(port) + "}) [^\\circ]$");
        ax1->xlabel("Frequency [GHz]");
        matplot::grid(ax1, true);
        const auto ylim1 = ax1->ylim();
        ax1->ylim({std::min(ylim1[0], -90.0), std::max(ylim1[1], 90.0)});

        _saveFigure(fig, outputDir / ("Z_" + std::to_string(port + 1) + ".png"), transparent);
    }
}

void Postprocessor::renderProbes(bool transparent, const std::filesystem::path& outputDir) const {
    logInfo("Rendering passive probe plots");
    const std::vector<double> freqGHz = _scaleFreqGHz(_frequencies);
    for (std::int32_t probe = 0; probe < _count; ++probe) {
        bool any = false;
        for (std::int32_t exc = 0; exc < _count; ++exc) {
            if (isValid(_probeVoltage[static_cast<std::size_t>(probe)][static_cast<std::size_t>(exc)])) {
                any = true;
                break;
            }
        }
        if (!any) {
            continue;
        }

        auto fig = _newFigure();
        matplot::axes_handle ax0 = matplot::subplot(2, 1, 0);
        matplot::hold(ax0, true);
        matplot::axes_handle ax1 = matplot::subplot(2, 1, 1);
        matplot::hold(ax1, true);
        for (std::int32_t exc = 0; exc < _count; ++exc) {
            const auto& v = _probeVoltage[static_cast<std::size_t>(probe)][static_cast<std::size_t>(exc)];
            const auto& i = _probeCurrent[static_cast<std::size_t>(probe)][static_cast<std::size_t>(exc)];
            if (!isValid(v)) {
                continue;
            }
            std::vector<double> vMag(v.size());
            std::vector<double> iMag(i.size());
            for (std::size_t f = 0; f < v.size(); ++f) {
                vMag[f] = std::abs(v[f]);
                iMag[f] = std::abs(i[f]);
            }
            matplot::plot(ax0, freqGHz, vMag)->display_name("exc. port " + std::to_string(exc + 1));
            matplot::plot(ax1, freqGHz, iMag)->display_name("exc. port " + std::to_string(exc + 1));
        }
        ax0->ylabel("$|V_{" + std::to_string(probe + 1) + "}| [V]$");
        matplot::grid(ax0, true);
        matplot::legend(ax0);
        ax1->ylabel("$|I_{" + std::to_string(probe + 1) + "}| [A]$");
        ax1->xlabel("Frequency [GHz]");
        matplot::grid(ax1, true);

        _saveFigure(fig, outputDir / ("Probe_x" + std::to_string(probe + 1) + ".png"), transparent);
    }
}

void Postprocessor::renderSmith(bool transparent, const std::filesystem::path& outputDir) const {
    logInfo("Rendering smith charts");
    for (std::int32_t port = 0; port < _count; ++port) {
        const auto& s = _sParams[static_cast<std::size_t>(port)][static_cast<std::size_t>(port)];
        if (!isValid(s)) {
            continue;
        }

        auto fig = _newFigure();
        auto ax = fig->current_axes();
        matplot::hold(ax, true);

        // Normalized-impedance Smith grid. For z=r+jx, Γ=(z-1)/(z+1): fixed r produces a circle
        // centred at r/(r+1) with radius 1/(r+1), while fixed x produces an arc from the rim to Γ=1.
        std::vector<double> circleX;
        std::vector<double> circleY;
        for (std::int32_t d = 0; d <= 360; ++d) {
            const double a = static_cast<double>(d) * M_PI / 180.0;
            circleX.push_back(std::cos(a));
            circleY.push_back(std::sin(a));
        }
        matplot::plot(ax, circleX, circleY)->color("black").line_width(1.2F);

        constexpr std::array<double, 5> gridValues{0.2, 0.5, 1.0, 2.0, 5.0};
        for (const double resistance : gridValues) {
            std::vector<double> x;
            std::vector<double> y;
            const double radius = 1 / (1 + resistance);
            const double center = resistance / (1 + resistance);
            for (std::int32_t d = 0; d <= 360; ++d) {
                const double angle = static_cast<double>(d) * M_PI / 180.0;
                x.push_back(center + radius * std::cos(angle));
                y.push_back(radius * std::sin(angle));
            }
            matplot::plot(ax, x, y)->color({0.65F, 0.65F, 0.65F, 0.65F}).line_width(0.6F);
        }

        for (const double magnitude : gridValues) {
            for (const double reactance : {magnitude, -magnitude}) {
                std::vector<double> x;
                std::vector<double> y;
                auto appendGamma = [&](double resistance) {
                    const double denominator = (resistance + 1) * (resistance + 1) + reactance * reactance;
                    x.push_back((resistance * resistance + reactance * reactance - 1) / denominator);
                    y.push_back(2 * reactance / denominator);
                };
                appendGamma(0);
                for (std::int32_t sample = 0; sample <= 180; ++sample) {
                    appendGamma(std::pow(10.0, -4.0 + 8.0 * static_cast<double>(sample) / 180.0));
                }
                x.push_back(1);
                y.push_back(0);
                matplot::plot(ax, x, y)->color({0.75F, 0.75F, 0.75F, 0.75F}).line_width(0.5F);
            }
        }
        matplot::plot(ax, std::vector<double>{-1, 1}, std::vector<double>{0, 0})
            ->color("black").line_width(0.8F);

        const double s11Margin = _simConfig.ports()[static_cast<std::size_t>(port)].dBMargin();
        const double vswrMargin = (std::pow(10.0, s11Margin / 20.0) + 1) / (std::pow(10.0, s11Margin / 20.0) - 1);
        const double vswrGamma = std::abs((vswrMargin - 1) / (vswrMargin + 1));
        std::vector<double> vswrX;
        std::vector<double> vswrY;
        for (std::int32_t d = 0; d <= 360; ++d) {
            const double a = static_cast<double>(d) * M_PI / 180.0;
            vswrX.push_back(vswrGamma * std::cos(a));
            vswrY.push_back(vswrGamma * std::sin(a));
        }
        matplot::plot(ax, vswrX, vswrY)->line_style("--").color("red").display_name("VSWR margin");

        std::vector<double> reGamma(s.size());
        std::vector<double> imGamma(s.size());
        for (std::size_t f = 0; f < s.size(); ++f) {
            reGamma[f] = s[f].real();
            imGamma[f] = s[f].imag();
        }
        matplot::plot(ax, reGamma, imGamma)
            ->line_width(1.5F)
            .display_name("$S_{" + std::to_string(port + 1) + std::to_string(port + 1) + "}$");

        matplot::axis(ax, matplot::equal);
        ax->xlim({-1.05, 1.05});
        ax->ylim({-1.05, 1.05});
        matplot::legend(ax);
        _saveFigure(fig, outputDir / ("S_" + std::to_string(port + 1) + std::to_string(port + 1) + "_smith.png"),
                    transparent);
    }
}

void Postprocessor::renderTraceDelays(bool transparent, const std::filesystem::path& outputDir) const {
    logInfo("Rendering trace delay plots");
    const std::vector<double> freqGHz = _scaleFreqGHz(_frequencies);

    for (const auto& trace : _simConfig.traces()) {
        if (!trace.correct()) {
            continue;
        }
        const auto start = static_cast<std::size_t>(*trace.start().resolvedIndex());
        const auto stop = static_cast<std::size_t>(*trace.stop().resolvedIndex());
        if (std::any_of(_delays[stop][start].begin(), _delays[stop][start].end(),
                         [](double v) { return std::isnan(v); })) {
            continue;
        }
        std::vector<double> delayNs(_delays[stop][start].size());
        for (std::size_t f = 0; f < delayNs.size(); ++f) {
            delayNs[f] = _delays[stop][start][f] * 1e9;
        }
        auto fig = _newFigure();
        matplot::plot(freqGHz, delayNs)->display_name(trace.name().value_or("") + " delay");
        matplot::legend();
        matplot::xlabel("Frequency [GHz]");
        matplot::ylabel("Trace delay [ns]");
        matplot::grid(true);
        _saveFigure(fig, outputDir / (trace.name().value_or("trace") + "_delay.png"), transparent);
    }

    for (const auto& pair : _simConfig.diffPairs()) {
        if (!pair.correct()) {
            continue;
        }
        const auto sp = static_cast<std::size_t>(*pair.positiveExcitation().resolvedIndex());
        const auto sn = static_cast<std::size_t>(*pair.negativeExcitation().resolvedIndex());
        const auto ep = static_cast<std::size_t>(*pair.positiveProbe().resolvedIndex());
        const auto en = static_cast<std::size_t>(*pair.negativeProbe().resolvedIndex());
        const bool nOk = !std::any_of(_delays[en][sn].begin(), _delays[en][sn].end(),
                                       [](double v) { return std::isnan(v); });
        const bool pOk = !std::any_of(_delays[ep][sp].begin(), _delays[ep][sp].end(),
                                       [](double v) { return std::isnan(v); });
        if (!nOk || !pOk) {
            continue;
        }
        std::vector<double> nDelay(_delays[en][sn].size());
        std::vector<double> pDelay(_delays[ep][sp].size());
        for (std::size_t f = 0; f < nDelay.size(); ++f) {
            nDelay[f] = _delays[en][sn][f] * 1e9;
            pDelay[f] = _delays[ep][sp][f] * 1e9;
        }
        auto fig = _newFigure();
        matplot::hold(true);
        matplot::plot(freqGHz, nDelay)->display_name("N trace delay");
        matplot::plot(freqGHz, pDelay)->display_name("P trace delay");
        matplot::legend();
        matplot::xlabel("Frequency [GHz]");
        matplot::ylabel("Trace delay [ns]");
        matplot::grid(true);
        _saveFigure(fig, outputDir / "diff_delay.png", transparent);
    }
}

void Postprocessor::saveToFile(const std::filesystem::path& outputDir) const {
    for (std::int32_t i = 0; i < _count; ++i) {
        if (isValid(_sParams[static_cast<std::size_t>(i)][static_cast<std::size_t>(i)])) {
            savePortToFile(i, outputDir);
        }
    }
}

void Postprocessor::savePortToFile(std::int32_t portNumber, const std::filesystem::path& path) const {
    const auto p = static_cast<std::size_t>(portNumber);
    std::string header = "Frequency [MHz],";
    for (std::int32_t i = 0; i < _count; ++i) {
        header += "|S" + std::to_string(i) + "-" + std::to_string(portNumber) + "| [-],";
    }
    for (std::int32_t i = 0; i < _count; ++i) {
        header += "Arg(S" + std::to_string(i) + "-" + std::to_string(portNumber) + ") [rad],";
    }
    for (std::int32_t i = 0; i < _count; ++i) {
        header += "Delay " + std::to_string(portNumber) + ">" + std::to_string(i) + " [s],";
    }
    header += "|Z" + std::to_string(portNumber) + "| [Ohm],";
    header += "Arg(Z" + std::to_string(portNumber) + ") [rad]";

    std::ofstream file(path / ("Port_" + std::to_string(portNumber) + "_data.csv"));
    file << header << "\n";
    for (std::size_t f = 0; f < _frequencies.size(); ++f) {
        file << (_frequencies[f] / 1e6);
        for (std::int32_t i = 0; i < _count; ++i) {
            file << ", " << std::abs(_sParams[static_cast<std::size_t>(i)][p][f]);
        }
        for (std::int32_t i = 0; i < _count; ++i) {
            file << ", " << std::arg(_sParams[static_cast<std::size_t>(i)][p][f]);
        }
        for (std::int32_t i = 0; i < _count; ++i) {
            file << ", " << _delays[static_cast<std::size_t>(i)][p][f];
        }
        file << ", " << std::abs(_impedances[p][f]);
        file << ", " << std::arg(_impedances[p][f]);
        file << "\n";
    }
}

void Postprocessor::sparamToFile(const std::filesystem::path& simulationDir) const {
    for (std::int32_t i = 0; i < _count; ++i) {
        if (isValid(_sParams[static_cast<std::size_t>(i)][static_cast<std::size_t>(i)])) {
            sparamPortToFile(i, simulationDir);
        }
    }
}

void Postprocessor::sparamPortToFile(std::int32_t portNumber, const std::filesystem::path& path) const {
    const auto p = static_cast<std::size_t>(portNumber);
    std::string header = "Frequency [MHz], ";
    for (std::int32_t i = 0; i < _count; ++i) {
        header += "re(S" + std::to_string(i) + "-" + std::to_string(portNumber) + "), ";
    }
    for (std::int32_t i = 0; i < _count; ++i) {
        header += "im(S" + std::to_string(i) + "-" + std::to_string(portNumber) + "), ";
    }

    std::ofstream file(path / _sparamPath(portNumber));
    file << header << "\n";
    for (std::size_t f = 0; f < _frequencies.size(); ++f) {
        file << (_frequencies[f] / 1e6);
        for (std::int32_t i = 0; i < _count; ++i) {
            file << ", " << _sParams[static_cast<std::size_t>(i)][p][f].real();
        }
        for (std::int32_t i = 0; i < _count; ++i) {
            file << ", " << _sParams[static_cast<std::size_t>(i)][p][f].imag();
        }
        file << "\n";
    }
}

void Postprocessor::probeToFile(const std::filesystem::path& simulationDir) const {
    for (std::int32_t i = 0; i < _count; ++i) {
        bool any = false;
        for (std::int32_t exc = 0; exc < _count; ++exc) {
            if (isValid(_probeVoltage[static_cast<std::size_t>(i)][static_cast<std::size_t>(exc)])) {
                any = true;
                break;
            }
        }
        if (any) {
            probePortToFile(i, simulationDir);
        }
    }
}

void Postprocessor::probePortToFile(std::int32_t probeNumber, const std::filesystem::path& path) const {
    const auto p = static_cast<std::size_t>(probeNumber);
    std::string header = "Frequency [MHz], ";
    for (std::int32_t i = 0; i < _count; ++i) {
        header += "re(V-" + std::to_string(i) + "), im(V-" + std::to_string(i) + "), re(I-" + std::to_string(i) +
                  "), im(I-" + std::to_string(i) + "), re(Z-" + std::to_string(i) + "), im(Z-" + std::to_string(i) +
                  "), ";
    }

    std::ofstream file(path / _probePath(probeNumber));
    file << header << "\n";
    for (std::size_t f = 0; f < _frequencies.size(); ++f) {
        file << (_frequencies[f] / 1e6);
        for (std::int32_t i = 0; i < _count; ++i) {
            const auto ii = static_cast<std::size_t>(i);
            file << ", " << _probeVoltage[p][ii][f].real() << ", " << _probeVoltage[p][ii][f].imag() << ", "
                 << _probeCurrent[p][ii][f].real() << ", " << _probeCurrent[p][ii][f].imag() << ", "
                 << _probeImpedance[p][ii][f].real() << ", " << _probeImpedance[p][ii][f].imag();
        }
        file << "\n";
    }
}

namespace {

std::vector<std::string> _splitCsvLine(const std::string& line) {
    std::vector<std::string> fields;
    std::string field;
    bool inQuotes = false;
    for (std::size_t i = 0; i < line.size(); ++i) {
        const char c = line[i];
        if (inQuotes) {
            if (c == '"') {
                if (i + 1 < line.size() && line[i + 1] == '"') {
                    field.push_back('"');
                    ++i;
                } else {
                    inQuotes = false;
                }
            } else {
                field.push_back(c);
            }
        } else if (c == '"') {
            inQuotes = true;
        } else if (c == ',') {
            fields.push_back(field);
            field.clear();
        } else {
            field.push_back(c);
        }
    }
    fields.push_back(field);
    return fields;
}

std::string _lower(std::string s) {
    for (char& c : s) {
        c = static_cast<char>(std::tolower(static_cast<unsigned char>(c)));
    }
    return s;
}

std::string _trim(const std::string& s) {
    std::size_t begin = 0;
    while (begin < s.size() && std::isspace(static_cast<unsigned char>(s[begin])) != 0) {
        ++begin;
    }
    std::size_t end = s.size();
    while (end > begin && std::isspace(static_cast<unsigned char>(s[end - 1])) != 0) {
        --end;
    }
    return s.substr(begin, end - begin);
}

} // namespace

std::expected<void, std::string> Postprocessor::loadSparams(const std::filesystem::path& inputDir) {
    for (std::size_t idx = 0; idx < _simConfig.ports().size(); ++idx) {
        const PortConfig& port = _simConfig.ports()[idx];
        if (!port.excite()) {
            continue;
        }
        const std::filesystem::path fpath = inputDir / _sparamPath(static_cast<std::int32_t>(idx));
        if (!std::filesystem::exists(fpath)) {
            return std::unexpected("Input file with s-parameters (" + std::filesystem::absolute(fpath).string() +
                                    ") could not be found. Did you run simulation step?");
        }

        std::ifstream csvfile(fpath);
        std::string headerLine;
        std::getline(csvfile, headerLine);
        const std::vector<std::string> header = _splitCsvLine(headerLine);

        double freqMul = 1.0;
        std::size_t freqCol = 0;
        std::map<std::string, std::map<std::pair<std::int32_t, std::int32_t>, std::size_t>> sMap;
        std::map<std::pair<std::int32_t, std::int32_t>, bool> phDegrees;
        static const std::regex sxxPattern(R"(s([0-9]+)[,-]?([0-9]+))");

        for (std::size_t colNum = 0; colNum < header.size(); ++colNum) {
            const std::string lcell = _lower(_trim(header[colNum]));
            if (lcell.find("freq") != std::string::npos) {
                if (header[colNum].find("kHz") != std::string::npos) {
                    freqMul = 1e3;
                } else if (header[colNum].find("MHz") != std::string::npos) {
                    freqMul = 1e6;
                } else if (header[colNum].find("GHz") != std::string::npos) {
                    freqMul = 1e9;
                }
                freqCol = colNum;
                continue;
            }
            std::smatch match;
            if (!std::regex_search(lcell, match, sxxPattern)) {
                continue;
            }
            const std::pair<std::int32_t, std::int32_t> sxx = {std::stoi(match[1].str()), std::stoi(match[2].str())};
            if (lcell.find("mag") != std::string::npos || lcell.find("abs") != std::string::npos ||
                lcell.rfind('|', 0) == 0) {
                sMap["mag"][sxx] = colNum;
            } else if (lcell.find("ang") != std::string::npos || lcell.find("arg") != std::string::npos ||
                       lcell.find("ph") != std::string::npos) {
                sMap["arg"][sxx] = colNum;
                phDegrees[sxx] = lcell.find("deg") != std::string::npos || header[colNum].find("\xC2\xB0") != std::string::npos;
            } else if (lcell.find("re") != std::string::npos) {
                sMap["re"][sxx] = colNum;
            } else if (lcell.find("im") != std::string::npos) {
                sMap["im"][sxx] = colNum;
            }
        }

        std::vector<std::vector<double>> rows;
        std::string line;
        while (std::getline(csvfile, line)) {
            if (_trim(line).empty()) {
                continue;
            }
            const std::vector<std::string> cells = _splitCsvLine(line);
            std::vector<double> row;
            row.reserve(cells.size());
            for (const auto& cell : cells) {
                row.push_back(std::stod(cell));
            }
            rows.push_back(std::move(row));
        }

        _frequencies.resize(rows.size());
        for (std::size_t r = 0; r < rows.size(); ++r) {
            _frequencies[r] = rows[r][freqCol] * freqMul;
        }

        for (const auto& [sxx, col] : sMap["mag"]) {
            const auto argIt = sMap["arg"].find(sxx);
            if (argIt == sMap["arg"].end()) {
                return std::unexpected("S-param CSV error: no phase data matching `mag(S" + std::to_string(sxx.first) +
                                        "-" + std::to_string(sxx.second) + ")` from column " + std::to_string(col) +
                                        "!");
            }
            const bool degrees = phDegrees.at(sxx);
            for (std::size_t r = 0; r < rows.size(); ++r) {
                const double phase = degrees ? rows[r][argIt->second] * M_PI / 180.0 : rows[r][argIt->second];
                _sParams[static_cast<std::size_t>(sxx.first)][static_cast<std::size_t>(sxx.second)][r] =
                    std::polar(rows[r][col], phase);
            }
        }
        for (const auto& [sxx, col] : sMap["re"]) {
            const auto imIt = sMap["im"].find(sxx);
            if (imIt == sMap["im"].end()) {
                return std::unexpected("S-param CSV error: no imaginary data matching `re(S" + std::to_string(sxx.first) +
                                        "-" + std::to_string(sxx.second) + ")` from column " + std::to_string(col) +
                                        "!");
            }
            for (std::size_t r = 0; r < rows.size(); ++r) {
                _sParams[static_cast<std::size_t>(sxx.first)][static_cast<std::size_t>(sxx.second)][r] =
                    std::complex<double>(rows[r][col], rows[r][imIt->second]);
            }
        }
    }
    return {};
}

std::expected<void, std::string> Postprocessor::loadProbes(const std::filesystem::path& inputDir) {
    for (std::size_t idx = 0; idx < _simConfig.ports().size(); ++idx) {
        if (_simConfig.ports()[idx].absorbSignal()) {
            continue;
        }
        const std::filesystem::path fpath = inputDir / _probePath(static_cast<std::int32_t>(idx));
        if (!std::filesystem::exists(fpath)) {
            continue; // this probe simply wasn't reached by any excited port's own run
        }

        std::ifstream csvfile(fpath);
        std::string headerLine;
        std::getline(csvfile, headerLine);
        const std::vector<std::string> header = _splitCsvLine(headerLine);

        // 'v'/'i'/'z' -- voltage, current, and (trace-impedance probes only) measured impedance.
        static const std::regex viPattern(R"(([viz])-([0-9]+))");
        std::map<std::pair<char, std::int32_t>, std::size_t> reCol, imCol;
        for (std::size_t colNum = 0; colNum < header.size(); ++colNum) {
            const std::string lcell = _lower(_trim(header[colNum]));
            std::smatch match;
            if (!std::regex_search(lcell, match, viPattern)) {
                continue;
            }
            const std::pair<char, std::int32_t> key = {match[1].str()[0], std::stoi(match[2].str())};
            if (lcell.find("re(") != std::string::npos) {
                reCol[key] = colNum;
            } else if (lcell.find("im(") != std::string::npos) {
                imCol[key] = colNum;
            }
        }

        std::vector<std::vector<double>> rows;
        std::string line;
        while (std::getline(csvfile, line)) {
            if (_trim(line).empty()) {
                continue;
            }
            const std::vector<std::string> cells = _splitCsvLine(line);
            std::vector<double> row;
            row.reserve(cells.size());
            for (const auto& cell : cells) {
                row.push_back(std::stod(cell));
            }
            rows.push_back(std::move(row));
        }

        for (const auto& [key, col] : reCol) {
            const auto imIt = imCol.find(key);
            if (imIt == imCol.end()) {
                return std::unexpected("Probe CSV error: no imaginary data matching column " + std::to_string(col));
            }
            std::vector<std::complex<double>> series(rows.size());
            for (std::size_t r = 0; r < rows.size(); ++r) {
                series[r] = std::complex<double>(rows[r][col], rows[r][imIt->second]);
            }
            auto& dest = key.first == 'v' ? _probeVoltage : key.first == 'i' ? _probeCurrent : _probeImpedance;
            dest[idx][static_cast<std::size_t>(key.second)] = std::move(series);
        }
    }
    return {};
}

} // namespace kiems
