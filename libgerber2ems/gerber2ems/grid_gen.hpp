// Dynamic simulation grid generation. Ported from gerber2ems/grid_gen.py.
#pragma once

#include <filesystem>
#include <memory>
#include <string>
#include <unordered_map>
#include <vector>

#include <CSXCAD/CSRectGrid.h>

#include "config.hpp"
#include "gerber_io.hpp"

namespace gerber2ems {

/// Manages grid generation. All the geometric-series/region-densification machinery
/// (Region, SubRegion, GridGeneratorAxis) is an internal implementation detail of this class.
class GridGenerator {
public:
    /// `boardXMin`/`boardYMin`/`boardWidth`/`boardHeight` are the simulation's own board extent
    /// (SlicedBoard's, per board_slicing.hpp) -- not necessarily the real board's, and not
    /// necessarily starting at (0,0), since a sliced cutout is generally offset from the real
    /// board's own Edge_Cuts origin. `config` must outlive this GridGenerator (kept by reference).
    GridGenerator(const EMSConfig& config, double boardXMin, double boardYMin, double boardWidth, double boardHeight);
    ~GridGenerator();

    /// Extra pads to consider during grid generation (e.g. synthetic port apertures).
    std::vector<Pad>& addPads();
    /// Extra apertures (referenced by the above pads) to consider during grid generation.
    std::unordered_map<std::string, Aperture>& addApertures();

    double xmin() const;
    double ymin() const;

    /// Generates the complete dynamic grid (X, Y and Z lines) into `grid`, densifying around
    /// `simConfig`'s resolved involved nets (see SimulationConfig::resolvedNets(), populated by
    /// port_resolution.cpp).
    CSRectGrid& generate(CSRectGrid& grid, const SimulationConfig& simConfig, const std::filesystem::path& fabDir);

    /// The core mesh's own extent along each axis -- everywhere *inside* the PML band generate()
    /// appends beyond it (see GridGeneratorAxis::pmlInnerMin()/pmlInnerMax()'s own doc comment, in
    /// grid_gen.cpp). Meaningful only after generate() has run; purely diagnostic (GeometryView's
    /// "Show Grid" overlay uses these to color PML-band lines differently) -- nothing in the FDTD
    /// pipeline itself reads these.
    double pmlInnerXMin() const;
    double pmlInnerXMax() const;
    double pmlInnerYMin() const;
    double pmlInnerYMax() const;
    /// Same idea as pmlInnerXMin/Max, for Z -- the substrate stack's own top/bottom extent (board
    /// top is always 0), everywhere *inside* the graded PML/margin cells _generateZ() appends
    /// beyond it at both ends. Unlike X/Y (a GridGeneratorAxis per axis), Z has no separate origin
    /// offset to re-add -- see _generateZ()'s own doc comment in grid_gen.cpp.
    double pmlInnerZMin() const;
    double pmlInnerZMax() const;

private:
    struct Impl;
    std::unique_ptr<Impl> _impl;
};

} // namespace gerber2ems
