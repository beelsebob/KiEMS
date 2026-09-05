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
    // Not std::getline(stream, field, '\t') in a loop: that silently drops a trailing empty field --
    // getline on an already-exhausted stream at EOF just fails without appending anything, so a line
    // ending right at a tab with nothing after it (e.g. "C89\t1\t", a pad with an empty pin function)
    // would parse as only 2 fields instead of 3, losing that pin entirely at call sites that check
    // fields.size().
    std::vector<std::string> fields;
    std::size_t start = 0;
    while (true) {
        const std::size_t tab = s.find('\t', start);
        if (tab == std::string::npos) {
            fields.push_back(s.substr(start));
            break;
        }
        fields.push_back(s.substr(start, tab - start));
        start = tab + 1;
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

TrackSegment _parseTrackLine(const std::string& line) {
    const std::vector<std::string> fields = _splitTabs(line);
    TrackSegment track;
    track.startXMm = std::stod(fields.at(0));
    track.startYMm = std::stod(fields.at(1));
    track.endXMm = std::stod(fields.at(2));
    track.endYMm = std::stod(fields.at(3));
    track.widthMm = std::stod(fields.at(4));
    track.copperLayerName = fields.at(5);
    return track;
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
    } else if (kind == "soldermask-top") {
        layer.kind = StackupLayerKind::SolderMaskTop;
    } else if (kind == "soldermask-bottom") {
        layer.kind = StackupLayerKind::SolderMaskBottom;
    } else {
        layer.kind = StackupLayerKind::Prepreg;
    }
    layer.name = fields.at(1);
    layer.thicknessMm = std::stod(fields.at(2));
    layer.epsilonR = std::stod(fields.at(3));
    layer.lossTangent = std::stod(fields.at(4));
    return layer;
}

ComponentTriangle _parseComponentTriangleLine(const std::string& line) {
    const std::vector<std::string> fields = _splitTabs(line);
    ComponentTriangle t;
    t.ax = std::stod(fields.at(0));
    t.ay = std::stod(fields.at(1));
    t.az = std::stod(fields.at(2));
    t.bx = std::stod(fields.at(3));
    t.by = std::stod(fields.at(4));
    t.bz = std::stod(fields.at(5));
    t.cx = std::stod(fields.at(6));
    t.cy = std::stod(fields.at(7));
    t.cz = std::stod(fields.at(8));
    t.r = std::stod(fields.at(9));
    t.g = std::stod(fields.at(10));
    t.b = std::stod(fields.at(11));
    t.a = std::stod(fields.at(12));
    return t;
}

PolygonLoop _parsePolygonLoop(const std::vector<std::string>& fields, std::size_t holeIndex) {
    PolygonLoop loop;
    loop.hole = fields.at(holeIndex) == "1";
    loop.pointsMm.reserve(fields.size() - holeIndex - 1);
    for (std::size_t i = holeIndex + 1; i < fields.size(); ++i) {
        const std::size_t comma = fields[i].find(',');
        loop.pointsMm.emplace_back(std::stod(fields[i].substr(0, comma)),
                                   std::stod(fields[i].substr(comma + 1)));
    }
    return loop;
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

std::expected<std::vector<TrackSegment>, std::string> tracksOnNet(const PathsConfig& paths,
                                                                    const std::string& netName,
                                                                    const std::string& context) {
    auto lines = _query(paths, "tracks-on-net", {netName}, context);
    if (!lines) return std::unexpected(std::move(lines).error());
    std::vector<TrackSegment> tracks;
    tracks.reserve(lines->size());
    for (const std::string& line : *lines) {
        tracks.push_back(_parseTrackLine(line));
    }
    return tracks;
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

std::expected<std::vector<PadIdentity>, std::string> allPads(const PathsConfig& paths, const std::string& context) {
    auto lines = _query(paths, "all-pads", {}, context);
    if (!lines) return std::unexpected(std::move(lines).error());
    std::vector<PadIdentity> pads;
    pads.reserve(lines->size());
    for (const std::string& line : *lines) {
        pads.push_back(_parsePadLine(line));
    }
    return pads;
}

std::expected<std::vector<std::pair<std::string, TrackSegment>>, std::string> allTracks(const PathsConfig& paths,
                                                                                          const std::string& context) {
    auto lines = _query(paths, "all-tracks", {}, context);
    if (!lines) return std::unexpected(std::move(lines).error());
    std::vector<std::pair<std::string, TrackSegment>> tracks;
    tracks.reserve(lines->size());
    for (const std::string& line : *lines) {
        const std::vector<std::string> fields = _splitTabs(line);
        TrackSegment track;
        track.startXMm = std::stod(fields.at(1));
        track.startYMm = std::stod(fields.at(2));
        track.endXMm = std::stod(fields.at(3));
        track.endYMm = std::stod(fields.at(4));
        track.widthMm = std::stod(fields.at(5));
        track.copperLayerName = fields.at(6);
        tracks.emplace_back(fields.at(0), std::move(track));
    }
    return tracks;
}

std::expected<std::vector<ZoneGeometry>, std::string> zones(const PathsConfig& paths, const std::string& context) {
    auto lines = _query(paths, "zones", {}, context);
    if (!lines) return std::unexpected(std::move(lines).error());
    std::vector<ZoneGeometry> zones;
    zones.reserve(lines->size());
    for (const std::string& line : *lines) {
        const std::vector<std::string> fields = _splitTabs(line);
        ZoneGeometry zone;
        zone.netName = fields.at(0);
        zone.copperLayerName = fields.at(1);
        zone.outlineMm.reserve(fields.size() - 2);
        for (std::size_t i = 2; i < fields.size(); ++i) {
            const std::size_t comma = fields[i].find(',');
            zone.outlineMm.emplace_back(std::stod(fields[i].substr(0, comma)), std::stod(fields[i].substr(comma + 1)));
        }
        zones.push_back(std::move(zone));
    }
    return zones;
}

std::expected<BoardGeometry, std::string> boardGeometry(const PathsConfig& paths, const std::string& context) {
    auto lines = _query(paths, "board-geometry", {}, context);
    if (!lines) return std::unexpected(std::move(lines).error());

    BoardGeometry geometry;
    for (const std::string& line : *lines) {
        const std::vector<std::string> fields = _splitTabs(line);
        const std::string& kind = fields.at(0);
        if (kind == "outline") {
            geometry.outline.push_back(_parsePolygonLoop(fields, 1));
        } else if (kind == "copper") {
            CopperPolygon polygon;
            polygon.netName = fields.at(1);
            polygon.copperLayerName = fields.at(2);
            polygon.loop = _parsePolygonLoop(fields, 3);
            geometry.copper.push_back(std::move(polygon));
        } else if (kind == "front-mask") {
            geometry.frontMaskOpenings.push_back(_parsePolygonLoop(fields, 1));
        } else if (kind == "back-mask") {
            geometry.backMaskOpenings.push_back(_parsePolygonLoop(fields, 1));
        } else {
            return std::unexpected(context + ": unknown board geometry row: " + kind);
        }
    }
    if (geometry.outline.empty()) {
        return std::unexpected(context + ": board geometry response has no outline");
    }
    return geometry;
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

std::expected<std::vector<LayerColor>, std::string> layerColors(const PathsConfig& paths, const std::string& context) {
    auto lines = _query(paths, "layer-colors", {}, context);
    if (!lines) return std::unexpected(std::move(lines).error());
    std::vector<LayerColor> colors;
    for (const std::string& line : *lines) {
        const std::vector<std::string> fields = _splitTabs(line);
        colors.push_back(LayerColor{.name = fields.at(0), .hex = fields.at(1)});
    }
    return colors;
}

std::expected<std::vector<std::string>, std::string> netClasses(const PathsConfig& paths, const std::string& context) {
    return _query(paths, "net-classes", {}, context);
}

std::expected<std::vector<std::string>, std::string> allNets(const PathsConfig& paths, const std::string& context) {
    return _query(paths, "all-nets", {}, context);
}

std::expected<std::vector<ThroughHole>, std::string> throughHoles(const PathsConfig& paths,
                                                                     const std::string& context) {
    auto lines = _query(paths, "through-holes", {}, context);
    if (!lines) return std::unexpected(std::move(lines).error());
    std::vector<ThroughHole> holes;
    holes.reserve(lines->size());
    for (const std::string& line : *lines) {
        const std::vector<std::string> fields = _splitTabs(line);
        ThroughHole hole;
        hole.footprintRef = fields.at(0);
        hole.padNumber = fields.at(1);
        hole.netName = fields.at(2);
        hole.xMm = std::stod(fields.at(3));
        hole.yMm = std::stod(fields.at(4));
        hole.padWidthMm = std::stod(fields.at(5));
        hole.padHeightMm = std::stod(fields.at(6));
        hole.drillWidthMm = std::stod(fields.at(7));
        hole.drillHeightMm = std::stod(fields.at(8));
        hole.orientationDeg = std::stod(fields.at(9));
        holes.push_back(std::move(hole));
    }
    return holes;
}

std::expected<std::vector<NonPlatedHole>, std::string> nonPlatedHoles(const PathsConfig& paths,
                                                                         const std::string& context) {
    auto lines = _query(paths, "non-plated-holes", {}, context);
    if (!lines) return std::unexpected(std::move(lines).error());
    std::vector<NonPlatedHole> holes;
    holes.reserve(lines->size());
    for (const std::string& line : *lines) {
        const std::vector<std::string> fields = _splitTabs(line);
        holes.push_back(NonPlatedHole{.xMm = std::stod(fields.at(0)),
                                      .yMm = std::stod(fields.at(1)),
                                      .drillWidthMm = std::stod(fields.at(2)),
                                      .drillHeightMm = std::stod(fields.at(3)),
                                      .orientationDeg = std::stod(fields.at(4))});
    }
    return holes;
}

std::expected<ComponentModelExportResult, std::string> exportComponentModels(const PathsConfig& paths,
                                                                                const std::string& componentFilter,
                                                                                const std::string& outputStlPath,
                                                                                const std::string& context) {
    auto lines = _query(paths, "export-component-models", {componentFilter, outputStlPath}, context);
    if (!lines) return std::unexpected(std::move(lines).error());
    // Three explicitly-counted sections, not just newline-delimited to end of stream -- see
    // libkicad_smoketest/main.cpp's own comment on why an implicit boundary between free-text
    // messages and tab-separated triangle rows would be ambiguous.
    if (lines->size() < 3) {
        return std::unexpected(context + ": malformed response from libkicad_smoketest (missing header)");
    }
    std::size_t index = 0;
    ComponentModelExportResult result;
    result.exportSucceeded = lines->at(index++) == "1";
    result.topCopperZMm = std::stod(lines->at(index++));

    const std::size_t messageCount = std::stoul(lines->at(index++));
    if (index + messageCount > lines->size()) {
        return std::unexpected(context + ": malformed response from libkicad_smoketest (truncated messages)");
    }
    result.messages.assign(lines->begin() + static_cast<std::ptrdiff_t>(index),
                            lines->begin() + static_cast<std::ptrdiff_t>(index + messageCount));
    index += messageCount;

    if (index >= lines->size()) {
        return std::unexpected(context + ": malformed response from libkicad_smoketest (missing triangle count)");
    }
    const std::size_t triangleCount = std::stoul(lines->at(index++));
    if (index + triangleCount > lines->size()) {
        return std::unexpected(context + ": malformed response from libkicad_smoketest (truncated triangles)");
    }
    result.triangles.reserve(triangleCount);
    for (std::size_t i = 0; i < triangleCount; ++i) {
        result.triangles.push_back(_parseComponentTriangleLine(lines->at(index + i)));
    }
    return result;
}

std::expected<std::vector<FootprintInfo>, std::string> footprints(const PathsConfig& paths,
                                                                    const std::string& context) {
    auto lines = _query(paths, "footprints", {}, context);
    if (!lines) return std::unexpected(std::move(lines).error());

    // libkicad_smoketest's `footprints` command emits one line per pin
    // (reference\tnumber\tfunction\tvalue\tnetName), with every footprint's pins consecutive (and
    // `value` repeated on each, redundantly, so every line is self-contained) -- group consecutive
    // lines sharing a reference into one FootprintInfo rather than requiring a second round trip
    // per footprint.
    std::vector<FootprintInfo> result;
    for (const std::string& line : *lines) {
        const std::vector<std::string> fields = _splitTabs(line);
        const std::string& reference = fields.at(0);
        if (result.empty() || result.back().reference != reference) {
            const std::string value = fields.size() >= 4 ? fields[3] : "";
            result.push_back(FootprintInfo{reference, value, {}});
        }
        if (fields.size() >= 3 && !fields[1].empty()) {
            const std::string netName = fields.size() >= 5 ? fields[4] : "";
            result.back().pins.push_back(FootprintPin{fields[1], fields[2], netName});
        }
    }
    return result;
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
