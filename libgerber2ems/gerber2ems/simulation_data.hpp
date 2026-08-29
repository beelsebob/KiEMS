// A typed, staged pipeline for one SimulationConfig's geometry: each stage's SimulationData<Stage>
// is an immutable snapshot that only knows about the stages up to and including its own (enforced
// at compile time, not just by convention -- see SimulationData's own doc comment), built from the
// previous stage's SimulationData by a plain free function. Every stage's own payload
// (SimulationGeometry/SimulationGrid) is plain C++ value data -- a same-process caller needing the
// same geometry twice (e.g. once per excited port's own FDTD run -- see
// Simulation::adoptSlicedBoard()/adoptGridLines()) just reads it again directly, no encode/decode
// step anywhere. A genuinely cross-process caller (a `-s`-only invocation in a separate process
// from whichever `-g` produced this data, or a spawned FDTD worker) still needs *some* on-disk
// form -- saveSimulationData()/loadSimulationData() serialize/deserialize a whole
// SimulationData<Grid> (every stage up to and including it) as one JSON document, so both the
// same-process and cross-process paths end up with the exact same SimulationData<Grid> type and
// the exact same generateResults() call, rather than two different code paths.
#pragma once

#include <complex>
#include <cstdint>
#include <expected>
#include <filesystem>
#include <map>
#include <memory>
#include <optional>
#include <string>
#include <type_traits>
#include <vector>

#include <nlohmann/json.hpp>

#include "board_slicing.hpp"
#include "config.hpp"
#include "paths_config.hpp"
#include "postprocess.hpp"
#include "simulation.hpp"

namespace gerber2ems {

enum class SimulationStage { Configured, Geometry, Grid, Results, Postprocessing };

/// One simulation's sliced board (see board_slicing.hpp) -- the natural, in-memory result of the
/// comparatively expensive gerber-parsing + board-slicing polygon algorithm.
struct SimulationGeometry {
    SlicedBoard slicedBoard;
};

inline void to_json(nlohmann::json& j, const SimulationGeometry& g) { j = nlohmann::json{{"slicedBoard", g.slicedBoard}}; }

inline void from_json(const nlohmann::json& j, SimulationGeometry& g) { j.at("slicedBoard").get_to(g.slicedBoard); }

/// Adds the grid line positions GridGenerator placed along each axis (see
/// Simulation::gridLines()) -- GridGenerator itself re-parses every gerber file to place these, so
/// caching them here is what lets a second (or third, ...) Simulation skip that entirely via
/// Simulation::adoptGridLines() instead of calling Simulation::addGrid() itself.
struct SimulationGrid {
    ComputedGridLines gridLines;
};

inline void to_json(nlohmann::json& j, const SimulationGrid& g) { j = nlohmann::json{{"gridLines", g.gridLines}}; }

inline void from_json(const nlohmann::json& j, SimulationGrid& g) { j.at("gridLines").get_to(g.gridLines); }

/// One excited port's own completed FDTD run -- the (reflected, incident) uf phasors vs.
/// frequency (see Simulation::getPortParameters()), indexed [measured port][frequency], that
/// Postprocessor::calculateSparams() needs.
struct SimulationPortResults {
    std::vector<std::vector<std::complex<double>>> reflected;
    std::vector<std::vector<std::complex<double>>> incident;
    /// Raw (undecomposed) voltage/current vs. frequency for ports with absorbSignal()==false --
    /// see Simulation::PortParameters' own doc comment. Keyed by port index; only ever populated
    /// for non-absorbing ports.
    std::map<std::int32_t, std::vector<std::complex<double>>> probeVoltage;
    std::map<std::int32_t, std::vector<std::complex<double>>> probeCurrent;
};

/// Every excited port's own FDTD run, for one SimulationConfig -- keyed by excited port index.
/// Empty if the config has no port marked to excite (see generateResults()). Deliberately plural
/// ("Results", not "Result") and namespaced only under gerber2ems -- distinct from the existing
/// gerber2ems::SimulationResult (singular), which aggregates this same data, across every
/// simulation in an EMSConfig, into loadable/savable Sx<port>.csv files; this is just the raw
/// per-port phasors this SimulationConfig's own pipeline produced, still in memory.
struct SimulationResults {
    std::map<std::int32_t, SimulationPortResults> byExcitedPort;
};

/// S-parameters computed (Postprocessor::calculateSparams()) from every excited port's own FDTD
/// results -- see generatePostprocessing(). Held via shared_ptr (like GeometryResult's own
/// _simulationData -- see its own doc comment) so a SimulationData<Postprocessing> stays cheap to
/// copy despite Postprocessor itself not being copyable (it holds a `const SimulationConfig&`).
struct SimulationPostprocessing {
    std::shared_ptr<Postprocessor> postprocessor;
};

/// Immutable, progressively-richer snapshot of one SimulationConfig's pipeline state.
/// SimulationData<Configured> only carries the config itself; SimulationData<Geometry>
/// additionally carries a SimulationGeometry (built by generateGeometry()); SimulationData<Grid>
/// additionally carries a SimulationGrid (built by generateGrid()); SimulationData<Results>
/// additionally carries a SimulationResults (built by generateResults()); SimulationData
/// <Postprocessing> additionally carries a SimulationPostprocessing (built by
/// generatePostprocessing()). `geometry()`/`grid()`/`results()`/`postprocessing()` are only
/// callable once the pipeline has actually reached that stage -- attempting to call `grid()` on a
/// SimulationData<Geometry> is a compile error, not a runtime one (see their own `enable_if_t`
/// gating), so a function that only asks for `SimulationData<Geometry>` can never accidentally
/// read grid data (there is none yet) and a caller can't pass a not-yet-gridded SimulationData to
/// something that requires one.
///
/// A SimulationData is cheap to reuse: every earlier stage's data is still owned by a later one
/// (a SimulationData<Grid> still holds its own SimulationGeometry), so a single
/// SimulationData<Grid> can be handed, by const reference, to generateResults() to run every
/// excited port's FDTD pass -- each one just reads the same already-computed SlicedBoard/grid
/// lines again rather than recomputing or reloading them.
template <SimulationStage Stage>
class SimulationData {
public:
    /// The pipeline's actual starting point -- only valid for SimulationData<Configured>.
    /// `configuration` must outlive this object (and every later stage built from it).
    template <SimulationStage S = Stage, typename = std::enable_if_t<S == SimulationStage::Configured>>
    explicit SimulationData(SimulationConfig& configuration) : _configuration(configuration) {}

    /// Advances from SimulationData<Configured> to SimulationData<Geometry> -- only valid for
    /// SimulationData<Geometry>. See generateGeometry().
    template <SimulationStage S = Stage, typename = std::enable_if_t<S == SimulationStage::Geometry>>
    SimulationData(const SimulationData<SimulationStage::Configured>& previous, SimulationGeometry geometry)
        : _configuration(previous._configuration), _geometry(std::move(geometry)) {}

    /// Advances from SimulationData<Geometry> to SimulationData<Grid> -- only valid for
    /// SimulationData<Grid>. See generateGrid().
    template <SimulationStage S = Stage, typename = std::enable_if_t<S == SimulationStage::Grid>>
    SimulationData(const SimulationData<SimulationStage::Geometry>& previous, SimulationGrid grid)
        : _configuration(previous._configuration), _geometry(previous._geometry), _grid(std::move(grid)) {}

    /// Advances from SimulationData<Grid> to SimulationData<Results> -- only valid for
    /// SimulationData<Results>. See generateResults().
    template <SimulationStage S = Stage, typename = std::enable_if_t<S == SimulationStage::Results>>
    SimulationData(const SimulationData<SimulationStage::Grid>& previous, SimulationResults results)
        : _configuration(previous._configuration), _geometry(previous._geometry), _grid(previous._grid),
          _results(std::move(results)) {}

    /// Advances from SimulationData<Results> to SimulationData<Postprocessing> -- only valid for
    /// SimulationData<Postprocessing>. See generatePostprocessing().
    template <SimulationStage S = Stage, typename = std::enable_if_t<S == SimulationStage::Postprocessing>>
    SimulationData(const SimulationData<SimulationStage::Results>& previous, SimulationPostprocessing postprocessing)
        : _configuration(previous._configuration), _geometry(previous._geometry), _grid(previous._grid),
          _results(previous._results), _postprocessing(std::move(postprocessing)) {}

    SimulationConfig& configuration() const { return _configuration; }

    template <SimulationStage S = Stage, typename = std::enable_if_t<(S >= SimulationStage::Geometry)>>
    const SimulationGeometry& geometry() const {
        return *_geometry;
    }

    template <SimulationStage S = Stage, typename = std::enable_if_t<(S >= SimulationStage::Grid)>>
    const SimulationGrid& grid() const {
        return *_grid;
    }

    template <SimulationStage S = Stage, typename = std::enable_if_t<(S >= SimulationStage::Results)>>
    const SimulationResults& results() const {
        return *_results;
    }

    template <SimulationStage S = Stage, typename = std::enable_if_t<(S >= SimulationStage::Postprocessing)>>
    const SimulationPostprocessing& postprocessing() const {
        return *_postprocessing;
    }

private:
    template <SimulationStage>
    friend class SimulationData;

    SimulationConfig& _configuration;
    std::optional<SimulationGeometry> _geometry;
    std::optional<SimulationGrid> _grid;
    std::optional<SimulationResults> _results;
    std::optional<SimulationPostprocessing> _postprocessing;
};

/// Slices `data.configuration()`'s board (see Simulation::sliceBoard()) into a SimulationGeometry.
/// Combine with `data` via SimulationData<Geometry>'s own constructor to advance the pipeline:
/// `SimulationData<SimulationStage::Geometry>(data, *generateGeometry(data, config, paths))`.
std::expected<SimulationGeometry, std::string> generateGeometry(const SimulationData<SimulationStage::Configured>& data,
                                                                  const EMSConfig& config, const PathsConfig& paths);

/// Places grid lines (see Simulation::addGrid()/gridLines()) for `data.geometry()`'s already-sliced
/// board into a SimulationGrid. Combine with `data` via SimulationData<Grid>'s own constructor to
/// advance the pipeline: `SimulationData<SimulationStage::Grid>(data, generateGrid(data, config, options, paths))`.
SimulationGrid generateGrid(const SimulationData<SimulationStage::Geometry>& data, const EMSConfig& config,
                             const RunOptions& options, const PathsConfig& paths);

/// Runs every excited port's own FDTD pass (see FDTDPortRunner and
/// `data.configuration().ports()`'s own excite() flags) against `data.grid()`'s
/// already-sliced-and-gridded geometry, producing a SimulationResults with one entry per excited
/// port -- empty if none are marked to excite. Builds its own independent Simulation per port (see
/// Simulation::adoptSlicedBoard()/adoptGridLines()/populateGeometry()) -- the same
/// unavoidable-fresh-ContinuousStructure-per-port constraint generateGrid() itself works around
/// (see its own doc comment), since `data` itself is read again, unmodified, for each one -- with
/// no encode/decode step anywhere: every input is a plain C++ value already in memory, not a
/// serialized form of one. `portRunner`, if given, replaces the default `sim.run(excitedPortIndex)`
/// (posix_spawn'd worker) for every excited port -- see gerber2ems::FDTDPortRunner's own doc
/// comment.
std::expected<SimulationResults, std::string> generateResults(const SimulationData<SimulationStage::Grid>& data,
                                                                const EMSConfig& config, const RunOptions& options,
                                                                const PathsConfig& paths,
                                                                const std::vector<double>& frequencies,
                                                                const FDTDPortRunner& portRunner = {});

/// Computes S-parameters (Postprocessor::calculateSparams()) from every excited port's own FDTD
/// results (`data.results()`) -- a pure computation, no disk I/O of its own (see
/// Postprocessor::sparamToFile() for a caller that wants Sx<port>.csv files on disk, matching the
/// established pattern of leaving persistence an explicit, caller-driven step -- see e.g.
/// saveSimulationData() below).
SimulationPostprocessing generatePostprocessing(const SimulationData<SimulationStage::Results>& data,
                                                 const std::vector<double>& frequencies);

/// Where `simulationName`'s serialized SimulationData<Grid> is (or will be) saved -- see
/// saveSimulationData()/loadSimulationData(). Replaces the old geometry.xml path (same directory,
/// different filename/format).
std::filesystem::path simulationDataFile(const PathsConfig& paths, const std::string& simulationName);

/// Serializes `data` (every stage up to and including Grid -- see SimulationData's own doc
/// comment) to `file` as one JSON document.
std::expected<void, std::string> saveSimulationData(const SimulationData<SimulationStage::Grid>& data,
                                                      const std::filesystem::path& file);

/// Reconstructs a SimulationData<Grid> from a file saveSimulationData() previously wrote --
/// `configuration` must be the SimulationConfig this data was originally built from (or an
/// equivalent one read back from the same simulation.json); only the SlicedBoard/grid-line payload
/// is actually read from `file`. Fails if `file` doesn't exist or doesn't parse.
std::expected<SimulationData<SimulationStage::Grid>, std::string> loadSimulationData(SimulationConfig& configuration,
                                                                                       const std::filesystem::path& file);

} // namespace gerber2ems
