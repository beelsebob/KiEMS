#include "ports.hpp"

#include <algorithm>
#include <array>
#include <cmath>
#include <fstream>
#include <limits>
#include <sstream>
#include <stdexcept>

#include "csx_grid_utils.hpp"

namespace gerber2ems {

namespace {

std::pair<std::vector<double>, std::vector<double>> _loadUiFile(const std::filesystem::path& path) {
    std::ifstream file(path);
    if (!file.is_open()) {
        throw std::runtime_error("Failed to open probe file: " + path.string());
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
    return {time, value};
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

} // namespace

std::vector<std::complex<double>> dftTimeToFreq(const std::vector<double>& t, const std::vector<double>& val,
                                                 const std::vector<double>& freq, const std::string& signalType) {
    std::vector<std::complex<double>> fVal(freq.size(), std::complex<double>(0, 0));
    for (std::size_t nF = 0; nF < freq.size(); ++nF) {
        std::complex<double> sum(0, 0);
        for (std::size_t n = 0; n < t.size(); ++n) {
            sum += val[n] * std::exp(std::complex<double>(0, -2 * M_PI * freq[nF] * t[n]));
        }
        fVal[nF] = sum;
    }
    if (signalType == "pulse") {
        const double dt = t.size() > 1 ? t[1] - t[0] : 0;
        for (auto& v : fVal) {
            v *= dt;
        }
    } else if (signalType == "periodic") {
        const double n = static_cast<double>(t.size());
        for (auto& v : fVal) {
            v /= n;
        }
    } else {
        throw std::runtime_error("Unknown signal type: " + signalType);
    }
    for (auto& v : fVal) {
        v *= 2.0;
    }
    return fVal;
}

UIData::UIData(const std::vector<std::string>& filenames, const std::filesystem::path& path,
               const std::vector<double>& freq, const std::string& signalType) {
    for (const auto& fn : filenames) {
        auto [time, value] = _loadUiFile(path / fn);
        _freqValue.push_back(dftTimeToFreq(time, value, freq, signalType));
        _time.push_back(std::move(time));
        _value.push_back(std::move(value));
    }
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

void Port::readUiData(const std::filesystem::path& simPath, const std::vector<double>& freq,
                       const std::string& signalType) {
    const UIData uData(_uFilenames, simPath, freq, signalType);
    _ufTot.assign(freq.size(), std::complex<double>(0, 0));
    for (const auto& fv : uData.freqValue()) {
        for (std::size_t i = 0; i < freq.size(); ++i) {
            _ufTot[i] += fv[i];
        }
    }

    const UIData iData(_iFilenames, simPath, freq, signalType);
    _ifTot.assign(freq.size(), std::complex<double>(0, 0));
    for (const auto& fv : iData.freqValue()) {
        for (std::size_t i = 0; i < freq.size(); ++i) {
            _ifTot[i] += fv[i];
        }
    }
}

void Port::calcPort(const std::filesystem::path& simPath, const std::vector<double>& freq,
                     std::optional<double> refImpedance, const std::string& signalType) {
    readUiData(simPath, freq, signalType);
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

void LumpedPort::calcPort(const std::filesystem::path& simPath, const std::vector<double>& freq,
                           std::optional<double> refImpedance, const std::string& signalType) {
    if (!refImpedance.has_value()) {
        refImpedance = _resistance;
    }
    Port::calcPort(simPath, freq, refImpedance, signalType);
}

MSLPort::MSLPort(ContinuousStructure& csx, std::int32_t portNr, CSProperties& metalProp, Point3 start, Point3 stop,
                  const std::string& propDir, const std::string& excDir, double excite, double feedR,
                  std::int32_t priority, std::string portNamePrefix, double delay)
    : Port(csx, portNr, start, stop, excite, priority, std::move(portNamePrefix), delay),
      _excNy(axisIndex(excDir)),
      _propNy(axisIndex(propDir)) {
    const auto excNy = static_cast<std::size_t>(_excNy);
    const auto propNy = static_cast<std::size_t>(_propNy);
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

    Point3 mslStart = _start;
    Point3 mslStop = _stop;
    mslStop[excNy] = mslStart[excNy];
    addBox(metalProp, mslStart, mslStop, _priority);

    CSRectGrid* mesh = _csx.GetGrid();
    const std::vector<double> propLines = gridLines(*mesh, _propNy, true);
    if (propLines.size() <= 5) {
        throw std::runtime_error("At least 5 lines in propagation direction required!");
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
    const std::array<std::string, 3> suffix = {"A", "B", "C"};
    for (std::size_t n = 0; n < 3; ++n) {
        Point3 uStart = {0.5 * (_start[0] + _stop[0]), 0.5 * (_start[1] + _stop[1]), 0.5 * (_start[2] + _stop[2])};
        Point3 uStop = uStart;
        uStart[propNy] = uPropePos[n];
        uStop[propNy] = uPropePos[n];
        uStart[excNy] = _start[excNy];
        uStop[excNy] = _stop[excNy];
        const std::string uName = _label("ut") + suffix[n];
        _uFilenames.push_back(uName);
        CSPropProbeBox* uProbe = addProbe(_csx, uName, 0);
        addBox(*uProbe, uStart, uStop);
    }

    const std::array<double, 2> iPropePos = {uPropePos[0] + _uDelta[0] / 2.0, uPropePos[1] + _uDelta[1] / 2.0};
    _iDelta = iPropePos[1] - iPropePos[0];
    Point3 iStart = _start;
    Point3 iStop = _stop;
    iStop[excNy] = _start[excNy];
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
            addBox(metalProp, rStart, rStop);
        } else {
            CSPropLumpedElement* lumpedR = addLumpedElement(_csx, _label("resist"), _excNy, true, feedR);
            addBox(*lumpedR, rStart, rStop);
        }
    }
}

void MSLPort::readUiData(const std::filesystem::path& simPath, const std::vector<double>& freq,
                          const std::string& signalType) {
    const UIData uData(_uFilenames, simPath, freq, signalType);
    _ufTot = uData.freqValue()[1];

    const UIData iData(_iFilenames, simPath, freq, signalType);
    _ifTot.resize(freq.size());
    for (std::size_t i = 0; i < freq.size(); ++i) {
        _ifTot[i] = 0.5 * (iData.freqValue()[0][i] + iData.freqValue()[1][i]);
    }

    const double unit = _csx.GetGrid()->GetDeltaUnit();
    const std::vector<std::complex<double>>& et = uData.freqValue()[1];
    const double uDeltaAbsSum = std::abs(_uDelta[0]) + std::abs(_uDelta[1]);

    _zRef.resize(freq.size());
    for (std::size_t i = 0; i < freq.size(); ++i) {
        const std::complex<double> det = (uData.freqValue()[2][i] - uData.freqValue()[0][i]) / (uDeltaAbsSum * unit);
        const std::complex<double> ht = _ifTot[i]; // space averaging: Ht is defined at the same pos as Et
        const std::complex<double> dht = (iData.freqValue()[1][i] - iData.freqValue()[0][i]) / (std::abs(_iDelta) * unit);

        // NOTE: the Python source also computes `beta` here (a propagation constant) and stores it
        // as `self.beta`, but that's only ever read back for CalcPort's ref_plane_shift handling,
        // which gerber2ems never exercises (see the Port class doc comment) -- omitted as dead code.
        _zRef[i] = std::sqrt(et[i] * det / (ht * dht));
    }
}

} // namespace gerber2ems
