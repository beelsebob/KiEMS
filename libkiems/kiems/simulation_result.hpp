// Opaque result of the simulate pipeline stage. See postprocess_result.hpp for the stage that
// consumes this.
#pragma once

#include <complex>
#include <cstdint>
#include <expected>
#include <filesystem>
#include <functional>
#include <map>
#include <memory>
#include <optional>
#include <string>
#include <vector>

#include "geometry_result.hpp"
#include "postprocess.hpp"

namespace kiems {

class Simulation;

/// S-parameters computed from FDTD runs (one posix_spawn'd worker process per excited port -- see
/// Simulation::run()) for every simulation in the GeometryResult it was built from. Carries that
/// GeometryResult (and, through it, the EMSConfig) forward, so PostprocessResult only ever needs
/// *this*, never the original config or geometry again.
class SimulationResult {
public:
    /// See kiems::FDTDPortRunner (simulation.hpp) -- defined there, not here, so
    /// simulation_data.hpp's generateResults() can share the same type without an include cycle
    /// back through this header. Defaults to `sim.run(excitedPortNumber)` -- see run()'s own
    /// `portRunner` parameter.
    using FDTDPortRunner = kiems::FDTDPortRunner;

    /// Runs FDTD for every excited port of every simulation in `geometry`, then computes
    /// S-parameters from the resulting incident/reflected phasors. Also writes Sx<port>.csv into
    /// `geometry.paths().simulationDir` per simulation (the same files `load()` reads back), so a
    /// later `-p`-only invocation in a separate process can resume from this run's output.
    ///
    /// `portRunner`, if given, replaces the default `sim.run(excitedPortNumber)` (posix_spawn'd
    /// worker) call for every excited port -- letting a caller outside libkiems (which must
    /// never depend on Copper.framework -- see CopperFDTDRunner.h's own file comment) substitute an
    /// in-process GPU run instead, without this function needing to know Copper exists. The
    /// Simulation passed to it has already had adoptSlicedBoard()/adoptGridLines()/
    /// populateGeometry()/setupPorts() called -- see simulation_data.hpp's generateResults(), which drives
    /// this sequence now; it does NOT yet have prepareRunDirectory() applied (unlike
    /// Simulation::run()'s own spawned-worker path, whose worker process does that itself) -- an
    /// in-process portRunner must do that part itself (see kiems_fdtd_worker/main.cpp and
    /// copper_fdtd_worker/main.cpp for the exact sequence to mirror).
    ///
    /// `board` is the KiCad board `geometry.paths().kicadBoardPaths()` names.
    static std::expected<SimulationResult, std::string> run(const GeometryResult& geometry, const RunOptions& options,
                                                              const libkicad::Board& board,
                                                              const FDTDPortRunner& portRunner = {});

    /// Reconstructs a SimulationResult by reading back Sx<port>.csv files from `inputDir` (usually
    /// `geometry.paths().simulationDir`, wherever a previous `run()` wrote them -- exposed as an
    /// explicit parameter, rather than hardcoded to that path, purely so the CLI's own `-i` override
    /// keeps working) -- e.g. a `-p`-only invocation, run in a separate process from whichever `-s`
    /// produced them, rather than re-running FDTD.
    static std::expected<SimulationResult, std::string> load(const GeometryResult& geometry,
                                                               const std::filesystem::path& inputDir);

    const EMSConfig& config() const { return _geometry.config(); }
    const GeometryResult& geometry() const { return _geometry; }

    /// nullopt if `simulationName` isn't in config(), or if that port pair wasn't (successfully)
    /// simulated.
    std::optional<std::vector<std::complex<double>>> getSParam(const std::string& simulationName,
                                                                 std::int32_t outputPort, std::int32_t inputPort) const;
    /// Raw (undecomposed) voltage/current for a non-absorbing (passive-probe) port -- see
    /// PortConfig::absorbSignal()'s own doc comment. nullopt for an absorbing port (which never has
    /// this data -- use getSParam() instead) or an unsimulated pair.
    std::optional<std::vector<std::complex<double>>> getProbeVoltage(const std::string& simulationName,
                                                                       std::int32_t probe, std::int32_t excitedPort) const;
    std::optional<std::vector<std::complex<double>>> getProbeCurrent(const std::string& simulationName,
                                                                       std::int32_t probe, std::int32_t excitedPort) const;
    /// Measured characteristic impedance for a trace-impedance probe only (PortConfig::
    /// isTraceProbe()==true, a strict subset of the non-absorbing ports above) -- nullopt for any
    /// other port, or an unsimulated pair.
    std::optional<std::vector<std::complex<double>>> getProbeImpedance(const std::string& simulationName,
                                                                          std::int32_t probe,
                                                                          std::int32_t excitedPort) const;

    /// Writes `simulationName`'s Sx<port>.csv files to `outputDir`. No-op if `simulationName` isn't
    /// in config() or had no excited port.
    void sparamToFile(const std::string& simulationName, const std::filesystem::path& outputDir) const;
    /// Writes `simulationName`'s Probe<index>.csv files to `outputDir` -- the passive-probe
    /// equivalent of sparamToFile().
    void probeToFile(const std::string& simulationName, const std::filesystem::path& outputDir) const;

private:
    SimulationResult(GeometryResult geometry, std::vector<double> frequencies,
                      std::map<std::string, std::shared_ptr<Postprocessor>> postprocessors);

    const Postprocessor* _postprocessorFor(const std::string& simulationName) const;

    GeometryResult _geometry;
    std::vector<double> _frequencies;
    // shared_ptr, not unique_ptr: run() below gets these straight out of a
    // SimulationData<Postprocessing>'s own SimulationPostprocessing (simulation_data.hpp), which
    // holds a shared_ptr itself so that type can stay cheaply copyable despite Postprocessor not
    // being copyable.
    std::map<std::string, std::shared_ptr<Postprocessor>> _postprocessors;
};

} // namespace kiems
