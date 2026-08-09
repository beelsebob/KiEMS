#include "simulation.hpp"

#include <algorithm>
#include <cmath>
#include <cstdlib>
#include <fstream>
#include <limits>
#include <map>
#include <regex>
#include <sstream>

#include "constants.hpp"
#include "csx_grid_utils.hpp"
#include "logging.hpp"

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

std::string _normalizeLayerName(std::string name) {
    for (char& c : name) {
        if (c == '.' || c == '(' || c == ')' || c == ' ' || c == '/') {
            c = '_';
        }
    }
    return name;
}

} // namespace

Simulation::Simulation(SimulationConfig& simConfig)
    : _csx(new ContinuousStructure()),
      _grid(nullptr),
      _simConfig(simConfig),
      _planeMaterial(nullptr),
      _viaMaterial(nullptr),
      _viaFillingMaterial(nullptr) {
    _fdtd.SetNumberOfTimeSteps(static_cast<unsigned int>(Config::sharedConfig().maxSteps()));
    _fdtd.SetCSX(_csx);
    _grid = _csx->GetGrid();
    _grid->SetDeltaUnit(constants::baseUnit / constants::unitMultiplier);

    _planeMaterial = addMetal(*_csx, "Plane");
    _viaMaterial = addMetal(*_csx, "Via");
    _viaFillingMaterial = addMaterial(*_csx, "ViaFilling", Config::sharedConfig().via().fillingEpsilon());
}

void Simulation::sliceBoard() { _slicedBoard = sliceBoardForSimulation(_simConfig); }

void Simulation::createMaterials() {
    const auto metals = Config::sharedConfig().getMetals();
    for (std::size_t i = 0; i < metals.size(); ++i) {
        _gerberMaterials.push_back(addMetal(*_csx, "Gerber_" + std::to_string(i)));
    }
    const auto substrates = Config::sharedConfig().getSubstrates();
    for (std::size_t i = 0; i < substrates.size(); ++i) {
        _substrateMaterials.push_back(addMaterial(*_csx, "Substrate_" + std::to_string(i), substrates[i].epsilon()));
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
        _gridGen->addPads().emplace_back(
            ap, "PORT", Position(posX + _gridGen->xmin() + width / 2, posY + _gridGen->ymin()));
        _gridGen->addApertures().insert_or_assign(
            ap, Aperture("", std::make_shared<ApertureRect>(width, height)));
    }
}

void Simulation::addGrid() {
    _gridGen = std::make_unique<GridGenerator>(_slicedBoard.xMin, _slicedBoard.yMin, _slicedBoard.width,
                                                _slicedBoard.height);
    addPortGrid();
    logInfo("Compiling grid");
    _gridGen->generate(*_grid, _simConfig);
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

    // _slicedBoard.layerTriangles is already indexed exactly like Config::sharedConfig().getMetals()
    // (see board_slicing.cpp) -- one entry per metal layer, in stackup order -- so no separate
    // per-file compositing/lookup is needed here any more (board_slicing.cpp did it once, per
    // simulation, using only this simulation's involved+ground nets rather than the whole board).
    double offset = 0;
    std::int32_t index = 0;
    for (const auto& layer : Config::sharedConfig().layers()) {
        if (layer.kind() == LayerKind::Substrate) {
            offset -= layer.thickness();
        } else if (layer.kind() == LayerKind::Metal) {
            logInfo("Adding metal mesh for " + layer.file());
            addContours(_slicedBoard.layerTriangles.at(static_cast<std::size_t>(index)), offset, index);
            ++index;
        }
    }
}

double Simulation::getMetalLayerOffset(std::int32_t index) const {
    std::int32_t currentMetalIndex = -1;
    double offset = 0;
    for (const auto& layer : Config::sharedConfig().layers()) {
        if (layer.kind() == LayerKind::Metal) {
            ++currentMetalIndex;
            if (currentMetalIndex == index) {
                return offset;
            }
        } else if (layer.kind() == LayerKind::Substrate) {
            offset -= layer.thickness();
        }
    }
    logError("Hadn't found " + std::to_string(index) + "th metal layer");
    std::exit(1);
}

void Simulation::addMslPort(PortConfig& portConfig, std::int32_t portNumber, bool excite) {
    logDebug("Adding port number " + std::to_string(_ports.size()));
    if (!portConfig.position().has_value() || !portConfig.direction().has_value()) {
        logError("Port has no defined position or rotation, skipping");
        return;
    }
    while (*portConfig.direction() < 0) {
        portConfig.setDirection(*portConfig.direction() + 360);
    }

    static const std::map<std::int32_t, std::string> dirMap = {{0, "y"}, {90, "x"}, {180, "y"}, {270, "x"}};
    const auto dirIt = dirMap.find(static_cast<std::int32_t>(*portConfig.direction()));
    if (dirIt == dirMap.end()) {
        logError("Ports rotation is not a multiple of 90 degrees which is not supported, skipping");
        return;
    }

    const double startZ = getMetalLayerOffset(portConfig.layer());
    const double stopZ = getMetalLayerOffset(portConfig.plane());
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
}

void Simulation::addResistivePort(PortConfig& portConfig, bool excite) {
    logDebug("Adding port number " + std::to_string(_ports.size()));
    if (!portConfig.position().has_value() || !portConfig.direction().has_value()) {
        logError("Port has no defined position or rotation, skipping");
        return;
    }
    static const std::map<std::int32_t, std::string> dirMap = {{0, "y"}, {90, "x"}, {180, "y"}, {270, "x"}};
    const auto dirIt = dirMap.find(static_cast<std::int32_t>(*portConfig.direction()));
    if (dirIt == dirMap.end()) {
        logError("Ports rotation is not a multiple of 90 degrees which is not supported, skipping");
        return;
    }

    const double startZ = getMetalLayerOffset(portConfig.layer());
    const double stopZ = getMetalLayerOffset(portConfig.plane());
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
}

void Simulation::addVirtualPort(const PortConfig& portConfig) {
    for (std::int32_t i = 0; i < 11; ++i) {
        addGridLine(*_grid, "x", i);
        addGridLine(*_grid, "y", i);
    }
    addGridLine(*_grid, "z", 0);
    addGridLine(*_grid, "z", 10);

    CSPropMetal* metal = addMetal(*_csx, "VirtualPort_" + std::to_string(_ports.size()));
    _ports.push_back(std::make_unique<MSLPort>(*_csx, static_cast<std::int32_t>(_ports.size()), *metal,
                                                Point3{0, 0, 0}, Point3{10, 10, 10}, "x", "z", 0.0,
                                                portConfig.impedance(), 100));
}

void Simulation::addPlane(double zHeight) {
    addBox(*_planeMaterial, {_slicedBoard.xMin, _slicedBoard.yMin, zHeight},
           {_slicedBoard.xMin + _slicedBoard.width, _slicedBoard.yMin + _slicedBoard.height, zHeight}, 1);
}

void Simulation::addSubstrates() {
    logInfo("Adding substrates");
    double offset = 0;
    const auto substrates = Config::sharedConfig().getSubstrates();
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

void Simulation::addVias() {
    logInfo("Adding vias from excellon file");
    // Real board vias: kept only where they still fall within this simulation's sliced outline --
    // a via for copper that's been sliced away has nothing left to connect to anyway.
    for (const auto& via : getVias()) {
        if (_pointInPolygon(via.x, via.y, _slicedBoard.outline)) {
            addVia(via.x, via.y, via.diameter);
        }
    }

    logInfo("Adding " + std::to_string(_slicedBoard.stitchingVias.size()) +
            " ground-net stitching via(s) from board slicing");
    for (const auto& via : _slicedBoard.stitchingVias) {
        addVia(via.x, via.y, via.diameter);
    }
}

void Simulation::addVia(double xPos, double yPos, double diameter) {
    double thickness = 0;
    for (const auto& layer : Config::sharedConfig().getSubstrates()) {
        thickness += layer.thickness();
    }

    std::vector<double> xCoords;
    std::vector<double> yCoords;
    for (std::int32_t i = 0; i < constants::viaPolygon; ++i) {
        xCoords.push_back(xPos + std::sin(static_cast<double>(i) / constants::viaPolygon * 2 * M_PI) * diameter / 2);
        yCoords.push_back(yPos + std::cos(static_cast<double>(i) / constants::viaPolygon * 2 * M_PI) * diameter / 2);
    }
    addLinPoly(*_viaFillingMaterial, xCoords, yCoords, axisIndex("z"), -thickness, thickness, 51);

    xCoords.clear();
    yCoords.clear();
    for (std::int32_t i = constants::viaPolygon - 1; i >= 0; --i) {
        const double platingThickness = Config::sharedConfig().via().platingThickness();
        xCoords.push_back(xPos + std::sin(static_cast<double>(i) / constants::viaPolygon * 2 * M_PI) *
                                      (diameter / 2 + platingThickness));
        yCoords.push_back(yPos + std::cos(static_cast<double>(i) / constants::viaPolygon * 2 * M_PI) *
                                      (diameter / 2 + platingThickness));
    }
    addLinPoly(*_viaMaterial, xCoords, yCoords, axisIndex("z"), -thickness, thickness, 50);
}

void Simulation::addSingleDumpBox(const std::string& name, double z) {
    logDebug("Adding dump box at " + std::to_string(z));
    CSPropDumpBox* dump = addDump(*_csx, name, {1, 1, 1});
    const double margin = Config::sharedConfig().grid().margin().xy();
    addBox(*dump, {_slicedBoard.xMin - margin, _slicedBoard.yMin - margin, z},
           {_slicedBoard.xMin + _slicedBoard.width + margin, _slicedBoard.yMin + _slicedBoard.height + margin, z});
}

void Simulation::addDumpBoxes() {
    const Arguments& args = Config::sharedConfig().arguments();
    if (!args.exportField().has_value()) {
        return;
    }
    logInfo("Adding field dump boxes");

    std::vector<std::string> exportField = *args.exportField();
    if (exportField.empty()) {
        exportField = {"outer", "cu-outer", "cu-inner", "substrate"};
    }
    const auto contains = [&](const std::string& v) {
        return std::find(exportField.begin(), exportField.end(), v) != exportField.end();
    };

    double offset = 0;
    std::int32_t metalIdx = 0;
    const std::int32_t metalCount = static_cast<std::int32_t>(Config::sharedConfig().getMetals().size());
    for (const auto& layer : Config::sharedConfig().layers()) {
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
        for (std::int32_t i = 0; i < 6; ++i) {
            _fdtd.Set_BC_PML(i, 8);
        }
    } else {
        logInfo("Adding MUR boundary condition");
        for (std::int32_t i = 0; i < 6; ++i) {
            _fdtd.Set_BC_Type(i, 2); // 2 == MUR, matching ['PEC','PMC','MUR'].index('MUR')
        }
    }
}

void Simulation::setExcitation() {
    const Frequency& freq = Config::sharedConfig().frequency();
    logDebug("Setting excitation to gaussian pulse from " + std::to_string(freq.start()) + " to " +
             std::to_string(freq.stop()));
    _fdtd.SetGaussExcite((freq.start() + freq.stop()) / 2, (freq.stop() - freq.start()) / 2);
}

void Simulation::setSinusExcitation(double freq) {
    logDebug("Setting excitation to sine at " + std::to_string(freq));
    _fdtd.SetSinusExcite(freq);
}

void Simulation::run(std::int32_t excitedPortNumber) {
    logInfo("Starting simulation");
    const std::filesystem::path cwd = std::filesystem::current_path();
    _fdtd.SetOverSampling(Config::sharedConfig().arguments().oversampling());

    const std::filesystem::path simPath =
        cwd / constants::simSimulationDir(_simConfig.name()) / std::to_string(excitedPortNumber);
    std::filesystem::create_directories(simPath);
    std::filesystem::current_path(simPath);

    const int ec = _fdtd.SetupFDTD();
    if (ec != 0) {
        logError("Run: Setup failed, error code: " + std::to_string(ec));
    } else {
        _fdtd.RunFDTD();
    }

    std::filesystem::current_path(cwd);
}

void Simulation::saveGeometry() const {
    const std::filesystem::path filename =
        std::filesystem::current_path() / constants::simGeometryDir(_simConfig.name()) / "geometry.xml";
    logInfo("Saving geometry to " + filename.string());
    _csx->Write2XML(filename.string());

    // Replacing , with . for numerals in the file (openEMS bug mitigation for locales that use ,
    // as the decimal separator).
    std::ifstream inFile(filename);
    std::stringstream buffer;
    buffer << inFile.rdbuf();
    inFile.close();
    static const std::regex commaDecimal(R"(([0-9]+),([0-9]+e))");
    const std::string newContent = std::regex_replace(buffer.str(), commaDecimal, "$1.$2");
    std::ofstream outFile(filename);
    outFile << newContent;
}

void Simulation::loadGeometry() {
    const std::filesystem::path filename =
        std::filesystem::current_path() / constants::simGeometryDir(_simConfig.name()) / "geometry.xml";
    logInfo("Loading geometry from " + filename.string());
    if (!std::filesystem::exists(filename)) {
        logError("Geometry file does not exist. Did you run geometry step?");
        std::exit(1);
    }
    _csx->ReadFromXML(filename.string());
    _grid = _csx->GetGrid();
}

std::pair<std::vector<std::vector<std::complex<double>>>, std::vector<std::vector<std::complex<double>>>>
Simulation::getPortParameters(std::int32_t exIndex, const std::vector<double>& frequencies) {
    const std::filesystem::path resultPath =
        std::filesystem::current_path() / constants::simSimulationDir(_simConfig.name()) / std::to_string(exIndex);

    std::vector<std::vector<std::complex<double>>> incident;
    std::vector<std::vector<std::complex<double>>> reflected;
    for (std::size_t index = 0; index < _ports.size(); ++index) {
        try {
            _ports[index]->calcPort(resultPath, frequencies);
            logDebug("Found data for port " + std::to_string(index));
        } catch (const std::exception&) {
            logError("Port data files do not exist. Did you run simulation step?");
            std::exit(1);
        }
        incident.push_back(_ports[index]->ufInc());
        reflected.push_back(_ports[index]->ufRef());
    }
    return {reflected, incident};
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

void Simulation::addPorts() {
    logInfo("Adding ports");
    _ports.clear();
    auto& ports = _simConfig.ports();
    for (std::size_t index = 0; index < ports.size(); ++index) {
        addMslPort(ports[index], static_cast<std::int32_t>(index), true);
    }
}

void Simulation::addVirtualPorts() {
    logInfo("Adding virtual ports");
    for (const auto& portConfig : _simConfig.ports()) {
        addVirtualPort(portConfig);
    }
}

} // namespace gerber2ems
