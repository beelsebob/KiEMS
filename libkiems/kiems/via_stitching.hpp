// Ground-return stitching-via placement along a sliced board cutout's own newly-introduced
// boundary. Split out of board_slicing.cpp so this fairly self-contained arc-length-walking
// algorithm can be exercised directly against hand-built polygon geometry, with no board/net
// resolution or PathsConfig/subprocess IO needed to set it up -- see placeStitchingVias()'s own
// doc comment.
#pragma once

#include <vector>

#include "board_slicing.hpp"
#include "importer.hpp"
#include "polygon_geometry.hpp"

namespace kiems {

struct StitchingViaPlacement {
    std::vector<StitchingVia> vias;
    /// Every candidate position considered but rejected -- see SlicedBoard::failedStitchingViaAttempts'
    /// own doc comment (board_slicing.hpp) for what this is used for.
    std::vector<Position> failedAttempts;
};

/// Places stitching vias along `cutout`'s own boundary loops, wherever a segment forms a "new cut"
/// not already coincident with `boardOutline` (the real Edge.Cuts) -- see
/// sliceBoardForSimulation()'s algorithm doc comment (board_slicing.hpp), step 4, for the full
/// placement rule (arc-length spacing, edge inset, clearance/spacing rejection conditions) and the
/// electrical rationale for why an unstitched cut edge matters. A pure geometry function: no
/// PathsConfig/subprocess IO of its own, and no SimulationConfig or EMSConfig either -- just
/// `slicing` (see SlicingConfig's own doc comment, board_slicing.hpp), so a caller can't
/// accidentally reach for an unrelated field this function was never meant to see, and a test can
/// build the whole input by hand with no config-file/board-load machinery at all. Every other input
/// the real board would otherwise supply is passed in explicitly by the caller
/// (sliceBoardForSimulation(), which already has all of them on hand for its own use):
///  - `groundPerLayer`: this same cutout's own ground-net copper composite, one polygon set per
///    metal layer -- used to find where a candidate via actually reaches ground.
///  - `nonGroundCopperObstaclesPerLayer`: routed traces and footprint pads belonging to every
///    non-ground net, one polygon set per metal layer -- a candidate's annular ring must not
///    intersect either. Non-ground zones are deliberately excluded by the caller and therefore do
///    not prevent placement.
///  - `existingVias`: every real via already on the board (getVias()'s own return, re-origined the
///    same way as `cutout`/`boardOutline`) -- new vias are kept clear of these (and of each other)
///    per `slicing.viaClearance`/`slicing.viaSpacing`.
StitchingViaPlacement placeStitchingVias(const SlicingConfig& slicing, const Cu::PolygonSet& cutout,
                                          const Cu::PolygonSet& boardOutline,
                                          const std::vector<Cu::PolygonSet>& groundPerLayer,
                                          const std::vector<Cu::PolygonSet>& nonGroundCopperObstaclesPerLayer,
                                          const std::vector<ViaHole>& existingVias);

} // namespace kiems
