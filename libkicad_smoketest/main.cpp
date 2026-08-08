#include <expected>
#include <iostream>

#include "../libkicad/libkicad.hpp"

int main(int argc, char** argv) {
    if (argc != 3) {
        std::cerr << "usage: " << argv[0] << " <project.kicad_pro> <board.kicad_pcb>\n";
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
    std::cout << "SUCCESS\n";
    return 0;
}
