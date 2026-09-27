// Experimental in-process KiCad board query: drives the same API_HANDLER_PCB / protobuf command
// path KiCad's own IPC API server uses, without a PCB_EDIT_FRAME, KIWAY, or wx GUI window. See
// libkicad.cpp for the chain: SETTINGS_MANAGER -> PCB_IO_KICAD_SEXPR -> HEADLESS_PCB_CONTEXT ->
// API_HANDLER_PCB::Handle(GetItems).
//
// This header requires c++23 (std::expected) and must never be included from a translation unit
// that also includes KiCad's own headers -- those don't compile at c++23 on this checkout. See
// libkicad_result.hpp for the plain-data type shared across the c++20/c++23 boundary, and
// libkicad_api.cpp for where the two sides meet.
#pragma once

#include <expected>
#include <string>
#include <utility>
#include <vector>

#include "libkicad_result.hpp"

namespace libkicad {

/// The two files needed to load one KiCad board. This value type lets applications retain a board
/// source without introducing their own query-wrapper API.
struct BoardPaths {
    std::string projectPath;
    std::string boardPath;
};

/// Initializes KiCad's process-global runtime. Cocoa applications must call this from their main
/// thread before issuing any libkicad query on a background queue. Command-line clients may rely
/// on the first query to initialize lazily, provided that query runs on their main thread.
std::expected<void, std::string> initialize();

std::expected<PadCounts, std::string> countPads(const std::string& projectPath, const std::string& boardPath);

/// Resolves the net connected to one footprint's pin. `pin` is tried first as a pad number
/// (PAD::GetNumber(), e.g. "3"), then as a schematic pin name (PAD::GetPinFunction(), e.g. "GND")
/// if no pad matches by number.
std::expected<std::string, std::string> netForFootprintPin(const std::string& projectPath,
                                                             const std::string& boardPath,
                                                             const std::string& footprintRef, const std::string& pin);

/// The effective KiCad net class for one concrete net. Composite/pattern class resolution is left
/// to KiCad; the returned name is exactly NETCLASS::GetName().
std::expected<std::string, std::string> netClassForNet(const std::string& projectPath,
                                                         const std::string& boardPath,
                                                         const std::string& netName);

/// Resolves one footprint's pin to its full pad identity (including position/orientation/layer and
/// which net it's on) -- the same pad lookup as netForFootprintPin, but returning everything about
/// that specific pad rather than just its net name. Used to match a footprint+pin selector
/// (ExcitationConfig, a trace/differential-pair PortRef) back to one already-resolved port.
std::expected<PadPosition, std::string> resolvePin(const std::string& projectPath, const std::string& boardPath,
                                                     const std::string& footprintRef, const std::string& pin);

/// Every net assigned to the given netclass (by name). Requires the board to have a linked
/// project (a sibling .kicad_pro) for netclass assignment to be resolvable at all.
std::expected<std::vector<std::string>, std::string> netsInNetClass(const std::string& projectPath,
                                                                      const std::string& boardPath,
                                                                      const std::string& netClassName);

/// Every pad connected to the given net, with position/orientation/layer for port placement.
std::expected<std::vector<PadPosition>, std::string> padsOnNet(const std::string& projectPath,
                                                                 const std::string& boardPath,
                                                                 const std::string& netName);

/// Every straight PCB track segment connected to `netName`, with its actual KiCad width and copper
/// layer. Vias and curved arcs are excluded because they are not valid MSL probe spans.
std::expected<std::vector<TrackSegment>, std::string> tracksOnNet(const std::string& projectPath,
                                                                    const std::string& boardPath,
                                                                    const std::string& netName);

/// Every copper zone/pour on the board (ground fills, rule areas, ...), one entry per copper layer
/// each is actually on -- see ZoneInfo's own doc comment.
std::expected<std::vector<ZoneInfo>, std::string> zones(const std::string& projectPath,
                                                           const std::string& boardPath);

/// Exact board outline, net-owned copper (including a zone/non-zone display distinction),
/// solder-mask openings, and expanded front/back silkscreen from KiCad's BOARD model.
std::expected<BoardGeometry, std::string> boardGeometry(const std::string& projectPath,
                                                           const std::string& boardPath);

/// Every layer enabled in the board file, including non-stackup technical/user layers.
std::expected<std::vector<BoardLayerInfo>, std::string> boardLayers(const std::string& projectPath,
                                                                     const std::string& boardPath);

/// Extract just one layer. This intentionally permits preview clients to schedule visible layers
/// first instead of paying for every enabled layer before presenting their UI.
std::expected<BoardLayerGeometry, std::string> boardLayerGeometry(const std::string& projectPath,
                                                                   const std::string& boardPath,
                                                                   const std::string& layerName);

/// Bounds of a BoardGeometry's Edge.Cuts contours, in the geometry's native millimetre frame.
std::expected<BoardBounds, std::string> boardBounds(const BoardGeometry& geometry);

/// Every pad on the board regardless of net, in one single board load -- see
/// detail::allPadsRaw()'s own doc comment for why this exists alongside padsOnNet().
std::expected<std::vector<PadPosition>, std::string> allPads(const std::string& projectPath,
                                                                const std::string& boardPath);

/// Every PCB track centreline on the board regardless of net, paired with its own net name, in one
/// single board load. Curved tracks are flattened into short connected segments; vias are returned
/// separately by throughHoles().
std::expected<std::vector<std::pair<std::string, TrackSegment>>, std::string> allTracks(
    const std::string& projectPath, const std::string& boardPath);

/// The board's physical stackup (Board Setup > Board Stackup), top-to-bottom -- solder mask/paste/
/// silkscreen entries are omitted, only copper and dielectric layers are returned. If the board's
/// file has no explicit stackup section, this is KiCad's own computed default for its layer count,
/// not an error.
std::expected<std::vector<StackupLayer>, std::string> stackup(const std::string& projectPath,
                                                                const std::string& boardPath);

/// Every enabled board layer's configured color, from the currently active PCB color theme -- KiCad's own
/// "layer colours" (Board Setup/Preferences > Colors), not something unique to this board; falls
/// back to KiCad's built-in default theme if no other theme is resolvable for this process. Not
/// layer order, and only covers layers the active theme has an entry for.
std::expected<std::vector<LayerColor>, std::string> layerColors(const std::string& projectPath,
                                                                  const std::string& boardPath);

/// Every net with a configured PCB color override. Explicit per-net colors win over the net's
/// effective net-class color, exactly as KiCad's PCB renderer resolves them. Nets with neither
/// kind of override are omitted and should use their copper-layer color.
std::expected<std::vector<NetColor>, std::string> netColors(const std::string& projectPath,
                                                              const std::string& boardPath);

/// Every net class name assigned to at least one net on the board, deduplicated. Requires the
/// board to have a linked project (a sibling .kicad_pro), same as netsInNetClass.
std::expected<std::vector<std::string>, std::string> netClasses(const std::string& projectPath,
                                                                  const std::string& boardPath);

/// Every net name on the board (excluding the unconnected pseudo-net).
std::expected<std::vector<std::string>, std::string> allNets(const std::string& projectPath,
                                                               const std::string& boardPath);

/// Every footprint on the board, with its pins -- populates a "browse by footprint" UI without a
/// separate round trip per footprint.
std::expected<std::vector<FootprintInfo>, std::string> footprints(const std::string& projectPath,
                                                                    const std::string& boardPath);

/// Every plated through-hole on the board -- both plain KiCad vias and through-hole footprint pads
/// (e.g. a connector's SHIELD pin) -- with their real copper (annular ring / pad) and drill sizes.
/// See ThroughHole's own doc comment; non-plated holes are never included.
std::expected<std::vector<ThroughHole>, std::string> throughHoles(const std::string& projectPath,
                                                                    const std::string& boardPath);

/// Every non-plated mechanical hole/slot on the board, read directly from NPTH footprint pads.
std::expected<std::vector<NonPlatedHole>, std::string> nonPlatedHoles(const std::string& projectPath,
                                                                        const std::string& boardPath);

/// Returns `componentFilter`'s own footprints' real, placed 3D models (their real position/
/// rotation/offset on the board, no board body/copper/tracks/pads) as a flat, real-colored triangle
/// list (ComponentModelExportResult::triangles) -- via KiCad's own EXPORTER_STEP/STEP_PCB_MODEL
/// classes, the same machinery `kicad-cli pcb export stl` itself uses, run in-process rather than
/// as a second subprocess. `outputStlPath` is still where an incidental STL copy of the same mesh
/// gets written (a debug artifact, not read by this function itself -- see exportComponentModelsRaw's
/// own comment). `componentFilter` is a comma-separated list of reference designators (wildcards
/// supported, same syntax as kicad-cli's own --component-filter). The returned std::expected's
/// error channel is only for a hard failure (board didn't load, or the exporter itself reported
/// failure) -- a requested component whose own linked 3D model can't be resolved is reported
/// through the success value's own `messages` instead (see ComponentModelExportResult's own doc
/// comment), not as an error here.
std::expected<ComponentModelExportResult, std::string> exportComponentModels(const std::string& projectPath,
                                                                                const std::string& boardPath,
                                                                                const std::string& componentFilter,
                                                                                const std::string& outputStlPath);

// BoardPaths conveniences keep callers on libkicad's in-process API without repeating the two
// filenames at every query site.
inline std::expected<std::string, std::string> netForFootprintPin(const BoardPaths& p,
    const std::string& footprint, const std::string& pin) {
    return netForFootprintPin(p.projectPath, p.boardPath, footprint, pin);
}
inline std::expected<std::string, std::string> netClassForNet(const BoardPaths& p, const std::string& net) {
    return netClassForNet(p.projectPath, p.boardPath, net);
}
inline std::expected<PadPosition, std::string> resolvePin(const BoardPaths& p, const std::string& footprint,
                                                          const std::string& pin) {
    return resolvePin(p.projectPath, p.boardPath, footprint, pin);
}
inline std::expected<std::vector<std::string>, std::string> netsInNetClass(const BoardPaths& p,
                                                                           const std::string& name) {
    return netsInNetClass(p.projectPath, p.boardPath, name);
}
inline std::expected<std::vector<PadPosition>, std::string> padsOnNet(const BoardPaths& p,
                                                                      const std::string& net) {
    return padsOnNet(p.projectPath, p.boardPath, net);
}
inline std::expected<std::vector<TrackSegment>, std::string> tracksOnNet(const BoardPaths& p,
                                                                         const std::string& net) {
    return tracksOnNet(p.projectPath, p.boardPath, net);
}
inline std::expected<std::vector<ZoneInfo>, std::string> zones(const BoardPaths& p) {
    return zones(p.projectPath, p.boardPath);
}
inline std::expected<BoardGeometry, std::string> boardGeometry(const BoardPaths& p) {
    return boardGeometry(p.projectPath, p.boardPath);
}
inline std::expected<std::vector<BoardLayerInfo>, std::string> boardLayers(const BoardPaths& p) {
    return boardLayers(p.projectPath, p.boardPath);
}
inline std::expected<BoardLayerGeometry, std::string> boardLayerGeometry(const BoardPaths& p,
                                                                          const std::string& layerName) {
    return boardLayerGeometry(p.projectPath, p.boardPath, layerName);
}
inline std::expected<std::vector<PadPosition>, std::string> allPads(const BoardPaths& p) {
    return allPads(p.projectPath, p.boardPath);
}
inline std::expected<std::vector<std::pair<std::string, TrackSegment>>, std::string> allTracks(const BoardPaths& p) {
    return allTracks(p.projectPath, p.boardPath);
}
inline std::expected<std::vector<StackupLayer>, std::string> stackup(const BoardPaths& p) {
    return stackup(p.projectPath, p.boardPath);
}
inline std::expected<std::vector<LayerColor>, std::string> layerColors(const BoardPaths& p) {
    return layerColors(p.projectPath, p.boardPath);
}
inline std::expected<std::vector<NetColor>, std::string> netColors(const BoardPaths& p) {
    return netColors(p.projectPath, p.boardPath);
}
inline std::expected<std::vector<std::string>, std::string> netClasses(const BoardPaths& p) {
    return netClasses(p.projectPath, p.boardPath);
}
inline std::expected<std::vector<std::string>, std::string> allNets(const BoardPaths& p) {
    return allNets(p.projectPath, p.boardPath);
}
inline std::expected<std::vector<FootprintInfo>, std::string> footprints(const BoardPaths& p) {
    return footprints(p.projectPath, p.boardPath);
}
inline std::expected<std::vector<ThroughHole>, std::string> throughHoles(const BoardPaths& p) {
    return throughHoles(p.projectPath, p.boardPath);
}
inline std::expected<std::vector<NonPlatedHole>, std::string> nonPlatedHoles(const BoardPaths& p) {
    return nonPlatedHoles(p.projectPath, p.boardPath);
}
inline std::expected<ComponentModelExportResult, std::string> exportComponentModels(
    const BoardPaths& p, const std::string& filter, const std::string& outputStlPath) {
    return exportComponentModels(p.projectPath, p.boardPath, filter, outputStlPath);
}

} // namespace libkicad
