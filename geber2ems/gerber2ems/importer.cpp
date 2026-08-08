#include "importer.hpp"

#include <cmath>
#include <fstream>
#include <limits>
#include <map>
#include <regex>
#include <sstream>
#include <string_view>

#include <nlohmann/json.hpp>

#include "config.hpp"
#include "constants.hpp"
#include "gerber_composite.hpp"
#include "logging.hpp"

namespace gerber2ems {

using namespace gerber2ems::constants;

namespace {

// ---- small filesystem helpers ----

bool _endsWith(const std::string& s, std::string_view suffix) {
    return s.size() >= suffix.size() && s.compare(s.size() - suffix.size(), suffix.size(), suffix) == 0;
}

std::vector<std::filesystem::path> _globSuffix(const std::filesystem::path& dir, std::string_view suffix) {
    std::vector<std::filesystem::path> result;
    std::error_code ec;
    if (!std::filesystem::is_directory(dir, ec)) {
        return result;
    }
    for (const auto& entry : std::filesystem::directory_iterator(dir, ec)) {
        if (_endsWith(entry.path().filename().string(), suffix)) {
            result.push_back(entry.path());
        }
    }
    return result;
}

std::vector<std::string> _splitDot(const std::string& s) {
    std::vector<std::string> parts;
    std::stringstream ss(s);
    std::string part;
    while (std::getline(ss, part, '.')) {
        parts.push_back(part);
    }
    return parts;
}

} // namespace

std::pair<double, double> getDimensions() {
    const std::filesystem::path fabDir = std::filesystem::current_path() / "fab";
    const std::vector<std::filesystem::path> edgeMatches = _globSuffix(fabDir, "Edge_Cuts.gbr");
    if (edgeMatches.empty()) {
        logError("No edge_cuts gerber found");
        std::exit(1);
    }
    const GerberFile edgeCuts(edgeMatches.front());
    double xMin = std::numeric_limits<double>::infinity();
    double xMax = -std::numeric_limits<double>::infinity();
    double yMin = std::numeric_limits<double>::infinity();
    double yMax = -std::numeric_limits<double>::infinity();
    for (const auto& seg : edgeCuts.traceForNet("no-net").segments()) {
        xMin = std::min({seg.start().x(), seg.stop().x(), xMin});
        yMin = std::min({seg.start().y(), seg.stop().y(), yMin});
        xMax = std::max({seg.start().x(), seg.stop().x(), xMax});
        yMax = std::max({seg.start().y(), seg.stop().y(), yMax});
    }
    const double width = xMax - xMin;
    const double height = yMax - yMin;
    logDebug("Board dimensions read from file are: height:" + std::to_string(height) +
             " width:" + std::to_string(width));
    return {width, height};
}

std::vector<Triangle> getTriangles(const std::string& layerFileName) {
    const std::filesystem::path fabDir = std::filesystem::current_path() / "fab";
    const std::string suffix = "-" + layerFileName + ".gbr";
    std::optional<std::filesystem::path> gerberPath;
    std::error_code ec;
    if (std::filesystem::is_directory(fabDir, ec)) {
        for (const auto& entry : std::filesystem::directory_iterator(fabDir, ec)) {
            if (_endsWith(entry.path().filename().string(), suffix)) {
                gerberPath = entry.path();
                break;
            }
        }
    }
    if (!gerberPath.has_value()) {
        logError("Couldn't find gerber file for layer: " + layerFileName);
        std::exit(1);
    }
    return compositeLayerTriangles(*gerberPath);
}

std::vector<ViaHole> getVias() {
    const std::filesystem::path fabDir = std::filesystem::current_path() / "fab";
    std::vector<std::filesystem::path> drillFiles = _globSuffix(fabDir, "-PTH.drl");
    if (drillFiles.empty()) {
        logError("Couldn't find drill file");
        std::exit(1);
    }

    std::map<std::int32_t, double> drills = {{0, 0.0}};
    std::int32_t currentDrill = 0;
    std::vector<ViaHole> vias;

    static const std::regex drillDefPattern(R"(T([0-9]+)C([0-9]+.[0-9]+))");
    static const std::regex drillSelectPattern(R"(T([0-9]+))");
    static const std::regex holePattern(R"(X([0-9]+.[0-9]+)Y([0-9]+.[0-9]+))");

    std::ifstream drillFile(drillFiles.front());
    std::string line;
    while (std::getline(drillFile, line)) {
        std::smatch match;
        if (std::regex_match(line, match, drillDefPattern)) {
            drills[std::stoi(match[1].str())] = std::stod(match[2].str()) / 1000 / baseUnit * unitMultiplier;
        }
        if (std::regex_match(line, match, drillSelectPattern)) {
            currentDrill = std::stoi(match[1].str());
        }
        if (std::regex_match(line, match, holePattern)) {
            const auto it = drills.find(currentDrill);
            if (it != drills.end()) {
                ViaHole via;
                via.x = std::stod(match[1].str()) / 1000 / baseUnit * unitMultiplier;
                via.y = std::stod(match[2].str()) / 1000 / baseUnit * unitMultiplier;
                via.diameter = it->second;
                vias.push_back(via);
            } else {
                logWarning("Drill file parsing failed. Drill with specifed number wasn't found");
            }
        }
    }
    logDebug("Found " + std::to_string(vias.size()) + " vias");
    return vias;
}

void importStackup() {
    const std::filesystem::path filename = "fab/stackup.json";
    std::ifstream file(filename);
    if (!file.is_open()) {
        logError("Couldn't open stackup file: " + filename.string());
        std::exit(1);
    }
    nlohmann::json stackup;
    try {
        file >> stackup;
    } catch (const nlohmann::json::parse_error& error) {
        logError(std::string("JSON decoding failed: ") + error.what());
        std::exit(1);
    }

    const std::string ver = stackup.value("format_version", std::string());
    const std::vector<std::string> verParts = _splitDot(ver);
    const std::vector<std::string> stackupParts = _splitDot(std::string(stackupFormatVersion));

    const bool ok = !ver.empty() && verParts.size() >= 2 && stackupParts.size() >= 2 && verParts[0] == stackupParts[0] &&
                    verParts[1] >= stackupParts[1]; // mirrors the Python source's string comparison
    if (ok) {
        Config::sharedConfig().loadStackup(stackup);
    } else {
        logError("Stackup format (" + ver + ") is not supported (supported: " + std::string(stackupFormatVersion) + ")");
        std::exit(1);
    }
}

void importPortPositions() {
    std::vector<std::tuple<std::int32_t, std::pair<double, double>, double>> ports;
    for (const auto& filename : _globSuffix(std::filesystem::current_path() / "fab", "pos.csv")) {
        auto found = getPortsFromFile(filename);
        ports.insert(ports.end(), found.begin(), found.end());
    }

    for (const auto& [number, position, direction] : ports) {
        // Guards against a negative index (e.g. a board using differently-numbered refdes than
        // expected): rather than replicate Python's `cfg.ports[-1]` wraparound-to-last-port
        // behavior, skip with a warning below via the "not defined on board" pass.
        if (number >= 0 && static_cast<std::int32_t>(Config::sharedConfig().ports().size()) > number) {
            PortConfig& port = Config::sharedConfig().ports()[static_cast<std::size_t>(number)];
            if (!port.position().has_value()) {
                port.setPosition(position);
                port.setDirection(direction);
            } else {
                logWarning("Port #" + std::to_string(number) + " is defined twice on the board. Ignoring the second instance");
            }
        }
    }
    for (std::size_t index = 0; index < Config::sharedConfig().ports().size(); ++index) {
        if (!Config::sharedConfig().ports()[index].position().has_value()) {
            logError("Port #" + std::to_string(index) + " is not defined on board. It will be skipped");
        }
    }
}

} // namespace gerber2ems
