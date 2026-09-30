#pragma once

#include <array>
#include <cstdint>
#include <vector>

#include "CopperYeeGrid.hpp"

namespace copper {

struct CopperFDTDPortConfig;
class CopperOperator;

// XY classification shared by both field updates and the irregular-domain absorber. 0 is
// external, 1 is ordinary simulation space, and 2..(pmlDepth+1) are successive absorbing rings
// from inside out. The mask is deliberately two-dimensional: the cut board is an XY extrusion,
// while the existing top/bottom CPML remains a conventional Z slab.
//
// The rings are *not* a CPML -- see applyRingAbsorber() (CopperCPML.hpp) for why no
// stretched-coordinate PML can follow an irregular outline stably; they are an isotropic,
// impedance-matched lossy layer folded straight into the Yee coefficients.
struct CopperDomainMask {
    enum class Region : std::uint8_t { Interior = 1, CPML = 2 };

    struct DispatchBox {
        std::uint32_t startX = 0, startY = 0;
        std::uint32_t width = 0, height = 0;
        Region region = Region::Interior;
    };

    /// The four XY positions a Yee component can occupy relative to its node (x,y): the node itself
    /// (Ez), half a cell along x (Ex, Hy), half a cell along y (Ey, Hx), and both (Hz).
    enum StaggeredPosition : std::uint8_t { Node = 0, HalfX = 1, HalfY = 2, HalfXY = 3 };

    std::uint32_t nx = 0;
    std::uint32_t ny = 0;
    std::uint32_t pmlDepth = 0;
    std::vector<std::uint8_t> xyClass;
    /// Non-overlapping, class-pure rectangles covering every non-external node exactly once. A
    /// rectangle is entirely Interior or entirely CPML; external nodes are in no rectangle. Metal
    /// can therefore dispatch these cuboids without uploading/checking a per-node mask.
    std::vector<DispatchBox> dispatchBoxes;
    /// Absorbing-ring layer (0 = none, 1..pmlDepth from inside out; a point beyond the outermost
    /// ring reads pmlDepth) sampled at each StaggeredPosition, indexed like xyClass. The absorber's
    /// conductivity must be sampled where each component actually lives: giving every component of
    /// a node its node's value shifts the H-side profile half a cell against the E-side one, which
    /// mismatches the layer's impedance at every step of the grading.
    std::array<std::vector<std::uint8_t>, 4> staggeredLayer;
    /// Physical thickness of one ring layer in metres. Only the CopperOperator overload of
    /// buildDomainMask() knows the drawing unit, so a coordinate-only (preview) mask leaves this 0
    /// and applyRingAbsorber() treats it as "no absorber".
    double ringLayerMetres = 0.0;

    bool empty() const { return xyClass.empty(); }
    std::uint8_t at(std::uint32_t x, std::uint32_t y) const {
        return xyClass[static_cast<std::size_t>(x) + static_cast<std::size_t>(nx) * y];
    }
    std::uint8_t layerAt(StaggeredPosition position, std::uint32_t x, std::uint32_t y) const {
        return staggeredLayer[position][static_cast<std::size_t>(x) + static_cast<std::size_t>(nx) * y];
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
