#include <algorithm>
#include <expected>
#include <iomanip>
#include <iostream>
#include <sstream>
#include <string>
#include <vector>

#include "../libkicad/libkicad.hpp"

namespace {

// Enough significant digits to round-trip a double exactly through text.
std::string _formatDouble(double value) {
    std::ostringstream oss;
    oss << std::setprecision(17) << value;
    return oss.str();
}

void _printPad(const libkicad::PadPosition& pad) {
    std::cout << pad.footprintRef << '\t' << pad.padNumber << '\t' << pad.netName << '\t' << _formatDouble(pad.xMm)
               << '\t' << _formatDouble(pad.yMm) << '\t' << _formatDouble(pad.orientationDeg) << '\t'
               << pad.copperLayerName << '\t' << _formatDouble(pad.widthMm) << '\t' << _formatDouble(pad.heightMm)
               << '\n';
}

std::string _stackupLayerKindName(libkicad::StackupLayerKind kind) {
    switch (kind) {
        case libkicad::StackupLayerKind::Copper:
            return "copper";
        case libkicad::StackupLayerKind::Core:
            return "core";
        case libkicad::StackupLayerKind::Prepreg:
            return "prepreg";
        case libkicad::StackupLayerKind::SolderMaskTop:
            return "soldermask-top";
        case libkicad::StackupLayerKind::SolderMaskBottom:
            return "soldermask-bottom";
    }
    return "unknown";
}

void _printStackupLayer(const libkicad::StackupLayer& layer) {
    std::cout << _stackupLayerKindName(layer.kind) << '\t' << layer.name << '\t' << _formatDouble(layer.thicknessMm)
               << '\t' << _formatDouble(layer.epsilonR) << '\t' << _formatDouble(layer.lossTangent) << '\n';
}

// One line per pin (not one line per footprint): the caller groups by the reference column, same
// as every other line-oriented query here -- keeps the wire format flat regardless of how many
// pins a footprint has. `value` is repeated on every one of a footprint's lines (redundant, but
// keeps every line self-contained rather than making the caller special-case the first one).
// Columns: reference, pad number, pin function, footprint value, net name (net name empty if the
// pad isn't connected to any net).
void _printFootprints(const std::vector<libkicad::FootprintInfo>& footprints) {
    for (const libkicad::FootprintInfo& footprint : footprints) {
        if (footprint.pins.empty()) {
            std::cout << footprint.reference << "\t\t\t" << footprint.value << "\t\n";
            continue;
        }
        for (const libkicad::FootprintPin& pin : footprint.pins) {
            std::cout << footprint.reference << '\t' << pin.number << '\t' << pin.function << '\t' << footprint.value
                       << '\t' << pin.netName << '\n';
        }
    }
}

// Machine-readable query mode used by port_resolution.cpp (invoked as a subprocess, exactly like
// this project already invokes kicad-cli -- see importer.cpp's _runProcess). libkicad pulls in
// KiCad's own wx/protobuf/abseil/OpenCASCADE dependency chain, including a *different* build of
// Clipper2 than the one geber2ems links directly (Homebrew's, vs. KiCad's own bundled copy) --
// linking libkicad straight into the main geber2ems executable would risk duplicate-symbol errors
// between the two Clipper2 builds. A subprocess keeps the two dependency worlds fully separate.
// Output on success is line-oriented plain text (tab-separated for multi-field rows); on failure,
// an error message goes to stderr and the process exits 1. No JSON library is linked into either
// binary purely for this.
int _runQuery(int argc, char** argv) {
    const std::string command = argv[1];

    if (command == "net-for-pin" && argc == 6) {
        const std::expected<std::string, std::string> net = libkicad::netForFootprintPin(argv[2], argv[3], argv[4], argv[5]);
        if (!net.has_value()) {
            std::cerr << net.error() << "\n";
            return 1;
        }
        std::cout << *net << "\n";
        return 0;
    }

    if (command == "nets-in-class" && argc == 5) {
        const std::expected<std::vector<std::string>, std::string> nets = libkicad::netsInNetClass(argv[2], argv[3], argv[4]);
        if (!nets.has_value()) {
            std::cerr << nets.error() << "\n";
            return 1;
        }
        for (const std::string& net : *nets) {
            std::cout << net << "\n";
        }
        return 0;
    }

    if (command == "pads-on-net" && argc == 5) {
        const std::expected<std::vector<libkicad::PadPosition>, std::string> pads = libkicad::padsOnNet(argv[2], argv[3], argv[4]);
        if (!pads.has_value()) {
            std::cerr << pads.error() << "\n";
            return 1;
        }
        for (const libkicad::PadPosition& pad : *pads) {
            _printPad(pad);
        }
        return 0;
    }

    if (command == "tracks-on-net" && argc == 5) {
        const std::expected<std::vector<libkicad::TrackSegment>, std::string> tracks =
            libkicad::tracksOnNet(argv[2], argv[3], argv[4]);
        if (!tracks.has_value()) {
            std::cerr << tracks.error() << "\n";
            return 1;
        }
        for (const libkicad::TrackSegment& track : *tracks) {
            std::cout << _formatDouble(track.startXMm) << '\t' << _formatDouble(track.startYMm) << '\t'
                      << _formatDouble(track.endXMm) << '\t' << _formatDouble(track.endYMm) << '\t'
                      << _formatDouble(track.widthMm) << '\t' << track.copperLayerName << '\n';
        }
        return 0;
    }

    if (command == "all-pads" && argc == 4) {
        const std::expected<std::vector<libkicad::PadPosition>, std::string> pads = libkicad::allPads(argv[2], argv[3]);
        if (!pads.has_value()) {
            std::cerr << pads.error() << "\n";
            return 1;
        }
        for (const libkicad::PadPosition& pad : *pads) {
            _printPad(pad);
        }
        return 0;
    }

    if (command == "all-tracks" && argc == 4) {
        const std::expected<std::vector<std::pair<std::string, libkicad::TrackSegment>>, std::string> tracks =
            libkicad::allTracks(argv[2], argv[3]);
        if (!tracks.has_value()) {
            std::cerr << tracks.error() << "\n";
            return 1;
        }
        for (const auto& [netName, track] : *tracks) {
            std::cout << netName << '\t' << _formatDouble(track.startXMm) << '\t' << _formatDouble(track.startYMm)
                       << '\t' << _formatDouble(track.endXMm) << '\t' << _formatDouble(track.endYMm) << '\t'
                       << _formatDouble(track.widthMm) << '\t' << track.copperLayerName << '\n';
        }
        return 0;
    }

    if (command == "zones" && argc == 4) {
        const std::expected<std::vector<libkicad::ZoneInfo>, std::string> zones = libkicad::zones(argv[2], argv[3]);
        if (!zones.has_value()) {
            std::cerr << zones.error() << "\n";
            return 1;
        }
        for (const libkicad::ZoneInfo& zone : *zones) {
            std::cout << zone.netName << '\t' << zone.copperLayerName;
            for (const auto& [x, y] : zone.outlineMm) {
                std::cout << '\t' << _formatDouble(x) << ',' << _formatDouble(y);
            }
            std::cout << '\n';
        }
        return 0;
    }

    if (command == "resolve-pin" && argc == 6) {
        const std::expected<libkicad::PadPosition, std::string> pad = libkicad::resolvePin(argv[2], argv[3], argv[4], argv[5]);
        if (!pad.has_value()) {
            std::cerr << pad.error() << "\n";
            return 1;
        }
        _printPad(*pad);
        return 0;
    }

    if (command == "stackup" && argc == 4) {
        const std::expected<std::vector<libkicad::StackupLayer>, std::string> layers =
                libkicad::stackup(argv[2], argv[3]);
        if (!layers.has_value()) {
            std::cerr << layers.error() << "\n";
            return 1;
        }
        for (const libkicad::StackupLayer& layer : *layers) {
            _printStackupLayer(layer);
        }
        return 0;
    }

    if (command == "layer-colors" && argc == 4) {
        const std::expected<std::vector<libkicad::LayerColor>, std::string> colors =
                libkicad::layerColors(argv[2], argv[3]);
        if (!colors.has_value()) {
            std::cerr << colors.error() << "\n";
            return 1;
        }
        for (const libkicad::LayerColor& color : *colors) {
            std::cout << color.name << '\t' << color.hex << "\n";
        }
        return 0;
    }

    if (command == "net-classes" && argc == 4) {
        const std::expected<std::vector<std::string>, std::string> classes = libkicad::netClasses(argv[2], argv[3]);
        if (!classes.has_value()) {
            std::cerr << classes.error() << "\n";
            return 1;
        }
        for (const std::string& name : *classes) {
            std::cout << name << "\n";
        }
        return 0;
    }

    if (command == "all-nets" && argc == 4) {
        const std::expected<std::vector<std::string>, std::string> nets = libkicad::allNets(argv[2], argv[3]);
        if (!nets.has_value()) {
            std::cerr << nets.error() << "\n";
            return 1;
        }
        for (const std::string& name : *nets) {
            std::cout << name << "\n";
        }
        return 0;
    }

    if (command == "footprints" && argc == 4) {
        const std::expected<std::vector<libkicad::FootprintInfo>, std::string> footprints =
                libkicad::footprints(argv[2], argv[3]);
        if (!footprints.has_value()) {
            std::cerr << footprints.error() << "\n";
            return 1;
        }
        _printFootprints(*footprints);
        return 0;
    }

    if (command == "through-holes" && argc == 4) {
        const std::expected<std::vector<libkicad::ThroughHole>, std::string> holes =
                libkicad::throughHoles(argv[2], argv[3]);
        if (!holes.has_value()) {
            std::cerr << holes.error() << "\n";
            return 1;
        }
        for (const libkicad::ThroughHole& hole : *holes) {
            std::cout << (hole.footprintRef.empty() ? "(via)" : hole.footprintRef) << "\t" << hole.padNumber << "\t"
                       << hole.netName << "\t" << hole.xMm << "\t" << hole.yMm << "\t" << hole.padWidthMm << "\t"
                       << hole.padHeightMm << "\t" << hole.drillWidthMm << "\t" << hole.drillHeightMm << "\n";
        }
        return 0;
    }

    if (command == "export-component-models" && argc == 6) {
        const std::expected<libkicad::ComponentModelExportResult, std::string> exportResult =
                libkicad::exportComponentModels(argv[2], argv[3], argv[4], argv[5]);
        if (!exportResult.has_value()) {
            std::cerr << exportResult.error() << "\n";
            return 1;
        }
        // Three sections, each explicitly counted rather than just newline-delimited to end of
        // stream (the plain convention every other query command here uses) -- messages are
        // free-text diagnostics from KiCad's own exporter (see ComponentModelExportResult's own
        // doc comment for why these aren't errors) and triangle rows are tab-separated, so an
        // implicit "read until EOF" boundary between the two sections would be ambiguous the
        // moment a message happened to contain a tab.
        // Line 1: exportSucceeded ("1"/"0"). Line 2: topCopperZMm (see ComponentModelExportResult's
        // own doc comment). Line 3: message count. Next N lines: one message each. Next line:
        // triangle count. Next M lines: one triangle each, 13 tab-separated fields (ax ay az bx by
        // bz cx cy cz r g b a) -- see ComponentTriangle's own doc comment.
        std::cout << (exportResult->exportSucceeded ? "1" : "0") << "\n";
        std::cout << _formatDouble(exportResult->topCopperZMm) << "\n";
        std::cout << exportResult->messages.size() << "\n";
        for (const std::string& message : exportResult->messages) {
            std::cout << message << "\n";
        }
        std::cout << exportResult->triangles.size() << "\n";
        for (const libkicad::ComponentTriangle& t : exportResult->triangles) {
            std::cout << _formatDouble(t.ax) << '\t' << _formatDouble(t.ay) << '\t' << _formatDouble(t.az) << '\t'
                       << _formatDouble(t.bx) << '\t' << _formatDouble(t.by) << '\t' << _formatDouble(t.bz) << '\t'
                       << _formatDouble(t.cx) << '\t' << _formatDouble(t.cy) << '\t' << _formatDouble(t.cz) << '\t'
                       << _formatDouble(t.r) << '\t' << _formatDouble(t.g) << '\t' << _formatDouble(t.b) << '\t'
                       << _formatDouble(t.a) << '\n';
        }
        return 0;
    }

    std::cerr << "usage: " << argv[0]
               << " {net-for-pin <project> <board> <footprint> <pin> | nets-in-class <project> <board> "
                  "<net_class> | pads-on-net <project> <board> <net> | tracks-on-net <project> <board> <net> | "
                  "resolve-pin <project> <board> "
                  "<footprint> <pin> | stackup <project> <board> | layer-colors <project> <board> | "
                  "net-classes <project> <board> | all-nets <project> <board> | "
                  "footprints <project> <board> | through-holes <project> <board> | "
                  "export-component-models <project> <board> <component_filter_csv> <output_stl_path>}\n";
    return 2;
}

// Human-readable dev smoketest (this file's original purpose): loads a board, exercises every
// libkicad function against it, and prints a plain-English summary. Used to manually verify
// libkicad changes against a real board -- not invoked by port_resolution.cpp.
int _runSmoketest(int argc, char** argv) {
    if (argc != 3 && argc != 6) {
        std::cerr << "usage: " << argv[0]
                   << " <project.kicad_pro> <board.kicad_pcb> [footprintRef pin netClassName]\n";
        return 1;
    }

    std::expected<libkicad::PadCounts, std::string> result = libkicad::countPads(argv[1], argv[2]);
    if (!result.has_value()) {
        std::cerr << "FAILED: " << result.error() << "\n";
        return 1;
    }

    std::cout << "Footprints: " << result->footprintCount << ", Tracks: " << result->trackCount
               << ", Zones: " << result->zoneCount << "\n";
    std::cout << "GetItems(PAD) via protobuf handler returned " << result->padCount << " items\n";

    std::expected<std::vector<libkicad::StackupLayer>, std::string> stackup = libkicad::stackup(argv[1], argv[2]);
    if (!stackup.has_value()) {
        std::cerr << "FAILED stackup: " << stackup.error() << "\n";
        return 1;
    }
    std::cout << "Stackup has " << stackup->size() << " layer(s)";
    if (!stackup->empty()) {
        const libkicad::StackupLayer& first = stackup->front();
        std::cout << ", e.g. \"" << first.name << "\" (" << _stackupLayerKindName(first.kind) << "), "
                   << first.thicknessMm << " mm thick";
    }
    std::cout << "\n";

    std::expected<std::vector<std::string>, std::string> allNets = libkicad::allNets(argv[1], argv[2]);
    if (!allNets.has_value()) {
        std::cerr << "FAILED allNets: " << allNets.error() << "\n";
        return 1;
    }
    std::cout << "Board has " << allNets->size() << " net(s)";
    if (!allNets->empty()) {
        std::cout << ", e.g. \"" << allNets->front() << "\"";
    }
    std::cout << "\n";

    std::expected<std::vector<std::string>, std::string> netClasses = libkicad::netClasses(argv[1], argv[2]);
    if (!netClasses.has_value()) {
        std::cerr << "FAILED netClasses: " << netClasses.error() << "\n";
        return 1;
    }
    std::cout << "Board has " << netClasses->size() << " net class(es)";
    if (!netClasses->empty()) {
        std::cout << ", e.g. \"" << netClasses->front() << "\"";
    }
    std::cout << "\n";

    std::expected<std::vector<libkicad::FootprintInfo>, std::string> footprints =
            libkicad::footprints(argv[1], argv[2]);
    if (!footprints.has_value()) {
        std::cerr << "FAILED footprints: " << footprints.error() << "\n";
        return 1;
    }
    std::cout << "Board has " << footprints->size() << " footprint(s)";
    if (!footprints->empty()) {
        std::cout << ", e.g. \"" << footprints->front().reference << "\" with " << footprints->front().pins.size()
                   << " pin(s)";
    }
    std::cout << "\n";

    if (argc == 6) {
        const std::string footprintRef = argv[3];
        const std::string pin = argv[4];
        const std::string netClassName = argv[5];

        std::expected<std::string, std::string> net = libkicad::netForFootprintPin(argv[1], argv[2], footprintRef, pin);
        if (!net.has_value()) {
            std::cerr << "FAILED netForFootprintPin: " << net.error() << "\n";
            return 1;
        }
        std::cout << footprintRef << "." << pin << " is on net \"" << *net << "\"\n";

        std::expected<std::vector<std::string>, std::string> members =
                libkicad::netsInNetClass(argv[1], argv[2], netClassName);
        if (!members.has_value()) {
            std::cerr << "FAILED netsInNetClass: " << members.error() << "\n";
            return 1;
        }
        std::cout << "Netclass \"" << netClassName << "\" has " << members->size() << " member net(s)";
        if (!members->empty()) {
            std::cout << ", e.g. \"" << members->front() << "\"";
        }
        std::cout << "\n";

        std::expected<std::vector<libkicad::PadPosition>, std::string> pads = libkicad::padsOnNet(argv[1], argv[2], *net);
        if (!pads.has_value()) {
            std::cerr << "FAILED padsOnNet: " << pads.error() << "\n";
            return 1;
        }
        std::cout << "Net \"" << *net << "\" has " << pads->size() << " pad(s)";
        if (!pads->empty()) {
            const libkicad::PadPosition& p = pads->front();
            std::cout << ", e.g. " << p.footprintRef << "." << p.padNumber << " at (" << p.xMm << ", " << p.yMm
                       << ") mm, orientation " << p.orientationDeg << " deg, layer " << p.copperLayerName;
        }
        std::cout << "\n";
    }

    std::cout << "SUCCESS\n";
    return 0;
}

const std::vector<std::string> kQueryCommands = {"net-for-pin",  "nets-in-class", "pads-on-net", "tracks-on-net",
                                                  "all-pads",     "all-tracks",    "zones",       "resolve-pin",
                                                  "stackup",      "layer-colors",  "net-classes", "all-nets",
                                                  "footprints",   "through-holes", "export-component-models"};

} // namespace

int main(int argc, char** argv) {
    if (argc >= 2 &&
        std::find(kQueryCommands.begin(), kQueryCommands.end(), std::string(argv[1])) != kQueryCommands.end()) {
        return _runQuery(argc, argv);
    }
    return _runSmoketest(argc, argv);
}
