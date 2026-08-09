// Shared net/pad-identity queries against the real KiCad board, used by both port_resolution.cpp
// and board_slicing.cpp. Delegates to the libkicad_smoketest binary as a subprocess rather than
// linking libkicad directly: libkicad pulls in KiCad's own wx/protobuf/abseil/OpenCASCADE
// dependency chain, including a *different* build of Clipper2 than the one geber2ems links
// directly (Homebrew's, vs. KiCad's own bundled copy) -- linking both into one executable would
// risk duplicate-symbol errors. A subprocess keeps the two dependency worlds fully separate, the
// same way this project already shells out to kicad-cli (see importer.cpp's _runProcess).
#pragma once

#include <expected>
#include <string>
#include <vector>

#include "config.hpp"
#include "paths_config.hpp"

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

/// Resolves one footprint's pin to its net name. `paths` supplies the board/project to query and
/// the query-helper binary to run (see PathsConfig); `context` prefixes any error message -- every
/// caller treats a failure here as an unrecoverable config error (a typo'd footprint/pin name
/// needs the user to fix the config, not a fallback), but the decision of what to do about it is
/// now the caller's, not this function's.
std::expected<std::string, std::string> netForFootprintPin(const PathsConfig& paths, const std::string& footprint,
                                                             const std::string& pin, const std::string& context);

/// Every net assigned to `netClassName`. See netForFootprintPin.
std::expected<std::vector<std::string>, std::string> netsInNetClass(const PathsConfig& paths,
                                                                      const std::string& netClassName,
                                                                      const std::string& context);

/// Every pad connected to `netName`. See netForFootprintPin.
std::expected<std::vector<PadIdentity>, std::string> padsOnNet(const PathsConfig& paths, const std::string& netName,
                                                                 const std::string& context);

/// Resolves one footprint's pin to its full pad identity (position/orientation/layer/net). See
/// netForFootprintPin.
std::expected<PadIdentity, std::string> resolvePin(const PathsConfig& paths, const std::string& footprint,
                                                     const std::string& pin, const std::string& context);

/// Resolves an InvolvedNetConfig entry (net_class / net / footprint+pins) to a list of net names,
/// per its documented semantics (a footprint+pin entry resolves to that pin's net, deduplicated
/// across its pins() list).
std::expected<std::vector<std::string>, std::string> resolveInvolvedNetNames(const PathsConfig& paths,
                                                                               const InvolvedNetConfig& entry);

/// Resolves a GroundNetConfig (net_class / net) to a list of net names.
std::expected<std::vector<std::string>, std::string> resolveGroundNetNames(const PathsConfig& paths,
                                                                             const GroundNetConfig& ground);

} // namespace gerber2ems::libkicad_query
