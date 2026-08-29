// Configuration parsing. Ported from gerber2ems/config.py.
#pragma once

#include <algorithm>
#include <cstdint>
#include <expected>
#include <filesystem>
#include <limits>
#include <optional>
#include <string>
#include <utility>
#include <vector>

#include <nlohmann/json.hpp>

namespace gerber2ems {

/// Which FDTD engine actually runs the per-port simulation -- see Simulation::run(), which
/// posix_spawns paths.fdtdWorkerPath or paths.copperFdtdWorkerPath depending on this.
enum class FDTDBackend { OpenEMSCPU, CopperGPU };

/// Which PML formulation the GPU backend's boundary uses -- only meaningful when `backend` is
/// CopperGPU (the CPU backend always uses openEMS's own UPML, unmodified). Plain UPML can diverge
/// numerically on very long runs (confirmed: stable through ~250,000 timesteps, then exponential
/// blowup by step ~740,000 on a real board) -- a well-documented FDTD phenomenon ("late-time PML
/// instability"), not a bug specific to this codebase's own GPU port. CPML fixes it structurally,
/// and is this codebase's own default (validated on the exact real-board scenario that exposed
/// UPML's own failure: same board, same 1,000,000-timestep run, CPML showed no divergence at all --
/// see copper::CopperBoundaryKind's own doc comment). UPML stays available (openEMS's own formula,
/// untouched) for comparison/fallback. This enum stays libgerber2ems-native (no Copper dependency,
/// matching `FDTDBackend`'s own convention) -- translated to `copper::CopperBoundaryKind` only at
/// the call sites that already link Copper (geber2ems/main.cpp, Gerber2EMSStudio's
/// EMSSimulationPipelineBridge.mm).
enum class PMLKind { UPML, CPML };

/// Command line arguments. Ported from the argparse::Namespace fields used by config.py/main.py.
/// Populated incrementally by the (not yet ported) command-line parser, hence the public setters.
class Arguments {
public:
    const std::optional<std::string>& configPath() const { return _configPath; }
    void setConfigPath(std::optional<std::string> value) { _configPath = std::move(value); }

    bool updateConfig() const { return _updateConfig; }
    void setUpdateConfig(bool value) { _updateConfig = value; }

    bool geometry() const { return _geometry; }
    void setGeometry(bool value) { _geometry = value; }

    bool simulate() const { return _simulate; }
    void setSimulate(bool value) { _simulate = value; }

    bool postprocess() const { return _postprocess; }
    void setPostprocess(bool value) { _postprocess = value; }

    bool all() const { return _all; }
    void setAll(bool value) { _all = value; }

    const std::optional<std::vector<std::string>>& exportField() const { return _exportField; }
    void setExportField(std::optional<std::vector<std::string>> value) { _exportField = std::move(value); }

    std::int32_t oversampling() const { return _oversampling; }
    void setOversampling(std::int32_t value) { _oversampling = value; }

    bool transparent() const { return _transparent; }
    void setTransparent(bool value) { _transparent = value; }

    bool plotPhase() const { return _plotPhase; }
    void setPlotPhase(bool value) { _plotPhase = value; }

    const std::filesystem::path& input() const { return _input; }
    void setInput(std::filesystem::path value) { _input = std::move(value); }

    const std::filesystem::path& output() const { return _output; }
    void setOutput(std::filesystem::path value) { _output = std::move(value); }

    bool debug() const { return _debug; }
    void setDebug(bool value) { _debug = value; }

    const std::optional<std::string>& logLevel() const { return _logLevel; }
    void setLogLevel(std::optional<std::string> value) { _logLevel = std::move(value); }

    FDTDBackend backend() const { return _backend; }
    void setBackend(FDTDBackend value) { _backend = value; }

    PMLKind pmlKind() const { return _pmlKind; }
    void setPmlKind(PMLKind value) { _pmlKind = value; }

private:
    std::optional<std::string> _configPath;
    bool _updateConfig = false;
    bool _geometry = false;
    bool _simulate = false;
    bool _postprocess = false;
    bool _all = false;
    std::optional<std::vector<std::string>> _exportField; // nullopt == not requested
    std::int32_t _oversampling = 4;
    bool _transparent = false;
    bool _plotPhase = false;
    std::filesystem::path _input;
    std::filesystem::path _output;
    bool _debug = false;
    std::optional<std::string> _logLevel;
    FDTDBackend _backend = FDTDBackend::OpenEMSCPU;
    PMLKind _pmlKind = PMLKind::CPML;
};

/// Class representing a single simulation port. Never (de)serialized directly -- populated by
/// port_resolution.cpp from a SimulationConfig's InvolvedNetConfig entries, one instance per pad
/// on each resolved net.
class PortConfig {
public:
    const std::string& name() const { return _name; }
    void setName(std::string value) { _name = std::move(value); }

    // Identity of the real board pad this port sits on -- used by port_resolution.cpp to match an
    // ExcitationConfig/PortRef's footprint+pin selector back to a resolved port index, without
    // parsing it out of name() (which is a display string, not a stable key).
    const std::string& footprintRef() const { return _footprintRef; }
    void setFootprintRef(std::string value) { _footprintRef = std::move(value); }

    const std::string& padNumber() const { return _padNumber; }
    void setPadNumber(std::string value) { _padNumber = std::move(value); }

    const std::optional<std::pair<double, double>>& position() const { return _position; }
    void setPosition(std::pair<double, double> value) { _position = value; }

    const std::optional<double>& direction() const { return _direction; }
    void setDirection(double value) { _direction = value; }

    double width() const { return _width; }
    void setWidth(double value) { _width = value; }

    double length() const { return _length; }
    void setLength(double value) { _length = value; }

    double impedance() const { return _impedance; }
    void setImpedance(double value) { _impedance = value; }

    std::int32_t layer() const { return _layer; }
    void setLayer(std::int32_t value) { _layer = value; }

    std::int32_t plane() const { return _plane; }
    void setPlane(std::int32_t value) { _plane = value; }

    double dBMargin() const { return _dBMargin; }
    void setDBMargin(double value) { _dBMargin = value; }

    bool excite() const { return _excite; }
    void setExcite(bool value) { _excite = value; }

    /// Whether this port physically loads/terminates the line it sits on -- true (the historical,
    /// still-default behavior) means a real metal trace + impedance-matched feed resistor gets
    /// built (Simulation::addMslPort()); false means only U/I probe boxes get placed
    /// (Simulation::addPassiveProbe()), a purely passive read point with zero effect on the
    /// simulated fields. excite() always implies the full absorbing structure regardless of this
    /// flag's own value -- see port_resolution.cpp's resolution rule, which never lets an excited
    /// pad end up with absorbSignal()==false.
    bool absorbSignal() const { return _absorbSignal; }
    void setAbsorbSignal(bool value) { _absorbSignal = value; }

    /// Scales width/length into simulation units (mirrors the `*= UNIT_MULTIPLIER` done in
    /// Config.load).
    void scaleToSimulationUnits(std::int32_t unitMultiplier);

private:
    std::string _name = "Unnamed";
    std::string _footprintRef;
    std::string _padNumber;
    std::optional<std::pair<double, double>> _position;
    std::optional<double> _direction;
    double _width = 200;
    double _length = 1000;
    double _impedance = 50;
    std::int32_t _layer = 0;
    std::int32_t _plane = 1;
    double _dBMargin = -15;
    bool _excite = false;
    bool _absorbSignal = true;
};

/// Which of a LumpedComponentConfig's R/L/C fields are physically present -- mirrors how
/// CSPropLumpedElement/Operator_Ext_LumpedRLC themselves distinguish "absent" (NaN) from "present,
/// value zero" (see operator_ext_lumpedRLC.cpp's own doc comment on this), just narrowed to the
/// three single-quantity component kinds resolveSimulationPorts() ever auto-discovers.
enum class LumpedComponentType { Resistor, Inductor, Capacitor };

/// One auto-discovered 2-pin R/L/C component, resolved to real board geometry -- populated
/// entirely by resolveSimulationPorts() (never (de)serialized, same as PortConfig; see
/// SimulationConfig::_lumpedComponents' own comment). A component only ever gets one of these if
/// both its pins sit on a net already involved in this simulation (or its ground net) -- see
/// port_resolution.cpp's own doc comment on the discovery rule.
class LumpedComponentConfig {
public:
    const std::string& reference() const { return _reference; }
    void setReference(std::string value) { _reference = std::move(value); }

    LumpedComponentType type() const { return _type; }
    void setType(LumpedComponentType value) { _type = value; }

    /// NaN means "not physically present" (this component isn't of that kind) -- matches
    /// CSPropLumpedElement's own NaN-means-absent convention exactly, so these are handed straight
    /// through to SetResistance()/SetInductance()/SetCapacity() unchanged.
    double resistance() const { return _resistance; }
    void setResistance(double value) { _resistance = value; }
    double inductance() const { return _inductance; }
    void setInductance(double value) { _inductance = value; }
    double capacitance() const { return _capacitance; }
    void setCapacitance(double value) { _capacitance = value; }

    /// Both pads' positions, already in simulation-frame coordinates (like PortConfig::position(),
    /// these come from board/gerber geometry, not a JSON field, so they're never scaled by
    /// scaleToSimulationUnits() -- only width() is).
    const std::pair<double, double>& position1() const { return _position1; }
    void setPosition1(std::pair<double, double> value) { _position1 = value; }
    const std::pair<double, double>& position2() const { return _position2; }
    void setPosition2(std::pair<double, double> value) { _position2 = value; }

    /// Cardinal degrees (0/90/180/270) from position1 towards position2 -- same convention as
    /// PortConfig::direction().
    double direction() const { return _direction; }
    void setDirection(double value) { _direction = value; }

    std::int32_t layer() const { return _layer; }
    void setLayer(std::int32_t value) { _layer = value; }

    /// Transverse box width, in file units until scaleToSimulationUnits() runs -- matches
    /// PortConfig::width()'s own default.
    double width() const { return _width; }
    void setWidth(double value) { _width = value; }

    void scaleToSimulationUnits(std::int32_t unitMultiplier) { _width *= unitMultiplier; }

private:
    std::string _reference;
    LumpedComponentType _type = LumpedComponentType::Resistor;
    double _resistance = std::numeric_limits<double>::quiet_NaN();
    double _inductance = std::numeric_limits<double>::quiet_NaN();
    double _capacitance = std::numeric_limits<double>::quiet_NaN();
    std::pair<double, double> _position1;
    std::pair<double, double> _position2;
    double _direction = 0;
    std::int32_t _layer = 0;
    double _width = 200;
};

/// Identifies a port by the footprint+pin selector it was placed on -- the same, human-writable
/// way any other part of this config names a specific pin (ExcitationConfig, an InvolvedNetConfig
/// footprint-pin entry). Resolved to a concrete index into a SimulationConfig's ports() once
/// during resolveSimulationPorts(), the same way ExcitationConfig's driven pin is.
class PortRef {
public:
    const std::string& footprint() const { return _footprint; }
    const std::string& pin() const { return _pin; }

    const std::optional<std::int32_t>& resolvedIndex() const { return _resolvedIndex; }
    void setResolvedIndex(std::int32_t index) { _resolvedIndex = index; }

private:
    friend void to_json(nlohmann::json& j, const PortRef& p);
    friend void from_json(const nlohmann::json& j, PortRef& p);

    std::string _footprint;
    std::string _pin;
    std::optional<std::int32_t> _resolvedIndex; // not (de)serialized
};

void to_json(nlohmann::json& j, const PortRef& p);
void from_json(const nlohmann::json& j, PortRef& p);

/// Which of InvolvedNetConfig's mutually-exclusive selector fields is populated.
enum class NetSelectorKind {
    NetClass,
    Net,
    FootprintPin,
};

/// One footprint+pin pair, identifying a single pad the way port_resolution.cpp's own PadIdentity
/// does (footprintRef/padNumber) -- but as plain, JSON-serializable strings, since this is a
/// config-file field, not a live board query result.
struct ExcludedPin {
    std::string footprint;
    std::string pin;

    bool operator==(const ExcludedPin& other) const { return footprint == other.footprint && pin == other.pin; }
};

void to_json(nlohmann::json& j, const ExcludedPin& p);
void from_json(const nlohmann::json& j, ExcludedPin& p);

/// One footprint+pin+absorb triple -- the opt-*in* per-pin selection the source list's "Probe"/
/// "Absorb Signal" checkboxes drive (see InvolvedNetConfig::probedPins()'s own doc comment for how
/// this coexists with the older, opt-*out* ExcludedPin list).
struct ProbedPin {
    std::string footprint;
    std::string pin;
    bool absorbSignal = true;

    bool operator==(const ProbedPin& other) const { return footprint == other.footprint && pin == other.pin; }
};

void to_json(nlohmann::json& j, const ProbedPin& p);
void from_json(const nlohmann::json& j, ProbedPin& p);

/// One footprint+pin+direction triple -- a per-pad override for the departure direction
/// port_resolution.cpp would otherwise apply uniformly to every pad on this entry's resolved
/// net(s) (see InvolvedNetConfig::direction()'s own doc comment for why a single net-wide value is
/// sometimes wrong: opposite ends of a routed net generally depart their own pads in different,
/// often opposite, cardinal directions, so no single value can be right for both). Checked before
/// the net-wide direction() override, which stays the fallback applied to every *other* pad on the
/// net that doesn't have one of these.
struct PinDirectionOverride {
    std::string footprint;
    std::string pin;
    double direction = 0;

    bool operator==(const PinDirectionOverride& other) const {
        return footprint == other.footprint && pin == other.pin;
    }
};

void to_json(nlohmann::json& j, const PinDirectionOverride& p);
void from_json(const nlohmann::json& j, PinDirectionOverride& p);

/// One entry in a SimulationConfig's involved-nets list. Resolves (via port_resolution.cpp and
/// libkicad) to a set of net names -- a net class expands to every net assigned to it; a
/// footprint+pin resolves to the net connected to that pin and is thereafter treated exactly like
/// naming that net directly.
///
/// Which pads on a resolved net actually get a PortConfig is governed by one of two mutually
/// exclusive modes, selected by hasExplicitPinSelections():
///  - Legacy (hasExplicitPinSelections()==false, the state of every entry that predates the
///    Probe/Absorb Signal/Excite source-list redesign): every pad gets a PortConfig
///    (absorbSignal()==true), *except* pads named in excludedPins() -- an opt-*out* blacklist.
///    This is what makes loading an old simulation.json a no-op: an entry nobody has touched under
///    the new per-pin UI keeps resolving exactly as it always did.
///  - Explicit (hasExplicitPinSelections()==true, set permanently the first time any pin under
///    this net is edited via the new UI): only pads named in probedPins() get a PortConfig (with
///    that entry's own absorbSignal), plus any pad targeted by a SimulationConfig-level
///    ExcitationConfig (which always gets absorbSignal()==true regardless of its probedPins()
///    entry, if any -- see port_resolution.cpp's resolution rule). excludedPins() is not consulted
///    in this mode.
/// See port_resolution.cpp's resolveSimulationPorts() for the exact rule, and
/// SourceListViewController's probeToggled()/absorbToggled()/excitedToggled() for how the GUI
/// drives it.
class InvolvedNetConfig {
public:
    NetSelectorKind kind() const { return _kind; }
    const std::optional<std::string>& netClass() const { return _netClass; }
    const std::optional<std::string>& net() const { return _net; }
    const std::optional<std::string>& footprint() const { return _footprint; }
    const std::vector<std::string>& pins() const { return _pins; }
    /// Only meaningful for a Net-kind entry, and only consulted when hasExplicitPinSelections() is
    /// false -- see this class's own doc comment.
    const std::vector<ExcludedPin>& excludedPins() const { return _excludedPins; }
    std::vector<ExcludedPin>& excludedPins() { return _excludedPins; }
    bool isPinExcluded(const std::string& footprint, const std::string& pin) const {
        return std::find(_excludedPins.begin(), _excludedPins.end(), ExcludedPin{footprint, pin}) !=
               _excludedPins.end();
    }

    /// True once this entry's pins have ever been edited via the new per-pin Probe/Excite UI --
    /// see this class's own doc comment for what that switches probedPins()/excludedPins()
    /// resolution to. Never set back to false.
    bool hasExplicitPinSelections() const { return _hasExplicitPinSelections; }
    /// Only meaningful for a Net-kind entry, and only consulted when hasExplicitPinSelections() is
    /// true -- see this class's own doc comment.
    const std::vector<ProbedPin>& probedPins() const { return _probedPins; }
    /// nullopt if `footprint`.`pin` isn't in probedPins() at all.
    std::optional<bool> probedPinAbsorbs(const std::string& footprint, const std::string& pin) const {
        const auto it = std::find_if(_probedPins.begin(), _probedPins.end(), [&](const ProbedPin& p) {
            return p.footprint == footprint && p.pin == pin;
        });
        return it != _probedPins.end() ? std::optional<bool>(it->absorbSignal) : std::nullopt;
    }
    /// Sets (`absorbSignal` has a value) or clears (nullopt) this one pad's probed state. Always
    /// sets hasExplicitPinSelections() true, even when clearing -- the act of editing a pin's Probe
    /// state at all is what commits this net to the new, explicit resolution mode (see this class's
    /// own doc comment); there's no way back to legacy mode once any pin has been touched.
    void setPinProbed(const std::string& footprint, const std::string& pin, std::optional<bool> absorbSignal) {
        _hasExplicitPinSelections = true;
        _probedPins.erase(std::remove_if(_probedPins.begin(), _probedPins.end(),
                                          [&](const ProbedPin& p) { return p.footprint == footprint && p.pin == pin; }),
                           _probedPins.end());
        if (absorbSignal.has_value()) {
            _probedPins.push_back({footprint, pin, *absorbSignal});
        }
    }

    double impedance() const { return _impedance; }
    double length() const { return _length; } // -> PortConfig::length()
    std::int32_t plane() const { return _plane; }
    const std::optional<double>& width() const { return _width; }
    const std::optional<double>& dBMargin() const { return _dBMargin; }
    const std::optional<double>& direction() const { return _direction; } // escape hatch, see port_resolution.cpp
    /// Only meaningful for a Net-kind entry, same as excludedPins() -- see PinDirectionOverride's
    /// own doc comment for why a single net-wide direction() sometimes isn't enough.
    const std::vector<PinDirectionOverride>& pinDirectionOverrides() const { return _pinDirectionOverrides; }
    std::vector<PinDirectionOverride>& pinDirectionOverrides() { return _pinDirectionOverrides; }
    std::optional<double> pinDirectionOverride(const std::string& footprint, const std::string& pin) const {
        const auto it = std::find_if(_pinDirectionOverrides.begin(), _pinDirectionOverrides.end(),
                                      [&](const PinDirectionOverride& o) {
                                          return o.footprint == footprint && o.pin == pin;
                                      });
        return it != _pinDirectionOverrides.end() ? std::optional<double>(it->direction) : std::nullopt;
    }
    /// Sets (or, given nullopt, clears) this one pad's own direction override -- never leaves more
    /// than one entry for the same (footprint, pin) pair.
    void setPinDirectionOverride(const std::string& footprint, const std::string& pin,
                                  std::optional<double> direction) {
        _pinDirectionOverrides.erase(
            std::remove_if(_pinDirectionOverrides.begin(), _pinDirectionOverrides.end(),
                            [&](const PinDirectionOverride& o) {
                                return o.footprint == footprint && o.pin == pin;
                            }),
            _pinDirectionOverrides.end());
        if (direction.has_value()) {
            _pinDirectionOverrides.push_back({footprint, pin, *direction});
        }
    }

    // impedance/length/width are intentionally left unscaled here: they're copied verbatim into a
    // resolved PortConfig by port_resolution.cpp, which scales the whole PortConfig exactly once
    // (PortConfig::scaleToSimulationUnits) -- scaling them here too would double-scale.

    void setKind(NetSelectorKind value) { _kind = value; }
    void setNetClass(std::optional<std::string> value) { _netClass = std::move(value); }
    void setNet(std::optional<std::string> value) { _net = std::move(value); }
    void setFootprint(std::optional<std::string> value) { _footprint = std::move(value); }
    std::vector<std::string>& pins() { return _pins; }

    void setImpedance(double value) { _impedance = value; }
    void setLength(double value) { _length = value; }
    void setPlane(std::int32_t value) { _plane = value; }
    void setWidth(std::optional<double> value) { _width = value; }
    void setDBMargin(std::optional<double> value) { _dBMargin = value; }
    void setDirection(std::optional<double> value) { _direction = value; }

private:
    friend void to_json(nlohmann::json& j, const InvolvedNetConfig& p);
    friend void from_json(const nlohmann::json& j, InvolvedNetConfig& p);

    NetSelectorKind _kind = NetSelectorKind::Net;
    std::optional<std::string> _netClass;
    std::optional<std::string> _net;
    std::optional<std::string> _footprint;
    std::vector<std::string> _pins;
    std::vector<ExcludedPin> _excludedPins;
    bool _hasExplicitPinSelections = false;
    std::vector<ProbedPin> _probedPins;
    double _impedance = 45;
    double _length = 1000;
    std::int32_t _plane = 1;
    std::optional<double> _width;
    std::optional<double> _dBMargin;
    std::optional<double> _direction;
    std::vector<PinDirectionOverride> _pinDirectionOverrides;
};

void to_json(nlohmann::json& j, const InvolvedNetConfig& p);
void from_json(const nlohmann::json& j, InvolvedNetConfig& p);

/// Which of GroundNetConfig's mutually-exclusive selector fields is populated.
enum class GroundSelectorKind {
    NetClass,
    Net,
};

/// Names the net (or net class) whose copper survives board slicing purely to give the sliced
/// nets something real to return current through -- never becomes a port or a signal of interest.
class GroundNetConfig {
public:
    GroundSelectorKind kind() const { return _kind; }
    const std::optional<std::string>& netClass() const { return _netClass; }
    const std::optional<std::string>& net() const { return _net; }

    void setKind(GroundSelectorKind value) { _kind = value; }
    void setNetClass(std::optional<std::string> value) { _netClass = std::move(value); }
    void setNet(std::optional<std::string> value) { _net = std::move(value); }

private:
    friend void to_json(nlohmann::json& j, const GroundNetConfig& p);
    friend void from_json(const nlohmann::json& j, GroundNetConfig& p);

    GroundSelectorKind _kind = GroundSelectorKind::Net;
    std::optional<std::string> _netClass;
    std::optional<std::string> _net;
};

void to_json(nlohmann::json& j, const GroundNetConfig& p);
void from_json(const nlohmann::json& j, GroundNetConfig& p);

/// One entry in a SimulationConfig's excitations list. Purely a postprocessing input (see
/// excitation_postprocess.hpp) -- it plays no role in which ports get excited during the actual
/// FDTD sweep (every involved-net port always does).
class ExcitationConfig {
public:
    double startTime() const { return _startTime; }
    double duration() const { return _duration; }
    bool isMain() const { return _isMain; }
    const std::optional<double>& frequency() const { return _frequency; } // required iff !isMain()
    const std::optional<double>& amplitude() const { return _amplitude; } // required iff !isMain()
    double phaseDegrees() const { return _phaseDegrees; }
    const std::string& footprint() const { return _footprint; }
    const std::string& pin() const { return _pin; }

    const std::optional<std::int32_t>& drivenPortIndex() const { return _drivenPortIndex; }
    void setDrivenPortIndex(std::int32_t index) { _drivenPortIndex = index; }

    void setStartTime(double value) { _startTime = value; }
    void setDuration(double value) { _duration = value; }
    void setIsMain(bool value) { _isMain = value; }
    void setFrequency(std::optional<double> value) { _frequency = value; }
    void setAmplitude(std::optional<double> value) { _amplitude = value; }
    void setPhaseDegrees(double value) { _phaseDegrees = value; }
    void setFootprint(std::string value) { _footprint = std::move(value); }
    void setPin(std::string value) { _pin = std::move(value); }

private:
    friend void to_json(nlohmann::json& j, const ExcitationConfig& p);
    friend void from_json(const nlohmann::json& j, ExcitationConfig& p);

    double _startTime = 0;
    double _duration = 0;
    bool _isMain = false;
    std::optional<double> _frequency;
    std::optional<double> _amplitude;
    double _phaseDegrees = 0;
    std::string _footprint;
    std::string _pin;
    std::optional<std::int32_t> _drivenPortIndex; // not (de)serialized
};

void to_json(nlohmann::json& j, const ExcitationConfig& p);
void from_json(const nlohmann::json& j, ExcitationConfig& p);

/// Class representing and parsing differential pair config, for postprocessing (mixed-mode
/// S-parameter / differential impedance) purposes. References ports by footprint+pin rather than
/// index, since one-port-per-pad makes hand-written indices unpredictable.
class DifferentialPairConfig {
public:
    const PortRef& startP() const { return _startP; }
    PortRef& startP() { return _startP; }
    const PortRef& stopP() const { return _stopP; }
    PortRef& stopP() { return _stopP; }
    const PortRef& startN() const { return _startN; }
    PortRef& startN() { return _startN; }
    const PortRef& stopN() const { return _stopN; }
    PortRef& stopN() { return _stopN; }
    const std::optional<std::string>& name() const { return _name; }
    bool correct() const { return _correct; }

    /// Validate that every PortRef resolved to a real port (mirrors __post_init__, now
    /// resolution-based instead of index-range-based).
    void postInit();

private:
    friend void to_json(nlohmann::json& j, const DifferentialPairConfig& p);
    friend void from_json(const nlohmann::json& j, DifferentialPairConfig& p);

    PortRef _startP;
    PortRef _stopP;
    PortRef _startN;
    PortRef _stopN;
    std::optional<std::string> _name;
    bool _correct = true; // not (de)serialized
};

void to_json(nlohmann::json& j, const DifferentialPairConfig& p);
void from_json(const nlohmann::json& j, DifferentialPairConfig& p);

/// Class representing and parsing single-ended trace config, for postprocessing (propagation
/// delay/insertion loss labeling) purposes. References ports by footprint+pin, see
/// DifferentialPairConfig.
class SingleEndedConfig {
public:
    const PortRef& start() const { return _start; }
    PortRef& start() { return _start; }
    const PortRef& stop() const { return _stop; }
    PortRef& stop() { return _stop; }
    const std::optional<std::string>& name() const { return _name; }
    bool correct() const { return _correct; }

    /// Validate that both PortRefs resolved to real ports (mirrors __post_init__, now
    /// resolution-based instead of index-range-based).
    void postInit();

private:
    friend void to_json(nlohmann::json& j, const SingleEndedConfig& p);
    friend void from_json(const nlohmann::json& j, SingleEndedConfig& p);

    PortRef _start;
    PortRef _stop;
    std::optional<std::string> _name;
    bool _correct = true; // not (de)serialized
};

void to_json(nlohmann::json& j, const SingleEndedConfig& p);
void from_json(const nlohmann::json& j, SingleEndedConfig& p);

enum class LayerKind {
    Substrate,
    Metal,
    SolderMaskTop,
    SolderMaskBottom,
};

/// One layer of a resolved board stackup (see libkicad_query::stackup()) -- copper, substrate, or
/// (top/bottom) solder mask, already scaled to simulation units.
class LayerConfig {
public:
    /// `thicknessMm` is scaled to simulation units internally; `epsilon`/`lossTangent` are ignored
    /// (left at 0) for `LayerKind::Metal`. For `LayerKind::Metal`, `file()` is derived from `name` by
    /// replacing '.' with '_' (matching how gerber2ems already names its own Gerber-derived layer
    /// files).
    LayerConfig(LayerKind kind, std::string name, double thicknessMm, double epsilon = 0, double lossTangent = 0);

    LayerKind kind() const { return _kind; }
    double thickness() const { return _thickness; }
    const std::string& name() const { return _name; }
    const std::string& file() const { return _file; }  // only meaningful when kind() == Metal
    // only meaningful when kind() == Substrate/SolderMaskTop/SolderMaskBottom
    double epsilon() const { return _epsilon; }
    double lossTangent() const { return _lossTangent; }

private:
    LayerKind _kind;
    double _thickness = 0;
    std::string _name;
    std::string _file;
    double _epsilon = 0;
    double _lossTangent = 0;
};

/// Frequency config.
class Frequency {
public:
    double start() const { return _start; }
    void setStart(double value) { _start = value; }
    double stop() const { return _stop; }
    void setStop(double value) { _stop = value; }

private:
    friend void to_json(nlohmann::json& j, const Frequency& f);
    friend void from_json(const nlohmann::json& j, Frequency& f);

    double _start = 1e6;
    double _stop = 6e9;
};

void to_json(nlohmann::json& j, const Frequency& f);
void from_json(const nlohmann::json& j, Frequency& f);

/// Via config.
class Via {
public:
    double platingThickness() const { return _platingThickness; }
    void setPlatingThickness(double value) { _platingThickness = value; }
    double fillingEpsilon() const { return _fillingEpsilon; }
    void setFillingEpsilon(double value) { _fillingEpsilon = value; }

    /// Geometry for the ground-net stitching vias board_slicing.cpp invents itself to close a
    /// cutout's newly-introduced edges (see StitchingVia's own doc comment) -- unlike a real board
    /// via, a stitching via has no separately-modeled copper pad on any layer (nothing in the
    /// original board ever put one there), so these double as both its electrical contact and its
    /// visible pad; platingThickness alone (a real via's actual copper-wall thickness, a few tens
    /// of microns) is far too small for that second job. Defaults: a 0.3mm drill in a 0.6mm pad,
    /// typical minimum via geometry.
    double stitchingViaHoleDiameter() const { return _stitchingViaHoleDiameter; }
    void setStitchingViaHoleDiameter(double value) { _stitchingViaHoleDiameter = value; }
    double stitchingViaAnnularRingDiameter() const { return _stitchingViaAnnularRingDiameter; }
    void setStitchingViaAnnularRingDiameter(double value) { _stitchingViaAnnularRingDiameter = value; }

    /// Minimum edge-to-edge (not center-to-center) gap board_slicing.cpp must leave between a
    /// candidate stitching via and *any* other via -- real or already-placed stitching, on any net
    /// -- purely to avoid an unmanufacturable/overlapping pair of holes. Independent of
    /// SimulationConfig::viaSpacing(), which is a much larger, ground-return-driven spacing that
    /// only applies among ground-net vias specifically (see sliceBoardForSimulation's doc comment).
    /// Default 0.2mm, a typical minimum drill-to-drill clearance.
    double viaClearance() const { return _viaClearance; }
    void setViaClearance(double value) { _viaClearance = value; }

    void scaleToSimulationUnits(std::int32_t unitMultiplier);

private:
    friend void to_json(nlohmann::json& j, const Via& v);
    friend void from_json(const nlohmann::json& j, Via& v);

    double _platingThickness = 50;
    double _fillingEpsilon = 1;
    // In micrometers, like every other length-like field (see constants::baseUnit) -- 0.3mm/0.6mm.
    double _stitchingViaHoleDiameter = 300;
    double _stitchingViaAnnularRingDiameter = 600;
    double _viaClearance = 200;
};

void to_json(nlohmann::json& j, const Via& v);
void from_json(const nlohmann::json& j, Via& v);

/// Margin config (how far outside area of interest should grid span).
class Margin {
public:
    double xy() const { return _xy; }
    void setXy(double value) { _xy = value; }
    double z() const { return _z; }
    void setZ(double value) { _z = value; }

    void scaleToSimulationUnits(std::int32_t unitMultiplier);

private:
    friend void to_json(nlohmann::json& j, const Margin& m);
    friend void from_json(const nlohmann::json& j, Margin& m);

    double _xy = 1500;
    double _z = 2000;
};

void to_json(nlohmann::json& j, const Margin& m);
void from_json(const nlohmann::json& j, Margin& m);

/// Cell Ratio config (Optimal scaling between neighboring grid cell sizes).
class CellRatio {
public:
    double xy() const { return _xy; }
    void setXy(double value) { _xy = value; }
    double z() const { return _z; }
    void setZ(double value) { _z = value; }

private:
    friend void to_json(nlohmann::json& j, const CellRatio& c);
    friend void from_json(const nlohmann::json& j, CellRatio& c);

    double _xy = 1.2;
    double _z = 1.5;
};

void to_json(nlohmann::json& j, const CellRatio& c);
void from_json(const nlohmann::json& j, CellRatio& c);

/// Grid generation config (configures simulation grid density).
class Grid {
public:
    std::int32_t interLayers() const { return _interLayers; }
    void setInterLayers(std::int32_t value) { _interLayers = value; }
    double optimal() const { return _optimal; }
    void setOptimal(double value) { _optimal = value; }
    double diagonal() const { return _diagonal; }
    void setDiagonal(double value) { _diagonal = value; }
    double perpendicular() const { return _perpendicular; }
    void setPerpendicular(double value) { _perpendicular = value; }
    double max() const { return _max; }
    void setMax(double value) { _max = value; }
    const Margin& margin() const { return _margin; }
    Margin& margin() { return _margin; }
    const CellRatio& cellRatio() const { return _cellRatio; }
    CellRatio& cellRatio() { return _cellRatio; }

    /// Clamp max/perpendicular/diagonal/optimal based on the minimum simulated wavelength
    /// (mirrors the grid-related portion of _Config.__post_init__).
    void applyFrequencyConstraint(double stopFrequencyHz);

    /// Scales max/diagonal/optimal/perpendicular/margin into simulation units (mirrors the
    /// grid-related portion of _Config._apply_unit_multiplier).
    void scaleToSimulationUnits(std::int32_t unitMultiplier);

private:
    friend void to_json(nlohmann::json& j, const Grid& g);
    friend void from_json(const nlohmann::json& j, Grid& g);

    std::int32_t _interLayers = 4;
    double _optimal = 50;
    double _diagonal = 50;
    double _perpendicular = 200;
    double _max = 500;
    Margin _margin;
    CellRatio _cellRatio;
};

void to_json(nlohmann::json& j, const Grid& g);
void from_json(const nlohmann::json& j, Grid& g);

/// One independent simulation: its own involved-nets-driven port resolution, board slicing
/// parameters, and excitation list. Replaces the old flat Config::ports()/traces()/diffPairs() for
/// everything simulation-specific.
class SimulationConfig {
public:
    const std::string& name() const { return _name; }
    void setName(std::string value) { _name = std::move(value); }

    const std::vector<InvolvedNetConfig>& involvedNets() const { return _involvedNets; }
    std::vector<InvolvedNetConfig>& involvedNets() { return _involvedNets; }
    const GroundNetConfig& groundNet() const { return _groundNet; }
    GroundNetConfig& groundNet() { return _groundNet; }

    double hullPadding() const { return _hullPadding; }
    void setHullPadding(double value) { _hullPadding = value; }
    double viaEdgeDistance() const { return _viaEdgeDistance; }
    void setViaEdgeDistance(double value) { _viaEdgeDistance = value; }
    double viaSpacing() const { return _viaSpacing; }
    void setViaSpacing(double value) { _viaSpacing = value; }

    std::vector<ExcitationConfig>& excitations() { return _excitations; }
    const std::vector<ExcitationConfig>& excitations() const { return _excitations; }
    std::vector<SingleEndedConfig>& traces() { return _traces; }
    const std::vector<SingleEndedConfig>& traces() const { return _traces; }
    std::vector<DifferentialPairConfig>& diffPairs() { return _diffPairs; }
    const std::vector<DifferentialPairConfig>& diffPairs() const { return _diffPairs; }

    std::vector<PortConfig>& ports() { return _ports; }
    const std::vector<PortConfig>& ports() const { return _ports; }

    /// Auto-discovered 2-pin R/L/C components -- see LumpedComponentConfig's own doc comment.
    /// Populated by resolveSimulationPorts(), alongside ports(); never (de)serialized (same
    /// reasoning as _ports itself -- see that member's own comment below).
    std::vector<LumpedComponentConfig>& lumpedComponents() { return _lumpedComponents; }
    const std::vector<LumpedComponentConfig>& lumpedComponents() const { return _lumpedComponents; }

    /// Every net name resolved from involvedNets() (populated once by resolveSimulationPorts(),
    /// alongside ports()) -- cached here so grid_gen.cpp's mesh-density placement doesn't need to
    /// re-resolve net_class/footprint+pin entries via another libkicad_query round trip. The mesh's
    /// own core-boundary (domain size) is derived directly from the sliced board's own extent, not
    /// from this list, so it does not need the ground net included; grid_gen.cpp's density placement
    /// doesn't need it either (the ground pour's own extent is already covered by the domain-sized
    /// core mesh).
    std::vector<std::string>& resolvedNets() { return _resolvedNets; }
    const std::vector<std::string>& resolvedNets() const { return _resolvedNets; }

    /// Scales hullPadding/viaEdgeDistance/viaSpacing, and every resolved port's width/length
    /// (PortConfig::scaleToSimulationUnits), into simulation units. Does not touch involvedNets(),
    /// which stays in file units even after this call -- it's copied verbatim into a PortConfig by
    /// port_resolution.cpp, itself scaled independently (see InvolvedNetConfig). Only ever called by
    /// EMSConfig::scaledToSimulationUnits(), on a scratch copy -- never on the canonical, edited/
    /// saved EMSConfig a caller holds.
    void scaleToSimulationUnits(std::int32_t unitMultiplier);

private:
    friend void to_json(nlohmann::json& j, const SimulationConfig& p);
    friend void from_json(const nlohmann::json& j, SimulationConfig& p);

    std::string _name;
    std::vector<InvolvedNetConfig> _involvedNets;
    GroundNetConfig _groundNet;
    // In micrometers, like every other length-like field (see constants::baseUnit) -- 5/1.5/1.5 mm.
    double _hullPadding = 5000;
    double _viaEdgeDistance = 1500;
    double _viaSpacing = 1500;
    std::vector<ExcitationConfig> _excitations;
    std::vector<SingleEndedConfig> _traces;
    std::vector<DifferentialPairConfig> _diffPairs;

    std::vector<PortConfig> _ports;         // not (de)serialized, populated by resolveSimulationPorts()
    std::vector<std::string> _resolvedNets; // not (de)serialized, populated by resolveSimulationPorts()
    std::vector<LumpedComponentConfig> _lumpedComponents; // not (de)serialized, populated by resolveSimulationPorts()
};

void to_json(nlohmann::json& j, const SimulationConfig& p);
void from_json(const nlohmann::json& j, SimulationConfig& p);

/// Per-run knobs that don't belong in the parsed config itself -- distinct from Arguments (the
/// CLI's own argv-parsing type, which also carries argv-only fields like configPath/updateConfig
/// that a library caller has no business setting).
struct RunOptions {
    std::int32_t oversampling = 4;
    std::optional<std::vector<std::string>> exportField;
    bool transparent = false;
    bool plotPhase = false;
    FDTDBackend backend = FDTDBackend::OpenEMSCPU;
    PMLKind pmlKind = PMLKind::CPML;
};

/// Parsed simulation.json configuration, plus the stackup imported into it separately (see
/// loadStackup()). A plain value type: every caller holds and threads it explicitly rather than
/// reaching into shared global state, so multiple EMSConfigs (e.g. for different boards) can
/// coexist safely in the same process.
class EMSConfig {
public:
    /// Default-constructs a config for a brand-new document: empty simulations(), every other
    /// field at the same defaults `from_json` would fill in for a field missing from the JSON.
    /// `formatVersion()` is left empty until the first save() (mirroring parse()'s own
    /// `_postInit()`, which a default-constructed EMSConfig doesn't go through).
    EMSConfig() = default;

    /// Parses `cfgPath`. If updateConfig is true and no file exists at cfgPath, creates a stub, and
    /// afterwards rewrites the file with any missing fields filled in (mirrors the CLI's
    /// --update-config behavior).
    static std::expected<EMSConfig, std::string> parse(const std::filesystem::path& cfgPath, bool updateConfig);

    /// Writes this config to `cfgPath` as JSON, in exactly the units it's held in -- this type is
    /// never scaled to simulation units in place (see scaledToSimulationUnits()), so there's no
    /// unscaling to do here; a save() is just to_json() on `self`, verbatim.
    std::expected<void, std::string> save(const std::filesystem::path& cfgPath) const;

    /// A copy of `self` with every spatial field (grid, via, and each simulation's hull padding/
    /// via edge distance/via spacing/resolved ports' width+length) scaled from file units into FDTD
    /// simulation units. `self` itself is never mutated -- called once, by GeometryResult::build()/
    /// load(), right before any FDTD-facing code runs; every other caller (a document editor, this
    /// type's own save()) should keep working with unscaled instances.
    EMSConfig scaledToSimulationUnits() const;

    /// Replaces layers() with `layers` (already resolved by the caller from the live board via
    /// libkicad_query::stackup() -- see importer.cpp's importStackup()).
    void loadStackup(std::vector<LayerConfig> layers);

    /// The .kicad_pcb this document is linked to -- an absolute path to wherever the user's KiCad
    /// project actually lives, stored so the document remembers it across reopens without needing
    /// its own persisted copy of the board (a GUI app's document is itself the thing that persists
    /// across invocations, unlike the CLI, which copies the board into fab/ specifically because it
    /// has no equivalent memory between separate -g/-s/-p runs -- see importer.cpp's
    /// exportKicadPcb()). nullopt until a caller (the app's board picker) sets it.
    const std::optional<std::filesystem::path>& kicadPcbPath() const { return _kicadPcbPath; }
    void setKicadPcbPath(std::optional<std::filesystem::path> value) { _kicadPcbPath = std::move(value); }

    const std::string& formatVersion() const { return _formatVersion; }

    const std::vector<SimulationConfig>& simulations() const { return _simulations; }
    std::vector<SimulationConfig>& simulations() { return _simulations; }

    const Frequency& frequency() const { return _frequency; }
    void setFrequency(Frequency value) { _frequency = value; }
    /// Hard cap on FDTD timesteps (Simulation::run() -> openEMS::SetNumberOfTimeSteps()) -- the run
    /// stops here even if openEMS's own -60dB energy-decay end criteria hasn't been reached yet. Too
    /// low a value truncates the recorded time-domain signal before it's actually decayed, which
    /// shows up in post-processed S-parameters as spurious ripple and rapid phase rotation (a
    /// truncated time-domain signal is equivalent to windowing it with a hard rectangular cutoff,
    /// which is exactly the kind of artifact a DFT turns into ringing).
    std::int32_t maxSteps() const { return _maxSteps; }
    void setMaxSteps(std::int32_t value) { _maxSteps = value; }
    /// Copper-geometry fidelity control, in microns: the maximum chord/sagitta deviation allowed
    /// when tessellating curves (arcs, round pads/vias) into straight polygon edges, and the
    /// point-simplification tolerance applied to the resulting copper regions before triangulation.
    /// Smaller values produce more accurate (and more finely triangulated) curved geometry. Named
    /// "pixel_size" in config JSON for backwards compatibility: this used to be the raster DPI
    /// control for the tool's old gerbv-based rendering pipeline, which the same fidelity/cost
    /// trade-off maps onto directly now that geometry is reconstructed as vectors instead.
    std::int32_t pixelSize() const { return _pixelSize; }
    void setPixelSize(std::int32_t value) { _pixelSize = value; }
    const Via& via() const { return _via; }
    Via& via() { return _via; }
    const Grid& grid() const { return _grid; }
    Grid& grid() { return _grid; }

    const std::vector<LayerConfig>& layers() const { return _layers; }

    std::vector<LayerConfig> getSubstrates() const;
    std::vector<LayerConfig> getMetals() const;
    /// The board's solder mask layers, if present in its stackup -- 0, 1 (top or bottom only, rare),
    /// or 2 (top and bottom, the common case) entries, top-to-bottom order (matching layers()' own
    /// convention) since that's also SolderMaskTop-before-SolderMaskBottom order.
    std::vector<LayerConfig> getSolderMasks() const;

    /// Ordinal index (0-based, counting from the top) of the Metal-kind layer whose LayerConfig::
    /// file() matches `normalizedFileName` (dots already replaced with underscores, matching how
    /// LayerConfig::file() itself is derived from a layer's KiCad name). Used by port_resolution.cpp
    /// to turn a pad's copper layer name into the layer index PortConfig::layer() expects.
    std::optional<std::int32_t> metalLayerIndexForFileName(const std::string& normalizedFileName) const;

private:
    /// Validate grid setting & clamp values (mirrors _Config.__post_init__).
    void _postInit();
    /// Scale distance-valued fields into simulation units (mirrors _Config._apply_unit_multiplier).
    void _applyUnitMultiplier();

    static bool _isCfgVersionInvalid(const std::optional<std::string>& version);

    /// Read config file and load it to a JSON object. If updateConfig is enabled and there is no
    /// config file at the provided path, returns a stub with an empty "simulations" list.
    static nlohmann::json _getCfgJson(const std::filesystem::path& cfgPath, bool updateConfig);

    std::string _formatVersion;
    std::optional<std::filesystem::path> _kicadPcbPath;
    std::vector<SimulationConfig> _simulations;
    Frequency _frequency;
    std::int32_t _maxSteps = 100000;
    std::int32_t _pixelSize = 5;
    Via _via;
    Grid _grid;

    std::vector<LayerConfig> _layers; // not (de)serialized, populated by loadStackup()
};

} // namespace gerber2ems
