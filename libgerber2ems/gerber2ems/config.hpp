// Configuration parsing. Ported from gerber2ems/config.py.
#pragma once

#include <cstdint>
#include <expected>
#include <filesystem>
#include <optional>
#include <string>
#include <utility>
#include <vector>

#include <nlohmann/json.hpp>

namespace gerber2ems {

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

/// One entry in a SimulationConfig's involved-nets list. Resolves (via port_resolution.cpp and
/// libkicad) to a set of net names -- a net class expands to every net assigned to it; a
/// footprint+pin resolves to the net connected to that pin and is thereafter treated exactly like
/// naming that net directly. Every pad on every resolved net gets one auto-placed PortConfig,
/// using this entry's impedance/length/plane/overrides.
class InvolvedNetConfig {
public:
    NetSelectorKind kind() const { return _kind; }
    const std::optional<std::string>& netClass() const { return _netClass; }
    const std::optional<std::string>& net() const { return _net; }
    const std::optional<std::string>& footprint() const { return _footprint; }
    const std::vector<std::string>& pins() const { return _pins; }

    double impedance() const { return _impedance; }
    double length() const { return _length; } // -> PortConfig::length()
    std::int32_t plane() const { return _plane; }
    const std::optional<double>& width() const { return _width; }
    const std::optional<double>& dBMargin() const { return _dBMargin; }
    const std::optional<double>& direction() const { return _direction; } // escape hatch, see port_resolution.cpp

    // impedance/length/width are intentionally left unscaled here: they're copied verbatim into a
    // resolved PortConfig by port_resolution.cpp, which scales the whole PortConfig exactly once
    // (PortConfig::scaleToSimulationUnits) -- scaling them here too would double-scale.

private:
    friend void to_json(nlohmann::json& j, const InvolvedNetConfig& p);
    friend void from_json(const nlohmann::json& j, InvolvedNetConfig& p);

    NetSelectorKind _kind = NetSelectorKind::Net;
    std::optional<std::string> _netClass;
    std::optional<std::string> _net;
    std::optional<std::string> _footprint;
    std::vector<std::string> _pins;
    double _impedance = 50;
    double _length = 1000;
    std::int32_t _plane = 1;
    std::optional<double> _width;
    std::optional<double> _dBMargin;
    std::optional<double> _direction;
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
};

/// One layer of a resolved board stackup (see libkicad_query::stackup()) -- copper or substrate,
/// already scaled to simulation units.
class LayerConfig {
public:
    /// `thicknessMm` is scaled to simulation units internally; `epsilon` is ignored (left at 0) for
    /// `LayerKind::Metal`. For `LayerKind::Metal`, `file()` is derived from `name` by replacing '.'
    /// with '_' (matching how gerber2ems already names its own Gerber-derived layer files).
    LayerConfig(LayerKind kind, std::string name, double thicknessMm, double epsilon = 0);

    LayerKind kind() const { return _kind; }
    double thickness() const { return _thickness; }
    const std::string& name() const { return _name; }
    const std::string& file() const { return _file; }       // only meaningful when kind() == Metal
    double epsilon() const { return _epsilon; }              // only meaningful when kind() == Substrate

private:
    LayerKind _kind;
    double _thickness = 0;
    std::string _name;
    std::string _file;
    double _epsilon = 0;
};

/// Frequency config.
class Frequency {
public:
    double start() const { return _start; }
    double stop() const { return _stop; }

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
    double fillingEpsilon() const { return _fillingEpsilon; }

    void scaleToSimulationUnits(std::int32_t unitMultiplier);

private:
    friend void to_json(nlohmann::json& j, const Via& v);
    friend void from_json(const nlohmann::json& j, Via& v);

    double _platingThickness = 50;
    double _fillingEpsilon = 1;
};

void to_json(nlohmann::json& j, const Via& v);
void from_json(const nlohmann::json& j, Via& v);

/// Margin config (how far outside area of interest should grid span).
class Margin {
public:
    double xy() const { return _xy; }
    double z() const { return _z; }
    bool fromTrace() const { return _fromTrace; }

    void scaleToSimulationUnits(std::int32_t unitMultiplier);

private:
    friend void to_json(nlohmann::json& j, const Margin& m);
    friend void from_json(const nlohmann::json& j, Margin& m);

    double _xy = 1500;
    double _z = 2000;
    bool _fromTrace = true;
};

void to_json(nlohmann::json& j, const Margin& m);
void from_json(const nlohmann::json& j, Margin& m);

/// Cell Ratio config (Optimal scaling between neighboring grid cell sizes).
class CellRatio {
public:
    double xy() const { return _xy; }
    double z() const { return _z; }

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
    double optimal() const { return _optimal; }
    double diagonal() const { return _diagonal; }
    double perpendicular() const { return _perpendicular; }
    double max() const { return _max; }
    const Margin& margin() const { return _margin; }
    const CellRatio& cellRatio() const { return _cellRatio; }

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
    const std::vector<InvolvedNetConfig>& involvedNets() const { return _involvedNets; }
    const GroundNetConfig& groundNet() const { return _groundNet; }

    double hullPadding() const { return _hullPadding; }
    double viaEdgeDistance() const { return _viaEdgeDistance; }
    double viaSpacing() const { return _viaSpacing; }

    std::vector<ExcitationConfig>& excitations() { return _excitations; }
    const std::vector<ExcitationConfig>& excitations() const { return _excitations; }
    std::vector<SingleEndedConfig>& traces() { return _traces; }
    const std::vector<SingleEndedConfig>& traces() const { return _traces; }
    std::vector<DifferentialPairConfig>& diffPairs() { return _diffPairs; }
    const std::vector<DifferentialPairConfig>& diffPairs() const { return _diffPairs; }

    std::vector<PortConfig>& ports() { return _ports; }
    const std::vector<PortConfig>& ports() const { return _ports; }

    /// Every net name resolved from involvedNets() (populated once by resolveSimulationPorts(),
    /// alongside ports()) -- cached here so grid_gen.cpp's mesh-density hint doesn't need to
    /// re-resolve net_class/footprint+pin entries via another libkicad_query round trip.
    std::vector<std::string>& resolvedNets() { return _resolvedNets; }
    const std::vector<std::string>& resolvedNets() const { return _resolvedNets; }

    /// Scales hullPadding/viaEdgeDistance/viaSpacing into simulation units. Resolved ports scale
    /// themselves individually (PortConfig::scaleToSimulationUnits, called by port_resolution.cpp)
    /// -- this does not touch ports() or involvedNets(), which either aren't populated yet at
    /// config-load time or are copied verbatim into a PortConfig later (see InvolvedNetConfig).
    void scaleToSimulationUnits(std::int32_t unitMultiplier);

private:
    friend void to_json(nlohmann::json& j, const SimulationConfig& p);
    friend void from_json(const nlohmann::json& j, SimulationConfig& p);

    std::string _name;
    std::vector<InvolvedNetConfig> _involvedNets;
    GroundNetConfig _groundNet;
    double _hullPadding = 2000;
    double _viaEdgeDistance = 300;
    double _viaSpacing = 500;
    std::vector<ExcitationConfig> _excitations;
    std::vector<SingleEndedConfig> _traces;
    std::vector<DifferentialPairConfig> _diffPairs;

    std::vector<PortConfig> _ports;         // not (de)serialized, populated by resolveSimulationPorts()
    std::vector<std::string> _resolvedNets; // not (de)serialized, populated by resolveSimulationPorts()
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
};

/// Parsed simulation.json configuration, plus the stackup imported into it separately (see
/// loadStackup()). A plain value type: every caller holds and threads it explicitly rather than
/// reaching into shared global state, so multiple EMSConfigs (e.g. for different boards) can
/// coexist safely in the same process.
class EMSConfig {
public:
    /// Parses `cfgPath`. If updateConfig is true and no file exists at cfgPath, creates a stub, and
    /// afterwards rewrites the file with any missing fields filled in (mirrors the CLI's
    /// --update-config behavior).
    static std::expected<EMSConfig, std::string> parse(const std::filesystem::path& cfgPath, bool updateConfig);

    /// Replaces layers() with `layers` (already resolved by the caller from the live board via
    /// libkicad_query::stackup() -- see importer.cpp's importStackup()).
    void loadStackup(std::vector<LayerConfig> layers);

    const std::string& formatVersion() const { return _formatVersion; }

    const std::vector<SimulationConfig>& simulations() const { return _simulations; }
    std::vector<SimulationConfig>& simulations() { return _simulations; }

    const Frequency& frequency() const { return _frequency; }
    std::int32_t maxSteps() const { return _maxSteps; }
    /// Copper-geometry fidelity control, in microns: the maximum chord/sagitta deviation allowed
    /// when tessellating curves (arcs, round pads/vias) into straight polygon edges, and the
    /// point-simplification tolerance applied to the resulting copper regions before triangulation.
    /// Smaller values produce more accurate (and more finely triangulated) curved geometry. Named
    /// "pixel_size" in config JSON for backwards compatibility: this used to be the raster DPI
    /// control for the tool's old gerbv-based rendering pipeline, which the same fidelity/cost
    /// trade-off maps onto directly now that geometry is reconstructed as vectors instead.
    std::int32_t pixelSize() const { return _pixelSize; }
    const Via& via() const { return _via; }
    const Grid& grid() const { return _grid; }

    const std::vector<LayerConfig>& layers() const { return _layers; }

    std::vector<LayerConfig> getSubstrates() const;
    std::vector<LayerConfig> getMetals() const;

    /// Ordinal index (0-based, counting from the top) of the Metal-kind layer whose LayerConfig::
    /// file() matches `normalizedFileName` (dots already replaced with underscores, matching how
    /// LayerConfig::file() itself is derived from a layer's KiCad name). Used by port_resolution.cpp
    /// to turn a pad's copper layer name into the layer index PortConfig::layer() expects.
    std::optional<std::int32_t> metalLayerIndexForFileName(const std::string& normalizedFileName) const;

private:
    EMSConfig() = default;

    /// Validate grid setting & clamp values (mirrors _Config.__post_init__).
    void _postInit();
    /// Scale distance-valued fields into simulation units (mirrors _Config._apply_unit_multiplier).
    void _applyUnitMultiplier();

    static bool _isCfgVersionInvalid(const std::optional<std::string>& version);

    /// Read config file and load it to a JSON object. If updateConfig is enabled and there is no
    /// config file at the provided path, returns a stub with an empty "simulations" list.
    static nlohmann::json _getCfgJson(const std::filesystem::path& cfgPath, bool updateConfig);

    std::string _formatVersion;
    std::vector<SimulationConfig> _simulations;
    Frequency _frequency;
    std::int32_t _maxSteps = 100000;
    std::int32_t _pixelSize = 5;
    Via _via;
    Grid _grid;

    std::vector<LayerConfig> _layers; // not (de)serialized, populated by loadStackup()
};

} // namespace gerber2ems
