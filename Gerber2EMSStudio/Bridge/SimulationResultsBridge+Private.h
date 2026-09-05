// Internal accessor shared only between this bridge's own .mm and EMSSimulationPipelineBridge.mm
// (which drives *when* a Postprocessor gets built, via the typed SimulationData<Stage> pipeline --
// see simulation_data.hpp -- but reuses this file's own struct-to-DTO conversion logic to render
// it). Never imported from the Swift bridging header -- like EMSConfigBridge+Private.h, this is one
// of the few places a C++ reference type crosses an Objective-C interface boundary, which Swift
// can't see at all.
#import "SimulationResultsBridge.h"

#include "gerber2ems/config.hpp"
#include "gerber2ems/postprocess.hpp"

NS_ASSUME_NONNULL_BEGIN

/// Builds a renderable EMSResultsPreview directly from an already-computed Postprocessor (see
/// Postprocessor::calculateSparams()/processData(), both expected to have already been called) and
/// the SimulationConfig it was built against -- the same conversion this file used to do
/// inline after running the whole pipeline itself; factored out so a caller that already has a
/// Postprocessor (e.g. EMSSimulationPipelineBridge, which caches one per simulation across
/// Geometry/Results tab switches) doesn't need to re-run anything just to render it.
EMSResultsPreview* buildResultsPreview(gerber2ems::Postprocessor& postprocessor,
                                        const gerber2ems::SimulationConfig& simConfig,
                                        const gerber2ems::Frequency& frequency);

NS_ASSUME_NONNULL_END
