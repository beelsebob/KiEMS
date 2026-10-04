// Command-line argument state for the kiems executable.
#pragma once

#include <cstdint>
#include <filesystem>
#include <optional>
#include <string>
#include <utility>
#include <vector>

#include "kiems/config.hpp"

namespace kiems {

/// Values populated by the kiems command-line parser.
class Arguments {
public:
    const std::optional<std::string>& configPath() const { return _configPath; }
    void setConfigPath(std::optional<std::string> value) { _configPath = std::move(value); }

    bool updateConfig() const { return _updateConfig; }
    void setUpdateConfig(bool value) { _updateConfig = value; }

    bool geometry() const { return _geometry; }
    void setGeometry(bool value) { _geometry = value; }

    bool simulate() const { return _simulate; }
    void setSimulate(bool value) { _simulate = value; }

    bool postprocess() const { return _postprocess; }
    void setPostprocess(bool value) { _postprocess = value; }

    bool all() const { return _all; }
    void setAll(bool value) { _all = value; }

    const std::optional<std::vector<std::string>>& exportField() const { return _exportField; }
    void setExportField(std::optional<std::vector<std::string>> value) { _exportField = std::move(value); }

    std::int32_t oversampling() const { return _oversampling; }
    void setOversampling(std::int32_t value) { _oversampling = value; }

    /// --absorbing-boundary-cells N: overrides the config's grid.absorbing_boundary_cells (absorbing cells on every face).
    const std::optional<std::int32_t>& absorbingBoundaryCells() const { return _absorbingBoundaryCells; }
    void setAbsorbingBoundaryCells(std::optional<std::int32_t> value) { _absorbingBoundaryCells = value; }

    bool transparent() const { return _transparent; }
    void setTransparent(bool value) { _transparent = value; }

    bool plotPhase() const { return _plotPhase; }
    void setPlotPhase(bool value) { _plotPhase = value; }

    const std::filesystem::path& input() const { return _input; }
    void setInput(std::filesystem::path value) { _input = std::move(value); }

    const std::filesystem::path& output() const { return _output; }
    void setOutput(std::filesystem::path value) { _output = std::move(value); }

    bool debug() const { return _debug; }
    void setDebug(bool value) { _debug = value; }

    const std::optional<std::string>& logLevel() const { return _logLevel; }
    void setLogLevel(std::optional<std::string> value) { _logLevel = std::move(value); }

    FDTDBackend backend() const { return _backend; }
    void setBackend(FDTDBackend value) { _backend = value; }

private:
    std::optional<std::string> _configPath;
    bool _updateConfig = false;
    bool _geometry = false;
    bool _simulate = false;
    bool _postprocess = false;
    bool _all = false;
    std::optional<std::vector<std::string>> _exportField;
    std::int32_t _oversampling = 4;
    std::optional<std::int32_t> _absorbingBoundaryCells;
    bool _transparent = false;
    bool _plotPhase = false;
    std::filesystem::path _input;
    std::filesystem::path _output;
    bool _debug = false;
    std::optional<std::string> _logLevel;
    FDTDBackend _backend = FDTDBackend::OpenEMSCPU;
};

} // namespace kiems

