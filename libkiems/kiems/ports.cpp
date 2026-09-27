#include "ports.hpp"

#include <algorithm>
#include <array>
#include <cmath>
#include <fstream>
#include <limits>
#include <memory>
#include <sstream>
#include <stdexcept>

#include "csx_grid_utils.hpp"

namespace kiems {

namespace {

std::expected<std::pair<std::vector<double>, std::vector<double>>, std::string> _loadUiFile(
    const std::filesystem::path& path) {
    std::ifstream file(path);
    if (!file.is_open()) {
        return std::unexpected("Failed to open probe file: " + path.string());
    }
    std::vector<double> time;
    std::vector<double> value;
    std::string line;
    while (std::getline(file, line)) {
        if (line.empty() || line[0] == '%') {
            continue;
        }
        std::istringstream iss(line);
        std::vector<double> row;
        double v = 0;
        while (iss >> v) {
            row.push_back(v);
        }
        if (row.size() >= 2) {
            time.push_back(row[0]);
            value.push_back(row[1]);
        }
    }
    return std::pair{std::move(time), std::move(value)};
}

std::size_t _argminAbsDiff(const std::vector<double>& v, double target) {
    std::size_t best = 0;
    double bestDiff = std::numeric_limits<double>::infinity();
    for (std::size_t i = 0; i < v.size(); ++i) {
        const double diff = std::abs(v[i] - target);
        if (diff < bestDiff) {
            bestDiff = diff;
            best = i;
        }
    }
    return best;
}

void _fft(std::vector<std::complex<double>>& values, bool inverse) {
    const std::size_t count = values.size();
    for (std::size_t i = 1, j = 0; i < count; ++i) {
        std::size_t bit = count >> 1;
        for (; j & bit; bit >>= 1) {
            j ^= bit;
        }
        j ^= bit;
        if (i < j) {
            std::swap(values[i], values[j]);
        }
    }
    for (std::size_t length = 2; length <= count; length <<= 1) {
        const double angle = (inverse ? 2.0 : -2.0) * M_PI / static_cast<double>(length);
        const std::complex<double> step(std::cos(angle), std::sin(angle));
        for (std::size_t start = 0; start < count; start += length) {
            std::complex<double> phase(1.0, 0.0);
            for (std::size_t offset = 0; offset < length / 2; ++offset) {
                const std::complex<double> even = values[start + offset];
                const std::complex<double> odd = values[start + offset + length / 2] * phase;
                values[start + offset] = even + odd;
                values[start + offset + length / 2] = even - odd;
                phase *= step;
            }
        }
    }
    if (inverse) {
        const double scale = 1.0 / static_cast<double>(count);
        for (auto& value : values) {
            value *= scale;
        }
    }
}

bool _uniformGrid(const std::vector<double>& values, double& step) {
    if (values.size() < 2) {
        step = 0.0;
        return true;
    }
    step = values[1] - values[0];
    for (std::size_t index = 2; index < values.size(); ++index) {
        const double expected = values[0] + static_cast<double>(index) * step;
        const double tolerance = std::max(std::abs(step) * 1e-5,
                                          std::numeric_limits<double>::epsilon() * std::abs(expected) * 32.0);
        if (std::abs(values[index] - expected) > tolerance) {
            return false;
        }
    }
    return true;
}

// Evaluates a uniformly sampled signal at an arbitrary, uniformly spaced set of frequencies using
// Bluestein's chirp-Z identity. Unlike a normal FFT, neither the first frequency nor the frequency
// spacing has to coincide with an FFT bin, so this is numerically equivalent to the direct DFT
// below while reducing a real 300,000-sample x 1,001-frequency probe from O(NM) transcendental-heavy
// work to O((N+M) log(N+M)). The kernel spectrum is cached because every U/I probe in one simulation
// has the same time/frequency grids.
class ChirpZPlan {
public:
    ChirpZPlan(const std::vector<double>& time, const std::vector<double>& frequency, double dt, double df)
        : _inputCount(time.size()),
          _outputCount(frequency.size()),
          _timeStart(time.empty() ? 0.0 : time.front()),
          _timeStep(dt),
          _frequencyStart(frequency.empty() ? 0.0 : frequency.front()),
          _frequencyStep(df),
          _inputChirp(_inputCount),
          _outputChirp(_outputCount) {
        _fftSize = 1;
        const std::size_t convolutionSize = _inputCount + _outputCount - 1;
        while (_fftSize < convolutionSize) {
            _fftSize <<= 1;
        }

        std::vector<std::complex<double>> kernel(_fftSize, {0.0, 0.0});
        const auto unitPhase = [](double angle) {
            const double reduced = std::remainder(angle, 2.0 * M_PI);
            return std::complex<double>(std::cos(reduced), std::sin(reduced));
        };
        for (std::size_t n = 0; n < _inputCount; ++n) {
            const double nd = static_cast<double>(n);
            _inputChirp[n] = unitPhase(-2.0 * M_PI * _frequencyStart * _timeStep * nd -
                                       M_PI * _frequencyStep * _timeStep * nd * nd);
        }
        for (std::size_t k = 0; k < _outputCount; ++k) {
            const double kd = static_cast<double>(k);
            _outputChirp[k] = unitPhase(-2.0 * M_PI * (_frequencyStart + kd * _frequencyStep) * _timeStart -
                                        M_PI * _frequencyStep * _timeStep * kd * kd);
        }
        for (std::ptrdiff_t m = -static_cast<std::ptrdiff_t>(_inputCount - 1);
             m <= static_cast<std::ptrdiff_t>(_outputCount - 1); ++m) {
            const double md = static_cast<double>(m);
            kernel[static_cast<std::size_t>(m + static_cast<std::ptrdiff_t>(_inputCount - 1))] =
                unitPhase(M_PI * _frequencyStep * _timeStep * md * md);
        }
        _fft(kernel, false);
        _kernelSpectrum = std::move(kernel);
    }

    bool matches(const std::vector<double>& time, const std::vector<double>& frequency, double dt, double df) const {
        return time.size() == _inputCount && frequency.size() == _outputCount &&
               (time.empty() || time.front() == _timeStart) && dt == _timeStep &&
               (frequency.empty() || frequency.front() == _frequencyStart) && df == _frequencyStep;
    }

    std::vector<std::complex<double>> transform(const std::vector<double>& samples) const {
        std::vector<std::complex<double>> work(_fftSize, {0.0, 0.0});
        for (std::size_t n = 0; n < _inputCount; ++n) {
            work[n] = samples[n] * _inputChirp[n];
        }
        _fft(work, false);
        for (std::size_t index = 0; index < _fftSize; ++index) {
            work[index] *= _kernelSpectrum[index];
        }
        _fft(work, true);

        std::vector<std::complex<double>> result(_outputCount);
        for (std::size_t k = 0; k < _outputCount; ++k) {
            result[k] = work[k + _inputCount - 1] * _outputChirp[k];
        }
        return result;
    }

private:
    std::size_t _inputCount;
    std::size_t _outputCount;
    std::size_t _fftSize;
    double _timeStart;
    double _timeStep;
    double _frequencyStart;
    double _frequencyStep;
    std::vector<std::complex<double>> _inputChirp;
    std::vector<std::complex<double>> _outputChirp;
    std::vector<std::complex<double>> _kernelSpectrum;
};

} // namespace

std::expected<std::vector<std::complex<double>>, std::string> dftTimeToFreq(const std::vector<double>& t,
                                                                             const std::vector<double>& val,
                                                                             const std::vector<double>& freq,
                                                                             const std::string& signalType) {
    if (t.size() != val.size()) {
        return std::unexpected("Time and signal sample counts do not match");
    }
    if (signalType != "pulse" && signalType != "periodic") {
        return std::unexpected("Unknown signal type: " + signalType);
    }

    std::vector<std::complex<double>> fVal;
    double dt = 0.0;
    double df = 0.0;
    if (!t.empty() && !freq.empty() && _uniformGrid(t, dt) && _uniformGrid(freq, df)) {
        static thread_local std::unique_ptr<ChirpZPlan> cachedPlan;
        if (!cachedPlan || !cachedPlan->matches(t, freq, dt, df)) {
            cachedPlan = std::make_unique<ChirpZPlan>(t, freq, dt, df);
        }
        fVal = cachedPlan->transform(val);
    } else {
        fVal.assign(freq.size(), std::complex<double>(0, 0));
        for (std::size_t nF = 0; nF < freq.size(); ++nF) {
            std::complex<double> sum(0, 0);
            for (std::size_t n = 0; n < t.size(); ++n) {
                sum += val[n] * std::exp(std::complex<double>(0, -2 * M_PI * freq[nF] * t[n]));
            }
            fVal[nF] = sum;
        }
    }
    if (signalType == "pulse") {
        const double scalingDt = t.size() > 1 ? t[1] - t[0] : 0;
        for (auto& v : fVal) {
            v *= scalingDt;
        }
    } else if (signalType == "periodic") {
        const double n = static_cast<double>(t.size());
        for (auto& v : fVal) {
            v /= n;
        }
    }
    for (auto& v : fVal) {
        v *= 2.0;
    }
    return fVal;
}

std::expected<UIData, std::string> UIData::load(const std::vector<std::string>& filenames,
                                                  const std::filesystem::path& path, const std::vector<double>& freq,
                                                  const std::string& signalType) {
    UIData data;
    for (const auto& fn : filenames) {
        auto loaded = _loadUiFile(path / fn);
        if (!loaded) return std::unexpected(std::move(loaded).error());
        auto& [time, value] = *loaded;
        auto freqValue = dftTimeToFreq(time, value, freq, signalType);
        if (!freqValue) return std::unexpected(std::move(freqValue).error());
        data._freqValue.push_back(std::move(*freqValue));
        data._time.push_back(std::move(time));
        data._value.push_back(std::move(value));
    }
    return data;
}

Port::Port(ContinuousStructure& csx, std::int32_t portNr, Point3 start, Point3 stop, double excite,
           std::int32_t priority, std::string portNamePrefix, double delay)
    : _csx(csx),
      _number(portNr),
      _excite(excite),
      _start(start),
      _stop(stop),
      _priority(priority),
      _prefix(std::move(portNamePrefix)),
      _delay(delay) {}

std::expected<void, std::string> Port::readUiData(const std::filesystem::path& simPath,
                                                    const std::vector<double>& freq, const std::string& signalType) {
    auto uData = UIData::load(_uFilenames, simPath, freq, signalType);
    if (!uData) return std::unexpected(std::move(uData).error());
    _ufTot.assign(freq.size(), std::complex<double>(0, 0));
    for (const auto& fv : uData->freqValue()) {
        for (std::size_t i = 0; i < freq.size(); ++i) {
            _ufTot[i] += fv[i];
        }
    }

    auto iData = UIData::load(_iFilenames, simPath, freq, signalType);
    if (!iData) return std::unexpected(std::move(iData).error());
    _ifTot.assign(freq.size(), std::complex<double>(0, 0));
    for (const auto& fv : iData->freqValue()) {
        for (std::size_t i = 0; i < freq.size(); ++i) {
            _ifTot[i] += fv[i];
        }
    }
    return {};
}

std::expected<void, std::string> Port::calcPort(const std::filesystem::path& simPath, const std::vector<double>& freq,
                                                  std::optional<double> refImpedance, const std::string& signalType) {
    if (auto result = readUiData(simPath, freq, signalType); !result) return result;
    if (refImpedance.has_value()) {
        _zRef.assign(freq.size(), std::complex<double>(*refImpedance, 0));
    }
    // Otherwise _zRef must already have been populated by the subclass (LumpedPort::calcPort sets
    // it to R; MSLPort::readUiData computes a per-frequency characteristic impedance), matching
    // the Python source's ordering.

    _ufInc.resize(freq.size());
    _ifInc.resize(freq.size());
    _ufRef.resize(freq.size());
    _ifRef.resize(freq.size());
    for (std::size_t i = 0; i < freq.size(); ++i) {
        _ufInc[i] = 0.5 * (_ufTot[i] + _ifTot[i] * _zRef[i]);
        _ifInc[i] = 0.5 * (_ifTot[i] + _ufTot[i] / _zRef[i]);
        _ufRef[i] = _ufTot[i] - _ufInc[i];
        _ifRef[i] = _ifInc[i] - _ifTot[i];
    }
    return {};
}

LumpedPort::LumpedPort(ContinuousStructure& csx, std::int32_t portNr, double resistance, Point3 start, Point3 stop,
                        const std::string& excDir, double excite, std::int32_t priority, std::string portNamePrefix,
                        double delay)
    : Port(csx, portNr, start, stop, excite, priority, std::move(portNamePrefix), delay),
      _resistance(resistance),
      _excNy(axisIndex(excDir)) {
    const double direction = (_stop[static_cast<std::size_t>(_excNy)] - _start[static_cast<std::size_t>(_excNy)]) < 0
                                  ? -1.0
                                  : 1.0;
    if (_start[static_cast<std::size_t>(_excNy)] == _stop[static_cast<std::size_t>(_excNy)]) {
        throw std::runtime_error("LumpedPort: start and stop may not be identical in excitation direction");
    }

    CSProperties* lumpedR = nullptr;
    if (_resistance > 0) {
        lumpedR = addLumpedElement(_csx, _label("resist"), _excNy, true, _resistance);
    } else if (_resistance == 0) {
        lumpedR = addMetal(_csx, _label("resist"));
    }
    if (lumpedR != nullptr) {
        addBox(*lumpedR, _start, _stop, _priority);
    }

    if (_excite != 0) {
        Point3 excVec{0, 0, 0};
        excVec[static_cast<std::size_t>(_excNy)] = -1 * direction * _excite;
        CSPropExcitation* exc = addExcitation(_csx, _label("excite"), 0, excVec, _delay);
        addBox(*exc, _start, _stop, _priority);
    }

    _uFilenames = {_label("ut")};
    Point3 uStart = {0.5 * (_start[0] + _stop[0]), 0.5 * (_start[1] + _stop[1]), 0.5 * (_start[2] + _stop[2])};
    Point3 uStop = uStart;
    uStart[static_cast<std::size_t>(_excNy)] = _start[static_cast<std::size_t>(_excNy)];
    uStop[static_cast<std::size_t>(_excNy)] = _stop[static_cast<std::size_t>(_excNy)];
    CSPropProbeBox* uProbe = addProbe(_csx, _uFilenames[0], 0, -1);
    addBox(*uProbe, uStart, uStop);

    _iFilenames = {_label("it")};
    Point3 iStart = _start;
    Point3 iStop = _stop;
    const double mid = 0.5 * (_start[static_cast<std::size_t>(_excNy)] + _stop[static_cast<std::size_t>(_excNy)]);
    iStart[static_cast<std::size_t>(_excNy)] = mid;
    iStop[static_cast<std::size_t>(_excNy)] = mid;
    CSPropProbeBox* iProbe = addProbe(_csx, _iFilenames[0], 1, direction, _excNy);
    addBox(*iProbe, iStart, iStop);
}

std::expected<void, std::string> LumpedPort::calcPort(const std::filesystem::path& simPath,
                                                        const std::vector<double>& freq,
                                                        std::optional<double> refImpedance,
                                                        const std::string& signalType) {
    if (!refImpedance.has_value()) {
        refImpedance = _resistance;
    }
    return Port::calcPort(simPath, freq, refImpedance, signalType);
}

PassiveProbe::PassiveProbe(ContinuousStructure& csx, std::int32_t portNr, Point3 start, Point3 stop,
                            const std::string& excDir, std::int32_t priority, std::string portNamePrefix)
    : Port(csx, portNr, start, stop, /*excite=*/0, priority, std::move(portNamePrefix)), _excNy(axisIndex(excDir)) {
    if (_start[static_cast<std::size_t>(_excNy)] == _stop[static_cast<std::size_t>(_excNy)]) {
        throw std::runtime_error("PassiveProbe: start and stop may not be identical in probe direction");
    }
    const double direction = (_stop[static_cast<std::size_t>(_excNy)] - _start[static_cast<std::size_t>(_excNy)]) < 0
                                  ? -1.0
                                  : 1.0;

    // No metal, no resistor, no excitation box -- see this class's own doc comment. Only the U/I
    // probe boxes, placed exactly like LumpedPort's own (see its constructor above).
    _uFilenames = {_label("ut")};
    Point3 uStart = {0.5 * (_start[0] + _stop[0]), 0.5 * (_start[1] + _stop[1]), 0.5 * (_start[2] + _stop[2])};
    Point3 uStop = uStart;
    uStart[static_cast<std::size_t>(_excNy)] = _start[static_cast<std::size_t>(_excNy)];
    uStop[static_cast<std::size_t>(_excNy)] = _stop[static_cast<std::size_t>(_excNy)];
    CSPropProbeBox* uProbe = addProbe(_csx, _uFilenames[0], 0, -1);
    addBox(*uProbe, uStart, uStop);

    _iFilenames = {_label("it")};
    Point3 iStart = _start;
    Point3 iStop = _stop;
    const double mid = 0.5 * (_start[static_cast<std::size_t>(_excNy)] + _stop[static_cast<std::size_t>(_excNy)]);
    iStart[static_cast<std::size_t>(_excNy)] = mid;
    iStop[static_cast<std::size_t>(_excNy)] = mid;
    CSPropProbeBox* iProbe = addProbe(_csx, _iFilenames[0], 1, direction, _excNy);
    addBox(*iProbe, iStart, iStop);
}

std::expected<void, std::string> PassiveProbe::calcPort(const std::filesystem::path& simPath,
                                                          const std::vector<double>& freq, std::optional<double>,
                                                          const std::string& signalType) {
    // Deliberately does not call Port::calcPort() -- there's no characteristic impedance to
    // decompose against (see this class's own doc comment). readUiData() alone is enough to
    // populate ufTot()/ifTot(), which is all a passive probe's data ever consists of.
    return readUiData(simPath, freq, signalType);
}

MSLPort::MSLPort(ContinuousStructure& csx, std::int32_t portNr, Point3 start, Point3 stop,
                  const std::string& propDir, const std::string& excDir, double excite, double feedR,
                  std::int32_t priority, std::string portNamePrefix, double delay)
    : Port(csx, portNr, start, stop, excite, priority, std::move(portNamePrefix), delay),
      _excNy(axisIndex(excDir)),
      _propNy(axisIndex(propDir)) {
    const auto excNy = static_cast<std::size_t>(_excNy);
    const auto propNy = static_cast<std::size_t>(_propNy);
    const auto widthNy = static_cast<std::size_t>(3 - _excNy - _propNy);
    const double direction = (_stop[propNy] - _start[propNy]) < 0 ? -1.0 : 1.0;
    const double upsideDown = (_stop[excNy] - _start[excNy]) < 0 ? -1.0 : 1.0;

    if (_start[0] == _stop[0] || _start[1] == _stop[1] || _start[2] == _stop[2]) {
        throw std::runtime_error("Start coordinate must not be equal to stop coordinate");
    }
    if (_excNy == _propNy) {
        throw std::runtime_error("Excitation direction must not be equal to propagation direction");
    }

    const double measplaneShiftInit = 0.5 * std::abs(_start[propNy] - _stop[propNy]);
    const double measplanePos = _start[propNy] + measplaneShiftInit * direction;
    const double feedShift = 0;

    CSRectGrid* mesh = _csx.GetGrid();
    const std::vector<double> propLines = gridLines(*mesh, _propNy, true);
    const std::vector<double> widthLines = gridLines(*mesh, static_cast<std::int32_t>(widthNy), true);
    const std::vector<double> heightLines = gridLines(*mesh, _excNy, true);
    if (propLines.size() <= 5) {
        throw std::runtime_error("At least 5 lines in propagation direction required!");
    }
    if (widthLines.size() < 2 || heightLines.size() < 5) {
        throw std::runtime_error("MSLPort: insufficient mesh lines around the trace cross-section");
    }
    std::int64_t measPosIdx = static_cast<std::int64_t>(_argminAbsDiff(propLines, measplanePos));
    if (measPosIdx == 0) {
        measPosIdx = 1;
    }
    if (measPosIdx >= static_cast<std::int64_t>(propLines.size()) - 1) {
        measPosIdx = static_cast<std::int64_t>(propLines.size()) - 2;
    }

    std::array<std::int64_t, 3> propeIdx = {measPosIdx - 1, measPosIdx, measPosIdx + 1};
    if (direction < 0) {
        std::reverse(propeIdx.begin(), propeIdx.end());
    }
    std::array<double, 3> uPropePos{};
    for (std::size_t n = 0; n < 3; ++n) {
        uPropePos[n] = propLines[static_cast<std::size_t>(propeIdx[n])];
    }

    _uDelta = {uPropePos[1] - uPropePos[0], uPropePos[2] - uPropePos[1]};
    // Match AddMSLPort.m: voltage is sampled on the transverse E-grid line nearest the centre of
    // the strip. Leaving this at an arbitrary geometric coordinate works only when that coordinate
    // happens to survive mesh smoothing unchanged.
    const double widthCentre = 0.5 * (_start[widthNy] + _stop[widthNy]);
    const double voltageProbeWidth = widthLines[_argminAbsDiff(widthLines, widthCentre)];
    const std::array<std::string, 3> suffix = {"A", "B", "C"};
    for (std::size_t n = 0; n < 3; ++n) {
        Point3 uStart = {0.5 * (_start[0] + _stop[0]), 0.5 * (_start[1] + _stop[1]), 0.5 * (_start[2] + _stop[2])};
        Point3 uStop = uStart;
        uStart[propNy] = uPropePos[n];
        uStop[propNy] = uPropePos[n];
        uStart[widthNy] = voltageProbeWidth;
        uStop[widthNy] = voltageProbeWidth;
        uStart[excNy] = _start[excNy];
        uStop[excNy] = _stop[excNy];
        const std::string uName = _label("ut") + suffix[n];
        _uFilenames.push_back(uName);
        CSPropProbeBox* uProbe = addProbe(_csx, uName, 0);
        addBox(*uProbe, uStart, uStop);
    }

    const std::array<double, 2> iPropePos = {uPropePos[0] + _uDelta[0] / 2.0, uPropePos[1] + _uDelta[1] / 2.0};
    _iDelta = iPropePos[1] - iPropePos[0];

    // A current probe measures the closed H-field contour around the strip; it must surround the
    // conductor, not collapse onto the conductor's own plane. This is the mesh-aware placement
    // used by the reference MATLAB AddMSLPort implementation. The older Python port simply made
    // both height coordinates equal to start[excNy], which can omit most of the contour on a
    // smoothed/nonuniform Yee grid and substantially under-report current (therefore over-reporting
    // characteristic impedance).
    const double widthMin = std::min(_start[widthNy], _stop[widthNy]);
    const double widthMax = std::max(_start[widthNy], _stop[widthNy]);
    const std::size_t widthMinIdx = _argminAbsDiff(widthLines, widthMin);
    const std::size_t widthMaxIdx = _argminAbsDiff(widthLines, widthMax);
    const std::size_t traceHeightIdx = _argminAbsDiff(heightLines, _start[excNy]);
    if (widthMinIdx == 0 || widthMaxIdx + 1 >= widthLines.size() || traceHeightIdx < 2 ||
        traceHeightIdx + 2 >= heightLines.size()) {
        throw std::runtime_error("MSLPort: trace is too close to a mesh boundary for current-probe placement");
    }

    Point3 iStart = {std::min(_start[0], _stop[0]), std::min(_start[1], _stop[1]),
                     std::min(_start[2], _stop[2])};
    Point3 iStop = {std::max(_start[0], _stop[0]), std::max(_start[1], _stop[1]),
                    std::max(_start[2], _stop[2])};
    iStart[widthNy] = 0.5 * (widthLines[widthMinIdx - 1] + widthLines[widthMinIdx]);
    iStop[widthNy] = 0.5 * (widthLines[widthMaxIdx] + widthLines[widthMaxIdx + 1]);
    iStart[excNy] = 0.5 * (heightLines[traceHeightIdx - 2] + heightLines[traceHeightIdx - 1]);
    iStop[excNy] = 0.5 * (heightLines[traceHeightIdx + 1] + heightLines[traceHeightIdx + 2]);
    for (std::size_t n = 0; n < 2; ++n) {
        iStart[propNy] = iPropePos[n];
        iStop[propNy] = iPropePos[n];
        const std::string iName = _label("it") + suffix[n];
        _iFilenames.push_back(iName);
        CSPropProbeBox* iProbe = addProbe(_csx, iName, 1, direction, _propNy);
        addBox(*iProbe, iStart, iStop);
    }

    if (_excite != 0) {
        const std::size_t excitePosIdx = _argminAbsDiff(propLines, _start[propNy] + feedShift * direction);
        Point3 excStart = _start;
        Point3 excStop = _stop;
        excStart[propNy] = propLines[excitePosIdx];
        excStop[propNy] = propLines[excitePosIdx];
        Point3 excVec{0, 0, 0};
        excVec[excNy] = -1 * upsideDown * _excite;
        CSPropExcitation* exc = addExcitation(_csx, _label("excite"), 0, excVec, _delay);
        addBox(*exc, excStart, excStop, _priority);
    }

    if (feedR >= 0 && !std::isinf(feedR)) {
        Point3 rStart = _start;
        Point3 rStop = _stop;
        rStop[propNy] = rStart[propNy];
        if (feedR == 0) {
            CSPropMetal* feed = addMetal(_csx, _label("resist"));
            addBox(*feed, rStart, rStop);
        } else {
            CSPropLumpedElement* lumpedR = addLumpedElement(_csx, _label("resist"), _excNy, true, feedR);
            addBox(*lumpedR, rStart, rStop);
        }
    }
}

std::expected<void, std::string> MSLPort::readUiData(const std::filesystem::path& simPath,
                                                       const std::vector<double>& freq,
                                                       const std::string& signalType) {
    auto uData = UIData::load(_uFilenames, simPath, freq, signalType);
    if (!uData) return std::unexpected(std::move(uData).error());
    _ufTot = uData->freqValue()[1];

    auto iData = UIData::load(_iFilenames, simPath, freq, signalType);
    if (!iData) return std::unexpected(std::move(iData).error());
    _ifTot.resize(freq.size());
    for (std::size_t i = 0; i < freq.size(); ++i) {
        _ifTot[i] = 0.5 * (iData->freqValue()[0][i] + iData->freqValue()[1][i]);
    }

    const double unit = _csx.GetGrid()->GetDeltaUnit();
    const std::vector<std::complex<double>>& et = uData->freqValue()[1];
    const double uDeltaAbsSum = std::abs(_uDelta[0]) + std::abs(_uDelta[1]);

    _zRef.resize(freq.size());
    for (std::size_t i = 0; i < freq.size(); ++i) {
        const std::complex<double> det = (uData->freqValue()[2][i] - uData->freqValue()[0][i]) / (uDeltaAbsSum * unit);
        const std::complex<double> ht = _ifTot[i]; // space averaging: Ht is defined at the same pos as Et
        const std::complex<double> dht =
            (iData->freqValue()[1][i] - iData->freqValue()[0][i]) / (std::abs(_iDelta) * unit);

        // NOTE: the Python source also computes `beta` here (a propagation constant) and stores it
        // as `self.beta`, but that's only ever read back for CalcPort's ref_plane_shift handling,
        // which kiems never exercises (see the Port class doc comment) -- omitted as dead code.
        _zRef[i] = std::sqrt(et[i] * det / (ht * dht));
    }
    return {};
}

} // namespace kiems
