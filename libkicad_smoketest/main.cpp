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

    if (command == "resolve-pin" && argc == 6) {
        const std::expected<libkicad::PadPosition, std::string> pad = libkicad::resolvePin(argv[2], argv[3], argv[4], argv[5]);
        if (!pad.has_value()) {
            std::cerr << pad.error() << "\n";
            return 1;
        }
        _printPad(*pad);
        return 0;
    }

    std::cerr << "usage: " << argv[0]
               << " {net-for-pin <project> <board> <footprint> <pin> | nets-in-class <project> <board> "
                  "<net_class> | pads-on-net <project> <board> <net> | resolve-pin <project> <board> "
                  "<footprint> <pin>}\n";
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

const std::vector<std::string> kQueryCommands = {"net-for-pin", "nets-in-class", "pads-on-net", "resolve-pin"};

} // namespace

int main(int argc, char** argv) {
    if (argc >= 2 &&
        std::find(kQueryCommands.begin(), kQueryCommands.end(), std::string(argv[1])) != kQueryCommands.end()) {
        return _runQuery(argc, argv);
    }
    return _runSmoketest(argc, argv);
}
