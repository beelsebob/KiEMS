#include "libkicad_query.hpp"

#include <algorithm>
#include <array>
#include <cstdlib>
#include <filesystem>
#include <sstream>
#include <utility>

#include <spawn.h>
#include <sys/wait.h>
#include <unistd.h>

#if defined(__APPLE__)
#include <mach-o/dyld.h>
#endif

#include "constants.hpp"
#include "logging.hpp"

extern char** environ;

namespace gerber2ems::libkicad_query {

namespace {

std::filesystem::path _boardPath() { return std::filesystem::current_path() / constants::fabBoardFile; }
std::filesystem::path _projectPath() { return std::filesystem::current_path() / constants::fabProjectFile; }

/// Absolute path to the currently-running executable's own directory, via the macOS-specific
/// _NSGetExecutablePath API (portable across how this binary itself was invoked -- PATH lookup,
/// relative path, symlink, etc.) -- libkicad_smoketest is always a sibling build product in the
/// same BUILT_PRODUCTS_DIR.
std::filesystem::path _executableDir() {
    std::array<char, 4096> buffer{};
    std::uint32_t size = static_cast<std::uint32_t>(buffer.size());
    if (_NSGetExecutablePath(buffer.data(), &size) != 0) {
        logError("_NSGetExecutablePath: path longer than buffer");
        std::exit(1);
    }
    std::error_code ec;
    const std::filesystem::path resolved = std::filesystem::canonical(buffer.data(), ec);
    return (ec ? std::filesystem::path(buffer.data()) : resolved).parent_path();
}

struct _SubprocessResult {
    std::int32_t exitCode = -1;
    std::string stdOut;
    std::string stdErr;
};

/// Runs `args[0]` with the given arguments, capturing its stdout/stderr rather than letting them
/// pass through (unlike importer.cpp's _runProcess, which is used for kicad-cli's own
/// user-facing diagnostics instead).
_SubprocessResult _runCapturing(const std::vector<std::string>& args) {
    std::array<int, 2> stdoutPipe{};
    std::array<int, 2> stderrPipe{};
    if (pipe(stdoutPipe.data()) != 0 || pipe(stderrPipe.data()) != 0) {
        logError("Failed to create pipes for subprocess: " + args[0]);
        std::exit(1);
    }

    posix_spawn_file_actions_t actions;
    posix_spawn_file_actions_init(&actions);
    posix_spawn_file_actions_adddup2(&actions, stdoutPipe[1], STDOUT_FILENO);
    posix_spawn_file_actions_adddup2(&actions, stderrPipe[1], STDERR_FILENO);
    posix_spawn_file_actions_addclose(&actions, stdoutPipe[0]);
    posix_spawn_file_actions_addclose(&actions, stdoutPipe[1]);
    posix_spawn_file_actions_addclose(&actions, stderrPipe[0]);
    posix_spawn_file_actions_addclose(&actions, stderrPipe[1]);

    std::vector<char*> argv;
    argv.reserve(args.size() + 1);
    for (const auto& arg : args) {
        argv.push_back(const_cast<char*>(arg.c_str()));
    }
    argv.push_back(nullptr);

    pid_t pid = 0;
    const int rc = posix_spawn(&pid, args[0].c_str(), &actions, nullptr, argv.data(), environ);
    posix_spawn_file_actions_destroy(&actions);
    close(stdoutPipe[1]);
    close(stderrPipe[1]);
    if (rc != 0) {
        close(stdoutPipe[0]);
        close(stderrPipe[0]);
        logError("Failed to spawn process: " + args[0]);
        std::exit(1);
    }

    _SubprocessResult result;
    std::array<char, 4096> buffer{};
    ssize_t bytesRead = 0;
    while ((bytesRead = read(stdoutPipe[0], buffer.data(), buffer.size())) > 0) {
        result.stdOut.append(buffer.data(), static_cast<std::size_t>(bytesRead));
    }
    close(stdoutPipe[0]);
    while ((bytesRead = read(stderrPipe[0], buffer.data(), buffer.size())) > 0) {
        result.stdErr.append(buffer.data(), static_cast<std::size_t>(bytesRead));
    }
    close(stderrPipe[0]);

    int status = 0;
    waitpid(pid, &status, 0);
    result.exitCode = WIFEXITED(status) ? static_cast<std::int32_t>(WEXITSTATUS(status)) : -1;
    return result;
}

std::string _rstrip(std::string s) {
    while (!s.empty() && (s.back() == '\n' || s.back() == '\r')) {
        s.pop_back();
    }
    return s;
}

std::vector<std::string> _splitLines(const std::string& s) {
    std::vector<std::string> lines;
    std::istringstream stream(s);
    std::string line;
    while (std::getline(stream, line)) {
        lines.push_back(_rstrip(line));
    }
    return lines;
}

std::vector<std::string> _splitTabs(const std::string& s) {
    std::vector<std::string> fields;
    std::istringstream stream(s);
    std::string field;
    while (std::getline(stream, field, '\t')) {
        fields.push_back(field);
    }
    return fields;
}

PadIdentity _parsePadLine(const std::string& line) {
    const std::vector<std::string> fields = _splitTabs(line);
    PadIdentity pad;
    pad.footprintRef = fields.at(0);
    pad.padNumber = fields.at(1);
    pad.netName = fields.at(2);
    pad.xMm = std::stod(fields.at(3));
    pad.yMm = std::stod(fields.at(4));
    pad.orientationDeg = std::stod(fields.at(5));
    pad.copperLayerName = fields.at(6);
    pad.widthMm = std::stod(fields.at(7));
    pad.heightMm = std::stod(fields.at(8));
    return pad;
}

std::vector<std::string> _query(const std::string& command, const std::vector<std::string>& args,
                                 const std::string& context) {
    std::vector<std::string> fullArgs = {(_executableDir() / "libkicad_smoketest").string(), command,
                                          _projectPath().string(), _boardPath().string()};
    fullArgs.insert(fullArgs.end(), args.begin(), args.end());

    const _SubprocessResult result = _runCapturing(fullArgs);
    if (result.exitCode != 0) {
        logError(context + ": " + _rstrip(result.stdErr));
        std::exit(1);
    }
    return _splitLines(result.stdOut);
}

} // namespace

std::string netForFootprintPin(const std::string& footprint, const std::string& pin, const std::string& context) {
    const std::vector<std::string> lines = _query("net-for-pin", {footprint, pin}, context);
    if (lines.empty()) {
        logError(context + ": empty response from libkicad_smoketest");
        std::exit(1);
    }
    return lines.front();
}

std::vector<std::string> netsInNetClass(const std::string& netClassName, const std::string& context) {
    return _query("nets-in-class", {netClassName}, context);
}

std::vector<PadIdentity> padsOnNet(const std::string& netName, const std::string& context) {
    std::vector<PadIdentity> pads;
    for (const std::string& line : _query("pads-on-net", {netName}, context)) {
        pads.push_back(_parsePadLine(line));
    }
    return pads;
}

PadIdentity resolvePin(const std::string& footprint, const std::string& pin, const std::string& context) {
    const std::vector<std::string> lines = _query("resolve-pin", {footprint, pin}, context);
    if (lines.empty()) {
        logError(context + ": empty response from libkicad_smoketest");
        std::exit(1);
    }
    return _parsePadLine(lines.front());
}

std::vector<std::string> resolveInvolvedNetNames(const InvolvedNetConfig& entry) {
    switch (entry.kind()) {
        case NetSelectorKind::Net:
            return {*entry.net()};
        case NetSelectorKind::NetClass:
            return netsInNetClass(*entry.netClass(), "Resolving net_class \"" + *entry.netClass() + "\"");
        case NetSelectorKind::FootprintPin: {
            std::vector<std::string> nets;
            for (const std::string& pin : entry.pins()) {
                std::string net =
                    netForFootprintPin(*entry.footprint(), pin, "Resolving " + *entry.footprint() + "." + pin);
                if (std::find(nets.begin(), nets.end(), net) == nets.end()) {
                    nets.push_back(std::move(net));
                }
            }
            return nets;
        }
    }
    return {};
}

std::vector<std::string> resolveGroundNetNames(const GroundNetConfig& ground) {
    switch (ground.kind()) {
        case GroundSelectorKind::Net:
            return {*ground.net()};
        case GroundSelectorKind::NetClass:
            return netsInNetClass(*ground.netClass(), "Resolving ground_net's net_class \"" + *ground.netClass() + "\"");
    }
    return {};
}

} // namespace gerber2ems::libkicad_query
