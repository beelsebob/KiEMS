#include "simulation.hpp"

#include <algorithm>
#include <array>
#include <cerrno>
#include <chrono>
#include <cmath>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <limits>
#include <map>
#include <sstream>

#include <spawn.h>
#include <sys/wait.h>

#include <clipper2/clipper.h>
#include <nlohmann/json.hpp>

#include "constants.hpp"
#include "csx_grid_utils.hpp"
#include "gerber_composite.hpp"
#include "logging.hpp"

extern char** environ;

namespace gerber2ems {

namespace {

std::string _point3ToString(const Point3& p) {
    return "[" + std::to_string(p[0]) + ", " + std::to_string(p[1]) + ", " + std::to_string(p[2]) + "]";
}

// Standard ray-casting point-in-polygon test against a simple closed loop.
bool _pointInPolygon(double x, double y, const std::vector<Position>& polygon) {
    bool inside = false;
    for (std::size_t i = 0, j = polygon.size() - 1; i < polygon.size(); j = i++) {
        const Position& pi = polygon[i];
        const Position& pj = polygon[j];
        const bool crosses = (pi.y() > y) != (pj.y() > y);
        if (crosses) {
            const double xIntersect = pj.x() + (y - pj.y()) * (pi.x() - pj.x()) / (pi.y() - pj.y());
            if (x < xIntersect) {
                inside = !inside;
            }
        }
    }
    return inside;
}

// Shortest distance from (x, y) to the polyline formed by `polygon`'s edges (treated as a closed
// loop) -- same algorithm as board_slicing.cpp's file-local _distancePointToPolyline, just against
// Position rather than Clipper2Lib::Point64 (this file never touches Clipper2 types directly).
double _distanceToPolygonBoundary(double x, double y, const std::vector<Position>& polygon) {
    double best = std::numeric_limits<double>::infinity();
    for (std::size_t i = 0, j = polygon.size() - 1; i < polygon.size(); j = i++) {
        const Position& a = polygon[j];
        const Position& b = polygon[i];
        const double abx = b.x() - a.x();
        const double aby = b.y() - a.y();
        const double lenSq = abx * abx + aby * aby;
        double t = 0;
        if (lenSq > 0) {
            t = ((x - a.x()) * abx + (y - a.y()) * aby) / lenSq;
            t = std::clamp(t, 0.0, 1.0);
        }
        const double px = a.x() + t * abx;
        const double py = a.y() + t * aby;
        best = std::min(best, std::hypot(x - px, y - py));
    }
    return best;
}

// A via whose *center* has been sliced away can still have real copper overlapping the sliced
// outline (its pad straddling the cutout boundary) -- checking only the center point (as this used
// to) silently dropped any such via, which is real copper the board-slicing cutout genuinely
// intersects. A via counts as kept if its center is inside the outline, or its disc (center +
// radius) reaches the outline boundary.
bool _viaIntersectsOutline(double x, double y, double diameter, const std::vector<Position>& outline) {
    if (_pointInPolygon(x, y, outline)) {
        return true;
    }
    return _distanceToPolygonBoundary(x, y, outline) <= diameter / 2;
}

std::string _normalizeLayerName(std::string name) {
    for (char& c : name) {
        if (c == '.' || c == '(' || c == ')' || c == ' ' || c == '/') {
            c = '_';
        }
    }
    return name;
}

/// One via's cross-section boundary, tessellated the same way a plain round via's already was
/// (constants::viaPolygon segments total): a plain circle when (x1, y1) and (x2, y2) coincide (the
/// overwhelmingly common case -- a round drilled via), or a stadium/capsule shape between the two
/// points otherwise (an elongated through-hole, e.g. a connector's oblong SHIELD pad -- see
/// ViaHole's own doc comment). `reversed` matches the two existing call sites' own opposite winding
/// conventions (filling vs. outer ring) -- preserved from the original circular-only
/// implementation rather than re-derived, since the reason for it isn't documented anywhere in this
/// codebase's history, and getting it wrong would be a silent, hard-to-notice regression rather
/// than a build failure.
std::pair<std::vector<double>, std::vector<double>> _viaPolygon(double x1, double y1, double x2, double y2,
                                                                    double diameter, bool reversed) {
    const double radius = diameter / 2;
    std::vector<double> xs;
    std::vector<double> ys;

    if (x1 == x2 && y1 == y2) {
        for (std::int32_t step = 0; step < constants::viaPolygon; ++step) {
            const std::int32_t i = reversed ? constants::viaPolygon - 1 - step : step;
            const double angle = static_cast<double>(i) / constants::viaPolygon * 2 * M_PI;
            xs.push_back(x1 + std::sin(angle) * radius);
            ys.push_back(y1 + std::cos(angle) * radius);
        }
        return {xs, ys};
    }

    const double lineAngle = std::atan2(y2 - y1, x2 - x1);
    const std::int32_t halfSegments = std::max(std::int32_t{1}, constants::viaPolygon / 2);
    // halfSegments *points* spanning a pi-radian sweep means halfSegments-1 *steps* -- dividing by
    // halfSegments instead undershoots the far endpoint by one step's worth of angle, leaving each
    // semicircle looking like it doesn't quite reach 180 degrees.
    const std::int32_t angleDenominator = std::max(std::int32_t{1}, halfSegments - 1);
    // Semicircle around (x2, y2) covering its far side (away from (x1, y1)), then one around
    // (x1, y1) covering its own far side -- the two straight sides connecting them are implicit,
    // the same way the plain-circle case above never explicitly closes its own loop (CSXCAD's
    // polygon primitives connect the last point back to the first).
    for (std::int32_t i = 0; i < halfSegments; ++i) {
        const double a = lineAngle - M_PI / 2 + M_PI * static_cast<double>(i) / angleDenominator;
        xs.push_back(x2 + std::cos(a) * radius);
        ys.push_back(y2 + std::sin(a) * radius);
    }
    for (std::int32_t i = 0; i < halfSegments; ++i) {
        const double a = lineAngle + M_PI / 2 + M_PI * static_cast<double>(i) / angleDenominator;
        xs.push_back(x1 + std::cos(a) * radius);
        ys.push_back(y1 + std::sin(a) * radius);
    }
    if (reversed) {
        std::reverse(xs.begin(), xs.end());
        std::reverse(ys.begin(), ys.end());
    }
    return {xs, ys};
}

Clipper2Lib::Path64 _xyToPath64(const std::vector<double>& xs, const std::vector<double>& ys) {
    Clipper2Lib::Path64 path;
    path.reserve(xs.size());
    for (std::size_t i = 0; i < xs.size(); ++i) {
        path.emplace_back(static_cast<std::int64_t>(std::llround(xs[i])), static_cast<std::int64_t>(std::llround(ys[i])));
    }
    return path;
}

std::pair<std::vector<double>, std::vector<double>> _path64ToXY(const Clipper2Lib::Path64& path) {
    std::vector<double> xs;
    std::vector<double> ys;
    xs.reserve(path.size());
    ys.reserve(path.size());
    for (const auto& pt : path) {
        xs.push_back(static_cast<double>(pt.x));
        ys.push_back(static_cast<double>(pt.y));
    }
    return {xs, ys};
}

/// Clips a via cross-section polygon (xs/ys, as produced by _viaPolygon) to the sliced board's own
/// outline via Clipper2 intersection -- a real via kept because its disc merely *reaches* the cutout
/// boundary (see _viaIntersectsOutline's own doc comment) would otherwise be added at its full,
/// uncropped geometric extent, sticking out past the simulation's own domain past the hull-padding
/// trim line. Usually a single loop; can (rarely) come back as more than one if the outline's own
/// boundary is concave enough to split the via's disc into disjoint pieces.
std::vector<std::pair<std::vector<double>, std::vector<double>>> _clipPolygonToOutline(
    const std::vector<double>& xs, const std::vector<double>& ys, const std::vector<Position>& outline) {
    const Clipper2Lib::Path64 subject = _xyToPath64(xs, ys);
    Clipper2Lib::Path64 clip;
    clip.reserve(outline.size());
    for (const auto& p : outline) {
        clip.emplace_back(static_cast<std::int64_t>(std::llround(p.x())), static_cast<std::int64_t>(std::llround(p.y())));
    }
    const Clipper2Lib::Paths64 result =
        Clipper2Lib::Intersect(Clipper2Lib::Paths64{subject}, Clipper2Lib::Paths64{clip}, Clipper2Lib::FillRule::NonZero);
    std::vector<std::pair<std::vector<double>, std::vector<double>>> loops;
    loops.reserve(result.size());
    for (const auto& loop : result) {
        loops.push_back(_path64ToXY(loop));
    }
    return loops;
}

} // namespace

Simulation::Simulation(SimulationConfig& simConfig, const EMSConfig& config, const RunOptions& options,
                        const PathsConfig& paths)
    : _csx(new ContinuousStructure()),
      _grid(nullptr),
      _simConfig(simConfig),
      _config(config),
      _options(options),
      _paths(paths),
      _planeMaterial(nullptr),
      _viaMaterial(nullptr),
      _viaFillingMaterial(nullptr),
      _npthVoidMaterial(nullptr) {
    _fdtd.SetNumberOfTimeSteps(static_cast<unsigned int>(_config.maxSteps()));
    _fdtd.SetCSX(_csx);
    _grid = _csx->GetGrid();
    _grid->SetDeltaUnit(constants::baseUnit / constants::unitMultiplier);

    _planeMaterial = addMetal(*_csx, "Plane");
    _viaMaterial = addMetal(*_csx, "Via");
    _viaFillingMaterial = addMaterial(*_csx, "ViaFilling", _config.via().fillingEpsilon());
    _npthVoidMaterial = addMaterial(*_csx, "NPTHVoid", 1.0);
}

std::expected<void, std::string> Simulation::sliceBoard() {
    auto result = sliceBoardForSimulation(_simConfig, _config, _paths);
    if (!result) {
        return std::unexpected(result.error());
    }
    _slicedBoard = std::move(*result);
    return {};
}

ComputedGridLines Simulation::computedGridLines() const {
    // _gridGen is only populated by addGrid() -- a Simulation that instead had its lines adopted via
    // adoptGridLines() (see that method's own doc comment) never gets a GridGenerator of its own, so
    // there's no PML-inner-bounds diagnostic to report; the 0-default is fine since these are display
    // only, not read anywhere in the FDTD pipeline itself.
    if (!_gridGen) {
        return {gridLines(*_grid, "x"), gridLines(*_grid, "y"), gridLines(*_grid, "z")};
    }
    return {gridLines(*_grid, "x"),      gridLines(*_grid, "y"),      gridLines(*_grid, "z"),
            _gridGen->pmlInnerXMin(),    _gridGen->pmlInnerXMax(),    _gridGen->pmlInnerYMin(),
            _gridGen->pmlInnerYMax()};
}

void Simulation::adoptGridLines(const ComputedGridLines& lines) {
    _grid->ClearLines(0);
    _grid->ClearLines(1);
    _grid->ClearLines(2);
    _grid->AddDiscLines(0, static_cast<int>(lines.x.size()), const_cast<double*>(lines.x.data()));
    _grid->AddDiscLines(1, static_cast<int>(lines.y.size()), const_cast<double*>(lines.y.data()));
    _grid->AddDiscLines(2, static_cast<int>(lines.z.size()), const_cast<double*>(lines.z.data()));
    _gridLinesAdopted = true;
}

std::expected<void, std::string> Simulation::populateGeometry() {
    createMaterials();
    addGerbers();
    if (!_gridLinesAdopted) {
        addGrid();
    }
    addSubstrates();
    addNPTHHoles();
    if (_options.exportField.has_value()) {
        addDumpBoxes();
    }
    setBoundaryConditions(true);
    if (auto result = addVias(); !result) {
        return std::unexpected(result.error());
    }
    if (auto result = addPorts(); !result) {
        return std::unexpected(result.error());
    }
    return {};
}

void Simulation::createMaterials() {
    const auto metals = _config.getMetals();
    for (std::size_t i = 0; i < metals.size(); ++i) {
        _gerberMaterials.push_back(addMetal(*_csx, "Gerber_" + std::to_string(i)));
    }
    // Dielectric loss tangent -> conductivity (kappa = 2*pi*f*eps0*epsilonR*lossTangent), evaluated
    // at a single fixed frequency rather than modeled as properly dispersive -- CSXCAD's
    // CSPropMaterial::SetKappa() takes one frequency-independent conductivity, but loss tangent
    // implies a conductivity that scales with frequency, so any single value is only exact at the
    // frequency it's evaluated at. 2.5 GHz is a placeholder for testing (chosen directly, not
    // derived from this simulation's own frequency sweep) -- TODO: replace with a configurable
    // per-simulation (or per-material) frequency once there's UI for it, rather than this constant.
    constexpr double kLossTangentFrequencyHz = 2.5e9;
    constexpr double kVacuumPermittivity = 8.85418781762e-12; // F/m
    const auto substrates = _config.getSubstrates();
    for (std::size_t i = 0; i < substrates.size(); ++i) {
        const double kappa = 2 * M_PI * kLossTangentFrequencyHz * kVacuumPermittivity * substrates[i].epsilon() *
                              substrates[i].lossTangent();
        _substrateMaterials.push_back(
            addMaterial(*_csx, "Substrate_" + std::to_string(i), substrates[i].epsilon(), kappa));
    }
}

void Simulation::printGridStats() const {
    auto getStat = [](const std::vector<double>& lines) -> std::pair<double, double> {
        double minSize = std::numeric_limits<double>::infinity();
        double maxScale = -std::numeric_limits<double>::infinity();
        double prev = lines[1];
        double prevSize = std::abs(lines[0] - lines[1]);
        for (const double line : lines) {
            const double size = std::abs(prev - line);
            minSize = std::min(size, minSize);
            double scale = prevSize / size;
            scale = scale > 1 ? scale : 1 / scale;
            maxScale = std::max(scale, maxScale);
            prev = line;
            prevSize = size;
        }
        return {minSize / constants::unitMultiplier, maxScale};
    };

    const std::vector<double> xLines = gridLines(*_grid, "x");
    const std::vector<double> yLines = gridLines(*_grid, "y");
    const std::vector<double> zLines = gridLines(*_grid, "z");
    const auto sx = getStat(xLines);
    const auto sy = getStat(yLines);
    const auto sz = getStat(zLines);
    const double xyz0 = static_cast<double>(gridLineCount(*_grid, "x"));
    const double xyz1 = static_cast<double>(gridLineCount(*_grid, "y"));
    const double xyz2 = static_cast<double>(gridLineCount(*_grid, "z"));

    logInfo("Grid line count, x: " + std::to_string(static_cast<std::int64_t>(xyz0)) +
            ", y: " + std::to_string(static_cast<std::int64_t>(xyz1)) +
            " z: " + std::to_string(static_cast<std::int64_t>(xyz2)) +
            ". Total number of cells: ~" + std::to_string(xyz0 * xyz1 * xyz2 / 1.0e6) + "M");
    logInfo("Minimal cell size, x: " + std::to_string(sx.first) + ", y: " + std::to_string(sy.first) +
            " z: " + std::to_string(sz.first) + " [um]");
    logInfo("Max cell size ratio, x: " + std::to_string(sx.second) + ", y: " + std::to_string(sy.second) +
            " z: " + std::to_string(sz.second));
}

void Simulation::addPortGrid() {
    logInfo("Adding ports grid");
    for (auto& portConfig : _simConfig.ports()) {
        if (!portConfig.position().has_value() || !portConfig.direction().has_value()) {
            logError("Port has no defined position or rotation, skipping");
            return;
        }
        const double angle = *portConfig.direction() / 360.0 * 2 * M_PI;
        const std::string ap = "PORT" + std::to_string(_gridGen->addApertures().size() + 1);
        const double w = portConfig.width();
        const double h = portConfig.length();
        const double width = w * std::round(std::cos(angle)) - h * std::round(std::sin(angle));
        const double height = w * std::round(std::sin(angle)) + h * std::round(std::cos(angle));

        const auto [posX, posY] = *portConfig.position();
        // portConfig.position() is already in the same absolute, Edge_Cuts-bounding-box-relative
        // frame GridGenerator::generate() re-origins its own gerber-parsed trace/pad positions into
        // (see port_resolution.cpp's _edgeCutsOrigin()/_padPositionInSimFrame() and
        // gerber_composite.hpp's BoundingBox doc comment) -- adding _gridGen->xmin()/ymin() here
        // (SlicedBoard::xMin/yMin, itself already an absolute coordinate in that same frame) would
        // double-count the offset and place this density pad millions of sim units away from the
        // real port, discarded once compileGrid() clips lines outside the real domain.
        _gridGen->addPads().emplace_back(ap, "PORT", Position(posX + width / 2, posY));
        _gridGen->addApertures().insert_or_assign(
            ap, Aperture("", std::make_shared<ApertureRect>(width, height)));
    }
}

void Simulation::addGrid() {
    _gridGen = std::make_unique<GridGenerator>(_config, _slicedBoard.xMin, _slicedBoard.yMin, _slicedBoard.width,
                                                _slicedBoard.height);
    addPortGrid();
    logInfo("Compiling grid");
    _gridGen->generate(*_grid, _simConfig, _paths.fabDir);
    printGridStats();
}

void Simulation::addContours(const std::vector<Triangle>& contours, double zHeight, std::int32_t layerIndex) {
    logDebug("Adding contours on z=" + std::to_string(zHeight));
    // Triangle vertices are already in native (x, y) board space -- see Triangle's doc comment.
    // The old raster pipeline needed a row/column swap plus a Y-flip here to undo its PNG's pixel
    // convention; the vector compositor produces triangles directly in board space, so neither is
    // needed any more.
    for (const auto& tri : contours) {
        std::vector<double> xs;
        std::vector<double> ys;
        for (const Position& point : {tri.a, tri.b, tri.c}) {
            xs.push_back(point.x());
            ys.push_back(point.y());
        }
        addPolygon(*_gerberMaterials[static_cast<std::size_t>(layerIndex)], xs, ys, axisIndex("z"), zHeight, 1);
    }
}

void Simulation::addGerbers() {
    logInfo("Adding copper from sliced board geometry");

    // _slicedBoard.layerTriangles is already indexed exactly like _config.getMetals()
    // (see board_slicing.cpp) -- one entry per metal layer, in stackup order -- so no separate
    // per-file compositing/lookup is needed here any more (board_slicing.cpp did it once, per
    // simulation, using only this simulation's involved+ground nets rather than the whole board).
    double offset = 0;
    std::int32_t index = 0;
    for (const auto& layer : _config.layers()) {
        if (layer.kind() == LayerKind::Substrate) {
            offset -= layer.thickness();
        } else if (layer.kind() == LayerKind::Metal) {
            logInfo("Adding metal mesh for " + layer.file());
            addContours(_slicedBoard.layerTriangles.at(static_cast<std::size_t>(index)), offset, index);
            ++index;
        }
    }
}

std::expected<double, std::string> Simulation::getMetalLayerOffset(std::int32_t index) const {
    std::int32_t currentMetalIndex = -1;
    double offset = 0;
    for (const auto& layer : _config.layers()) {
        if (layer.kind() == LayerKind::Metal) {
            ++currentMetalIndex;
            if (currentMetalIndex == index) {
                return offset;
            }
        } else if (layer.kind() == LayerKind::Substrate) {
            offset -= layer.thickness();
        }
    }
    return std::unexpected("Hadn't found " + std::to_string(index) + "th metal layer");
}

std::expected<void, std::string> Simulation::addMslPort(PortConfig& portConfig, std::int32_t portNumber, bool excite) {
    logDebug("Adding port number " + std::to_string(_ports.size()));
    if (!portConfig.position().has_value() || !portConfig.direction().has_value()) {
        logError("Port has no defined position or rotation, skipping");
        return {};
    }
    while (*portConfig.direction() < 0) {
        portConfig.setDirection(*portConfig.direction() + 360);
    }

    static const std::map<std::int32_t, std::string> dirMap = {{0, "y"}, {90, "x"}, {180, "y"}, {270, "x"}};
    const auto dirIt = dirMap.find(static_cast<std::int32_t>(*portConfig.direction()));
    if (dirIt == dirMap.end()) {
        logError("Ports rotation is not a multiple of 90 degrees which is not supported, skipping");
        return {};
    }

    const auto startZResult = getMetalLayerOffset(portConfig.layer());
    if (!startZResult) {
        return std::unexpected(startZResult.error());
    }
    const auto stopZResult = getMetalLayerOffset(portConfig.plane());
    if (!stopZResult) {
        return std::unexpected(stopZResult.error());
    }
    const double startZ = *startZResult;
    const double stopZ = *stopZResult;
    const double angle = *portConfig.direction() / 360.0 * 2 * M_PI;
    const auto [posX, posY] = *portConfig.position();
    const double width = portConfig.width();
    const double length = portConfig.length();

    const Point3 start = {
        std::round(posX - (width / 2) * std::round(std::cos(angle))),
        std::round(posY - (width / 2) * std::round(std::sin(angle))),
        std::round(startZ),
    };
    const Point3 stop = {
        std::round(posX + (width / 2) * std::round(std::cos(angle)) - length * std::round(std::sin(angle))),
        std::round(posY + (width / 2) * std::round(std::sin(angle)) + length * std::round(std::cos(angle))),
        std::round(stopZ),
    };

    logDebug("Adding port at start: " + _point3ToString(start) + " end: " + _point3ToString(stop));
    CSPropMetal* metal = addMetal(*_csx, "Port_" + std::to_string(portNumber));
    _ports.push_back(std::make_unique<MSLPort>(*_csx, portNumber, *metal, start, stop, dirIt->second, "z",
                                                excite ? 1.0 : 0.0, portConfig.impedance(), 100));
    return {};
}

std::expected<void, std::string> Simulation::addResistivePort(PortConfig& portConfig, bool excite) {
    logDebug("Adding port number " + std::to_string(_ports.size()));
    if (!portConfig.position().has_value() || !portConfig.direction().has_value()) {
        logError("Port has no defined position or rotation, skipping");
        return {};
    }
    static const std::map<std::int32_t, std::string> dirMap = {{0, "y"}, {90, "x"}, {180, "y"}, {270, "x"}};
    const auto dirIt = dirMap.find(static_cast<std::int32_t>(*portConfig.direction()));
    if (dirIt == dirMap.end()) {
        logError("Ports rotation is not a multiple of 90 degrees which is not supported, skipping");
        return {};
    }

    const auto startZResult = getMetalLayerOffset(portConfig.layer());
    if (!startZResult) {
        return std::unexpected(startZResult.error());
    }
    const auto stopZResult = getMetalLayerOffset(portConfig.plane());
    if (!stopZResult) {
        return std::unexpected(stopZResult.error());
    }
    const double startZ = *startZResult;
    const double stopZ = *stopZResult;
    const double angle = *portConfig.direction() / 360.0 * 2 * M_PI;
    const auto [posX, posY] = *portConfig.position();
    const double width = portConfig.width();

    const Point3 start = {
        std::round(posX - (width / 2) * std::round(std::cos(angle))),
        std::round(posY - (width / 2) * std::round(std::sin(angle))),
        std::round(startZ),
    };
    const Point3 stop = {
        std::round(posX + (width / 2) * std::round(std::cos(angle))),
        std::round(posY - (width / 2) * std::round(std::sin(angle))),
        std::round(stopZ),
    };

    logDebug("Adding resistive port at start: " + _point3ToString(start) + " end: " + _point3ToString(stop));
    _ports.push_back(std::make_unique<LumpedPort>(*_csx, static_cast<std::int32_t>(_ports.size()),
                                                    portConfig.impedance(), start, stop, "z", excite ? 1.0 : 0.0, 100));
    return {};
}

void Simulation::addPlane(double zHeight) {
    addBox(*_planeMaterial, {_slicedBoard.xMin, _slicedBoard.yMin, zHeight},
           {_slicedBoard.xMin + _slicedBoard.width, _slicedBoard.yMin + _slicedBoard.height, zHeight}, 1);
}

void Simulation::addSubstrates() {
    logInfo("Adding substrates");
    double offset = 0;
    const auto substrates = _config.getSubstrates();
    for (std::size_t i = 0; i < substrates.size(); ++i) {
        addBox(*_substrateMaterials[i], {_slicedBoard.xMin, _slicedBoard.yMin, offset},
               {_slicedBoard.xMin + _slicedBoard.width, _slicedBoard.yMin + _slicedBoard.height,
                offset - substrates[i].thickness()},
               -static_cast<std::int32_t>(i) - 1);
        logDebug("Added substrate from " + std::to_string(offset) + " to " +
                 std::to_string(offset - substrates[i].thickness()));
        offset -= substrates[i].thickness();
    }
}

std::expected<void, std::string> Simulation::addVias() {
    logInfo("Adding vias from excellon file");
    // Excellon coordinates come out of kicad-cli relative to the board's auxiliary origin, like
    // every Gerber this pipeline reads -- re-derived here the same way board_slicing.cpp derives
    // it (see BoundingBox's own doc comment on why that's a deliberate re-derive-per-use-site, not
    // a shared cache) so getVias()'s output lands in the same [0, pcbWidth] x [0, pcbHeight] frame
    // as _slicedBoard, comparable to it directly.
    const double tessellationTolerance = static_cast<double>(_config.pixelSize()) * constants::unitMultiplier;
    auto originResult = edgeCutsBoundingBox(_paths.fabDir, tessellationTolerance);
    if (!originResult) {
        return std::unexpected(originResult.error());
    }
    auto viasResult = getVias(_paths, originResult->xMin, originResult->yMin);
    if (!viasResult) {
        return std::unexpected(viasResult.error());
    }
    // Real board vias: kept only where they still overlap this simulation's sliced outline -- a
    // via whose pad has been entirely sliced away has nothing left to connect to anyway, but one
    // straddling the cutout boundary (real copper the cutout genuinely intersects) must be kept,
    // hence the disc-overlap test rather than a center-point-only one (see
    // _viaIntersectsOutline's own doc comment). Tested against *both* ends of an elongated via's
    // centerline (a plain round via just tests the same point twice) -- an oblong pad can straddle
    // the cutout boundary at either end independently of the other.
    for (const auto& via : *viasResult) {
        if (_viaIntersectsOutline(via.x, via.y, via.diameter, _slicedBoard.outline) ||
            _viaIntersectsOutline(via.x2, via.y2, via.diameter, _slicedBoard.outline)) {
            // A real via's own copper pad on each layer is already modeled separately (it's part
            // of that layer's composited copper, read straight from the Gerbers) -- this outer
            // ring only needs to be wide enough for the drilled barrel's actual conductive wall,
            // not a full pad, unlike a stitching via below. Cropped to the sliced outline
            // (cropToOutline=true) since this via was kept precisely because its disc *reaches*
            // that boundary, not because it's fully inside it -- left uncropped, it would extend
            // past the hull-padding trim line into the simulation's own PML/boundary region.
            const double outerDiameter = via.diameter + 2 * _config.via().platingThickness();
            addVia(via.x, via.y, via.x2, via.y2, via.diameter, outerDiameter, /*cropToOutline=*/true);
        }
    }

    logInfo("Adding " + std::to_string(_slicedBoard.stitchingVias.size()) +
            " ground-net stitching via(s) from board slicing");
    for (const auto& via : _slicedBoard.stitchingVias) {
        // Unlike a real via, a stitching via has no copper pad modeled anywhere else -- its outer
        // ring has to be the full annular ring diameter to serve as its own pad, not just a thin
        // conductive wall (see Via::stitchingViaAnnularRingDiameter's own doc comment). Always a
        // plain round hole -- this pipeline only ever invents round stitching vias, never oblong
        // ones.
        addVia(via.x, via.y, via.x, via.y, via.diameter, via.annularRingDiameter);
    }
    return {};
}

void Simulation::addVia(double xPos, double yPos, double x2Pos, double y2Pos, double diameter, double outerDiameter,
                          bool cropToOutline) {
    double thickness = 0;
    for (const auto& layer : _config.getSubstrates()) {
        thickness += layer.thickness();
    }

    auto addCrossSection = [&](CSProperties& material, const std::vector<double>& xs, const std::vector<double>& ys,
                                std::int32_t priority) {
        if (!cropToOutline) {
            addLinPoly(material, xs, ys, axisIndex("z"), -thickness, thickness, priority);
            return;
        }
        // A degenerate (<3-point) loop can fall out of Clipper2's intersection at a boundary that
        // grazes the via's disc only tangentially -- skipped rather than fed to addLinPoly, which
        // expects a genuine polygon.
        for (const auto& [loopXs, loopYs] : _clipPolygonToOutline(xs, ys, _slicedBoard.outline)) {
            if (loopXs.size() < 3) {
                continue;
            }
            addLinPoly(material, loopXs, loopYs, axisIndex("z"), -thickness, thickness, priority);
        }
    };

    auto [fillXs, fillYs] = _viaPolygon(xPos, yPos, x2Pos, y2Pos, diameter, false);
    addCrossSection(*_viaFillingMaterial, fillXs, fillYs, 51);

    auto [outerXs, outerYs] = _viaPolygon(xPos, yPos, x2Pos, y2Pos, outerDiameter, true);
    addCrossSection(*_viaMaterial, outerXs, outerYs, 50);
}

void Simulation::addNPTHHoles() {
    if (_slicedBoard.npthHoleLoops.empty()) {
        return;
    }
    double thickness = 0;
    for (const auto& layer : _config.getSubstrates()) {
        thickness += layer.thickness();
    }
    logInfo("Adding " + std::to_string(_slicedBoard.npthHoleLoops.size()) + " NPTH hole(s)");
    // Same "extrude a material through the whole substrate stack, at a priority above every
    // substrate layer's" technique addVia() uses for a via's own barrel -- just vacuum instead of
    // conductor, and priority 60 (above the via priorities of 50/51, though the two shouldn't ever
    // spatially coincide in practice) so it reliably overrides substrate wherever a hole falls.
    for (const auto& loop : _slicedBoard.npthHoleLoops) {
        std::vector<double> xCoords;
        std::vector<double> yCoords;
        xCoords.reserve(loop.size());
        yCoords.reserve(loop.size());
        for (const Position& p : loop) {
            xCoords.push_back(p.x());
            yCoords.push_back(p.y());
        }
        addLinPoly(*_npthVoidMaterial, xCoords, yCoords, axisIndex("z"), -thickness, thickness, 60);
    }
}

void Simulation::addSingleDumpBox(const std::string& name, double z) {
    logDebug("Adding dump box at " + std::to_string(z));
    CSPropDumpBox* dump = addDump(*_csx, name, {1, 1, 1});
    const double margin = _config.grid().margin().xy();
    addBox(*dump, {_slicedBoard.xMin - margin, _slicedBoard.yMin - margin, z},
           {_slicedBoard.xMin + _slicedBoard.width + margin, _slicedBoard.yMin + _slicedBoard.height + margin, z});
}

void Simulation::addDumpBoxes() {
    if (!_options.exportField.has_value()) {
        return;
    }
    logInfo("Adding field dump boxes");

    std::vector<std::string> exportField = *_options.exportField;
    if (exportField.empty()) {
        exportField = {"outer", "cu-outer", "cu-inner", "substrate"};
    }
    const auto contains = [&](const std::string& v) {
        return std::find(exportField.begin(), exportField.end(), v) != exportField.end();
    };

    double offset = 0;
    std::int32_t metalIdx = 0;
    const std::int32_t metalCount = static_cast<std::int32_t>(_config.getMetals().size());
    for (const auto& layer : _config.layers()) {
        const std::string normName = _normalizeLayerName(layer.name());
        if (layer.kind() == LayerKind::Substrate) {
            if (contains("substrate")) {
                const double height = offset - layer.thickness() / 2;
                addSingleDumpBox("e_field_" + normName, height);
            }
            offset -= layer.thickness();
        } else if (layer.kind() == LayerKind::Metal) {
            // NOTE deliberate deviation from the Python source, whose equivalent comparison is
            // `metal_idx == metal_count`. Since metal_idx is only ever incremented after this check,
            // that condition never actually triggers, so "cu-outer" only ever captured the first
            // (top) metal layer, never the last (bottom) one. Compare against `metalCount - 1`
            // instead so the last metal layer is correctly recognised as the bottom outer layer.
            const bool exportInner = contains("cu-inner") && metalIdx != 0 && metalIdx != metalCount - 1;
            const bool exportOuter = contains("cu-outer") && (metalIdx == 0 || metalIdx == metalCount - 1);
            if (exportInner || exportOuter) {
                addSingleDumpBox("e_field_" + normName, offset);
            }
            ++metalIdx;
        }
    }

    if (contains("outer")) {
        addSingleDumpBox("e_field_top_over", 100);
        addSingleDumpBox("e_field_bottom_over", offset - 100);
    }
}

void Simulation::setBoundaryConditions(bool pml) {
    if (pml) {
        logInfo("Adding perfectly matched layer boundary condition");
        // See constants::pmlDepthCells's own doc comment for why 16, not openEMS's own PML_8
        // default -- and GridGenerator's own outermost-cell regrading, which keeps this many cells
        // on each face smoothly, predictably sized rather than whatever the general-purpose mesh
        // densification produced there.
        for (std::int32_t i = 0; i < 6; ++i) {
            _fdtd.Set_BC_PML(i, constants::pmlDepthCells);
        }
    } else {
        logInfo("Adding MUR boundary condition");
        for (std::int32_t i = 0; i < 6; ++i) {
            _fdtd.Set_BC_Type(i, 2); // 2 == MUR, matching ['PEC','PMC','MUR'].index('MUR')
        }
    }
}

void Simulation::setExcitation() {
    const Frequency& freq = _config.frequency();
    logDebug("Setting excitation to gaussian pulse from " + std::to_string(freq.start()) + " to " +
             std::to_string(freq.stop()));
    _fdtd.SetGaussExcite((freq.start() + freq.stop()) / 2, (freq.stop() - freq.start()) / 2);
}

void Simulation::setSinusExcitation(double freq) {
    logDebug("Setting excitation to sine at " + std::to_string(freq));
    _fdtd.SetSinusExcite(freq);
}

std::expected<void, std::string> Simulation::run(std::int32_t excitedPortNumber) {
    logInfo("Starting simulation");
    const std::filesystem::path simPath = _paths.simulationDir / _simConfig.name() / std::to_string(excitedPortNumber);
    std::error_code dirEc;
    std::filesystem::create_directories(simPath, dirEc);
    if (dirEc) {
        return std::unexpected("Failed to create simulation directory: " + dirEc.message());
    }

    // job.json carries just enough for a freshly-spawned worker to reconstruct an equivalent
    // Simulation on its own (it shares no memory with this process): where to reload the already-
    // saved geometry from, and which port to excite. Everything else (grid/via/frequency/maxSteps)
    // the worker re-derives itself from paths.configFile, exactly as this process did.
    const std::filesystem::path jobPath = simPath / "job.json";
    nlohmann::json job;
    job["config_path"] = _paths.configFile.string();
    job["simulation_name"] = _simConfig.name();
    job["excited_port"] = excitedPortNumber;
    job["oversampling"] = _options.oversampling;
    {
        std::ofstream jobFile(jobPath);
        if (!jobFile) {
            return std::unexpected("Failed to write job file: " + jobPath.string());
        }
        jobFile << job.dump();
    }

    // Cleared up front so a stale error from a previous run in the same directory can never be
    // mistaken for this run's failure.
    const std::filesystem::path errorPath = simPath / "worker_error.txt";
    std::error_code removeEc;
    std::filesystem::remove(errorPath, removeEc);

    const std::filesystem::path& workerPath =
        (_options.backend == FDTDBackend::CopperGPU) ? _paths.copperFdtdWorkerPath : _paths.fdtdWorkerPath;
    std::string workerPathStr = workerPath.string();
    std::string jobPathStr = jobPath.string();
    std::array<char*, 3> argv = {workerPathStr.data(), jobPathStr.data(), nullptr};
    pid_t pid = 0;
    if (posix_spawn(&pid, workerPathStr.c_str(), nullptr, nullptr, argv.data(), environ) != 0) {
        return std::unexpected("Failed to spawn FDTD worker (" + workerPathStr + "): " + std::strerror(errno));
    }
    int status = 0;
    if (waitpid(pid, &status, 0) < 0) {
        return std::unexpected("waitpid failed: " + std::string(std::strerror(errno)));
    }
    if (!WIFEXITED(status) || WEXITSTATUS(status) != 0) {
        std::ifstream errFile(errorPath);
        if (errFile) {
            std::stringstream buffer;
            buffer << errFile.rdbuf();
            if (!buffer.str().empty()) {
                return std::unexpected(buffer.str());
            }
        }
        return std::unexpected("FDTD worker exited with an error (no message written to " + errorPath.string() + ")");
    }
    return {};
}

std::expected<void, std::string> Simulation::setupFDTDOperator(std::int32_t excitedPortNumber) {
    const std::filesystem::path cwd = std::filesystem::current_path();
    const std::filesystem::path simPath = _paths.simulationDir / _simConfig.name() / std::to_string(excitedPortNumber);
    std::error_code dirEc;
    std::filesystem::create_directories(simPath, dirEc);
    if (dirEc) {
        return std::unexpected("Failed to create simulation directory: " + dirEc.message());
    }
    std::filesystem::current_path(simPath);

    _fdtd.SetOverSampling(_options.oversampling);
    const auto setupStart = std::chrono::steady_clock::now();
    const int rc = _fdtd.SetupFDTD();
    const double setupSeconds = std::chrono::duration<double>(std::chrono::steady_clock::now() - setupStart).count();
    logInfo("openEMS::SetupFDTD() took " + std::to_string(setupSeconds) + "s");
    if (rc != 0) {
        std::filesystem::current_path(cwd);
        return std::unexpected("Run: Setup failed, error code: " + std::to_string(rc));
    }
    return {};
}

std::expected<void, std::string> Simulation::runFDTDInPlace(std::int32_t excitedPortNumber) {
    const std::filesystem::path cwd = std::filesystem::current_path();
    if (auto result = setupFDTDOperator(excitedPortNumber); !result) {
        return result;
    }
    _fdtd.RunFDTD();

    std::filesystem::current_path(cwd);
    return {};
}

std::expected<std::pair<std::vector<std::vector<std::complex<double>>>, std::vector<std::vector<std::complex<double>>>>,
              std::string>
Simulation::getPortParameters(std::int32_t exIndex, const std::vector<double>& frequencies) {
    const std::filesystem::path resultPath = _paths.simulationDir / _simConfig.name() / std::to_string(exIndex);

    std::vector<std::vector<std::complex<double>>> incident;
    std::vector<std::vector<std::complex<double>>> reflected;
    for (std::size_t index = 0; index < _ports.size(); ++index) {
        if (auto result = _ports[index]->calcPort(resultPath, frequencies); !result) {
            return std::unexpected("Port data files do not exist. Did you run simulation step? (" + result.error() +
                                    ")");
        }
        logDebug("Found data for port " + std::to_string(index));
        incident.push_back(_ports[index]->ufInc());
        reflected.push_back(_ports[index]->ufRef());
    }
    return std::make_pair(std::move(reflected), std::move(incident));
}

void Simulation::setupPorts(std::int32_t enabledIdx) {
    logInfo("Setting up ports");
    for (std::size_t i = 0; i < _csx->GetQtyProperties(); ++i) {
        auto* prop = dynamic_cast<CSPropExcitation*>(_csx->GetProperty(i));
        if (prop == nullptr) {
            continue;
        }
        const std::string pname = prop->GetName();
        std::size_t digitsStart = pname.size();
        while (digitsStart > 0 && std::isdigit(static_cast<unsigned char>(pname[digitsStart - 1])) != 0) {
            --digitsStart;
        }
        const std::int32_t idx = std::stoi(pname.substr(digitsStart));
        if (idx != enabledIdx) {
            prop->SetExcitation(0, 0);
            prop->SetExcitation(0, 1);
            prop->SetExcitation(0, 2);
        } else {
            prop->SetExcitation(0, 0);
            prop->SetExcitation(0, 1);
            prop->SetExcitation(1, 2);
        }
    }
}

std::expected<void, std::string> Simulation::addPorts() {
    logInfo("Adding ports");
    _ports.clear();
    auto& ports = _simConfig.ports();
    for (std::size_t index = 0; index < ports.size(); ++index) {
        if (auto result = addMslPort(ports[index], static_cast<std::int32_t>(index), true); !result) {
            return result;
        }
    }
    return {};
}

} // namespace gerber2ems
