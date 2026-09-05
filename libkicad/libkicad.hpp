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

std::expected<PadCounts, std::string> countPads(const std::string& projectPath, const std::string& boardPath);

/// Resolves the net connected to one footprint's pin. `pin` is tried first as a pad number
/// (PAD::GetNumber(), e.g. "3"), then as a schematic pin name (PAD::GetPinFunction(), e.g. "GND")
/// if no pad matches by number.
std::expected<std::string, std::string> netForFootprintPin(const std::string& projectPath,
                                                             const std::string& boardPath,
                                                             const std::string& footprintRef, const std::string& pin);

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

/// Every pad on the board regardless of net, in one single board load -- see
/// detail::allPadsRaw()'s own doc comment for why this exists alongside padsOnNet().
std::expected<std::vector<PadPosition>, std::string> allPads(const std::string& projectPath,
                                                                const std::string& boardPath);

/// Every straight PCB track segment on the board regardless of net, paired with its own net name, in
/// one single board load -- see detail::allPadsRaw()'s own doc comment.
std::expected<std::vector<std::pair<std::string, TrackSegment>>, std::string> allTracks(
    const std::string& projectPath, const std::string& boardPath);

/// The board's physical stackup (Board Setup > Board Stackup), top-to-bottom -- solder mask/paste/
/// silkscreen entries are omitted, only copper and dielectric layers are returned. If the board's
/// file has no explicit stackup section, this is KiCad's own computed default for its layer count,
/// not an error.
std::expected<std::vector<StackupLayer>, std::string> stackup(const std::string& projectPath,
                                                                const std::string& boardPath);

/// Every copper layer's configured color, from the currently active PCB color theme -- KiCad's own
/// "layer colours" (Board Setup/Preferences > Colors), not something unique to this board; falls
/// back to KiCad's built-in default theme if no other theme is resolvable for this process. Not
/// necessarily in stackup order, and only covers layers the active theme has an entry for.
std::expected<std::vector<LayerColor>, std::string> layerColors(const std::string& projectPath,
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

} // namespace libkicad
