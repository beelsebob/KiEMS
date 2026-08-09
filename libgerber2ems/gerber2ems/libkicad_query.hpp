// Shared net/pad-identity queries against the real KiCad board, used by both port_resolution.cpp
// and board_slicing.cpp. Delegates to the libkicad_smoketest binary as a subprocess rather than
// linking libkicad directly: libkicad pulls in KiCad's own wx/protobuf/abseil/OpenCASCADE
// dependency chain, including a *different* build of Clipper2 than the one geber2ems links
// directly (Homebrew's, vs. KiCad's own bundled copy) -- linking both into one executable would
// risk duplicate-symbol errors. A subprocess keeps the two dependency worlds fully separate, the
// same way this project already shells out to kicad-cli (see importer.cpp's _runProcess).
#pragma once

#include <string>
#include <vector>

#include "config.hpp"

namespace gerber2ems::libkicad_query {

/// Identity/position of one pad, as reported by libkicad_smoketest's `pads-on-net`/`resolve-pin`
/// query modes. Position is in millimetres, relative to the board's auxiliary origin -- the same
/// frame kicad-cli's --use-drill-file-origin exports (Gerbers, drill file) use.
struct PadIdentity {
    std::string footprintRef;
    std::string padNumber;
    std::string netName;
    double xMm = 0;
    double yMm = 0;
    double orientationDeg = 0;
    std::string copperLayerName;
    /// Pad footprint size in millimetres, in the pad's own local (unrotated) frame. Rotation isn't
    /// folded in -- see libkicad_result.hpp's identical field for the rationale.
    double widthMm = 0;
    double heightMm = 0;
};

/// Resolves one footprint's pin to its net name. `context` prefixes any error message; on failure,
/// logs the error and exits the process (every caller treats this as an unrecoverable config error
/// -- a typo'd footprint/pin name needs the user to fix the config, not a fallback).
std::string netForFootprintPin(const std::string& footprint, const std::string& pin, const std::string& context);

/// Every net assigned to `netClassName`. Exits the process on failure (see netForFootprintPin).
std::vector<std::string> netsInNetClass(const std::string& netClassName, const std::string& context);

/// Every pad connected to `netName`. Exits the process on failure (see netForFootprintPin).
std::vector<PadIdentity> padsOnNet(const std::string& netName, const std::string& context);

/// Resolves one footprint's pin to its full pad identity (position/orientation/layer/net). Exits
/// the process on failure (see netForFootprintPin).
PadIdentity resolvePin(const std::string& footprint, const std::string& pin, const std::string& context);

/// Resolves an InvolvedNetConfig entry (net_class / net / footprint+pins) to a list of net names,
/// per its documented semantics (a footprint+pin entry resolves to that pin's net, deduplicated
/// across its pins() list).
std::vector<std::string> resolveInvolvedNetNames(const InvolvedNetConfig& entry);

/// Resolves a GroundNetConfig (net_class / net) to a list of net names.
std::vector<std::string> resolveGroundNetNames(const GroundNetConfig& ground);

} // namespace gerber2ems::libkicad_query
