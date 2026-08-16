// Interacting with openEMS/CSXCAD to build and run the FDTD simulation. Ported from
// gerber2ems/simulation.py.
#pragma once

#include <complex>
#include <cstdint>
#include <expected>
#include <filesystem>
#include <memory>
#include <string>
#include <utility>
#include <vector>

#include <CSXCAD/ContinuousStructure.h>
#include <openEMS/openems.h>

#include "board_slicing.hpp"
#include "config.hpp"
#include "csx_helpers.hpp"
#include "grid_gen.hpp"
#include "importer.hpp"
#include "paths_config.hpp"
#include "ports.hpp"

namespace gerber2ems {

/// Interacts with openEMS/CSXCAD to build simulation geometry and run the FDTD simulation.
class Simulation {
public:
    /// `simConfig`/`config`/`options`/`paths` must all outlive this Simulation (kept by reference).
    Simulation(SimulationConfig& simConfig, const EMSConfig& config, const RunOptions& options,
               const PathsConfig& paths);

    /// Slices simConfig's board geometry (see board_slicing.hpp) -- simConfig.ports() must already
    /// be populated (resolveSimulationPorts(), called before any Simulation is constructed). Must
    /// be called before createMaterials()/addGerbers()/addGrid()/addSubstrates()/addVias(), which
    /// all consume the result. Deliberately not done in the constructor: a `simulate()`-step
    /// Simulation only ever calls loadGeometry() (reading the already-built geometry.xml a
    /// `geometry()`-step Simulation saved earlier) and never needs sliced geometry recomputed.
    std::expected<void, std::string> sliceBoard();

    void createMaterials();
    void addGrid();
    void addGerbers();
    void addPortGrid();

    std::expected<void, std::string> addMslPort(PortConfig& portConfig, std::int32_t portNumber, bool excite = false);
    std::expected<void, std::string> addResistivePort(PortConfig& portConfig, bool excite = false);
    void addPlane(double zHeight);
    void addSubstrates();
    std::expected<void, std::string> addVias();
    /// (xPos, yPos)-(x2Pos, y2Pos) is the via's own capsule/stadium centerline -- a plain round via
    /// is the degenerate case where the two points coincide (see ViaHole's own doc comment).
    /// `diameter` is the drill hole; `outerDiameter` is the copper conductor's outer edge (the
    /// "annular ring" OD) -- callers compute this differently per via kind, see addVias().
    void addVia(double xPos, double yPos, double x2Pos, double y2Pos, double diameter, double outerDiameter);
    /// Cuts every non-plated through-hole (see SlicedBoard::npthHoleLoops) out of the substrate
    /// model: an explicit vacuum-epsilon material, extruded through the full substrate stack depth
    /// at a priority above every substrate layer's, so it overrides them wherever it overlaps --
    /// the same addLinPoly-through-full-thickness technique addVia() uses for a via's own barrel,
    /// just with air instead of conductor. Copper is already handled separately (see
    /// board_slicing.cpp -- an NPTH hole is subtracted from layerTriangles directly, since that's
    /// plain 2D polygon geometry addGerbers() then extrudes at each metal layer's own Z height); this
    /// only needs to additionally punch through the substrate boxes addSubstrates() lays down, which
    /// have no other hole-cutting mechanism at all.
    void addNPTHHoles();
    void addDumpBoxes();

    /// PML is a far stronger absorber than MUR for the oblique-incidence/near-field content a board
    /// floating in open space radiates close to the domain boundary -- MUR reflections can keep the
    /// domain's total energy from ever decaying to the FDTD end criteria at all. Defaults to PML for
    /// that reason; MUR exists as an option mainly for comparison/debugging.
    void setBoundaryConditions(bool pml = true);
    void setExcitation();
    void setSinusExcitation(double freq);

    /// Runs one port's FDTD pass in a dedicated posix_spawn'd worker process (see
    /// paths.fdtdWorkerPath), rather than chdir'ing this process -- so the caller's own working
    /// directory (and any other threads it owns) are never touched. The worker reconstructs its own
    /// Simulation from paths.configFile/simConfig.name()/geometry.xml; it doesn't share memory with
    /// this object. loadGeometry()/setExcitation()/setupPorts(excitedPortNumber) must already have
    /// been called on *this* Simulation before run(), even though the worker redoes the same steps
    /// on its own copy -- getPortParameters() afterwards still reads this object's _ports.
    std::expected<void, std::string> run(std::int32_t excitedPortNumber);

    /// The actual FDTD execution: chdirs into this port's simulation directory, runs
    /// SetupFDTD()/RunFDTD(), and restores the previous working directory. Only ever safe to call
    /// from a freshly-spawned, single-purpose process (see gerber2ems_fdtd_worker's main()) -- never
    /// called directly by run(), which spawns exactly such a process instead of calling this itself.
    std::expected<void, std::string> runFDTDInPlace(std::int32_t excitedPortNumber);

    void saveGeometry() const;
    std::expected<void, std::string> loadGeometry();

    /// Returns (reflected, incident) uf phasors per port, vs. `frequencies`.
    std::expected<std::pair<std::vector<std::vector<std::complex<double>>>, std::vector<std::vector<std::complex<double>>>>,
                  std::string>
    getPortParameters(std::int32_t exIndex, const std::vector<double>& frequencies);

    void setupPorts(std::int32_t enabledIdx);
    std::expected<void, std::string> addPorts();

    const std::vector<std::unique_ptr<Port>>& ports() const { return _ports; }

private:
    void addContours(const std::vector<Triangle>& contours, double zHeight, std::int32_t layerIndex);
    std::expected<double, std::string> getMetalLayerOffset(std::int32_t index) const;
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

    SimulationConfig& _simConfig;
    const EMSConfig& _config;
    const RunOptions& _options;
    const PathsConfig& _paths;
    SlicedBoard _slicedBoard;

    std::vector<std::unique_ptr<Port>> _ports;
    std::vector<CSProperties*> _gerberMaterials;   // owned by _csx
    std::vector<CSProperties*> _substrateMaterials; // owned by _csx
    CSPropMetal* _planeMaterial;
    CSPropMetal* _viaMaterial;
    CSPropMaterial* _viaFillingMaterial;
    CSPropMaterial* _npthVoidMaterial; // Vacuum (epsilon_r = 1) -- see addNPTHHoles().

    std::unique_ptr<GridGenerator> _gridGen;
};

} // namespace gerber2ems
