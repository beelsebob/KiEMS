// Slices the board down to one SimulationConfig's involved nets, per the "board slicing" design:
// build a padded region around the involved nets' own copper, keep only involved-net and
// ground-net copper within it, and stitch ground-net vias along the newly introduced cut edges.
// New feature, not ported from any Python source.
#pragma once

#include <cstdint>
#include <vector>

#include "config.hpp"
#include "importer.hpp"

namespace gerber2ems {

/// A via added purely to stitch a board-slicing cutout's newly-introduced edges back to a
/// plausible ground return. Connects every copper layer where the ground net's own (already
/// cutout-clipped) copper covers this position -- see sliceBoardForSimulation()'s doc comment.
struct StitchingVia {
    double x = 0;
    double y = 0;
    double diameter = 0;
};

/// The board geometry actually fed to a Simulation for one SimulationConfig: only the involved
/// nets' and the ground net's own copper survive, clipped to a padded region ("cutout") around the
/// involved nets' own extent.
struct SlicedBoard {
    /// Per metal layer, in the same order as Config::sharedConfig().getMetals(), the final
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
///    unioned with ground-net composite intersected with the cutout.
/// 5. Classify the cutout boundary against the real Edge_Cuts outline: segments lying on/near it
///    are pre-existing edges (no stitching -- the real board already provides a return path there);
///    every other segment is a new cut. Stitching vias are placed along new-cut segments only, at
///    sim.viaEdgeDistance() inward, spaced sim.viaSpacing() apart, connecting through whichever
///    layers the (cutout-clipped) ground composite covers at that position.
///
/// Exits the process on any unresolvable reference (mirrors resolveSimulationPorts()).
SlicedBoard sliceBoardForSimulation(const SimulationConfig& sim);

} // namespace gerber2ems
