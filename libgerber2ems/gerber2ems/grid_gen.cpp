#include "grid_gen.hpp"

#include <algorithm>
#include <cmath>
#include <cstdlib>
#include <filesystem>
#include <functional>
#include <limits>
#include <set>
#include <sstream>
#include <unordered_map>
#include <utility>

#include "config.hpp"
#include "constants.hpp"
#include "csx_grid_utils.hpp"
#include "gerber_composite.hpp"
#include "logging.hpp"

namespace gerber2ems {

using namespace Cu;

namespace {

// ---- scalar root finder (replaces scipy.optimize.fsolve for these single-variable equations) ----
//
// A plain secant iteration is sufficient here: both call sites solve a smooth, well-behaved
// equation for a single cell-ratio-like scalar `q`, starting from a sensible initial guess. This
// isn't expected to trace scipy's hybrd iteration path exactly, but converges to the same root for
// well-posed inputs, which is all downstream grid-line placement (subsequently truncated to
// integers) needs.
double _solveScalar(const std::function<double(double)>& f, double initialGuess) {
    double x0 = initialGuess;
    double x1 = initialGuess + (initialGuess == 0 ? 1e-6 : initialGuess * 1e-4);
    double f0 = f(x0);
    for (int iteration = 0; iteration < 200; ++iteration) {
        const double f1 = f(x1);
        if (std::abs(f1) < 1e-10) {
            return x1;
        }
        const double denom = f1 - f0;
        if (std::abs(denom) < 1e-300) {
            break;
        }
        double x2 = x1 - f1 * (x1 - x0) / denom;
        if (x2 <= 0) {
            x2 = x1 / 2; // cell ratios must stay positive
        }
        x0 = x1;
        f0 = f1;
        x1 = x2;
    }
    return x1;
}

/// Appends `pmlCells` brand-new, uniformly sized cells beyond each end of `lines` (already fully
/// generated, deduplicated, and sorted) -- rather than resizing any of the cells already there (see
/// the reverted _regradePMLBand, which tried that and made a real board's CPU/GPU PML divergence
/// worse, not better), this leaves the existing interior mesh -- including whatever margin cells the
/// general-purpose densify fill already produced -- completely untouched, and gives Set_BC_PML()'s
/// own outermost-`pmlCells`-cells classification genuinely new domain to work with instead of
/// reclassifying part of the existing margin. Each new cell matches the width of the cell immediately
/// adjacent to it (so there's no discontinuity where the new band starts) and stays that width for
/// all `pmlCells` cells -- uniform, not grown -- so the PML's own depth-dependent loss grading is the
/// only thing varying cell-to-cell, not an additional, independently-varying physical cell size
/// compounding it.
std::vector<double> _extendPMLBand(std::vector<double> lines, std::int32_t pmlCells) {
    std::sort(lines.begin(), lines.end());
    if (pmlCells < 1 || lines.size() < 2) {
        return lines;
    }
    const double loWidth = lines[1] - lines[0];
    const double hiWidth = lines[lines.size() - 1] - lines[lines.size() - 2];

    std::vector<double> loExtra;
    if (loWidth > 0) {
        double pos = lines.front();
        for (std::int32_t i = 0; i < pmlCells; ++i) {
            pos -= loWidth;
            loExtra.push_back(pos);
        }
    }
    std::vector<double> hiExtra;
    if (hiWidth > 0) {
        double pos = lines.back();
        for (std::int32_t i = 0; i < pmlCells; ++i) {
            pos += hiWidth;
            hiExtra.push_back(pos);
        }
    }

    lines.insert(lines.begin(), loExtra.rbegin(), loExtra.rend());
    lines.insert(lines.end(), hiExtra.begin(), hiExtra.end());
    return lines;
}

/// Merge grid lines that are too close to each other.
std::vector<double> _dedupGrid(std::vector<double> grid, double gridMin, const std::vector<double>& edgeGrid) {
    std::vector<std::size_t> toRemove;
    std::sort(grid.begin(), grid.end());
    for (std::size_t idx = 0; idx + 1 < grid.size(); ++idx) {
        if (grid[idx + 1] - grid[idx] < gridMin / 2) {
            grid[idx + 1] = (grid[idx + 1] + grid[idx]) / 2;
            if (std::find(edgeGrid.begin(), edgeGrid.end(), grid[idx]) == edgeGrid.end()) {
                toRemove.push_back(idx);
            } else if (std::find(edgeGrid.begin(), edgeGrid.end(), grid[idx + 1]) == edgeGrid.end()) {
                toRemove.push_back(idx + 1);
            }
        }
    }
    for (auto it = toRemove.rbegin(); it != toRemove.rend(); ++it) {
        grid.erase(grid.begin() + static_cast<std::ptrdiff_t>(*it));
    }
    return grid;
}

/// Stores a range with additional data as priority and center position. Purely internal to grid
/// generation, so (per the earlier agreed pattern for private, never-exposed state) fields stay
/// plain rather than getter/setter-encapsulated.
class Region {
public:
    Region() = default;
    Region(double regionMin, double regionMax, double regionPrio = 1, double regionCenter = 0)
        : min(regionMin), max(regionMax), prio(regionPrio), center(regionCenter) {}

    bool operator==(const Region& other) const {
        return min == other.min && max == other.max && prio == other.prio && center == other.center;
    }

    /// Distance to another region (sub-zero values indicate how much one region needs to move to
    /// eliminate overlap).
    double distance(const Region& rhs) const {
        if (min > rhs.max) {
            return min - rhs.max;
        }
        if (max < rhs.min) {
            return rhs.min - max;
        }
        return std::min(rhs.min - max, min - rhs.max);
    }

    /// Scales this region to the requested size, using `center` as the origin. Mutates in place.
    Region& resize(double size) {
        const double fac = std::abs(size / (max - min));
        min = center - fac * std::abs(center - min);
        max = center + fac * std::abs(center - max);
        return *this;
    }

    /// Checks if `grid` is dense enough within this region & follows optimal scaling; if not, adds
    /// new grid lines to fix it. See grid_gen.py's Region.densify_region_grid for the full algorithm
    /// description (geometric-series fill flanked by an evenly-spaced middle section).
    std::vector<double> densifyRegionGrid(std::vector<double> grid, double gridSize, double absMin,
                                           double cellRatio) const;

    double min = 0;
    double max = 0;
    double prio = 1;
    double center = 0;
};

/// Part of a region that consists of 4 grid lines (and 3 cells in between, with the center cell to
/// be divided to conform with grid rules). Purely internal; see Region for the encapsulation note.
/// Fields are underscore-prefixed (unlike Region's) purely to avoid shadowing same-named locals
/// used throughout this class's own methods -- the algorithm genuinely needs both a persisted
/// m_opt/n_opt/k and freely-mutated local working copies of the same quantities.
class SubRegion {
public:
    SubRegion(std::size_t startIdx, double regMin, double regMax, double gridSize, double gridSizeMin,
              double gridSizeAbsMin, double cellRatio, bool edgeL, bool edgeH, std::vector<double> lines)
        : _startIdx(startIdx),
          _regMin(regMin),
          _regMax(regMax),
          _gridSize(gridSize),
          _gridSizeMin(gridSizeMin),
          _gridSizeAbsMin(gridSizeAbsMin),
          _cellRatio(cellRatio),
          _edgeL(edgeL),
          _edgeH(edgeH),
          _lines(std::move(lines)) {}

    void addBorderLines(std::vector<double>& grid) {
        _boundedL = std::abs(_lines[1] - _lines[0]) > 1e-6 && _lines[1] - _lines[0] < _gridSize * 3;
        _boundedH = std::abs(_lines[2] - _lines[3]) > 1e-6 && _lines[3] - _lines[2] < _gridSize * 3;

        double regionEndLine = std::min(_lines[2] - _gridSize, _regMin);
        if (_edgeL && regionEndLine > _lines[1] + _gridSize) {
            _lines[0] = _lines[1];
            _lines[1] = regionEndLine;
            grid.insert(grid.begin() + static_cast<std::ptrdiff_t>(_startIdx) + 2, regionEndLine);
            _startIdx += 1;
            _edgeL = false;
        }
        regionEndLine = std::max(_lines[1] + _gridSize, _regMax);
        if (_edgeH && regionEndLine < _lines[2] - _gridSize) {
            _lines[3] = _lines[2];
            _lines[2] = regionEndLine;
            grid.insert(grid.begin() + static_cast<std::ptrdiff_t>(_startIdx) + 2, regionEndLine);
            _edgeH = false;
        }
        _boundedL = std::abs(_lines[1] - _lines[0]) > 1e-6 && _lines[1] - _lines[0] < _gridSize * 3;
        _boundedH = std::abs(_lines[2] - _lines[3]) > 1e-6 && _lines[3] - _lines[2] < _gridSize * 3;

        _prevSize = _boundedL ? std::abs(_lines[1] - _lines[0]) : _gridSize;
        _nextSize = _boundedH ? std::abs(_lines[3] - _lines[2]) : _gridSize;

        if (_boundedL && _prevSize > _gridSize + _gridSizeMin && _regMin < _lines[1] && _regMin > _lines[0]) {
            _lines[0] = std::min(_regMin, _lines[1] - _gridSize);
            grid.insert(grid.begin() + static_cast<std::ptrdiff_t>(_startIdx) + 1, _lines[0]);
            _startIdx += 1;
            _prevSize = _lines[1] - _lines[0];
        }
        if (_boundedH && _nextSize > _gridSize + _gridSizeMin && _regMax > _lines[2] && _regMax < _lines[3]) {
            _lines[3] = std::max(_regMax, _lines[2] + _gridSize);
            grid.insert(grid.begin() + static_cast<std::ptrdiff_t>(_startIdx) + 3, _lines[3]);
            _nextSize = _lines[3] - _lines[2];
        }

        _dist = std::min(_regMax, _lines[2]) - std::max(_regMin, _lines[1]);
        _mQSgn = _nextSize > _gridSize ? -1 : 1;
        _nQSgn = _prevSize > _gridSize ? -1 : 1;
    }

    bool ready() const {
        return _dist < _gridSizeAbsMin * 2 ||
               ((_dist < (_prevSize * _cellRatio * 1.1) || !_boundedL) &&
                (_dist < (_nextSize * _cellRatio * 1.1) || !_boundedH) && (_dist < _gridSizeMin * 2));
    }

    double calcLeftDist(std::int32_t mOpt, std::int32_t nOpt, double q) const {
        const double qm = std::pow(q, _mQSgn);
        const double qn = std::pow(q, _nQSgn);
        if (q == 1) {
            return _dist;
        }
        return _dist - _nextSize * qm * (1 - std::pow(qm, mOpt)) / (1 - qm) -
               _prevSize * qn * (1 - std::pow(qn, nOpt)) / (1 - qn);
    }

    bool tryGeometricFill(double cellRatioMul = 1) {
        std::int32_t mOpt =
            static_cast<std::int32_t>(std::floor(std::log(_gridSize / _nextSize) / std::log(_cellRatio) * _mQSgn));
        mOpt = _boundedH ? std::max(mOpt, std::int32_t(0)) : 0;

        std::int32_t nOpt =
            _boundedL
                ? std::max(static_cast<std::int32_t>(
                               std::floor(std::log(_gridSize / _prevSize) / std::log(_cellRatio) * _nQSgn)),
                           std::int32_t(0))
                : 0;
        bool breakCond = false;

        for (std::int32_t iter = 0; iter < nOpt + mOpt; ++iter) {
            auto calcLeftDistFn = [&](double q) { return calcLeftDist(mOpt, nOpt, q); };
            double leftDist = calcLeftDistFn(_finalCellRatio != 0 ? _finalCellRatio : _cellRatio);
            std::int32_t k = 0;
            if (leftDist >= -_gridSize) {
                k = std::max(std::int32_t(0), static_cast<std::int32_t>(std::floor(leftDist / _gridSize)));

                auto seriesSum2 = [&](double q) { return calcLeftDistFn(q) - k * _gridSize; };
                const double q1 = _solveScalar(seriesSum2, _cellRatio);
                const double q1norm = q1 > 1 ? q1 : 1 / q1;
                if (1 < q1norm && q1norm < _cellRatio * cellRatioMul) {
                    leftDist = calcLeftDistFn(q1);
                    k = std::max(
                        std::int32_t(0),
                        static_cast<std::int32_t>(std::floor(leftDist / (_prevSize * std::pow(q1, _nQSgn * nOpt)))));
                    if (k == 0) {
                        if (nOpt != 0) {
                            nOpt -= 1;
                        } else {
                            mOpt = std::max(mOpt - 1, 0);
                        }
                    }
                    breakCond = true;
                    if ((q1 > _finalCellRatio && q1norm <= _cellRatio * cellRatioMul) || _finalCellRatio == 0) {
                        _mOpt = mOpt;
                        _nOpt = nOpt;
                        _k = k;
                        _finalCellRatio = q1;
                    }
                    continue;
                }
            }
            const double sprev = _prevSize * std::pow(_cellRatio, _nQSgn * nOpt);
            const double snext = _nextSize * std::pow(_cellRatio, _mQSgn * mOpt);
            if (sprev > snext) {
                nOpt = std::max(nOpt - 1, 0);
            } else {
                mOpt = std::max(mOpt - 1, 0);
            }
        }
        return breakCond;
    }

    bool tryRegularFill() {
        const bool unbounded = !_boundedH && !_boundedL;
        const bool regGridPossible =
            ((1 / _cellRatio) <= (_prevSize / _nextSize) && (_prevSize / _nextSize) <= _cellRatio) || unbounded;
        if (!regGridPossible) {
            return false;
        }
        _mOpt = 0;
        _nOpt = 0;
        double g;
        if (_boundedH && _boundedL) {
            g = (_prevSize + _nextSize) / 2;
        } else if (!_boundedH && _boundedL) {
            g = _prevSize;
        } else if (_boundedH && !_boundedL) {
            g = _nextSize;
        } else {
            g = _gridSize;
        }
        _k = static_cast<std::int32_t>(std::floor(_dist / g));
        return true;
    }

    bool findAnyFill() {
        _k = 0;
        double q1;
        if (!_boundedL) {
            _nOpt = 0;
            _mOpt = std::max(static_cast<std::int32_t>(
                                  std::floor(std::log(1 - _dist * (1 - _cellRatio) / _nextSize) / std::log(_cellRatio))),
                              0);
            q1 = _cellRatio;
        } else if (!_boundedH) {
            _mOpt = 0;
            _nOpt = std::max(static_cast<std::int32_t>(
                                  std::floor(std::log(1 - _dist * (1 - _cellRatio) / _prevSize) / std::log(_cellRatio))),
                              0);
            q1 = _cellRatio;
        } else if (_prevSize >= _dist || _nextSize >= _dist) {
            _mOpt = 0;
            _nOpt = 0;
            _k = 0;
            return true;
        } else {
            _mOpt = 0;
            _nQSgn = _prevSize > _nextSize ? -1 : 1;
            q1 = (1 - _prevSize / _dist) / (1 - _nextSize / _dist);
            _nOpt = std::max(static_cast<std::int32_t>(std::lround(std::log(_nextSize / _prevSize) / std::log(q1))), 0);
            q1 = std::pow(q1, _nQSgn);
        }

        _finalCellRatio = _solveScalar([&](double q) { return calcLeftDist(_mOpt, _nOpt, q); }, q1);
        return true;
    }

    /// Adds lines to `grid` using the previously calculated fill parameters. Returns the new index.
    std::size_t fillLines(std::vector<double>& grid) {
        std::size_t idx = _startIdx;
        for (std::int32_t i = 0; i < _nOpt; ++i) {
            _lines[0] = _lines[1];
            _prevSize *= std::pow(_finalCellRatio, _nQSgn);
            _lines[1] += std::min(_gridSize, _prevSize);
            grid.insert(grid.begin() + static_cast<std::ptrdiff_t>(idx) + 2, _lines[1]);
            idx += 1;
        }
        for (std::int32_t i = 0; i < _mOpt; ++i) {
            _lines[3] = _lines[2];
            _nextSize *= std::pow(_finalCellRatio, _mQSgn);
            _lines[2] -= std::min(_gridSize, _nextSize);
            grid.insert(grid.begin() + static_cast<std::ptrdiff_t>(idx) + 2, _lines[2]);
        }

        const double step = _k != 0 ? (_lines[2] - _lines[1]) / _k : 0;
        for (std::int32_t i = 0; i < _k - 1; ++i) {
            _lines[1] += step;
            grid.insert(grid.begin() + static_cast<std::ptrdiff_t>(idx) + 2, _lines[1]);
            idx += 1;
        }
        return idx + static_cast<std::size_t>(_mOpt);
    }

    std::size_t _startIdx;
    double _regMin;
    double _regMax;
    double _gridSize;
    double _gridSizeMin;
    double _gridSizeAbsMin;
    double _cellRatio;
    bool _edgeL;
    bool _edgeH;
    std::vector<double> _lines;
    bool _boundedL = true;
    bool _boundedH = true;
    double _prevSize = 0;
    double _nextSize = 0;
    double _dist = 0;
    std::int32_t _mQSgn = 1;
    std::int32_t _nQSgn = 1;
    std::int32_t _mOpt = 0;
    std::int32_t _nOpt = 0;
    double _finalCellRatio = 0;
    std::int32_t _k = 0;
};

std::vector<double> Region::densifyRegionGrid(std::vector<double> grid, double gridSize, double absMin,
                                               double cellRatio) const {
    const double gridMin = gridSize / cellRatio;
    std::sort(grid.begin(), grid.end());
    grid.insert(grid.begin(), grid.front());
    grid.push_back(grid.back());

    std::ptrdiff_t idx = -1;
    bool edgeL = true;
    bool edgeH = true;
    while (true) {
        ++idx;
        if (idx >= static_cast<std::ptrdiff_t>(grid.size()) - 3) {
            break;
        }

        SubRegion subreg(static_cast<std::size_t>(idx), min, max, gridSize, gridMin, absMin, cellRatio, edgeL, edgeH,
                          std::vector<double>(grid.begin() + idx, grid.begin() + idx + 4));

        if (min >= subreg._lines[2] || max <= subreg._lines[1]) {
            continue;
        }

        subreg.addBorderLines(grid);
        edgeL = subreg._edgeL;
        edgeH = subreg._edgeH;

        if (subreg.ready()) {
            continue;
        }

        const std::vector<std::function<bool()>> fillMethods = {
            [&]() { return subreg.tryGeometricFill(); },
            [&]() { return subreg.tryGeometricFill(1.5); },
            [&]() { return subreg.tryRegularFill(); },
            [&]() { return subreg.findAnyFill(); },
        };
        for (const auto& method : fillMethods) {
            if (method()) {
                break;
            }
        }

        idx = static_cast<std::ptrdiff_t>(subreg.fillLines(grid));
    }

    return std::vector<double>(grid.begin() + 1, grid.end() - 1);
}

/// Responsible for generating grid lines in a single dimension. Purely internal; see Region for
/// the encapsulation note.
class GridGeneratorAxis {
public:
    /// `grid` must outlive this GridGeneratorAxis (kept by reference). `trustedMin`/`trustedMax` are
    /// this axis's own true sliced-board extent (SlicedBoard::xMin/yMin's own bounds, absolute frame,
    /// no grid margin) -- see addLinesFromTrace()'s own doc comment for why a segment's *region* (as
    /// opposed to its own start/stop, which inBounds() already validated in generate()) needs
    /// clamping to this.
    GridGeneratorAxis(std::string axis, Region board, const Grid& grid, double trustedMin, double trustedMax)
        : _axis(std::move(axis)), _board(board), _grid(grid), _trustedMin(trustedMin), _trustedMax(trustedMax) {}

    void addLinesFromTrace(const std::vector<TraceSegment>& segments) {
        const std::string oaxis = _axis == "y" ? "x" : "y";
        const double w3 = _grid.optimal() / 3;
        auto axisValue = [](const Position& pos, const std::string& axis) { return axis == "x" ? pos.x() : pos.y(); };

        for (const auto& seg : segments) {
            const double slenX = std::abs(seg.start().x() - seg.stop().x());
            const double slenY = std::abs(seg.start().y() - seg.stop().y());
            const double ang = std::atan2(slenY, slenX);
            const double deg5 = M_PI / 36; // angle smaller than 5 degrees

            const double p0 = axisValue(seg.start(), _axis);
            const double p1 = axisValue(seg.stop(), _axis);
            const double slenAxis = _axis == "x" ? slenX : slenY;
            const double slenOaxis = oaxis == "x" ? slenX : slenY;
            Region region(std::min(p0, p1) - seg.width() / 2, std::max(p0, p1) + seg.width() / 2, slenAxis + 1,
                           (p0 + p1) / 2);
            // generate()'s own inBounds() only validates the segment's own start/stop *centerline*
            // points -- this region additionally pads by seg.width()/2 on each side, and for a wide
            // enough feature (a large pad or a zone/plane edge represented as a wide "trace" stroke)
            // that padding alone can push region.min/max well past the true sliced board's own real
            // edge, into open vacuum, even though both original endpoints legitimately passed
            // inBounds(). Confirmed on a real board: a region reaching to x=1419534.79 while the
            // sliced board's own true xMin was 1436785 -- a ~1.7mm overshoot, exactly matching
            // width/2 for a ~3.45mm-wide feature. Clamping here (rather than not padding at all)
            // keeps the padding's own purpose -- a wide feature's mesh should still resolve its own
            // real edges -- while never letting it reach past geometry that was never validated.
            region.min = std::max(region.min, _trustedMin);
            region.max = std::min(region.max, _trustedMax);

            // Diagnostic: dump every segment (trace or pad-contour -- addLinesFromPads() feeds pad
            // contours through this same function) whose own region overlaps a hardcoded coordinate
            // watch window, so a specific dense patch found via the axis gap dump can be traced back
            // to the exact geometry (and its classification) responsible.
            constexpr double kWatchMin = 1400000.0;
            constexpr double kWatchMax = 1450000.0;
            const bool watch = _axis == "x" && region.max >= kWatchMin && region.min <= kWatchMax;
            auto logWatch = [&](const char* category) {
                if (!watch) return;
                logInfo("### Grid Generator: WATCH [" + _axis + "] " + category + " region=[" +
                         std::to_string(region.min) + "," + std::to_string(region.max) + "] from seg start=(" +
                         std::to_string(seg.start().x()) + "," + std::to_string(seg.start().y()) + ") stop=(" +
                         std::to_string(seg.stop().x()) + "," + std::to_string(seg.stop().y()) + ") width=" +
                         std::to_string(seg.width()) + " mode=" + std::to_string(static_cast<int>(seg.mode())) +
                         " normal=" + std::to_string(seg.normal()) + " ###");
            };

            if (seg.mode() != PlotMode::Linear) {
                _diagonal.push_back(region);
                logWatch("diagonal(non-linear)");
                continue;
            }

            if ((ang < deg5 && _axis == "x") || (ang > M_PI / 2 - deg5 && _axis == "y")) {
                _perpendicular.push_back(region);
                logWatch("perpendicular");
            } else if ((ang < deg5 && _axis == "y") || (ang > M_PI / 2 - deg5 && _axis == "x")) {
                _parallel.push_back(region);
                logWatch("parallel");
                if (seg.width() != 0 || seg.normal()) {
                    _edgeCells.emplace_back(region.min - 2 * w3, region.min + w3, slenOaxis + 1, region.min);
                }
                if (seg.width() != 0 || !seg.normal()) {
                    _edgeCells.emplace_back(region.max - w3, region.max + 2 * w3, slenOaxis + 1, region.max);
                }
            } else {
                _diagonal.push_back(region);
                logWatch("diagonal");
            }
        }
    }

    void addLinesFromPads(const std::vector<Pad>& pads, const std::vector<NetName>& nets,
                           const std::unordered_map<std::string, Aperture>& apertures) {
        for (const auto& pad : pads) {
            if (std::find(nets.begin(), nets.end(), pad.net()) == nets.end()) {
                continue;
            }
            const Aperture& ap = apertures.at(pad.aperture());
            std::vector<TraceSegment> cont = ap.data().contours(pad.pos(), pad.rotation(), pad.scale(), pad.mirror());
            addLinesFromTrace(cont);
        }
    }

    /// Builds a bounding region spanning BOTH legs of a differential pair -- covering each leg's own
    /// footprint plus the coupling gap between them -- and densifies that whole span to `optimal`
    /// (compileGrid()'s own `_diffPairGap` pass, right alongside `_parallel`). Without this, the gap
    /// itself is never a densify target at all: addLinesFromTrace() only resolves each trace's own
    /// edges/footprint, so the coupling gap (and the trace-to-coplanar-pour gap, if edgeCells reach
    /// it) ends up covered only by a couple of narrow edge-hugging bands plus whatever the coarse,
    /// `max`-targeted whole-board pass leaves behind -- often just 1-2 cells across a gap of a few
    /// hundred microns, despite that gap being exactly the geometry that sets this pair's own
    /// characteristic impedance.
    ///
    /// `segmentsP`/`segmentsN` needn't have matching order or even count (a routed pair's two legs
    /// can be split into a different number of segments by bends/vias) -- each P segment is matched
    /// to its nearest N segment by center-to-center distance, and a match wider than `kMaxCoupledGap`
    /// is skipped rather than densified, since that means the two legs have genuinely diverged at
    /// that point (or one leg's segment list ran out) and there's no real coupling gap left to
    /// resolve there. Unlike addLinesFromTrace(), this never classifies by angle -- the coupling gap
    /// needs `optimal` density regardless of which way the pair happens to be routed locally.
    void addLinesFromDifferentialPair(const std::vector<TraceSegment>& segmentsP,
                                       const std::vector<TraceSegment>& segmentsN) {
        auto axisValue = [](const Position& pos, const std::string& axis) { return axis == "x" ? pos.x() : pos.y(); };
        auto segmentCenter = [](const TraceSegment& seg) {
            return Position((seg.start().x() + seg.stop().x()) / 2, (seg.start().y() + seg.stop().y()) / 2);
        };
        auto centerDistance = [](const Position& a, const Position& b) { return std::hypot(a.x() - b.x(), a.y() - b.y()); };

        constexpr double kMaxCoupledGap = 5000; // 5mm (constants::baseUnit-scaled microns) -- generous
                                                 // for any realistic differential-pair spacing.
        for (const auto& segP : segmentsP) {
            const Position centerP = segmentCenter(segP);
            const TraceSegment* nearest = nullptr;
            double nearestDistance = std::numeric_limits<double>::max();
            for (const auto& segN : segmentsN) {
                const double d = centerDistance(centerP, segmentCenter(segN));
                if (d < nearestDistance) {
                    nearestDistance = d;
                    nearest = &segN;
                }
            }
            if (nearest == nullptr || nearestDistance > kMaxCoupledGap) {
                continue;
            }

            const double p0 = axisValue(segP.start(), _axis);
            const double p1 = axisValue(segP.stop(), _axis);
            const double n0 = axisValue(nearest->start(), _axis);
            const double n1 = axisValue(nearest->stop(), _axis);
            const double halfWidth = std::max(segP.width(), nearest->width()) / 2;
            const double lo = std::min({p0, p1, n0, n1}) - halfWidth;
            const double hi = std::max({p0, p1, n0, n1}) + halfWidth;
            if (hi <= lo) {
                continue;
            }
            _diffPairGap.emplace_back(lo, hi, 1, (lo + hi) / 2);
        }
    }

    /// Shrinks/merges conflicting edge regions (following the rule of thirds as closely as possible).
    // See _mergeRegions()'s own doc comment for why `deleted[j]` (O(1)) replaces what used to be a
    // std::find over a growing toDelete list (O(n), inside an already-O(n^2) loop) here too -- the
    // identical shape, and the identical profiled cost, on _edgeCells instead of _parallel/etc.
    void resolveEdgeRegions() {
        const double gridSize = _grid.optimal();
        const double gridMin = gridSize / 1.8;
        std::sort(_edgeCells.begin(), _edgeCells.end(),
                  [](const Region& a, const Region& b) { return a.prio > b.prio; }); // high to low
        std::vector<bool> deleted(_edgeCells.size(), false);
        for (std::size_t i = 0; i < _edgeCells.size(); ++i) {
            Region reg = _edgeCells[i];
            for (std::size_t j = 0; j < i; ++j) {
                if (deleted[j]) {
                    continue;
                }
                Region reg2 = _edgeCells[j];
                double dist = reg.distance(reg2);
                if (dist > gridMin) {
                    continue;
                }
                const double size0 = reg.max - reg.min;
                const double size1 = reg2.max - reg2.min;
                const double shrinkPotential = size0 + size1 - 2 * gridMin;
                if (dist + shrinkPotential > gridMin) {
                    reg = Region(reg).resize(gridMin);
                    reg2 = Region(reg2).resize(gridMin);
                    dist = reg.distance(reg2);
                    if (dist > gridMin) {
                        continue;
                    }
                }

                const Region newReg((reg.min * reg.prio + reg2.min * reg2.prio) / (reg.prio + reg2.prio),
                                     (reg.max * reg.prio + reg2.max * reg2.prio) / (reg.prio + reg2.prio),
                                     reg.prio + reg2.prio,
                                     (reg.center * reg.prio + reg2.center * reg2.prio) / (reg.prio + reg2.prio));
                deleted[j] = true;
                reg = newReg;
                _edgeCells[i] = newReg;
                _edgeCells[j] = newReg;
            }
        }

        for (std::size_t idx = _edgeCells.size(); idx-- > 0;) {
            if (deleted[idx]) {
                _edgeCells.erase(_edgeCells.begin() + static_cast<std::ptrdiff_t>(idx));
            }
        }

        // list(set(...)): dedup by exact value equality (order need not be preserved).
        std::vector<Region> unique;
        for (const auto& reg : _edgeCells) {
            if (std::find(unique.begin(), unique.end(), reg) == unique.end()) {
                unique.push_back(reg);
            }
        }
        _edgeCells = std::move(unique);
    }

    CSRectGrid& compileGrid(CSRectGrid& csgrid, double offset) {
        clearGridLines(csgrid, _axis);
        const double gridSize = _grid.optimal();
        const double cellRatio = _grid.cellRatio().xy();
        const double gridMin = gridSize / cellRatio;
        const double gridDiag = _grid.diagonal();
        const double gridPerp = _grid.perpendicular();

        resolveEdgeRegions();
        std::vector<double> grid;
        // The mesh's own core extent is simply the real sliced board's own extent (+ margin,
        // already baked into `_board` by the constructor) -- not reconstructed from trace/pad/
        // region classification. An earlier version of this reconstructed it from wherever
        // involved-net copper happened to land (`Grid::margin().fromTrace()`, since removed): a
        // real board's own gerbers showed that heuristic can undershoot the true board size
        // arbitrarily, even with every relevant net (including ground) correctly included, because
        // it only sees per-segment local extents, not "this net's copper happens to reach every
        // corner of the board." A too-small core extent isn't just an inefficiency -- it leaves
        // GridGenerator's own PML band (appended just beyond it) wrapping around real, still-
        // simulated copper instead of strictly outside it, a severe, fast-onset FDTD divergence.
        _board.min += offset;
        _board.max += offset;

        for (const auto& reg : _edgeCells) {
            grid.push_back(reg.min);
            grid.push_back(reg.max);
        }

        const std::vector<double> edgeGrid = grid;
        grid.push_back(_board.min);
        grid.push_back(_board.max);

        _mergeRegions(_parallel, gridSize);
        _mergeRegions(_perpendicular, gridPerp);
        _mergeRegions(_diagonal, gridDiag);
        _mergeRegions(_diffPairGap, gridSize);

        double realGeometryMin = std::numeric_limits<double>::infinity();
        double realGeometryMax = -std::numeric_limits<double>::infinity();
        {
            // Diagnostic: the true reach of every density-contributing region on this axis, by
            // category, vs _board's own [min,max] floor -- lets us tell whether fine spacing far
            // from any visible copper is coming from a real (if distant-in-the-other-axis) region,
            // or from something reaching further than the actual accepted geometry warrants.
            auto extent = [](const std::vector<Region>& regs) -> std::pair<double, double> {
                double lo = std::numeric_limits<double>::infinity();
                double hi = -std::numeric_limits<double>::infinity();
                for (const auto& r : regs) {
                    lo = std::min(lo, r.min);
                    hi = std::max(hi, r.max);
                }
                return {lo, hi};
            };
            auto fmt = [](std::pair<double, double> e) {
                return std::isfinite(e.first) ? "[" + std::to_string(e.first) + "," + std::to_string(e.second) + "]"
                                               : std::string("[empty]");
            };
            for (const std::vector<Region>* regs :
                 {&_parallel, &_perpendicular, &_diagonal, &_diffPairGap, &_edgeCells}) {
                const auto e = extent(*regs);
                realGeometryMin = std::min(realGeometryMin, e.first);
                realGeometryMax = std::max(realGeometryMax, e.second);
            }
            logInfo("### Grid Generator: " + _axis + " axis region reach: board=[" + std::to_string(_board.min) +
                     "," + std::to_string(_board.max) + "], parallel(n=" + std::to_string(_parallel.size()) +
                     ")=" + fmt(extent(_parallel)) + ", perpendicular(n=" + std::to_string(_perpendicular.size()) +
                     ")=" + fmt(extent(_perpendicular)) + ", diagonal(n=" + std::to_string(_diagonal.size()) +
                     ")=" + fmt(extent(_diagonal)) + ", diffPairGap(n=" + std::to_string(_diffPairGap.size()) +
                     ")=" + fmt(extent(_diffPairGap)) + ", edgeCells(n=" + std::to_string(_edgeCells.size()) +
                     ")=" + fmt(extent(_edgeCells)) + " ###");
        }

        for (const auto& reg : _parallel) {
            grid = reg.densifyRegionGrid(grid, gridSize, gridMin, cellRatio);
        }
        grid = _dedupGrid(grid, gridMin, edgeGrid);

        // Differential-pair coupling-gap regions -- densified at the same `optimal` target as
        // _parallel (the trace bodies themselves), right alongside them and before the coarser
        // _diagonal/_perpendicular/whole-board passes below, so nothing coarser gets a chance to
        // plant a line inside the gap first (see addLinesFromDifferentialPair()'s own doc comment).
        for (const auto& reg : _diffPairGap) {
            grid = reg.densifyRegionGrid(grid, gridSize, gridMin, cellRatio);
        }
        grid = _dedupGrid(grid, gridMin, edgeGrid);

        for (const auto& reg : _diagonal) {
            grid = reg.densifyRegionGrid(grid, gridDiag, gridMin, cellRatio);
        }
        grid = _dedupGrid(grid, gridMin, edgeGrid);

        for (const auto& reg : _perpendicular) {
            grid = reg.densifyRegionGrid(grid, gridPerp, gridMin, cellRatio);
        }
        grid = _dedupGrid(grid, gridMin, edgeGrid);

        grid = _board.densifyRegionGrid(grid, _grid.max(), gridMin, cellRatio);
        grid = _dedupGrid(grid, gridMin, edgeGrid);
        // Nothing above clips a region's own density-placed lines to `_board`'s own span --
        // addLinesFromTrace()'s per-segment Region spans that segment's own local extent, and while
        // generate()'s own inBounds() filter now requires *both* trace-segment endpoints to pass
        // (see its own call site's doc comment for why the old either-endpoint version let a single
        // long segment place density arbitrarily far into open vacuum), a *pad* only ever tests one
        // point to begin with, and a still-accepted segment's own edge-cell buffer band (addLinesFrom
        // Trace()'s `w3` expansion) can reach a little past that segment's own true endpoint.
        // Removing anything outside [_board.min, _board.max] here, once, after every density source
        // has already contributed, is the one place that actually guarantees the mesh never extends
        // past the real simulated board regardless of which net/mechanism introduced a stray line.
        grid.erase(std::remove_if(grid.begin(), grid.end(),
                                   [this](double line) { return line < _board.min || line > _board.max; }),
                   grid.end());
        // _dedupGrid() sorts internally, so grid is already sorted here -- front()/back() are the
        // core mesh's own extent, before _extendPMLBand() appends the PML band beyond it. Captured
        // in the same coordinate space compileGrid()'s own returned lines end up in (see
        // pmlInnerMin()/pmlInnerMax()'s own doc comment).
        if (!grid.empty()) {
            _pmlInnerMin = static_cast<double>(static_cast<std::int32_t>(grid.front() - offset));
            _pmlInnerMax = static_cast<double>(static_cast<std::int32_t>(grid.back() - offset));
        }
        logInfo("### Grid Generator: " + _axis + " axis core mesh extent = [" + std::to_string(_pmlInnerMin) +
                 ", " + std::to_string(_pmlInnerMax) + "] ###");
        grid = _extendPMLBand(std::move(grid), constants::pmlDepthCells);

        // `grid` is in the same absolute, Edge_Cuts-bounding-box-relative frame as every geometry
        // primitive this Simulation adds (addSubstrates()/addGerbers()/addMslPort()/addVias() all
        // place things directly from _slicedBoard.xMin/yMin, never offset) -- the real CSRectGrid
        // added here must stay in that same absolute frame too, or every single primitive ends up
        // with zero overlap against the mesh (confirmed: openEMS reported every primitive in the
        // whole simulation, including Substrate boxes spanning the entire domain, as "unused", and
        // the excited port never registered, so energy stayed at exactly 0 all run). Only
        // _pmlInnerMin/_pmlInnerMax (a few lines up) are meant to stay local/offset-subtracted --
        // those exist purely for the geometry preview's own diagnostic overlay, which re-adds this
        // same offset itself (see GeometryPreviewBridge.mm).
        std::vector<double> intLines;
        intLines.reserve(grid.size());
        for (const double line : grid) {
            intLines.push_back(static_cast<double>(static_cast<std::int32_t>(line)));
        }
        {
            // Diagnostic: intLines is sorted (grid was sorted going into _extendPMLBand(), which only
            // prepends/appends further-out values) -- dump the low and high ends verbatim so a dense
            // patch sitting in the middle of otherwise-coarse vacuum can be pinpointed by coordinate.
            std::vector<double> sorted = intLines;
            std::sort(sorted.begin(), sorted.end());
            auto dump = [](const std::vector<double>& v, std::size_t from, std::size_t to) {
                std::string s;
                for (std::size_t i = from; i < to && i < v.size(); ++i) {
                    if (!s.empty()) s += ", ";
                    s += std::to_string(v[i]);
                }
                return s;
            };
            const std::size_t n = sorted.size();
            logInfo("### Grid Generator: " + _axis + " axis " + std::to_string(n) + " line(s) total, first 50 = [" +
                     dump(sorted, 0, 50) + "], last 50 = [" +
                     dump(sorted, n > 50 ? n - 50 : 0, n) + "] ###");

            // Full raw gap dump -- no pre-filtering, no assumption about where a real bug can or
            // can't be (the previous version of this diagnostic wrongly assumed anything between
            // realGeometryMin/Max was automatically legitimate, missing a genuine local vacuum gap
            // *inside* that overall envelope, between two separate clusters of real copper, where the
            // same bug could just as easily hide). One gap per line line: index, coordinate, gap to
            // next line -- scan this directly for any place spacing tightens without a nearby real
            // feature to justify it.
            std::string gaps;
            for (std::size_t i = 0; i + 1 < n; ++i) {
                if (!gaps.empty()) gaps += ", ";
                gaps += std::to_string(static_cast<std::int64_t>(sorted[i + 1] - sorted[i]));
            }
            logInfo("### Grid Generator: " + _axis + " axis gaps (n=" + std::to_string(n > 0 ? n - 1 : 0) +
                     ", coordinate " + std::to_string(!sorted.empty() ? sorted.front() : 0) + " to " +
                     std::to_string(!sorted.empty() ? sorted.back() : 0) + "): [" + gaps + "] ###");
        }

        addGridLines(csgrid, _axis, intLines);
        return csgrid;
    }

private:
    /// Merges overlapping regions in `regList` in place.
    // Profiled on a real (large, post-ground/geometry-only-net-inclusion) board: 93% of this whole
    // function's own time, and 99%+ of GridGenerator::generate() overall, was spent in the
    // std::find(toDelete.begin(), toDelete.end(), j) call below -- a linear scan of an
    // already-deleted-index list, itself growing up to O(n), executed inside a loop that's already
    // O(n^2) -- i.e. this function was O(n^3) in the worst case. `deleted[j]` (a std::vector<bool>,
    // one entry per original regList index, O(1) to check) replaces that scan; the erase loop below
    // walks indices in the same descending order toDelete used to be sorted into (largest first, so
    // erasing at one index never invalidates an index still to be checked), just without needing an
    // explicit std::vector<std::size_t> + sort step to get there.
    void _mergeRegions(std::vector<Region>& regList, double gridSize) {
        std::vector<bool> deleted(regList.size(), false);
        for (std::size_t i = 0; i < regList.size(); ++i) {
            Region reg = regList[i];
            for (std::size_t j = 0; j < i; ++j) {
                if (deleted[j]) {
                    continue;
                }
                Region reg2 = regList[j];
                if (reg.distance(reg2) < gridSize) {
                    const double nmin = std::min(reg.min, reg2.min);
                    const double nmax = std::max(reg.max, reg2.max);
                    const Region newReg(nmin, nmax, reg.prio + reg2.prio, (nmin + nmax) / 2);
                    deleted[j] = true;
                    reg = newReg;
                    regList[i] = newReg;
                    regList[j] = newReg;
                }
            }
        }
        for (std::size_t idx = regList.size(); idx-- > 0;) {
            if (deleted[idx]) {
                regList.erase(regList.begin() + static_cast<std::ptrdiff_t>(idx));
            }
        }
    }

    std::string _axis;
    Region _board;
    std::vector<Region> _edgeCells;
    std::vector<Region> _parallel;
    std::vector<Region> _diagonal;
    std::vector<Region> _perpendicular;
    std::vector<Region> _diffPairGap;
    const Grid& _grid;
    double _trustedMin = 0;
    double _trustedMax = 0;

public:
    /// The core mesh's own extent along this axis -- i.e. everywhere *inside* the PML band
    /// _extendPMLBand() appends in compileGrid(), in the same coordinate space compileGrid()'s own
    /// returned grid lines are in (post `-offset`, pre-cast rounding). Meaningful only after
    /// compileGrid() has actually run; 0 before that. Exists purely for diagnostic display (see
    /// GeometryView's "Show Grid" overlay, which colors PML-band lines differently) -- nothing in
    /// the FDTD pipeline itself reads these.
    double pmlInnerMin() const { return _pmlInnerMin; }
    double pmlInnerMax() const { return _pmlInnerMax; }

private:
    double _pmlInnerMin = 0;
    double _pmlInnerMax = 0;
};

/// Shortest distance from `p` to the segment a-b. Used below to give the strict point-in-polygon
/// test the same "close enough to legitimately matter" tolerance the old bounding-box-only filter
/// always had (see inBounds()'s own comment), rather than a hard cutoff exactly at the cutout's own
/// boundary.
double pointSegmentDistance(const Position& p, const Position& a, const Position& b) {
    const double abx = b.x() - a.x();
    const double aby = b.y() - a.y();
    const double apx = p.x() - a.x();
    const double apy = p.y() - a.y();
    const double lengthSq = abx * abx + aby * aby;
    const double t = std::clamp(lengthSq > 0 ? (apx * abx + apy * aby) / lengthSq : 0.0, 0.0, 1.0);
    const double dx = p.x() - (a.x() + t * abx);
    const double dy = p.y() - (a.y() + t * aby);
    return std::sqrt(dx * dx + dy * dy);
}

/// Standard even-odd ray-casting point-in-polygon test, summed (XORed) across every loop of a
/// possibly multi-loop, possibly-holed shape (each closed loop's last point need not repeat its
/// first). This is the standard technique for testing membership against an already-resolved
/// Clipper2Lib polygon set: a hole loop's opposite winding doesn't need to be identified explicitly
/// -- ray-casting parity naturally flips back to "outside" once a ray has crossed into and back out
/// of a hole, and a genuinely separate, disjoint outer loop just contributes its own independent
/// crossings the same way. Deliberately not Clipper2Lib::PointInPolygon -- this file otherwise
/// re-parses gerbers and does its own geometry entirely independently of board_slicing.cpp's own
/// Clipper2Lib-based machinery (fixed-point coordinates, boolean-operation support neither needed
/// here), so a plain membership test on the same double-precision Position data everything else in
/// this file already uses avoids pulling in a new dependency/coordinate-space conversion for it.
bool pointInPolygonSet(const Position& p, const std::vector<std::vector<Position>>& loops) {
    bool inside = false;
    for (const std::vector<Position>& loop : loops) {
        const std::size_t n = loop.size();
        for (std::size_t i = 0, j = n - 1; i < n; j = i++) {
            const double xi = loop[i].x();
            const double yi = loop[i].y();
            const double xj = loop[j].x();
            const double yj = loop[j].y();
            if (((yi > p.y()) != (yj > p.y())) && (p.x() < (xj - xi) * (p.y() - yi) / (yj - yi) + xi)) {
                inside = !inside;
            }
        }
    }
    return inside;
}

/// Signed shoelace area, summed across every loop -- an outer loop and a hole loop wound oppositely
/// (standard Clipper2Lib convention) contribute with opposite sign, so this returns the polygon
/// set's own true net area regardless of how many outer/hole loops it has. Diagnostic use only (see
/// generate()'s own logging) -- comparing this against the loops' combined bounding-box area is a
/// quick way to tell whether a "cutout" shape is genuinely a narrow/sparse ribbon (area << bbox
/// area, expected for a padded trace route) or has ballooned to fill most of its own bounding box.
double polygonSetArea(const std::vector<std::vector<Position>>& loops) {
    double area = 0;
    for (const std::vector<Position>& loop : loops) {
        const std::size_t n = loop.size();
        for (std::size_t i = 0, j = n - 1; i < n; j = i++) {
            area += loop[j].x() * loop[i].y() - loop[i].x() * loop[j].y();
        }
    }
    return std::abs(area) / 2.0;
}

/// True if `p` is inside the polygon set `loops` (see pointInPolygonSet()), or within `tolerance`
/// of any loop's boundary. Empty `loops` (no stored cutout -- an old cached geometry stage from
/// before SlicedBoard::cutoutLoops was threaded into GridGenerator) always returns true, i.e. no
/// polygon filtering at all.
bool inPolygonSetWithTolerance(const Position& p, const std::vector<std::vector<Position>>& loops,
                                double tolerance) {
    if (loops.empty()) {
        return true;
    }
    if (pointInPolygonSet(p, loops)) {
        return true;
    }
    double minDist = std::numeric_limits<double>::infinity();
    for (const std::vector<Position>& loop : loops) {
        const std::size_t n = loop.size();
        for (std::size_t i = 0, j = n - 1; i < n; j = i++) {
            minDist = std::min(minDist, pointSegmentDistance(p, loop[j], loop[i]));
            if (minDist <= tolerance) {
                return true;
            }
        }
    }
    return minDist <= tolerance;
}

} // namespace

struct GridGenerator::Impl {
    Impl(const EMSConfig& config, double boardXMin, double boardYMin, double boardWidth, double boardHeight,
         const std::vector<std::vector<Position>>& boardCutout)
        : x("x", Region(-config.grid().margin().xy(), boardWidth + config.grid().margin().xy()), config.grid(),
             boardXMin, boardXMin + boardWidth),
          y("y", Region(-config.grid().margin().xy(), boardHeight + config.grid().margin().xy()), config.grid(),
             boardYMin, boardYMin + boardHeight),
          xmin(boardXMin),
          xmax(boardXMin + boardWidth),
          ymin(boardYMin),
          ymax(boardYMin + boardHeight),
          _boardCutout(boardCutout),
          _config(config) {}

    std::vector<std::int32_t> _generateZ() {
        logInfo("### Grid Generator: generate Z axis ###");
        const Grid& gridCfg = _config.grid();
        const double cellRatio = gridCfg.cellRatio().z();
        const double gridMin = gridCfg.optimal() / cellRatio;
        const double gridMax = gridCfg.max();
        const double margin = gridCfg.margin().z();
        std::int32_t zCount = gridCfg.interLayers();
        if (zCount % 2 == 1) { // Always have a z-line at the dumpbox
            zCount += 1;
        }

        std::vector<double> zLines = {0};
        double offset = 0;
        double firstLayerCellWidth = 0;
        double lastLayerCellWidth = 0;
        bool sawFirstLayer = false;
        for (const auto& layer : _config.getSubstrates()) {
            const double cellWidth = layer.thickness() / static_cast<double>(zCount);
            if (!sawFirstLayer) {
                firstLayerCellWidth = cellWidth;
                sawFirstLayer = true;
            }
            lastLayerCellWidth = cellWidth;
            for (std::int32_t i = 0; i < zCount; ++i) {
                zLines.push_back(offset - layer.thickness() +
                                  (layer.thickness() * static_cast<double>(i)) / static_cast<double>(zCount));
            }
            offset -= layer.thickness();
        }
        // Explicit anchor heights from geometry this function otherwise has no idea about -- e.g. a
        // diagonal lumped component's corner-bridge, routed through open airspace some distance above
        // the topmost (or below the bottommost) copper layer (see
        // Simulation::addLumpedComponentGrid()'s own doc comment). Without an anchor here, that
        // height would just fall wherever the *unrelated* graded densification below happens to land,
        // possibly in the middle of a cell far wider than the bridge's own small geometry -- pushed
        // in before densifyRegionGrid() runs (like the layer boundaries just added above), so the
        // same grading machinery treats it as a real point to grade around instead.
        for (const double height : additionalZHeights) {
            zLines.push_back(height);
        }

        const double zmin = *std::min_element(zLines.begin(), zLines.end());
        const double zmax = *std::max_element(zLines.begin(), zLines.end());
        // One genuine, ordinary (non-PML) transition cell immediately outside the board on each
        // side, matching the immediately-adjacent substrate layer's own per-cell width -- so the
        // dedicated PML band appended below starts from a real physical buffer cell, not directly
        // against the board's own top/bottom copper.
        zLines.push_back(zmax + firstLayerCellWidth);
        zLines.push_back(offset - lastLayerCellWidth);
        zLines.push_back(gridCfg.margin().z());
        zLines.push_back(offset - gridCfg.margin().z());

        zLines = Region(zmin, zmax).densifyRegionGrid(zLines, gridMax, gridMin, cellRatio);
        zLines = Region(zmax, margin).densifyRegionGrid(zLines, gridMax, gridMin, cellRatio);
        zLines = Region(offset - margin, zmin).densifyRegionGrid(zLines, gridMax, gridMin, cellRatio);
        zLines = _dedupGrid(zLines, gridMin, {});
        // Captured *after* the margin above is fully densified but *before* _extendPMLBand() below
        // appends the genuinely-dedicated PML cells -- i.e. "board + real margin," exactly mirroring
        // GridGeneratorAxis::compileGrid()'s own pmlInnerMin/Max capture for X/Y (a few hundred
        // lines up in this same file, from grid.front()/back() at the identical point in its own
        // sequence) -- X/Y's own _board region already includes margin.xy() on each side, so its
        // "inner" bound was never just the bare board either. Capturing from the bare substrate
        // zmin/zmax instead (an earlier version of this fix did) made the real, legitimate margin
        // band -- genuine mesh, not PML -- look identical to true PML in GeometryView's "Show Grid"
        // overlay, which colors anything outside pmlInnerZMin/Max magenta: the whole ~2mm margin
        // read as PML crammed right against the board, even though Set_BC_PML()'s own actual
        // 16-cell-deep shell sits comfortably beyond it. Diagnostic only either way -- nothing in
        // the FDTD pipeline itself reads these. No offset re-basing needed here the way X/Y's own
        // pmlInner values need (see GridGenerator::pmlInnerZMin()'s own doc comment in grid_gen.hpp):
        // Z has no separate per-axis local origin to begin with.
        // zLines is already sorted here (see _dedupGrid()'s own comment), so front()/back() are its
        // current extent -- same as GridGeneratorAxis::compileGrid()'s own grid.front()/back().
        if (!zLines.empty()) {
            _pmlInnerZMin = zLines.front();
            _pmlInnerZMax = zLines.back();
        }
        logInfo("### Grid Generator: z axis core mesh extent = [" + std::to_string(_pmlInnerZMin) + ", " +
                 std::to_string(_pmlInnerZMax) + "] ###");
        // Appends constants::pmlDepthCells brand-new, dedicated PML-only cells beyond each end --
        // exactly mirroring GridGeneratorAxis::compileGrid()'s own identical call for X/Y (a few
        // hundred lines up in this same file). Without this, Set_BC_PML()'s outermost-N-cells
        // classification (constants::pmlDepthCells = 16) reclassified part of the *margin* band
        // above as PML -- and since that margin band is only ~8 cells deep in Z (unlike X/Y's own,
        // comfortably wider than 16), the other 8 cells of "PML" landed squarely inside the real
        // substrate stack, overwriting perfectly correct dielectric vv/vi coefficients with PML's
        // own absorbing-boundary ones in every substrate layer within 16 cells of either Z face --
        // every one of them except the thick middle layer, which was the entire pattern behind the
        // vi/vv "collapse" this was traced back from.
        zLines = _extendPMLBand(std::move(zLines), constants::pmlDepthCells);

        {
            // _dedupGrid() sorts internally, so zLines is already sorted here -- one entry per
            // cell, positional (not just the worst-case ratio printGridStats() reports), in
            // microns (sim units are 0.1 micron each, per constants::unitMultiplier).
            std::string cells;
            for (std::size_t i = 0; i + 1 < zLines.size(); ++i) {
                if (!cells.empty()) {
                    cells += ", ";
                }
                cells += std::to_string((zLines[i + 1] - zLines[i]) / constants::unitMultiplier);
            }
            logInfo("### Grid Generator: z axis cell thicknesses (um), " + std::to_string(zLines.size() - 1) +
                     " cells = [" + cells + "] ###");
        }

        std::vector<std::int32_t> result;
        result.reserve(zLines.size());
        for (const double v : zLines) {
            result.push_back(static_cast<std::int32_t>(v));
        }
        return result;
    }

    CSRectGrid& generate(CSRectGrid& grid, const SimulationConfig& simConfig, const std::filesystem::path& fabDir,
                        const std::vector<std::string>& additionalDensityNets) {
        const double tessellationTolerance = static_cast<double>(_config.pixelSize()) * constants::unitMultiplier;
        // GerberFile::load() itself returns raw, unshifted file coordinates -- every other consumer
        // of trace/pad positions in this codebase (board_slicing.cpp, gerber_composite.cpp) re-origins
        // by this same edgeCutsBoundingBox() before using them, matching xmin/xmax/ymin/ymax above
        // (from GridGenerator's own constructor args, ultimately SlicedBoard::xMin/yMin -- see its own
        // doc comment on being Edge_Cuts-bounding-box-relative) and _board (compileGrid()'s own core
        // extent, the same frame). Without this, every trace/pad position parsed below is off by
        // this same origin from everything else in this function -- inBounds() below would reject
        // it outright (on a board whose Edge_Cuts doesn't happen to start near its own native gerber
        // origin), and even where it didn't, addLinesFromTrace()/addLinesFromPads()'s own placements
        // would land far outside _board's own span, discarded entirely once compileGrid() clips the
        // final line list to the real domain -- leaving only _board's own uniform density, with none
        // of the real per-trace/pad mesh refinement this whole nets/gerbers loop exists to produce.
        auto originResult = edgeCutsBoundingBox(fabDir, tessellationTolerance);
        if (!originResult) {
            logError(originResult.error());
            std::exit(1);
        }
        const BoundingBox& origin = *originResult;
        auto reOrigin = [&](const Position& p) { return Position(p.x() - origin.xMin, p.y() - origin.yMin); };

        std::vector<GerberFile> gerbers;
        std::error_code ec;
        if (std::filesystem::is_directory(fabDir, ec)) {
            for (const auto& entry : std::filesystem::directory_iterator(fabDir, ec)) {
                const std::string name = entry.path().filename().string();
                if (name.size() >= 7 && name.compare(name.size() - 7, 7, "_Cu.gbr") == 0) {
                    auto gerberResult = GerberFile::load(entry.path(), tessellationTolerance);
                    if (!gerberResult) {
                        logError(gerberResult.error());
                        std::exit(1);
                    }
                    gerbers.push_back(std::move(*gerberResult));
                }
            }
        }

        // "Nets of interest" for mesh-DENSITY placement purposes are this simulation's own resolved
        // involved nets (see SimulationConfig::resolvedNets()'s own doc comment, populated by
        // resolveSimulationPorts()) plus `additionalDensityNets` (ground plus any GeometryOnly-level
        // involved-nets entries -- see this class's own generate()'s doc comment in grid_gen.hpp for
        // why they get exactly the same treatment, not a separate mechanism: their own edge/pad
        // density naturally self-modulates with that net's own local complexity, wide open pour vs
        // dense stitching). The mesh's core-boundary (domain SIZE) is floored directly from the
        // sliced board's own extent below, independent of either list.
        // Wrapped in NetName rather than manually reversing KiCad's own "{slash}" escaping here (as
        // this used to) -- resolvedNets()/additionalDensityNets are in KiCad's escaped form, while
        // gbr.traceForNet()/addLinesFromPads() below compare straight against Gerber-derived data
        // (already NetName, real-unescaped-slash form -- see gerber_io.cpp); NetName's own
        // normalize-before-compare handles that mismatch structurally instead. See net_name.hpp's own
        // doc comment.
        std::vector<NetName> nets;
        for (const std::string& net : simConfig.resolvedNets()) {
            nets.emplace_back(net);
        }
        for (const std::string& net : additionalDensityNets) {
            const NetName name(net);
            if (std::find(nets.begin(), nets.end(), name) == nets.end()) {
                nets.push_back(name);
            }
        }
        {
            std::string netsList;
            for (const auto& n : nets) {
                if (!netsList.empty()) {
                    netsList += ", ";
                }
                netsList += n.unescaped();
            }
            logInfo("### Grid Generator: mesh-sizing nets = [" + netsList + "] ###");
        }

        // gbr.traceForNet()/gbr.pads() match purely by net *name*, with no geometric restriction to
        // this simulation's own sliced-board region -- fine on a gerber file that only ever contains
        // one board, but a net name (especially a common one like "GND") isn't unique across a
        // shared multi-DUT panel where several unrelated test coupons sit on the same physical
        // board/gerber files. Without this filter, copper from a totally different coupon elsewhere
        // on the panel gets pulled into this simulation's own mesh-*density* placement (the core
        // extent itself is fixed from the sliced board's own real size regardless -- see
        // compileGrid() -- so a stray far-away pad can no longer balloon the overall domain the way
        // it once could; this filter now only guards against wasted density mesh lines outside the
        // simulated region entirely). `filterMargin` reuses the grid's own configured margin as the
        // tolerance for "close enough to the board to legitimately matter" -- the same distance the
        // config already says is worth meshing past the board's own edge.
        const double filterMargin = _config.grid().margin().xy();
        const double filterXMin = xmin - filterMargin;
        const double filterXMax = xmax + filterMargin;
        const double filterYMin = ymin - filterMargin;
        const double filterYMax = ymax + filterMargin;
        // The bbox check is a cheap pre-filter only (generously padded by filterMargin, same as
        // before); the real test is inPolygonSetWithTolerance() against _boardCutout (SlicedBoard's
        // own true cutout shape -- every loop of it, generally non-rectangular and possibly
        // disjoint/holed, since it follows the involved nets' real inflated footprint, per
        // board_slicing.cpp's own InflatePaths() step, not their bounding box). Without the polygon
        // test, ground/GeometryOnly-level copper anywhere within the bbox but outside the actual
        // cutout got densified as if it were real simulated geometry, even directly over open vacuum
        // -- e.g. a via far from the involved nets but still inside their bounding rectangle. Using
        // the full loop set (not just outline's single largest loop) matters here specifically: a
        // single-loop test would wrongly treat every other disjoint cutout region, and any genuine
        // hole inside the largest one, as outside-or-inside respectively -- either way densifying
        // regions that aren't actually part of the simulated geometry.
        //
        // The polygon test's own tolerance is a tiny numerical-fuzz epsilon, deliberately NOT
        // filterMargin -- filterMargin is the mesh's own "how far past the board is still worth a
        // regular (non-PML) grid" distance, a completely different concept from "how far past a
        // trace's own copper is still legitimately that trace." The latter is already answered by
        // sim.hullPadding(), baked into _boardCutout's own shape by board_slicing.cpp; reusing
        // filterMargin here on top of that double-counted it, letting vacuum several mm beyond the
        // already-padded cutout boundary (up to filterMargin away from *any* point on that boundary,
        // not just the part nearest in the perpendicular direction) still count as real
        // density-driving geometry -- confirmed on a real board where accepted _parallel regions
        // reached all the way to within a few hundred sim-units of the outer margin/PML boundary,
        // ~5.9mm past the true cutout's own edge, entirely inside this now-removed tolerance band.
        constexpr double kPolygonToleranceSimUnits = 10.0; // 1 micron -- tessellation/rounding fuzz only.
        std::size_t bboxRejected = 0;
        std::size_t polygonRejected = 0;
        std::size_t bothPassed = 0;
        auto inBounds = [&](const Position& p) {
            if (p.x() < filterXMin || p.x() > filterXMax || p.y() < filterYMin || p.y() > filterYMax) {
                ++bboxRejected;
                return false;
            }
            if (!inPolygonSetWithTolerance(p, _boardCutout, kPolygonToleranceSimUnits)) {
                ++polygonRejected;
                return false;
            }
            ++bothPassed;
            return true;
        };
        {
            std::size_t cutoutPoints = 0;
            for (const auto& loop : _boardCutout) {
                cutoutPoints += loop.size();
            }
            const double bboxArea = (filterXMax - filterXMin) * (filterYMax - filterYMin);
            const double cutoutArea = polygonSetArea(_boardCutout);
            logInfo("### Grid Generator: cutout polygon filter = " + std::to_string(_boardCutout.size()) +
                     " loop(s), " + std::to_string(cutoutPoints) + " point(s) total, bbox=[" +
                     std::to_string(filterXMin) + "," + std::to_string(filterXMax) + "]x[" +
                     std::to_string(filterYMin) + "," + std::to_string(filterYMax) + "], bboxArea=" +
                     std::to_string(bboxArea) + ", cutoutArea=" + std::to_string(cutoutArea) + " (" +
                     std::to_string(bboxArea > 0 ? 100.0 * cutoutArea / bboxArea : 0.0) + "% of bbox) ###");
        }

        logInfo("### Grid Generator: parse gerber files ###");
        // Retained (net name -> every segment found for it, across every gerber/layer) purely for
        // the differential-pair coupling-gap pass below -- addLinesFromTrace() itself has no concept
        // of net identity (see its own doc comment), so this is the only point in this function where
        // "these segments belong to net X" is still known.
        std::unordered_map<NetName, std::vector<TraceSegment>, NetNameHash> segmentsByNet;
        std::size_t acceptedSegments = 0;
        std::size_t rejectedSegments = 0;
        std::size_t acceptedPads = 0;
        std::size_t rejectedPads = 0;
        for (auto& gbr : gerbers) {
            for (const auto& net : nets) {
                const Trace trace = gbr.traceForNet(net);
                std::vector<TraceSegment> segments;
                for (const auto& seg : trace.segments()) {
                    const Position start = reOrigin(seg.start());
                    const Position stop = reOrigin(seg.stop());
                    // Both endpoints, not just one: addLinesFromTrace() builds this segment's own
                    // density Region spanning its *original* start/stop coordinates verbatim (see
                    // that method's own doc comment -- it has no concept of the cutout shape at all,
                    // just raw geometry), so accepting a segment on the strength of only one endpoint
                    // being near the true cutout let its Region's other end -- wherever the segment's
                    // real, unclipped far endpoint happened to be -- densify everything in between.
                    // Harmless back when the filter was bbox-only (a segment crossing that boundary
                    // couldn't reach far outside it either), but with the precise polygon test above,
                    // a single long edge of an otherwise-correctly-excluded pour (one endpoint just
                    // inside the true cutout, the other far out in open vacuum, e.g. tracing the
                    // pour's own real perimeter) produced exactly this: a real, but wildly
                    // disproportionate, density region reaching arbitrarily far from any actually
                    // simulated copper. A segment straddling the true boundary now gets dropped
                    // entirely instead of partially trimmed -- an acceptable trade since
                    // sim.hullPadding() (baked into the cutout shape itself) already gives real,
                    // in-bounds copper a generous allowance before this boundary is even reached.
                    if (inBounds(start) && inBounds(stop)) {
                        segments.emplace_back(start, stop, seg.aperture(), seg.width(), seg.mode(), seg.normal());
                        ++acceptedSegments;
                    } else {
                        ++rejectedSegments;
                    }
                }
                x.addLinesFromTrace(segments);
                y.addLinesFromTrace(segments);
                auto& accumulated = segmentsByNet[net];
                accumulated.insert(accumulated.end(), segments.begin(), segments.end());
            }
            std::vector<Pad> pads;
            for (const auto& pad : gbr.pads()) {
                const Position pos = reOrigin(pad.pos());
                if (inBounds(pos)) {
                    pads.emplace_back(pad.aperture(), pad.net(), pos, pad.pinRef(), pad.additive(), pad.mirror(),
                                        pad.rotation(), pad.scale());
                    ++acceptedPads;
                } else {
                    ++rejectedPads;
                }
            }
            pads.insert(pads.end(), addPads.begin(), addPads.end());
            gbr.addApertures(addApertures);
            nets.push_back(NetName("PORT"));
            x.addLinesFromPads(pads, nets, gbr.apertures());
            y.addLinesFromPads(pads, nets, gbr.apertures());
        }
        logInfo("### Grid Generator: inBounds filter accepted " + std::to_string(acceptedSegments) + "/" +
                 std::to_string(acceptedSegments + rejectedSegments) + " trace segment(s), " +
                 std::to_string(acceptedPads) + "/" + std::to_string(acceptedPads + rejectedPads) + " pad(s) ###");
        logInfo("### Grid Generator: inBounds() point-level breakdown: " + std::to_string(bothPassed) +
                 " passed both bbox+polygon, " + std::to_string(bboxRejected) + " rejected by bbox, " +
                 std::to_string(polygonRejected) + " passed bbox but rejected by polygon ###");

        // Differential pairs get an extra densification pass beyond ordinary per-trace edge/optimal
        // handling -- see GridGeneratorAxis::addLinesFromDifferentialPair()'s own doc comment for why
        // the coupling gap between two legs otherwise ends up resolved far more coarsely than the
        // traces themselves. Deduplicated by unordered net-name pair since InvolvedNetConfig stores
        // the pairing reciprocally on both entries (mirrors port_resolution.cpp's own
        // generatedNetPairs pattern for the same reason) -- processed even if only declared on one
        // side, since a mesh-density pass has no correctness requirement as strict as mixed-mode
        // S-parameter postprocessing does.
        std::set<std::pair<NetName, NetName>> processedDiffPairs;
        for (const InvolvedNetConfig& entry : simConfig.involvedNets()) {
            if (entry.kind() != NetSelectorKind::Net || !entry.net().has_value() ||
                !entry.simulateAsDifferentialPair() || !entry.differentialPairPartner().has_value()) {
                continue;
            }
            const NetName firstNet(*entry.net());
            const NetName secondNet(*entry.differentialPairPartner());
            const auto pairKey = std::minmax(firstNet, secondNet);
            if (!processedDiffPairs.emplace(pairKey.first, pairKey.second).second) {
                continue; // already processed this pair, from either its own or its partner's entry
            }
            const auto firstSegments = segmentsByNet.find(firstNet);
            const auto secondSegments = segmentsByNet.find(secondNet);
            if (firstSegments == segmentsByNet.end() || secondSegments == segmentsByNet.end()) {
                continue; // neither net's own copper actually landed within this mesh's own bounds
            }
            x.addLinesFromDifferentialPair(firstSegments->second, secondSegments->second);
            y.addLinesFromDifferentialPair(firstSegments->second, secondSegments->second);
        }

        logInfo("### Grid Generator: generate X axis ###");
        x.compileGrid(grid, xmin);
        logInfo("### Grid Generator: generate Y axis ###");
        y.compileGrid(grid, ymin);

        const std::vector<std::int32_t> zLines = _generateZ();
        addGridLines(grid, "z", std::vector<double>(zLines.begin(), zLines.end()));

        return grid;
    }

    GridGeneratorAxis x;
    GridGeneratorAxis y;
    std::vector<Pad> addPads;
    std::unordered_map<std::string, Aperture> addApertures;
    std::vector<double> additionalZHeights;
    double xmin = 0;
    double xmax = 0;
    double ymin = 0;
    double ymax = 0;
    double _pmlInnerZMin = 0;
    double _pmlInnerZMax = 0;
    std::vector<std::vector<Position>> _boardCutout;
    const EMSConfig& _config;
};

GridGenerator::GridGenerator(const EMSConfig& config, double boardXMin, double boardYMin, double boardWidth,
                              double boardHeight, const std::vector<std::vector<Position>>& boardCutout)
    : _impl(std::make_unique<Impl>(config, boardXMin, boardYMin, boardWidth, boardHeight, boardCutout)) {}
GridGenerator::~GridGenerator() = default;

std::vector<Pad>& GridGenerator::addPads() { return _impl->addPads; }
std::unordered_map<std::string, Aperture>& GridGenerator::addApertures() { return _impl->addApertures; }
std::vector<double>& GridGenerator::additionalZHeights() { return _impl->additionalZHeights; }
double GridGenerator::xmin() const { return _impl->xmin; }
double GridGenerator::ymin() const { return _impl->ymin; }

double GridGenerator::pmlInnerXMin() const { return _impl->x.pmlInnerMin(); }
double GridGenerator::pmlInnerXMax() const { return _impl->x.pmlInnerMax(); }
double GridGenerator::pmlInnerYMin() const { return _impl->y.pmlInnerMin(); }
double GridGenerator::pmlInnerYMax() const { return _impl->y.pmlInnerMax(); }
double GridGenerator::pmlInnerZMin() const { return _impl->_pmlInnerZMin; }
double GridGenerator::pmlInnerZMax() const { return _impl->_pmlInnerZMax; }

CSRectGrid& GridGenerator::generate(CSRectGrid& grid, const SimulationConfig& simConfig,
                                     const std::filesystem::path& fabDir, const std::vector<std::string>& additionalDensityNets) {
    return _impl->generate(grid, simConfig, fabDir, additionalDensityNets);
}

} // namespace gerber2ems
