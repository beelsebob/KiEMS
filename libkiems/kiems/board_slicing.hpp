// Slices the board down to one SimulationConfig's involved nets, per the "board slicing" design:
// build a padded region around the involved nets' own copper, keep only involved-net and
// ground-net copper within it, and stitch ground-net vias along the newly introduced cut edges.
// New feature, not ported from any Python source.
#pragma once

#include <cmath>
#include <cstdint>
#include <expected>
#include <functional>
#include <string>
#include <vector>

#include "config.hpp"
#include "importer.hpp"
#include "../../libkicad/libkicad.hpp"
#include "paths_config.hpp"
#include "polygon_geometry.hpp"

namespace kiems {

using Cu::BoundingBox;

enum class GeometryProcessingPhase { PolygonOperations, Triangulation, Finishing };

struct GeometryProcessingProgress {
    GeometryProcessingPhase phase = GeometryProcessingPhase::PolygonOperations;
    std::size_t completedPrimitives = 0;
    std::size_t totalPrimitives = 0;
};

using GeometryProcessingProgressCallback = std::function<void(const GeometryProcessingProgress&)>;

/// A via added purely to stitch a board-slicing cutout's newly-introduced edges back to a
/// plausible ground return. Connects every copper layer where the ground net's own (already
/// cutout-clipped) copper covers this position -- see sliceBoardForSimulation()'s doc comment.
/// Deliberately not a Hole subclass (a stitching via is placed by this codebase itself, never
/// loaded off the real board the way ViaHole/NPTHHole are) -- but path() has the same shape as
/// Hole::path() (a degenerate, coincident-endpoint centerline: a stitching via is always round) so
/// tessellateHoles() (board_slicing.cpp) can still tessellate a std::vector<StitchingVia> the same
/// templated way, aggregate-initialization (see placeStitchingVias()'s own StitchingVia{...} calls)
/// and JSON (de)serialization included, neither of which a Hole base class allows.
struct StitchingVia {
    double x = 0;
    double y = 0;
    double diameter = 0;            // Drill hole, from EMSConfig::via().stitchingViaHoleDiameter().
    double annularRingDiameter = 0; // Pad OD, from EMSConfig::via().stitchingViaAnnularRingDiameter().

    Cu::Polygon path() const {
        return {{x, y}, {x, y}};
    }
};

inline void to_json(nlohmann::json& j, const StitchingVia& v) {
    j = nlohmann::json{{"x", v.x}, {"y", v.y}, {"diameter", v.diameter}, {"annularRingDiameter", v.annularRingDiameter}};
}

inline void from_json(const nlohmann::json& j, StitchingVia& v) {
    j.at("x").get_to(v.x);
    j.at("y").get_to(v.y);
    j.at("diameter").get_to(v.diameter);
    j.at("annularRingDiameter").get_to(v.annularRingDiameter);
}

/// The board geometry actually fed to a Simulation for one SimulationConfig: only the involved
/// nets' and the ground net's own copper survive, with substrate/context clipped to a padded region
/// ("cutout") around every simulated net's own extent.
struct SlicedBoard {
    /// Per metal layer, the exact composited copper polygon loops after every hull/cutout Boolean
    /// operation, before triangulation. These are the authoritative XY mesh-density input: deriving
    /// density from the original KiCad board and clipping those hints later can retain fine spacing
    /// demanded only by copper that no longer exists in the sliced simulation. Kept separately from
    /// layerTriangles because triangle edges include artificial tessellation diagonals.
    std::vector<Cu::PolygonSet> layerCopperLoops;
    /// Per metal layer, in the same order as EMSConfig::getMetals(), the final triangulated copper
    /// for that layer (involved-net copper, plus ground-net copper wherever it falls inside the
    /// cutout) -- what Simulation::addContours() actually feeds the real FDTD geometry. Deliberately
    /// does *not* have via/NPTH holes cut out of it (unlike previewLayerTriangles below) -- see that
    /// field's own doc comment for why cutting them here used to seem harmless but measurably wasn't.
    std::vector<std::vector<Triangle>> layerTriangles;
    /// The same copper as layerTriangles, but with every via's own drilled hole and every NPTH hole
    /// additionally cut out -- for GeometryPreviewBridge's rendering only, *not* fed to the real FDTD
    /// geometry the way layerTriangles is. Cutting these holes is redundant for the real simulation
    /// (Simulation::addVia()'s own via metal/filling, and addNPTHHoles()'s own vacuum punch, both sit
    /// at CSXCAD priority well above copper's, so they already correctly override whatever copper is
    /// underneath regardless of whether it has a hole pre-cut) but *is* needed for a previewer with
    /// no such priority system, so a via's own open barrel/annular-ring geometry has real empty space
    /// to sit in rather than visually clipping through solid copper. This used to be the *only*
    /// version computed, shared by both consumers on the theory that computing it twice wasn't worth
    /// avoiding -- reverted once CSXCAD's own profiler showed the hole-cutting this implies (many
    /// small triangles around every via, each its own separate primitive) made real mesh generation
    /// dramatically slower: every extra small primitive gets checked at every quarter-cell query
    /// across the *entire* mesh, not just near where it actually sits, so a board with many vias paid
    /// that cost on every single simulation run for a purely cosmetic previewer need.
    std::vector<std::vector<Triangle>> previewLayerTriangles;
    /// This simulation's own outline (a single closed polygon loop), in the same coordinate frame
    /// as the rest of the pipeline (relative to the *original* board's Edge_Cuts origin, not
    /// re-origined to its own bounding box -- so xMin/yMin are generally nonzero, unlike the
    /// whole-board [0,pcbWidth] x [0,pcbHeight] convention), replacing Edge_Cuts for legacy/fallback
    /// sizing. Only the *largest* loop of the true cutout region (see cutoutLoops below), and
    /// therefore NOT a substitute for cutoutLoops wherever the true,
    /// possibly-disjoint/possibly-holed shape actually matters.
    std::vector<Position> outline;
    /// The true cutout region computed by sliceBoardForSimulation() -- every loop of it, not just
    /// the largest (unlike outline above): a spatially disjoint involved-net footprint produces more
    /// than one outer loop here, and Intersect()-ing against the real board outline can also leave
    /// genuine holes (opposite winding from their enclosing outer loop). grid_gen.cpp uses this for
    /// a real point-in-polygon membership test (mesh-DENSITY
    /// placement must only look at copper genuinely within the actual sliced geometry, not
    /// pre-cutout copper that happens to fall in outline's single-loop approximation's bounding
    /// region) -- ray-cast parity summed across every loop here handles both disjoint regions and
    /// holes correctly without needing to know which loops are holes ahead of time.
    std::vector<std::vector<Position>> cutoutLoops;
    /// Axis-aligned bounding box of `outline` above, in the same coordinate frame (relative to the
    /// *original* board's Edge_Cuts origin, not re-origined to its own bounding box) -- so
    /// bounds.xMin/yMin are generally nonzero, unlike the whole-board [0,pcbWidth] x [0,pcbHeight]
    /// convention. `bounds.xMax`/`bounds.yMax` replace the old separate width/height fields (still
    /// xMin + width/yMin + height, just not stored redundantly).
    BoundingBox<double> bounds;
    /// Ground-net stitching vias, placed only along cutout edges that don't already coincide with
    /// the board's real Edge_Cuts outline.
    std::vector<StitchingVia> stitchingVias;
    /// Every candidate stitching-via position that was considered along a new-cut edge but rejected
    /// (no ground copper there, intersecting non-ground trace/pad copper, or too close to another
    /// via) -- see
    /// sliceBoardForSimulation()'s doc
    /// comment and the "electrically floating" warning it logs
    /// when a whole run's candidates are all rejected. Kept purely for diagnostics/visualization (the
    /// geometry preview marks these with a black cross); never fed back into the FDTD geometry itself.
    std::vector<Position> failedStitchingViaAttempts;
    /// Every non-plated through-hole (mechanical/alignment hole -- e.g. a USB connector's elongated
    /// mounting slots) on the board, as an already-tessellated capsule/stadium polygon loop (one
    /// loop per hole, round holes included -- a capsule with coincident endpoints). Already
    /// subtracted from layerTriangles' own copper; kept here too so Simulation::addNPTHHoles() can
    /// cut the same holes out of the substrate model, which layerTriangles alone can't do.
    std::vector<std::vector<Position>> npthHoleLoops;
    /// The board's own solder mask coverage, in two different shapes for two different consumers:
    /// topMaskTriangles/bottomMaskTriangles is "coverage minus every opening", already triangulated
    /// (like layerTriangles), for GeometryPreviewBridge's rendering; topMaskOpeningLoops/
    /// bottomMaskOpeningLoops is the much smaller set of raw opening polygon loops themselves (one
    /// loop per exposed pad/via, mirroring npthHoleLoops' own shape exactly), for
    /// Simulation::addSolderMask() to punch out of a single big coverage box rather than extruding
    /// hundreds of small triangles as separate CSXCAD primitives -- confirmed via CSXCAD's own
    /// gprof-style profiler that doing the latter made mesh generation dramatically slower (every
    /// small extruded-polygon primitive gets checked at every quarter-cell material-averaging query
    /// across the *entire* mesh, not just near where it actually is, so primitive count matters far
    /// more than which of these two shapes is geometrically "correct" -- both represent the same
    /// mask, just via a different number of CSXCAD primitives). Both empty (not an error) if the
    /// board has no mask openings, or no solder mask stackup layer at all.
    std::vector<Triangle> topMaskTriangles;
    std::vector<Triangle> bottomMaskTriangles;
    std::vector<std::vector<Position>> topMaskOpeningLoops;
    std::vector<std::vector<Position>> bottomMaskOpeningLoops;
    /// Per metal layer (same order as layerCopperLoops), the part of every
    /// SimulationConfig::edgeTerminatedNets() net's copper lying within edgeTerminationWidth of the
    /// cut -- where Simulation::addEdgeTerminations() places its matched resistive sheet. Empty when
    /// no nets are edge-terminated.
    std::vector<Cu::PolygonSet> edgeTerminationLoops;
    double edgeTerminationWidth = 0;
};

/// Serialized/deserialized whole -- see simulation_data.hpp's saveSimulationData()/
/// loadSimulationData(), which persist a SlicedBoard as part of a SimulationData<Grid>'s own
/// on-disk representation, replacing the old geometry.xml CSXCAD dump.
inline void to_json(nlohmann::json& j, const SlicedBoard& b) {
    j = nlohmann::json{{"layerCopperLoops", b.layerCopperLoops}, {"layerTriangles", b.layerTriangles},
                        {"outline", b.outline},       {"bounds", b.bounds},
                        {"stitchingVias", b.stitchingVias},   {"npthHoleLoops", b.npthHoleLoops},
                        {"failedStitchingViaAttempts", b.failedStitchingViaAttempts},
                        {"topMaskTriangles", b.topMaskTriangles}, {"bottomMaskTriangles", b.bottomMaskTriangles},
                        {"topMaskOpeningLoops", b.topMaskOpeningLoops},
                        {"bottomMaskOpeningLoops", b.bottomMaskOpeningLoops},
                        {"previewLayerTriangles", b.previewLayerTriangles},
                        {"cutoutLoops", b.cutoutLoops}};
    if (!b.edgeTerminationLoops.empty()) {
        j["edgeTerminationLoops"] = b.edgeTerminationLoops;
        j["edgeTerminationWidth"] = b.edgeTerminationWidth;
    }
}

inline void from_json(const nlohmann::json& j, SlicedBoard& b) {
    if (j.contains("layerCopperLoops")) {
        j.at("layerCopperLoops").get_to(b.layerCopperLoops);
    }
    j.at("layerTriangles").get_to(b.layerTriangles);
    j.at("outline").get_to(b.outline);
    // "bounds" replaced the old flat xMin/yMin/width/height fields -- fall back to reconstructing
    // it from those so a geometry.json cached before this field existed still loads.
    if (j.contains("bounds")) {
        j.at("bounds").get_to(b.bounds);
    } else {
        double xMin = 0;
        double yMin = 0;
        double width = 0;
        double height = 0;
        j.at("xMin").get_to(xMin);
        j.at("yMin").get_to(yMin);
        j.at("width").get_to(width);
        j.at("height").get_to(height);
        b.bounds.xMin = xMin;
        b.bounds.yMin = yMin;
        b.bounds.xMax = xMin + width;
        b.bounds.yMax = yMin + height;
    }
    j.at("stitchingVias").get_to(b.stitchingVias);
    j.at("npthHoleLoops").get_to(b.npthHoleLoops);
    // Absent in geometry.json written before this field existed -- defaults to empty rather than
    // failing to load an otherwise-valid cached geometry stage.
    if (j.contains("failedStitchingViaAttempts")) {
        j.at("failedStitchingViaAttempts").get_to(b.failedStitchingViaAttempts);
    }
    if (j.contains("topMaskTriangles")) {
        j.at("topMaskTriangles").get_to(b.topMaskTriangles);
    }
    if (j.contains("bottomMaskTriangles")) {
        j.at("bottomMaskTriangles").get_to(b.bottomMaskTriangles);
    }
    if (j.contains("topMaskOpeningLoops")) {
        j.at("topMaskOpeningLoops").get_to(b.topMaskOpeningLoops);
    }
    if (j.contains("bottomMaskOpeningLoops")) {
        j.at("bottomMaskOpeningLoops").get_to(b.bottomMaskOpeningLoops);
    }
    // Absent in geometry.json written before previewLayerTriangles existed as its own field (back
    // when layerTriangles itself was shared, hole-cut, by both the simulation and the preview) --
    // falls back to layerTriangles itself so an old cached geometry stage still renders something
    // reasonable (copper without via holes visually cut) rather than blank, until the next real
    // geometry rebuild recomputes this properly.
    if (j.contains("previewLayerTriangles")) {
        j.at("previewLayerTriangles").get_to(b.previewLayerTriangles);
    } else {
        b.previewLayerTriangles = b.layerTriangles;
    }
    // Absent in geometry.json written before cutoutLoops existed -- defaults to empty, which
    // grid_gen.cpp's own point-in-polygon filter treats as "no polygon filtering, bbox only" (this
    // function's original, less precise behaviour) rather than failing to load an otherwise-valid
    // cached geometry stage.
    if (j.contains("cutoutLoops")) {
        j.at("cutoutLoops").get_to(b.cutoutLoops);
    }
    if (j.contains("edgeTerminationLoops")) {
        j.at("edgeTerminationLoops").get_to(b.edgeTerminationLoops);
        b.edgeTerminationWidth = j.value("edgeTerminationWidth", 0.0);
    }
}

/// Everything sliceBoardForSimulation()/placeStitchingVias() (via_stitching.hpp) need from a
/// SimulationConfig and an EMSConfig, pulled out into their own plain struct -- not the whole
/// SimulationConfig/EMSConfig, whose every other field (net selectors, grid, frequency, substrate
/// layers, ...) has nothing to do with slicing a board or stitching a via. Also carries no
/// simulation name (unlike SimulationConfig) -- a caller that wants one in its logs should log it
/// once, itself, before calling either function; see sliceBoardForSimulation()'s own doc comment for
/// why neither logs one internally. Fields are named to match their SimulationConfig/EMSConfig
/// source fields exactly, and are expected in the same simulation-unit space as the geometry passed
/// alongside them (a caller reads these off SimulationConfig/EMSConfig after EMSConfig::
/// scaledToSimulationUnits()).
struct SlicingConfig {
    /// Uniform fallback used only by the low-level overload that is handed flat copper rather than
    /// ClassifiedCopper::hullContributions. Production configuration no longer has a simulation-
    /// wide hull-padding option; SlicingConfig::from() leaves this at zero.
    double hullPadding = 0;
    double viaEdgeDistance = 0;
    double viaSpacing = 0;
    /// Real via annular-ring half-width -- see ExistingVia::outerRadius's own use (via_stitching.cpp).
    double platingThickness = 0;
    double stitchingViaHoleDiameter = 0;
    double stitchingViaAnnularRingDiameter = 0;
    double viaClearance = 0;
    /// Copper-geometry tessellation tolerance -- EMSConfig::pixelSize(), still in file units (a plain
    /// pixel/micron count, not itself scaled by EMSConfig::scaledToSimulationUnits()); sliceBoardForSimulation()
    /// multiplies it by constants::unitMultiplier itself, exactly as it always has.
    std::int32_t pixelSize = 5;
    /// Every metal layer's own KiCad layer name, in the same order as EMSConfig::getMetals() (and
    /// thus SlicedBoard::layerTriangles) -- the only piece of an EMSConfig::getMetals() (a
    /// std::vector<LayerConfig>, carrying substrate/mask thickness and epsilon fields no slicing code
    /// ever reads) sliceBoardForSimulation() actually needs: which layer each involved/geometry-only/
    /// ground CopperPolygon's own copperLayerName should be matched against, per output layer index.
    std::vector<std::string> layerNames;
    /// SimulationConfig::edgeTerminatedNets(): involved/geometry-only copper on these nets gets a
    /// SlicedBoard::edgeTerminationLoops entry wherever it lies within edgeTerminationWidth of the cut.
    std::vector<std::string> edgeTerminatedNets;
    /// Width of that band inward from the cut, in simulation units -- the grid's maximum cell size,
    /// so the band always covers at least one column of Yee edges.
    double edgeTerminationWidth = 0;

    /// Builds one from `sim`'s own viaEdgeDistance()/viaSpacing() and `config`'s own
    /// via()/pixelSize()/getMetals() -- the two real sources every caller reads these fields off, so
    /// this is the one place that mapping is written down rather than repeated at each call site.
    static SlicingConfig from(const SimulationConfig& sim, const EMSConfig& config);
};

/// `sim`'s simulated-net, geometry-only-net, and ground-net copper, split
/// out of a whole-board
/// libkicad::BoardGeometry -- the (IO-performing) net-name-resolution step of board slicing,
/// kept separate from sliceBoardForSimulation() itself so that function can stay a pure geometry
/// algorithm exercisable directly against hand-built CopperPolygon fixtures, with no PathsConfig/
/// board reload needed. See NetInclusionLevel's own doc comment (config.hpp) for
/// what governs the involved/geometry-only split; a polygon is independently eligible for more than
/// one bucket (e.g. nothing stops a net appearing in both an involved-net entry and the ground-net
/// selector), matching how the selectors are resolved as independent net-name sets.
struct ClassifiedCopper {
    struct HullContribution {
        std::vector<libkicad::CopperPolygon> copper;
        double padding = 0;
    };
    std::vector<libkicad::CopperPolygon> involved;
    std::vector<libkicad::CopperPolygon> geometryOnly;
    std::vector<libkicad::CopperPolygon> ground;
    /// One group per SimulationNet entry, retaining its own padding so the cutout can be the union
    /// of individually expanded selectors. Empty groups are harmless and diagnose naturally if
    /// every contributing selector resolves to no copper.
    std::vector<HullContribution> hullContributions;
};

std::expected<BoundingBox<double>, std::string> boardBoundsInSimulationUnits(
    const libkicad::BoardGeometry& geometry);

std::expected<ClassifiedCopper, std::string> classifyCopperForSimulation(const SimulationConfig& sim,
                                                                           const libkicad::BoardGeometry& geometry,
                                                                           const libkicad::Board& board);

std::expected<std::vector<std::string>, std::string> resolveInvolvedNetNames(
    const libkicad::Board& board, const InvolvedNetConfig& entry);
std::expected<std::vector<std::string>, std::string> resolveGroundNetNames(
    const libkicad::Board& board, const GroundNetConfig& ground);

/// Slices a simulation's board geometry, given `slicing` (see SlicingConfig's own doc comment).
/// `geometry`, the three net-classified copper polygon lists (see classifyCopperForSimulation(),
/// which is how a real caller obtains them), `existingVias`, and `npthHoles` are all supplied by the
/// caller, already resolved against the real board -- this function itself performs no net-name
/// resolution, does not load a libkicad::BoardGeometry, and takes no PathsConfig at all: a
/// pure geometry algorithm, exercisable directly against hand-built fixtures with no board-load/
/// subprocess IO anywhere in its own call graph. `existingVias`/`npthHoles` are the real board's own
/// getVias()/getNPTHHoles() results (both ordinarily best-effort -- see boardBoundsInSimulationUnits()'s
/// own doc comment for how a caller derives the origin to call them with; an empty vector here means
/// either a board with none, or a caller that treated its own query failure as "found none", exactly
/// as this function used to do internally). Takes no SimulationConfig/EMSConfig directly (nor logs a
/// simulation name anywhere) for the same reason placeStitchingVias() doesn't -- see SlicingConfig's
/// own doc comment; a caller that wants a name in its logs should log it once, itself, before
/// calling. Algorithm:
/// 1. Per copper layer, union each of involvedCopper/geometryOnlyCopper/groundCopper
///    separately.
/// 2. Expand each simulated selector's copper by its own HullContribution::padding, then union the
///    results across every layer -- this is the cutout region. Adding a net to the Simulated set therefore
///    expands the surrounding substrate/ground region whether or not that net has an excitation.
///    Geometry-only entries remain clipped to this cutout and never grow it. (No separate
///    concave-hull/alpha-shape algorithm: inflating the simulated nets' own copper union by a real
///    physical distance already
///    produces a reasonably-shaped, non-convex enclosing region without a new geometry-algorithm
///    dependency -- a deliberate approximation, worth revisiting if it looks too jagged on a real
///    board.) Intersected against the board's real Edge_Cuts outline (`geometry.outline`) so the
///    cutout never extends past the real board edge.
/// 3. Per layer, final copper = involved-net composite (already inside the cutout by construction)
///    unioned with ground-net composite intersected with the cutout, minus every non-plated
///    through-hole (NPTH) on the board -- a mechanical/alignment hole (e.g. a USB connector's
///    elongated mounting slots) has no copper of its own in KiCad's copper polygons, so
///    nothing upstream already carves it out of a zone/plane pour that happens to cover that area;
///    it's subtracted explicitly here, as a capsule/stadium shape so an elongated slot comes out
///    elongated rather than as a hole only at its center point.
/// 4. Places stitching vias -- see placeStitchingVias() (via_stitching.hpp) for the full rule and
///    rationale; `slicing` is forwarded to it unchanged. Routed traces and footprint pads on
///    non-ground nets block a candidate when they intersect its annular ring; non-ground zones do
///    not.
std::expected<SlicedBoard, std::string> sliceBoardForSimulation(
    const SlicingConfig& slicing, const libkicad::BoardGeometry& geometry,
    const std::vector<libkicad::CopperPolygon>& involvedCopper,
    const std::vector<libkicad::CopperPolygon>& geometryOnlyCopper,
    const std::vector<libkicad::CopperPolygon>& groundCopper,
    const std::vector<ClassifiedCopper::HullContribution>& hullContributions,
    const std::vector<ViaHole>& existingVias,
    const std::vector<NPTHHole>& npthHoles,
    const GeometryProcessingProgressCallback& onProgress = {});

/// The part of a SlicedBoard that interactive setup UI needs -- where the cut falls and where
/// stitching vias would go -- without any of the per-layer copper Booleans, solder mask
/// preparation, or triangulation that only the real geometry stage consumes.
struct SlicedBoardPlan {
    std::vector<std::vector<Position>> cutoutLoops;
    std::vector<StitchingVia> stitchingVias;
    std::vector<Position> failedStitchingViaAttempts;
};

/// Steps 1, 2 and 4 of sliceBoardForSimulation() only, with identical results for the fields
/// SlicedBoardPlan carries (both functions share the same implementation of those steps) and the
/// same errors for an empty net selection or cutout. Skips step 3 and every triangulation, which
/// dominate sliceBoardForSimulation()'s cost on a real board.
std::expected<SlicedBoardPlan, std::string> planSlicedBoardForSimulation(
    const SlicingConfig& slicing, const libkicad::BoardGeometry& geometry,
    const std::vector<libkicad::CopperPolygon>& involvedCopper,
    const std::vector<libkicad::CopperPolygon>& groundCopper,
    const std::vector<ClassifiedCopper::HullContribution>& hullContributions,
    const std::vector<ViaHole>& existingVias);

/// Low-level compatibility overload for geometry fixtures that provide one flat contributing
/// copper set. Production callers pass ClassifiedCopper::hullContributions to the overload above.
std::expected<SlicedBoard, std::string> sliceBoardForSimulation(
    const SlicingConfig& slicing, const libkicad::BoardGeometry& geometry,
    const std::vector<libkicad::CopperPolygon>& involvedCopper,
    const std::vector<libkicad::CopperPolygon>& geometryOnlyCopper,
    const std::vector<libkicad::CopperPolygon>& groundCopper, const std::vector<ViaHole>& existingVias,
    const std::vector<NPTHHole>& npthHoles,
    const GeometryProcessingProgressCallback& onProgress = {});

/// Removes auto-discovered lumped R/L/C components whose two pad centres both lie outside the
/// board cutout. Called immediately after slicing (and after loading cached sliced geometry), so
/// subsequent grid generation and FDTD construction see exactly the passives that physically
/// intersect the retained simulation region.
void restrictLumpedComponentsToCutout(SimulationConfig& simulation, const SlicedBoard& board);

} // namespace kiems
