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
#include "net_name.hpp"
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

enum class StackupLayerKind {
    Copper,
    Core,
    Prepreg,
    SolderMaskTop,
    SolderMaskBottom,
};

/// One layer of the board's physical stackup, as reported by libkicad_smoketest's `stackup` query
/// mode -- see libkicad_result.hpp's identical StackupLayer for field semantics (this is
/// gerber2ems_query's own copy of that shape, for the same subprocess-decoupling reason
/// PadIdentity mirrors libkicad::PadPosition instead of including libkicad's headers directly).
struct StackupLayer {
    StackupLayerKind kind = StackupLayerKind::Copper;
    std::string name;
    double thicknessMm = 0;
    double epsilonR = 0;
    double lossTangent = 0;
};

/// The board's physical stackup, top-to-bottom. See netForFootprintPin for `context`.
std::expected<std::vector<StackupLayer>, std::string> stackup(const PathsConfig& paths, const std::string& context);

/// One copper layer's configured display color -- mirrors libkicad::LayerColor. `hex` is
/// "#RRGGBB" or "#RRGGBBAA".
struct LayerColor {
    std::string name;
    std::string hex;
};

/// Every copper layer's configured color, from the currently active PCB color theme (KiCad's own
/// "layer colours" -- not necessarily unique to this board; see libkicad::layerColors's doc
/// comment). Not necessarily in stackup order. See netForFootprintPin for `context`.
std::expected<std::vector<LayerColor>, std::string> layerColors(const PathsConfig& paths, const std::string& context);

/// Every user-defined net class name on the board (independent of whether any net currently uses
/// it). Populates a "browse by net class" UI. See netForFootprintPin for `context`.
std::expected<std::vector<std::string>, std::string> netClasses(const PathsConfig& paths, const std::string& context);

/// Every net name on the board. Populates a "browse by net" UI. See netForFootprintPin for
/// `context`.
std::expected<std::vector<std::string>, std::string> allNets(const PathsConfig& paths, const std::string& context);

/// One pad on a footprint -- mirrors libkicad::FootprintPin. `function` is empty if the pad has no
/// assigned schematic pin function; `netName` is empty if the pad isn't connected to any net.
struct FootprintPin {
    std::string number;
    std::string function;
    std::string netName;
};

/// One footprint on the board and its pins -- mirrors libkicad::FootprintInfo. Populates a "browse
/// by footprint, then pick a pin" UI. `value` is KiCad's "Value" field text (e.g. "100nF", "10k"),
/// empty if unset.
struct FootprintInfo {
    std::string reference;
    std::string value;
    std::vector<FootprintPin> pins;
};

/// Every footprint on the board, with its pins. See netForFootprintPin for `context`.
std::expected<std::vector<FootprintInfo>, std::string> footprints(const PathsConfig& paths,
                                                                    const std::string& context);

/// One plated through-hole on the board -- mirrors libkicad::ThroughHole (see its own doc comment
/// for the via-vs-through-hole-pad distinction and why NPTH holes are never included here). Sizes
/// are in millimetres, in the same board-auxiliary-origin frame every other libkicad_query position
/// uses. footprintRef/padNumber are both empty for a plain KiCad via.
struct ThroughHole {
    double xMm = 0;
    double yMm = 0;
    std::string netName;
    std::string footprintRef;
    std::string padNumber;
    double padWidthMm = 0;
    double padHeightMm = 0;
    double drillWidthMm = 0;
    double drillHeightMm = 0;
};

/// Every plated through-hole on the board (vias and through-hole footprint pads alike), with their
/// real copper (annular ring / pad) and drill sizes -- the authoritative source for how big a given
/// via/pad actually is, as opposed to reconstructing it from an Excellon drill file (which only
/// ever carries a hole's position and diameter, nothing about the copper around it). See
/// netForFootprintPin for `context`.
std::expected<std::vector<ThroughHole>, std::string> throughHoles(const PathsConfig& paths,
                                                                     const std::string& context);

/// One mesh triangle of a footprint's real, placed 3D model -- mirrors libkicad::ComponentTriangle.
/// Vertex positions are absolute, in millimetres, in the same board-auxiliary-origin-relative frame
/// every other libkicad_query position uses. Color is straight from the model's own STEP colors,
/// each channel 0-1; (1,1,1,1) if the model carries none.
struct ComponentTriangle {
    double ax = 0, ay = 0, az = 0;
    double bx = 0, by = 0, bz = 0;
    double cx = 0, cy = 0, cz = 0;
    double r = 0, g = 0, b = 0, a = 0;
};

/// Result of exportComponentModels() -- mirrors libkicad::ComponentModelExportResult. `messages` is
/// every diagnostic KiCad's own exporter reported while building the requested components' shapes
/// (e.g. a component whose linked 3D model file can't be resolved); non-fatal, `exportSucceeded`
/// stays true and `triangles` still has every other requested component's mesh.
struct ComponentModelExportResult {
    bool exportSucceeded = false;
    std::vector<std::string> messages;
    std::vector<ComponentTriangle> triangles;
    /// The board's real top-copper mounting surface Z, in the same millimetre frame `triangles`'
    /// own vertices are in -- mirrors libkicad::ComponentModelExportResult::topCopperZMm; see its
    /// own doc comment for exactly what this is and why a caller re-basing these triangles onto a
    /// different Z=0 convention (e.g. this project's own "every copper layer is infinitesimally
    /// thin" one) needs this specific value rather than deriving an equivalent offset from stackup
    /// thickness alone.
    double topCopperZMm = 0;
};

/// Returns `componentFilter`'s own footprints' real, placed 3D models (no board body/copper/tracks/
/// pads) as a flat, real-colored triangle list, via libkicad's in-process EXPORTER_STEP/
/// STEP_PCB_MODEL wrapper (the same machinery `kicad-cli pcb export stl` itself uses).
/// `outputStlPath` is still where an incidental STL copy of the same mesh gets written (a debug
/// artifact, not read by this function itself). `componentFilter` is a comma-separated list of
/// reference designators (wildcards supported). See netForFootprintPin for `context`.
std::expected<ComponentModelExportResult, std::string> exportComponentModels(const PathsConfig& paths,
                                                                                const std::string& componentFilter,
                                                                                const std::string& outputStlPath,
                                                                                const std::string& context);

/// Resolves an InvolvedNetConfig entry (net_class / net / footprint+pins) to a list of net names,
/// per its documented semantics (a footprint+pin entry resolves to that pin's net, deduplicated
/// across its pins() list).
std::expected<std::vector<std::string>, std::string> resolveInvolvedNetNames(const PathsConfig& paths,
                                                                               const InvolvedNetConfig& entry);

/// Resolves a GroundNetConfig (net_class / net) to a list of net names.
std::expected<std::vector<std::string>, std::string> resolveGroundNetNames(const PathsConfig& paths,
                                                                             const GroundNetConfig& ground);

} // namespace gerber2ems::libkicad_query
