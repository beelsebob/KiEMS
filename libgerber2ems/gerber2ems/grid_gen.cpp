#include "grid_gen.hpp"

#include <algorithm>
#include <cmath>
#include <cstdlib>
#include <filesystem>
#include <functional>
#include <limits>
#include <sstream>

#include "config.hpp"
#include "constants.hpp"
#include "csx_grid_utils.hpp"
#include "logging.hpp"

namespace gerber2ems {

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
    /// `grid` must outlive this GridGeneratorAxis (kept by reference).
    GridGeneratorAxis(std::string axis, Region board, const Grid& grid)
        : _axis(std::move(axis)), _board(board), _grid(grid) {}

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

            if (seg.mode() != PlotMode::Linear) {
                _diagonal.push_back(region);
                continue;
            }

            if ((ang < deg5 && _axis == "x") || (ang > M_PI / 2 - deg5 && _axis == "y")) {
                _perpendicular.push_back(region);
            } else if ((ang < deg5 && _axis == "y") || (ang > M_PI / 2 - deg5 && _axis == "x")) {
                _parallel.push_back(region);
                if (seg.width() != 0 || seg.normal()) {
                    _edgeCells.emplace_back(region.min - 2 * w3, region.min + w3, slenOaxis + 1, region.min);
                }
                if (seg.width() != 0 || !seg.normal()) {
                    _edgeCells.emplace_back(region.max - w3, region.max + 2 * w3, slenOaxis + 1, region.max);
                }
            } else {
                _diagonal.push_back(region);
            }
        }
    }

    void addLinesFromPads(const std::vector<Pad>& pads, const std::vector<std::string>& nets,
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

    /// Shrinks/merges conflicting edge regions (following the rule of thirds as closely as possible).
    void resolveEdgeRegions() {
        const double gridSize = _grid.optimal();
        const double gridMin = gridSize / 1.8;
        std::sort(_edgeCells.begin(), _edgeCells.end(),
                  [](const Region& a, const Region& b) { return a.prio > b.prio; }); // high to low
        std::vector<std::size_t> toDelete;
        for (std::size_t i = 0; i < _edgeCells.size(); ++i) {
            Region reg = _edgeCells[i];
            for (std::size_t j = 0; j < i; ++j) {
                if (std::find(toDelete.begin(), toDelete.end(), j) != toDelete.end()) {
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
                toDelete.push_back(j);
                reg = newReg;
                _edgeCells[i] = newReg;
                _edgeCells[j] = newReg;
            }
        }

        std::sort(toDelete.rbegin(), toDelete.rend());
        for (const std::size_t idx : toDelete) {
            _edgeCells.erase(_edgeCells.begin() + static_cast<std::ptrdiff_t>(idx));
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
        if (_grid.margin().fromTrace()) {
            _board.min = std::numeric_limits<double>::infinity();
            _board.max = -std::numeric_limits<double>::infinity();
            for (const auto* list : {&_edgeCells, &_diagonal, &_parallel, &_perpendicular}) {
                for (const auto& r : *list) {
                    _board.min = std::min(_board.min, r.min);
                    _board.max = std::max(_board.max, r.max);
                }
            }
            const double margin = _grid.margin().xy();
            _board.min -= margin;
            _board.max += margin;
        } else {
            _board.min += offset;
            _board.max += offset;
        }

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

        for (const auto& reg : _parallel) {
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

        std::vector<double> intLines;
        intLines.reserve(grid.size());
        for (const double line : grid) {
            intLines.push_back(static_cast<double>(static_cast<std::int32_t>(line - offset)));
        }

        addGridLines(csgrid, _axis, intLines);
        return csgrid;
    }

private:
    /// Merges overlapping regions in `regList` in place.
    void _mergeRegions(std::vector<Region>& regList, double gridSize) {
        std::vector<std::size_t> toDelete;
        for (std::size_t i = 0; i < regList.size(); ++i) {
            Region reg = regList[i];
            for (std::size_t j = 0; j < i; ++j) {
                if (std::find(toDelete.begin(), toDelete.end(), j) != toDelete.end()) {
                    continue;
                }
                Region reg2 = regList[j];
                if (reg.distance(reg2) < gridSize) {
                    const double nmin = std::min(reg.min, reg2.min);
                    const double nmax = std::max(reg.max, reg2.max);
                    const Region newReg(nmin, nmax, reg.prio + reg2.prio, (nmin + nmax) / 2);
                    toDelete.push_back(j);
                    reg = newReg;
                    regList[i] = newReg;
                    regList[j] = newReg;
                }
            }
        }
        std::sort(toDelete.rbegin(), toDelete.rend());
        for (const std::size_t idx : toDelete) {
            regList.erase(regList.begin() + static_cast<std::ptrdiff_t>(idx));
        }
    }

    std::string _axis;
    Region _board;
    std::vector<Region> _edgeCells;
    std::vector<Region> _parallel;
    std::vector<Region> _diagonal;
    std::vector<Region> _perpendicular;
    const Grid& _grid;
};

} // namespace

struct GridGenerator::Impl {
    Impl(const EMSConfig& config, double boardXMin, double boardYMin, double boardWidth, double boardHeight)
        : x("x", Region(-config.grid().margin().xy(), boardWidth + config.grid().margin().xy()), config.grid()),
          y("y", Region(-config.grid().margin().xy(), boardHeight + config.grid().margin().xy()), config.grid()),
          xmin(boardXMin),
          xmax(boardXMin + boardWidth),
          ymin(boardYMin),
          ymax(boardYMin + boardHeight),
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
        for (const auto& layer : _config.getSubstrates()) {
            for (std::int32_t i = 0; i < zCount; ++i) {
                zLines.push_back(offset - layer.thickness() +
                                  (layer.thickness() * static_cast<double>(i)) / static_cast<double>(zCount));
            }
            offset -= layer.thickness();
        }
        const double zmin = *std::min_element(zLines.begin(), zLines.end());
        const double zmax = *std::max_element(zLines.begin(), zLines.end());
        zLines.push_back(gridCfg.margin().z());
        zLines.push_back(offset - gridCfg.margin().z());

        zLines = Region(zmin, zmax).densifyRegionGrid(zLines, gridMax, gridMin, cellRatio);
        zLines = Region(zmax, margin).densifyRegionGrid(zLines, gridMax, gridMin, cellRatio);
        zLines = Region(offset - margin, zmin).densifyRegionGrid(zLines, gridMax, gridMin, cellRatio);
        zLines = _dedupGrid(zLines, gridMin, {});

        std::vector<std::int32_t> result;
        result.reserve(zLines.size());
        for (const double v : zLines) {
            result.push_back(static_cast<std::int32_t>(v));
        }
        return result;
    }

    CSRectGrid& generate(CSRectGrid& grid, const SimulationConfig& simConfig, const std::filesystem::path& fabDir) {
        const double tessellationTolerance = static_cast<double>(_config.pixelSize()) * constants::unitMultiplier;
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

        // "Nets of interest" for mesh-density purposes are simply this simulation's own resolved
        // involved nets (see SimulationConfig::resolvedNets(), populated by resolveSimulationPorts())
        // -- board slicing has already reduced the board down to just these nets' (plus the ground
        // net's) copper, so there's no longer a separate "guess which nets matter" step needed.
        std::vector<std::string> nets = simConfig.resolvedNets();

        logInfo("### Grid Generator: parse gerber files ###");
        for (auto& gbr : gerbers) {
            for (const auto& net : nets) {
                const Trace trace = gbr.traceForNet(net);
                x.addLinesFromTrace(trace.segments());
                y.addLinesFromTrace(trace.segments());
            }
            std::vector<Pad> pads = gbr.pads();
            pads.insert(pads.end(), addPads.begin(), addPads.end());
            gbr.addApertures(addApertures);
            nets.push_back("PORT");
            x.addLinesFromPads(pads, nets, gbr.apertures());
            y.addLinesFromPads(pads, nets, gbr.apertures());
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
    double xmin = 0;
    double xmax = 0;
    double ymin = 0;
    double ymax = 0;
    const EMSConfig& _config;
};

GridGenerator::GridGenerator(const EMSConfig& config, double boardXMin, double boardYMin, double boardWidth,
                              double boardHeight)
    : _impl(std::make_unique<Impl>(config, boardXMin, boardYMin, boardWidth, boardHeight)) {}
GridGenerator::~GridGenerator() = default;

std::vector<Pad>& GridGenerator::addPads() { return _impl->addPads; }
std::unordered_map<std::string, Aperture>& GridGenerator::addApertures() { return _impl->addApertures; }
double GridGenerator::xmin() const { return _impl->xmin; }
double GridGenerator::ymin() const { return _impl->ymin; }

CSRectGrid& GridGenerator::generate(CSRectGrid& grid, const SimulationConfig& simConfig,
                                     const std::filesystem::path& fabDir) {
    return _impl->generate(grid, simConfig, fabDir);
}

} // namespace gerber2ems
