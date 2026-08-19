// Plain data shared between libkicad.cpp (compiled at c++20, matching KiCad's own headers, which
// don't compile at c++23 on this checkout) and libkicad_api.cpp (compiled at c++23, so it can
// return the public std::expected-based API from libkicad.hpp). No KiCad headers and no
// <expected> here, so this stays includable from either translation unit.
#pragma once

#include <cstdint>
#include <string>
#include <vector>

namespace libkicad {

struct PadCounts {
    std::int32_t footprintCount = 0;
    std::int32_t trackCount = 0;
    std::int32_t zoneCount = 0;
    std::int32_t padCount = 0;
};

/// What a BOARD_STACKUP_ITEM (see KiCad's board_stackup_manager/board_stackup.h) actually is, for
/// the subset this project cares about -- solder mask/paste/silkscreen entries are filtered out
/// before ever reaching a StackupLayer (see stackupRaw()).
enum class StackupLayerKind {
    Copper,
    Core,    // rigid dielectric (FR4 etc.)
    Prepreg, // bonding-film dielectric between core layers
};

/// One layer of a board's physical stackup (BOARD_DESIGN_SETTINGS::GetStackupDescriptor()), in
/// top-to-bottom order. thicknessMm/epsilonR/lossTangent come straight off BOARD_STACKUP_ITEM;
/// epsilonR/lossTangent are meaningless (left at 0) for Copper layers.
struct StackupLayer {
    StackupLayerKind kind = StackupLayerKind::Copper;
    std::string name; // BOARD_STACKUP_ITEM::GetLayerName(), e.g. "F.Cu", "Dielectric 1"
    double thicknessMm = 0;
    double epsilonR = 0;
    double lossTangent = 0;
};

/// One pad on a resolved net: identity (for matching against an ExcitationConfig's footprint+pin),
/// position/orientation for port placement, and which copper layer it sits on. Position is in
/// millimetres, relative to the board's auxiliary origin (BOARD_DESIGN_SETTINGS::GetAuxOrigin()) --
/// the same frame kicad-cli's --use-drill-file-origin exports (Gerbers, drill file, pick&place CSV)
/// use, i.e. gerber2ems's own native frame, needing no further conversion by callers.
struct PadPosition {
    std::string footprintRef;
    std::string padNumber;
    std::string netName;
    double xMm = 0;
    double yMm = 0;
    double orientationDeg = 0;
    std::string copperLayerName;
    /// Pad footprint size in millimetres, in the pad's own local (unrotated) frame: widthMm along
    /// its local X, heightMm along its local Y. Rotation isn't folded in here (unlike
    /// xMm/yMm/orientationDeg) -- callers that need a rotation-agnostic bound on how far the pad's
    /// copper extends from its center can just use max(widthMm, heightMm) / 2.
    double widthMm = 0;
    double heightMm = 0;
};

/// One pad on a footprint, identified the same way PadPosition/ExcitationConfig/InvolvedNetConfig
/// selectors do: a pad number (tried first when matching) and, if present, a schematic pin
/// function name (e.g. "GND") -- see libkicad.cpp's _findFootprintPad for the matching order this
/// mirrors.
struct FootprintPin {
    std::string number;
    std::string function; // empty if the pad has no assigned pin function
    std::string netName; // empty if the pad isn't connected to any net
};

/// One footprint on the board: its reference designator, KiCad's "Value" field text (e.g. "100nF",
/// "10k" -- empty if unset), and every pad on it. Used to populate a "browse by footprint, then pick
/// a pin" UI -- see footprints().
struct FootprintInfo {
    std::string reference;
    std::string value;
    std::vector<FootprintPin> pins;
};

/// One copper layer's configured display color, from the currently active PCB color theme (see
/// layerColors()) -- `hex` is `COLOR4D::ToHexString()`'s own format ("#RRGGBB" or "#RRGGBBAA").
struct LayerColor {
    std::string name; // Same as StackupLayer::name for the matching copper layer, e.g. "F.Cu"
    std::string hex;
};

/// One plated through-hole feature on the board -- either a plain KiCad via (PCB_VIA, not tied to
/// any footprint) or a through-hole pad on a footprint (PAD_ATTRIB::PTH, e.g. a connector's SHIELD
/// pin). Non-plated holes (PAD_ATTRIB::NPTH) are never included -- those have no copper at all, a
/// fundamentally different feature (see gerber2ems::NPTHHole). Position is in millimetres, relative
/// to the board's auxiliary origin, the same convention PadPosition uses. padWidthMm/padHeightMm is
/// the actual copper (a via's own annular ring, or a pad's real size) and drillWidthMm/
/// drillHeightMm the actual hole -- each pair is equal for a round shape (every via; most pads) and
/// distinct for an oblong one (a pad only -- KiCad vias are always round). footprintRef/padNumber
/// are both empty for a plain via.
struct ThroughHole {
    double xMm = 0;
    double yMm = 0;
    std::string netName; // empty if unconnected
    std::string footprintRef; // empty for a plain via (not tied to any footprint)
    std::string padNumber;    // empty for a plain via
    double padWidthMm = 0;
    double padHeightMm = 0;
    double drillWidthMm = 0;
    double drillHeightMm = 0;
};

namespace detail {

struct RawStringListResult {
    bool ok = false;
    std::string error;
    std::vector<std::string> values;
};

struct RawFootprintsResult {
    bool ok = false;
    std::string error;
    std::vector<FootprintInfo> footprints;
};

struct RawPadCountsResult {
    bool ok = false;
    std::string error;
    PadCounts counts;
};

struct RawNetNameResult {
    bool ok = false;
    std::string error;
    std::string netName;
};

struct RawPadResult {
    bool ok = false;
    std::string error;
    PadPosition pad;
};

struct RawNetClassMembersResult {
    bool ok = false;
    std::string error;
    std::vector<std::string> netNames;
};

struct RawPadsOnNetResult {
    bool ok = false;
    std::string error;
    std::vector<PadPosition> pads;
};

struct RawStackupResult {
    bool ok = false;
    std::string error;
    std::vector<StackupLayer> layers;
};

struct RawLayerColorsResult {
    bool ok = false;
    std::string error;
    std::vector<LayerColor> colors;
};

RawPadCountsResult countPadsRaw(const std::string& projectPath, const std::string& boardPath);

RawNetNameResult netForFootprintPinRaw(const std::string& projectPath, const std::string& boardPath,
                                        const std::string& footprintRef, const std::string& pin);

RawPadResult resolvePinRaw(const std::string& projectPath, const std::string& boardPath,
                            const std::string& footprintRef, const std::string& pin);

RawNetClassMembersResult netsInNetClassRaw(const std::string& projectPath, const std::string& boardPath,
                                            const std::string& netClassName);

RawPadsOnNetResult padsOnNetRaw(const std::string& projectPath, const std::string& boardPath,
                                 const std::string& netName);

RawStackupResult stackupRaw(const std::string& projectPath, const std::string& boardPath);

RawLayerColorsResult layerColorsRaw(const std::string& projectPath, const std::string& boardPath);

RawStringListResult netClassesRaw(const std::string& projectPath, const std::string& boardPath);

RawStringListResult allNetsRaw(const std::string& projectPath, const std::string& boardPath);

RawFootprintsResult footprintsRaw(const std::string& projectPath, const std::string& boardPath);

struct RawThroughHolesResult {
    bool ok = false;
    std::string error;
    std::vector<ThroughHole> holes;
};

RawThroughHolesResult throughHolesRaw(const std::string& projectPath, const std::string& boardPath);

} // namespace detail
} // namespace libkicad
