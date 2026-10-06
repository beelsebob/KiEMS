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
#include <utility>

#include <spawn.h>
#include <sys/wait.h>

#include <nlohmann/json.hpp>

#include "constants.hpp"
#include "csx_grid_utils.hpp"
#include "../../submodules/libkicad/libkicad.hpp"
#include "board_slicing.hpp"
#include "logging.hpp"

extern char** environ;

namespace kiems {

using namespace Cu;

namespace {

std::string _point3ToString(const Point3& p) {
    return "[" + std::to_string(p[0]) + ", " + std::to_string(p[1]) + ", " + std::to_string(p[2]) + "]";
}

// Corner-bridge elevation above/below the board for a diagonal 2-pin lumped component (see
// LumpedComponentConfig::cornerBridge()'s own doc comment) -- shared by
// Simulation::addLumpedComponentGrid() (which must reserve mesh density here before the grid is
// generated) and Simulation::addLumpedComponents() (which actually builds the geometry there), so the
// two can never drift out of sync with each other.
constexpr double kCornerBridgeElevationSimUnits = 2000.0; // ~0.2mm clearance above/below the board
double _cornerBridgeZ(double padZ, std::int32_t layer) {
    // Metal layer 0 is F.Cu, the topmost copper (see Simulation::getMetalLayerOffset()'s own
    // convention: offset 0 there, more negative for every layer below it) -- elevate away from the
    // board in whichever direction is actually open air for this component's own side, not through
    // the substrate stack.
    return layer == 0 ? padZ + kCornerBridgeElevationSimUnits : padZ - kCornerBridgeElevationSimUnits;
}

// Dielectric loss tangent -> conductivity (kappa = 2*pi*f*eps0*epsilonR*lossTangent), evaluated at a
// single fixed frequency rather than modeled as properly dispersive -- CSXCAD's CSPropMaterial::
// SetKappa() takes one frequency-independent conductivity, but loss tangent implies a conductivity
// that scales with frequency, so any single value is only exact at the frequency it's evaluated at.
// 2.5 GHz is a placeholder for testing (chosen directly, not derived from this simulation's own
// frequency sweep) -- TODO: replace with a configurable per-simulation (or per-material) frequency
// once there's UI for it, rather than this constant. Shared by every dielectric material this
// Simulation creates (substrates, solder mask) so they're all evaluated at the same placeholder
// frequency, not just internally consistent with each other by coincidence.
double _lossTangentToKappa(double epsilon, double lossTangent) {
    constexpr double kLossTangentFrequencyHz = 2.5e9;
    constexpr double kVacuumPermittivity = 8.85418781762e-12; // F/m
    return 2 * M_PI * kLossTangentFrequencyHz * kVacuumPermittivity * epsilon * lossTangent;
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
// Position keeps this geometry in the same double-precision coordinate space as the board model.
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

std::expected<std::pair<double, double>, std::string> _boardOrigin(const libkicad::Board& board) {
    auto geometry = board.boardGeometry();
    if (!geometry) {
        return std::unexpected(std::move(geometry).error());
    }
    double xMin = std::numeric_limits<double>::infinity();
    double yMin = std::numeric_limits<double>::infinity();
    for (const libkicad::PolygonLoop& loop : geometry->outline) {
        for (const auto& [xMm, yMm] : loop.pointsMm) {
            const double x = xMm / 1000.0 / constants::baseUnit * constants::unitMultiplier;
            const double y = yMm / 1000.0 / constants::baseUnit * constants::unitMultiplier;
            xMin = std::min(xMin, x);
            yMin = std::min(yMin, y);
        }
    }
    if (!std::isfinite(xMin) || !std::isfinite(yMin)) {
        return std::unexpected("KiCad board geometry has no usable Edge.Cuts points");
    }
    return std::pair{xMin, yMin};
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

Polygon _xyToPolygon(const std::vector<double>& xs, const std::vector<double>& ys) {
    Polygon path;
    path.reserve(xs.size());
    for (std::size_t i = 0; i < xs.size(); ++i) {
        path.emplace_back(xs[i], ys[i]);
    }
    return path;
}

std::pair<std::vector<double>, std::vector<double>> _polygonToXY(const Polygon& path) {
    std::vector<double> xs;
    std::vector<double> ys;
    xs.reserve(path.size());
    ys.reserve(path.size());
    for (const Position& pt : path) {
        xs.push_back(pt.x());
        ys.push_back(pt.y());
    }
    return {xs, ys};
}

/// Clips a via cross-section polygon (xs/ys, as produced by _viaPolygon) to the sliced board's own
/// outline via polygon intersection -- a real via kept because its disc merely *reaches* the cutout
/// boundary (see _viaIntersectsOutline's own doc comment) would otherwise be added at its full,
/// uncropped geometric extent, sticking out past the simulation's own domain past the hull-padding
/// trim line. Usually a single loop; can (rarely) come back as more than one if the outline's own
/// boundary is concave enough to split the via's disc into disjoint pieces.
std::vector<std::pair<std::vector<double>, std::vector<double>>> _clipPolygonToOutline(
    const std::vector<double>& xs, const std::vector<double>& ys, const std::vector<Position>& outline) {
    const Polygon subject = _xyToPolygon(xs, ys);
    const PolygonSet result = intersectPolygons({subject}, {outline});
    std::vector<std::pair<std::vector<double>, std::vector<double>>> loops;
    loops.reserve(result.size());
    for (const auto& loop : result) {
        loops.push_back(_polygonToXY(loop));
    }
    return loops;
}

} // namespace

Simulation::Simulation(SimulationConfig& simConfig, const EMSConfig& config, const RunOptions& options,
                        const PathsConfig& paths, const libkicad::Board& board)
    : _csx(std::make_unique<ContinuousStructure>()),
      _grid(nullptr),
      _simConfig(simConfig),
      _config(config),
      _options(options),
      _paths(paths),
      _board(board),
      _planeMaterial(nullptr),
      _viaMaterial(nullptr),
      _viaFillingMaterial(nullptr),
      _npthVoidMaterial(nullptr) {
    _grid = _csx->GetGrid();
    _grid->SetDeltaUnit(constants::baseUnit / constants::unitMultiplier);

    _planeMaterial = addMetal(*_csx, "Plane");
    _viaMaterial = addMetal(*_csx, "Via");
    _viaFillingMaterial = addMaterial(*_csx, "ViaFilling", _config.via().fillingEpsilon());
    _npthVoidMaterial = addMaterial(*_csx, "NPTHVoid", 1.0);
}

std::expected<void, std::string> Simulation::sliceBoard() {
    logInfo("Slicing board for " + _simConfig.name());
    auto geometry = _board.boardGeometry();
    if (!geometry) {
        return std::unexpected(std::move(geometry).error());
    }
    auto copper = classifyCopperForSimulation(_simConfig, *geometry, _board);
    if (!copper) {
        return std::unexpected(std::move(copper).error());
    }

    auto origin = boardBoundsInSimulationUnits(*geometry);
    if (!origin) {
        return std::unexpected(std::move(origin).error());
    }
    // Best-effort: if the KiCad hole query fails, slicing/stitching just proceed without this data
    // rather than failing the whole slice over it (the same as if the board genuinely had none).
    std::vector<ViaHole> existingVias;
    if (auto vias = getVias(_board, origin->xMin, origin->yMin); vias) {
        existingVias = std::move(*vias);
    }
    std::vector<NPTHHole> npthHoles;
    if (auto holes = getNPTHHoles(_board, origin->xMin, origin->yMin); holes) {
        npthHoles = std::move(*holes);
    }

    const SlicingConfig slicing = SlicingConfig::from(_simConfig, _config);
    auto result = sliceBoardForSimulation(slicing, *geometry, copper->involved,
                                           copper->geometryOnly, copper->ground, copper->hullContributions,
                                           existingVias, npthHoles);
    if (!result) {
        return std::unexpected(result.error());
    }
    _slicedBoard = std::move(*result);
    restrictLumpedComponentsToCutout(_simConfig, _slicedBoard);
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
            _gridGen->pmlInnerYMax(),    _gridGen->pmlInnerZMin(),    _gridGen->pmlInnerZMax()};
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
    addEdgeTerminations();
    addSolderMask();
    addNPTHHoles();
    if (_options.exportField.has_value()) {
        addDumpBoxes();
    }
    if (auto result = addVias(); !result) {
        return std::unexpected(result.error());
    }
    if (auto result = addPorts(); !result) {
        return std::unexpected(result.error());
    }
    if (auto result = addLumpedComponents(); !result) {
        return std::unexpected(result.error());
    }
    return {};
}

void Simulation::createMaterials() {
    const auto metals = _config.getMetals();
    for (std::size_t i = 0; i < metals.size(); ++i) {
        _gerberMaterials.push_back(addMetal(*_csx, "Gerber_" + std::to_string(i)));
    }
    const auto substrates = _config.getSubstrates();
    for (std::size_t i = 0; i < substrates.size(); ++i) {
        const double kappa = _lossTangentToKappa(substrates[i].epsilon(), substrates[i].lossTangent());
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
        const std::string ap = "PORT" + std::to_string(_gridGen->addApertures().size() + 1);
        const PortGridFootprint footprint = portGridFootprint(portConfig);
        // portConfig.position() is already in the same absolute, Edge_Cuts-bounding-box-relative
        // frame as the sliced copper consumed by GridGenerator::generate()
        // (see port_resolution.cpp's _edgeCutsOrigin()/_padPositionInSimFrame() and
        // CopperUtils/polygon_geometry.hpp's BoundingBox doc comment) -- adding _gridGen->xmin()/ymin() here
        // (SlicedBoard::xMin/yMin, itself already an absolute coordinate in that same frame) would
        // double-count the offset and place this density pad millions of sim units away from the
        // real port, discarded once compileGrid() clips lines outside the real domain.
        // ApertureRect is centred on Pad::pos(). The former `posX + width / 2` placement shifted
        // every density hint off its real pad, while the signed cardinal rotation formula could
        // also produce a negative aperture dimension. On a small pad that meant the resistor box
        // and the locally-dense part of the mesh did not coincide, so an absorb-only port could be
        // present in CSX yet fail to make a reliable electrical connection. Use the same centred,
        // positive axis-aligned envelope as addResistivePort().
        _gridGen->addPads().emplace_back(ap, NetName("PORT"), Position(footprint.centerX, footprint.centerY));
        _gridGen->addApertures().insert_or_assign(
            ap, Aperture("", std::make_shared<ApertureRect>(footprint.width, footprint.height)));
    }
}

// A diagonal 2-pin component's corner-bridge (see LumpedComponentConfig::cornerBridge()'s own doc
// comment) is real 3D CSX geometry -- two short vertical pillars plus a small elevated horizontal
// bridge -- built later, in addLumpedComponents(). But grid generation runs *before* that (see
// addGrid()'s own call order) and works entirely from pre-computed config/gerber inputs, never from
// the CSX structure itself, so it has no way to discover that geometry on its own and would otherwise
// mesh right through it at whatever density the ordinary board-to-margin grading happens to produce
// there -- potentially far too coarse to resolve a ~0.2mm pillar (confirmed on a real board: the
// bridge showed the same near-zero transmission as the design it replaced, even though the geometry
// itself was verified correct, until this was added). Reserves X/Y density at the corner point the
// same way addPortGrid() already does for a port's own synthetic aperture, and Z density at both the
// pad's own layer and the bridge's own elevated height.
void Simulation::addLumpedComponentGrid() {
    for (const auto& component : _simConfig.lumpedComponents()) {
        if (!component.cornerBridge()) {
            continue;
        }
        // Not a fatal std::expected error here even though getMetalLayerOffset() can fail in
        // principle -- component.layer() was already validated as a real configured metal layer back
        // in port_resolution.cpp's own _resolveLumpedComponents() (via
        // EMSConfig::metalLayerIndexForFileName()), so a failure here would mean the config changed
        // out from under this run; addLumpedComponents() itself (which runs later, building the
        // actual geometry) will hit the exact same lookup and fail loudly there instead. Skipping just
        // this one component's density hints degrades to "may mesh a bit coarse" rather than losing
        // grid generation for every other component/port over one that's already about to fail anyway.
        const auto zResult = getMetalLayerOffset(component.layer());
        if (!zResult) {
            logWarning("Simulation: couldn't resolve corner-bridge component " + component.reference() +
                       "'s own metal layer for grid density -- skipping its density hints: " + zResult.error());
            continue;
        }
        const double padZ = std::round(*zResult);
        const double bridgeZ = _cornerBridgeZ(padZ, component.layer());
        _gridGen->additionalZHeights().push_back(padZ);
        _gridGen->additionalZHeights().push_back(bridgeZ);

        const auto [cornerX, cornerY] = component.bridgeCorner();
        const std::string ap = "LUMPEDBRIDGE" + std::to_string(_gridGen->addApertures().size() + 1);
        const double width = component.width();
        _gridGen->addPads().emplace_back(ap, NetName("LUMPEDBRIDGE"), Position(cornerX, cornerY));
        _gridGen->addApertures().insert_or_assign(ap, Aperture("", std::make_shared<ApertureRect>(width, width)));
    }
}

void Simulation::addGrid() {
    _gridGen = std::make_unique<GridGenerator>(_config, _slicedBoard.bounds.xMin, _slicedBoard.bounds.yMin,
                                                _slicedBoard.bounds.xMax - _slicedBoard.bounds.xMin,
                                                _slicedBoard.bounds.yMax - _slicedBoard.bounds.yMin,
                                                _slicedBoard.cutoutLoops, _slicedBoard.layerCopperLoops);
    addPortGrid();
    addLumpedComponentGrid();
    logInfo("Compiling grid");
    _gridGen->generate(*_grid, _simConfig, _board);
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
        addPolygon(*_gerberMaterials[static_cast<std::size_t>(layerIndex)], xs, ys, axisIndex("z"), zHeight, 10);
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

    // direction is the pad's own departure-angle convention (0/180 => horizontal => x, 90/270 =>
    // vertical => y) -- see LumpedComponentConfig::direction()'s own doc comment, which is explicit
    // that PortConfig::direction() uses this exact same convention (both are ultimately populated in
    // port_resolution.cpp, from a per-pad/net override or else the pad's own real rotation). This dirMap
    // previously read {{0,"y"},{90,"x"},...} -- backwards relative to that documented convention --
    // which rotated every MSL port's measurement/feed-resistor box 90 degrees away from the real
    // routed trace it is meant to sample and terminate, breaking clean absorption at that
    // junction (an excited port at the same misalignment still radiates something, so it read as
    // "mostly working" there, but a purely-absorbing port has no such slack).
    static const std::map<std::int32_t, std::string> dirMap = {{0, "x"}, {90, "y"}, {180, "x"}, {270, "y"}};
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

    // Transverse (width) axis and propagation (length) axis, matching the dirMap fix above -- at
    // direction=0 (a trace departing horizontally, +x) this must put `length` along x and `width`
    // along y, the opposite of the old cos<->width/sin<->length pairing.
    const double widthDirX = -std::round(std::sin(angle));
    const double widthDirY = std::round(std::cos(angle));
    const double propDirX = std::round(std::cos(angle));
    const double propDirY = std::round(std::sin(angle));

    const Point3 start = {
        std::round(posX - (width / 2) * widthDirX),
        std::round(posY - (width / 2) * widthDirY),
        std::round(startZ),
    };
    const Point3 stop = {
        std::round(posX + (width / 2) * widthDirX + length * propDirX),
        std::round(posY + (width / 2) * widthDirY + length * propDirY),
        std::round(stopZ),
    };

    logDebug("Adding port at start: " + _point3ToString(start) + " end: " + _point3ToString(stop));
    // The imported Gerber already supplies the trace metal. Adding the axis-aligned port box as
    // metal too would invent a straight copper strip even when the real route bends inside the port
    // interval. On TestSim's U10.59 that synthetic strip overlaps a nearby GND pour and creates a
    // literal PEC short across the intended clearance.
    _ports.push_back(std::make_unique<MSLPort>(*_csx, portNumber, start, stop, dirIt->second, "z",
                                                excite ? 1.0 : 0.0, portConfig.impedance(), 100));
    return {};
}

std::expected<void, std::string> Simulation::addImpedanceProbe(PortConfig& portConfig, std::int32_t portNumber) {
    logDebug("Adding port number " + std::to_string(_ports.size()));
    if (!portConfig.position().has_value() || !portConfig.direction().has_value()) {
        logError("Port has no defined position or rotation, skipping");
        return {};
    }
    while (*portConfig.direction() < 0) {
        portConfig.setDirection(*portConfig.direction() + 360);
    }

    // Same dirMap/width-axis convention as addMslPort() -- see that function's own comment on why
    // this (not addPassiveProbe()'s older, pad-anchored cos/sin-along-axis convention) is the
    // correct one for a box whose width must span transversely across the real trace, not along it.
    static const std::map<std::int32_t, std::string> dirMap = {{0, "x"}, {90, "y"}, {180, "x"}, {270, "y"}};
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

    const double widthDirX = -std::round(std::sin(angle));
    const double widthDirY = std::round(std::cos(angle));
    const double propDirX = std::round(std::cos(angle));
    const double propDirY = std::round(std::sin(angle));

    // This position is the selected run's centre, unlike a pad port's departure point. Centre the
    // whole MSL span so its two ends remain inside the straight run the heuristic validated.
    const Point3 start = {
        std::round(posX - (width / 2) * widthDirX - (length / 2) * propDirX),
        std::round(posY - (width / 2) * widthDirY - (length / 2) * propDirY),
        std::round(startZ),
    };
    const Point3 stop = {
        std::round(posX + (width / 2) * widthDirX + (length / 2) * propDirX),
        std::round(posY + (width / 2) * widthDirY + (length / 2) * propDirY),
        std::round(stopZ),
    };

    logDebug("Adding impedance probe at start: " + _point3ToString(start) + " end: " + _point3ToString(stop));
    // excite=0, feedR<0 (skip the resistor entirely, see MSLPort's own constructor) -- a pure
    // measurement point: no synthetic metal, no termination, zero effect on the simulated fields.
    _ports.push_back(std::make_unique<MSLPort>(*_csx, portNumber, start, stop, dirIt->second, "z",
                                                /*excite=*/0.0, /*feedR=*/-1.0, 100));
    return {};
}

std::expected<void, std::string> Simulation::addResistivePort(PortConfig& portConfig, std::int32_t portNumber,
                                                                bool excite) {
    logDebug("Adding port number " + std::to_string(_ports.size()));
    if (!portConfig.position().has_value() || !portConfig.direction().has_value()) {
        logError("Port has no defined position or rotation, skipping");
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

    // The resistor is vertical from pad to reference plane (excDir "z" below -- current here never
    // depends on `direction` at all) and covers the whole pad in XY; `direction` only orients that
    // XY footprint to the pad's own real (possibly non-cardinal) rotation -- port_resolution.cpp
    // populates it from the pad's own rotation, not a derived trace-departure angle, so this no
    // longer needs to reject anything: true sin/cos (not rounded to the nearest cardinal) gives the
    // exact axis-aligned bounding box of the pad's real rotated rectangle at any angle, and reduces
    // to the old rounded behavior exactly at true cardinal angles anyway. Both dimensions matter:
    // spanning only transversely creates a zero-thickness sheet along the propagation axis, so a
    // small mesh-line displacement can leave it containing no Z-directed Yee edges and therefore
    // produce no excitation at all.
    const double widthDirX = -std::sin(angle);
    const double widthDirY = std::cos(angle);
    const double propDirX = std::cos(angle);
    const double propDirY = std::sin(angle);
    const double length = portConfig.length();
    const double halfExtentX = (std::abs(widthDirX) * width + std::abs(propDirX) * length) / 2.0;
    const double halfExtentY = (std::abs(widthDirY) * width + std::abs(propDirY) * length) / 2.0;
    const Point3 start = {
        std::round(posX - halfExtentX),
        std::round(posY - halfExtentY),
        std::round(startZ),
    };
    const Point3 stop = {
        std::round(posX + halfExtentX),
        std::round(posY + halfExtentY),
        std::round(stopZ),
    };

    logDebug("Adding resistive port at start: " + _point3ToString(start) + " end: " + _point3ToString(stop));
    _ports.push_back(std::make_unique<LumpedPort>(*_csx, portNumber,
                                                    portConfig.impedance(), start, stop, "z", excite ? 1.0 : 0.0, 100));
    return {};
}

void Simulation::addPlane(double zHeight) {
    addBox(*_planeMaterial, {_slicedBoard.bounds.xMin, _slicedBoard.bounds.yMin, zHeight},
           {_slicedBoard.bounds.xMax, _slicedBoard.bounds.yMax, zHeight}, 10);
}

void Simulation::addSubstrates() {
    logInfo("Adding substrates");
    double offset = 0;
    const auto substrates = _config.getSubstrates();
    for (std::size_t i = 0; i < substrates.size(); ++i) {
        const double thickness = substrates[i].thickness();
        const std::int32_t substratePriority = -static_cast<std::int32_t>(i) - 1;
        if (_slicedBoard.cutoutLoops.empty()) {
            // Compatibility fallback for geometry caches predating cutoutLoops.
            addBox(*_substrateMaterials[i], {_slicedBoard.bounds.xMin, _slicedBoard.bounds.yMin, offset},
                   {_slicedBoard.bounds.xMax, _slicedBoard.bounds.yMax, offset - thickness}, substratePriority);
        } else {
            // The old bounding-box slab left dielectric in concave corners and between disjoint
            // pieces of the hull-cut board. That material then influenced both coefficient painting
            // and the supposedly-vacuum expansion band. Build the dielectric from the true cutout
            // loops instead; clockwise loops are holes and receive a higher-priority vacuum punch.
            for (const auto& loop : _slicedBoard.cutoutLoops) {
                std::vector<double> xs, ys;
                xs.reserve(loop.size());
                ys.reserve(loop.size());
                for (const Position& point : loop) {
                    xs.push_back(point.x());
                    ys.push_back(point.y());
                }
                if (Cu::isPositive(loop)) {
                    addLinPoly(*_substrateMaterials[i], xs, ys, axisIndex("z"), offset - thickness, thickness,
                               substratePriority);
                } else {
                    addLinPoly(*_npthVoidMaterial, xs, ys, axisIndex("z"), offset - thickness, thickness, 5);
                }
            }
        }
        logDebug("Added substrate from " + std::to_string(offset) + " to " +
                 std::to_string(offset - thickness));
        offset -= thickness;
    }
}

// Dissipative edge termination (Novak, IEEE Trans. Adv. Packaging 22(3), 1999) of every
// SimulationConfig::edgeTerminatedNets() net where the cut crosses it. A plane pair's TEM wave
// impedance is eta0/sqrt(epsR) regardless of the gap, so a vertical resistive sheet of that sheet
// resistance at the cut absorbs normally incident plane-pair waves as if the plane carried on. The
// sheet is a band of conductive dielectric (width w = SlicedBoard::edgeTerminationWidth, so
// sigma = sqrt(epsR)/(eta0*w)) filling each substrate directly above and below the terminated copper,
// i.e. from that copper to the neighbouring metal layers -- normally the ground planes it's
// referenced to.
void Simulation::addEdgeTerminations() {
    const auto& loopsPerLayer = _slicedBoard.edgeTerminationLoops;
    const double widthSimUnits = _slicedBoard.edgeTerminationWidth;
    if (loopsPerLayer.empty() || widthSimUnits <= 0) {
        return;
    }
    const double widthMetres = widthSimUnits * constants::baseUnit / constants::unitMultiplier;
    constexpr double eta0 = 376.730313668;

    struct StackEntry {
        LayerKind kind;
        std::size_t index; // into getMetals() or getSubstrates()
        double top;        // z of the upper face, simulation units
        double thickness;
    };
    std::vector<StackEntry> stack;
    std::size_t metalIndex = 0;
    std::size_t substrateIndex = 0;
    double offset = 0;
    for (const auto& layer : _config.layers()) {
        if (layer.kind() == LayerKind::Metal) {
            stack.push_back({LayerKind::Metal, metalIndex++, offset, 0});
        } else if (layer.kind() == LayerKind::Substrate) {
            stack.push_back({LayerKind::Substrate, substrateIndex++, offset, layer.thickness()});
            offset -= layer.thickness();
        }
    }
    const auto substrates = _config.getSubstrates();

    std::size_t sheets = 0;
    for (std::size_t position = 0; position < stack.size(); ++position) {
        const StackEntry& metal = stack[position];
        if (metal.kind != LayerKind::Metal || metal.index >= loopsPerLayer.size() ||
            loopsPerLayer[metal.index].empty()) {
            continue;
        }
        for (const std::size_t neighbour : {position - 1, position + 1}) {
            if (neighbour >= stack.size() || stack[neighbour].kind != LayerKind::Substrate) {
                continue; // outermost copper: nothing to terminate against on that side
            }
            const StackEntry& dielectric = stack[neighbour];
            const LayerConfig& substrate = substrates.at(dielectric.index);
            const double kappa = _lossTangentToKappa(substrate.epsilon(), substrate.lossTangent()) +
                                 std::sqrt(substrate.epsilon()) / (eta0 * widthMetres);
            CSPropMaterial* sheet =
                addMaterial(*_csx, "EdgeTermination_" + std::to_string(metal.index) + "_" + std::to_string(neighbour),
                            substrate.epsilon(), kappa);
            const double bottom = dielectric.top - dielectric.thickness;
            for (const Cu::Polygon& loop : loopsPerLayer[metal.index]) {
                std::vector<double> xs;
                std::vector<double> ys;
                xs.reserve(loop.size());
                ys.reserve(loop.size());
                for (const Position& point : loop) {
                    xs.push_back(point.x());
                    ys.push_back(point.y());
                }
                // Holes (antipads etc.) get the plain substrate back at a higher priority.
                const bool hole = !Cu::isPositive(loop);
                addLinPoly(hole ? *_substrateMaterials[dielectric.index] : *sheet, xs, ys, axisIndex("z"), bottom,
                           dielectric.thickness, hole ? 2 : 1);
            }
            ++sheets;
        }
    }
    logInfo("Added " + std::to_string(sheets) + " edge-termination sheet(s), width " +
            std::to_string(widthSimUnits) + " sim units");
}

void Simulation::addSolderMask() {
    const auto masks = _config.getSolderMasks();
    if (masks.empty()) {
        return;
    }
    logInfo("Adding solder mask");
    // Bottom mask sits just past the last copper layer's own Z -- same "sum every substrate's
    // thickness" computation addNPTHHoles() already does for that same Z (see its own doc comment).
    double substrateThickness = 0;
    for (const auto& layer : _config.getSubstrates()) {
        substrateThickness += layer.thickness();
    }
    for (const auto& mask : masks) {
        const bool isTop = mask.kind() == LayerKind::SolderMaskTop;
        const std::vector<std::vector<Position>>& openingLoops =
            isTop ? _slicedBoard.topMaskOpeningLoops : _slicedBoard.bottomMaskOpeningLoops;
        const std::vector<Triangle>& coverageTriangles =
            isTop ? _slicedBoard.topMaskTriangles : _slicedBoard.bottomMaskTriangles;
        if (coverageTriangles.empty()) {
            // No mask gerber for this side, or it composited to nothing -- see
            // board_slicing.cpp's own graceful-skip handling.
            continue;
        }
        // Top mask sits above F.Cu (Z=0, extruding toward +Z); bottom mask sits below the last
        // copper layer (extruding further away from Z=0, i.e. more negative still).
        const double elevation = isTop ? 0.0 : -substrateThickness - mask.thickness();
        const double length = mask.thickness();
        const double kappa = _lossTangentToKappa(mask.epsilon(), mask.lossTangent());
        CSProperties* material =
            addMaterial(*_csx, isTop ? "SolderMaskTop" : "SolderMaskBottom", mask.epsilon(), kappa);
        _solderMaskMaterials.push_back(material);
        // A small set of primitives for the *whole* coverage area -- this simulation's true cutout
        // loops (including disjoint pieces and holes), not a bounding-box rectangle: a tighter outer shape means fewer
        // quarter-cells even have a candidate reason to evaluate this primitive at all outside the
        // real board area (e.g. past a rounded/notched edge), on top of the primitive-count win
        // below. Every individual pad/via opening is then punched out via a small number of
        // higher-priority vacuum cutouts -- exactly addNPTHHoles()'s own established technique, not
        // the far more expensive "extrude every already-triangulated coverage-minus-holes triangle
        // as its own CSXCAD primitive" this used to do. That approach was geometrically equivalent
        // but made openEMS's own per-cell effective-material averaging dramatically slower (confirmed
        // via its own profiler): every extra small primitive gets checked at every quarter-cell query
        // across the *entire* mesh, not just near where it actually sits, so primitive count matters
        // far more than which of these two equivalent shapes is used. Priority 2: above substrate
        // (negative), so a query exactly at their shared Z=0 boundary resolves to mask rather than
        // raw substrate; below via priorities (50/51) so a real via barrel still correctly punches
        // through the modeled mask at its own footprint; and -- critically -- below copper's own
        // priority (10, not 1: raised specifically for this). Copper is a zero-thickness sheet at
        // Z=0, exactly the mask's own lower boundary, so the two primitives *do* coincide there
        // despite occupying disjoint Z ranges everywhere else. CalcPEC_Range() resolves PEC/PMC
        // edges via the *same* priority-ordered search across MATERIAL and METAL primitives
        // together (CSXCAD/ContinuousStructure.cpp's primList-based GetPropertyByCoordPriority()),
        // so if this dielectric mask ever outranked copper at that shared boundary, real copper
        // traces would stop being resolved as PEC everywhere the mask covers them (i.e. everywhere
        // except punched pad/via openings) -- exactly what caused the "signal never leaves the pad"
        // regression this priority was raised to fix.
        std::vector<std::vector<Position>> fallbackCutoutLoops;
        const std::vector<std::vector<Position>>* cutoutLoops = &_slicedBoard.cutoutLoops;
        if (cutoutLoops->empty()) {
            fallbackCutoutLoops.push_back(_slicedBoard.outline);
            cutoutLoops = &fallbackCutoutLoops;
        }
        for (const auto& loop : *cutoutLoops) {
            std::vector<double> xs, ys;
            xs.reserve(loop.size());
            ys.reserve(loop.size());
            for (const Position& point : loop) {
                xs.push_back(point.x());
                ys.push_back(point.y());
            }
            const bool filled = Cu::isPositive(loop);
            addLinPoly(filled ? *material : *_npthVoidMaterial, xs, ys, axisIndex("z"), elevation, length,
                       filled ? 2 : 3);
        }
        for (const std::vector<Position>& loop : openingLoops) {
            std::vector<double> xs;
            std::vector<double> ys;
            xs.reserve(loop.size());
            ys.reserve(loop.size());
            for (const Position& point : loop) {
                xs.push_back(point.x());
                ys.push_back(point.y());
            }
            addLinPoly(*_npthVoidMaterial, xs, ys, axisIndex("z"), elevation, length, 3);
        }
        logDebug("Added " + std::string(isTop ? "top" : "bottom") + " solder mask from " +
                 std::to_string(elevation) + " to " + std::to_string(elevation + length) + " with " +
                 std::to_string(openingLoops.size()) + " opening(s)");
    }
}

std::expected<void, std::string> Simulation::addVias() {
    logInfo("Adding vias from KiCad board geometry");
    auto originResult = _boardOrigin(_board);
    if (!originResult) {
        return std::unexpected(originResult.error());
    }
    auto viasResult = getVias(_board, originResult->first, originResult->second);
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
            // of that layer's copper geometry read directly from KiCad) -- this outer
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
        // A degenerate (<3-point) loop can fall out of the intersection at a boundary that
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
    addBox(*dump, {_slicedBoard.bounds.xMin - margin, _slicedBoard.bounds.yMin - margin, z},
           {_slicedBoard.bounds.xMax + margin, _slicedBoard.bounds.yMax + margin, z});
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
    // saved geometry from, and which port to excite.
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

std::expected<void, std::string> Simulation::prepareRunDirectory(std::int32_t excitedPortNumber) {
    const std::filesystem::path simPath = _paths.simulationDir / _simConfig.name() / std::to_string(excitedPortNumber);
    std::error_code dirEc;
    std::filesystem::create_directories(simPath, dirEc);
    if (dirEc) {
        return std::unexpected("Failed to create simulation directory: " + dirEc.message());
    }
    std::filesystem::current_path(simPath);

    return {};
}

std::expected<Simulation::PortParameters, std::string> Simulation::getPortParameters(
    std::int32_t exIndex, const std::vector<double>& frequencies) {
    const std::filesystem::path resultPath = _paths.simulationDir / _simConfig.name() / std::to_string(exIndex);
    const std::vector<std::complex<double>> naNPlaceholder(frequencies.size(),
                                                             std::complex<double>(std::numeric_limits<double>::quiet_NaN(),
                                                                                    std::numeric_limits<double>::quiet_NaN()));

    PortParameters params;
    for (std::size_t index = 0; index < _ports.size(); ++index) {
        const bool absorbs = _simConfig.ports()[index].absorbSignal();
        if (absorbs) {
            if (auto result = _ports[index]->calcPort(resultPath, frequencies); !result) {
                return std::unexpected("Port data files do not exist. Did you run simulation step? (" +
                                        result.error() + ")");
            }
            params.incident.push_back(_ports[index]->ufInc());
            params.reflected.push_back(_ports[index]->ufRef());
        } else {
            // A passive probe has no incident/reflected split (see PortConfig::absorbSignal()'s own
            // doc comment) -- readUiData() alone is enough for its real data (ufTot()/ifTot()),
            // pushed separately below; the placeholder here only keeps every other port-index-
            // aligned vector the right length.
            if (auto result = _ports[index]->readUiData(resultPath, frequencies); !result) {
                return std::unexpected("Probe data files do not exist. Did you run simulation step? (" +
                                        result.error() + ")");
            }
            params.incident.push_back(naNPlaceholder);
            params.reflected.push_back(naNPlaceholder);
            params.probeVoltage.emplace(static_cast<std::int32_t>(index), _ports[index]->ufTot());
            params.probeCurrent.emplace(static_cast<std::int32_t>(index), _ports[index]->ifTot());
            if (_simConfig.ports()[index].isTraceProbe()) {
                params.probeImpedance.emplace(static_cast<std::int32_t>(index), _ports[index]->zRef());
            }
        }
        logDebug("Found data for port " + std::to_string(index));
    }
    return params;
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

std::expected<void, std::string> Simulation::addLumpedComponents() {
    auto& components = _simConfig.lumpedComponents();
    if (components.empty()) {
        return {};
    }
    logInfo("Adding " + std::to_string(components.size()) + " auto-discovered lumped component(s)");

    // direction is the pad1->pad2 angle in file-frame degrees (0/180 => horizontal => x, 90/270 =>
    // vertical => y); it must match the box's long axis below, otherwise Operator_Ext_LumpedRLC
    // snaps the box to zero length along the "current" axis and drops it.
    static const std::map<std::int32_t, std::string> dirMap = {{0, "x"}, {90, "y"}, {180, "x"}, {270, "y"}};

    for (const auto& component : components) {
        if (component.cornerBridge()) {
            // Non-cardinally-aligned 2-pin component (see LumpedComponentConfig::cornerBridge()'s own
            // doc comment): an L-shaped route through a synthetic corner, each leg individually
            // cardinal-aligned -- but routed entirely through open airspace a small distance above (or
            // below, for a bottom-layer part) the board, connected to each real pad by a short
            // vertical PEC pillar, rather than running along the board's own copper layer. A board-
            // layer route would need to avoid every *other* net's own copper on that layer to not
            // accidentally connect into it -- workable for isolated pads/tracks, but a real board very
            // commonly has a ground pour covering most of a layer near any given component, which
            // would make that check fail almost everywhere. Nothing else this codebase places ever
            // occupies the airspace just above/below the board, so the horizontal bridge itself needs
            // no interference check at all; only the two short pillars, confined to each pad's own
            // (x, y) footprint, could conceivably need one, and since that's already legitimately this
            // component's own territory there's nothing new to check there either. This also happens
            // to be more physically realistic than a flush 2D bridge: a real 2-pin SMD part's own body
            // genuinely does sit above the board surface, connected down to its pads by solder.
            const auto zResult = getMetalLayerOffset(component.layer());
            if (!zResult) {
                return std::unexpected(zResult.error());
            }
            const double padZ = std::round(*zResult);
            const double bridgeZ = _cornerBridgeZ(padZ, component.layer());
            logInfo("Simulation: corner-bridge for " + component.reference() + ": layer=" +
                     std::to_string(component.layer()) + " padZ=" + std::to_string(padZ) +
                     " bridgeZ=" + std::to_string(bridgeZ) + " pos1=(" + std::to_string(component.position1().first) +
                     "," + std::to_string(component.position1().second) + ") pos2=(" +
                     std::to_string(component.position2().first) + "," + std::to_string(component.position2().second) +
                     ") corner=(" + std::to_string(component.bridgeCorner().first) + "," +
                     std::to_string(component.bridgeCorner().second) + ") width=" + std::to_string(component.width()));

            const auto buildPillar = [&](const std::string& suffix, std::pair<double, double> at) {
                const double width = component.width();
                const Point3 start = {std::round(at.first - width / 2.0), std::round(at.second - width / 2.0),
                                        std::min(padZ, bridgeZ)};
                const Point3 stop = {std::round(at.first + width / 2.0), std::round(at.second + width / 2.0),
                                       std::max(padZ, bridgeZ)};
                CSPropMetal* wire = addMetal(*_csx, "LumpedBridgePillar_" + component.reference() + "_" + suffix);
                addBox(*wire, start, stop, 100);
            };
            const auto buildLeg = [&](std::pair<double, double> from, std::pair<double, double> to, double direction,
                                       bool carriesComponent) -> std::expected<void, std::string> {
                std::int32_t dir = static_cast<std::int32_t>(direction);
                while (dir < 0) {
                    dir += 360;
                }
                const auto dirIt = dirMap.find(dir);
                if (dirIt == dirMap.end()) {
                    return std::unexpected("Lumped component " + component.reference() +
                                            "'s corner-bridge leg direction is not a multiple of 90 degrees");
                }
                const std::int32_t axisIndex = dirIt->second == "x" ? 0 : 1;
                const double angle = direction / 360.0 * 2 * M_PI;
                const double width = component.width();
                const auto [x1, y1] = from;
                const auto [x2, y2] = to;
                // See the plain cardinal case below for why this uses the perpendicular vector.
                const double halfWidthX = std::abs(std::round(std::sin(angle))) * width / 2.0;
                const double halfWidthY = std::abs(std::round(std::cos(angle))) * width / 2.0;
                const Point3 start = {
                    std::round(std::min(x1, x2) - halfWidthX),
                    std::round(std::min(y1, y2) - halfWidthY),
                    bridgeZ,
                };
                const Point3 stop = {
                    std::round(std::max(x1, x2) + halfWidthX),
                    std::round(std::max(y1, y2) + halfWidthY),
                    bridgeZ,
                };
                if (carriesComponent) {
                    CSPropLumpedElement* prop =
                        addLumpedElement(*_csx, "Lumped_" + component.reference(), axisIndex,
                                          /*caps=*/false, component.resistance(), CSPropLumpedElement::SERIES,
                                          component.inductance(), component.capacitance());
                    addBox(*prop, start, stop, 100);
                } else {
                    CSPropMetal* wire = addMetal(*_csx, "LumpedBridgeWire_" + component.reference());
                    addBox(*wire, start, stop, 100);
                }
                return {};
            };
            buildPillar("A", component.position1());
            buildPillar("B", component.position2());
            if (auto result =
                    buildLeg(component.position1(), component.bridgeCorner(), component.direction(), true);
                !result) {
                return std::unexpected(result.error());
            }
            if (auto result =
                    buildLeg(component.bridgeCorner(), component.position2(), component.direction2(), false);
                !result) {
                return std::unexpected(result.error());
            }
            continue;
        }

        std::int32_t direction = static_cast<std::int32_t>(component.direction());
        while (direction < 0) {
            direction += 360;
        }
        const auto dirIt = dirMap.find(direction);
        if (dirIt == dirMap.end()) {
            logError("Lumped component " + component.reference() + "'s direction is not a multiple of 90 degrees, skipping");
            continue;
        }
        const std::int32_t axisIndex = dirIt->second == "x" ? 0 : 1;

        const auto zResult = getMetalLayerOffset(component.layer());
        if (!zResult) {
            return std::unexpected(zResult.error());
        }
        const double z = std::round(*zResult);
        const double angle = component.direction() / 360.0 * 2 * M_PI;
        const double width = component.width();
        const auto [x1, y1] = component.position1();
        const auto [x2, y2] = component.position2();

        // `width` is transverse to the pad1->pad2/current axis. The old code multiplied it by
        // (cos(angle), sin(angle)), extending the box beyond each pad *along* that axis while
        // leaving its transverse extent at zero. After mesh snapping that produced nCells1 ==
        // nCells2 == 1, so only one Yee edge received the lumped correction even when the real pad
        // spanned several parallel edges. Use the perpendicular vector, and form normalized bounds
        // so 180/270-degree components are handled without relying on CSPrimBox to reorder them.
        const double halfWidthX = std::abs(std::round(std::sin(angle))) * width / 2.0;
        const double halfWidthY = std::abs(std::round(std::cos(angle))) * width / 2.0;
        const Point3 start = {
            std::round(std::min(x1, x2) - halfWidthX),
            std::round(std::min(y1, y2) - halfWidthY),
            z,
        };
        const Point3 stop = {
            std::round(std::max(x1, x2) + halfWidthX),
            std::round(std::max(y1, y2) + halfWidthY),
            z,
        };

        double resistance = component.resistance();
        double inductance = component.inductance();
        double capacitance = component.capacitance();
        logDebug("Adding lumped " +
                 std::string(component.type() == LumpedComponentType::Resistor   ? "resistor"
                             : component.type() == LumpedComponentType::Inductor ? "inductor"
                                                                                  : "capacitor") +
                 " " + component.reference() + " at start: " + _point3ToString(start) +
                 " end: " + _point3ToString(stop));
        CSPropLumpedElement* prop = addLumpedElement(*_csx, "Lumped_" + component.reference(), axisIndex,
                                                       /*caps=*/false, resistance, CSPropLumpedElement::SERIES,
                                                       inductance, capacitance);
        addBox(*prop, start, stop, 100);
    }
    return {};
}

std::expected<void, std::string> Simulation::addPassiveProbe(PortConfig& portConfig, std::int32_t portNumber) {
    logDebug("Adding port number " + std::to_string(_ports.size()));
    if (!portConfig.position().has_value() || !portConfig.direction().has_value()) {
        logError("Port has no defined position or rotation, skipping");
        return {};
    }

    // Same vertical (trace layer -> reference plane) span addResistivePort() uses, not
    // addMslPort()'s horizontal one -- a passive probe reads trace-to-plane voltage and
    // along-trace current at a single point, the same measurement convention LumpedPort's own U/I
    // probes already establish, not MSLPort's multi-point characteristic-impedance scheme (which
    // exists solely to normalize S-parameters, meaningless for a probe that computes none).
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

    // See addResistivePort()'s own comment on why true (not rounded-to-cardinal) sin/cos is correct
    // here: `direction` is the pad's own real rotation, not necessarily a multiple of 90 degrees.
    const Point3 start = {
        std::round(posX - (width / 2) * std::cos(angle)),
        std::round(posY - (width / 2) * std::sin(angle)),
        std::round(startZ),
    };
    const Point3 stop = {
        std::round(posX + (width / 2) * std::cos(angle)),
        std::round(posY - (width / 2) * std::sin(angle)),
        std::round(stopZ),
    };

    logDebug("Adding passive probe at start: " + _point3ToString(start) + " end: " + _point3ToString(stop));
    _ports.push_back(std::make_unique<PassiveProbe>(*_csx, portNumber, start, stop, "z", 100));
    return {};
}

std::expected<void, std::string> Simulation::addPorts() {
    logInfo("Adding ports");
    _ports.clear();
    auto& ports = _simConfig.ports();
    for (std::size_t index = 0; index < ports.size(); ++index) {
        const auto portNumber = static_cast<std::int32_t>(index);
        // isTraceProbe() is checked first: a trace probe also has absorbSignal()==false (see
        // PortConfig::isTraceProbe()'s own doc comment) but needs MSLPort-style geometry, not
        // addPassiveProbe()'s pad-anchored one. Otherwise, absorbSignal()==false means no metal/
        // resistor termination at all -- a passive read-only probe. port_resolution.cpp guarantees
        // excite() is never true here when absorbSignal() is false, so this check alone is enough.
        std::expected<void, std::string> result;
        if (ports[index].isTraceProbe()) {
            result = addImpedanceProbe(ports[index], portNumber);
        } else if (ports[index].absorbSignal()) {
            // Component-facing ports model the attached component impedance at its pad. Their S
            // parameters are therefore normalized to that explicit resistance by LumpedPort,
            // independently of the trace-impedance MSL probes placed farther down the route.
            result = addResistivePort(ports[index], portNumber, ports[index].excite());
        } else {
            result = addPassiveProbe(ports[index], portNumber);
        }
        if (!result) {
            return result;
        }
    }
    return {};
}

} // namespace kiems
