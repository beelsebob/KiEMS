// Dynamic simulation grid generation. Ported from kiems/grid_gen.py.
#pragma once

#include <cstdint>
#include <memory>
#include <string>
#include <unordered_map>
#include <vector>

#include <CSRectGrid.h>

#include "config.hpp"
#include "gerber_io.hpp"
#include "paths_config.hpp"
#include "polygon_geometry.hpp"

namespace kiems {

namespace grid_detail {
struct HullCutTrace {
    TraceSegment segment;
    std::string netName;
    std::string layerName;
};

struct HullCutPoint {
    Cu::Position position;
    std::string netName;
    std::string layerName;
    double inwardDirectionDegrees = 0;
    double width = 0;
};

/// Converts the authoritative post-cut copper loops into density segments without introducing the
/// artificial internal edges that would result from using the triangulated representation.
std::vector<TraceSegment> copperBoundarySegments(const std::vector<Cu::PolygonSet>& layerCopperLoops);

/// Clips mesh-density hint segments to the true 2D simulation cutout. Exposed for regression tests;
/// simulation geometry itself is still clipped separately by board_slicing.cpp.
std::vector<TraceSegment> clipTraceSegmentsToCutout(
    const std::vector<TraceSegment>& segments,
    const std::vector<std::vector<Cu::Position>>& cutoutLoops,
    double boundaryTolerance = 0.0);

/// Finds the newly-created endpoints where routed trace centrelines cross the hull. The returned
/// direction points from the boundary into the retained trace, which lets a synthetic port place
/// its whole footprint on copper rather than half in the discarded region.
std::vector<HullCutPoint> hullCutTracePoints(
    const std::vector<HullCutTrace>& traces,
    const std::vector<std::vector<Cu::Position>>& cutoutLoops,
    double boundaryTolerance = 0.0);

/// Extends both ends of an already-sorted core mesh with non-PML vacuum cells, geometrically
/// growing from the existing boundary cell to `targetCellSize`. The returned outermost cell at
/// each end is exactly the target size, ready for a uniform CPML band.
std::vector<double> growGridBoundaryCellsToSize(std::vector<double> lines, double targetCellSize,
                                                 double maximumCellRatio);

/// Removes every line outside `[contentMin, contentMax]`, anchors those two boundaries, then builds
/// fresh outward-only vacuum padding. Cell widths can only grow (up to `targetCellSize`) as they
/// move away from the content, and padding continues until both the requested minimum domain extent
/// and the coarse target size have been reached. This prevents a generic two-sided region fill from
/// shrinking cells again merely to meet an artificial margin boundary.
std::vector<double> rebuildExteriorPadding(std::vector<double> lines, double contentMin, double contentMax,
                                            double minimumDomainMin, double minimumDomainMax,
                                            double targetCellSize, double maximumCellRatio,
                                            double minimumBoundaryCellSize);

/// Appends `cellCount` uniform CPML cells at both ends, copying the now-coarse outermost core-cell
/// widths produced by growGridBoundaryCellsToSize().
std::vector<double> appendUniformPMLCells(std::vector<double> lines, std::int32_t cellCount);
}

/// Manages grid generation. All the geometric-series/region-densification machinery
/// (Region, SubRegion, GridGeneratorAxis) is an internal implementation detail of this class.
class GridGenerator {
public:
    /// `boardXMin`/`boardYMin`/`boardWidth`/`boardHeight` are the simulation's own board extent
    /// (SlicedBoard's, per board_slicing.hpp) -- not necessarily the real board's, and not
    /// necessarily starting at (0,0), since a sliced cutout is generally offset from the real
    /// board's own Edge_Cuts origin. `boardCutout` is SlicedBoard::cutoutLoops (same coordinate
    /// frame as the above. `layerCopperLoops` is SlicedBoard::layerCopperLoops: the actual copper
    /// remaining after the hull cut, and therefore the sole source for ordinary XY mesh density.
    /// `boardCutout` remains available only to clip the special differential-pair centreline pass.
    /// `config` and `layerCopperLoops` must outlive this GridGenerator (kept by reference).
    GridGenerator(const EMSConfig& config, double boardXMin, double boardYMin, double boardWidth, double boardHeight,
                  const std::vector<std::vector<Position>>& boardCutout,
                  const std::vector<Cu::PolygonSet>& layerCopperLoops);
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

    /// Generates the complete dynamic grid (X, Y and Z lines) into `grid`. Ordinary density comes
    /// exclusively from the already-sliced copper supplied to the constructor. The original board
    /// is consulted only for differential-pair net identity, and those centrelines are clipped to
    /// the cutout before their coupling gap is refined.
    CSRectGrid& generate(CSRectGrid& grid, const SimulationConfig& simConfig, const libkicad::Board& board);

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

} // namespace kiems
