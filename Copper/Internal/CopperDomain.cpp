#include "CopperDomain.hpp"

#include <algorithm>

#include "../CopperFDTDRunner.h"
#include "CopperOperator.hpp"
#include "polygon_geometry.hpp"

namespace copper {

CopperDomainMask buildDomainMask(const std::vector<double>& xCoordinates,
                                 const std::vector<double>& yCoordinates,
                                 const CopperFDTDPortConfig& config,
                                 std::uint32_t pmlDepthCells) {
    CopperDomainMask result;
    if (config.domainCutoutLoops.empty() || config.domainCPMLCellSize <= 0.0 || pmlDepthCells == 0) {
        return result;
    }

    Cu::PolygonSet cutout;
    cutout.reserve(config.domainCutoutLoops.size());
    for (const auto& inputLoop : config.domainCutoutLoops) {
        Cu::Polygon loop;
        loop.reserve(inputLoop.size());
        for (const auto& point : inputLoop) loop.emplace_back(point.x, point.y);
        if (loop.size() >= 3) cutout.push_back(std::move(loop));
    }
    if (cutout.empty()) return result;

    const double arcTolerance = std::max(1.0, config.domainCPMLCellSize / 16.0);
    std::vector<Cu::PolygonSet> boundaries;
    boundaries.reserve(static_cast<std::size_t>(pmlDepthCells) + 1);
    for (std::uint32_t layer = 0; layer <= pmlDepthCells; ++layer) {
        boundaries.push_back(Cu::offsetPolygons(
            cutout, config.domainPadding + static_cast<double>(layer) * config.domainCPMLCellSize, arcTolerance));
    }

    result.nx = static_cast<std::uint32_t>(xCoordinates.size());
    result.ny = static_cast<std::uint32_t>(yCoordinates.size());
    result.pmlDepth = pmlDepthCells;
    const std::size_t nodeCount = static_cast<std::size_t>(result.nx) * result.ny;
    result.xyClass.assign(nodeCount, 0);
    for (auto& layer : result.staggeredLayer) layer.assign(nodeCount, 0);

    // Each offset loop's raster shape is row-independent, so build it once rather than per row.
    struct RasterLoop {
        CopperOperator::PolygonRasterShape shape;
        int sign = 1;
    };
    std::vector<std::vector<RasterLoop>> rasterBoundaries(boundaries.size());
    for (std::size_t boundaryIndex = 0; boundaryIndex < boundaries.size(); ++boundaryIndex) {
        for (const Cu::Polygon& loop : boundaries[boundaryIndex]) {
            RasterLoop rasterLoop;
            rasterLoop.shape.x.reserve(loop.size());
            rasterLoop.shape.y.reserve(loop.size());
            for (const Cu::Position& p : loop) {
                rasterLoop.shape.x.push_back(p.x());
                rasterLoop.shape.y.push_back(p.y());
            }
            rasterLoop.sign = Cu::isPositive(loop) ? 1 : -1;
            rasterBoundaries[boundaryIndex].push_back(std::move(rasterLoop));
        }
    }

    // Classifies every point (columns[i], py) the same way xyClass does: 0 outside every offset,
    // 1 inside the padded cutout, 2..pmlDepth+1 in ring 1..pmlDepth.
    std::vector<std::vector<bool>> inside(boundaries.size());
    std::vector<int> winding;
    std::vector<bool> loopInside;
    auto classifyRow = [&](double py, const std::vector<double>& columns, std::vector<std::uint8_t>& classes) {
        for (std::size_t boundaryIndex = 0; boundaryIndex < boundaries.size(); ++boundaryIndex) {
            winding.assign(columns.size(), 0);
            for (const RasterLoop& loop : rasterBoundaries[boundaryIndex]) {
                CopperOperator::rasterizePolygonRow(loop.shape, py, columns, loopInside);
                for (std::size_t i = 0; i < loopInside.size(); ++i) {
                    if (loopInside[i]) winding[i] += loop.sign;
                }
            }
            inside[boundaryIndex].assign(columns.size(), false);
            for (std::size_t i = 0; i < winding.size(); ++i) inside[boundaryIndex][i] = winding[i] > 0;
        }
        classes.assign(columns.size(), 0);
        for (std::size_t i = 0; i < columns.size(); ++i) {
            if (inside.front()[i]) {
                classes[i] = 1;
            } else if (inside.back()[i]) {
                // Offset regions are nested. Find the first ring that contains this point instead
                // of doing a GEOS geometry rebuild/query for every point and every ring.
                std::uint32_t lo = 1, hi = pmlDepthCells;
                while (lo < hi) {
                    const std::uint32_t mid = lo + (hi - lo) / 2;
                    if (inside[mid][i]) hi = mid;
                    else lo = mid + 1;
                }
                classes[i] = static_cast<std::uint8_t>(lo + 1);
            }
        }
    };
    // Ring layer of a staggered sample: none inside the padded cutout, the outermost ring beyond it.
    auto staggeredLayerOf = [pmlDepthCells](std::uint8_t cls) -> std::uint8_t {
        if (cls == 0) return static_cast<std::uint8_t>(pmlDepthCells);
        return static_cast<std::uint8_t>(cls - 1);
    };

    // Half-cell sample positions, extrapolating half the last cell past the final line exactly like
    // CopperOperator::discLine(..., dualMesh=true) does.
    auto halfLines = [](const std::vector<double>& lines) {
        std::vector<double> half(lines.size());
        for (std::size_t i = 0; i < lines.size(); ++i) {
            if (i + 1 < lines.size()) half[i] = 0.5 * (lines[i] + lines[i + 1]);
            else half[i] = lines[i] + (i > 0 ? 0.5 * (lines[i] - lines[i - 1]) : 0.0);
        }
        return half;
    };
    const std::vector<double> xHalf = halfLines(xCoordinates);
    const std::vector<double> yHalf = halfLines(yCoordinates);
    // Node and half-x columns interleaved (x0, x0+1/2, x1, ...): still ascending, so one rasterizer
    // pass per row classifies both.
    std::vector<double> interleavedColumns(2 * static_cast<std::size_t>(result.nx));
    for (std::uint32_t x = 0; x < result.nx; ++x) {
        interleavedColumns[2 * static_cast<std::size_t>(x)] = xCoordinates[x];
        interleavedColumns[2 * static_cast<std::size_t>(x) + 1] = xHalf[x];
    }

    std::vector<std::uint8_t> nodeRow, halfRow;
    for (std::uint32_t y = 0; y < result.ny; ++y) {
        classifyRow(yCoordinates[y], interleavedColumns, nodeRow);
        classifyRow(yHalf[y], interleavedColumns, halfRow);
        for (std::uint32_t x = 0; x < result.nx; ++x) {
            const std::size_t i = static_cast<std::size_t>(x) + static_cast<std::size_t>(result.nx) * y;
            const std::size_t c = 2 * static_cast<std::size_t>(x);
            result.xyClass[i] = nodeRow[c];
            result.staggeredLayer[CopperDomainMask::Node][i] = staggeredLayerOf(nodeRow[c]);
            result.staggeredLayer[CopperDomainMask::HalfX][i] = staggeredLayerOf(nodeRow[c + 1]);
            result.staggeredLayer[CopperDomainMask::HalfY][i] = staggeredLayerOf(halfRow[c]);
            result.staggeredLayer[CopperDomainMask::HalfXY][i] = staggeredLayerOf(halfRow[c + 1]);
        }
    }

    // Turn the rasterized boundary into maximal vertical merges of identical horizontal runs.
    // Interior and CPML are decomposed separately: every resulting rectangle is homogeneous, and
    // external cells never appear in a dispatch at all. This deliberately regularizes at the Yee
    // grid's own cell resolution rather than using a coarser tile cover whose boundary tiles would
    // mix cell kinds and require a branch in every shader invocation.
    auto appendRectangles = [&](CopperDomainMask::Region region) {
        const auto wanted = [region](std::uint8_t cls) {
            return region == CopperDomainMask::Region::Interior ? cls == 1 : cls >= 2;
        };
        std::vector<CopperDomainMask::DispatchBox> open;
        for (std::uint32_t y = 0; y < result.ny; ++y) {
            std::vector<CopperDomainMask::DispatchBox> runs;
            for (std::uint32_t x = 0; x < result.nx;) {
                while (x < result.nx && !wanted(result.at(x, y))) ++x;
                const std::uint32_t start = x;
                while (x < result.nx && wanted(result.at(x, y))) ++x;
                if (x > start) runs.push_back({start, y, x - start, 1, region});
            }
            std::vector<CopperDomainMask::DispatchBox> next;
            for (const auto& run : runs) {
                auto it = std::find_if(open.begin(), open.end(), [&](const auto& box) {
                    return box.startX == run.startX && box.width == run.width &&
                           box.startY + box.height == y;
                });
                if (it == open.end()) {
                    next.push_back(run);
                } else {
                    auto extended = *it;
                    extended.height += 1;
                    next.push_back(extended);
                    open.erase(it);
                }
            }
            result.dispatchBoxes.insert(result.dispatchBoxes.end(), open.begin(), open.end());
            open = std::move(next);
        }
        result.dispatchBoxes.insert(result.dispatchBoxes.end(), open.begin(), open.end());
    };
    appendRectangles(CopperDomainMask::Region::Interior);
    appendRectangles(CopperDomainMask::Region::CPML);
    return result;
}

CopperDomainMask buildDomainMask(const CopperOperator& op, const CopperFDTDPortConfig& config,
                                 std::uint32_t pmlDepthCells) {
    std::vector<double> xCoordinates(op.numberOfLines(0));
    std::vector<double> yCoordinates(op.numberOfLines(1));
    for (std::size_t x = 0; x < xCoordinates.size(); ++x)
        xCoordinates[x] = op.discLine(0, static_cast<unsigned int>(x));
    for (std::size_t y = 0; y < yCoordinates.size(); ++y)
        yCoordinates[y] = op.discLine(1, static_cast<unsigned int>(y));
    CopperDomainMask mask = buildDomainMask(xCoordinates, yCoordinates, config, pmlDepthCells);
    if (!mask.empty()) mask.ringLayerMetres = config.domainCPMLCellSize * op.gridDeltaMetres();
    return mask;
}

} // namespace copper
