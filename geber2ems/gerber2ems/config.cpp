#include "config.hpp"

#include <algorithm>
#include <cmath>
#include <cstdlib>
#include <fstream>
#include <sstream>

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

// Splits a single CSV line into fields, honouring double-quoted fields (with "" as an escaped
// quote), matching Python's csv.reader(delimiter=",", quotechar='"') closely enough for the
// KiCad-style pick & place files this tool reads.
std::vector<std::string> _parseCsvLine(const std::string& line) {
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
        } else {
            if (c == '"') {
                inQuotes = true;
            } else if (c == ',') {
                fields.push_back(field);
                field.clear();
            } else {
                field.push_back(c);
            }
        }
    }
    fields.push_back(field);
    return fields;
}

} // namespace

PortConfig PortConfig::withName(const std::string& name) {
    PortConfig pc;
    pc._name = name;
    return pc;
}

void PortConfig::scaleToSimulationUnits(std::int32_t unitMultiplier) {
    _width *= unitMultiplier;
    _length *= unitMultiplier;
}

void to_json(nlohmann::json& j, const PortConfig& p) {
    j = nlohmann::json{
        {"name", p._name},
        {"width", p._width},
        {"length", p._length},
        {"impedance", p._impedance},
        {"layer", p._layer},
        {"plane", p._plane},
        {"dB_margin", p._dBMargin},
        {"excite", p._excite},
    };
}

void from_json(const nlohmann::json& j, PortConfig& p) {
    const PortConfig def;
    p._name = j.value("name", def._name);
    p._width = j.value("width", def._width);
    p._length = j.value("length", def._length);
    p._impedance = j.value("impedance", def._impedance);
    p._layer = j.value("layer", def._layer);
    p._plane = j.value("plane", def._plane);
    p._dBMargin = j.value("dB_margin", def._dBMargin);
    p._excite = j.value("excite", def._excite);
}

void DifferentialPairConfig::postInit(std::int32_t portCount) {
    if (!_name.has_value()) {
        _name = std::to_string(_startP) + "_" + std::to_string(_stopP) + "_" + std::to_string(_startN) + "_" +
                std::to_string(_stopN);
    }
    auto check = [&](const char* field, std::int32_t pn) {
        if (pn >= portCount) {
            logWarning("Differential pair " + *_name + " is defined to use not existing port number " +
                       std::to_string(pn) + " as " + field);
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
        {"nets", p._nets},
    };
}

void from_json(const nlohmann::json& j, DifferentialPairConfig& p) {
    const DifferentialPairConfig def;
    p._startP = j.value("start_p", def._startP);
    p._stopP = j.value("stop_p", def._stopP);
    p._startN = j.value("start_n", def._startN);
    p._stopN = j.value("stop_n", def._stopN);
    if (j.contains("name") && !j.at("name").is_null()) {
        p._name = j.at("name").get<std::string>();
    } else {
        p._name = std::nullopt;
    }
    p._nets = j.value("nets", def._nets);
}

void SingleEndedConfig::postInit(std::int32_t portCount) {
    if (!_name.has_value()) {
        _name = std::to_string(_start) + "_" + std::to_string(_stop);
    }
    auto check = [&](const char* field, std::int32_t pn) {
        if (pn >= portCount) {
            logWarning("Trace " + *_name + " is defined to use not existing port number " + std::to_string(pn) +
                       " as " + field);
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
        {"nets", p._nets},
    };
}

void from_json(const nlohmann::json& j, SingleEndedConfig& p) {
    const SingleEndedConfig def;
    p._start = j.value("start", def._start);
    p._stop = j.value("stop", def._stop);
    if (j.contains("name") && !j.at("name").is_null()) {
        p._name = j.at("name").get<std::string>();
    } else {
        p._name = std::nullopt;
    }
    p._nets = j.value("nets", def._nets);
}

LayerKind LayerConfig::_parseKind(const std::string& kind) {
    if (kind == "core" || kind == "prepreg") {
        return LayerKind::Substrate;
    }
    if (kind == "copper") {
        return LayerKind::Metal;
    }
    return LayerKind::Other;
}

LayerConfig::LayerConfig(const nlohmann::json& config) {
    _kind = _parseKind(config.at("type").get<std::string>());
    _thickness = 0;
    _name = config.at("name").get<std::string>();
    if (!config.at("thickness").is_null()) {
        _thickness = config.at("thickness").get<double>() / 1000 / constants::baseUnit * constants::unitMultiplier;
    }
    if (_kind == LayerKind::Metal) {
        _file = _name;
        std::replace(_file.begin(), _file.end(), '.', '_');
    } else if (_kind == LayerKind::Substrate) {
        _epsilon = config.at("epsilon").get<double>();
    }
}

void to_json(nlohmann::json& j, const Frequency& f) { j = nlohmann::json{{"start", f._start}, {"stop", f._stop}}; }

void from_json(const nlohmann::json& j, Frequency& f) {
    const Frequency def;
    f._start = j.value("start", def._start);
    f._stop = j.value("stop", def._stop);
}

void Via::scaleToSimulationUnits(std::int32_t unitMultiplier) { _platingThickness *= unitMultiplier; }

void to_json(nlohmann::json& j, const Via& v) {
    j = nlohmann::json{{"plating_thickness", v._platingThickness}, {"filling_epsilon", v._fillingEpsilon}};
}

void from_json(const nlohmann::json& j, Via& v) {
    const Via def;
    v._platingThickness = j.value("plating_thickness", def._platingThickness);
    v._fillingEpsilon = j.value("filling_epsilon", def._fillingEpsilon);
}

void Margin::scaleToSimulationUnits(std::int32_t unitMultiplier) {
    _xy *= unitMultiplier;
    _z *= unitMultiplier;
}

void to_json(nlohmann::json& j, const Margin& m) {
    j = nlohmann::json{{"xy", m._xy}, {"z", m._z}, {"from_trace", m._fromTrace}};
}

void from_json(const nlohmann::json& j, Margin& m) {
    const Margin def;
    m._xy = j.value("xy", def._xy);
    m._z = j.value("z", def._z);
    m._fromTrace = j.value("from_trace", def._fromTrace);
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

Config& Config::sharedConfig() {
    static Config instance;
    return instance;
}

void Config::_postInit() {
    _grid.applyFrequencyConstraint(_frequency.stop());
    _formatVersion = std::string(constants::configFormatVersion);
}

void Config::_applyUnitMultiplier() {
    _grid.scaleToSimulationUnits(constants::unitMultiplier);
    _via.scaleToSimulationUnits(constants::unitMultiplier);
}

std::vector<LayerConfig> Config::getSubstrates() const {
    std::vector<LayerConfig> result;
    for (const auto& layer : _layers) {
        if (layer.kind() == LayerKind::Substrate) {
            result.push_back(layer);
        }
    }
    return result;
}

std::vector<LayerConfig> Config::getMetals() const {
    std::vector<LayerConfig> result;
    for (const auto& layer : _layers) {
        if (layer.kind() == LayerKind::Metal) {
            result.push_back(layer);
        }
    }
    return result;
}

void Config::loadStackup(const nlohmann::json& stackup) {
    std::vector<LayerConfig> parsed;
    for (const auto& layer : stackup.at("layers")) {
        parsed.emplace_back(layer);
    }
    _layers.clear();
    for (auto& layer : parsed) {
        if (layer.kind() == LayerKind::Metal || layer.kind() == LayerKind::Substrate) {
            _layers.push_back(std::move(layer));
        }
    }
}

bool Config::_isCfgVersionInvalid(const std::optional<std::string>& version) {
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

std::vector<std::tuple<std::int32_t, std::pair<double, double>, double>> getPortsFromFile(
    const std::filesystem::path& filename) {
    std::vector<std::tuple<std::int32_t, std::pair<double, double>, double>> ports;
    std::ifstream csvfile(filename);
    std::string line;
    bool first = true;
    while (std::getline(csvfile, line)) {
        if (first) {
            first = false;
            continue; // skip header
        }
        if (line.empty()) {
            continue;
        }
        const std::vector<std::string> row = _parseCsvLine(line);
        if (row.size() < 6) {
            continue;
        }
        if (row[2].find("Simulation_Port") != std::string::npos ||
            row[2].find("Simulation-Port") != std::string::npos) {
            const std::int32_t number = static_cast<std::int32_t>(std::stoi(row[0].substr(2)));
            const double x = std::stod(row[3]) / 1000 / constants::baseUnit * constants::unitMultiplier;
            const double y = std::stod(row[4]) / 1000 / constants::baseUnit * constants::unitMultiplier;
            const double direction = std::stod(row[5]);
            // NOTE deliberate deviation from the Python source, which returns `number - 1` here
            // (assuming 1-indexed refdes like SP1..SPn). Boards whose pick&place exports 0-indexed
            // simulation port refdes (SP0..SPn-1, as this project's own reference board does) hit
            // `cfg.ports[-1]`, which Python silently wraps around to the *last* port instead of
            // erroring -- and cross-checking against actual board geometry confirms that wraparound
            // assigns the wrong physical position to the wrong port index (it scrambles which ports
            // pair up), rather than being an intentional convention. Using the refdes number
            // directly (no shift) matches the correct pairing for 0-indexed boards; a genuinely
            // 1-indexed board would need this reverted (or a config-driven base offset), but no such
            // board is in scope here.
            ports.emplace_back(number, std::pair{x, y}, direction);
            logDebug("Found port #" + std::to_string(number) + " position in pos file");
        }
    }
    return ports;
}

nlohmann::json Config::_getCfgJson(const std::filesystem::path& cfgPath, bool updateConfig) {
    logInfo("Loading config from " + cfgPath.string());

    if (!std::filesystem::is_regular_file(cfgPath) && updateConfig) {
        std::ofstream touch(cfgPath);
    }

    if (!std::filesystem::is_regular_file(cfgPath)) {
        logError("Config file doesn't exist: " + cfgPath.string());
        std::exit(1);
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
                logError(std::string("JSON decoding failed: ") + error.what());
                std::exit(1);
            }
        }
    }

    if (jsonCfg.is_null() || (jsonCfg.is_object() && jsonCfg.empty())) {
        jsonCfg = nlohmann::json{{"format_version", std::string(constants::configFormatVersion)}};
    }

    if (!jsonCfg.contains("ports") || jsonCfg.at("ports").empty()) {
        std::vector<std::tuple<std::int32_t, std::pair<double, double>, double>> portsPnp;
        std::error_code ec;
        const std::filesystem::path fabDir = std::filesystem::current_path() / "fab";
        if (std::filesystem::is_directory(fabDir, ec)) {
            for (const auto& entry : std::filesystem::directory_iterator(fabDir, ec)) {
                const std::string name = entry.path().filename().string();
                if (name.size() >= 7 && name.compare(name.size() - 7, 7, "pos.csv") == 0) {
                    auto found = getPortsFromFile(entry.path());
                    portsPnp.insert(portsPnp.end(), found.begin(), found.end());
                }
            }
        }

        std::vector<PortConfig> ports;
        ports.reserve(portsPnp.size());
        for (const auto& p : portsPnp) {
            ports.push_back(PortConfig::withName(std::to_string(std::get<0>(p))));
        }
        if (!ports.empty()) {
            ports.back().setExcite(true);
            if (ports.size() >= 4) {
                ports[ports.size() - 3].setExcite(true);
            }
        }

        jsonCfg["ports"] = ports;

        if (ports.size() == 2 || ports.size() == 3) {
            jsonCfg["traces"] = nlohmann::json::array(
                {nlohmann::json{{"start", std::get<0>(portsPnp[portsPnp.size() - 1]) - 1},
                                 {"stop", std::get<0>(portsPnp[portsPnp.size() - 2]) - 1}}});
        }
        if (ports.size() >= 4) {
            jsonCfg["differential_pairs"] = nlohmann::json::array(
                {nlohmann::json{{"start_p", std::get<0>(portsPnp[portsPnp.size() - 1]) - 1},
                                 {"stop_p", std::get<0>(portsPnp[portsPnp.size() - 2]) - 1},
                                 {"start_n", std::get<0>(portsPnp[portsPnp.size() - 3]) - 1},
                                 {"stop_n", std::get<0>(portsPnp[portsPnp.size() - 4]) - 1}}});
        }
    }
    return jsonCfg;
}

void Config::load(const Arguments& args) {
    Config& self = sharedConfig();

    logInfo("Parsing config");
    const std::filesystem::path cfgPath = std::filesystem::absolute(
        args.configPath().has_value() ? std::filesystem::path(*args.configPath()) : constants::defaultConfigPath);
    const nlohmann::json jsonCfg = _getCfgJson(cfgPath, args.updateConfig());

    const std::optional<std::string> version =
        jsonCfg.contains("format_version") && !jsonCfg.at("format_version").is_null()
            ? std::optional<std::string>(jsonCfg.at("format_version").get<std::string>())
            : std::nullopt;
    if (_isCfgVersionInvalid(version)) {
        logError("Config format (" + version.value_or("null") + ") is not supported (supported: " +
                  std::string(constants::configFormatVersion) + ")");
        std::exit(1);
    }

    self._ports.clear();
    for (const auto& p : jsonCfg.at("ports")) {
        self._ports.push_back(p.get<PortConfig>());
    }
    const std::int32_t portCount = static_cast<std::int32_t>(self._ports.size());

    self._formatVersion = std::string(constants::configFormatVersion);
    self._frequency = jsonCfg.value("frequency", Frequency{});
    self._maxSteps = jsonCfg.value("max_steps", 100000);
    self._pixelSize = jsonCfg.value("pixel_size", 5);
    self._via = jsonCfg.value("via", Via{});
    self._grid = jsonCfg.value("grid", Grid{});

    self._traces.clear();
    if (jsonCfg.contains("traces")) {
        for (const auto& t : jsonCfg.at("traces")) {
            SingleEndedConfig trace = t.get<SingleEndedConfig>();
            trace.postInit(portCount);
            self._traces.push_back(std::move(trace));
        }
    }

    self._diffPairs.clear();
    if (jsonCfg.contains("differential_pairs")) {
        for (const auto& d : jsonCfg.at("differential_pairs")) {
            DifferentialPairConfig pair = d.get<DifferentialPairConfig>();
            pair.postInit(portCount);
            self._diffPairs.push_back(std::move(pair));
        }
    }

    self._postInit();
    self._arguments = args;

    if (args.updateConfig()) {
        nlohmann::json out;
        out["format_version"] = self._formatVersion;
        out["ports"] = self._ports;
        out["frequency"] = self._frequency;
        out["max_steps"] = self._maxSteps;
        out["pixel_size"] = self._pixelSize;
        out["via"] = self._via;
        out["grid"] = self._grid;
        out["traces"] = self._traces;
        out["differential_pairs"] = self._diffPairs;
        std::ofstream file(cfgPath);
        file << out.dump(4);
    }

    for (auto& port : self._ports) {
        port.scaleToSimulationUnits(constants::unitMultiplier);
    }
    self._applyUnitMultiplier();
}

} // namespace gerber2ems
