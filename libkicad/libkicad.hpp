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
#include <memory>
#include <string>
#include <utility>
#include <vector>

#include "libkicad_result.hpp"

namespace libkicad {

/// The two files needed to load one KiCad board.
struct BoardPaths {
    std::string projectPath;
    std::string boardPath;
};

/// Initializes KiCad's process-wide runtime (wx, Pgm(), SETTINGS_MANAGER) and owns libkicad's use
/// of it: the lock serializing every query, and the record of which boards hold a loaded project.
/// A client creates one -- Cocoa applications on their main thread, before issuing any query on a
/// background queue -- and keeps it alive longer than every Board opened from it.
class Runtime {
public:
    static std::expected<Runtime, std::string> create();

    Runtime(Runtime&&) noexcept = default;
    Runtime& operator=(Runtime&&) noexcept = default;
    Runtime(const Runtime&) = delete;
    Runtime& operator=(const Runtime&) = delete;
    ~Runtime() = default;

private:
    friend class Board;
    struct Deleter {
        void operator()(detail::RuntimeState* state) const;
    };
    explicit Runtime(detail::RuntimeState* state) : _state(state) {}
    std::unique_ptr<detail::RuntimeState, Deleter> _state;
};

/// One KiCad board and its project. Owns the HEADLESS_PCB_CONTEXT (and with it the BOARD) once
/// loaded: the first query loads both files, later queries reuse them, and a query after either
/// file's mtime changes reloads. KiCad keeps only one active project, so loading a board of a
/// different project from the same Runtime unloads this one; its next query reloads it.
///
/// Queries are thread-safe (serialized by the Runtime). `runtime` must outlive this Board.
class Board {
public:
    Board(Runtime& runtime, std::string projectPath, std::string boardPath);
    Board(Runtime& runtime, const BoardPaths& paths) : Board(runtime, paths.projectPath, paths.boardPath) {}

    Board(Board&&) noexcept = default;
    Board& operator=(Board&&) noexcept = default;
    Board(const Board&) = delete;
    Board& operator=(const Board&) = delete;
    ~Board() = default;

    const BoardPaths& paths() const { return _paths; }

    std::expected<PadCounts, std::string> countPads() const;

    /// Resolves the net connected to one footprint's pin. `pin` is tried first as a pad number
    /// (PAD::GetNumber(), e.g. "3"), then as a schematic pin name (PAD::GetPinFunction(), e.g. "GND")
    /// if no pad matches by number.
    std::expected<std::string, std::string> netForFootprintPin(const std::string& footprintRef,
            const std::string& pin) const;

    /// The effective KiCad net class for one concrete net. Composite/pattern class resolution is left
    /// to KiCad; the returned name is exactly NETCLASS::GetName().
    std::expected<std::string, std::string> netClassForNet(const std::string& netName) const;

    /// Resolves one footprint's pin to its full pad identity (including position/orientation/layer and
    /// which net it's on) -- the same pad lookup as netForFootprintPin, but returning everything about
    /// that specific pad rather than just its net name. Used to match a footprint+pin selector
    /// (ExcitationConfig, a trace/differential-pair PortRef) back to one already-resolved port.
    std::expected<PadPosition, std::string> resolvePin(const std::string& footprintRef, const std::string& pin) const;

    /// Every net assigned to the given netclass (by name). Requires the board to have a linked
    /// project (a sibling .kicad_pro) for netclass assignment to be resolvable at all.
    std::expected<std::vector<std::string>, std::string> netsInNetClass(const std::string& netClassName) const;

    /// Every pad connected to the given net, with position/orientation/layer for port placement.
    std::expected<std::vector<PadPosition>, std::string> padsOnNet(const std::string& netName) const;

    /// Every straight PCB track segment connected to `netName`, with its actual KiCad width and copper
    /// layer. Vias and curved arcs are excluded because they are not valid MSL probe spans.
    std::expected<std::vector<TrackSegment>, std::string> tracksOnNet(const std::string& netName) const;

    /// Every copper zone/pour on the board (ground fills, rule areas, ...), one entry per copper layer
    /// each is actually on -- see ZoneInfo's own doc comment.
    std::expected<std::vector<ZoneInfo>, std::string> zones() const;

    /// Exact board outline, net-owned copper (including a zone/non-zone display distinction),
    /// solder-mask openings, and expanded front/back silkscreen from KiCad's BOARD model.
    std::expected<BoardGeometry, std::string> boardGeometry() const;

    /// Every layer enabled in the board file, including non-stackup technical/user layers.
    std::expected<std::vector<BoardLayerInfo>, std::string> boardLayers() const;

    /// Extract just one layer. This intentionally permits preview clients to schedule visible layers
    /// first instead of paying for every enabled layer before presenting their UI.
    std::expected<BoardLayerGeometry, std::string> boardLayerGeometry(const std::string& layerName) const;

    /// Every pad on the board regardless of net, in one single board load -- see
    /// detail::allPadsRaw()'s own doc comment for why this exists alongside padsOnNet().
    std::expected<std::vector<PadPosition>, std::string> allPads() const;

    /// Every PCB track centreline on the board regardless of net, paired with its own net name, in one
    /// single board load. Curved tracks are flattened into short connected segments; vias are returned
    /// separately by throughHoles().
    std::expected<std::vector<std::pair<std::string, TrackSegment>>, std::string> allTracks() const;

    /// The board's physical stackup (Board Setup > Board Stackup), top-to-bottom -- solder mask/paste/
    /// silkscreen entries are omitted, only copper and dielectric layers are returned. If the board's
    /// file has no explicit stackup section, this is KiCad's own computed default for its layer count,
    /// not an error.
    std::expected<std::vector<StackupLayer>, std::string> stackup() const;

    /// Every enabled board layer's configured color, from the currently active PCB color theme -- KiCad's own
    /// "layer colours" (Board Setup/Preferences > Colors), not something unique to this board; falls
    /// back to KiCad's built-in default theme if no other theme is resolvable for this process. Not
    /// layer order, and only covers layers the active theme has an entry for.
    std::expected<std::vector<LayerColor>, std::string> layerColors() const;

    /// Every net with a configured PCB color override. Explicit per-net colors win over the net's
    /// effective net-class color, exactly as KiCad's PCB renderer resolves them. Nets with neither
    /// kind of override are omitted and should use their copper-layer color.
    std::expected<std::vector<NetColor>, std::string> netColors() const;

    /// Every net class name assigned to at least one net on the board, deduplicated. Requires the
    /// board to have a linked project (a sibling .kicad_pro), same as netsInNetClass.
    std::expected<std::vector<std::string>, std::string> netClasses() const;

    /// Every net name on the board (excluding the unconnected pseudo-net).
    std::expected<std::vector<std::string>, std::string> allNets() const;

    /// Every footprint on the board, with its pins -- populates a "browse by footprint" UI without a
    /// separate round trip per footprint.
    std::expected<std::vector<FootprintInfo>, std::string> footprints() const;

    /// Every plated through-hole on the board -- both plain KiCad vias and through-hole footprint pads
    /// (e.g. a connector's SHIELD pin) -- with their real copper (annular ring / pad) and drill sizes.
    /// See ThroughHole's own doc comment; non-plated holes are never included.
    std::expected<std::vector<ThroughHole>, std::string> throughHoles() const;

    /// Every non-plated mechanical hole/slot on the board, read directly from NPTH footprint pads.
    std::expected<std::vector<NonPlatedHole>, std::string> nonPlatedHoles() const;

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
    std::expected<ComponentModelExportResult, std::string> exportComponentModels(const std::string& componentFilter,
            const std::string& outputStlPath) const;

private:
    struct Deleter {
        void operator()(detail::BoardState* state) const;
    };
    BoardPaths _paths;
    std::unique_ptr<detail::BoardState, Deleter> _state;
};

/// Bounds of a BoardGeometry's Edge.Cuts contours, in the geometry's native millimetre frame.
std::expected<BoardBounds, std::string> boardBounds(const BoardGeometry& geometry);

} // namespace libkicad
