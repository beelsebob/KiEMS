// Dynamic simulation grid generation. Ported from gerber2ems/grid_gen.py.
#pragma once

#include <memory>
#include <string>
#include <unordered_map>
#include <vector>

#include <CSXCAD/CSRectGrid.h>

#include "gerber_io.hpp"

namespace gerber2ems {

/// Manages grid generation. All the geometric-series/region-densification machinery
/// (Region, SubRegion, GridGeneratorAxis) is an internal implementation detail of this class.
class GridGenerator {
public:
    GridGenerator();
    ~GridGenerator();

    /// Extra pads to consider during grid generation (e.g. synthetic port apertures).
    std::vector<Pad>& addPads();
    /// Extra apertures (referenced by the above pads) to consider during grid generation.
    std::unordered_map<std::string, Aperture>& addApertures();

    double xmin() const;
    double ymin() const;

    /// Generates the complete dynamic grid (X, Y and Z lines) into `grid`.
    CSRectGrid& generate(CSRectGrid& grid);

private:
    struct Impl;
    std::unique_ptr<Impl> _impl;
};

} // namespace gerber2ems
