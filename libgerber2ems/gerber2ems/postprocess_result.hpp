// Opaque result of the postprocess pipeline stage -- the last stage in the geometry -> simulate ->
// postprocess chain (see geometry_result.hpp/simulation_result.hpp).
#pragma once

#include <complex>
#include <cstdint>
#include <expected>
#include <filesystem>
#include <map>
#include <memory>
#include <optional>
#include <string>
#include <vector>

#include "postprocess.hpp"
#include "simulation_result.hpp"

namespace gerber2ems {

/// Impedance/group-delay/differential-pair data derived from a SimulationResult's S-parameters,
/// for every simulation in it. Exposes both raw numeric accessors (for a future GUI to drive a
/// live chart directly) and the explicit render-to-file/save-to-file calls the CLI uses to write
/// PNGs and CSVs -- mirroring Postprocessor's own split between plain-data accessors and
/// explicit-outputDir render methods.
class PostprocessResult {
public:
    /// Computes impedance/delay/differential data for every simulation in `simulation`. Returns
    /// std::expected for API uniformity with buildGeometry()/runSimulation() -- there's currently
    /// no failure path in the underlying computation itself, only in file I/O the individual
    /// save/render calls below do explicitly.
    static std::expected<PostprocessResult, std::string> compute(const SimulationResult& simulation);

    const EMSConfig& config() const { return _geometry.config(); }
    const GeometryResult& geometry() const { return _geometry; }

    /// nullopt if `simulationName` isn't in config(), or if that data wasn't (successfully)
    /// computed.
    std::optional<std::vector<std::complex<double>>> getImpedance(const std::string& simulationName,
                                                                    std::int32_t port) const;
    std::optional<std::vector<std::complex<double>>> getSParam(const std::string& simulationName,
                                                                 std::int32_t outputPort, std::int32_t inputPort) const;

    // Explicit save/render calls, matching Postprocessor's own signatures -- no-ops if
    // `simulationName` isn't in config().
    void saveToFile(const std::string& simulationName, const std::filesystem::path& outputDir) const;
    void renderSParams(const std::string& simulationName, bool plotPhase, bool transparent,
                        const std::filesystem::path& outputDir) const;
    void renderDiffPairSParams(const std::string& simulationName, bool transparent,
                                const std::filesystem::path& outputDir) const;
    void renderDiffImpedance(const std::string& simulationName, bool transparent,
                              const std::filesystem::path& outputDir) const;
    void renderImpedance(const std::string& simulationName, bool transparent,
                          const std::filesystem::path& outputDir) const;
    void renderSmith(const std::string& simulationName, bool transparent, const std::filesystem::path& outputDir) const;
    void renderTraceDelays(const std::string& simulationName, bool transparent,
                            const std::filesystem::path& outputDir) const;

    /// Escape hatch for callers that need the underlying Postprocessor directly -- currently just
    /// the CLI's ExcitationPostprocessor construction (see excitation_postprocess.hpp), which isn't
    /// wrapped by a pipeline-result type of its own yet. nullptr if `simulationName` isn't in
    /// config().
    const Postprocessor* postprocessorFor(const std::string& simulationName) const;

private:
    // Stores the GeometryResult (not the SimulationResult itself, which owns non-copyable
    // Postprocessor state) that `simulation` was built from -- enough to carry EMSConfig forward,
    // matching every other stage's ownership pattern, without requiring SimulationResult to be
    // copyable.
    PostprocessResult(GeometryResult geometry, std::map<std::string, std::unique_ptr<Postprocessor>> postprocessors);

    GeometryResult _geometry;
    std::map<std::string, std::unique_ptr<Postprocessor>> _postprocessors;
};

} // namespace gerber2ems
