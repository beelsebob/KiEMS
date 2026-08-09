#include "importer.hpp"

#include <cmath>
#include <cstdlib>
#include <fstream>
#include <limits>
#include <map>
#include <regex>
#include <sstream>
#include <string_view>

#include <spawn.h>
#include <sys/wait.h>
#include <unistd.h>

#include <nlohmann/json.hpp>

#include "config.hpp"
#include "constants.hpp"
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

std::expected<std::vector<ViaHole>, std::string> getVias(const PathsConfig& paths) {
    std::vector<std::filesystem::path> drillFiles = _globSuffix(paths.fabDir, "-PTH.drl");
    if (drillFiles.empty()) {
        return std::unexpected("Couldn't find drill file");
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

std::expected<void, std::string> importStackup(const PathsConfig& paths, EMSConfig& config) {
    // Deliberately not under fab/: everything in fab/ is regenerated wholesale by exportKicadPcb()
    // (kicad-cli's own gerber/drill/pos export), but the stackup has no kicad-cli export equivalent
    // -- it's user-maintained (exported by hand from KiCad's Board Setup > Board Stackup dialog),
    // so it lives beside simulation.json instead, alongside the other input the user controls.
    std::ifstream file(paths.stackupFile);
    if (!file.is_open()) {
        return std::unexpected("Couldn't open stackup file: " + paths.stackupFile.string());
    }
    nlohmann::json stackup;
    try {
        file >> stackup;
    } catch (const nlohmann::json::parse_error& error) {
        return std::unexpected(std::string("JSON decoding failed: ") + error.what());
    }

    const std::string ver = stackup.value("format_version", std::string());
    const std::vector<std::string> verParts = _splitDot(ver);
    const std::vector<std::string> stackupParts = _splitDot(std::string(stackupFormatVersion));

    const bool ok = !ver.empty() && verParts.size() >= 2 && stackupParts.size() >= 2 && verParts[0] == stackupParts[0] &&
                    verParts[1] >= stackupParts[1]; // mirrors the Python source's string comparison
    if (!ok) {
        return std::unexpected("Stackup format (" + ver + ") is not supported (supported: " +
                                std::string(stackupFormatVersion) + ")");
    }
    config.loadStackup(stackup);
    return {};
}

} // namespace gerber2ems
