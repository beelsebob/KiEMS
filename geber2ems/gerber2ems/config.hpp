// Configuration parsing. Ported from gerber2ems/config.py.
#pragma once

#include <cstdint>
#include <filesystem>
#include <optional>
#include <string>
#include <tuple>
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

/// Class representing and parsing port config.
class PortConfig {
public:
    static PortConfig withName(const std::string& name);

    const std::string& name() const { return _name; }
    void setName(std::string value) { _name = std::move(value); }

    const std::optional<std::pair<double, double>>& position() const { return _position; }
    void setPosition(std::pair<double, double> value) { _position = value; }

    const std::optional<double>& direction() const { return _direction; }
    void setDirection(double value) { _direction = value; }

    double width() const { return _width; }
    double length() const { return _length; }
    double impedance() const { return _impedance; }
    std::int32_t layer() const { return _layer; }
    std::int32_t plane() const { return _plane; }
    double dBMargin() const { return _dBMargin; }

    bool excite() const { return _excite; }
    void setExcite(bool value) { _excite = value; }

    /// Scales width/length into simulation units (mirrors the `*= UNIT_MULTIPLIER` done in
    /// Config.load).
    void scaleToSimulationUnits(std::int32_t unitMultiplier);

private:
    friend void to_json(nlohmann::json& j, const PortConfig& p);
    friend void from_json(const nlohmann::json& j, PortConfig& p);

    std::string _name = "Unnamed";
    std::optional<std::pair<double, double>> _position; // not (de)serialized
    std::optional<double> _direction;                    // not (de)serialized
    double _width = 200;
    double _length = 1000;
    double _impedance = 50;
    std::int32_t _layer = 0;
    std::int32_t _plane = 1;
    double _dBMargin = -15;
    bool _excite = false;
};

void to_json(nlohmann::json& j, const PortConfig& p);
void from_json(const nlohmann::json& j, PortConfig& p);

/// Class representing and parsing differential pair config.
class DifferentialPairConfig {
public:
    std::int32_t startP() const { return _startP; }
    std::int32_t stopP() const { return _stopP; }
    std::int32_t startN() const { return _startN; }
    std::int32_t stopN() const { return _stopN; }
    const std::optional<std::string>& name() const { return _name; }
    const std::vector<std::string>& nets() const { return _nets; }
    bool correct() const { return _correct; }

    /// Validate trace config against the number of defined ports (mirrors __post_init__).
    void postInit(std::int32_t portCount);

private:
    friend void to_json(nlohmann::json& j, const DifferentialPairConfig& p);
    friend void from_json(const nlohmann::json& j, DifferentialPairConfig& p);

    std::int32_t _startP = 0;
    std::int32_t _stopP = 1;
    std::int32_t _startN = 2;
    std::int32_t _stopN = 3;
    std::optional<std::string> _name;
    std::vector<std::string> _nets;
    bool _correct = true; // not (de)serialized
};

void to_json(nlohmann::json& j, const DifferentialPairConfig& p);
void from_json(const nlohmann::json& j, DifferentialPairConfig& p);

/// Class representing and parsing single-ended config.
class SingleEndedConfig {
public:
    std::int32_t start() const { return _start; }
    std::int32_t stop() const { return _stop; }
    const std::optional<std::string>& name() const { return _name; }
    const std::vector<std::string>& nets() const { return _nets; }
    bool correct() const { return _correct; }

    /// Validate trace config against the number of defined ports (mirrors __post_init__).
    void postInit(std::int32_t portCount);

private:
    friend void to_json(nlohmann::json& j, const SingleEndedConfig& p);
    friend void from_json(const nlohmann::json& j, SingleEndedConfig& p);

    std::int32_t _start = 0;
    std::int32_t _stop = 1;
    std::optional<std::string> _name;
    std::vector<std::string> _nets;
    bool _correct = true; // not (de)serialized
};

void to_json(nlohmann::json& j, const SingleEndedConfig& p);
void from_json(const nlohmann::json& j, SingleEndedConfig& p);

enum class LayerKind {
    Substrate,
    Metal,
    Other,
};

/// Class representing and parsing layer config.
class LayerConfig {
public:
    explicit LayerConfig(const nlohmann::json& config);

    LayerKind kind() const { return _kind; }
    double thickness() const { return _thickness; }
    const std::string& name() const { return _name; }
    const std::string& file() const { return _file; }       // only meaningful when kind() == Metal
    double epsilon() const { return _epsilon; }              // only meaningful when kind() == Substrate

private:
    static LayerKind _parseKind(const std::string& kind);

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

/// Config validation and parsing singleton class.
class Config {
public:
    static Config& sharedConfig();

    /// Load config file (default: simulation.json).
    static void load(const Arguments& args);

    /// Load stackup from json object.
    void loadStackup(const nlohmann::json& stackup);

    const std::string& formatVersion() const { return _formatVersion; }

    const std::vector<PortConfig>& ports() const { return _ports; }
    std::vector<PortConfig>& ports() { return _ports; }

    const Frequency& frequency() const { return _frequency; }
    std::int32_t maxSteps() const { return _maxSteps; }
    std::int32_t pixelSize() const { return _pixelSize; }
    const Via& via() const { return _via; }
    const Grid& grid() const { return _grid; }
    const std::vector<SingleEndedConfig>& traces() const { return _traces; }
    const std::vector<DifferentialPairConfig>& diffPairs() const { return _diffPairs; }

    double pcbWidth() const { return _pcbWidth; }
    void setPcbWidth(double value) { _pcbWidth = value; }

    double pcbHeight() const { return _pcbHeight; }
    void setPcbHeight(double value) { _pcbHeight = value; }

    const std::vector<LayerConfig>& layers() const { return _layers; }
    const Arguments& arguments() const { return _arguments; }

    std::vector<LayerConfig> getSubstrates() const;
    std::vector<LayerConfig> getMetals() const;

private:
    Config() = default;

    /// Validate grid setting & clamp values (mirrors _Config.__post_init__).
    void _postInit();
    /// Scale distance-valued fields into simulation units (mirrors _Config._apply_unit_multiplier).
    void _applyUnitMultiplier();

    static bool _isCfgVersionInvalid(const std::optional<std::string>& version);

    /// Read config file and load it to a JSON object.
    ///
    /// If updateConfig is enabled and there is no config file at the provided path, returns a
    /// config stub, auto-populated with ports discovered from `fab/*pos.csv` if none are already
    /// defined.
    static nlohmann::json _getCfgJson(const std::filesystem::path& cfgPath, bool updateConfig);

    std::string _formatVersion;
    std::vector<PortConfig> _ports;
    Frequency _frequency;
    std::int32_t _maxSteps = 100000;
    std::int32_t _pixelSize = 5;
    Via _via;
    Grid _grid;
    std::vector<SingleEndedConfig> _traces;
    std::vector<DifferentialPairConfig> _diffPairs;

    double _pcbWidth = 0;  // not (de)serialized
    double _pcbHeight = 0; // not (de)serialized
    std::vector<LayerConfig> _layers; // not (de)serialized
    Arguments _arguments;             // not (de)serialized
};

/// Parse a KiCad-style pick & place CSV file and return all ports found in it, in the format
/// (port number, (x, y), direction). Also used by the (not yet ported) gerber importer.
std::vector<std::tuple<std::int32_t, std::pair<double, double>, double>> getPortsFromFile(
    const std::filesystem::path& filename);

} // namespace gerber2ems
