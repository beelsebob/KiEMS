// Dynamic simulation grid generation. Ported from gerber2ems/grid_gen.py.
#pragma once

#include <memory>
#include <string>
#include <unordered_map>
#include <vector>

#include <CSXCAD/CSRectGrid.h>

#include "config.hpp"
#include "gerber_io.hpp"
#include "paths_config.hpp"

namespace gerber2ems {

/// Manages grid generation. All the geometric-series/region-densification machinery
/// (Region, SubRegion, GridGeneratorAxis) is an internal implementation detail of this class.
class GridGenerator {
public:
    /// `boardXMin`/`boardYMin`/`boardWidth`/`boardHeight` are the simulation's own board extent
    /// (SlicedBoard's, per board_slicing.hpp) -- not necessarily the real board's, and not
    /// necessarily starting at (0,0), since a sliced cutout is generally offset from the real
    /// board's own Edge_Cuts origin. `boardCutout` is SlicedBoard::cutoutLoops (same coordinate
    /// frame as the above; every loop of the true, possibly disjoint/possibly holed cutout region,
    /// not just its largest loop -- see that field's own doc comment) -- used to filter which
    /// trace/pad geometry actually drives mesh DENSITY (see generate()'s own doc comment); pass an
    /// empty vector to fall back to bounding-box-only filtering (e.g. for an old cached geometry
    /// stage with no stored cutoutLoops). `config` must outlive this GridGenerator (kept by
    /// reference).
    GridGenerator(const EMSConfig& config, double boardXMin, double boardYMin, double boardWidth, double boardHeight,
                  const std::vector<std::vector<Position>>& boardCutout);
    ~GridGenerator();

    /// Extra pads to consider during grid generation (e.g. synthetic port apertures).
    std::vector<Pad>& addPads();
    /// Extra apertures (referenced by the above pads) to consider during grid generation.
    std::unordered_map<std::string, Aperture>& addApertures();
    /// Extra Z heights (simulation units) that must get a real mesh-line anchor during Z generation,
    /// graded around like any real layer boundary rather than left to fall wherever the ordinary
    /// board-to-margin densification happens to land -- e.g. a diagonal lumped component's
    /// corner-bridge, routed through open airspace some distance off the board (see
    /// Simulation::addLumpedComponentGrid()'s own doc comment).
    std::vector<double>& additionalZHeights();

    double xmin() const;
    double ymin() const;

    /// Generates the complete dynamic grid (X, Y and Z lines) into `grid`, densifying around
    /// `simConfig`'s resolved involved nets (see SimulationConfig::resolvedNets(), populated by
    /// port_resolution.cpp) plus `additionalDensityNets`.
    ///
    /// `additionalDensityNets` gets exactly the same edge-snapped/optimal-densified treatment as an
    /// involved net, without being involved itself -- the caller's own ground net and/or
    /// GeometryOnly-level involved-nets entries ("Included in Simulation", as opposed to full
    /// "Simulation Net" participation -- see NetInclusionLevel's own doc comment), neither of which
    /// feeds resolvedNets()/ports but both of which are real copper actually present in the
    /// simulated geometry. Local complexity varies enormously for this kind of net (a wide open pour
    /// in one area, dense via stitching in another), which this densification already self-modulates
    /// for: a pour with few edges produces few Region entries and stays close to the coarse `max`
    /// background density, while a stitched area's many small via/pad edges naturally drive it
    /// toward the fine `optimal` density, the same way it already does for any signal net's own
    /// geometry. Passing an empty list (the caller's own choice, e.g. if ground net resolution
    /// failed) reproduces this function's original behaviour exactly -- that copper covered only by
    /// the coarse whole-board pass, regardless of its own local complexity.
    CSRectGrid& generate(CSRectGrid& grid, const SimulationConfig& simConfig, const PathsConfig& paths,
                        const std::vector<std::string>& additionalDensityNets = {});

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
