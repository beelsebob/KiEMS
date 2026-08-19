// Internal accessor shared only between this bridge's own .mm and EMSSimulationPipelineBridge.mm
// (which drives *when* a SlicedBoard gets computed, via the typed SimulationData<Stage> pipeline --
// see simulation_data.hpp -- but reuses this file's own struct-to-DTO conversion logic, including
// its real-via/real-hole-size matching, to render it). Never imported from the Swift bridging
// header -- like EMSConfigBridge+Private.h, this is one of the few places a C++ reference type
// crosses an Objective-C interface boundary, which Swift can't see at all.
#import "GeometryPreviewBridge.h"

#include "gerber2ems/board_slicing.hpp"
#include "gerber2ems/config.hpp"
#include "gerber2ems/paths_config.hpp"
#include "gerber2ems/simulation.hpp"

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
EMSGeometryPreview* buildGeometryPreview(const gerber2ems::SlicedBoard& sliced,
                                          const gerber2ems::SimulationConfig& simConfig,
                                          const gerber2ems::EMSConfig& scaledConfig,
                                          const gerber2ems::PathsConfig& paths,
                                          const gerber2ems::ComputedGridLines* gridLines);

NS_ASSUME_NONNULL_END
