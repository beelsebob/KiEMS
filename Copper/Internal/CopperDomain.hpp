#pragma once

#include <cstdint>
#include <vector>

#include "CopperYeeGrid.hpp"

namespace copper {

struct CopperFDTDPortConfig;
class CopperOperator;

// XY classification shared by both field updates and the irregular CPML builder. 0 is external,
// 1 is ordinary simulation space, and 2..(pmlDepth+1) are successive CPML rings from inside out.
// The mask is deliberately two-dimensional: the cut board is an XY extrusion, while the existing
// top/bottom CPML remains a conventional Z slab.
struct CopperDomainMask {
    enum class Region : std::uint8_t { Interior = 1, CPML = 2 };

    struct DispatchBox {
        std::uint32_t startX = 0, startY = 0;
        std::uint32_t width = 0, height = 0;
        Region region = Region::Interior;
    };
    std::uint32_t nx = 0;
    std::uint32_t ny = 0;
    std::uint32_t pmlDepth = 0;
    std::vector<std::uint8_t> xyClass;
    /// Non-overlapping, class-pure rectangles covering every non-external node exactly once. A
    /// rectangle is entirely Interior or entirely CPML; external nodes are in no rectangle. Metal
    /// can therefore dispatch these cuboids without uploading/checking a per-node mask.
    std::vector<DispatchBox> dispatchBoxes;

    bool empty() const { return xyClass.empty(); }
    std::uint8_t at(std::uint32_t x, std::uint32_t y) const {
        return xyClass[static_cast<std::size_t>(x) + static_cast<std::size_t>(nx) * y];
    }
};

CopperDomainMask buildDomainMask(const CopperOperator& op, const CopperFDTDPortConfig& config,
                                 std::uint32_t pmlDepthCells);

/// Coordinate-only form used by diagnostics/previews that already have the final grid lines but
/// deliberately do not construct CopperOperator's material/coefficient machinery. This is the
/// authoritative classifier too: the operator overload above only extracts its X/Y lines and
/// delegates here, so the geometry view and the solver cannot drift into showing different domain
/// boundaries.
CopperDomainMask buildDomainMask(const std::vector<double>& xCoordinates,
                                 const std::vector<double>& yCoordinates,
                                 const CopperFDTDPortConfig& config,
                                 std::uint32_t pmlDepthCells);

} // namespace copper
