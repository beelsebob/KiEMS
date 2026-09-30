#include "polygon_geometry.hpp"

#include <cmath>
#include <memory>
#include <numbers>
#include <stdexcept>

#include <geos_c.h>

#include "logging.hpp"

namespace Cu {
namespace {

struct GeosContext {
    GEOSContextHandle_t handle = GEOS_init_r();
    std::string error;

    GeosContext() {
        GEOSContext_setErrorMessageHandler_r(
            handle,
            [](const char* message, void* userData) {
                static_cast<GeosContext*>(userData)->error = message != nullptr ? message : "unknown GEOS error";
            },
            this);
    }
    ~GeosContext() { GEOS_finish_r(handle); }
};

thread_local GeosContext gGeos;

struct GeometryDeleter {
    void operator()(GEOSGeometry* geometry) const {
        if (geometry != nullptr) GEOSGeom_destroy_r(gGeos.handle, geometry);
    }
};
using GeometryPtr = std::unique_ptr<GEOSGeometry, GeometryDeleter>;

[[noreturn]] void throwGeos(const std::string& operation);

GeometryPtr makeValid(GeometryPtr geometry, const std::string& context) {
    if (!geometry) return {};
    const char valid = GEOSisValid_r(gGeos.handle, geometry.get());
    if (valid == 2) throwGeos("Checking " + context + " validity");
    if (valid == 1) return geometry;

    std::string reason = "invalid geometry";
    if (char* geosReason = GEOSisValidReason_r(gGeos.handle, geometry.get())) {
        reason = geosReason;
        GEOSFree_r(gGeos.handle, geosReason);
    }
    GeometryPtr repaired(GEOSMakeValid_r(gGeos.handle, geometry.get()));
    if (!repaired) throwGeos("Repairing " + context + " (" + reason + ")");
    const char repairedValid = GEOSisValid_r(gGeos.handle, repaired.get());
    if (repairedValid != 1) {
        if (repairedValid == 2) throwGeos("Checking repaired " + context + " validity");
        throw std::runtime_error("Repairing " + context + " did not produce valid geometry (" + reason + ")");
    }
    logDebug("GEOS repaired " + context + ": " + reason);
    return repaired;
}

struct BufferParamsDeleter {
    void operator()(GEOSBufferParams* params) const {
        if (params != nullptr) GEOSBufferParams_destroy_r(gGeos.handle, params);
    }
};
using BufferParamsPtr = std::unique_ptr<GEOSBufferParams, BufferParamsDeleter>;

[[noreturn]] void throwGeos(const std::string& operation) {
    const std::string detail = gGeos.error.empty() ? "unknown GEOS error" : gGeos.error;
    gGeos.error.clear();
    throw std::runtime_error(operation + ": " + detail);
}

GeometryPtr makeRing(const Polygon& input) {
    if (input.size() < 3) return {};
    const bool explicitlyClosed = input.front().x() == input.back().x() && input.front().y() == input.back().y();
    const std::size_t count = input.size() + (explicitlyClosed ? 0 : 1);
    GEOSCoordSequence* sequence = GEOSCoordSeq_create_r(gGeos.handle, static_cast<unsigned int>(count), 2);
    if (sequence == nullptr) throwGeos("Creating polygon coordinate sequence");
    for (std::size_t i = 0; i < input.size(); ++i) {
        if (!GEOSCoordSeq_setXY_r(gGeos.handle, sequence, static_cast<unsigned int>(i), input[i].x(), input[i].y())) {
            GEOSCoordSeq_destroy_r(gGeos.handle, sequence);
            throwGeos("Writing polygon coordinate sequence");
        }
    }
    if (!explicitlyClosed &&
        !GEOSCoordSeq_setXY_r(gGeos.handle, sequence, static_cast<unsigned int>(count - 1), input.front().x(),
                              input.front().y())) {
        GEOSCoordSeq_destroy_r(gGeos.handle, sequence);
        throwGeos("Closing polygon coordinate sequence");
    }
    GEOSGeometry* ring = GEOSGeom_createLinearRing_r(gGeos.handle, sequence);
    if (ring == nullptr) {
        GEOSCoordSeq_destroy_r(gGeos.handle, sequence);
        throwGeos("Creating polygon ring");
    }
    return GeometryPtr(ring);
}

bool pointInRing(const Position& p, const Polygon& ring) {
    bool inside = false;
    if (ring.size() < 3) return false;
    for (std::size_t i = 0, j = ring.size() - 1; i < ring.size(); j = i++) {
        const double xi = ring[i].x(), yi = ring[i].y();
        const double xj = ring[j].x(), yj = ring[j].y();
        if (((yi > p.y()) != (yj > p.y())) && p.x() < (xj - xi) * (p.y() - yi) / (yj - yi) + xi) inside = !inside;
    }
    return inside;
}

enum class GeometryInput {
    Raw,
    Composited,
};

GeometryPtr makeGeometry(const PolygonSet& loops, GeometryInput input = GeometryInput::Raw) {
    struct Shell {
        Polygon ring;
        std::vector<Polygon> holes;
    };
    std::vector<Shell> shells;
    std::vector<Polygon> holes;
    for (const Polygon& loop : loops) {
        if (loop.size() < 3) continue;
        const double loopArea = signedArea(loop);
        if (loopArea < -1e-12) {
            holes.push_back(loop);
        } else {
            // A self-crossing ring can have zero shoelace area while still enclosing copper.
            // Treat it as a shell so GEOSMakeValid gets a chance to recover its filled pieces.
            shells.push_back({loop, {}});
        }
    }
    // A lone clockwise input is still useful as a polygon; orientation is a convention, not a
    // reason to silently discard otherwise valid geometry.
    if (shells.empty() && !holes.empty()) {
        for (Polygon& hole : holes) {
            std::reverse(hole.begin(), hole.end());
            shells.push_back({std::move(hole), {}});
        }
        holes.clear();
    }
    for (Polygon& hole : holes) {
        const Position probe = hole.front();
        std::size_t best = shells.size();
        double bestArea = std::numeric_limits<double>::infinity();
        for (std::size_t i = 0; i < shells.size(); ++i) {
            const double shellArea = std::abs(signedArea(shells[i].ring));
            if (shellArea < bestArea && pointInRing(probe, shells[i].ring)) {
                best = i;
                bestArea = shellArea;
            }
        }
        if (best != shells.size()) {
            shells[best].holes.push_back(std::move(hole));
        } else {
            // Non-zero winding fills a standalone ring regardless of orientation.
            std::reverse(hole.begin(), hole.end());
            shells.push_back({std::move(hole), {}});
        }
    }

    std::vector<GEOSGeometry*> polygons;
    polygons.reserve(shells.size());
    for (const Shell& shellData : shells) {
        GeometryPtr shell = makeRing(shellData.ring);
        if (!shell) continue;
        std::vector<GEOSGeometry*> holeRings;
        for (const Polygon& hole : shellData.holes) {
            GeometryPtr ring = makeRing(hole);
            if (ring) holeRings.push_back(ring.release());
        }
        GEOSGeometry* polygon = GEOSGeom_createPolygon_r(gGeos.handle, shell.release(), holeRings.data(),
                                                         static_cast<unsigned int>(holeRings.size()));
        if (polygon == nullptr) {
            for (GEOSGeometry* ring : holeRings) GEOSGeom_destroy_r(gGeos.handle, ring);
            for (GEOSGeometry* made : polygons) GEOSGeom_destroy_r(gGeos.handle, made);
            throwGeos("Creating polygon");
        }
        GeometryPtr ownedPolygon(polygon);
        if (input == GeometryInput::Raw) ownedPolygon = makeValid(std::move(ownedPolygon), "input polygon");
        polygons.push_back(ownedPolygon.release());
    }
    if (polygons.empty()) {
        return GeometryPtr(GEOSGeom_createEmptyCollection_r(gGeos.handle, GEOS_GEOMETRYCOLLECTION));
    }
    if (polygons.size() == 1) return GeometryPtr(polygons.front());
    // Raw KiCad loops may overlap. A GeometryCollection is valid in that case, whereas an already
    // composited result can use the more specific MultiPolygon expected by downstream algorithms.
    const int collectionType =
        input == GeometryInput::Raw ? GEOS_GEOMETRYCOLLECTION : GEOS_MULTIPOLYGON;
    GEOSGeometry* collection = GEOSGeom_createCollection_r(gGeos.handle, collectionType, polygons.data(),
                                                            static_cast<unsigned int>(polygons.size()));
    if (collection == nullptr) {
        for (GEOSGeometry* made : polygons) GEOSGeom_destroy_r(gGeos.handle, made);
        throwGeos("Creating multipolygon");
    }
    return GeometryPtr(collection);
}

Polygon readRing(const GEOSGeometry* ring, bool positive) {
    const GEOSCoordSequence* sequence = GEOSGeom_getCoordSeq_r(gGeos.handle, ring);
    unsigned int size = 0;
    if (sequence == nullptr || !GEOSCoordSeq_getSize_r(gGeos.handle, sequence, &size)) throwGeos("Reading polygon ring");
    Polygon result;
    result.reserve(size > 0 ? size - 1 : 0);
    for (unsigned int i = 0; i < size; ++i) {
        double x = 0, y = 0;
        if (!GEOSCoordSeq_getXY_r(gGeos.handle, sequence, i, &x, &y)) throwGeos("Reading polygon coordinate");
        if (i + 1 == size && !result.empty() && x == result.front().x() && y == result.front().y()) break;
        result.emplace_back(x, y);
    }
    if (result.size() >= 3 && isPositive(result) != positive) std::reverse(result.begin(), result.end());
    return result;
}

void appendPolygon(const GEOSGeometry* polygon, PolygonSet& output) {
    const GEOSGeometry* shell = GEOSGetExteriorRing_r(gGeos.handle, polygon);
    if (shell == nullptr) return;
    output.push_back(readRing(shell, true));
    const int holeCount = GEOSGetNumInteriorRings_r(gGeos.handle, polygon);
    if (holeCount < 0) throwGeos("Reading polygon holes");
    for (int i = 0; i < holeCount; ++i) {
        output.push_back(readRing(GEOSGetInteriorRingN_r(gGeos.handle, polygon, i), false));
    }
}

PolygonSet readPolygonSet(const GEOSGeometry* geometry) {
    PolygonSet output;
    const int type = GEOSGeomTypeId_r(gGeos.handle, geometry);
    if (type == GEOS_POLYGON) {
        appendPolygon(geometry, output);
    } else if (type == GEOS_MULTIPOLYGON || type == GEOS_GEOMETRYCOLLECTION) {
        const int count = GEOSGetNumGeometries_r(gGeos.handle, geometry);
        if (count < 0) throwGeos("Reading geometry collection");
        for (int i = 0; i < count; ++i) {
            PolygonSet child = readPolygonSet(GEOSGetGeometryN_r(gGeos.handle, geometry, i));
            output.insert(output.end(), std::make_move_iterator(child.begin()), std::make_move_iterator(child.end()));
        }
    }
    return output;
}

PolygonSet booleanOperation(const PolygonSet& subject, const PolygonSet* clip, int operation) {
    // Empty operands are answered here rather than handed to GEOS: 3.15's collection overlay
    // asserts ("Unable to determine overlay result geometry dimension") when an empty operand
    // leaves it no dimension for the result -- e.g. a layer with no ground copper intersected
    // with the cutout. The answers are trivial anyway.
    if (subject.empty()) return {};
    if (clip != nullptr && clip->empty()) {
        if (operation == 0) return {};
        clip = nullptr; // Difference with nothing: just the subject's regularized union.
    }
    GeometryPtr a = makeValid(makeGeometry(subject), "Boolean subject");
    GeometryPtr result;
    if (clip == nullptr) {
        result.reset(GEOSUnaryUnion_r(gGeos.handle, a.get()));
    } else {
        GeometryPtr b = makeValid(makeGeometry(*clip), "Boolean clip");
        result.reset(operation == 0 ? GEOSIntersection_r(gGeos.handle, a.get(), b.get())
                                    : GEOSDifference_r(gGeos.handle, a.get(), b.get()));
    }
    if (!result) throwGeos("GEOS Boolean operation");
    return readPolygonSet(result.get());
}

PolygonSet compositedDifference(const PolygonSet& subject, const PolygonSet& clip) {
    if (subject.empty()) return {}; // See booleanOperation(): GEOS 3.15 asserts on empty overlay operands.
    GeometryPtr a = makeGeometry(subject, GeometryInput::Composited);
    GeometryPtr b = makeGeometry(clip, GeometryInput::Composited);
    GeometryPtr result(GEOSDifference_r(gGeos.handle, a.get(), b.get()));
    if (!result) throwGeos("GEOS composited difference");
    return readPolygonSet(result.get());
}

PolygonSet compositedUnion(const std::vector<PolygonSet>& operands) {
    std::vector<GEOSGeometry*> geometries;
    geometries.reserve(operands.size());
    for (const PolygonSet& operand : operands) {
        if (operand.empty()) continue;
        GeometryPtr geometry = makeGeometry(operand, GeometryInput::Composited);
        if (geometry) geometries.push_back(geometry.release());
    }
    if (geometries.empty()) return {};
    GeometryPtr collection(GEOSGeom_createCollection_r(gGeos.handle, GEOS_GEOMETRYCOLLECTION,
                                                        geometries.data(),
                                                        static_cast<unsigned int>(geometries.size())));
    if (!collection) {
        for (GEOSGeometry* geometry : geometries) GEOSGeom_destroy_r(gGeos.handle, geometry);
        throwGeos("Creating composited union collection");
    }
    GeometryPtr result(GEOSUnaryUnion_r(gGeos.handle, collection.get()));
    if (!result) throwGeos("GEOS composited union");
    return readPolygonSet(result.get());
}

std::vector<Triangle> triangulateGeometry(GeometryPtr geometry, double tessellationTolerance,
                                          const std::string& contextForErrors, bool normalize) {
    if (!geometry) return {};
    try {
        if (normalize) {
            GeometryPtr normalized(GEOSUnaryUnion_r(gGeos.handle, geometry.get()));
            if (!normalized) throwGeos("Normalizing polygons for triangulation");
            geometry = std::move(normalized);
        }
        GeometryPtr simplified(
            GEOSTopologyPreserveSimplify_r(gGeos.handle, geometry.get(), tessellationTolerance));
        if (!simplified) throwGeos("Simplifying polygons");
        GeometryPtr triangles(GEOSConstrainedDelaunayTriangulation_r(gGeos.handle, simplified.get()));
        if (!triangles) throwGeos("Constrained Delaunay triangulation");
        const PolygonSet loops = readPolygonSet(triangles.get());
        std::vector<Triangle> result;
        result.reserve(loops.size());
        for (const Polygon& loop : loops) {
            if (loop.size() == 3) result.push_back({loop[0], loop[1], loop[2]});
        }
        logDebug("Found " + std::to_string(result.size()) + " triangles for " + contextForErrors);
        return result;
    } catch (const std::exception& error) {
        logError("Triangulation failed for " + contextForErrors + ": " + error.what());
        return {};
    }
}

int quadrantSegments(double radius, double tolerance) {
    if (radius <= 0 || tolerance <= 0 || tolerance >= radius) return 8;
    const double angle = std::acos(std::clamp(1.0 - tolerance / radius, -1.0, 1.0));
    return std::max(1, static_cast<int>(std::ceil(std::numbers::pi / (4.0 * angle))));
}

PolygonSet bufferGeometry(const GEOSGeometry* geometry, double distance, double tolerance) {
    BufferParamsPtr params(GEOSBufferParams_create_r(gGeos.handle));
    if (!params) throwGeos("Creating buffer parameters");
    GEOSBufferParams_setJoinStyle_r(gGeos.handle, params.get(), GEOSBUF_JOIN_ROUND);
    GEOSBufferParams_setEndCapStyle_r(gGeos.handle, params.get(), GEOSBUF_CAP_ROUND);
    GEOSBufferParams_setQuadrantSegments_r(gGeos.handle, params.get(), quadrantSegments(std::abs(distance), tolerance));
    GeometryPtr buffered(GEOSBufferWithParams_r(gGeos.handle, geometry, params.get(), distance));
    if (!buffered) throwGeos("Buffering geometry");
    return readPolygonSet(buffered.get());
}

int crossSign(const Position& o, const Position& a, const Position& b) {
    const long double value = static_cast<long double>(a.x() - o.x()) * (b.y() - o.y()) -
                              static_cast<long double>(a.y() - o.y()) * (b.x() - o.x());
    return (value > 0) - (value < 0);
}

bool segmentsProperlyIntersect(const Position& a1, const Position& a2, const Position& b1, const Position& b2) {
    if ((a1.x() == b1.x() && a1.y() == b1.y()) || (a1.x() == b2.x() && a1.y() == b2.y()) ||
        (a2.x() == b1.x() && a2.y() == b1.y()) || (a2.x() == b2.x() && a2.y() == b2.y())) return false;
    return crossSign(a1, a2, b1) != crossSign(a1, a2, b2) && crossSign(b1, b2, a1) != crossSign(b1, b2, a2);
}

} // namespace

BoundingBox<double> bounds(const Polygon& path) {
    BoundingBox<double> box;
    for (const Position& point : path) {
        box.xMin = std::min(box.xMin, point.x());
        box.xMax = std::max(box.xMax, point.x());
        box.yMin = std::min(box.yMin, point.y());
        box.yMax = std::max(box.yMax, point.y());
    }
    return box;
}

double signedArea(const Polygon& path) {
    if (path.size() < 3) return 0;
    long double twiceArea = 0;
    for (std::size_t i = 0, j = path.size() - 1; i < path.size(); j = i++) {
        twiceArea += static_cast<long double>(path[j].x()) * path[i].y() -
                     static_cast<long double>(path[i].x()) * path[j].y();
    }
    return static_cast<double>(twiceArea / 2.0L);
}

double area(const PolygonSet& polygons) {
    double result = 0;
    for (const Polygon& polygon : polygons) result += signedArea(polygon);
    return result;
}

bool isPositive(const Polygon& path) { return signedArea(path) > 0; }

PolygonSet unionPolygons(const PolygonSet& subject) { return booleanOperation(subject, nullptr, 0); }
PolygonSet intersectPolygons(const PolygonSet& subject, const PolygonSet& clip) { return booleanOperation(subject, &clip, 0); }
PolygonSet differencePolygons(const PolygonSet& subject, const PolygonSet& clip) { return booleanOperation(subject, &clip, 1); }

PolygonSet unionCompositedPolygons(const std::vector<PolygonSet>& operands) {
    return compositedUnion(operands);
}

PolygonSet unionDisjointSubsets(const PolygonSet& subject) {
    GeometryPtr geometry = makeValid(makeGeometry(subject), "Disjoint-subset union subject");
    GeometryPtr result(GEOSDisjointSubsetUnion_r(gGeos.handle, geometry.get()));
    if (!result) throwGeos("GEOS disjoint-subset union");
    return readPolygonSet(result.get());
}

PolygonSet differenceCompositedPolygons(const PolygonSet& subject, const PolygonSet& clip) {
    return compositedDifference(subject, clip);
}

PolygonSet offsetPolygons(const PolygonSet& polygons, double distance, double arcTolerance) {
    GeometryPtr geometry = makeGeometry(polygons);
    return bufferGeometry(geometry.get(), distance, arcTolerance);
}

PolygonSet bufferOpenPaths(const PolygonSet& paths, double radius, double arcTolerance) {
    std::vector<GEOSGeometry*> pieces;
    for (const Polygon& path : paths) {
        if (path.empty()) continue;
        const bool point = path.size() == 1 ||
                           (path.size() == 2 && path[0].x() == path[1].x() && path[0].y() == path[1].y());
        const unsigned int count = point ? 1U : static_cast<unsigned int>(path.size());
        GEOSCoordSequence* sequence = GEOSCoordSeq_create_r(gGeos.handle, count, 2);
        if (!sequence) throwGeos("Creating path coordinate sequence");
        for (unsigned int i = 0; i < count; ++i) {
            GEOSCoordSeq_setXY_r(gGeos.handle, sequence, i, path[i].x(), path[i].y());
        }
        GEOSGeometry* piece = point ? GEOSGeom_createPoint_r(gGeos.handle, sequence)
                                    : GEOSGeom_createLineString_r(gGeos.handle, sequence);
        if (!piece) {
            GEOSCoordSeq_destroy_r(gGeos.handle, sequence);
            throwGeos("Creating path geometry");
        }
        pieces.push_back(piece);
    }
    if (pieces.empty()) return {};
    GeometryPtr collection(GEOSGeom_createCollection_r(gGeos.handle, GEOS_GEOMETRYCOLLECTION, pieces.data(),
                                                        static_cast<unsigned int>(pieces.size())));
    if (!collection) {
        for (GEOSGeometry* piece : pieces) GEOSGeom_destroy_r(gGeos.handle, piece);
        throwGeos("Creating path collection");
    }
    return bufferGeometry(collection.get(), radius, arcTolerance);
}

bool containsPoint(const PolygonSet& polygons, const Position& point) {
    GeometryPtr geometry = makeGeometry(polygons);
    GEOSCoordSequence* sequence = GEOSCoordSeq_create_r(gGeos.handle, 1, 2);
    GEOSCoordSeq_setXY_r(gGeos.handle, sequence, 0, point.x(), point.y());
    GeometryPtr p(GEOSGeom_createPoint_r(gGeos.handle, sequence));
    const char result = GEOSCovers_r(gGeos.handle, geometry.get(), p.get());
    if (result == 2) throwGeos("Testing point containment");
    return result == 1;
}

struct PointLocator::Impl {
    GeometryPtr geometry;
    // One prepared geometry per component. A point is covered by a collection exactly when some
    // component covers it, and preparing components individually keeps GEOS's indexed polygon
    // fast path even when the whole set is a GeometryCollection (which would only get the generic,
    // unindexed prepared implementation).
    std::vector<const GEOSPreparedGeometry*> prepared;
    ~Impl() {
        for (const GEOSPreparedGeometry* p : prepared) GEOSPreparedGeom_destroy_r(gGeos.handle, p);
    }
};

PointLocator::PointLocator(const PolygonSet& polygons) : _impl(std::make_unique<Impl>()) {
    _impl->geometry = makeGeometry(polygons);
    const int count = GEOSGetNumGeometries_r(gGeos.handle, _impl->geometry.get());
    if (count < 0) throwGeos("Counting geometry components");
    _impl->prepared.reserve(static_cast<std::size_t>(count));
    for (int i = 0; i < count; ++i) {
        const GEOSGeometry* component = GEOSGetGeometryN_r(gGeos.handle, _impl->geometry.get(), i);
        const GEOSPreparedGeometry* prepared = GEOSPrepare_r(gGeos.handle, component);
        if (prepared == nullptr) throwGeos("Preparing geometry for point queries");
        _impl->prepared.push_back(prepared);
    }
}

PointLocator::~PointLocator() = default;
PointLocator::PointLocator(PointLocator&&) noexcept = default;
PointLocator& PointLocator::operator=(PointLocator&&) noexcept = default;

bool PointLocator::contains(const Position& point) const {
    if (_impl->prepared.empty()) return false;
    GEOSCoordSequence* sequence = GEOSCoordSeq_create_r(gGeos.handle, 1, 2);
    GEOSCoordSeq_setXY_r(gGeos.handle, sequence, 0, point.x(), point.y());
    GeometryPtr p(GEOSGeom_createPoint_r(gGeos.handle, sequence));
    for (const GEOSPreparedGeometry* prepared : _impl->prepared) {
        const char result = GEOSPreparedCovers_r(gGeos.handle, prepared, p.get());
        if (result == 2) throwGeos("Testing point containment");
        if (result == 1) return true;
    }
    return false;
}

std::vector<Triangle> triangulate(const PolygonSet& composited, double tessellationTolerance,
                                  const std::string& contextForErrors) {
    if (composited.empty()) return {};
    try {
        return triangulateGeometry(makeGeometry(composited), tessellationTolerance, contextForErrors, true);
    } catch (const std::exception& error) {
        logError("Triangulation failed for " + contextForErrors + ": " + error.what());
        return {};
    }
}

std::vector<Triangle> triangulateComposited(const PolygonSet& composited, double tessellationTolerance,
                                            const std::string& contextForErrors) {
    if (composited.empty()) return {};
    try {
        return triangulateGeometry(makeGeometry(composited, GeometryInput::Composited), tessellationTolerance,
                                   contextForErrors, false);
    } catch (const std::exception& error) {
        logError("Composited triangulation failed for " + contextForErrors + ": " + error.what());
        return {};
    }
}

std::optional<std::pair<std::size_t, std::size_t>> findSelfIntersection(const Polygon& poly) {
    const std::size_t n = poly.size();
    if (n < 4) return std::nullopt;
    for (std::size_t i = 0; i < n; ++i) {
        for (std::size_t j = i + 1; j < n; ++j) {
            if ((j + 1) % n == i || (i + 1) % n == j) continue;
            if (segmentsProperlyIntersect(poly[i], poly[(i + 1) % n], poly[j], poly[(j + 1) % n])) {
                return std::make_pair(i, j);
            }
        }
    }
    return std::nullopt;
}

} // namespace Cu
