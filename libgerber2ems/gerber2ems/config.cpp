#include "config.hpp"

#include <algorithm>
#include <cmath>
#include <cstdlib>
#include <fstream>
#include <sstream>
#include <stdexcept>

#include "constants.hpp"
#include "logging.hpp"

namespace gerber2ems {

namespace {

std::vector<std::string> _splitDot(const std::string& s) {
    std::vector<std::string> parts;
    std::stringstream ss(s);
    std::string part;
    while (std::getline(ss, part, '.')) {
        parts.push_back(part);
    }
    return parts;
}

// Pin identifiers stay std::string internally (KiCad pad "numbers" are frequently alphanumeric --
// BGA designators like "A12", or a schematic pin name like "GND" -- and get passed as plain text to
// the libkicad_smoketest subprocess either way), but a JSON config may write a purely numeric pin
// as a bare integer (e.g. `"pin": 4`) rather than a quoted string, for a more natural-looking
// config. Accept either.
std::string _pinToString(const nlohmann::json& j) {
    if (j.is_string()) {
        return j.get<std::string>();
    }
    if (j.is_number_integer()) {
        return std::to_string(j.get<std::int64_t>());
    }
    throw std::runtime_error("A \"pin\"/\"pins\" entry must be a string (pin name) or integer (pin number), got: " +
                              j.dump());
}

} // namespace

void PortConfig::scaleToSimulationUnits(std::int32_t unitMultiplier) {
    _width *= unitMultiplier;
    _length *= unitMultiplier;
}

void to_json(nlohmann::json& j, const PortRef& p) { j = nlohmann::json{{"footprint", p._footprint}, {"pin", p._pin}}; }

void from_json(const nlohmann::json& j, PortRef& p) {
    p._footprint = j.at("footprint").get<std::string>();
    p._pin = _pinToString(j.at("pin"));
}

void to_json(nlohmann::json& j, const ExcludedPin& p) {
    j = nlohmann::json{{"footprint", p.footprint}, {"pin", p.pin}};
}

void from_json(const nlohmann::json& j, ExcludedPin& p) {
    p.footprint = j.at("footprint").get<std::string>();
    p.pin = _pinToString(j.at("pin"));
}

void to_json(nlohmann::json& j, const PinDirectionOverride& p) {
    j = nlohmann::json{{"footprint", p.footprint}, {"pin", p.pin}, {"direction", p.direction}};
}

void from_json(const nlohmann::json& j, PinDirectionOverride& p) {
    p.footprint = j.at("footprint").get<std::string>();
    p.pin = _pinToString(j.at("pin"));
    p.direction = j.at("direction").get<double>();
}

void to_json(nlohmann::json& j, const InvolvedNetConfig& p) {
    switch (p._kind) {
        case NetSelectorKind::NetClass:
            j = nlohmann::json{{"net_class", *p._netClass}};
            break;
        case NetSelectorKind::Net:
            j = nlohmann::json{{"net", *p._net}};
            break;
        case NetSelectorKind::FootprintPin:
            j = nlohmann::json{{"footprint", *p._footprint}, {"pins", p._pins}};
            break;
    }
    j["impedance"] = p._impedance;
    j["length"] = p._length;
    j["plane"] = p._plane;
    if (p._width.has_value()) {
        j["width"] = *p._width;
    }
    if (p._dBMargin.has_value()) {
        j["dB_margin"] = *p._dBMargin;
    }
    if (p._direction.has_value()) {
        j["direction"] = *p._direction;
    }
    // Only meaningful (and only ever populated) for a Net-kind entry, but written unconditionally
    // when non-empty regardless of kind -- simpler than special-casing serialization for a field
    // that source-list toggling already guarantees stays empty on any other kind.
    if (!p._excludedPins.empty()) {
        j["excluded_pins"] = p._excludedPins;
    }
    if (!p._pinDirectionOverrides.empty()) {
        j["pin_direction_overrides"] = p._pinDirectionOverrides;
    }
}

void from_json(const nlohmann::json& j, InvolvedNetConfig& p) {
    const InvolvedNetConfig def;
    const bool hasNetClass = j.contains("net_class");
    const bool hasNet = j.contains("net");
    const bool hasFootprint = j.contains("footprint");
    const std::int32_t selectorCount =
        static_cast<std::int32_t>(hasNetClass) + static_cast<std::int32_t>(hasNet) + static_cast<std::int32_t>(hasFootprint);
    if (selectorCount != 1) {
        throw std::runtime_error(
            "involved_nets entry must have exactly one of \"net_class\", \"net\", or \"footprint\"+\"pins\"");
    }

    if (hasNetClass) {
        p._kind = NetSelectorKind::NetClass;
        p._netClass = j.at("net_class").get<std::string>();
    } else if (hasNet) {
        p._kind = NetSelectorKind::Net;
        p._net = j.at("net").get<std::string>();
    } else {
        p._kind = NetSelectorKind::FootprintPin;
        p._footprint = j.at("footprint").get<std::string>();
        p._pins.clear();
        if (j.contains("pins")) {
            for (const auto& pin : j.at("pins")) {
                p._pins.push_back(_pinToString(pin));
            }
        }
        if (p._pins.empty()) {
            throw std::runtime_error("involved_nets entry for footprint \"" + *p._footprint + "\" has no \"pins\"");
        }
    }

    p._impedance = j.value("impedance", def._impedance);
    p._length = j.value("length", def._length);
    p._plane = j.value("plane", def._plane);
    if (j.contains("width")) {
        p._width = j.at("width").get<double>();
    }
    if (j.contains("dB_margin")) {
        p._dBMargin = j.at("dB_margin").get<double>();
    }
    if (j.contains("direction")) {
        p._direction = j.at("direction").get<double>();
    }
    p._excludedPins.clear();
    if (j.contains("excluded_pins")) {
        for (const auto& excluded : j.at("excluded_pins")) {
            p._excludedPins.push_back(excluded.get<ExcludedPin>());
        }
    }
    p._pinDirectionOverrides.clear();
    if (j.contains("pin_direction_overrides")) {
        for (const auto& override : j.at("pin_direction_overrides")) {
            p._pinDirectionOverrides.push_back(override.get<PinDirectionOverride>());
        }
    }
}

void to_json(nlohmann::json& j, const GroundNetConfig& p) {
    switch (p._kind) {
        case GroundSelectorKind::NetClass:
            j = nlohmann::json{{"net_class", *p._netClass}};
            break;
        case GroundSelectorKind::Net:
            j = nlohmann::json{{"net", *p._net}};
            break;
    }
}

void from_json(const nlohmann::json& j, GroundNetConfig& p) {
    const bool hasNetClass = j.contains("net_class");
    const bool hasNet = j.contains("net");
    if (static_cast<std::int32_t>(hasNetClass) + static_cast<std::int32_t>(hasNet) != 1) {
        throw std::runtime_error("ground_net must have exactly one of \"net_class\" or \"net\"");
    }
    if (hasNetClass) {
        p._kind = GroundSelectorKind::NetClass;
        p._netClass = j.at("net_class").get<std::string>();
    } else {
        p._kind = GroundSelectorKind::Net;
        p._net = j.at("net").get<std::string>();
    }
}

void to_json(nlohmann::json& j, const ExcitationConfig& p) {
    j = nlohmann::json{
        {"main", p._isMain},
        {"start_time", p._startTime},
        {"duration", p._duration},
        {"phase", p._phaseDegrees},
        {"footprint", p._footprint},
        {"pin", p._pin},
    };
    if (p._frequency.has_value()) {
        j["frequency"] = *p._frequency;
    }
    if (p._amplitude.has_value()) {
        j["amplitude"] = *p._amplitude;
    }
}

void from_json(const nlohmann::json& j, ExcitationConfig& p) {
    const ExcitationConfig def;
    p._isMain = j.value("main", def._isMain);
    p._startTime = j.value("start_time", def._startTime);
    if (j.contains("duration")) {
        p._duration = j.at("duration").get<double>();
    } else if (j.contains("end_time")) {
        p._duration = j.at("end_time").get<double>() - p._startTime;
    } else {
        p._duration = def._duration;
    }
    p._phaseDegrees = j.value("phase", def._phaseDegrees);
    p._footprint = j.at("footprint").get<std::string>();
    p._pin = _pinToString(j.at("pin"));

    if (j.contains("frequency")) {
        p._frequency = j.at("frequency").get<double>();
    }
    if (j.contains("amplitude")) {
        p._amplitude = j.at("amplitude").get<double>();
    }
    if (!p._isMain && (!p._frequency.has_value() || !p._amplitude.has_value())) {
        throw std::runtime_error("Non-main excitation on " + p._footprint + "." + p._pin +
                                  " must specify both \"frequency\" and \"amplitude\"");
    }
}

void DifferentialPairConfig::postInit() {
    if (!_name.has_value()) {
        _name = _startP.footprint() + "." + _startP.pin() + "_" + _stopP.footprint() + "." + _stopP.pin();
    }
    auto check = [&](const char* field, const PortRef& ref) {
        if (!ref.resolvedIndex().has_value()) {
            logWarning("Differential pair " + *_name + " references an unresolved port (" + ref.footprint() + "." +
                       ref.pin() + ") as " + field);
            _correct = false;
        }
    };
    check("start_p", _startP);
    check("stop_p", _stopP);
    check("start_n", _startN);
    check("stop_n", _stopN);
}

void to_json(nlohmann::json& j, const DifferentialPairConfig& p) {
    j = nlohmann::json{
        {"start_p", p._startP},
        {"stop_p", p._stopP},
        {"start_n", p._startN},
        {"stop_n", p._stopN},
        {"name", p._name.has_value() ? nlohmann::json(*p._name) : nlohmann::json(nullptr)},
    };
}

void from_json(const nlohmann::json& j, DifferentialPairConfig& p) {
    p._startP = j.at("start_p").get<PortRef>();
    p._stopP = j.at("stop_p").get<PortRef>();
    p._startN = j.at("start_n").get<PortRef>();
    p._stopN = j.at("stop_n").get<PortRef>();
    if (j.contains("name") && !j.at("name").is_null()) {
        p._name = j.at("name").get<std::string>();
    } else {
        p._name = std::nullopt;
    }
}

void SingleEndedConfig::postInit() {
    if (!_name.has_value()) {
        _name = _start.footprint() + "." + _start.pin() + "_" + _stop.footprint() + "." + _stop.pin();
    }
    auto check = [&](const char* field, const PortRef& ref) {
        if (!ref.resolvedIndex().has_value()) {
            logWarning("Trace " + *_name + " references an unresolved port (" + ref.footprint() + "." + ref.pin() +
                       ") as " + field);
            _correct = false;
        }
    };
    check("start", _start);
    check("stop", _stop);
}

void to_json(nlohmann::json& j, const SingleEndedConfig& p) {
    j = nlohmann::json{
        {"start", p._start},
        {"stop", p._stop},
        {"name", p._name.has_value() ? nlohmann::json(*p._name) : nlohmann::json(nullptr)},
    };
}

void from_json(const nlohmann::json& j, SingleEndedConfig& p) {
    p._start = j.at("start").get<PortRef>();
    p._stop = j.at("stop").get<PortRef>();
    if (j.contains("name") && !j.at("name").is_null()) {
        p._name = j.at("name").get<std::string>();
    } else {
        p._name = std::nullopt;
    }
}

LayerConfig::LayerConfig(LayerKind kind, std::string name, double thicknessMm, double epsilon, double lossTangent)
    : _kind(kind), _thickness(thicknessMm / 1000 / constants::baseUnit * constants::unitMultiplier),
      _name(std::move(name)) {
    if (_kind == LayerKind::Metal) {
        _file = _name;
        std::replace(_file.begin(), _file.end(), '.', '_');
    } else if (_kind == LayerKind::Substrate) {
        _epsilon = epsilon;
        _lossTangent = lossTangent;
    }
}

void to_json(nlohmann::json& j, const Frequency& f) { j = nlohmann::json{{"start", f._start}, {"stop", f._stop}}; }

void from_json(const nlohmann::json& j, Frequency& f) {
    const Frequency def;
    f._start = j.value("start", def._start);
    f._stop = j.value("stop", def._stop);
}

void Via::scaleToSimulationUnits(std::int32_t unitMultiplier) {
    _platingThickness *= unitMultiplier;
    _stitchingViaHoleDiameter *= unitMultiplier;
    _stitchingViaAnnularRingDiameter *= unitMultiplier;
    _viaClearance *= unitMultiplier;
}

void to_json(nlohmann::json& j, const Via& v) {
    j = nlohmann::json{{"plating_thickness", v._platingThickness},
                       {"filling_epsilon", v._fillingEpsilon},
                       {"stitching_via_hole_diameter", v._stitchingViaHoleDiameter},
                       {"stitching_via_annular_ring_diameter", v._stitchingViaAnnularRingDiameter},
                       {"via_clearance", v._viaClearance}};
}

void from_json(const nlohmann::json& j, Via& v) {
    const Via def;
    v._platingThickness = j.value("plating_thickness", def._platingThickness);
    v._fillingEpsilon = j.value("filling_epsilon", def._fillingEpsilon);
    v._stitchingViaHoleDiameter = j.value("stitching_via_hole_diameter", def._stitchingViaHoleDiameter);
    v._stitchingViaAnnularRingDiameter =
        j.value("stitching_via_annular_ring_diameter", def._stitchingViaAnnularRingDiameter);
    v._viaClearance = j.value("via_clearance", def._viaClearance);
}

void Margin::scaleToSimulationUnits(std::int32_t unitMultiplier) {
    _xy *= unitMultiplier;
    _z *= unitMultiplier;
}

void to_json(nlohmann::json& j, const Margin& m) { j = nlohmann::json{{"xy", m._xy}, {"z", m._z}}; }

void from_json(const nlohmann::json& j, Margin& m) {
    const Margin def;
    m._xy = j.value("xy", def._xy);
    m._z = j.value("z", def._z);
    // "from_trace" (a config key that used to control how the mesh's own core extent was
    // determined) is silently ignored, not just dropped -- an old saved simulation.json with it
    // still round-trips fine; see GridGeneratorAxis::compileGrid()'s own doc comment for why that
    // toggle was removed entirely rather than kept as dead config.
}

void to_json(nlohmann::json& j, const CellRatio& c) { j = nlohmann::json{{"xy", c._xy}, {"z", c._z}}; }

void from_json(const nlohmann::json& j, CellRatio& c) {
    const CellRatio def;
    c._xy = j.value("xy", def._xy);
    c._z = j.value("z", def._z);
}

void Grid::applyFrequencyConstraint(double stopFrequencyHz) {
    // min wavelength (in microns)
    const double minWavelength = 3e8 * 1e6 / std::sqrt(4.13) / stopFrequencyHz;
    _max = std::min(static_cast<double>(static_cast<std::int32_t>(minWavelength / 10)), _max);
    _perpendicular = std::min(_perpendicular, _max);
    _diagonal = std::min(_diagonal, _perpendicular);
    _optimal = std::min(_diagonal, _optimal);
}

void Grid::scaleToSimulationUnits(std::int32_t unitMultiplier) {
    _max *= unitMultiplier;
    _diagonal *= unitMultiplier;
    _optimal *= unitMultiplier;
    _perpendicular *= unitMultiplier;
    _margin.scaleToSimulationUnits(unitMultiplier);
}

void to_json(nlohmann::json& j, const Grid& g) {
    j = nlohmann::json{
        {"inter_layers", g._interLayers}, {"optimal", g._optimal},           {"diagonal", g._diagonal},
        {"perpendicular", g._perpendicular}, {"max", g._max}, {"margin", g._margin}, {"cell_ratio", g._cellRatio},
    };
}

void from_json(const nlohmann::json& j, Grid& g) {
    const Grid def;
    g._interLayers = j.value("inter_layers", def._interLayers);
    g._optimal = j.value("optimal", def._optimal);
    g._diagonal = j.value("diagonal", def._diagonal);
    g._perpendicular = j.value("perpendicular", def._perpendicular);
    g._max = j.value("max", def._max);
    g._margin = j.value("margin", def._margin);
    g._cellRatio = j.value("cell_ratio", def._cellRatio);
}

void SimulationConfig::scaleToSimulationUnits(std::int32_t unitMultiplier) {
    _hullPadding *= unitMultiplier;
    _viaEdgeDistance *= unitMultiplier;
    _viaSpacing *= unitMultiplier;
    for (auto& port : _ports) {
        port.scaleToSimulationUnits(unitMultiplier);
    }
}

void to_json(nlohmann::json& j, const SimulationConfig& p) {
    j = nlohmann::json{
        {"name", p._name},
        {"involved_nets", p._involvedNets},
        {"ground_net", p._groundNet},
        {"hull_padding", p._hullPadding},
        {"via_edge_distance", p._viaEdgeDistance},
        {"via_spacing", p._viaSpacing},
        {"excitations", p._excitations},
        {"traces", p._traces},
        {"differential_pairs", p._diffPairs},
    };
}

void from_json(const nlohmann::json& j, SimulationConfig& p) {
    const SimulationConfig def;
    p._name = j.at("name").get<std::string>();
    p._involvedNets = j.value("involved_nets", std::vector<InvolvedNetConfig>{});
    if (p._involvedNets.empty()) {
        throw std::runtime_error("Simulation \"" + p._name + "\" has no involved_nets");
    }
    p._groundNet = j.at("ground_net").get<GroundNetConfig>();
    p._hullPadding = j.value("hull_padding", def._hullPadding);
    p._viaEdgeDistance = j.value("via_edge_distance", def._viaEdgeDistance);
    p._viaSpacing = j.value("via_spacing", def._viaSpacing);
    p._excitations = j.value("excitations", std::vector<ExcitationConfig>{});
    p._traces = j.value("traces", std::vector<SingleEndedConfig>{});
    p._diffPairs = j.value("differential_pairs", std::vector<DifferentialPairConfig>{});
}

void EMSConfig::_postInit() {
    _grid.applyFrequencyConstraint(_frequency.stop());
    _formatVersion = std::string(constants::configFormatVersion);
}

void EMSConfig::_applyUnitMultiplier() {
    _grid.scaleToSimulationUnits(constants::unitMultiplier);
    _via.scaleToSimulationUnits(constants::unitMultiplier);
}

std::vector<LayerConfig> EMSConfig::getSubstrates() const {
    std::vector<LayerConfig> result;
    for (const auto& layer : _layers) {
        if (layer.kind() == LayerKind::Substrate) {
            result.push_back(layer);
        }
    }
    return result;
}

std::vector<LayerConfig> EMSConfig::getMetals() const {
    std::vector<LayerConfig> result;
    for (const auto& layer : _layers) {
        if (layer.kind() == LayerKind::Metal) {
            result.push_back(layer);
        }
    }
    return result;
}

std::optional<std::int32_t> EMSConfig::metalLayerIndexForFileName(const std::string& normalizedFileName) const {
    const std::vector<LayerConfig> metals = getMetals();
    for (std::size_t i = 0; i < metals.size(); ++i) {
        if (metals[i].file() == normalizedFileName) {
            return static_cast<std::int32_t>(i);
        }
    }
    return std::nullopt;
}

void EMSConfig::loadStackup(std::vector<LayerConfig> layers) { _layers = std::move(layers); }

EMSConfig EMSConfig::scaledToSimulationUnits() const {
    EMSConfig scaled = *this;
    scaled._applyUnitMultiplier();
    for (auto& simulation : scaled._simulations) {
        simulation.scaleToSimulationUnits(constants::unitMultiplier);
    }
    return scaled;
}

std::expected<void, std::string> EMSConfig::save(const std::filesystem::path& cfgPath) const {
    nlohmann::json out;
    out["format_version"] = _formatVersion.empty() ? std::string(constants::configFormatVersion) : _formatVersion;
    if (_kicadPcbPath.has_value()) {
        out["kicad_pcb_path"] = _kicadPcbPath->string();
    }
    out["frequency"] = _frequency;
    out["max_steps"] = _maxSteps;
    out["pixel_size"] = _pixelSize;
    out["via"] = _via;
    out["grid"] = _grid;
    out["simulations"] = _simulations;

    std::ofstream file(cfgPath);
    if (!file) {
        return std::unexpected("Couldn't open " + cfgPath.string() + " for writing");
    }
    file << out.dump(4);
    if (!file) {
        return std::unexpected("Failed to write " + cfgPath.string());
    }
    return {};
}

bool EMSConfig::_isCfgVersionInvalid(const std::optional<std::string>& version) {
    if (!version.has_value()) {
        return true;
    }
    const std::vector<std::string> versionParts = _splitDot(*version);
    const std::vector<std::string> currentParts = _splitDot(std::string(constants::configFormatVersion));
    if (versionParts.size() < 2 || currentParts.size() < 2) {
        return true;
    }
    if (versionParts[0] != currentParts[0]) {
        return true;
    }
    // Mirrors the Python source's (likely unintended) lexicographic string comparison.
    return versionParts[1] > currentParts[1];
}

nlohmann::json EMSConfig::_getCfgJson(const std::filesystem::path& cfgPath, bool updateConfig) {
    logInfo("Loading config from " + cfgPath.string());

    if (!std::filesystem::is_regular_file(cfgPath) && updateConfig) {
        std::ofstream touch(cfgPath);
    }

    if (!std::filesystem::is_regular_file(cfgPath)) {
        throw std::runtime_error("Config file doesn't exist: " + cfgPath.string());
    }

    nlohmann::json jsonCfg;
    {
        std::ifstream file(cfgPath);
        std::stringstream buffer;
        buffer << file.rdbuf();
        const std::string content = buffer.str();
        if (!content.empty()) {
            try {
                jsonCfg = nlohmann::json::parse(content);
            } catch (const nlohmann::json::parse_error& error) {
                throw std::runtime_error(std::string("JSON decoding failed: ") + error.what());
            }
        }
    }

    if (jsonCfg.is_null() || (jsonCfg.is_object() && jsonCfg.empty())) {
        jsonCfg = nlohmann::json{{"format_version", std::string(constants::configFormatVersion)}};
    }

    // Ports are always resolved from involved_nets/libkicad now, never guessed from a pick&place
    // CSV -- --update-config just ensures a "simulations" list exists to hand-edit, rather than
    // trying to bootstrap one.
    if (!jsonCfg.contains("simulations")) {
        jsonCfg["simulations"] = nlohmann::json::array();
    }
    return jsonCfg;
}

std::expected<EMSConfig, std::string> EMSConfig::parse(const std::filesystem::path& cfgPath, bool updateConfig) {
    // JSON deserialization failures (malformed syntax, a validation check inside one of this file's
    // from_json hooks) surface as exceptions -- nlohmann::json's own from_json calling convention
    // (invoked implicitly by .get<T>()/.value<T>() below) has no way to return std::expected, so
    // this is the one boundary that converts them into this function's own std::expected contract.
    try {
        EMSConfig self;

        logInfo("Parsing config");
        const nlohmann::json jsonCfg = _getCfgJson(cfgPath, updateConfig);

        const std::optional<std::string> version =
            jsonCfg.contains("format_version") && !jsonCfg.at("format_version").is_null()
                ? std::optional<std::string>(jsonCfg.at("format_version").get<std::string>())
                : std::nullopt;
        if (_isCfgVersionInvalid(version)) {
            throw std::runtime_error("Config format (" + version.value_or("null") +
                                      ") is not supported (supported: " +
                                      std::string(constants::configFormatVersion) + ")");
        }

        self._formatVersion = std::string(constants::configFormatVersion);
        if (jsonCfg.contains("kicad_pcb_path")) {
            self._kicadPcbPath = std::filesystem::path(jsonCfg.at("kicad_pcb_path").get<std::string>());
        }
        self._frequency = jsonCfg.value("frequency", Frequency{});
        self._maxSteps = jsonCfg.value("max_steps", 100000);
        self._pixelSize = jsonCfg.value("pixel_size", 5);
        self._via = jsonCfg.value("via", Via{});
        self._grid = jsonCfg.value("grid", Grid{});

        self._simulations.clear();
        for (const auto& s : jsonCfg.at("simulations")) {
            self._simulations.push_back(s.get<SimulationConfig>());
        }
        // Note: SingleEndedConfig::postInit()/DifferentialPairConfig::postInit() are deliberately NOT
        // called here -- they validate that each PortRef resolved to a real port, which only happens
        // later in resolveSimulationPorts() (port_resolution.cpp), once libkicad has actually resolved
        // this simulation's involved nets into concrete ports. Called from there instead.

        self._postInit();

        if (updateConfig) {
            nlohmann::json out;
            out["format_version"] = self._formatVersion;
            if (self._kicadPcbPath.has_value()) {
                out["kicad_pcb_path"] = self._kicadPcbPath->string();
            }
            out["frequency"] = self._frequency;
            out["max_steps"] = self._maxSteps;
            out["pixel_size"] = self._pixelSize;
            out["via"] = self._via;
            out["grid"] = self._grid;
            out["simulations"] = self._simulations;
            std::ofstream file(cfgPath);
            file << out.dump(4);
        }

        // Deliberately not scaled to simulation units here -- self stays in exactly the units the
        // file uses (an EMSConfig is a document to be edited/saved as much as it's FDTD input now).
        // See EMSConfig::scaledToSimulationUnits(), called at the one boundary that actually needs
        // scaled values (GeometryResult::build()/load()).
        return self;
    } catch (const std::exception& e) {
        return std::unexpected(e.what());
    }
}

} // namespace gerber2ems
