#include "simulation.hpp"

#include <algorithm>
#include <array>
#include <cerrno>
#include <chrono>
#include <cmath>
#include <cstdlib>
#include <cstdio>
#include <cstring>
#include <fstream>
#include <limits>
#include <map>
#include <set>
#include <span>
#include <sstream>
#include <utility>

#include <spawn.h>
#include <sys/wait.h>

#include <nlohmann/json.hpp>

#include "constants.hpp"
#include "csx_grid_utils.hpp"
#include "libkicad/libkicad.hpp"
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

// A conformally modelled via is a solid prism with this many sides: the cut fractions Copper
// derives from it then see the true circle (its area within 0.2%), not the 12-sided outline that is
// plenty for rasterising nodes.
constexpr std::int32_t kConformalViaSegments = 64;
// Copper's own attribute names (CopperOperator::kConformalAttribute/kThinWireRadiusAttribute) --
// spelled out here because libkiems never depends on Copper itself.
constexpr const char* kCopperConformalAttribute = "copper:conformal";
constexpr const char* kCopperThinWireRadiusAttribute = "copper:thin_wire_radius";
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

// Shortest distance from (x, y) to the segment (x1, y1)-(x2, y2), which may be a single point.
double _distanceToSegment(double x, double y, double x1, double y1, double x2, double y2) {
    const double dx = x2 - x1;
    const double dy = y2 - y1;
    const double lengthSquared = dx * dx + dy * dy;
    const double t =
        lengthSquared > 0 ? std::clamp(((x - x1) * dx + (y - y1) * dy) / lengthSquared, 0.0, 1.0) : 0.0;
    return std::hypot(x - (x1 + t * dx), y - (y1 + t * dy));
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
                                                                    double diameter, bool reversed,
                                                                    std::int32_t segments = constants::viaPolygon) {
    const double radius = diameter / 2;
    std::vector<double> xs;
    std::vector<double> ys;

    if (x1 == x2 && y1 == y2) {
        for (std::int32_t step = 0; step < segments; ++step) {
            const std::int32_t i = reversed ? segments - 1 - step : step;
            const double angle = static_cast<double>(i) / segments * 2 * M_PI;
            xs.push_back(x1 + std::sin(angle) * radius);
            ys.push_back(y1 + std::cos(angle) * radius);
        }
        return {xs, ys};
    }

    const double lineAngle = std::atan2(y2 - y1, x2 - x1);
    const std::int32_t halfSegments = std::max(std::int32_t{1}, segments / 2);
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
      _conformalViaMaterial(nullptr),
      _npthVoidMaterial(nullptr) {
    _grid = _csx->GetGrid();
    _grid->SetDeltaUnit(constants::baseUnit / constants::unitMultiplier);

    _planeMaterial = addMetal(*_csx, "Plane");
    _conformalViaMaterial = addMetal(*_csx, "Via");
    _conformalViaMaterial->SetAttributeValue(kCopperConformalAttribute, "1");
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

        // A return bridge's pillars and legs are built later, in addReturnBridgePort(), so reserve
        // both heights its pillars span now. They need no X/Y density of their own: each pillar
        // stands on a real pad, whose copper edges already put mesh lines through it, and the legs
        // run along those pads' rows and columns. A square per pillar adds edge cells inside every
        // pad instead; on HorizonPC that was 2% more cells and a 9% shorter time step, for no node
        // the pads hadn't already placed. addReturnBridgePort() warns if a pillar ever misses one.
        if (!portConfig.returnBridge().has_value()) continue;
        const auto geometry = returnBridgeGeometry(portConfig);
        if (!geometry) {
            logWarning("Simulation: couldn't place return-bridge density for port " + portConfig.name() + ": " +
                       geometry.error());
            continue;
        }
        _gridGen->additionalZHeights().push_back(geometry->padZ);
        _gridGen->additionalZHeights().push_back(geometry->bridgeZ);
    }
}

namespace {

CSPropLumpedElement::LEtype _lumpedType(const LumpedComponentConfig& component) {
    return component.topology() == LumpedComponentTopology::Series ? CSPropLumpedElement::SERIES
                                                                   : CSPropLumpedElement::PARALLEL;
}

} // namespace

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
            logWarning("Simulation: couldn't resolve corner-bridge component " + component.name() +
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

std::expected<std::pair<Point3, Point3>, std::string> Simulation::padColumn(const PortConfig& portConfig) {
    if (!portConfig.position().has_value() || !portConfig.direction().has_value()) {
        return std::unexpected("Port " + portConfig.name() + " has no defined position or rotation");
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

    return std::pair<Point3, Point3>{start, stop};
}

std::expected<void, std::string> Simulation::addLoadCapacitor(const PortConfig& portConfig) {
    const auto column = padColumn(portConfig);
    if (!column) {
        return std::unexpected(column.error());
    }
    const auto& [start, stop] = *column;
    const double capacitance = portConfig.loadCapacitance();
    logInfo("Adding " + std::to_string(capacitance * 1e12) + " pF load capacitance at " + portConfig.name());
    // R and L NaN mark them absent (see LumpedComponentConfig), leaving a pure capacitor.
    CSPropLumpedElement* prop = addLumpedElement(*_csx, "Load_" + portConfig.name(), axisIndex("z"), /*caps=*/false,
                                                   std::nan(""), CSPropLumpedElement::PARALLEL, std::nan(""),
                                                   capacitance);
    addBox(*prop, start, stop, 100);
    return {};
}

std::expected<Simulation::ReturnBridgeGeometry, std::string> Simulation::returnBridgeGeometry(
    const PortConfig& portConfig) {
    if (!portConfig.position().has_value() || !portConfig.returnBridge().has_value()) {
        return std::unexpected("Port " + portConfig.name() + " has no return bridge to build");
    }
    const auto zResult = getMetalLayerOffset(portConfig.layer());
    if (!zResult) {
        return std::unexpected(zResult.error());
    }
    const PortReturnBridge& bridge = *portConfig.returnBridge();
    ReturnBridgeGeometry geometry;
    geometry.padZ = std::round(*zResult);
    // The same airspace a diagonal lumped component's corner bridge uses, and for the same reason:
    // nothing else is ever placed there, so the element can't touch another net's copper on the way.
    geometry.bridgeZ = _cornerBridgeZ(geometry.padZ, portConfig.layer());
    // The element keeps the pin's own row or column, and ends at the corner or level with the return
    // pad, inside its pillar.
    const auto [x, y] = *portConfig.position();
    const auto [farX, farY] = bridge.corner.value_or(bridge.position);
    const double half = bridge.width / 2;
    if (std::abs(farX - x) >= std::abs(farY - y)) {
        geometry.axis = "x";
        geometry.elementStart = {std::round(x), std::round(y - half), geometry.bridgeZ};
        geometry.elementStop = {std::round(farX), std::round(y + half), geometry.bridgeZ};
    } else {
        geometry.axis = "y";
        geometry.elementStart = {std::round(x - half), std::round(y), geometry.bridgeZ};
        geometry.elementStop = {std::round(x + half), std::round(farY), geometry.bridgeZ};
    }
    return geometry;
}

std::expected<void, std::string> Simulation::addReturnBridgePort(PortConfig& portConfig, std::int32_t portNumber) {
    const auto geometry = returnBridgeGeometry(portConfig);
    if (!geometry) {
        return std::unexpected(geometry.error());
    }
    const PortReturnBridge& bridge = *portConfig.returnBridge();
    const double half = bridge.width / 2;
    const std::string name = "PortBridge_" + std::to_string(portNumber);
    const auto pillar = [&](const std::string& suffix, std::pair<double, double> at) {
        CSPropMetal* metal = addMetal(*_csx, name + "_pillar_" + suffix);
        const double bottom = std::min(geometry->padZ, geometry->bridgeZ);
        const double top = std::max(geometry->padZ, geometry->bridgeZ);
        addBox(*metal, {std::round(at.first - half), std::round(at.second - half), bottom},
               {std::round(at.first + half), std::round(at.second + half), top}, 100);
    };
    // A pillar conducts only through a mesh node inside it. The element and the leg run along the
    // two pillars' rows and columns (the corner shares one coordinate with each), so a node in
    // both pillars connects the whole bridge.
    const auto missesNode = [&](std::pair<double, double> at) {
        for (int axis = 0; axis < 2; ++axis) {
            const double centre = axis == 0 ? at.first : at.second;
            unsigned int count = 0;
            double* lines = _grid->GetLines(axis, nullptr, count, true);
            const bool found = std::any_of(lines, lines + count, [&](double line) {
                return line >= std::round(centre - half) && line <= std::round(centre + half);
            });
            delete[] lines;
            if (!found) return true;
        }
        return false;
    };
    const auto mm = [](double simUnits) { return simUnits * constants::baseUnit / constants::unitMultiplier * 1e3; };
    for (const auto& [end, at] : {std::pair{"pin", *portConfig.position()}, std::pair{"return pad", bridge.position}}) {
        if (missesNode(at)) {
            logWarning("Port " + portConfig.name() + ": no mesh node inside its return bridge's pillar on the " + end +
                       " near (" + std::to_string(mm(at.first)) + ", " + std::to_string(mm(at.second)) +
                       ") mm, so the bridge stays open there");
        }
    }
    pillar("pad", *portConfig.position());
    pillar("return", bridge.position);
    if (bridge.corner.has_value()) {
        // Overlaps the corner and the return pillar by a half-width, so the pieces share cells
        // however the mesh snaps them.
        const auto [cornerX, cornerY] = *bridge.corner;
        const auto [returnX, returnY] = bridge.position;
        CSPropMetal* leg = addMetal(*_csx, name + "_return_leg");
        addBox(*leg,
               {std::round(std::min(cornerX, returnX) - half), std::round(std::min(cornerY, returnY) - half),
                geometry->bridgeZ},
               {std::round(std::max(cornerX, returnX) + half), std::round(std::max(cornerY, returnY) + half),
                geometry->bridgeZ},
               100);
    }

    const Point3& start = geometry->elementStart;
    const Point3& stop = geometry->elementStop;
    logDebug("Adding return-bridged port " + portConfig.name() + " to pin " + bridge.padNumber + " at start: " +
             _point3ToString(start) + " end: " + _point3ToString(stop));
    if (portConfig.absorbSignal()) {
        _ports.push_back(std::make_unique<LumpedPort>(*_csx, portNumber, portConfig.impedance(), start, stop,
                                                        geometry->axis, portConfig.excite() ? 1.0 : 0.0, 100));
        return {};
    }
    _ports.push_back(std::make_unique<PassiveProbe>(*_csx, portNumber, start, stop, geometry->axis, 100));
    if (portConfig.loadCapacitance() > 0) {
        logInfo("Adding " + std::to_string(portConfig.loadCapacitance() * 1e12) +
                " pF load capacitance across the return bridge at " + portConfig.name());
        CSPropLumpedElement* load = addLumpedElement(*_csx, "Load_" + portConfig.name(), axisIndex(geometry->axis),
                                                       /*caps=*/false, std::nan(""), CSPropLumpedElement::PARALLEL,
                                                       std::nan(""), portConfig.loadCapacitance());
        addBox(*load, start, stop, 100);
    }
    return {};
}

std::expected<void, std::string> Simulation::addResistivePort(PortConfig& portConfig, std::int32_t portNumber,
                                                                bool excite) {
    logDebug("Adding port number " + std::to_string(_ports.size()));
    if (!portConfig.position().has_value() || !portConfig.direction().has_value()) {
        logError("Port has no defined position or rotation, skipping");
        return {};
    }

    const auto column = padColumn(portConfig);
    if (!column) {
        return std::unexpected(column.error());
    }
    const auto& [start, stop] = *column;

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

ViaConductionPlan planViaConduction(const MeshLinesXY& mesh, double x1, double y1, double x2, double y2,
                                    double outerDiameter, double padDiameter) {
    const auto [outerXs, outerYs] = _viaPolygon(x1, y1, x2, y2, outerDiameter, true, kConformalViaSegments);
    std::vector<Position> outer;
    for (std::size_t i = 0; i < outerXs.size(); ++i) outer.emplace_back(outerXs[i], outerYs[i]);
    const auto linesNear = [](const std::vector<double>& lines, double lo, double hi) {
        return std::span<const double>(std::lower_bound(lines.begin(), lines.end(), lo),
                                       std::upper_bound(lines.begin(), lines.end(), hi));
    };
    const auto nodesWithin = [&](double radius) {
        return std::pair{linesNear(mesh[0], std::min(x1, x2) - radius, std::max(x1, x2) + radius),
                         linesNear(mesh[1], std::min(y1, y2) - radius, std::max(y1, y2) + radius)};
    };

    // The same node-centred test Copper applies to every Z edge.
    const auto [xs, ys] = nodesWithin(outerDiameter / 2);
    for (const double x : xs) {
        for (const double y : ys) {
            if (_pointInPolygon(x, y, outer)) return {ViaConduction::Conformal, std::nullopt};
        }
    }

    const double padRadius = std::max(padDiameter, outerDiameter) / 2;
    const auto [nearXs, nearYs] = nodesWithin(padRadius);
    std::optional<std::pair<double, double>> nearest;
    double nearestDistance = padRadius;
    for (const double x : nearXs) {
        for (const double y : nearYs) {
            const double distance = _distanceToSegment(x, y, x1, y1, x2, y2);
            if (distance < nearestDistance) {
                nearestDistance = distance;
                nearest = {x, y};
            }
        }
    }
    if (!nearest.has_value()) return {ViaConduction::Open, std::nullopt};
    return {ViaConduction::ThinWire, nearest};
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
    MeshLinesXY mesh;
    for (int axis = 0; axis < 2; ++axis) {
        unsigned int count = 0;
        double* lines = _grid->GetLines(axis, nullptr, count, true);
        mesh[static_cast<std::size_t>(axis)].assign(lines, lines + count);
        delete[] lines;
    }
    std::map<ViaConduction, std::size_t> conduction;
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
            const ViaConduction result = addVia(mesh, via.x, via.y, via.x2, via.y2, outerDiameter, via.padDiameter,
                                                /*cropToOutline=*/true);
            ++conduction[result];
            if (result == ViaConduction::Open) {
                logWarning("Simulation: the via at (" + std::to_string(via.x) + ", " + std::to_string(via.y) +
                           ") has no mesh node on it or its pad, so it can't conduct between its layers");
            }
        }
    }
    logInfo("Vias: " + std::to_string(conduction[ViaConduction::Conformal]) + " modelled as conformal cylinders, " +
            std::to_string(conduction[ViaConduction::ThinWire]) + " as thin wires; " +
            std::to_string(conduction[ViaConduction::Open]) + " stay open");

    logInfo("Adding " + std::to_string(_slicedBoard.stitchingVias.size()) +
            " ground-net stitching via(s) from board slicing");
    for (const auto& via : _slicedBoard.stitchingVias) {
        // Unlike a real via, a stitching via has no copper pad modeled anywhere else -- its outer
        // ring has to be the full annular ring diameter to serve as its own pad, not just a thin
        // conductive wall (see Via::stitchingViaAnnularRingDiameter's own doc comment). Always a
        // plain round hole -- this pipeline only ever invents round stitching vias, never oblong
        // ones.
        addVia(mesh, via.x, via.y, via.x, via.y, via.annularRingDiameter, via.annularRingDiameter);
    }
    return {};
}

ViaConduction Simulation::addVia(const MeshLinesXY& mesh, double xPos, double yPos, double x2Pos, double y2Pos,
                                 double outerDiameter, double padDiameter, bool cropToOutline) {
    double thickness = 0;
    for (const auto& layer : _config.getSubstrates()) {
        thickness += layer.thickness();
    }

    const ViaConductionPlan plan = planViaConduction(mesh, xPos, yPos, x2Pos, y2Pos, outerDiameter, padDiameter);
    if (plan.conduction == ViaConduction::Open) return plan.conduction;
    if (plan.conduction == ViaConduction::ThinWire) {
        // One node wide in X and Y, so only that node's own Z edges become metal; Copper gives the
        // edges around it Railton's parameters for the via's real radius.
        CSPropMetal* wire = addMetal(*_csx, "ViaThinWire_" + std::to_string(_csx->GetQtyProperties()));
        wire->SetAttributeValue(kCopperThinWireRadiusAttribute, std::to_string(outerDiameter / 2));
        constexpr double kHalf = 1.0;
        const auto [columnX, columnY] = *plan.column;
        addBox(*wire, {columnX - kHalf, columnY - kHalf, -thickness}, {columnX + kHalf, columnY + kHalf, 0.0}, 53);
        return plan.conduction;
    }

    // A solid cylinder of the barrel's outer diameter: nothing reaches inside a plated barrel at
    // these frequencies, so the drill, its filling and its caps don't change the fields outside.
    auto [xs, ys] = _viaPolygon(xPos, yPos, x2Pos, y2Pos, outerDiameter, true, kConformalViaSegments);
    if (!cropToOutline) {
        addLinPoly(*_conformalViaMaterial, xs, ys, axisIndex("z"), -thickness, thickness, 50);
        return plan.conduction;
    }
    // A degenerate (<3-point) loop can fall out of the intersection at a boundary that grazes the
    // via's disc only tangentially -- skipped rather than fed to addLinPoly, which expects a genuine
    // polygon.
    for (const auto& [loopXs, loopYs] : _clipPolygonToOutline(xs, ys, _slicedBoard.outline)) {
        if (loopXs.size() >= 3) {
            addLinPoly(*_conformalViaMaterial, loopXs, loopYs, axisIndex("z"), -thickness, thickness, 50);
        }
    }
    return plan.conduction;
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
    writeRunDiagnostics(simPath);

    return {};
}

std::vector<std::string> Simulation::writeMetalShortReport(const MetalRegionAt& regionAt,
                                                            const MetalRegionsIn& regionsIn,
                                                            const std::filesystem::path& directory) {
    const auto mm = [](double simUnits) { return simUnits * constants::baseUnit / constants::unitMultiplier * 1e3; };
    const auto where = [&](double x, double y) {
        std::ostringstream text;
        text << "(" << mm(x) << ", " << mm(y) << ") mm";
        return text.str();
    };

    // Label each region with the nets whose pads reach it: every pad-anchored port, and both pads of
    // every lumped component, on their own copper layer.
    std::map<std::uint32_t, std::set<std::string>> netsByRegion;
    std::map<std::uint32_t, std::string> regionLocation;
    const auto label = [&](std::int32_t layer, double x, double y, const std::string& net) {
        const auto z = getMetalLayerOffset(layer);
        if (!z || net.empty()) return;
        if (const auto region = regionAt({x, y, *z})) {
            netsByRegion[*region].insert(net);
            regionLocation.try_emplace(*region, where(x, y));
        }
    };
    const auto& ports = _simConfig.ports();
    for (const PortConfig& port : ports) {
        if (port.isTraceProbe() || !port.position().has_value()) continue;
        label(port.layer(), port.position()->first, port.position()->second, port.netName());
        if (const auto& bridge = port.returnBridge()) {
            label(port.layer(), bridge->position.first, bridge->position.second, bridge->netName);
        }
    }
    for (const LumpedComponentConfig& component : _simConfig.lumpedComponents()) {
        label(component.layer(), component.position1().first, component.position1().second, component.net1());
        label(component.layer(), component.position2().first, component.position2().second, component.net2());
    }

    std::vector<std::string> findings;
    const auto join = [](const std::set<std::string>& nets) {
        std::string text;
        for (const std::string& net : nets) text += (text.empty() ? "" : " + ") + net;
        return text;
    };
    for (const auto& [region, nets] : netsByRegion) {
        if (nets.size() > 1) {
            findings.push_back("Nets " + join(nets) + " share one piece of metal in the grid (near " +
                               regionLocation[region] + ")");
        }
    }
    // A terminal face may touch its own nets' metal and unlabelled metal (a plane, a floating
    // island); metal labelled only with other nets means the element is wired into the wrong net.
    const auto checkFace = [&](const std::string& element, const std::set<std::string>& own,
                               const std::array<double, 3>& start, const std::array<double, 3>& stop) {
        std::set<std::string> foreign;
        for (std::uint32_t region : regionsIn(start, stop)) {
            const auto nets = netsByRegion.find(region);
            if (nets == netsByRegion.end()) continue;
            bool sharesOwn = false;
            for (const std::string& net : nets->second) sharesOwn = sharesOwn || own.contains(net);
            if (!sharesOwn) foreign.insert(nets->second.begin(), nets->second.end());
        }
        if (!foreign.empty()) {
            findings.push_back(element + " (" + join(own) + ") also touches " + join(foreign) + " near " +
                               where((start[0] + stop[0]) / 2, (start[1] + stop[1]) / 2));
        }
    };
    for (const PortConfig& port : ports) {
        if (port.isTraceProbe() || !port.position().has_value()) continue;
        if (port.returnBridge().has_value()) {
            // The element's pin end must reach only the pin's metal, and its far end (the return
            // pillar, or the PEC leg at the corner) only the return pad's.
            const auto geometry = returnBridgeGeometry(port);
            if (!geometry) continue;
            const int axis = geometry->axis == "x" ? 0 : 1;
            std::array<double, 3> lo{}, hi{};
            for (std::size_t n = 0; n < 3; ++n) {
                lo[n] = std::min(geometry->elementStart[n], geometry->elementStop[n]);
                hi[n] = std::max(geometry->elementStart[n], geometry->elementStop[n]);
            }
            for (const bool pinEnd : {true, false}) {
                std::array<double, 3> faceLo = lo, faceHi = hi;
                const double end = pinEnd ? geometry->elementStart[static_cast<std::size_t>(axis)]
                                          : geometry->elementStop[static_cast<std::size_t>(axis)];
                faceLo[static_cast<std::size_t>(axis)] = faceHi[static_cast<std::size_t>(axis)] = end;
                checkFace("Port " + port.name() + (pinEnd ? "" : " return"),
                          {pinEnd ? port.netName() : port.returnBridge()->netName}, faceLo, faceHi);
            }
            continue;
        }
        const auto column = padColumn(port);
        if (!column) continue;
        // Only the pad end: the other end is the reference plane, which no net label covers.
        const auto& [start, stop] = *column;
        checkFace("Port " + port.name(), {port.netName()}, {start[0], start[1], start[2]},
                  {stop[0], stop[1], start[2]});
    }
    for (const LumpedComponentConfig& component : _simConfig.lumpedComponents()) {
        for (CSProperties* property : _csx->GetPropertiesByName("Lumped_" + component.name())) {
        auto* element = dynamic_cast<CSPropLumpedElement*>(property);
        if (element == nullptr) continue;
        const int axis = element->GetDirection();
        for (std::size_t p = 0; p < element->GetQtyPrimitives(); ++p) {
            CSPrimBox* box = element->GetPrimitive(p)->ToBox();
            if (box == nullptr || axis < 0 || axis > 2) continue;
            std::array<double, 3> lo{}, hi{};
            for (int n = 0; n < 3; ++n) {
                lo[static_cast<std::size_t>(n)] = std::min(box->GetCoord(2 * n), box->GetCoord(2 * n + 1));
                hi[static_cast<std::size_t>(n)] = std::max(box->GetCoord(2 * n), box->GetCoord(2 * n + 1));
            }
            for (const double end : {lo[static_cast<std::size_t>(axis)], hi[static_cast<std::size_t>(axis)]}) {
                std::array<double, 3> faceLo = lo, faceHi = hi;
                faceLo[static_cast<std::size_t>(axis)] = faceHi[static_cast<std::size_t>(axis)] = end;
                checkFace("Component " + component.name(), {component.net1(), component.net2()}, faceLo, faceHi);
            }
        }
        }
    }

    // Debugging aid: KIEMS_SHORTS_DUMP="x,y,halfwidth" (mm, board-origin frame) writes
    // shorts_map.txt, a character map of the metal regions around that point on every copper layer.
    if (const char* dump = std::getenv("KIEMS_SHORTS_DUMP")) {
        double cx = 0, cy = 0, half = 0;
        if (std::sscanf(dump, "%lf,%lf,%lf", &cx, &cy, &half) == 3) {
            const double perMm = constants::unitMultiplier * 1e-3 / constants::baseUnit;
            std::ofstream map(directory / "shorts_map.txt");
            std::map<std::uint32_t, char> symbols;
            const std::string alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789";
            // Sample exactly the mesh's own nodes in the window, so a gap with a line through it can't
            // be hidden by nearest-line snapping.
            const auto linesIn = [&](int axis, double lo, double hi) {
                unsigned int qty = 0;
                double* raw = _csx->GetGrid()->GetLines(axis, nullptr, qty, true);
                std::vector<double> kept;
                for (unsigned int i = 0; i < qty; ++i) {
                    if (raw[i] >= lo && raw[i] <= hi) kept.push_back(raw[i]);
                }
                delete[] raw;
                return kept;
            };
            const std::vector<double> xs = linesIn(0, (cx - half) * perMm, (cx + half) * perMm);
            std::vector<double> ys = linesIn(1, (cy - half) * perMm, (cy + half) * perMm);
            std::reverse(ys.begin(), ys.end());
            const std::vector<double> zs = linesIn(2, -1e12, 1e12);
            for (const double zLine : zs) {
                {
                    const double z = zLine;
                map << "z=" << z / perMm << " mm\n";
                for (const double yLine : ys) {
                    for (const double xLine : xs) {
                        const std::array<double, 3> point{xLine, yLine, z};
                        const auto regions = regionsIn(point, point);
                        if (regions.empty()) {
                            map << '.';
                            continue;
                        }
                        auto [it, added] = symbols.try_emplace(regions.front(), '?');
                        if (added) it->second = symbols.size() <= alphabet.size() ? alphabet[symbols.size() - 1] : '?';
                        map << it->second;
                    }
                    map << "  y=" << yLine / perMm << "\n";
                }
                }
            }
            map << "x lines (mm):";
            for (const double xLine : xs) map << " " << xLine / perMm;
            map << "\n";
            map << "\nlegend:\n";
            for (const auto& [region, symbol] : symbols) {
                const auto nets = netsByRegion.find(region);
                map << symbol << " = region " << region << " " << (nets == netsByRegion.end() ? "(no pad labels)" : join(nets->second)) << "\n";
            }
        }
    }

    std::ofstream report(directory / "shorts.txt");
    report << "# Nets joined in the solver's grid that the board keeps apart (empty when none)\n";
    for (const std::string& finding : findings) {
        report << finding << "\n";
        logWarning(finding);
    }
    return findings;
}

void Simulation::writeRunDiagnostics(const std::filesystem::path& directory) const {
    // Simulation units (config microns * unitMultiplier) to millimetres, in the board-origin frame.
    const auto mm = [](double simUnits) { return simUnits * constants::baseUnit / constants::unitMultiplier * 1e3; };
    const auto value = [](double v) {
        if (std::isnan(v)) return std::string("-");
        std::ostringstream text;
        text << v; // shortest form, so picofarads don't round to 0.000000
        return text.str();
    };

    std::ofstream ports(directory / "ports.txt");
    ports << "# Resolved ports for simulation \"" << _simConfig.name() << "\": index -- the N in port_ut_N /\n"
          << "# port_it_N -- name, net, role, impedance (ohm), load capacitance (F), position (mm), layer -> plane\n";
    const auto& portConfigs = _simConfig.ports();
    for (std::size_t index = 0; index < portConfigs.size(); ++index) {
        const PortConfig& port = portConfigs[index];
        std::string role = port.isTraceProbe() ? "trace-probe"
                           : port.absorbSignal() ? (port.excite() ? "excited" : "absorbing")
                                                 : "passive-probe";
        if (!port.probe() && !port.isTraceProbe()) role += ",hidden";
        ports << index << "\t" << port.name() << "\tnet=" << port.netName() << "\t" << role
              << "\tZ=" << port.impedance() << "\tCload=" << port.loadCapacitance();
        if (port.position().has_value()) {
            ports << "\tat=(" << mm(port.position()->first) << ", " << mm(port.position()->second) << ")";
        }
        ports << "\tlayer=" << port.layer() << "->";
        if (const auto& bridge = port.returnBridge()) {
            ports << "pin " << bridge->padNumber << " (" << bridge->netName << ")"
                  << (bridge->corner.has_value() ? " via an L" : " straight") << " above the board\n";
        } else {
            ports << port.plane() << "\n";
        }
    }

    std::ofstream lumped(directory / "lumped.txt");
    lumped << "# Resolved lumped components (config): name, nets, topology, R (ohm), L (H), C (F), pad positions (mm)\n";
    for (const LumpedComponentConfig& component : _simConfig.lumpedComponents()) {
        lumped << component.name() << "\t" << component.net1() << " -- " << component.net2() << "\t"
               << (component.topology() == LumpedComponentTopology::Series ? "series" : "parallel")
               << "\tR=" << value(component.resistance()) << "\tL=" << value(component.inductance())
               << "\tC=" << value(component.capacitance()) << "\tpads=(" << mm(component.position1().first) << ", "
               << mm(component.position1().second) << ") (" << mm(component.position2().first) << ", "
               << mm(component.position2().second) << ")" << (component.cornerBridge() ? "\tcorner-bridge" : "")
               << "\n";
    }
    lumped << "\n# Lumped elements as handed to the solver: name, type, R, L, C, axis, boxes (mm)\n";
    for (CSProperties* property : _csx->GetPropertyByType(CSProperties::LUMPED_ELEMENT)) {
        auto* element = dynamic_cast<CSPropLumpedElement*>(property);
        if (element == nullptr) continue;
        lumped << element->GetName() << "\t"
               << (element->GetLEtype() == CSPropLumpedElement::SERIES ? "series" : "parallel")
               << "\tR=" << value(element->GetResistance()) << "\tL=" << value(element->GetInductance())
               << "\tC=" << value(element->GetCapacity()) << "\taxis=" << "xyz"[element->GetDirection() % 3];
        for (std::size_t p = 0; p < element->GetQtyPrimitives(); ++p) {
            CSPrimBox* box = element->GetPrimitive(p)->ToBox();
            if (box == nullptr) continue;
            lumped << "\t[(" << mm(box->GetCoord(0)) << ", " << mm(box->GetCoord(2)) << ", " << mm(box->GetCoord(4))
                   << ")..(" << mm(box->GetCoord(1)) << ", " << mm(box->GetCoord(3)) << ", " << mm(box->GetCoord(5))
                   << ")]";
        }
        lumped << "\n";
    }
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
        // The enabled port keeps the vector its own port built: along its element, with the
        // polarity its voltage probe expects. A return bridge's element runs in X or Y, so
        // forcing +Z here zeroed its excitation.
        if (idx != enabledIdx) {
            prop->SetExcitation(0, 0);
            prop->SetExcitation(0, 1);
            prop->SetExcitation(0, 2);
        }
    }
}

std::expected<void, std::string> Simulation::addLumpedComponents() {
    auto& components = _simConfig.lumpedComponents();
    if (components.empty()) {
        return {};
    }
    logInfo("Adding " + std::to_string(components.size()) + " included lumped component(s)");

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
            logInfo("Simulation: corner-bridge for " + component.name() + ": layer=" +
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
                CSPropMetal* wire = addMetal(*_csx, "LumpedBridgePillar_" + component.name() + "_" + suffix);
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
                    return std::unexpected("Lumped component " + component.name() +
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
                        addLumpedElement(*_csx, "Lumped_" + component.name(), axisIndex,
                                          /*caps=*/false, component.resistance(), _lumpedType(component),
                                          component.inductance(), component.capacitance());
                    addBox(*prop, start, stop, 100);
                } else {
                    CSPropMetal* wire = addMetal(*_csx, "LumpedBridgeWire_" + component.name());
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
            logError("Lumped component " + component.name() + "'s direction is not a multiple of 90 degrees, skipping");
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
                 std::string(component.topology() == LumpedComponentTopology::Series ? "series" : "parallel") +
                 " element " + component.name() + " (R=" + std::to_string(resistance) +
                 " L=" + std::to_string(inductance) + " C=" + std::to_string(capacitance) +
                 ") at start: " + _point3ToString(start) + " end: " + _point3ToString(stop));
        CSPropLumpedElement* prop = addLumpedElement(*_csx, "Lumped_" + component.name(), axisIndex,
                                                       /*caps=*/false, resistance, _lumpedType(component),
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
        const bool bridged = ports[index].returnBridge().has_value();
        if (ports[index].isTraceProbe()) {
            result = addImpedanceProbe(ports[index], portNumber);
        } else if (bridged) {
            result = addReturnBridgePort(ports[index], portNumber);
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
        if (ports[index].loadCapacitance() > 0) {
            if (ports[index].absorbSignal()) {
                logWarning("Ignoring the load capacitance on " + ports[index].name() +
                           ": it absorbs the signal, and its resistor already fills the pad's column");
            } else if (bridged) {
                // addReturnBridgePort() already put it on the element leg.
            } else if (auto capacitor = addLoadCapacitor(ports[index]); !capacitor) {
                return capacitor;
            }
        }
    }
    return {};
}

} // namespace kiems
