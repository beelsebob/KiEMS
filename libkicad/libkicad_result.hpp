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
    Core,           // rigid dielectric (FR4 etc.)
    Prepreg,        // bonding-film dielectric between core layers
    SolderMaskTop,
    SolderMaskBottom,
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
/// use, i.e. kiems's own native frame, needing no further conversion by callers.
struct PadPosition {
    std::string footprintRef;
    std::string padNumber;
    std::string netName;
    /// KiCad's canonical schematic electrical type (for example "input", "bidirectional", or
    /// "power_in"). Empty when the PCB pad has no linked schematic pin metadata.
    std::string pinType;
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

/// One straight routed copper segment. Curved PCB arcs and vias are deliberately omitted by
/// tracksOnNet(): an MSL impedance probe needs a locally straight propagation axis and belongs on
/// one copper layer. Coordinates use the same auxiliary-origin-relative, Y-up millimetre frame as
/// PadPosition.
struct TrackSegment {
    double startXMm = 0;
    double startYMm = 0;
    double endXMm = 0;
    double endYMm = 0;
    double widthMm = 0;
    std::string copperLayerName;
};

/// One pad on a footprint, identified the same way PadPosition/ExcitationConfig/InvolvedNetConfig
/// selectors do: a pad number (tried first when matching) and, if present, a schematic pin
/// function name (e.g. "GND") -- see libkicad.cpp's _findFootprintPad for the matching order this
/// mirrors.
struct FootprintPin {
    std::string number;
    std::string function; // empty if the pad has no assigned pin function
    std::string netName; // empty if the pad isn't connected to any net
    std::string pinType; // KiCad schematic electrical type; empty when unavailable
};

/// One footprint on the board: its reference designator, KiCad's "Value" field text (e.g. "100nF",
/// "10k" -- empty if unset), and every pad on it. Used to populate a "browse by footprint, then pick
/// a pin" UI -- see footprints().
struct FootprintInfo {
    std::string reference;
    std::string value;
    std::vector<FootprintPin> pins;
};

/// One enabled layer's configured display color, from the currently active PCB color theme (see
/// layerColors()) -- `hex` is `COLOR4D::ToHexString()`'s own format ("#RRGGBB" or "#RRGGBBAA").
struct LayerColor {
    std::string name; // KiCad board-layer name, e.g. "F.Cu", "F.Fab", or "Edge.Cuts"
    std::string hex;
};

/// The effective PCB-editor color override for one net. KiCad stores explicit per-net colors and
/// net-class colors separately in the project file; the PCB renderer gives an explicit net color
/// precedence over the net's effective (possibly composite) net-class color. `netColors()` exposes
/// that resolved result so clients do not need to reproduce KiCad's net-class matching rules.
struct NetColor {
    std::string name;
    std::string hex; // COLOR4D::ToHexString(), "#RRGGBB" or "#RRGGBBAA"
};

/// One plated through-hole feature on the board -- either a plain KiCad via (PCB_VIA, not tied to
/// any footprint) or a through-hole pad on a footprint (PAD_ATTRIB::PTH, e.g. a connector's SHIELD
/// pin). Non-plated holes (PAD_ATTRIB::NPTH) are never included -- those have no copper at all, a
/// fundamentally different feature (see kiems::NPTHHole). Position is in millimetres, relative
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
    /// Rotation of the drill's local X axis in KiCad board coordinates. Needed to reconstruct the
    /// centerline of an oblong drill without round-tripping through an Excellon G85 record.
    double orientationDeg = 0;
};

/// One non-plated footprint-pad hole. KiCad represents both round mechanical holes and routed
/// slots as NPTH pads; the drill width/height plus orientation describe either exactly. Unlike a
/// ThroughHole this has no copper annulus and is only subtracted from board materials.
struct NonPlatedHole {
    double xMm = 0;
    double yMm = 0;
    double drillWidthMm = 0;
    double drillHeightMm = 0;
    double orientationDeg = 0;
};

/// One copper zone/pour's outline, on one of the copper layers it's filled on -- a single ZONE
/// object emits one ZoneInfo per copper layer in its own layer set, sharing the same outline (KiCad
/// zones use one drawn outline shape across every layer they're assigned to; the *filled* shape
/// differs per layer once clearances/thermal reliefs are applied, but that finer detail isn't
/// captured here -- outlineMm is the raw, undjusted outline, always a conservative (equal or larger)
/// bound on the real filled copper). Only the outer contour of the outline is returned (any cutouts
/// drawn inside it are ignored), which is also conservative -- treating a real cutout as if it were
/// still filled copper only ever makes this *more* cautious about calling a location "occupied",
/// never less. netName is empty for a rule area / keepout zone with no copper connection.
struct ZoneInfo {
    std::string netName;
    std::string copperLayerName;
    /// Outer contour only, in the same auxiliary-origin-relative millimetre frame as PadPosition.
    std::vector<std::pair<double, double>> outlineMm;
};

/// One polygon contour from KiCad geometry. Holes are kept explicit so the subprocess wire format
/// does not depend on winding conventions changing when KiCad's Y-down coordinates are converted
/// to kiems's Y-up frame.
struct PolygonLoop {
    bool hole = false;
    std::vector<std::pair<double, double>> pointsMm;
};

/// One net-owned copper contour on one physical copper layer.
struct CopperPolygon {
    std::string netName;
    std::string copperLayerName;
    /// True when this polygon came from a filled zone rather than a track or pad. Consumers use
    /// this distinction only for display opacity; it remains ordinary copper geometry.
    bool zone = false;
    /// Populated only when this contour came from a footprint pad. Together these preserve the
    /// physical pin identity through the whole-board triangulation path; tracks/vias and zones
    /// leave both empty.
    std::string footprintRef;
    std::string padNumber;
    PolygonLoop loop;
};

/// One silkscreen contour, optionally owned by a footprint. Board-level drawings leave
/// footprintRef empty; footprint graphics/text retain their reference so display clients can
/// visually de-emphasise silk belonging to components outside the selected simulation.
struct SilkscreenPolygon {
    std::string footprintRef;
    PolygonLoop loop;
};

/// Geometry needed by libkiems, extracted from the loaded BOARD without plotting Gerbers.
struct BoardGeometry {
    std::vector<PolygonLoop> outline;
    std::vector<CopperPolygon> copper;
    std::vector<PolygonLoop> frontMaskOpenings;
    std::vector<PolygonLoop> backMaskOpenings;
    std::vector<SilkscreenPolygon> frontSilkscreen;
    std::vector<SilkscreenPolygon> backSilkscreen;
};

/// One enabled layer from the board file, in KiCad's own display/layer order.  This is deliberately
/// separate from the physical stackup: documentation, fabrication, adhesive, courtyard and other
/// technical layers have no stackup entry but are still valid preview layers.
struct BoardLayerInfo {
    std::string name;
    bool copper = false;
    bool solderMask = false;
};

/// Geometry for one enabled board layer. Copper retains the ownership metadata used by the setup
/// screen's picking/highlighting path. Other layers are anonymous filled contours. For solder mask
/// KiCad returns the apertures, so callers form the visible coating by subtracting these contours
/// from the board outline.
struct BoardLayerGeometry {
    BoardLayerInfo layer;
    std::vector<CopperPolygon> copper;
    std::vector<PolygonLoop> contours;
    std::vector<PolygonLoop> boardOutline;
};

struct BoardBounds {
    double xMinMm = 0;
    double xMaxMm = 0;
    double yMinMm = 0;
    double yMaxMm = 0;
};

/// One mesh triangle of a footprint's real, placed 3D model -- mirrors STEP_COMPONENT_TRIANGLE
/// (libkicad/step_export/component_triangle.h). Vertex positions are absolute, in millimetres, in
/// the same board-auxiliary-origin-relative frame every other libkicad position (PadPosition,
/// ThroughHole, ...) uses when `--use-drill-origin`/m_UseDrillOrigin is set, which
/// exportComponentModels() always does. Color is straight from the model's own STEP colors
/// (XCAFDoc_ColorTool, the same source WriteSTEP/WriteGLTF preserve); (1,1,1,1) if the model
/// carries none, each channel 0-1.
struct ComponentTriangle {
    double ax = 0, ay = 0, az = 0;
    double bx = 0, by = 0, bz = 0;
    double cx = 0, cy = 0, cz = 0;
    double r = 0, g = 0, b = 0, a = 0;
    std::string footprintReference;
};

/// Result of exporting specific footprints' own real, placed 3D models (via
/// EXPORTER_STEP/STEP_PCB_MODEL, the same machinery `kicad-cli pcb export stl` itself uses, run
/// in-process instead of as a second subprocess) -- see exportComponentModels()'s own doc comment.
/// `messages` is every diagnostic KiCad's own exporter reported while building the requested
/// components' shapes, one entry per line of REPORTER output -- a component whose linked 3D model
/// file can't be resolved reports two consecutive entries here, "Could not add 3D model for <ref>."
/// then "File not found: <path>" (the exact text kicad-cli's own CLI export prints too) -- this is
/// non-fatal, `exportSucceeded` stays true and `triangles` still has every other requested
/// component's mesh.
struct ComponentModelExportResult {
    bool exportSucceeded = false;
    std::vector<std::string> messages;
    std::vector<ComponentTriangle> triangles;
    /// The board's real top-copper mounting surface Z, in the same millimetre frame `triangles`'
    /// own vertices are in -- mirrors STEP_PCB_MODEL::GetTopCopperZ()'s own doc comment for exactly
    /// what this is and why a caller placing these triangles into a *different* Z=0 convention
    /// (one where every copper layer is treated as infinitesimally thin, with no copper-thickness
    /// contribution to board Z at all) needs this specific value rather than deriving an equivalent
    /// offset from stackup thickness alone: `triangles`' own Z minus this value is exactly that
    /// caller's own "height above the top-copper surface," ready to add onto that convention's own
    /// Z=0 directly.
    double topCopperZMm = 0;
};

namespace detail {

/// Opaque across the c++20/c++23 boundary; both are defined in libkicad.cpp. See libkicad::Runtime
/// and libkicad::Board, which own one each.
struct RuntimeState;
struct BoardState;

/// Initializes KiCad's process-wide runtime (if not already) and returns a new RuntimeState, or
/// nullptr with `error` set.
RuntimeState* createRuntimeRaw(std::string& error);
void destroyRuntimeRaw(RuntimeState* runtime);

/// A board that loads lazily on its first query. Must be destroyed before `runtime`.
BoardState* createBoardRaw(RuntimeState& runtime, std::string projectPath, std::string boardPath);
void destroyBoardRaw(BoardState* board);

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

struct RawTracksOnNetResult {
    bool ok = false;
    std::string error;
    std::vector<TrackSegment> tracks;
};

/// Every straight PCB track segment on the board regardless of net, paired with its own net name --
/// TrackSegment itself has no net field (tracksOnNetRaw() doesn't need one, since the net is already
/// the query's own parameter there). See allPadsRaw()'s own doc comment for why an "every net at
/// once" query exists alongside the per-net ones.
struct RawAllTracksResult {
    bool ok = false;
    std::string error;
    std::vector<std::pair<std::string, TrackSegment>> tracks; // (netName, segment)
};

struct RawZonesResult {
    bool ok = false;
    std::string error;
    std::vector<ZoneInfo> zones;
};

struct RawBoardGeometryResult {
    bool ok = false;
    std::string error;
    BoardGeometry geometry;
};

struct RawBoardLayersResult {
    bool ok = false;
    std::string error;
    std::vector<BoardLayerInfo> layers;
};

struct RawBoardLayerGeometryResult {
    bool ok = false;
    std::string error;
    BoardLayerGeometry geometry;
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

struct RawNetColorsResult {
    bool ok = false;
    std::string error;
    std::vector<NetColor> colors;
};

RawPadCountsResult countPadsRaw(BoardState& board);

RawNetNameResult netForFootprintPinRaw(BoardState& board, const std::string& footprintRef, const std::string& pin);

/// The highest-priority constituent of the effective net class KiCad resolves for one concrete
/// net. Reuses RawNetNameResult's single string payload across the C++20/C++23 boundary; its
/// `netName` field contains the class.
RawNetNameResult netClassForNetRaw(BoardState& board, const std::string& netName);

RawPadResult resolvePinRaw(BoardState& board, const std::string& footprintRef, const std::string& pin);

RawNetClassMembersResult netsInNetClassRaw(BoardState& board, const std::string& netClassName);

RawPadsOnNetResult padsOnNetRaw(BoardState& board, const std::string& netName);

RawTracksOnNetResult tracksOnNetRaw(BoardState& board, const std::string& netName);

/// Every pad on the board regardless of net (PadPosition::netName is still populated per pad) --
/// unlike looping allNets()+padsOnNet() per net, this is one single board load, not one per net. See
/// kiems::LumpedComponentConfig's own doc comment on the diagonal-part cardinal-bridge
/// interference check for why that matters: a real board can have on the order of a hundred nets,
/// and each public query may otherwise reload and reparse the whole board from
/// scratch.
RawPadsOnNetResult allPadsRaw(BoardState& board);

RawAllTracksResult allTracksRaw(BoardState& board);

RawZonesResult zonesRaw(BoardState& board);

RawBoardGeometryResult boardGeometryRaw(BoardState& board);

RawBoardLayersResult boardLayersRaw(BoardState& board);

RawBoardLayerGeometryResult boardLayerGeometryRaw(BoardState& board, const std::string& layerName);

RawStackupResult stackupRaw(BoardState& board);

RawLayerColorsResult layerColorsRaw(BoardState& board);

RawNetColorsResult netColorsRaw(BoardState& board);

RawStringListResult netClassesRaw(BoardState& board);

RawStringListResult allNetsRaw(BoardState& board);

RawFootprintsResult footprintsRaw(BoardState& board);

struct RawThroughHolesResult {
    bool ok = false;
    std::string error;
    std::vector<ThroughHole> holes;
};

RawThroughHolesResult throughHolesRaw(BoardState& board);

struct RawNonPlatedHolesResult {
    bool ok = false;
    std::string error;
    std::vector<NonPlatedHole> holes;
};

RawNonPlatedHolesResult nonPlatedHolesRaw(BoardState& board);

struct RawComponentModelExportResult {
    bool ok = false;
    std::string error;
    ComponentModelExportResult result;
};

RawComponentModelExportResult exportComponentModelsRaw(BoardState& board, const std::string& componentFilter,
                                                          const std::string& outputStlPath);

} // namespace detail
} // namespace libkicad
