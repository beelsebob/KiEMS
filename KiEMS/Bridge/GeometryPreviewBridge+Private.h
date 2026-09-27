// Internal accessor shared only between this bridge's own .mm and EMSSimulationPipelineBridge.mm
// (which drives *when* a SlicedBoard gets computed, via the typed SimulationData<Stage> pipeline --
// see simulation_data.hpp -- but reuses this file's own struct-to-DTO conversion logic, including
// its real-via/real-hole-size matching, to render it). Never imported from the Swift bridging
// header -- like EMSConfigBridge+Private.h, this is one of the few places a C++ reference type
// crosses an Objective-C interface boundary, which Swift can't see at all.
#import "GeometryPreviewBridge.h"

#include <expected>
#include <string>

#include "kiems/board_slicing.hpp"
#include "kiems/config.hpp"
#include "kiems/paths_config.hpp"
#include "kiems/simulation.hpp"

NS_ASSUME_NONNULL_BEGIN

/// Builds a renderable EMSGeometryPreview directly from an already-sliced board (see
/// SlicedBoard/Simulation::sliceBoard()) and the (scaled-to-simulation-units) config it was sliced
/// from -- the same conversion this file used to do inline after running the whole
/// geometry-building pipeline itself; factored out so a caller that already has a SlicedBoard (e.g.
/// EMSSimulationPipelineBridge, which caches one per simulation across Geometry/Results tab
/// switches) doesn't need to re-slice anything just to render it. `simConfig` must be the specific
/// simulation `sliced` was produced from (for its own resolved ports); `paths` is used for
/// best-effort real-via/layer-color lookups (see this file's own doc comments on why those degrade
/// gracefully rather than failing the whole preview). `gridLines` is null until the caller's own
/// Grid pipeline stage has run (see EMSPipelineStageGrid) -- the resulting preview's own
/// gridLinesX/Y just come back empty in that case, not an error.
EMSGeometryPreview* buildGeometryPreview(const kiems::SlicedBoard& sliced,
                                          const kiems::SimulationConfig& simConfig,
                                          const kiems::EMSConfig& scaledConfig,
                                          const kiems::PathsConfig& paths,
                                          const kiems::ComputedGridLines* gridLines);

/// Builds a renderable EMSGeometryPreview for the *whole* board -- every net's own copper, on
/// every copper layer, at its own real stackup Z -- independent of any one SimulationConfig.
/// Unlike buildGeometryPreview() above, nothing here is clipped to a simulation's own
/// involved-nets hull: it queries the board directly (libkicad::boardGeometry()/importStackup()/
/// libkicad::layerColors()/netColors()), so it needs no already-sliced input, and there is no per-simulation
/// cache to fall back on if a query fails -- a failure here is a real error, not a best-effort
/// degrade. It also exports every resolvable footprint STEP model, KiCad-expanded silkscreen, and
/// real plated through-hole/via geometry. Grid lines and ports are empty because this preview has
/// no simulation to derive them from.
std::expected<EMSGeometryPreview*, std::string> buildWholeBoardPreview(const kiems::PathsConfig& paths);

/// Cheap first paint: layer names/colors/order and board bounds only. Individual meshes are loaded
/// with buildBoardLayerPreview(), so presenting either layer browser never waits for hidden layers.
std::expected<EMSGeometryPreview*, std::string> buildBoardLayerCatalogPreview(
    const kiems::PathsConfig& paths, bool wholeBoard);

/// Tessellates one named KiCad layer. Safe to schedule serially in a visibility-priority queue.
std::expected<EMSGeometryLayer*, std::string> buildBoardLayerPreview(
    const kiems::PathsConfig& paths, const std::string& layerName);

std::expected<EMSGeometryLayer*, std::string> buildSlicedBoardLayerPreview(
    const kiems::PathsConfig& paths, const std::string& layerName,
    const kiems::SlicedBoard& sliced, double tessellationTolerance);

NS_ASSUME_NONNULL_END
