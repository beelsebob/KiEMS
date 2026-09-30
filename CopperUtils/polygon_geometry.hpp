// Double-precision polygon operations shared by board slicing, simulation geometry, and tests.
// GEOS is deliberately hidden behind these project-owned types so geometry-library details do not
// leak through the rest of KiEMS.
#pragma once

#include <algorithm>
#include <limits>
#include <memory>
#include <optional>
#include <string>
#include <utility>
#include <vector>

#include <nlohmann/json.hpp>

#include "geometry.hpp"

namespace Cu {

using Polygon = std::vector<Position>;
using PolygonSet = std::vector<Polygon>;

namespace _detail {

template <typename T>
constexpr T _positiveBoundsSentinel() {
    if constexpr (std::numeric_limits<T>::has_infinity) return std::numeric_limits<T>::infinity();
    return std::numeric_limits<T>::max();
}

template <typename T>
constexpr T _negativeBoundsSentinel() {
    if constexpr (std::numeric_limits<T>::has_infinity) return -std::numeric_limits<T>::infinity();
    return std::numeric_limits<T>::lowest();
}

} // namespace _detail

template <typename T>
struct BoundingBox {
    T xMin = _detail::_positiveBoundsSentinel<T>();
    T xMax = _detail::_negativeBoundsSentinel<T>();
    T yMin = _detail::_positiveBoundsSentinel<T>();
    T yMax = _detail::_negativeBoundsSentinel<T>();

    BoundingBox() = default;

    template <typename U>
        requires requires(U value) { static_cast<T>(value); }
    explicit BoundingBox(const BoundingBox<U>& other)
        : xMin(static_cast<T>(other.xMin)), xMax(static_cast<T>(other.xMax)), yMin(static_cast<T>(other.yMin)),
          yMax(static_cast<T>(other.yMax)) {}
};

template <typename T>
void to_json(nlohmann::json& j, const BoundingBox<T>& b) {
    j = nlohmann::json{{"xMin", b.xMin}, {"xMax", b.xMax}, {"yMin", b.yMin}, {"yMax", b.yMax}};
}

template <typename T>
void from_json(const nlohmann::json& j, BoundingBox<T>& b) {
    j.at("xMin").get_to(b.xMin);
    j.at("xMax").get_to(b.xMax);
    j.at("yMin").get_to(b.yMin);
    j.at("yMax").get_to(b.yMax);
}

template <typename T>
std::string to_string(const BoundingBox<T>& b) {
    return "[" + std::to_string(b.xMin) + "," + std::to_string(b.xMax) + "] x [" + std::to_string(b.yMin) + "," +
           std::to_string(b.yMax) + "] (" + std::to_string(b.xMax - b.xMin) + "x" +
           std::to_string(b.yMax - b.yMin) + ")";
}

BoundingBox<double> bounds(const Polygon& path);
double signedArea(const Polygon& path);
double area(const PolygonSet& polygons);
bool isPositive(const Polygon& path);

/// Regularized Boolean operations. Output loops are normalized to counter-clockwise outer rings
/// and clockwise holes, including nested islands.
PolygonSet unionPolygons(const PolygonSet& subject);
PolygonSet intersectPolygons(const PolygonSet& subject, const PolygonSet& clip);
PolygonSet differencePolygons(const PolygonSet& subject, const PolygonSet& clip);

/// Union of operands that have each already been composited independently. Keeping operands
/// separate while reconstructing their GEOS polygons preserves every operand's own shell/hole
/// relationships, even when two operands contain coincident shells (for example when a net is
/// selected both as geometry-only copper and as ground copper).
PolygonSet unionCompositedPolygons(const std::vector<PolygonSet>& operands);

/// Exact union optimized for inputs made up of many disconnected clusters. Unlike a coverage
/// union, members within a cluster may overlap arbitrarily.
PolygonSet unionDisjointSubsets(const PolygonSet& subject);

/// Difference for inputs already returned by one of the regularized Boolean/buffer operations (or
/// otherwise known to be valid and non-overlapping). Skips the repeated per-polygon and collection
/// validity checks performed by differencePolygons().
PolygonSet differenceCompositedPolygons(const PolygonSet& subject, const PolygonSet& clip);

/// Round-join polygon offset and round-cap open-path buffer. `arcTolerance` is the maximum sagitta
/// error in the same coordinate units as the input.
PolygonSet offsetPolygons(const PolygonSet& polygons, double distance, double arcTolerance);
PolygonSet bufferOpenPaths(const PolygonSet& paths, double radius, double arcTolerance);

/// True for points in filled areas, false for points in holes or outside all components.
/// Rebuilds (and validates) the whole geometry on every call -- use PointLocator for more than a
/// handful of queries against the same polygon set.
bool containsPoint(const PolygonSet& polygons, const Position& point);

/// Repeated containsPoint() queries against one polygon set, with identical answers: the geometry
/// is built once and each component is prepared (indexed) for point queries. Must be created,
/// queried, and destroyed on one thread -- the underlying GEOS context is thread-local.
class PointLocator {
public:
    explicit PointLocator(const PolygonSet& polygons);
    ~PointLocator();
    PointLocator(PointLocator&&) noexcept;
    PointLocator& operator=(PointLocator&&) noexcept;
    PointLocator(const PointLocator&) = delete;
    PointLocator& operator=(const PointLocator&) = delete;

    bool contains(const Position& point) const;

private:
    struct Impl;
    std::unique_ptr<Impl> _impl;
};

/// Constrained Delaunay triangulation of an already-composited polygon set. GEOS preserves every
/// exterior and hole boundary; simplification is topology-preserving.
std::vector<Triangle> triangulate(const PolygonSet& composited, double tessellationTolerance,
                                  const std::string& contextForErrors);

/// Faster form for a valid, already-composited polygon set. In particular, this does not run a
/// second unary union before simplifying and triangulating it.
std::vector<Triangle> triangulateComposited(const PolygonSet& composited, double tessellationTolerance,
                                            const std::string& contextForErrors);

std::optional<std::pair<std::size_t, std::size_t>> findSelfIntersection(const Polygon& poly);

} // namespace Cu
