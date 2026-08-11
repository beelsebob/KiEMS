// Slices the board down to one SimulationConfig's involved nets, per the "board slicing" design:
// build a padded region around the involved nets' own copper, keep only involved-net and
// ground-net copper within it, and stitch ground-net vias along the newly introduced cut edges.
// New feature, not ported from any Python source.
#pragma once

#include <cstdint>
#include <expected>
#include <string>
#include <vector>

#include "config.hpp"
#include "importer.hpp"
#include "paths_config.hpp"

namespace gerber2ems {

/// A via added purely to stitch a board-slicing cutout's newly-introduced edges back to a
/// plausible ground return. Connects every copper layer where the ground net's own (already
/// cutout-clipped) copper covers this position -- see sliceBoardForSimulation()'s doc comment.
struct StitchingVia {
    double x = 0;
    double y = 0;
    double diameter = 0;            // Drill hole, from EMSConfig::via().stitchingViaHoleDiameter().
    double annularRingDiameter = 0; // Pad OD, from EMSConfig::via().stitchingViaAnnularRingDiameter().
};

/// The board geometry actually fed to a Simulation for one SimulationConfig: only the involved
/// nets' and the ground net's own copper survive, clipped to a padded region ("cutout") around the
/// involved nets' own extent.
struct SlicedBoard {
    /// Per metal layer, in the same order as EMSConfig::getMetals(), the final
    /// triangulated copper for that layer (involved-net copper, plus ground-net copper wherever it
    /// falls inside the cutout).
    std::vector<std::vector<Triangle>> layerTriangles;
    /// This simulation's own outline (a single closed polygon loop), in the same coordinate frame
    /// as the rest of the pipeline (relative to the *original* board's Edge_Cuts origin, not
    /// re-origined to its own bounding box -- so xMin/yMin are generally nonzero, unlike the
    /// whole-board [0,pcbWidth] x [0,pcbHeight] convention), replacing Edge_Cuts for
    /// substrate/plane sizing.
    std::vector<Position> outline;
    double xMin = 0;
    double yMin = 0;
    double width = 0;
    double height = 0;
    /// Ground-net stitching vias, placed only along cutout edges that don't already coincide with
    /// the board's real Edge_Cuts outline.
    std::vector<StitchingVia> stitchingVias;
    /// Every non-plated through-hole (mechanical/alignment hole -- e.g. a USB connector's elongated
    /// mounting slots) on the board, as an already-tessellated capsule/stadium polygon loop (one
    /// loop per hole, round holes included -- a capsule with coincident endpoints). Already
    /// subtracted from layerTriangles' own copper; kept here too so Simulation::addNPTHHoles() can
    /// cut the same holes out of the substrate model, which layerTriangles alone can't do.
    std::vector<std::vector<Position>> npthHoleLoops;
};

/// Slices `sim`'s board geometry. Algorithm:
/// 1. Resolve involved-net and ground-net names (libkicad_query, same as port_resolution.cpp).
/// 2. Per copper layer, composite involved-net copper and ground-net copper separately (filtering
///    CopperOp::net -- see gerber_composite.hpp's compositeOps()).
/// 3. Union the involved-net composite across every layer into one 2D shape and inflate it by
///    sim.hullPadding() -- this is the cutout region. (No separate concave-hull/alpha-shape
///    algorithm: inflating the involved nets' own copper union by a real physical distance already
///    produces a reasonably-shaped, non-convex enclosing region without a new geometry-algorithm
///    dependency -- a deliberate approximation, worth revisiting if it looks too jagged on a real
///    board.) Intersected against the board's real Edge_Cuts outline so the cutout never extends
///    past the real board edge.
/// 4. Per layer, final copper = involved-net composite (already inside the cutout by construction)
///    unioned with ground-net composite intersected with the cutout, minus every non-plated
///    through-hole (NPTH) on the board -- a mechanical/alignment hole (e.g. a USB connector's
///    elongated mounting slots) has no copper of its own and never appears in any copper Gerber, so
///    nothing upstream already carves it out of a zone/plane pour that happens to cover that area;
///    it's subtracted explicitly here, as a capsule/stadium shape so an elongated slot comes out
///    elongated rather than as a hole only at its center point.
/// 5. Classify the cutout boundary against the real Edge_Cuts outline: segments lying on/near it
///    are pre-existing edges (no stitching -- the real board already provides a return path there);
///    every other segment is a new cut. Adjacent new-cut segments are joined into contiguous runs
///    first (the boundary comes out of Clipper2 tessellated into many short segments, so spacing
///    vias per raw segment would badly over-place them -- see the .cpp for detail); stitching vias
///    are then placed along each run's own arc length, at sim.viaEdgeDistance() inward, spaced
///    sim.viaSpacing() apart, connecting through whichever layers the (cutout-clipped) ground
///    composite covers at that position. A candidate is dropped if it would sit closer than
///    config.via().viaClearance() (edge-to-edge) to any other via -- real or already placed here,
///    any net -- or closer than sim.viaSpacing() to any real or already-placed *ground-net* via
///    specifically (a stitching via is itself always ground, so this keeps freshly-placed ones that
///    spacing apart from each other too, not just from the board's own vias).
std::expected<SlicedBoard, std::string> sliceBoardForSimulation(const SimulationConfig& sim, const EMSConfig& config,
                                                                  const PathsConfig& paths);

} // namespace gerber2ems
