// Port abstractions (MSLPort, LumpedPort) and S-parameter extraction. Ported from the *Python*
// openEMS package's ports.py/utilities.py -- these classes are NOT part of the compiled
// libopenEMS/libCSXCAD C++ libraries; they're a convenience layer that builds ports out of raw
// CSXCAD primitives (lumped terminations, probes, excitations) and post-processes the resulting probe
// files. Only the subset gerber2ems actually exercises is ported: the shared Port base, LumpedPort
// and MSLPort (waveguide/coaxial/stripline/CPW/curve port types are not used by gerber2ems and are
// omitted).
#pragma once

#include <complex>
#include <cstdint>
#include <expected>
#include <filesystem>
#include <optional>
#include <string>
#include <vector>

#include <CSXCAD/ContinuousStructure.h>

#include "csx_helpers.hpp"

namespace gerber2ems {

/// Direct (Goertzel-style) DFT of a time-domain signal at a set of frequencies.
std::expected<std::vector<std::complex<double>>, std::string> dftTimeToFreq(
    const std::vector<double>& t, const std::vector<double>& val, const std::vector<double>& freq,
    const std::string& signalType = "pulse");

/// Loaded & DFT'd data for one or more openEMS voltage/current probe files.
class UIData {
public:
    /// A constructor can't report failure, so loading happens behind this factory instead.
    static std::expected<UIData, std::string> load(const std::vector<std::string>& filenames,
                                                     const std::filesystem::path& path, const std::vector<double>& freq,
                                                     const std::string& signalType = "pulse");

    const std::vector<std::vector<double>>& time() const { return _time; }
    const std::vector<std::vector<double>>& value() const { return _value; }
    const std::vector<std::vector<std::complex<double>>>& freqValue() const { return _freqValue; }

private:
    UIData() = default;

    std::vector<std::vector<double>> _time;
    std::vector<std::vector<double>> _value;
    std::vector<std::vector<std::complex<double>>> _freqValue;
};

/// Port base class.
///
/// NOTE: the Python source's ref_plane_shift handling (CalcPort's `ref_plane_shift` parameter) is
/// omitted -- gerber2ems never calls CalcPort with it set, so that branch is dead code for this
/// application. Likewise the scalar (SetEnabled) port_props bookkeeping is omitted since
/// gerber2ems never reads it back. Only uf_inc/uf_ref (what get_port_parameters() actually reads)
/// are computed; the Python source's additional ut_inc/it_inc/P_inc/P_ref/P_acc bookkeeping is
/// likewise unused by gerber2ems and omitted.
class Port {
public:
    Port(ContinuousStructure& csx, std::int32_t portNr, Point3 start, Point3 stop, double excite,
         std::int32_t priority = 0, std::string portNamePrefix = "", double delay = 0);
    virtual ~Port() = default;

    std::int32_t number() const { return _number; }

    virtual std::expected<void, std::string> readUiData(const std::filesystem::path& simPath,
                                                          const std::vector<double>& freq,
                                                          const std::string& signalType = "pulse");

    /// Computes uf_inc/uf_ref (incident/reflected wave phasors vs. frequency) from probe data.
    virtual std::expected<void, std::string> calcPort(const std::filesystem::path& simPath,
                                                        const std::vector<double>& freq,
                                                        std::optional<double> refImpedance = std::nullopt,
                                                        const std::string& signalType = "pulse");

    const std::vector<std::complex<double>>& ufInc() const { return _ufInc; }
    const std::vector<std::complex<double>>& ufRef() const { return _ufRef; }
    /// Raw, undecomposed total voltage/current vs. frequency -- what readUiData() alone computes,
    /// before calcPort()'s impedance-based incident/reflected split. Always populated once
    /// readUiData()/calcPort() has run; the only data PassiveProbe (a port with no real
    /// characteristic impedance to decompose against) ever produces.
    const std::vector<std::complex<double>>& ufTot() const { return _ufTot; }
    const std::vector<std::complex<double>>& ifTot() const { return _ifTot; }
    /// Per-frequency reference/characteristic impedance -- for a plain Port/PassiveProbe/LumpedPort
    /// this is only ever a flat refImpedance (or empty, if calcPort()/readUiData() was never called
    /// with one), but MSLPort::readUiData() populates it with a genuine local characteristic
    /// impedance derived from its own 3-plane E/H measurement (see that override's own doc comment)
    /// -- what Simulation::addImpedanceProbe()'s non-loading MSLPort-based probes exist to read.
    const std::vector<std::complex<double>>& zRef() const { return _zRef; }

protected:
    std::string _label(const std::string& tag) const { return _prefix + "port_" + tag + "_" + std::to_string(_number); }

    ContinuousStructure& _csx;
    std::int32_t _number;
    double _excite;
    Point3 _start;
    Point3 _stop;
    std::int32_t _priority;
    std::string _prefix;
    double _delay;

    std::vector<std::complex<double>> _zRef; // per-frequency reference impedance

    std::vector<std::string> _uFilenames;
    std::vector<std::string> _iFilenames;

    std::vector<std::complex<double>> _ufTot;
    std::vector<std::complex<double>> _ifTot;

private:
    std::vector<std::complex<double>> _ufInc;
    std::vector<std::complex<double>> _ifInc;
    std::vector<std::complex<double>> _ufRef;
    std::vector<std::complex<double>> _ifRef;
};

/// A lumped (resistive) port.
class LumpedPort : public Port {
public:
    LumpedPort(ContinuousStructure& csx, std::int32_t portNr, double resistance, Point3 start, Point3 stop,
               const std::string& excDir, double excite = 0, std::int32_t priority = 0,
               std::string portNamePrefix = "", double delay = 0);

    std::expected<void, std::string> calcPort(const std::filesystem::path& simPath, const std::vector<double>& freq,
                                               std::optional<double> refImpedance = std::nullopt,
                                               const std::string& signalType = "pulse") override;

private:
    double _resistance;
    std::int32_t _excNy;
};

/// A purely passive, non-loading probe -- U/I probe boxes only, no metal trace, no feed resistor,
/// no excitation. Reads a location's own voltage/current without adding any physical structure that
/// could affect the simulated fields (unlike LumpedPort/MSLPort, which always terminate/absorb the
/// line they sit on). See PortConfig::absorbSignal()'s own doc comment -- this is what
/// Simulation::addPassiveProbe() builds for a PortConfig with absorbSignal()==false.
///
/// Never excited (excite is always 0) and calcPort() is a deliberate no-op beyond readUiData(): a
/// passive probe has no characteristic impedance to decompose ufTot/ifTot into incident/reflected
/// waves against, so ufInc()/ufRef() stay empty -- callers needing this port's data must use
/// ufTot()/ifTot() instead (see Postprocessor::addProbeData(), which is fed from those, never from
/// ufInc()/ufRef()).
class PassiveProbe : public Port {
public:
    PassiveProbe(ContinuousStructure& csx, std::int32_t portNr, Point3 start, Point3 stop, const std::string& excDir,
                 std::int32_t priority = 0, std::string portNamePrefix = "");

    std::expected<void, std::string> calcPort(const std::filesystem::path& simPath, const std::vector<double>& freq,
                                               std::optional<double> refImpedance = std::nullopt,
                                               const std::string& signalType = "pulse") override;

private:
    std::int32_t _excNy;
};

/// A microstrip transmission line port placed on existing imported trace copper. The start/stop
/// box defines its excitation, termination and measurement cross-sections; it deliberately does not
/// manufacture a straight metal strip between them, since a PCB trace may bend or pass close to an
/// unrelated conductor inside that interval.
class MSLPort : public Port {
public:
    MSLPort(ContinuousStructure& csx, std::int32_t portNr, Point3 start, Point3 stop, const std::string& propDir,
            const std::string& excDir, double excite = 0, double feedR = 50, std::int32_t priority = 0,
            std::string portNamePrefix = "", double delay = 0);

    std::expected<void, std::string> readUiData(const std::filesystem::path& simPath, const std::vector<double>& freq,
                                                 const std::string& signalType = "pulse") override;

private:
    std::int32_t _excNy;
    std::int32_t _propNy;
    std::array<double, 2> _uDelta{};
    double _iDelta = 0;
};

} // namespace gerber2ems
