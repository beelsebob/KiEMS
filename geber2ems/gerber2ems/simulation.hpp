// Interacting with openEMS/CSXCAD to build and run the FDTD simulation. Ported from
// gerber2ems/simulation.py.
#pragma once

#include <complex>
#include <cstdint>
#include <filesystem>
#include <memory>
#include <utility>
#include <vector>

#include <CSXCAD/ContinuousStructure.h>
#include <openEMS/openems.h>

#include "config.hpp"
#include "csx_helpers.hpp"
#include "grid_gen.hpp"
#include "importer.hpp"
#include "ports.hpp"

namespace gerber2ems {

/// Interacts with openEMS/CSXCAD to build simulation geometry and run the FDTD simulation.
class Simulation {
public:
    Simulation();

    void createMaterials();
    void addGrid();
    void addGerbers();
    void addPortGrid();

    void addMslPort(PortConfig& portConfig, std::int32_t portNumber, bool excite = false);
    void addResistivePort(PortConfig& portConfig, bool excite = false);
    void addVirtualPort(const PortConfig& portConfig);
    void addPlane(double zHeight);
    void addSubstrates();
    void addVias();
    void addVia(double xPos, double yPos, double diameter);
    void addDumpBoxes();

    void setBoundaryConditions(bool pml = false);
    void setExcitation();
    void setSinusExcitation(double freq);

    void run(std::int32_t excitedPortNumber);

    void saveGeometry() const;
    void loadGeometry();

    /// Returns (reflected, incident) uf phasors per port, vs. `frequencies`.
    std::pair<std::vector<std::vector<std::complex<double>>>, std::vector<std::vector<std::complex<double>>>>
    getPortParameters(std::int32_t exIndex, const std::vector<double>& frequencies);

    void setupPorts(std::int32_t enabledIdx);
    void addPorts();
    void addVirtualPorts();

    const std::vector<std::unique_ptr<Port>>& ports() const { return _ports; }

private:
    void addContours(const std::vector<Triangle>& contours, double zHeight, std::int32_t layerIndex);
    double getMetalLayerOffset(std::int32_t index) const;
    void addSingleDumpBox(const std::string& name, double z);
    void printGridStats() const;

    // Heap-allocated (not a value/unique_ptr member): openEMS::SetCSX() hands ownership to the
    // FDTD engine, whose own destructor (via Reset()) unconditionally `delete`s it. A value member
    // here would make that delete operate on non-heap memory (a real crash reproduced against a
    // live board during verification); a unique_ptr would double-free. Raw, deliberately
    // non-owning pointer is correct here.
    ContinuousStructure* _csx;
    openEMS _fdtd;
    CSRectGrid* _grid;

    std::vector<std::unique_ptr<Port>> _ports;
    std::vector<CSProperties*> _gerberMaterials;   // owned by _csx
    std::vector<CSProperties*> _substrateMaterials; // owned by _csx
    CSPropMetal* _planeMaterial;
    CSPropMetal* _viaMaterial;
    CSPropMaterial* _viaFillingMaterial;

    std::unique_ptr<GridGenerator> _gridGen;
};

} // namespace gerber2ems
