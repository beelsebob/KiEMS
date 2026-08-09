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

#include "logging.hpp"

extern char** environ;

namespace gerber2ems::libkicad_query {

namespace {

struct _SubprocessResult {
    std::int32_t exitCode = -1;
    std::string stdOut;
    std::string stdErr;
};

/// Runs `args[0]` with the given arguments, capturing its stdout/stderr rather than letting them
/// pass through (unlike importer.cpp's _runProcess, which is used for kicad-cli's own
/// user-facing diagnostics instead).
std::expected<_SubprocessResult, std::string> _runCapturing(const std::vector<std::string>& args) {
    std::array<int, 2> stdoutPipe{};
    std::array<int, 2> stderrPipe{};
    if (pipe(stdoutPipe.data()) != 0 || pipe(stderrPipe.data()) != 0) {
        return std::unexpected("Failed to create pipes for subprocess: " + args[0]);
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
        return std::unexpected("Failed to spawn process: " + args[0]);
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

std::expected<std::vector<std::string>, std::string> _query(const PathsConfig& paths, const std::string& command,
                                                              const std::vector<std::string>& args,
                                                              const std::string& context) {
    std::vector<std::string> fullArgs = {paths.kicadQueryHelperPath.string(), command,
                                          paths.fabProjectFile.string(), paths.fabBoardFile.string()};
    fullArgs.insert(fullArgs.end(), args.begin(), args.end());

    auto result = _runCapturing(fullArgs);
    if (!result) return std::unexpected(std::move(result).error());
    if (result->exitCode != 0) {
        return std::unexpected(context + ": " + _rstrip(result->stdErr));
    }
    return _splitLines(result->stdOut);
}

StackupLayer _parseStackupLine(const std::string& line) {
    const std::vector<std::string> fields = _splitTabs(line);
    StackupLayer layer;
    const std::string& kind = fields.at(0);
    if (kind == "copper") {
        layer.kind = StackupLayerKind::Copper;
    } else if (kind == "core") {
        layer.kind = StackupLayerKind::Core;
    } else {
        layer.kind = StackupLayerKind::Prepreg;
    }
    layer.name = fields.at(1);
    layer.thicknessMm = std::stod(fields.at(2));
    layer.epsilonR = std::stod(fields.at(3));
    return layer;
}

} // namespace

std::expected<std::string, std::string> netForFootprintPin(const PathsConfig& paths, const std::string& footprint,
                                                             const std::string& pin, const std::string& context) {
    auto lines = _query(paths, "net-for-pin", {footprint, pin}, context);
    if (!lines) return std::unexpected(std::move(lines).error());
    if (lines->empty()) {
        return std::unexpected(context + ": empty response from libkicad_smoketest");
    }
    return lines->front();
}

std::expected<std::vector<std::string>, std::string> netsInNetClass(const PathsConfig& paths,
                                                                      const std::string& netClassName,
                                                                      const std::string& context) {
    return _query(paths, "nets-in-class", {netClassName}, context);
}

std::expected<std::vector<PadIdentity>, std::string> padsOnNet(const PathsConfig& paths, const std::string& netName,
                                                                 const std::string& context) {
    auto lines = _query(paths, "pads-on-net", {netName}, context);
    if (!lines) return std::unexpected(std::move(lines).error());
    std::vector<PadIdentity> pads;
    for (const std::string& line : *lines) {
        pads.push_back(_parsePadLine(line));
    }
    return pads;
}

std::expected<PadIdentity, std::string> resolvePin(const PathsConfig& paths, const std::string& footprint,
                                                     const std::string& pin, const std::string& context) {
    auto lines = _query(paths, "resolve-pin", {footprint, pin}, context);
    if (!lines) return std::unexpected(std::move(lines).error());
    if (lines->empty()) {
        return std::unexpected(context + ": empty response from libkicad_smoketest");
    }
    return _parsePadLine(lines->front());
}

std::expected<std::vector<StackupLayer>, std::string> stackup(const PathsConfig& paths, const std::string& context) {
    auto lines = _query(paths, "stackup", {}, context);
    if (!lines) return std::unexpected(std::move(lines).error());
    std::vector<StackupLayer> layers;
    for (const std::string& line : *lines) {
        layers.push_back(_parseStackupLine(line));
    }
    return layers;
}

std::expected<std::vector<std::string>, std::string> resolveInvolvedNetNames(const PathsConfig& paths,
                                                                               const InvolvedNetConfig& entry) {
    switch (entry.kind()) {
        case NetSelectorKind::Net:
            return std::vector<std::string>{*entry.net()};
        case NetSelectorKind::NetClass:
            return netsInNetClass(paths, *entry.netClass(), "Resolving net_class \"" + *entry.netClass() + "\"");
        case NetSelectorKind::FootprintPin: {
            std::vector<std::string> nets;
            for (const std::string& pin : entry.pins()) {
                auto net = netForFootprintPin(paths, *entry.footprint(), pin,
                                               "Resolving " + *entry.footprint() + "." + pin);
                if (!net) return std::unexpected(std::move(net).error());
                if (std::find(nets.begin(), nets.end(), *net) == nets.end()) {
                    nets.push_back(std::move(*net));
                }
            }
            return nets;
        }
    }
    return std::vector<std::string>{};
}

std::expected<std::vector<std::string>, std::string> resolveGroundNetNames(const PathsConfig& paths,
                                                                             const GroundNetConfig& ground) {
    switch (ground.kind()) {
        case GroundSelectorKind::Net:
            return std::vector<std::string>{*ground.net()};
        case GroundSelectorKind::NetClass:
            return netsInNetClass(paths, *ground.netClass(),
                                   "Resolving ground_net's net_class \"" + *ground.netClass() + "\"");
    }
    return std::vector<std::string>{};
}

} // namespace gerber2ems::libkicad_query
