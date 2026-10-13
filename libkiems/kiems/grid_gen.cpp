#include "grid_gen.hpp"

#include <algorithm>
#include <array>
#include <cmath>
#include <cstdlib>
#include <functional>
#include <limits>
#include <set>
#include <sstream>
#include <unordered_map>
#include <utility>

#include "config.hpp"
#include "constants.hpp"
#include "csx_grid_utils.hpp"
#include "libkicad/libkicad.hpp"
#include "logging.hpp"

namespace kiems {

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
    // Lines closer than gridMin / 2 collapse into one. A protected (edgeGrid) line marks real copper
    // and never moves for an unprotected neighbour, which it absorbs; two lines of the same kind meet
    // halfway. Merging two copper edges can close the gap between them -- a ball and the pour
    // across its clearance landing on one row of nodes -- but GridGenerator reopens exactly those
    // gaps afterwards (grid_detail::resolveCopperJoins()), which costs far fewer cells and far less
    // timestep than keeping every close pair of edges apart with a sliver cell between them.
    std::vector<double> protectedLines = edgeGrid;
    std::sort(protectedLines.begin(), protectedLines.end());
    const auto isProtected = [&](double line) {
        return std::binary_search(protectedLines.begin(), protectedLines.end(), line);
    };
    std::sort(grid.begin(), grid.end());
    std::vector<double> result;
    result.reserve(grid.size());
    for (const double line : grid) {
        if (result.empty() || line - result.back() >= gridMin / 2) {
            result.push_back(line);
            continue;
        }
        const bool previousProtected = isProtected(result.back());
        const bool lineProtected = isProtected(line);
        if (previousProtected && lineProtected) {
            result.back() = (result.back() + line) / 2;
            protectedLines.insert(std::lower_bound(protectedLines.begin(), protectedLines.end(), result.back()),
                                  result.back());
        } else if (lineProtected) {
            result.back() = line;
        } else if (!previousProtected) {
            result.back() = (result.back() + line) / 2;
        }
    }
    return result;
}

/// Stores a range with additional data as priority and center position. Purely internal to grid
/// generation, so (per the earlier agreed pattern for private, never-exposed state) fields stay
/// plain rather than getter/setter-encapsulated.
class Region {
public:
    Region() = default;
    Region(double regionMin, double regionMax, double regionPrio = 1, double regionCenter = 0, int regionSide = 0)
        : min(regionMin), max(regionMax), prio(regionPrio), center(regionCenter), side(regionSide) {}

    bool operator==(const Region& other) const {
        return min == other.min && max == other.max && prio == other.prio && center == other.center &&
               side == other.side;
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
    /// For an edge cell: +1 where copper begins (it lies above `center` along this axis), -1 where
    /// it ends, 0 when unknown or merged from both kinds.
    int side = 0;
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

            if (seg.mode() != PlotMode::Linear) {
                _diagonal.push_back(region);
                continue;
            }

            if ((ang < deg5 && _axis == "x") || (ang > M_PI / 2 - deg5 && _axis == "y")) {
                _perpendicular.push_back(region);
            } else if ((ang < deg5 && _axis == "y") || (ang > M_PI / 2 - deg5 && _axis == "x")) {
                _parallel.push_back(region);
                if (seg.width() != 0 || seg.normal()) {
                    _edgeCells.emplace_back(region.min - 2 * w3, region.min + w3, slenOaxis + 1, region.min, +1);
                }
                if (seg.width() != 0 || !seg.normal()) {
                    _edgeCells.emplace_back(region.max - w3, region.max + 2 * w3, slenOaxis + 1, region.max, -1);
                }
            } else {
                _diagonal.push_back(region);
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
                // Copper ending, then copper beginning above it, bounds a gap: merging the two would
                // average away the lines on either side of it and leave the gap unmeshed.
                const Region& lower = reg.center <= reg2.center ? reg : reg2;
                const Region& upper = reg.center <= reg2.center ? reg2 : reg;
                if (lower.side == -1 && upper.side == +1 && upper.center > lower.center) {
                    continue;
                }
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
                                     (reg.center * reg.prio + reg2.center * reg2.prio) / (reg.prio + reg2.prio),
                                     reg.side == reg2.side ? reg.side : 0);
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
        // `_board` is the minimum outer extent (sliced board + configured vacuum margin). It must
        // not itself be passed through Region's generic two-sided densifier: that algorithm treats
        // both margin boundaries as constrained neighbours and can make cells shrink again while
        // moving away from the board merely to meet the artificial outer endpoint. Density is
        // generated only through the real sliced-board extent below; exterior padding is rebuilt
        // one-way afterward.
        _board.min += offset;
        _board.max += offset;

        for (const auto& reg : _edgeCells) {
            grid.push_back(reg.min);
            grid.push_back(reg.max);
        }
        grid.push_back(_trustedMin);
        grid.push_back(_trustedMax);
        const std::vector<double> edgeGrid = grid;

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

        const Region slicedBoardRegion(_trustedMin, _trustedMax);
        grid = slicedBoardRegion.densifyRegionGrid(grid, _grid.max(), gridMin, cellRatio);
        grid = _dedupGrid(grid, gridMin, edgeGrid);
        // Delete every line the general density passes may have placed beyond the cut board, then
        // construct the vacuum region from scratch. This makes the intended ordering explicit:
        // cut geometry -> mesh cut geometry -> monotonically expanding padding -> uniform CPML.
        grid = grid_detail::rebuildExteriorPadding(std::move(grid), _trustedMin, _trustedMax,
                                                    _board.min, _board.max, _grid.max(), cellRatio,
                                                    gridMin / 2.0);
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
        grid = grid_detail::appendUniformPMLCells(std::move(grid), _grid.absorbingBoundaryCells());

        // `grid` is in the same absolute, Edge_Cuts-bounding-box-relative frame as every geometry
        // primitive this Simulation adds (addSubstrates()/addGerbers()/addMslPort()/addVias() all
        // place things directly from _slicedBoard.bounds.xMin/yMin, never offset) -- the real CSRectGrid
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
/// polygon set: a hole loop's opposite winding doesn't need to be identified explicitly
/// -- ray-casting parity naturally flips back to "outside" once a ray has crossed into and back out
/// of a hole, and a genuinely separate, disjoint outer loop just contributes its own independent
/// crossings the same way. Deliberately independent of the geometry backend: a plain membership
/// test on the same
/// double-precision Position data already produced from KiCad avoids an unnecessary coordinate
/// conversion.
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

std::vector<TraceSegment> grid_detail::copperBoundarySegments(
    const std::vector<Cu::PolygonSet>& layerCopperLoops) {
    std::vector<TraceSegment> result;
    for (const Cu::PolygonSet& layer : layerCopperLoops) {
        for (const Cu::Polygon& loop : layer) {
            if (loop.size() < 2) continue;
            for (std::size_t i = 0, j = loop.size() - 1; i < loop.size(); j = i++) {
                if (loop[j].x() == loop[i].x() && loop[j].y() == loop[i].y()) continue;
                result.emplace_back(loop[j], loop[i], "", 0.0);
            }
        }
    }
    return result;
}

std::vector<TraceSegment> grid_detail::clipTraceSegmentsToCutout(
    const std::vector<TraceSegment>& segments,
    const std::vector<std::vector<Position>>& cutoutLoops,
    double boundaryTolerance) {
    if (cutoutLoops.empty()) return segments;

    constexpr double kParameterEpsilon = 1e-10;
    auto cross = [](double ax, double ay, double bx, double by) { return ax * by - ay * bx; };
    std::vector<TraceSegment> clipped;
    for (const TraceSegment& segment : segments) {
        const Position& a = segment.start();
        const Position& b = segment.stop();
        const double rx = b.x() - a.x();
        const double ry = b.y() - a.y();
        std::vector<double> parameters = {0.0, 1.0};
        for (const std::vector<Position>& loop : cutoutLoops) {
            if (loop.size() < 2) continue;
            for (std::size_t i = 0, j = loop.size() - 1; i < loop.size(); j = i++) {
                const Position& c = loop[j];
                const Position& d = loop[i];
                const double sx = d.x() - c.x();
                const double sy = d.y() - c.y();
                const double denominator = cross(rx, ry, sx, sy);
                if (std::abs(denominator) <= kParameterEpsilon) continue;
                const double cax = c.x() - a.x();
                const double cay = c.y() - a.y();
                const double t = cross(cax, cay, sx, sy) / denominator;
                const double u = cross(cax, cay, rx, ry) / denominator;
                if (t >= -kParameterEpsilon && t <= 1.0 + kParameterEpsilon &&
                    u >= -kParameterEpsilon && u <= 1.0 + kParameterEpsilon) {
                    parameters.push_back(std::clamp(t, 0.0, 1.0));
                }
            }
        }
        std::sort(parameters.begin(), parameters.end());
        parameters.erase(std::unique(parameters.begin(), parameters.end(), [](double lhs, double rhs) {
                             return std::abs(lhs - rhs) <= kParameterEpsilon;
                         }), parameters.end());
        auto interpolate = [&](double t) { return Position(a.x() + t * rx, a.y() + t * ry); };
        for (std::size_t i = 0; i + 1 < parameters.size(); ++i) {
            const double t0 = parameters[i];
            const double t1 = parameters[i + 1];
            if (t1 - t0 <= kParameterEpsilon ||
                !inPolygonSetWithTolerance(interpolate((t0 + t1) * 0.5), cutoutLoops, boundaryTolerance)) {
                continue;
            }
            clipped.emplace_back(interpolate(t0), interpolate(t1), segment.aperture(), segment.width(),
                                 segment.mode(), segment.normal());
        }
    }
    return clipped;
}

std::vector<double> grid_detail::dedupGrid(std::vector<double> grid, double gridMin,
                                           const std::vector<double>& protectedLines) {
    return _dedupGrid(std::move(grid), gridMin, protectedLines);
}

std::vector<double> grid_detail::meshAxis(const std::string& axis, const std::vector<TraceSegment>& copperSegments,
                                          const Grid& grid, double trustedMin, double trustedMax) {
    const double margin = grid.margin().xy();
    GridGeneratorAxis generator(axis, Region(-margin, trustedMax - trustedMin + margin), grid, trustedMin, trustedMax);
    generator.addLinesFromTrace(copperSegments);
    CSRectGrid csGrid;
    generator.compileGrid(csGrid, trustedMin);
    const int axisIndex = axis == "x" ? 0 : axis == "y" ? 1 : 2;
    unsigned int quantity = 0;
    double* lines = csGrid.GetLines(axisIndex, nullptr, quantity, true);
    std::vector<double> result(lines, lines + quantity);
    delete[] lines;
    return result;
}

std::vector<grid_detail::HullCutPoint> grid_detail::hullCutTracePoints(
    const std::vector<HullCutTrace>& traces,
    const std::vector<std::vector<Position>>& cutoutLoops,
    double boundaryTolerance) {
    std::vector<HullCutPoint> result;
    const double comparisonTolerance = std::max(boundaryTolerance, 1e-6);
    auto distance = [](const Position& a, const Position& b) {
        return std::hypot(a.x() - b.x(), a.y() - b.y());
    };
    auto append = [&](std::size_t traceIndex, const Position& boundary, const Position& inside) {
        const HullCutTrace& trace = traces[traceIndex];
        for (const HullCutPoint& existing : result) {
            if (existing.netName == trace.netName && existing.layerName == trace.layerName &&
                distance(existing.position, boundary) <= comparisonTolerance) {
                return;
            }
        }
        const double direction = std::atan2(inside.y() - boundary.y(), inside.x() - boundary.x()) * 180.0 / M_PI;
        const Position& start = trace.segment.start();
        const Position& stop = trace.segment.stop();
        const double alongX = stop.x() - start.x();
        const double alongY = stop.y() - start.y();
        const bool keepsTrackEnd = (inside.x() - boundary.x()) * alongX + (inside.y() - boundary.y()) * alongY > 0;
        const double lengthSquared = alongX * alongX + alongY * alongY;
        const double fraction =
            lengthSquared > 0
                ? std::clamp(((boundary.x() - start.x()) * alongX + (boundary.y() - start.y()) * alongY) / lengthSquared,
                             0.0, 1.0)
                : 0.0;
        result.push_back({boundary, trace.netName, trace.layerName,
                          direction < 0 ? direction + 360.0 : direction, trace.segment.width(), trace.trackUUID,
                          keepsTrackEnd, static_cast<double>(traceIndex) + fraction});
    };
    auto onBoundary = [&](const Position& p) {
        for (const std::vector<Position>& loop : cutoutLoops) {
            for (std::size_t i = 0, j = loop.size() - 1; i < loop.size(); j = i++) {
                if (pointSegmentDistance(p, loop[j], loop[i]) <= comparisonTolerance) return true;
            }
        }
        return false;
    };
    std::vector<std::vector<TraceSegment>> piecesByTrace;
    piecesByTrace.reserve(traces.size());
    for (const HullCutTrace& trace : traces) {
        piecesByTrace.push_back(clipTraceSegmentsToCutout({trace.segment}, cutoutLoops, boundaryTolerance));
    }
    // An original corner can sit on the hull when the hull outline passes through a bend. It is
    // a cut unless another retained piece of the same net and layer carries the trace on from it.
    auto continuesInside = [&](std::size_t self, const Position& corner) {
        for (std::size_t other = 0; other < traces.size(); ++other) {
            if (other == self || traces[other].netName != traces[self].netName ||
                traces[other].layerName != traces[self].layerName) {
                continue;
            }
            for (const TraceSegment& piece : piecesByTrace[other]) {
                if (distance(piece.start(), corner) <= comparisonTolerance ||
                    distance(piece.stop(), corner) <= comparisonTolerance) {
                    return true;
                }
            }
        }
        return false;
    };
    for (std::size_t index = 0; index < traces.size(); ++index) {
        const HullCutTrace& trace = traces[index];
        auto isCut = [&](const Position& end) {
            const bool original = distance(end, trace.segment.start()) <= comparisonTolerance ||
                                  distance(end, trace.segment.stop()) <= comparisonTolerance;
            return !original || (onBoundary(end) && !continuesInside(index, end));
        };
        for (const TraceSegment& piece : piecesByTrace[index]) {
            if (isCut(piece.start())) append(index, piece.start(), piece.stop());
            if (isCut(piece.stop())) append(index, piece.stop(), piece.start());
        }
    }
    return result;
}

std::vector<double> grid_detail::growGridBoundaryCellsToSize(std::vector<double> lines,
                                                              double targetCellSize,
                                                              double maximumCellRatio) {
    std::sort(lines.begin(), lines.end());
    if (lines.size() < 2 || targetCellSize <= 0 || maximumCellRatio <= 1) return lines;

    auto transitionWidths = [&](double initialWidth) {
        std::vector<double> widths;
        double width = initialWidth;
        constexpr std::size_t kMaximumTransitionCells = 1024;
        while (width > 0 && width < targetCellSize && widths.size() < kMaximumTransitionCells) {
            width = std::min(targetCellSize, width * maximumCellRatio);
            widths.push_back(width);
        }
        return widths;
    };

    const std::vector<double> lowWidths = transitionWidths(lines[1] - lines[0]);
    std::vector<double> lowLines;
    lowLines.reserve(lowWidths.size());
    double lowPosition = lines.front();
    for (const double width : lowWidths) {
        lowPosition -= width;
        lowLines.push_back(lowPosition);
    }
    lines.insert(lines.begin(), lowLines.rbegin(), lowLines.rend());

    // The original high boundary remains at `lines.size() - lowLines.size() - 1`; prepending does
    // not change its adjacent width, so using the final two original values before appending is safe.
    const std::size_t originalHighIndex = lines.size() - 1;
    const std::vector<double> highWidths =
        transitionWidths(lines[originalHighIndex] - lines[originalHighIndex - 1]);
    double highPosition = lines.back();
    for (const double width : highWidths) {
        highPosition += width;
        lines.push_back(highPosition);
    }
    return lines;
}

std::vector<double> grid_detail::rebuildExteriorPadding(std::vector<double> lines, double contentMin,
                                                         double contentMax, double minimumDomainMin,
                                                         double minimumDomainMax, double targetCellSize,
                                                         double maximumCellRatio,
                                                         double minimumBoundaryCellSize) {
    if (contentMax <= contentMin || targetCellSize <= 0 || maximumCellRatio <= 1) return lines;

    std::sort(lines.begin(), lines.end());
    lines.erase(std::remove_if(lines.begin(), lines.end(), [&](double line) {
                    if (line < contentMin || line > contentMax) return true;
                    // The sliced-board boundary is an indispensable domain boundary. If an
                    // independently protected copper/edge line is nearly coincident with it,
                    // keeping both creates a microscopic cell that dominates the CFL timestep and
                    // seeds dozens of tiny outward transition cells. Snap that unresolvable feature
                    // to the board boundary by dropping the interior line before inserting the
                    // authoritative endpoint below.
                    if (line > contentMin && line - contentMin < minimumBoundaryCellSize) return true;
                    if (line < contentMax && contentMax - line < minimumBoundaryCellSize) return true;
                    return false;
                }),
                lines.end());
    lines.push_back(contentMin);
    lines.push_back(contentMax);
    std::sort(lines.begin(), lines.end());
    lines.erase(std::unique(lines.begin(), lines.end()), lines.end());
    if (lines.size() < 2) return lines;

    constexpr std::size_t kMaximumPaddingCellsPerSide = 1000000;
    auto outwardWidths = [&](double initialWidth, double distanceRequired) {
        std::vector<double> widths;
        double width = initialWidth > 0 ? initialWidth : targetCellSize;
        double distance = 0;
        while ((distance < distanceRequired || width < targetCellSize) &&
               widths.size() < kMaximumPaddingCellsPerSide) {
            width = std::min(targetCellSize, width * maximumCellRatio);
            widths.push_back(width);
            distance += width;
        }
        return widths;
    };

    const std::vector<double> lowWidths =
        outwardWidths(lines[1] - lines[0], std::max(0.0, contentMin - minimumDomainMin));
    std::vector<double> lowLines;
    lowLines.reserve(lowWidths.size());
    double lowPosition = lines.front();
    for (const double width : lowWidths) {
        lowPosition -= width;
        lowLines.push_back(lowPosition);
    }
    lines.insert(lines.begin(), lowLines.rbegin(), lowLines.rend());

    const std::vector<double> highWidths =
        outwardWidths(lines[lines.size() - 1] - lines[lines.size() - 2],
                      std::max(0.0, minimumDomainMax - contentMax));
    double highPosition = lines.back();
    for (const double width : highWidths) {
        highPosition += width;
        lines.push_back(highPosition);
    }
    return lines;
}

std::vector<double> grid_detail::appendUniformPMLCells(std::vector<double> lines, std::int32_t cellCount) {
    return _extendPMLBand(std::move(lines), cellCount);
}

namespace {

/// One copper layer's loops, prepared for the sweeps copperJoins() makes along every mesh line.
/// Loops only nest (board slicing unions each layer), so the innermost loop containing a point is
/// the smallest one: an outer loop's copper, or a hole in it.
struct _LayerLoops {
    const Cu::PolygonSet* loops = nullptr;
    std::vector<Cu::BoundingBox<double>> bounds;
    std::vector<double> area;
    std::vector<bool> outer;
    /// The copper a point on each loop's boundary belongs to: the loop itself, or for a hole the
    /// outer loop round it (Copper paints copper as triangles, boundaries included).
    std::vector<std::int32_t> boundaryOwner;
};

/// pointInPolygonSet() for a single loop, without copying it into a set.
bool _insideLoop(const Position& point, const Cu::Polygon& loop) {
    bool inside = false;
    for (std::size_t i = 0, j = loop.size() - 1; i < loop.size(); j = i++) {
        if (((loop[i].y() > point.y()) != (loop[j].y() > point.y())) &&
            (point.x() < (loop[j].x() - loop[i].x()) * (point.y() - loop[i].y()) / (loop[j].y() - loop[i].y()) +
                             loop[i].x())) {
            inside = !inside;
        }
    }
    return inside;
}

_LayerLoops _prepareLayerLoops(const Cu::PolygonSet& loops) {
    _LayerLoops layer;
    layer.loops = &loops;
    for (const Cu::Polygon& loop : loops) {
        layer.bounds.push_back(Cu::bounds(loop));
        const double signedArea = Cu::signedArea(loop);
        layer.area.push_back(std::abs(signedArea));
        layer.outer.push_back(signedArea > 0);
    }
    for (std::size_t k = 0; k < loops.size(); ++k) {
        std::int32_t owner = layer.outer[k] ? static_cast<std::int32_t>(k) : -1;
        double smallest = std::numeric_limits<double>::infinity();
        for (std::size_t parent = 0; !layer.outer[k] && !loops[k].empty() && parent < loops.size(); ++parent) {
            const Cu::BoundingBox<double>& a = layer.bounds[parent];
            const Cu::BoundingBox<double>& b = layer.bounds[k];
            if (!layer.outer[parent] || layer.area[parent] >= smallest || a.xMin > b.xMin || a.xMax < b.xMax ||
                a.yMin > b.yMin || a.yMax < b.yMax) {
                continue;
            }
            if (_insideLoop(loops[k].front(), loops[parent])) {
                owner = static_cast<std::int32_t>(parent);
                smallest = layer.area[parent];
            }
        }
        layer.boundaryOwner.push_back(owner);
    }
    return layer;
}

double _coordinate(const Position& point, int axis) { return axis == 0 ? point.x() : point.y(); }

/// For points along one mesh line -- `fixed` on the other axis, `queries` (sorted) along `axis` --
/// the outer loop whose copper each lies on, boundaries included, or -1 off copper.
void _lineOwners(const _LayerLoops& layer, int axis, double fixed, const std::vector<double>& queries,
                 std::int32_t* owners) {
    struct Crossing {
        double at;
        std::size_t loop;
    };
    struct Run {
        double from;
        double to;
        std::int32_t owner;
    };
    std::vector<Crossing> crossings;
    std::vector<Run> collinear; // boundary edges lying along the line itself
    const int other = 1 - axis;
    for (std::size_t k = 0; k < layer.loops->size(); ++k) {
        const Cu::BoundingBox<double>& box = layer.bounds[k];
        if (fixed < (other == 0 ? box.xMin : box.yMin) || fixed > (other == 0 ? box.xMax : box.yMax)) continue;
        const Cu::Polygon& loop = (*layer.loops)[k];
        for (std::size_t i = 0, j = loop.size() - 1; i < loop.size(); j = i++) {
            const double v0 = _coordinate(loop[j], other);
            const double v1 = _coordinate(loop[i], other);
            const double u0 = _coordinate(loop[j], axis);
            const double u1 = _coordinate(loop[i], axis);
            if (v0 == fixed && v1 == fixed) {
                collinear.push_back({std::min(u0, u1), std::max(u0, u1), layer.boundaryOwner[k]});
                continue;
            }
            if ((v0 <= fixed) == (v1 <= fixed)) continue;
            crossings.push_back({u0 + (fixed - v0) * (u1 - u0) / (v1 - v0), k});
        }
    }
    std::sort(crossings.begin(), crossings.end(), [](const Crossing& a, const Crossing& b) { return a.at < b.at; });
    // The loops containing the current point, smallest first: each crossing passed toggles one.
    std::set<std::pair<double, std::size_t>> containing;
    std::size_t next = 0;
    for (std::size_t q = 0; q < queries.size(); ++q) {
        for (; next < crossings.size() && crossings[next].at <= queries[q]; ++next) {
            const std::pair key{layer.area[crossings[next].loop], crossings[next].loop};
            if (containing.erase(key) == 0) containing.insert(key);
        }
        const bool onCopper = !containing.empty() && layer.outer[containing.begin()->second];
        owners[q] = onCopper ? static_cast<std::int32_t>(containing.begin()->second) : -1;
        // A point exactly on a boundary the line crosses is that boundary's copper.
        for (std::size_t k = next; k > 0 && crossings[k - 1].at == queries[q]; --k) {
            owners[q] = layer.boundaryOwner[crossings[k - 1].loop];
        }
    }
    for (const Run& run : collinear) {
        const auto first = std::lower_bound(queries.begin(), queries.end(), run.from);
        const auto last = std::upper_bound(first, queries.end(), run.to);
        for (auto it = first; it != last; ++it) owners[it - queries.begin()] = run.owner;
    }
}

/// The outer loop whose copper `point` lies on, or -1.
std::int32_t _pointOwner(const _LayerLoops& layer, const Position& point) {
    std::int32_t owner = -1;
    double smallest = std::numeric_limits<double>::infinity();
    for (std::size_t k = 0; k < layer.loops->size(); ++k) {
        const Cu::BoundingBox<double>& box = layer.bounds[k];
        if (point.x() < box.xMin || point.x() > box.xMax || point.y() < box.yMin || point.y() > box.yMax) continue;
        if (layer.area[k] < smallest && _insideLoop(point, (*layer.loops)[k])) {
            smallest = layer.area[k];
            owner = layer.outer[k] ? static_cast<std::int32_t>(k) : -1;
        }
    }
    return owner;
}

} // namespace

bool grid_detail::isViaCircleSegment(const TraceSegment& segment, const std::vector<CopperBarrel>& barrels) {
    // A via's pad and antipad stay within half a millimetre of it, and a flattened circle's
    // segments end within a couple of microns of the same radius.
    constexpr double kReach = 500.0 * constants::unitMultiplier;
    constexpr double kRadiusTolerance = 2.0 * constants::unitMultiplier;
    const Position& a = segment.start();
    const Position& b = segment.stop();
    const double length = std::hypot(b.x() - a.x(), b.y() - a.y());
    for (const CopperBarrel& barrel : barrels) {
        for (const auto& [cx, cy] : {std::pair{barrel.x1, barrel.y1}, std::pair{barrel.x2, barrel.y2}}) {
            if (std::abs(a.x() - cx) > kReach || std::abs(a.y() - cy) > kReach) continue;
            const double ra = std::hypot(a.x() - cx, a.y() - cy);
            const double rb = std::hypot(b.x() - cx, b.y() - cy);
            if (ra <= kReach && std::abs(ra - rb) < kRadiusTolerance && length <= ra) return true;
        }
    }
    return false;
}

std::vector<grid_detail::CopperJoin> grid_detail::copperJoins(const std::vector<double>& xLines,
                                                              const std::vector<double>& yLines,
                                                              const std::vector<Cu::PolygonSet>& layerCopperLoops,
                                                              const std::vector<CopperBarrel>& barrels,
                                                              std::size_t barrelLayers) {
    std::vector<CopperJoin> joins;
    const std::size_t nx = xLines.size();
    const std::size_t ny = yLines.size();
    if (nx < 2 || ny < 2) return joins;
    std::vector<double> xMid(nx - 1);
    std::vector<double> yMid(ny - 1);
    for (std::size_t i = 0; i + 1 < nx; ++i) xMid[i] = (xLines[i] + xLines[i + 1]) / 2;
    for (std::size_t j = 0; j + 1 < ny; ++j) yMid[j] = (yLines[j] + yLines[j + 1]) / 2;

    for (std::size_t layerIndex = 0; layerIndex < layerCopperLoops.size(); ++layerIndex) {
        const _LayerLoops layer = _prepareLayerLoops(layerCopperLoops[layerIndex]);
        // xOwner[j * (nx - 1) + i] owns the X edge from line i to i + 1 on row j; yOwner[i * (ny - 1)
        // + j] the Y edge from line j to j + 1 on column i.
        std::vector<std::int32_t> xOwner(ny * (nx - 1), -1);
        std::vector<std::int32_t> yOwner(nx * (ny - 1), -1);
        // nodeOwner[j * nx + i]: the copper the node itself is on.
        std::vector<std::int32_t> nodeOwner(nx * ny, -1);
        for (std::size_t j = 0; j < ny; ++j) {
            _lineOwners(layer, 0, yLines[j], xMid, &xOwner[j * (nx - 1)]);
            _lineOwners(layer, 0, yLines[j], xLines, &nodeOwner[j * nx]);
        }
        for (std::size_t i = 0; i < nx; ++i) _lineOwners(layer, 1, xLines[i], yMid, &yOwner[i * (ny - 1)]);

        // A plated barrel connects to all the copper it overlaps on this layer -- its pad, the copper
        // round its drill -- so that copper and the barrel count as one; a barrel overlapping none
        // (passing an antipad) is a conductor of its own. Its centre and rim are sampled.
        std::vector<std::int32_t> alias(layer.loops->size() + barrels.size());
        for (std::size_t k = 0; k < alias.size(); ++k) alias[k] = static_cast<std::int32_t>(k);
        const auto find = [&](std::int32_t owner) {
            while (alias[static_cast<std::size_t>(owner)] != owner) owner = alias[static_cast<std::size_t>(owner)];
            return owner;
        };
        std::vector<std::int32_t> barrelOwner(nx * ny, -1);
        for (std::size_t b = 0; layerIndex < barrelLayers && b < barrels.size(); ++b) {
            const CopperBarrel& barrel = barrels[b];
            const auto owner = static_cast<std::int32_t>(layer.loops->size() + b);
            constexpr int kRimSamples = 16;
            for (int sample = -1; sample < 2 * kRimSamples; ++sample) {
                // Sample -1 is the first end's centre; then the rim round each end.
                const bool secondEnd = sample >= kRimSamples;
                const double angle = 2 * M_PI * (sample % kRimSamples) / kRimSamples;
                const double r = sample < 0 ? 0.0 : barrel.radius;
                const Position at((secondEnd ? barrel.x2 : barrel.x1) + r * std::cos(angle),
                                  (secondEnd ? barrel.y2 : barrel.y1) + r * std::sin(angle));
                const std::int32_t copper = _pointOwner(layer, at);
                if (copper >= 0) alias[static_cast<std::size_t>(find(copper))] = find(owner);
            }
            const auto range = [&](const std::vector<double>& lines, double a, double c) {
                const auto first = std::lower_bound(lines.begin(), lines.end(), std::min(a, c) - barrel.radius);
                const auto last = std::upper_bound(lines.begin(), lines.end(), std::max(a, c) + barrel.radius);
                return std::pair{static_cast<std::size_t>(first - lines.begin()),
                                 static_cast<std::size_t>(last - lines.begin())};
            };
            const auto [i0, i1] = range(xLines, barrel.x1, barrel.x2);
            const auto [j0, j1] = range(yLines, barrel.y1, barrel.y2);
            for (std::size_t j = j0; j < j1; ++j) {
                for (std::size_t i = i0; i < i1; ++i) {
                    const double distance = pointSegmentDistance(Position(xLines[i], yLines[j]),
                                                                 Position(barrel.x1, barrel.y1),
                                                                 Position(barrel.x2, barrel.y2));
                    if (distance <= barrel.radius) barrelOwner[j * nx + i] = owner;
                }
            }
        }

        for (std::size_t j = 0; j < ny; ++j) {
            for (std::size_t i = 0; i < nx; ++i) {
                const auto resolved = [&](std::int32_t owner) { return owner < 0 ? owner : find(owner); };
                const std::int32_t left = resolved(i > 0 ? xOwner[j * (nx - 1) + i - 1] : -1);
                const std::int32_t right = resolved(i + 1 < nx ? xOwner[j * (nx - 1) + i] : -1);
                const std::int32_t down = resolved(j > 0 ? yOwner[i * (ny - 1) + j - 1] : -1);
                const std::int32_t up = resolved(j + 1 < ny ? yOwner[i * (ny - 1) + j] : -1);
                const std::int32_t held = resolved(barrelOwner[j * nx + i]);
                std::int32_t first = -1;
                bool joined = false;
                for (const std::int32_t owner : {left, right, down, up, held}) {
                    if (owner < 0) continue;
                    if (first < 0) {
                        first = owner;
                    } else if (owner != first) {
                        joined = true;
                    }
                }
                if (!joined) continue;
                // Only the edges reaching copper other than the node's own (its barrel's, or what it
                // stands on) need shortening.
                const std::int32_t own = held >= 0 ? held : resolved(nodeOwner[j * nx + i]);
                const auto foreign = [&](std::int32_t owner) { return owner >= 0 && owner != own; };
                joins.push_back({layerIndex, i, j, foreign(left) || foreign(right), foreign(down) || foreign(up)});
            }
        }
    }
    return joins;
}

std::vector<grid_detail::CopperJoin> grid_detail::resolveCopperJoins(
    std::vector<double>& xLines, std::vector<double>& yLines, const std::vector<Cu::PolygonSet>& layerCopperLoops,
    const std::vector<CopperBarrel>& barrels, double minimumCell, std::size_t barrelLayers) {
    // Each pass halves every edge at a join, so copper g apart is separated within log2(cell / g)
    // passes; the cap only guards against copper closer than minimumCell, which stops shrinking.
    constexpr int kMaxPasses = 12;
    std::vector<CopperJoin> joins = copperJoins(xLines, yLines, layerCopperLoops, barrels, barrelLayers);
    for (int pass = 0; pass < kMaxPasses && !joins.empty(); ++pass) {
        std::array<std::vector<double>, 2> midpoints;
        for (const CopperJoin& join : joins) {
            for (std::size_t axis = 0; axis < 2; ++axis) {
                if (!(axis == 0 ? join.alongX : join.alongY)) continue;
                const std::vector<double>& lines = axis == 0 ? xLines : yLines;
                const std::size_t node = axis == 0 ? join.xIndex : join.yIndex;
                // Halve the node's edges on this axis, while both halves stay whole cells.
                for (std::size_t k = node > 0 ? node - 1 : node; k <= node && k + 1 < lines.size(); ++k) {
                    if (lines[k + 1] - lines[k] >= 2 * minimumCell) {
                        midpoints[axis].push_back(std::round((lines[k] + lines[k + 1]) / 2));
                    }
                }
            }
        }
        if (midpoints[0].empty() && midpoints[1].empty()) break;
        for (std::size_t axis = 0; axis < 2; ++axis) {
            std::vector<double>& lines = axis == 0 ? xLines : yLines;
            lines.insert(lines.end(), midpoints[axis].begin(), midpoints[axis].end());
            std::sort(lines.begin(), lines.end());
            lines.erase(std::unique(lines.begin(), lines.end()), lines.end());
        }
        joins = copperJoins(xLines, yLines, layerCopperLoops, barrels, barrelLayers);
    }
    return joins;
}

struct GridGenerator::Impl {
    Impl(const EMSConfig& config, double boardXMin, double boardYMin, double boardWidth, double boardHeight,
         const std::vector<std::vector<Position>>& boardCutout,
         const std::vector<Cu::PolygonSet>& layerCopperLoops)
        : x("x", Region(-config.grid().margin().xy(), boardWidth + config.grid().margin().xy()), config.grid(),
             boardXMin, boardXMin + boardWidth),
          y("y", Region(-config.grid().margin().xy(), boardHeight + config.grid().margin().xy()), config.grid(),
             boardYMin, boardYMin + boardHeight),
          xmin(boardXMin),
          xmax(boardXMin + boardWidth),
          ymin(boardYMin),
          ymax(boardYMin + boardHeight),
          _boardCutout(boardCutout),
          _layerCopperLoops(layerCopperLoops),
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
        zLines = grid_detail::growGridBoundaryCellsToSize(std::move(zLines), gridMax, cellRatio);
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
        // Appends Grid::absorbingBoundaryCells() brand-new, dedicated PML-only cells beyond each end --
        // exactly mirroring GridGeneratorAxis::compileGrid()'s own identical call for X/Y (a few
        // hundred lines up in this same file). Without this, Set_BC_PML()'s outermost-N-cells
        // classification (16 cells deep then) reclassified part of the *margin* band
        // above as PML -- and since that margin band is only ~8 cells deep in Z (unlike X/Y's own,
        // comfortably wider than 16), the other 8 cells of "PML" landed squarely inside the real
        // substrate stack, overwriting perfectly correct dielectric vv/vi coefficients with PML's
        // own absorbing-boundary ones in every substrate layer within 16 cells of either Z face --
        // every one of them except the thick middle layer, which was the entire pattern behind the
        // vi/vv "collapse" this was traced back from.
        zLines = grid_detail::appendUniformPMLCells(std::move(zLines), gridCfg.absorbingBoundaryCells());

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

    CSRectGrid& generate(CSRectGrid& grid, const SimulationConfig& simConfig, const libkicad::Board& board) {
        // The Boolean result from board slicing is the source of truth. In particular, do not reopen
        // the original board to derive ordinary density: even clipping those old hints afterward can
        // preserve line positions demanded only by copper that the hull cut removed.
        std::vector<TraceSegment> copperSegments = grid_detail::copperBoundarySegments(_layerCopperLoops);
        // A via's own circles -- its pad, the antipad round it, its drill -- need no lines of their
        // own: Copper models the barrel conformally wherever it falls, and _resolveCopperJoins()
        // keeps open every gap those circles bound. On HorizonPC they were over half the boundary
        // segments and about 8% of the cells.
        const std::size_t before = copperSegments.size();
        std::erase_if(copperSegments, [&](const TraceSegment& segment) {
            return grid_detail::isViaCircleSegment(segment, copperBarrels);
        });
        logInfo("### Grid Generator: " + std::to_string(before - copperSegments.size()) +
                " segment(s) on via-centred circles add no density ###");
        x.addLinesFromTrace(copperSegments);
        y.addLinesFromTrace(copperSegments);
        logInfo("### Grid Generator: density from " + std::to_string(copperSegments.size()) +
                " post-cut copper boundary segment(s) ###");

        // Synthetic ports and component bridges are created after board slicing, so add their own
        // contours explicitly. All real board pads are already represented in layerCopperLoops.
        const std::vector<NetName> syntheticPadNets = {NetName("PORT"), NetName("LUMPEDBRIDGE")};
        x.addLinesFromPads(addPads, syntheticPadNets, addApertures);
        y.addLinesFromPads(addPads, syntheticPadNets, addApertures);

        // Net identity is needed only for the differential-pair coupling-gap refinement. Build the
        // requested set first; simulations without differential pairs never reopen the source board
        // during grid generation at all.
        std::set<NetName> differentialNets;
        for (const InvolvedNetConfig& entry : simConfig.involvedNets()) {
            if (entry.kind() == NetSelectorKind::Net && entry.net().has_value() &&
                entry.simulateAsDifferentialPair() && entry.differentialPairPartner().has_value()) {
                differentialNets.emplace(*entry.net());
                differentialNets.emplace(*entry.differentialPairPartner());
            }
        }

        std::unordered_map<NetName, std::vector<TraceSegment>, NetNameHash> segmentsByNet;
        if (!differentialNets.empty()) {
            auto geometryResult = board.boardGeometry();
            auto allTracksResult = board.allTracks();
            if (!geometryResult || !allTracksResult) {
                logError(!geometryResult ? geometryResult.error() : allTracksResult.error());
                std::exit(1);
            }
            double originX = std::numeric_limits<double>::infinity();
            double originY = std::numeric_limits<double>::infinity();
            for (const libkicad::PolygonLoop& loop : geometryResult->outline) {
                for (const auto& [xMm, yMm] : loop.pointsMm) {
                    originX = std::min(originX, xMm / 1000.0 / constants::baseUnit * constants::unitMultiplier);
                    originY = std::min(originY, yMm / 1000.0 / constants::baseUnit * constants::unitMultiplier);
                }
            }
            if (!std::isfinite(originX) || !std::isfinite(originY)) {
                logError("KiCad board geometry has no usable Edge.Cuts points");
                std::exit(1);
            }
            constexpr double kPolygonToleranceSimUnits = 10.0;
            for (const auto& [rawNetName, track] : *allTracksResult) {
                const NetName net(rawNetName);
                if (!differentialNets.contains(net)) continue;
                const auto pointFromMm = [&](double xMm, double yMm) {
                    return Position(xMm / 1000.0 / constants::baseUnit * constants::unitMultiplier - originX,
                                    yMm / 1000.0 / constants::baseUnit * constants::unitMultiplier - originY);
                };
                const double width = track.widthMm / 1000.0 / constants::baseUnit * constants::unitMultiplier;
                auto pieces = grid_detail::clipTraceSegmentsToCutout(
                    {TraceSegment(pointFromMm(track.startXMm, track.startYMm),
                                  pointFromMm(track.endXMm, track.endYMm), "", width)},
                    _boardCutout, kPolygonToleranceSimUnits);
                auto& destination = segmentsByNet[net];
                destination.insert(destination.end(), pieces.begin(), pieces.end());
            }
        }

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
        _resolveCopperJoins(grid);

        const std::vector<std::int32_t> zLines = _generateZ();
        addGridLines(grid, "z", std::vector<double>(zLines.begin(), zLines.end()));

        return grid;
    }

    /// Refines the X and Y lines just compiled wherever Copper would join copper the board keeps
    /// apart (see grid_detail::resolveCopperJoins()), and warns about any join it can't remove.
    void _resolveCopperJoins(CSRectGrid& grid) {
        std::array<std::vector<double>, 2> lines;
        for (int axis = 0; axis < 2; ++axis) {
            unsigned int count = 0;
            double* raw = grid.GetLines(axis, nullptr, count, true);
            lines[static_cast<std::size_t>(axis)].assign(raw, raw + count);
            delete[] raw;
        }
        const std::size_t before = lines[0].size() + lines[1].size();
        const double cellRatio = _config.grid().cellRatio().xy();
        // The finest cell the ordinary passes leave between two protected copper edges (_dedupGrid()).
        const double minimumCell = _config.grid().optimal() / cellRatio / 4;
        std::vector<Cu::PolygonSet> sheets = _layerCopperLoops;
        sheets.insert(sheets.end(), offBoardSheets.begin(), offBoardSheets.end());
        const std::vector<grid_detail::CopperJoin> remaining = grid_detail::resolveCopperJoins(
            lines[0], lines[1], sheets, copperBarrels, minimumCell, _layerCopperLoops.size());
        const std::size_t added = lines[0].size() + lines[1].size() - before;
        if (added > 0) {
            clearGridLines(grid, "x");
            addGridLines(grid, "x", lines[0]);
            clearGridLines(grid, "y");
            addGridLines(grid, "y", lines[1]);
        }
        logInfo("Grid: " + std::to_string(added) + " line(s) added so separate copper stays apart");
        const auto mm = [](double simUnits) { return simUnits * constants::baseUnit / constants::unitMultiplier * 1e3; };
        constexpr std::size_t kReported = 20;
        for (std::size_t k = 0; k < std::min(remaining.size(), kReported); ++k) {
            const grid_detail::CopperJoin& join = remaining[k];
            const std::string where = join.layer < _layerCopperLoops.size()
                                          ? "copper on metal layer " + std::to_string(join.layer)
                                          : std::string("return-bridge metal");
            logWarning("Grid: " + where + " near (" +
                       std::to_string(mm(lines[0][join.xIndex])) + ", " + std::to_string(mm(lines[1][join.yIndex])) +
                       ") mm is closer than the finest cell allowed, so the grid joins it there");
        }
        if (remaining.size() > kReported) {
            logWarning("Grid: " + std::to_string(remaining.size() - kReported) + " more such join(s)");
        }
    }

    GridGeneratorAxis x;
    GridGeneratorAxis y;
    std::vector<Pad> addPads;
    std::unordered_map<std::string, Aperture> addApertures;
    std::vector<double> additionalZHeights;
    std::vector<grid_detail::CopperBarrel> copperBarrels;
    std::vector<Cu::PolygonSet> offBoardSheets;
    double xmin = 0;
    double xmax = 0;
    double ymin = 0;
    double ymax = 0;
    double _pmlInnerZMin = 0;
    double _pmlInnerZMax = 0;
    std::vector<std::vector<Position>> _boardCutout;
    const std::vector<Cu::PolygonSet>& _layerCopperLoops;
    const EMSConfig& _config;
};

GridGenerator::GridGenerator(const EMSConfig& config, double boardXMin, double boardYMin, double boardWidth,
                              double boardHeight, const std::vector<std::vector<Position>>& boardCutout,
                              const std::vector<Cu::PolygonSet>& layerCopperLoops)
    : _impl(std::make_unique<Impl>(config, boardXMin, boardYMin, boardWidth, boardHeight, boardCutout,
                                   layerCopperLoops)) {}
GridGenerator::~GridGenerator() = default;

std::vector<Pad>& GridGenerator::addPads() { return _impl->addPads; }
std::unordered_map<std::string, Aperture>& GridGenerator::addApertures() { return _impl->addApertures; }
std::vector<double>& GridGenerator::additionalZHeights() { return _impl->additionalZHeights; }
std::vector<grid_detail::CopperBarrel>& GridGenerator::copperBarrels() { return _impl->copperBarrels; }
std::vector<Cu::PolygonSet>& GridGenerator::offBoardSheets() { return _impl->offBoardSheets; }
double GridGenerator::xmin() const { return _impl->xmin; }
double GridGenerator::ymin() const { return _impl->ymin; }

double GridGenerator::pmlInnerXMin() const { return _impl->x.pmlInnerMin(); }
double GridGenerator::pmlInnerXMax() const { return _impl->x.pmlInnerMax(); }
double GridGenerator::pmlInnerYMin() const { return _impl->y.pmlInnerMin(); }
double GridGenerator::pmlInnerYMax() const { return _impl->y.pmlInnerMax(); }
double GridGenerator::pmlInnerZMin() const { return _impl->_pmlInnerZMin; }
double GridGenerator::pmlInnerZMax() const { return _impl->_pmlInnerZMax; }

CSRectGrid& GridGenerator::generate(CSRectGrid& grid, const SimulationConfig& simConfig, const libkicad::Board& board) {
    return _impl->generate(grid, simConfig, board);
}

} // namespace kiems
