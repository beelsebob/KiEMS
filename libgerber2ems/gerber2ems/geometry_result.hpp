// Opaque result of the geometry-building pipeline stage. See simulation_result.hpp/
// postprocess_result.hpp for the stages that consume this.
#pragma once

#include <expected>
#include <filesystem>
#include <memory>
#include <string>

#include "config.hpp"
#include "paths_config.hpp"

namespace gerber2ems {

/// Sliced/meshed geometry (saved to geometry.xml per simulation) for every simulation in an
/// EMSConfig. Owns the EMSConfig it was built from, so once a pipeline run has started, nothing
/// can mutate the config it's reading from underneath it -- only `build()`/`load()` take a config
/// explicitly; every later stage (SimulationResult, PostprocessResult) only ever takes the
/// previous stage's result by const&. Cheap to copy: the owned EMSConfig is held via shared_ptr
/// so later stages can keep referencing the exact same SimulationConfig objects (Postprocessor
/// keeps a `const SimulationConfig&` alive across the whole chain -- a shared_ptr's pointee never
/// moves, unlike a config copied stage-to-stage by value).
class GeometryResult {
public:
    /// Builds geometry for every simulation in `config` (consumed by value: this result becomes
    /// the sole owner of its own copy, so the caller's own copy -- if kept -- can't confuse a run
    /// already in progress). Stops at the first simulation that fails.
    static std::expected<GeometryResult, std::string> build(EMSConfig config, const RunOptions& options,
                                                              const PathsConfig& paths);

    /// Reconstructs a GeometryResult from geometry.xml files a previous `build()` already saved
    /// under `paths.geometryDir` -- e.g. a `-s`-only invocation, run in a separate process from
    /// whichever `-g` produced them. Fails if any simulation's geometry.xml is missing.
    static std::expected<GeometryResult, std::string> load(EMSConfig config, const PathsConfig& paths);

    const EMSConfig& config() const { return *_config; }
    const PathsConfig& paths() const { return _paths; }

    /// Where `simulationName`'s geometry.xml was (or will be) saved.
    std::filesystem::path geometryFile(const std::string& simulationName) const;

private:
    friend class SimulationResult;

    GeometryResult(std::shared_ptr<EMSConfig> config, PathsConfig paths);

    std::shared_ptr<EMSConfig> _config;
    PathsConfig _paths;
};

} // namespace gerber2ems
