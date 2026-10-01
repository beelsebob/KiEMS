// Opaque result of the geometry-building pipeline stage. See simulation_result.hpp/
// postprocess_result.hpp for the stages that consume this.
#pragma once

#include <cstdint>
#include <expected>
#include <filesystem>
#include <functional>
#include <map>
#include <memory>
#include <string>

#include "board_slicing.hpp"
#include "config.hpp"
#include "paths_config.hpp"
#include "simulation_data.hpp"

namespace kiems {

/// Which stage of building one simulation's geometry a GeometryProgress report describes.
/// `SlicingBoard` is the expensive one (gerber parsing + the board-slicing polygon algorithm --
/// see board_slicing.hpp, generateGeometry()); `PlacingGrid` covers grid-line placement (also
/// gerber-parsing-heavy -- see generateGrid()). There is no third, CSXCAD-populating phase here
/// any more -- materials/gerbers/substrates/vias/ports only ever get built later, once per excited
/// port, by generateResults() (see simulation_data.hpp) -- the geometry step itself never needs a
/// full ContinuousStructure at all.
enum class GeometryPhase { SlicingBoard, PlacingGrid };

/// One progress update. `simulationIndex`/`simulationCount` place this within the overall
/// `build()` loop (a config can define more than one simulation); `currentStep`/`totalSteps`
/// follow CopperFDTDPhase::Setup's own 0/1 -> 1/1 convention (entering vs. leaving the phase), not
/// a real step count -- neither phase here has one.
struct GeometryProgress {
    std::string simulationName;
    std::size_t simulationIndex = 0;
    std::size_t simulationCount = 0;
    GeometryPhase phase = GeometryPhase::SlicingBoard;
    std::uint32_t currentStep = 0;
    std::uint32_t totalSteps = 1;
};

using GeometryProgressCallback = std::function<void(const GeometryProgress&)>;

/// Sliced/meshed geometry for every simulation in an EMSConfig. Owns the EMSConfig it was built
/// from, so once a pipeline run has started, nothing can mutate the config it's reading from
/// underneath it -- only `build()`/`load()` take a config explicitly; every later stage
/// (SimulationResult, PostprocessResult) only ever takes the previous stage's result by const&.
/// Cheap to copy: the owned EMSConfig and the per-simulation SimulationData<Grid> cache are both
/// held via shared_ptr so later stages can keep referencing the exact same objects (Postprocessor
/// keeps a `const SimulationConfig&` alive across the whole chain -- a shared_ptr's pointee never
/// moves, unlike a config copied stage-to-stage by value) without a large board's sliced-geometry
/// data getting deep-copied every time a GeometryResult itself is copied (e.g. into
/// SimulationResult's own `_geometry` member).
class GeometryResult {
public:
    /// Builds geometry for every simulation in `config` (consumed by value: this result becomes
    /// the sole owner of its own copy, so the caller's own copy -- if kept -- can't confuse a run
    /// already in progress) by running each simulation through generateGeometry()/generateGrid()
    /// (see simulation_data.hpp), caching the resulting SimulationData<Grid> in memory *and* writing
    /// it to disk (see saveSimulationData()) -- a spawned FDTD worker process (the CPU backend
    /// always, the GPU backend when not run in-process) shares no memory with this process and has
    /// no other way to receive the geometry it needs, and a standalone `-g` invocation needs the
    /// file on disk for a `-s`-only invocation to pick up later (see load() below, which reads the
    /// exact same file format back into an equally-real SimulationData<Grid> -- both code paths
    /// converge on the same type, so SimulationResult::run() never needs to know or care which one
    /// produced it). Stops at the first simulation that fails.
    ///
    /// `onProgress`, if given, is invoked entering and leaving each simulation's SlicingBoard and
    /// PlacingGrid phases (see GeometryPhase's own doc comment).
    static std::expected<GeometryResult, std::string> build(EMSConfig config, const RunOptions& options,
                                                              const PathsConfig& paths, const libkicad::Board& board,
                                                              const GeometryProgressCallback& onProgress = {});

    /// Reconstructs a GeometryResult by deserializing every simulation's SimulationData<Grid> from
    /// the files a previous `build()` wrote under `paths.geometryDir` (see loadSimulationData()) --
    /// e.g. a `-s`-only invocation, run in a separate process from whichever `-g` produced them.
    /// Fails if any simulation's geometry data file is missing or malformed. Produces a
    /// GeometryResult indistinguishable from build()'s own -- simulationData() below is never null
    /// for a simulation that exists in `config`, regardless of which of these two created it.
    static std::expected<GeometryResult, std::string> load(EMSConfig config, const PathsConfig& paths);

    const EMSConfig& config() const { return *_config; }
    const PathsConfig& paths() const { return _paths; }

    /// Where `simulationName`'s serialized SimulationData<Grid> was (or will be) saved.
    std::filesystem::path geometryFile(const std::string& simulationName) const;

    /// `simulationName`'s SimulationData<Grid> -- both build() and load() always populate this for
    /// every simulation in config(), so this is only ever null if `simulationName` doesn't exist.
    const SimulationData<SimulationStage::Grid>* simulationData(const std::string& simulationName) const;

private:
    friend class SimulationResult;

    GeometryResult(std::shared_ptr<EMSConfig> config, PathsConfig paths,
                   std::shared_ptr<std::map<std::string, SimulationData<SimulationStage::Grid>>> simulationData);

    std::shared_ptr<EMSConfig> _config;
    PathsConfig _paths;
    std::shared_ptr<std::map<std::string, SimulationData<SimulationStage::Grid>>> _simulationData;
};

} // namespace kiems
