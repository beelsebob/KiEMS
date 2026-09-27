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
    result.xyClass.assign(static_cast<std::size_t>(result.nx) * result.ny, 0);
    for (std::uint32_t y = 0; y < result.ny; ++y) {
        const double py = yCoordinates[y];
        std::vector<std::vector<bool>> inside(boundaries.size(), std::vector<bool>(result.nx, false));
        for (std::size_t boundaryIndex = 0; boundaryIndex < boundaries.size(); ++boundaryIndex) {
            std::vector<int> winding(result.nx, 0);
            for (const Cu::Polygon& loop : boundaries[boundaryIndex]) {
                CopperOperator::PolygonRasterShape shape;
                shape.x.reserve(loop.size());
                shape.y.reserve(loop.size());
                for (const Cu::Position& p : loop) {
                    shape.x.push_back(p.x());
                    shape.y.push_back(p.y());
                }
                std::vector<bool> loopInside;
                CopperOperator::rasterizePolygonRow(shape, py, xCoordinates, loopInside);
                const int sign = Cu::isPositive(loop) ? 1 : -1;
                for (std::size_t x = 0; x < loopInside.size(); ++x) {
                    if (loopInside[x]) winding[x] += sign;
                }
            }
            for (std::size_t x = 0; x < winding.size(); ++x) inside[boundaryIndex][x] = winding[x] > 0;
        }
        for (std::uint32_t x = 0; x < result.nx; ++x) {
            std::uint8_t cls = 0;
            if (inside.front()[x]) {
                cls = 1;
            } else if (inside.back()[x]) {
                // Offset regions are nested. Find the first ring that contains this node instead
                // of doing a GEOS geometry rebuild/query for every node and every ring.
                std::uint32_t lo = 1, hi = pmlDepthCells;
                while (lo < hi) {
                    const std::uint32_t mid = lo + (hi - lo) / 2;
                    if (inside[mid][x]) hi = mid;
                    else lo = mid + 1;
                }
                cls = static_cast<std::uint8_t>(lo + 1);
            }
            result.xyClass[static_cast<std::size_t>(x) + static_cast<std::size_t>(result.nx) * y] = cls;
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
    return buildDomainMask(xCoordinates, yCoordinates, config, pmlDepthCells);
}

} // namespace copper
