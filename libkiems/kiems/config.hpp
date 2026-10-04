// Configuration parsing. Ported from kiems/config.py.
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

#include "constants.hpp"

namespace kiems {

/// Which Copper engine backend actually runs the per-port simulation -- see Simulation::run(),
/// which posix_spawns paths.fdtdWorkerPath (`OpenEMSCPU`) or paths.copperFdtdWorkerPath
/// (`CopperGPU`) depending on this. `OpenEMSCPU`'s own name is a historical holdover from when that
/// worker ran openEMS's real `Engine::RunFDTD()` directly -- it now runs `copper::CopperEngine`'s
/// own CPU backend instead, kept only so
/// every existing `--backend cpu`/serialized value stays stable.
enum class FDTDBackend { OpenEMSCPU, CopperGPU };

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

    /// Display form of the KiCad net this resolved port belongs to. Like footprintRef/padNumber,
    /// this is derived by port_resolution.cpp and copied into scaled configurations, never
    /// serialized as user-authored configuration.
    const std::string& netName() const { return _netName; }
    void setNetName(std::string value) { _netName = std::move(value); }

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
    /// still-default behavior) means a pad-sized lumped resistor gets built between the pad and
    /// reference plane (Simulation::addResistivePort()); false means only U/I probe boxes get placed
    /// (Simulation::addPassiveProbe()), a purely passive read point with zero effect on the
    /// simulated fields. excite() always implies the full absorbing structure regardless of this
    /// flag's own value -- see port_resolution.cpp's resolution rule, which never lets an excited
    /// pad end up with absorbSignal()==false.
    bool absorbSignal() const { return _absorbSignal; }
    void setAbsorbSignal(bool value) { _absorbSignal = value; }

    /// True for a net-level, auto-placed trace-impedance probe (see InvolvedNetConfig::
    /// probeImpedance()'s own doc comment) -- selects Simulation::addImpedanceProbe() in
    /// addPorts()'s dispatch, ahead of the absorbSignal() check (a trace probe is never pad-
    /// anchored, so it's also never added to port_resolution.cpp's own _PortIndex the way every
    /// other port is). Always paired with absorbSignal()==false (it has zero effect on the
    /// simulated fields, same reasoning as a PassiveProbe) and excite()==false.
    bool isTraceProbe() const { return _isTraceProbe; }
    void setIsTraceProbe(bool value) { _isTraceProbe = value; }

    /// Whether this port should appear as a named, selectable entry in Results (the port picker,
    /// S-parameter matrix, impedance charts, etc.) -- entirely a *display* concern, orthogonal to
    /// excite()/absorbSignal(): a resistive termination (Simulation::addResistivePort(), still
    /// selected purely by absorbSignal()) gets built either way, so an "absorb-only" pin (probe()==
    /// false, absorbSignal()==true, excite()==false) still physically loads its own trace exactly
    /// like a real probed pin would -- it just never shows up as something to look at. Meant for a
    /// pin that only exists to keep an otherwise-unmodeled downstream trace (one running to an IC or
    /// resistor outside this simulation's own involved/probed set) from behaving like an open,
    /// fully-reflecting stub in the FDTD field, without cluttering results with a "port" nobody
    /// asked to measure. Defaults true (every pre-existing probed/excited pin stays exactly as
    /// reportable as it always was); see InvolvedNetConfig::setPinAbsorbOnly()'s own doc comment for
    /// how a config entry ends up with probe()==false here.
    bool probe() const { return _probe; }
    void setProbe(bool value) { _probe = value; }

    /// Scales width/length into simulation units (mirrors the `*= UNIT_MULTIPLIER` done in
    /// Config.load).
    void scaleToSimulationUnits(std::int32_t unitMultiplier);

private:
    std::string _name = "Unnamed";
    std::string _footprintRef;
    std::string _padNumber;
    std::string _netName;
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
    bool _isTraceProbe = false;
    bool _probe = true;
};

/// Axis-aligned XY footprint used to reserve mesh density for a component-facing port. It must
/// match Simulation::addResistivePort()'s box exactly: if the synthetic grid pad is offset or
/// smaller than the resistor, mesh deduplication can leave the termination with no electrically
/// connected Yee column even though its configured pad is inside the simulation cutout.
struct PortGridFootprint {
    double centerX;
    double centerY;
    double width;
    double height;
};

PortGridFootprint portGridFootprint(const PortConfig& port);

/// Which of a LumpedComponentConfig's R/L/C fields are physically present -- mirrors how
/// CSPropLumpedElement/Operator_Ext_LumpedRLC themselves distinguish "absent" (NaN) from "present,
/// value zero" (see operator_ext_lumpedRLC.cpp's own doc comment on this), just narrowed to the
/// three single-quantity component kinds resolveSimulationPorts() ever auto-discovers.
enum class LumpedComponentType { Resistor, Inductor, Capacitor };

/// One auto-discovered 2-pin R/L/C component, resolved to real board geometry -- populated
/// entirely by resolveSimulationPorts() (never (de)serialized, same as PortConfig; see
/// SimulationConfig::_lumpedComponents' own comment). A component only ever gets one of these if
/// both its pins sit on nets included at either inclusion level (or on the simulation's ground net)
/// and at least one pad centre survives inside the subsequently computed board cutout -- see
/// port_resolution.cpp's discovery and restrictLumpedComponentsToCutout()'s spatial filter.
class LumpedComponentConfig {
public:
    const std::string& reference() const { return _reference; }
    void setReference(std::string value) { _reference = std::move(value); }

    LumpedComponentType type() const { return _type; }
    void setType(LumpedComponentType value) { _type = value; }

    /// Display-form net names at the two terminals. These are retained alongside the geometry so
    /// result presentation can identify every net electrically reachable through the passives
    /// that were actually included in this simulation.
    const std::string& net1() const { return _net1; }
    void setNet1(std::string value) { _net1 = std::move(value); }
    const std::string& net2() const { return _net2; }
    void setNet2(std::string value) { _net2 = std::move(value); }

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
    /// PortConfig::direction(). When cornerBridge() is true, this is the pos1->bridgeCorner() leg's
    /// own axis instead (see cornerBridge()'s own doc comment) -- position2 isn't reached by
    /// travelling along this direction in that mode.
    double direction() const { return _direction; }
    void setDirection(double value) { _direction = value; }

    /// Only meaningful when cornerBridge() is true -- the bridgeCorner()->position2 leg's own axis
    /// (same 0/90/180/270 convention as direction(), which is the pos1->corner leg's axis in that
    /// mode).
    double direction2() const { return _direction2; }
    void setDirection2(double value) { _direction2 = value; }

    /// True if this component's two pads aren't cardinally aligned with each other (see
    /// port_resolution.cpp's own _resolveLumpedComponents() doc comment for why that can happen --
    /// a 2-pin part's footprint placed at a diagonal board angle). CSPropLumpedElement/
    /// Operator_Ext_LumpedRLC have no concept of a diagonal element (a lumped component modifies one
    /// E-field edge's own update equation along a single Cartesian axis, not a filled 3D region like
    /// real copper), so Simulation::addLumpedComponents() dispatches this to a genuinely different
    /// code path: an ordinary, single-axis lumped R/L/C element from position1() to bridgeCorner()
    /// (along direction()), plus a second, plain zero-impedance PEC wire segment from bridgeCorner()
    /// to position2() (along direction2()) -- an L-shaped route through a synthetic corner point,
    /// each leg individually cardinal-aligned even though the true pad1->pad2 line isn't. This
    /// replaced an earlier "remote pair" mechanism (a shared Norton-node branch-current state
    /// bridging two independent, non-adjacent terminals with no real geometric connection at all --
    /// see git history for CopperLumpedRLCPair.hpp/CopperLumpedRLCPairDiscovery.*, now deleted)
    /// abandoned after two separate real-board failures: first, no single axis-aligned box size
    /// could both fully cover a terminal's own real (rotated) pad *and* avoid overlapping a
    /// tightly-pitched neighbour's pad; second, and more fundamentally, that mechanism's own
    /// per-terminal "local bare capacitance" (recovered from the tiny claimed edges' own admittance)
    /// has no way to represent "this terminal sits on a large, well-connected, low-impedance real
    /// trace" -- every value tried (geometry-derived, or an artificially large fixed constant) turned
    /// the branch into a divider dominated by that terminal capacitance rather than the real R/L/C,
    /// confirmed empirically (a real board's own reported cd values reproduced a frequency-
    /// *independent* attenuation matching a plain two-capacitor charge-sharing ratio, not the near-
    /// total transmission a 220nF cap should show at 100MHz-6GHz). A real geometric connection (this
    /// field) sidesteps that meta-problem entirely: current only ever flows through real, ordinary
    /// Yee-grid physics, the same as any other trace. See bridgeCorner()'s own doc comment for how
    /// the corner point is chosen to guarantee it (and both legs) can't interfere with any other net's
    /// real copper. When false (the common case), position1()->position2() along direction() is one
    /// ordinary axis-aligned run, exactly as before this field existed.
    bool cornerBridge() const { return _cornerBridge; }
    void setCornerBridge(bool value) { _cornerBridge = value; }

    /// Only meaningful when cornerBridge() is true -- the synthetic L-shaped route's own corner point
    /// (x, y), already in simulation-frame units (like position1()/position2(), so never touched by
    /// scaleToSimulationUnits()). Always one of the two axis-aligned choices ((position2().x,
    /// position1().y) or (position1().x, position2().y)) -- port_resolution.cpp's own
    /// _resolveLumpedComponents() picks whichever of the two keeps both legs (as real-width bridge
    /// geometry, not just this single point) clear of every *other* net's own pads, tracks, and
    /// copper pours on this component's own layer (a real geometric query against the board itself,
    /// not a heuristic), or leaves cornerBridge() false and drops the component entirely (logged) if
    /// neither choice is clear -- silently connecting into an unrelated net would be a worse outcome
    /// than not modelling this component at all.
    const std::pair<double, double>& bridgeCorner() const { return _bridgeCorner; }
    void setBridgeCorner(std::pair<double, double> value) { _bridgeCorner = value; }

    std::int32_t layer() const { return _layer; }
    void setLayer(std::int32_t value) { _layer = value; }

    /// Transverse box width, in file units until scaleToSimulationUnits() runs -- matches
    /// PortConfig::width()'s own default. When cornerBridge() is true, both legs (position1()-
    /// >bridgeCorner() and bridgeCorner()->position2()) use this same width, and it's also the
    /// clearance width port_resolution.cpp's own interference check requires around each leg.
    double width() const { return _width; }
    void setWidth(double value) { _width = value; }

    void scaleToSimulationUnits(std::int32_t unitMultiplier) { _width *= unitMultiplier; }

private:
    std::string _net1;
    std::string _net2;
    std::string _reference;
    LumpedComponentType _type = LumpedComponentType::Resistor;
    double _resistance = std::numeric_limits<double>::quiet_NaN();
    double _inductance = std::numeric_limits<double>::quiet_NaN();
    double _capacitance = std::numeric_limits<double>::quiet_NaN();
    std::pair<double, double> _position1;
    std::pair<double, double> _position2;
    std::pair<double, double> _bridgeCorner;
    double _direction = 0;
    double _direction2 = 0;
    bool _cornerBridge = false;
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
    void setFootprint(std::string value) { _footprint = std::move(value); }
    void setPin(std::string value) { _pin = std::move(value); }

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

/// How fully an InvolvedNetConfig entry participates in the simulation -- the "Simulation Net" vs.
/// "Included in Simulation" source-list checkboxes. SimulationNet is full participation (today's
/// only behavior, pre-dating this distinction): the net's copper defines/grows the hull region
/// (board_slicing.cpp's own InflatePaths of the involved-net union), feeds sim.resolvedNets()
/// (port_resolution.cpp), and its pads are eligible for Probe/Absorb/Excite ports. GeometryOnly is a
/// strict subset: the net's copper is composited into the simulated geometry (clipped to whatever
/// hull the SimulationNet-level entries already produced, exactly like ground-net copper already
/// is -- see board_slicing.cpp), but never grows the hull itself, never enters resolvedNets(), and
/// never becomes probe/excitation-eligible. An explicitly absorbing pin, or a non-ground KiCad
/// input/bidirectional/power-input pin with no explicit override, is the sole port exception: it
/// still gets an unreported physical termination, without promoting the net or expanding the hull.
/// Meant for geometry (e.g. via-stitched ground-
/// adjacent structure) that needs to physically exist in the mesh/model but isn't itself something
/// being probed or exciting a response -- see grid_gen.cpp's own ground-net density treatment for
/// the same reasoning applied one layer up (mesh density, not geometry inclusion).
enum class NetInclusionLevel {
    SimulationNet,
    GeometryOnly,
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

/// One footprint+pin+absorb(+probe) entry -- the opt-*in* per-pin selection the source list's
/// "Probe"/"Absorb Signal" checkboxes drive (see InvolvedNetConfig::probedPins()'s own doc comment
/// for how this coexists with the older, opt-*out* ExcludedPin list). `probe` defaults true (every
/// pre-existing entry -- from before this field existed -- keeps meaning exactly what it always did:
/// a real, reportable S-parameter/impedance probe); `probe=false` is InvolvedNetConfig::
/// setPinAbsorbOnly()'s own state. With absorbSignal=true that is a real resistive termination with
/// nothing shown in Results (see PortConfig::probe()'s own doc comment); with absorbSignal=false it
/// is an explicit no-port choice, retained so a UI default such as "active-component pins absorb"
/// can be overridden and round-tripped. `probe` is declared *after* absorbSignal so every
/// existing 3-argument positional `ProbedPin{footprint, pin, absorbSignal}` construction keeps
/// working unchanged, defaulting the new field to true.
struct ProbedPin {
    std::string footprint;
    std::string pin;
    bool absorbSignal = true;
    bool probe = true;

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

/// One footprint+pin port-impedance override, in ohms. Kept separate from ProbedPin so changing a
/// pin between probed, absorb-only, and excited states does not discard its termination setting.
struct PinImpedanceOverride {
    std::string footprint;
    std::string pin;
    double impedance = 45;

    bool operator==(const PinImpedanceOverride& other) const {
        return footprint == other.footprint && pin == other.pin;
    }
};

void to_json(nlohmann::json& j, const PinImpedanceOverride& p);
void from_json(const nlohmann::json& j, PinImpedanceOverride& p);

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
///    this net is edited via the new UI): pads named in probedPins() use that explicit state;
///    otherwise non-ground KiCad input/bidirectional/power-input pins get an unreported 45-ohm
///    absorbing port by default. A SimulationConfig-level ExcitationConfig always gets a full
///    absorbing/reportable port regardless of either rule. excludedPins() is not consulted in this
///    mode.
/// See port_resolution.cpp's resolveSimulationPorts() for the exact rule, and
/// SourceListViewController's probeToggled()/absorbToggled()/excitedToggled() for how the GUI
/// drives it.
class InvolvedNetConfig {
public:
    NetSelectorKind kind() const { return _kind; }
    /// Defaults to SimulationNet -- an entry from a simulation.json predating this distinction loads
    /// with exactly its old, only-ever-had behavior. See NetInclusionLevel's own doc comment.
    NetInclusionLevel inclusionLevel() const { return _inclusionLevel; }
    void setInclusionLevel(NetInclusionLevel value) { _inclusionLevel = value; }
    /// Distance by which this entry's copper expands the simulation hull, in micrometers in a
    /// saved configuration and simulation units in a scaled working copy. Zero is meaningful: the
    /// copper still contributes, and therefore survives clipping, but the hull follows its edge.
    /// GeometryOnly entries do not contribute at all, irrespective of this retained value.
    double hullPadding() const { return _hullPadding; }
    void setHullPadding(double value) { _hullPadding = value; }
    void scaleHullPaddingToSimulationUnits(std::int32_t unitMultiplier) { _hullPadding *= unitMultiplier; }
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
    /// Switches a newly-created net to explicit opt-in mode without having to invent a dummy pin.
    /// This is used by selection-driven configuration UIs whose documented default is zero probed
    /// pins. Serialisation writes an empty `probed_pins` array, so the choice round-trips.
    void useExplicitPinSelections() { _hasExplicitPinSelections = true; }
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
    /// nullopt if `footprint`.`pin` isn't in probedPins() at all -- otherwise that entry's own
    /// `probe` flag (see ProbedPin's own doc comment). Distinct from probedPinAbsorbs(): a pin can
    /// be in this list (get a real port) while probe() is false (absorb-only, not reportable).
    std::optional<bool> probedPinIsProbe(const std::string& footprint, const std::string& pin) const {
        const auto it = std::find_if(_probedPins.begin(), _probedPins.end(), [&](const ProbedPin& p) {
            return p.footprint == footprint && p.pin == pin;
        });
        return it != _probedPins.end() ? std::optional<bool>(it->probe) : std::nullopt;
    }
    /// Sets (`absorbSignal` has a value) or clears (nullopt) this one pad's probed state. Always
    /// sets hasExplicitPinSelections() true, even when clearing -- the act of editing a pin's Probe
    /// state at all is what commits this net to the new, explicit resolution mode (see this class's
    /// own doc comment); there's no way back to legacy mode once any pin has been touched. Always
    /// sets probe=true (a reportable probe) -- see setPinAbsorbOnly() for the other state this same
    /// list can hold.
    void setPinProbed(const std::string& footprint, const std::string& pin, std::optional<bool> absorbSignal) {
        _hasExplicitPinSelections = true;
        _probedPins.erase(std::remove_if(_probedPins.begin(), _probedPins.end(),
                                          [&](const ProbedPin& p) { return p.footprint == footprint && p.pin == pin; }),
                           _probedPins.end());
        if (absorbSignal.has_value()) {
            _probedPins.push_back({footprint, pin, *absorbSignal, /*probe=*/true});
        }
    }
    /// Stores this one pad's explicit unprobed absorbing choice. When enabled, a real resistive
    /// termination port gets built for it (see PortConfig::absorbSignal()'s own doc comment on
    /// Simulation::addResistivePort()), so it doesn't behave as an open, fully-reflecting stub in
    /// the FDTD field. When disabled, the retained probe=false/absorbSignal=false entry explicitly
    /// means no port, overriding UI defaults while still round-tripping through JSON. It is never
    /// shown as a measured port in Results and never becomes an excitation target on its own.
    /// Works on a GeometryOnly entry too
    /// (unlike setPinProbed(), which is meaningless there -- see NetInclusionLevel's own doc comment
    /// and port_resolution.cpp's resolveSimulationPorts(), which reads probedPins() for a
    /// GeometryOnly entry only to find absorb-only pins like this one, never to grow resolvedNets()
    /// or place a reportable probe). Mutually exclusive with setPinProbed() for the same pin -- a pin
    /// is either measured or just loaded, never both -- so this replaces any existing entry outright,
    /// same erase-then-push_back shape as setPinProbed().
    void setPinAbsorbOnly(const std::string& footprint, const std::string& pin, bool enabled) {
        _hasExplicitPinSelections = true;
        _probedPins.erase(std::remove_if(_probedPins.begin(), _probedPins.end(),
                                          [&](const ProbedPin& p) { return p.footprint == footprint && p.pin == pin; }),
                           _probedPins.end());
        _probedPins.push_back({footprint, pin, /*absorbSignal=*/enabled, /*probe=*/false});
    }

    double impedance() const { return _impedance; }
    double length() const { return _length; } // -> PortConfig::length()
    std::int32_t plane() const { return _plane; }
    /// Net/NetClass-kind entries only (meaningless for a FootprintPin-kind entry, which names a
    /// single pad, not a routed net to search for straight trace runs on). When true,
    /// resolveSimulationPorts() additionally auto-places up to a handful of non-loading, trace-
    /// anchored impedance-measurement probes (PortConfig::isTraceProbe()==true) along this net's
    /// own straight, pad-clear routed copper -- independent of, and in addition to, whatever ports
    /// this net's own pads already resolve to via probedPins()/excludedPins(). Neither impedance()
    /// nor length() is read for this: a trace probe measures Z rather than being sized to one, and
    /// its width and propagation-axis extent are derived from the selected KiCad track run (see
    /// port_resolution.cpp's probe-placement loop) -- so a net that's only ever probed for
    /// impedance genuinely needs neither field set.
    bool probeImpedance() const { return _probeImpedance; }
    void setProbeImpedance(bool value) { _probeImpedance = value; }
    /// For Net-kind entries that were added together as a differential pair, names the other
    /// entry's net.  Stored reciprocally on both entries so either one remains self-describing
    /// when edited through the UI.
    const std::optional<std::string>& differentialPairPartner() const { return _differentialPairPartner; }
    void setDifferentialPairPartner(std::optional<std::string> value) {
        _differentialPairPartner = std::move(value);
    }
    /// When enabled, the paired ports are interpreted as an odd-mode stimulus and mixed-mode
    /// S-parameters/impedance are produced. Pair membership itself is retained when this is off.
    bool simulateAsDifferentialPair() const { return _simulateAsDifferentialPair; }
    void setSimulateAsDifferentialPair(bool value) { _simulateAsDifferentialPair = value; }
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

    std::optional<double> pinImpedance(const std::string& footprint, const std::string& pin) const {
        const auto it = std::find_if(_pinImpedanceOverrides.begin(), _pinImpedanceOverrides.end(),
                                     [&](const PinImpedanceOverride& o) {
                                         return o.footprint == footprint && o.pin == pin;
                                     });
        return it != _pinImpedanceOverrides.end() ? std::optional<double>(it->impedance) : std::nullopt;
    }
    /// Sets (or, given nullopt, clears) this pin's port-impedance override.
    void setPinImpedance(const std::string& footprint, const std::string& pin,
                         std::optional<double> impedance) {
        _pinImpedanceOverrides.erase(
            std::remove_if(_pinImpedanceOverrides.begin(), _pinImpedanceOverrides.end(),
                           [&](const PinImpedanceOverride& o) {
                               return o.footprint == footprint && o.pin == pin;
                           }),
            _pinImpedanceOverrides.end());
        if (impedance.has_value()) {
            _pinImpedanceOverrides.push_back({footprint, pin, *impedance});
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
    NetInclusionLevel _inclusionLevel = NetInclusionLevel::SimulationNet;
    double _hullPadding = 5000;
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
    bool _probeImpedance = false;
    std::optional<std::string> _differentialPairPartner;
    bool _simulateAsDifferentialPair = false;
    std::optional<double> _width;
    std::optional<double> _dBMargin;
    std::optional<double> _direction;
    std::vector<PinDirectionOverride> _pinDirectionOverrides;
    std::vector<PinImpedanceOverride> _pinImpedanceOverrides;
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

/// One entry in a SimulationConfig's excitations list. It identifies either an ordinary pad by
/// footprint/pin or an authored hull-cut port by id. The resolved port index is derived for the
/// FDTD run and is never persisted.
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
    const std::optional<std::string>& hullCutPortID() const { return _hullCutPortID; }

    const std::optional<std::int32_t>& drivenPortIndex() const { return _drivenPortIndex; }
    void setDrivenPortIndex(std::int32_t index) { _drivenPortIndex = index; }
    void clearDrivenPortIndex() { _drivenPortIndex.reset(); }

    void setStartTime(double value) { _startTime = value; }
    void setDuration(double value) { _duration = value; }
    void setIsMain(bool value) { _isMain = value; }
    void setFrequency(std::optional<double> value) { _frequency = value; }
    void setAmplitude(std::optional<double> value) { _amplitude = value; }
    void setPhaseDegrees(double value) { _phaseDegrees = value; }
    void setFootprint(std::string value) { _footprint = std::move(value); }
    void setPin(std::string value) { _pin = std::move(value); }
    void setHullCutPortID(std::optional<std::string> value) { _hullCutPortID = std::move(value); }

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
    std::optional<std::string> _hullCutPortID;
    std::optional<std::int32_t> _drivenPortIndex; // not (de)serialized
};

void to_json(nlohmann::json& j, const ExcitationConfig& p);
void from_json(const nlohmann::json& j, ExcitationConfig& p);

/// A user-authored port at a routed trace's intersection with the simulation hull. Unlike an
/// ordinary pad port it has no footprint/pin identity, so its complete placement is persisted.
/// Positions, width and length are in configuration micrometres and are scaled at the same
/// FDTD-facing boundary as every other authored length.
class HullCutPortConfig {
public:
    const std::string& id() const { return _id; }
    const std::string& net() const { return _net; }
    const std::string& layer() const { return _layer; }
    double x() const { return _x; }
    double y() const { return _y; }
    double direction() const { return _direction; }
    double width() const { return _width; }
    double length() const { return _length; }
    std::int32_t plane() const { return _plane; }
    double impedance() const { return _impedance; }
    bool probe() const { return _probe; }
    bool absorbSignal() const { return _absorbSignal; }

    void setID(std::string value) { _id = std::move(value); }
    void setNet(std::string value) { _net = std::move(value); }
    void setLayer(std::string value) { _layer = std::move(value); }
    void setX(double value) { _x = value; }
    void setY(double value) { _y = value; }
    void setDirection(double value) { _direction = value; }
    void setWidth(double value) { _width = value; }
    void setLength(double value) { _length = value; }
    void setPlane(std::int32_t value) { _plane = value; }
    void setImpedance(double value) { _impedance = value; }
    void setProbe(bool value) { _probe = value; }
    void setAbsorbSignal(bool value) { _absorbSignal = value; }
    void scaleToSimulationUnits(std::int32_t unitMultiplier);

private:
    friend void to_json(nlohmann::json& j, const HullCutPortConfig& p);
    friend void from_json(const nlohmann::json& j, HullCutPortConfig& p);
    std::string _id;
    std::string _net;
    std::string _layer;
    double _x = 0;
    double _y = 0;
    double _direction = 0;
    double _width = 200;
    double _length = 200;
    std::int32_t _plane = 1;
    double _impedance = 45;
    bool _probe = false;
    bool _absorbSignal = false;
};

void to_json(nlohmann::json& j, const HullCutPortConfig& p);
void from_json(const nlohmann::json& j, HullCutPortConfig& p);

/// Which of DiffPairNetMember's mutually-exclusive selector fields is populated.
enum class DiffPairNetKind {
    NetClass,
    Net,
};

/// One entry in a DifferentialPairConfig's positiveNets()/negativeNets() list -- a net or net
/// class that belongs to that half of the pair. More than one entry on a side means those nets
/// are expected to be connected to each other by series components only (e.g. AC-coupling caps),
/// which is also why positiveProbe/negativeProbe can legitimately land on a different net than
/// positiveExcitation/negativeExcitation -- see DifferentialPairConfig's own doc comment.
/// Serializes as a single "net://name" or "net-class://name" string rather than an object, to
/// keep a hand-written differential_pairs entry terse.
class DiffPairNetMember {
public:
    DiffPairNetKind kind() const { return _kind; }
    const std::optional<std::string>& netClass() const { return _netClass; }
    const std::optional<std::string>& net() const { return _net; }

    void setKind(DiffPairNetKind value) { _kind = value; }
    void setNetClass(std::optional<std::string> value) { _netClass = std::move(value); }
    void setNet(std::optional<std::string> value) { _net = std::move(value); }

private:
    friend void to_json(nlohmann::json& j, const DiffPairNetMember& p);
    friend void from_json(const nlohmann::json& j, DiffPairNetMember& p);

    DiffPairNetKind _kind = DiffPairNetKind::Net;
    std::optional<std::string> _netClass;
    std::optional<std::string> _net;
};

void to_json(nlohmann::json& j, const DiffPairNetMember& p);
void from_json(const nlohmann::json& j, DiffPairNetMember& p);

/// Class representing and parsing differential pair config, for postprocessing (mixed-mode
/// S-parameter / differential impedance) and field-viewer (combined-mode field snapshot)
/// purposes. References ports by footprint+pin rather than index, since one-port-per-pad makes
/// hand-written indices unpredictable.
///
/// Named for how a differential pair is actually used, not the geometric start/stop language an
/// earlier shape of this class used: `positiveExcitation`/`negativeExcitation` are the driven,
/// independently-excited near-end pins (the two ports the FDTD sweep runs separately -- see
/// EMSSimulationPipelineBridge.mm's combined field-snapshot code and Postprocessor::
/// getDiffPairSdd(), which both linearly combine those two ports' own independent results rather
/// than reading anything from positiveProbe/negativeProbe directly). `positiveProbe`/
/// `negativeProbe` are the absorbing far-end pins mixed-mode S-parameter/impedance analysis
/// reports against.
///
/// `positiveNets`/`negativeNets` record every net that half of the signal actually travels over
/// between those two ends -- more than one when series components break net continuity along the
/// way (see DiffPairNetMember's own doc comment), which is also why positiveProbe/negativeProbe
/// can land on a different net than positiveExcitation/negativeExcitation.
class DifferentialPairConfig {
public:
    const PortRef& positiveExcitation() const { return _positiveExcitation; }
    PortRef& positiveExcitation() { return _positiveExcitation; }
    const PortRef& positiveProbe() const { return _positiveProbe; }
    PortRef& positiveProbe() { return _positiveProbe; }
    const PortRef& negativeExcitation() const { return _negativeExcitation; }
    PortRef& negativeExcitation() { return _negativeExcitation; }
    const PortRef& negativeProbe() const { return _negativeProbe; }
    PortRef& negativeProbe() { return _negativeProbe; }
    const std::vector<DiffPairNetMember>& positiveNets() const { return _positiveNets; }
    std::vector<DiffPairNetMember>& positiveNets() { return _positiveNets; }
    const std::vector<DiffPairNetMember>& negativeNets() const { return _negativeNets; }
    std::vector<DiffPairNetMember>& negativeNets() { return _negativeNets; }
    const std::optional<std::string>& name() const { return _name; }
    void setName(std::optional<std::string> value) { _name = std::move(value); }
    /// Canonical user-facing label shared by the Field Viewer and every results category.
    std::string displayName() const { return "Differential Pair - " + _name.value_or("Unnamed"); }
    bool automatic() const { return _automatic; }
    void setAutomatic(bool value) { _automatic = value; }
    bool correct() const { return _correct; }
    /// Lets port_resolution.cpp fail this pair after postInit() -- e.g. once it's found that
    /// positiveNets()/negativeNets() don't actually connect positiveExcitation()/positiveProbe()
    /// (or the negative equivalents) via series components -- the same board-query-dependent kind
    /// of check postInit() itself can't do, since it takes no PathsConfig and never talks to the
    /// board.
    void setCorrect(bool value) { _correct = value; }

    /// Validate that every PortRef resolved to a real port (mirrors __post_init__, now
    /// resolution-based instead of index-range-based).
    void postInit();

private:
    friend void to_json(nlohmann::json& j, const DifferentialPairConfig& p);
    friend void from_json(const nlohmann::json& j, DifferentialPairConfig& p);

    PortRef _positiveExcitation;
    PortRef _positiveProbe;
    PortRef _negativeExcitation;
    PortRef _negativeProbe;
    std::vector<DiffPairNetMember> _positiveNets;
    std::vector<DiffPairNetMember> _negativeNets;
    std::optional<std::string> _name;
    bool _correct = true; // not (de)serialized
    bool _automatic = false; // derived from involved-net pairing; never serialized
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

/// One layer of a resolved board stackup (see libkicad::Board::stackup()) -- copper, substrate, or
/// (top/bottom) solder mask, already scaled to simulation units.
class LayerConfig {
public:
    /// `thicknessMm` is scaled to simulation units internally; `epsilon`/`lossTangent` are ignored
    /// (left at 0) for `LayerKind::Metal`. For `LayerKind::Metal`, `file()` is derived from `name` by
    /// replacing '.' with '_' (matching how kiems already names its own Gerber-derived layer
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

    /// Grows xy/z (never shrinks) so the gap between the modeled structure and the PML boundary is
    /// at least a quarter of `minWavelength` (same micrometer units as _xy/_z, pre-
    /// scaleToSimulationUnits() -- see Grid::applyFrequencyConstraint()'s own call site). The fixed
    /// 1.5mm/2mm defaults below were tuned for lower-frequency nets; PML absorbs incoming plane
    /// waves well but is much less effective against near-field/evanescent content that hasn't
    /// settled by the time it reaches the boundary, and at several-GHz content (e.g. USB SuperSpeed)
    /// 1.5mm can be electrically tight enough to show up as a visible reflection artifact right at
    /// the board edge. Quarter-wavelength is a conservative standard buffer, not a rigorously
    /// derived value -- a reasonable starting point to tune from if artifacts persist.
    void applyFrequencyConstraint(double minWavelength);

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
    /// Absorbing boundary depth in cells on every face (the CPML, and an irregular domain's matched
    /// ring): GridGenerator appends this many dedicated cells beyond the mesh on each side, and
    /// Copper's absorber grades them -- so changing it changes the geometry.
    std::int32_t absorbingBoundaryCells() const { return _absorbingBoundaryCells; }
    void setAbsorbingBoundaryCells(std::int32_t value) { _absorbingBoundaryCells = value; }

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
    std::int32_t _absorbingBoundaryCells = constants::defaultAbsorbingBoundaryCells;
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

    double viaEdgeDistance() const { return _viaEdgeDistance; }
    void setViaEdgeDistance(double value) { _viaEdgeDistance = value; }
    double viaSpacing() const { return _viaSpacing; }
    void setViaSpacing(double value) { _viaSpacing = value; }
    /// Serial data rate used when synthesizing the PRBS waveform for eye-diagram analysis. A
    /// non-positive value means "automatic"; results generation then uses the analysis stop
    /// frequency so older configurations acquire a useful eye without a migration step.
    double eyeBitRate() const { return _eyeBitRate; }
    void setEyeBitRate(double value) { _eyeBitRate = value; }

    /// Whether this simulation is fundamentally about a differential pair -- gates
    /// resolveSimulationPorts()'s own reciprocal-net-pair auto-detection (which populates
    /// diffPairs() from involvedNets() entries carrying a differentialPairPartner/
    /// simulateAsDifferentialPair pairing): that auto-generation only ever runs when this is true,
    /// so a false positive (two nets that happen to look paired) never silently turns a normal,
    /// single-ended simulation's results into a mixed-mode one. False by default -- existing
    /// configurations keep resolving with no diffPairs() at all until this is explicitly set,
    /// matching their behavior from before this flag existed.
    bool isDifferentialPair() const { return _isDifferentialPair; }
    void setIsDifferentialPair(bool value) { _isDifferentialPair = value; }

    /// Nets whose copper is terminated to the ground net wherever the board-slicing cut crosses it.
    /// The cut makes a plane that really continues across the board (a power pour, say) end in an
    /// open edge, which turns it into a closed, lightly damped resonator between the adjacent
    /// reference planes. sliceBoardForSimulation() records where these nets' copper meets the cut
    /// (SlicedBoard::edgeTerminationLoops) and Simulation::addEdgeTerminations() places a matched
    /// resistive sheet (a dissipative edge termination, Novak 1999) in the dielectric on either side,
    /// so energy reaching the cut leaves as it would into the rest of the plane. Names use the same
    /// spelling as ground_net's "net" (the board's own net names).
    const std::vector<std::string>& edgeTerminatedNets() const { return _edgeTerminatedNets; }
    std::vector<std::string>& edgeTerminatedNets() { return _edgeTerminatedNets; }

    std::vector<ExcitationConfig>& excitations() { return _excitations; }
    const std::vector<ExcitationConfig>& excitations() const { return _excitations; }
    std::vector<HullCutPortConfig>& hullCutPorts() { return _hullCutPorts; }
    const std::vector<HullCutPortConfig>& hullCutPorts() const { return _hullCutPorts; }
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
    /// re-resolve net_class/footprint+pin entries via another ki round trip. The mesh's
    /// own core-boundary (domain size) is derived directly from the sliced board's own extent, not
    /// from this list, so it does not need the ground net included; grid_gen.cpp's density placement
    /// doesn't need it either (the ground pour's own extent is already covered by the domain-sized
    /// core mesh).
    std::vector<std::string>& resolvedNets() { return _resolvedNets; }
    const std::vector<std::string>& resolvedNets() const { return _resolvedNets; }

    /// Scales every involved net's hull padding, viaEdgeDistance/viaSpacing, and every resolved
    /// port's width/length (PortConfig::scaleToSimulationUnits), into simulation units. The other
    /// InvolvedNetConfig fields stay in file units: impedance/length/width are copied verbatim into
    /// a PortConfig by port_resolution.cpp and scaled with that port exactly once. Only ever called
    /// by EMSConfig::scaledToSimulationUnits(), on a scratch copy -- never on the canonical,
    /// edited/saved EMSConfig a caller holds.
    void scaleToSimulationUnits(std::int32_t unitMultiplier);

private:
    friend void to_json(nlohmann::json& j, const SimulationConfig& p);
    friend void from_json(const nlohmann::json& j, SimulationConfig& p);

    std::string _name;
    std::vector<InvolvedNetConfig> _involvedNets;
    GroundNetConfig _groundNet;
    // In micrometers, like every other length-like field (see constants::baseUnit) -- 1.5/1.5 mm.
    double _viaEdgeDistance = 1500;
    double _viaSpacing = 1500;
    double _eyeBitRate = 0;
    bool _isDifferentialPair = false;
    std::vector<std::string> _edgeTerminatedNets;
    std::vector<ExcitationConfig> _excitations;
    std::vector<HullCutPortConfig> _hullCutPorts;
    std::vector<SingleEndedConfig> _traces;
    std::vector<DifferentialPairConfig> _diffPairs;

    std::vector<PortConfig> _ports;         // not (de)serialized, populated by resolveSimulationPorts()
    std::vector<std::string> _resolvedNets; // not (de)serialized, populated by resolveSimulationPorts()
    std::vector<LumpedComponentConfig> _lumpedComponents; // not (de)serialized, populated by resolveSimulationPorts()
};

void to_json(nlohmann::json& j, const SimulationConfig& p);
void from_json(const nlohmann::json& j, SimulationConfig& p);

/// Per-run knobs that don't belong in the parsed config itself -- distinct from Arguments in the
/// CLI (its argv-parsing type, which also carries argv-only fields like configPath/updateConfig
/// that a library caller has no business setting).
struct RunOptions {
    std::int32_t oversampling = 4;
    std::optional<std::vector<std::string>> exportField;
    bool transparent = false;
    bool plotPhase = false;
    FDTDBackend backend = FDTDBackend::OpenEMSCPU;
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

    /// A copy of `self` with every spatial field (grid, via, and each involved net's hull padding/
    /// via edge distance/via spacing/resolved ports' width+length) scaled from file units into FDTD
    /// simulation units. `self` itself is never mutated -- called once, by GeometryResult::build()/
    /// load(), right before any FDTD-facing code runs; every other caller (a document editor, this
    /// type's own save()) should keep working with unscaled instances.
    EMSConfig scaledToSimulationUnits() const;

    /// Replaces layers() with `layers` (already resolved by the caller from the live board via
    /// libkicad::Board::stackup() -- see importer.cpp's importStackup()).
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
    /// Hard cap on FDTD timesteps -- the run stops here even if Copper's -60dB energy-decay end
    /// criterion hasn't been reached yet. Too
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

} // namespace kiems
