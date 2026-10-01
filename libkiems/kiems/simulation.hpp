// Interacting with CSXCAD to build and run the FDTD simulation. Ported from
// kiems/simulation.py.
#pragma once

#include <array>
#include <complex>
#include <cstdint>
#include <expected>
#include <filesystem>
#include <functional>
#include <map>
#include <memory>
#include <string>
#include <utility>
#include <vector>

#include <CSXCAD/ContinuousStructure.h>

#include <nlohmann/json.hpp>

#include "board_slicing.hpp"
#include "config.hpp"
#include "csx_helpers.hpp"
#include "grid_gen.hpp"
#include "importer.hpp"
#include "paths_config.hpp"
#include "ports.hpp"

namespace kiems {

class Simulation;

/// Runs one excited port's FDTD pass on an already-geometry-populated/setupPorts()'d Simulation,
/// writing its probe files wherever that backend's own convention puts
/// them -- the extension point that lets a caller outside libkiems (which must never depend
/// on Copper.framework -- see CopperFDTDRunner.h's own file comment) substitute an in-process GPU
/// run for the default posix_spawn'd CPU worker (Simulation::run()). Declared here (rather than
/// nested in SimulationResult, where it originally lived) so simulation_data.hpp's
/// generateResults() can use the same type without simulation_result.hpp/geometry_result.hpp's own
/// circular include back onto this header.
using FDTDPortRunner = std::function<std::expected<void, std::string>(Simulation& sim, std::int32_t excitedPortNumber)>;

/// The grid line positions Simulation::addGrid() placed along each axis -- see
/// Simulation::computedGridLines()/adoptGridLines(). At namespace scope (not nested in Simulation,
/// unlike an earlier version of this type) so it can have its own to_json/from_json below, found
/// via ADL the same way every other serializable value type in this codebase is (see config.hpp) --
/// nlohmann's ADL lookup for a nested class does not reach into its enclosing class the way it
/// does an enclosing namespace.
/// `pmlInner*` are the core mesh's own extent on X/Y, i.e. everywhere inside the PML band
/// GridGenerator::generate() appends beyond it -- see GridGenerator::pmlInnerXMin()'s own doc
/// comment. Purely diagnostic (GeometryView's "Show Grid" overlay colors PML-band lines
/// differently); all 0 for a ComputedGridLines that didn't come from a fresh addGrid() call (e.g.
/// one round-tripped through JSON from before these fields existed).
struct ComputedGridLines {
    std::vector<double> x;
    std::vector<double> y;
    std::vector<double> z;
    double pmlInnerXMin = 0;
    double pmlInnerXMax = 0;
    double pmlInnerYMin = 0;
    double pmlInnerYMax = 0;
    double pmlInnerZMin = 0;
    double pmlInnerZMax = 0;
};

inline void to_json(nlohmann::json& j, const ComputedGridLines& g) {
    j = nlohmann::json{{"x", g.x},
                        {"y", g.y},
                        {"z", g.z},
                        {"pmlInnerXMin", g.pmlInnerXMin},
                        {"pmlInnerXMax", g.pmlInnerXMax},
                        {"pmlInnerYMin", g.pmlInnerYMin},
                        {"pmlInnerYMax", g.pmlInnerYMax},
                        {"pmlInnerZMin", g.pmlInnerZMin},
                        {"pmlInnerZMax", g.pmlInnerZMax}};
}

inline void from_json(const nlohmann::json& j, ComputedGridLines& g) {
    j.at("x").get_to(g.x);
    j.at("y").get_to(g.y);
    j.at("z").get_to(g.z);
    g.pmlInnerXMin = j.value("pmlInnerXMin", 0.0);
    g.pmlInnerXMax = j.value("pmlInnerXMax", 0.0);
    g.pmlInnerYMin = j.value("pmlInnerYMin", 0.0);
    g.pmlInnerYMax = j.value("pmlInnerYMax", 0.0);
    g.pmlInnerZMin = j.value("pmlInnerZMin", 0.0);
    g.pmlInnerZMax = j.value("pmlInnerZMax", 0.0);
}

/// Builds CSXCAD simulation geometry and orchestrates the selected Copper FDTD backend.
class Simulation {
public:
    /// `simConfig`/`config`/`options`/`paths`/`board` must all outlive this Simulation (kept by
    /// reference). `board` is the KiCad board `paths.kicadBoardPaths()` names.
    Simulation(SimulationConfig& simConfig, const EMSConfig& config, const RunOptions& options,
               const PathsConfig& paths, const libkicad::Board& board);

    /// Slices simConfig's board geometry (see board_slicing.hpp) -- simConfig.ports() must already
    /// be populated (resolveSimulationPorts(), called before any Simulation is constructed). Must
    /// be called (or adoptSlicedBoard() used instead) before createMaterials()/addGerbers()/
    /// addGrid()/addSubstrates()/addVias(), which all consume the result.
    std::expected<void, std::string> sliceBoard();

    /// Adopts an already-sliced board a *different* Simulation object computed (typically
    /// GeometryResult::build()'s own, still held in memory via GeometryResult::slicedBoard()) --
    /// the cheap alternative to sliceBoard() (which re-parses gerbers and re-runs the board-slicing
    /// polygon algorithm from scratch) for a caller that just needs a second, independent
    /// Simulation/ContinuousStructure built from geometry that was already sliced once this same
    /// process. See populateGeometry()'s own doc comment for why a second Simulation is needed at
    /// all rather than just reusing the first one directly.
    void adoptSlicedBoard(SlicedBoard board) { _slicedBoard = std::move(board); }

    const SlicedBoard& slicedBoard() const { return _slicedBoard; }

    /// Snapshots _grid's current line arrays -- meaningful only once addGrid() (or adoptGridLines())
    /// has actually populated them. GridGenerator::generate() (addGrid()'s own real work) derives
    /// these from the sliced copper -- capturing the answer here is what lets a second Simulation
    /// skip that work entirely via adoptGridLines() instead of calling addGrid() itself. Named
    /// distinctly from csx_grid_utils.hpp's own gridLines(CSRectGrid&, ...) free function (which
    /// this is implemented in terms of) -- an unqualified call to that name from inside a Simulation
    /// member function would otherwise resolve to this method instead (class-scope names hide
    /// same-named free functions, even ones with a different signature), breaking
    /// printGridStats()'s own existing use of it.
    ComputedGridLines computedGridLines() const;

    /// Restores grid lines a *different* Simulation's addGrid() already computed (see
    /// computedGridLines()) -- must be called before populateGeometry() (which checks for
    /// already-populated lines and skips its own addGrid() call when it finds them -- see
    /// populateGeometry()'s own doc comment).
    void adoptGridLines(const ComputedGridLines& lines);

    /// createMaterials()/addGerbers()/addGrid()/addSubstrates()/addNPTHHoles()/(addDumpBoxes() if
    /// options.exportField)/addVias()/addPorts(), in the one order
    /// that's actually valid (each one depends on state an earlier one sets up) -- sliceBoard() or
    /// adoptSlicedBoard() must already have been called. addGrid() itself is skipped when
    /// adoptGridLines() was already called (grid lines already present) -- GridGenerator::generate()
    /// re-parses every gerber file, so a caller that already has the answer (see gridLines()) should
    /// never pay for it twice. This is the exact sequence GeometryResult::build() runs once per
    /// simulation to produce the canonical geometry, and that SimulationResult::run()'s own
    /// per-excited-port Simulation re-runs against GeometryResult::slicedBoard()'s cached copy -- a
    /// second, genuinely independent ContinuousStructure is used per excited port so each run owns
    /// its mutable geometry and ports; N excited ports therefore use N structures rather than
    /// sharing one across runs,
    /// but rebuilding CSXCAD primitives directly from the already-sliced-and-cached SlicedBoard (and
    /// already-placed grid lines) is real, cheap, in-memory construction work, not serialization --
    /// unlike the geometry.xml round-trip this replaces for any caller running in the same process
    /// that already did the (comparatively expensive) gerber-parsing/board-slicing/grid-placement
    /// work, there is no text encode/decode step anywhere in this path.
    std::expected<void, std::string> populateGeometry();

    void createMaterials();
    void addGrid();
    void addGerbers();
    void addPortGrid();
    void addLumpedComponentGrid();

    std::expected<void, std::string> addMslPort(PortConfig& portConfig, std::int32_t portNumber, bool excite = false);
    std::expected<void, std::string> addResistivePort(PortConfig& portConfig, std::int32_t portNumber,
                                                        bool excite = false);
    /// Built instead of addResistivePort() for a PortConfig with absorbSignal()==false (and excite()==
    /// false, which port_resolution.cpp guarantees whenever absorbSignal() is false -- see
    /// PortConfig::absorbSignal()'s own doc comment): a PassiveProbe, U/I probe boxes only, no
    /// metal/resistor/excitation. Still pushed onto _ports (see addPorts()), so it's reachable
    /// through every existing per-port accessor.
    std::expected<void, std::string> addPassiveProbe(PortConfig& portConfig, std::int32_t portNumber);
    /// Built instead of addResistivePort()/addPassiveProbe() for a PortConfig with isTraceProbe()==true --
    /// a non-loading, mid-trace characteristic-impedance measurement point (see
    /// PortConfig::isTraceProbe()'s own doc comment). Same transverse-width/propagation-axis box
    /// geometry as addMslPort() (reusing its corrected widthDirX/widthDirY convention -- not
    /// addPassiveProbe()'s older, pad-anchored one, which would orient the box wrong for a mid-trace
    /// probe), but built as an MSLPort with excite()==0 and no feed resistor: no synthetic metal, no
    /// termination, only the U/I/characteristic-impedance measurement cross-sections
    /// MSLPort::readUiData() already computes into Port::zRef().
    std::expected<void, std::string> addImpedanceProbe(PortConfig& portConfig, std::int32_t portNumber);
    /// Builds one SERIES CSPropLumpedElement box per SimulationConfig::lumpedComponents() entry,
    /// bridging its two real pad positions -- see that type's own doc comment and
    /// port_resolution.cpp's discovery rule. Unlike ports, these are never individually excited and
    /// aren't tracked in _ports (nothing in this library reads their probe data back) -- the CPU
    /// backend picks them up while constructing Copper's operator; the shared implementation lives
    /// in Copper/Internal/CopperLumpedRLC.hpp.
    std::expected<void, std::string> addLumpedComponents();
    void addPlane(double zHeight);
    void addSubstrates();
    /// See SimulationConfig::edgeTerminatedNets() and the definition's own comment.
    void addEdgeTerminations();
    /// Top/bottom solder mask, if this board's stackup has any -- see _slicedBoard.topMaskTriangles/
    /// bottomMaskTriangles' own doc comment for where the (already hole-free) covering shape comes
    /// from; this just extrudes it through the real mask thickness and adds the dielectric material.
    void addSolderMask();
    std::expected<void, std::string> addVias();
    /// (xPos, yPos)-(x2Pos, y2Pos) is the via's own capsule/stadium centerline -- a plain round via
    /// is the degenerate case where the two points coincide (see ViaHole's own doc comment).
    /// `diameter` is the drill hole; `outerDiameter` is the copper conductor's outer edge (the
    /// "annular ring" OD) -- callers compute this differently per via kind, see addVias().
    /// `cropToOutline`, when set, clips the via's cross-section to `_slicedBoard.outline` (via
    /// polygon intersection) before adding it -- for a real board via kept because its disc merely
    /// *reaches* the cutout boundary (see _viaIntersectsOutline's own doc comment), this prevents
    /// its geometry from extending past the simulation's own domain. A freshly-placed stitching via
    /// is always positioned viaEdgeDistance() inward of the boundary by construction, so it never
    /// needs this -- callers only set it for real board vias.
    void addVia(double xPos, double yPos, double x2Pos, double y2Pos, double diameter, double outerDiameter,
                bool cropToOutline = false);
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
    /// Runs one port's FDTD pass in a dedicated posix_spawn'd worker process (see
    /// paths.fdtdWorkerPath/paths.copperFdtdWorkerPath, selected by options.backend), rather than
    /// chdir'ing this process -- so the caller's own working directory (and any other threads it
    /// owns) are never touched. The worker reconstructs its own Simulation from
    /// paths.configFile/simConfig.name()'s own serialized SimulationData<Grid> (see
    /// simulation_data.hpp's loadSimulationData()); it doesn't share memory with this object.
    /// adoptSlicedBoard()/adoptGridLines()/populateGeometry()/
    /// setupPorts(excitedPortNumber) must already have been called on *this* Simulation before
    /// run(), even though the worker redoes the same steps on its own copy -- getPortParameters()
    /// afterwards still reads this object's _ports.
    std::expected<void, std::string> run(std::int32_t excitedPortNumber);

    /// Chdirs into this port's
    /// simulation directory so probe/dump files land next to whichever backend produced them, but
    /// does NOT run any timesteps and does NOT restore the working directory on success (the caller
    /// does that once its own copper::runFDTDPortOnCPU()/runFDTDPortOnGPU() run is actually done).
    /// CopperOperator computes the mesh and coefficients directly from `csx()`, so this only
    /// prepares the output directory. Only ever safe to call from a freshly-spawned,
    /// single-purpose process because it changes the working directory on success.
    std::expected<void, std::string> prepareRunDirectory(std::int32_t excitedPortNumber);

    /// The CSXCAD geometry -- exposed because a Copper worker
    /// needs it to discover probe boxes (see Copper/Internal/CopperProbes.hpp's discoverProbes()),
    /// which the Operator alone doesn't carry. The returned reference remains valid for as long as
    /// this Simulation is alive.
    ContinuousStructure& csx() { return *_csx; }

    /// A Copper worker needs this simulation's own
    /// EMSConfig::frequency() to compute a correctly-scaled CPML alphaMax (see
    /// copper::cpmlAlphaMaxForFrequency()'s own doc comment) rather than relying on
    /// runFDTDPortOnCPU()'s/runFDTDPortOnGPU()'s generic, frequency-agnostic default, and to build a
    /// copper::CopperFDTDPortConfig directly (maxTimesteps()/excitationF0()/excitationFc() below,
    /// plus boundaryIsPEC()) instead of reading those values back off a real Operator.
    const EMSConfig& config() const { return _config; }

    /// Per-side boundary state (face order 0=xmin,1=xmax,2=ymin,3=ymax,4=zmin,5=zmax, matching
    /// copper::CopperOperator::Config::boundary). True means PEC; false means open, with a CPML
    /// shell providing absorption. kiems never requests a PEC boundary today, so this is all-false
    /// in practice, but a Copper worker should read it rather than assume that.
    const std::array<bool, 6>& boundaryIsPEC() const { return _boundaryIsPEC; }

    /// `config().maxSteps()`, pre-cast to the unsigned type
    /// copper::CopperFDTDPortConfig::maxTimesteps expects.
    std::uint32_t maxTimesteps() const { return static_cast<std::uint32_t>(_config.maxSteps()); }

    /// The Gaussian pulse center frequency/half-bandwidth derived from config().frequency(), exposed
    /// so a Copper worker can build copper::CopperFDTDPortConfig::f0/fc directly.
    double excitationF0() const { return (_config.frequency().start() + _config.frequency().stop()) / 2; }
    double excitationFc() const { return (_config.frequency().stop() - _config.frequency().start()) / 2; }

    /// `reflected`/`incident` are uf phasors per port (a same-length, all-NaN placeholder for any
    /// port with absorbSignal()==false, which never computes a meaningful incident/reflected split
    /// -- see PortConfig::absorbSignal()'s own doc comment -- kept only to preserve every other
    /// piece of code's port-index alignment). `probeVoltage`/`probeCurrent` carry that same
    /// non-absorbing port's real data instead (ufTot()/ifTot()), keyed by port index -- only ever
    /// populated for ports with absorbSignal()==false. `probeImpedance` is populated only for a
    /// trace-impedance probe (PortConfig::isTraceProbe()==true, a strict subset of the non-absorbing
    /// ports above) with that probe's own measured characteristic impedance (Port::zRef()).
    struct PortParameters {
        std::vector<std::vector<std::complex<double>>> reflected;
        std::vector<std::vector<std::complex<double>>> incident;
        std::map<std::int32_t, std::vector<std::complex<double>>> probeVoltage;
        std::map<std::int32_t, std::vector<std::complex<double>>> probeCurrent;
        std::map<std::int32_t, std::vector<std::complex<double>>> probeImpedance;
    };
    std::expected<PortParameters, std::string> getPortParameters(std::int32_t exIndex,
                                                                    const std::vector<double>& frequencies);

    void setupPorts(std::int32_t enabledIdx);
    std::expected<void, std::string> addPorts();

    const std::vector<std::unique_ptr<Port>>& ports() const { return _ports; }

private:
    void addContours(const std::vector<Triangle>& contours, double zHeight, std::int32_t layerIndex);
    std::expected<double, std::string> getMetalLayerOffset(std::int32_t index) const;
    void addSingleDumpBox(const std::string& name, double z);
    void printGridStats() const;

    std::unique_ptr<ContinuousStructure> _csx;
    CSRectGrid* _grid;

    SimulationConfig& _simConfig;
    const EMSConfig& _config;
    const RunOptions& _options;
    const PathsConfig& _paths;
    const libkicad::Board& _board;
    SlicedBoard _slicedBoard;
    // Set by adoptGridLines(); checked (only) by populateGeometry() to skip its own addGrid() call
    // -- see both their own doc comments.
    bool _gridLinesAdopted = false;
    std::array<bool, 6> _boundaryIsPEC = {false, false, false, false, false, false};

    std::vector<std::unique_ptr<Port>> _ports;
    std::vector<CSProperties*> _gerberMaterials;   // owned by _csx
    std::vector<CSProperties*> _substrateMaterials; // owned by _csx
    std::vector<CSProperties*> _solderMaskMaterials; // owned by _csx -- see addSolderMask()
    CSPropMetal* _planeMaterial;
    CSPropMetal* _viaMaterial;
    CSPropMaterial* _viaFillingMaterial;
    CSPropMaterial* _npthVoidMaterial; // Vacuum (epsilon_r = 1) -- see addNPTHHoles().

    std::unique_ptr<GridGenerator> _gridGen;
};

} // namespace kiems
