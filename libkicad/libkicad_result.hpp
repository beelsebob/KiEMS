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
/// top-to-bottom order. thicknessMm/epsilonR come straight off BOARD_STACKUP_ITEM; epsilonR is
/// meaningless (left at 0) for Copper layers.
struct StackupLayer {
    StackupLayerKind kind = StackupLayerKind::Copper;
    std::string name; // BOARD_STACKUP_ITEM::GetLayerName(), e.g. "F.Cu", "Dielectric 1"
    double thicknessMm = 0;
    double epsilonR = 0;
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

namespace detail {

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

} // namespace detail
} // namespace libkicad
