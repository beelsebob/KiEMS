#include "importer.hpp"

#include <cmath>
#include <cstdlib>
#include <fstream>
#include <limits>
#include <map>
#include <regex>
#include <string_view>

#include <spawn.h>
#include <sys/wait.h>
#include <unistd.h>

#include "config.hpp"
#include "constants.hpp"
#include "libkicad_query.hpp"
#include "logging.hpp"

extern char** environ;

namespace gerber2ems {

using namespace gerber2ems::constants;

namespace {

/// Runs `argv[0]` with the given arguments and waits for it to exit, letting its stdout/stderr
/// pass through to ours (unlike gerbv's old invocation, kicad-cli's own diagnostics are useful to
/// the user directly). Uses posix_spawnp (no shell) so filenames never need escaping.
std::int32_t _runProcess(const std::vector<std::string>& args) {
    std::vector<char*> argv;
    argv.reserve(args.size() + 1);
    for (const auto& arg : args) {
        argv.push_back(const_cast<char*>(arg.c_str()));
    }
    argv.push_back(nullptr);

    pid_t pid = 0;
    const int rc = posix_spawnp(&pid, argv[0], nullptr, nullptr, argv.data(), environ);
    if (rc != 0) {
        logError("Failed to spawn process: " + args[0]);
        return -1;
    }
    int status = 0;
    waitpid(pid, &status, 0);
    return WIFEXITED(status) ? static_cast<std::int32_t>(WEXITSTATUS(status)) : -1;
}

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

} // namespace

std::expected<void, std::string> exportKicadPcb(const PathsConfig& paths, const std::filesystem::path& kicadPcbPath) {
    logInfo("Exporting gerbers/drill/position files from " + kicadPcbPath.string() + " via kicad-cli");
    std::filesystem::create_directories(paths.fabDir);

    const std::string pcb = kicadPcbPath.string();
    const std::string fabOut = (paths.fabDir.string() + "/");
    const std::string posOut = (paths.fabDir / "positions-pos.csv").string();
    const std::string kicadCli = paths.kicadCliPath.string();

    const std::int32_t drillStatus =
        _runProcess({kicadCli, "pcb", "export", "drill", "--format", "excellon", "--excellon-separate-th", "-o",
                     fabOut, pcb});
    const std::int32_t gerberStatus = _runProcess({kicadCli, "pcb", "export", "gerbers", "--no-protel-ext",
                                                    "--use-drill-file-origin", "-o", fabOut, pcb});
    const std::int32_t posStatus = _runProcess({kicadCli, "pcb", "export", "pos", "--format", "csv",
                                                 "--use-drill-file-origin", "--units", "mm", "-o", posOut, pcb});

    if (drillStatus != 0 || gerberStatus != 0 || posStatus != 0) {
        return std::unexpected("kicad-cli export failed (drill/gerbers/pos exit codes: " + std::to_string(drillStatus) +
                                "/" + std::to_string(gerberStatus) + "/" + std::to_string(posStatus) + ")");
    }

    // port_resolution.cpp (libkicad-based net/pad queries) needs a board -- and, for net_class
    // involved-net entries, a linked project -- to query, potentially in a later, separate `-g`/
    // `-s`/`-p` invocation than this one. Keep persistent copies rather than requiring `-i` to be
    // repeated on every invocation.
    std::error_code copyEc;
    std::filesystem::copy_file(kicadPcbPath, paths.fabBoardFile, std::filesystem::copy_options::overwrite_existing,
                                copyEc);
    if (copyEc) {
        return std::unexpected("Failed to copy " + kicadPcbPath.string() + " to fab/: " + copyEc.message());
    }
    const std::filesystem::path projectPath = std::filesystem::path(kicadPcbPath).replace_extension(".kicad_pro");
    if (std::filesystem::is_regular_file(projectPath)) {
        std::filesystem::copy_file(projectPath, paths.fabProjectFile, std::filesystem::copy_options::overwrite_existing,
                                    copyEc);
        if (copyEc) {
            return std::unexpected("Failed to copy " + projectPath.string() + " to fab/: " + copyEc.message());
        }
    } else {
        logWarning("No sibling .kicad_pro found for " + kicadPcbPath.string() +
                   "; involved_nets entries using \"net_class\" will fail to resolve");
    }
    return {};
}

std::expected<std::vector<ViaHole>, std::string> getVias(const PathsConfig& paths, double originX, double originY) {
    std::vector<std::filesystem::path> drillFiles = _globSuffix(paths.fabDir, "-PTH.drl");
    if (drillFiles.empty()) {
        return std::unexpected("Couldn't find drill file");
    }

    std::map<std::int32_t, double> drills = {{0, 0.0}};
    std::int32_t currentDrill = 0;
    std::vector<ViaHole> vias;

    static const std::regex drillDefPattern(R"(T([0-9]+)C([0-9]+\.[0-9]+))");
    static const std::regex drillSelectPattern(R"(T([0-9]+))");
    // X/Y both need an optional leading '-' -- Excellon coordinates are relative to the board's
    // auxiliary origin (see PathsConfig's own doc comment on this pipeline's native frame), which
    // sits at a board corner, not necessarily one that keeps every hole's coordinates positive.
    // regex_match requires the *whole* line to match; without the '-' this silently failed (no
    // warning, `regex_match` just returns false) for every hole on the negative side of the
    // origin -- on a real board, that's often most or all of them, dropping their vias entirely.
    static const std::regex holePattern(R"(X(-?[0-9]+\.[0-9]+)Y(-?[0-9]+\.[0-9]+))");
    // G85 "canned slot cycle": a straight drilled cut of the current tool's diameter between two
    // points, with semicircular ends -- how KiCad/Excellon represents an elongated/oblong plated
    // through-hole (e.g. a connector's oblong SHIELD pad), same convention getNPTHHoles() already
    // handles for non-plated ones. holePattern's regex_match alone can never partially match this
    // (it requires matching the *whole* line), so a slot line just silently fell through every
    // check below before this existed -- dropping that via/pad entirely, along with whatever it
    // should have cut out of the substrate (see Simulation::addVia()).
    static const std::regex slotPattern(
        R"(X(-?[0-9]+\.[0-9]+)Y(-?[0-9]+\.[0-9]+)G85X(-?[0-9]+\.[0-9]+)Y(-?[0-9]+\.[0-9]+))");

    auto toSimUnits = [](const std::string& raw) { return std::stod(raw) / 1000 / baseUnit * unitMultiplier; };

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
        if (std::regex_match(line, match, slotPattern)) {
            const auto it = drills.find(currentDrill);
            if (it != drills.end()) {
                ViaHole via;
                via.x = toSimUnits(match[1].str()) - originX;
                via.y = toSimUnits(match[2].str()) - originY;
                via.x2 = toSimUnits(match[3].str()) - originX;
                via.y2 = toSimUnits(match[4].str()) - originY;
                via.diameter = it->second;
                vias.push_back(via);
            } else {
                logWarning("Drill file parsing failed. Drill with specifed number wasn't found");
            }
        } else if (std::regex_match(line, match, holePattern)) {
            const auto it = drills.find(currentDrill);
            if (it != drills.end()) {
                ViaHole via;
                via.x = toSimUnits(match[1].str()) - originX;
                via.y = toSimUnits(match[2].str()) - originY;
                via.x2 = via.x;
                via.y2 = via.y;
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

std::expected<std::vector<NPTHHole>, std::string> getNPTHHoles(const PathsConfig& paths, double originX,
                                                                  double originY) {
    std::vector<std::filesystem::path> drillFiles = _globSuffix(paths.fabDir, "-NPTH.drl");
    if (drillFiles.empty()) {
        return std::vector<NPTHHole>{}; // Plenty of real boards have no mechanical holes at all.
    }

    std::map<std::int32_t, double> drills = {{0, 0.0}};
    std::int32_t currentDrill = 0;
    std::vector<NPTHHole> holes;

    static const std::regex drillDefPattern(R"(T([0-9]+)C([0-9]+\.[0-9]+))");
    static const std::regex drillSelectPattern(R"(T([0-9]+))");
    static const std::regex holePattern(R"(X(-?[0-9]+\.[0-9]+)Y(-?[0-9]+\.[0-9]+))");
    // G85 "canned slot cycle": a straight drilled cut of the current tool's diameter between two
    // points, with semicircular ends -- how KiCad/Excellon represents an elongated/oval hole.
    static const std::regex slotPattern(
        R"(X(-?[0-9]+\.[0-9]+)Y(-?[0-9]+\.[0-9]+)G85X(-?[0-9]+\.[0-9]+)Y(-?[0-9]+\.[0-9]+))");

    auto toSimUnits = [](const std::string& raw) { return std::stod(raw) / 1000 / baseUnit * unitMultiplier; };

    std::ifstream drillFile(drillFiles.front());
    std::string line;
    while (std::getline(drillFile, line)) {
        std::smatch match;
        if (std::regex_match(line, match, drillDefPattern)) {
            drills[std::stoi(match[1].str())] = std::stod(match[2].str()) / 1000 / baseUnit * unitMultiplier;
            continue;
        }
        if (std::regex_match(line, match, drillSelectPattern)) {
            currentDrill = std::stoi(match[1].str());
            continue;
        }
        // Checked before holePattern: regex_match requires the *whole* line, so holePattern alone
        // can never partially match a slot line, but checking the more specific pattern first keeps
        // that obvious rather than relying on that guarantee implicitly.
        if (std::regex_match(line, match, slotPattern)) {
            const auto it = drills.find(currentDrill);
            if (it == drills.end()) {
                logWarning("NPTH drill file parsing failed. Drill with specified number wasn't found");
                continue;
            }
            NPTHHole hole;
            hole.x1 = toSimUnits(match[1].str()) - originX;
            hole.y1 = toSimUnits(match[2].str()) - originY;
            hole.x2 = toSimUnits(match[3].str()) - originX;
            hole.y2 = toSimUnits(match[4].str()) - originY;
            hole.diameter = it->second;
            holes.push_back(hole);
            continue;
        }
        if (std::regex_match(line, match, holePattern)) {
            const auto it = drills.find(currentDrill);
            if (it == drills.end()) {
                logWarning("NPTH drill file parsing failed. Drill with specified number wasn't found");
                continue;
            }
            NPTHHole hole;
            hole.x1 = hole.x2 = toSimUnits(match[1].str()) - originX;
            hole.y1 = hole.y2 = toSimUnits(match[2].str()) - originY;
            hole.diameter = it->second;
            holes.push_back(hole);
        }
    }
    logDebug("Found " + std::to_string(holes.size()) + " NPTH holes");
    return holes;
}

std::expected<void, std::string> importStackup(const PathsConfig& paths, EMSConfig& config) {
    // Queries the live board's own Board Setup > Board Stackup data (via libkicad_query, which
    // shells out to libkicad_smoketest -- see its module comment) rather than a hand-maintained
    // stackup.json: the board file is the actual source of truth, and keeping a second,
    // easily-stale copy of the same data in sync by hand was never anything but a workaround for
    // not having this query available yet. Requires fab/board.kicad_pcb (persisted by
    // exportKicadPcb()), exactly like port_resolution.cpp's own libkicad_query calls.
    auto stackupResult = libkicad_query::stackup(paths, "Reading board stackup");
    if (!stackupResult) {
        return std::unexpected(stackupResult.error());
    }

    std::vector<LayerConfig> layers;
    layers.reserve(stackupResult->size());
    for (const auto& layer : *stackupResult) {
        if (layer.kind == libkicad_query::StackupLayerKind::Copper) {
            layers.emplace_back(LayerKind::Metal, layer.name, layer.thicknessMm);
        } else {
            layers.emplace_back(LayerKind::Substrate, layer.name, layer.thicknessMm, layer.epsilonR,
                                 layer.lossTangent);
        }
    }
    config.loadStackup(std::move(layers));
    return {};
}

} // namespace gerber2ems
