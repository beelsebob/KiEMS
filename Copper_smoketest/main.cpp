// Copper smoketest, phases 0-2: build plumbing (Phase 0), Yee grid/coefficient/excitation
// extraction (Phase 1), and the Metal interior leapfrog engine on a PEC cavity (Phase 2). Confirms
// Copper.framework links against libopenEMS/libCSXCAD (via the source-checkout header search path
// added for the Copper target), that CopperOpenEMSAccess's protected-member access actually
// compiles and works, that a hand-built synthetic CSX structure produces a sane, real openEMS
// Operator, that CopperYeeGrid/CopperExcitation's own extraction exactly reproduces values read
// directly from that same Operator/Excitation, and that CopperEngine's GPU leapfrog reproduces the
// real CPU openEMS Engine's field values (to float-rounding tolerance) on an identical grid -- no
// gerber2ems/libgerber2ems involvement at all, matching the plan's intent to keep this fixture
// independent of the rest of the pipeline for phases 0-3.
//
// Plain assert-and-print-PASS/FAIL, matching this repo's existing libgerber2ems_smoketest/
// libkicad_smoketest convention -- not XCTest.

#include <algorithm>
#include <array>
#include <cassert>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <sstream>
#include <string>
#include <utility>

// Flat (unnamespaced) includes, not <CSXCAD/...> -- openEMS's own internal headers (pulled in via
// CopperOpenEMSAccess.hpp) already include CSXCAD this way, resolving against the CSXCAD *source
// checkout* (see the Copper target's SYSTEM_HEADER_SEARCH_PATHS), not the installed, namespaced
// `CSXCAD/` public headers other parts of this app use. Mixing the two in one translation unit
// pulls in two independent copies of the same classes (no shared include guards between an
// installed copy and a source-checkout copy) and fails to compile with "redefinition" errors.
#include <CSPropExcitation.h>
#include <CSPropLumpedElement.h>
#include <CSPropMaterial.h>
#include <CSPropMetal.h>
#include <CSPropProbeBox.h>
#include <CSPrimBox.h>
#include <CSPrimPolygon.h>
#include <CSRectGrid.h>
#include <ContinuousStructure.h>

#include "Internal/CopperCPML.hpp"
#include "Internal/CopperEngine.hpp"
#include "Internal/CopperExcitation.hpp"
#include "tools/constants.h" // EPS0/MUE0, for Phase 4c's independent cross-check of estimateEnergy()
#include "Internal/CopperOpenEMSAccess.hpp"
#include "Internal/CopperPML.hpp"
#include "Internal/CopperProbes.hpp"
#include "Internal/CopperYeeGrid.hpp"

namespace {

void fail(const char* what) {
    std::fprintf(stderr, "Copper_smoketest: FAIL: %s\n", what);
    std::exit(EXIT_FAILURE);
}

/// A trivial 11x11x3-line vacuum grid (1mm cells, PEC on every side), with a single soft E-field
/// (excitation type 0, matching gerber2ems's own ports.cpp -- see CopperExcitation.hpp) excitation
/// box in the middle of the domain, oriented along z like a real MSLPort's excitation. No material
/// boxes at all otherwise -- a bare vacuum cell already has well-defined, checkable vv/vi/ii/iv
/// coefficients, and this is intentionally the simplest geometry that still exercises the full
/// SetGeometryCSX/CalcECOperator/excitation-signal-build path.
///
/// Heap-allocated, not returned by value: `openEMS::SetCSX()` takes ownership of whatever pointer
/// it's given -- its own destructor (via Reset()) unconditionally `delete`s it. Handing it a
/// pointer to anything not obtained from `new` (a stack local, or a temporary that's since been
/// destroyed) crashes at `fdtd`'s own destruction with "pointer being freed was not allocated".
/// (`libgerber2ems::Simulation::_csx` is a raw, non-owning pointer for exactly this reason -- see
/// its own doc comment.)
ContinuousStructure* buildTinyVacuumGrid() {
    auto* csx = new ContinuousStructure();
    CSRectGrid* grid = csx->GetGrid();
    grid->SetDeltaUnit(1e-3); // millimetres
    for (int i = 0; i <= 10; ++i) {
        grid->AddDiscLine(0, static_cast<double>(i));
        grid->AddDiscLine(1, static_cast<double>(i));
    }
    grid->AddDiscLine(2, 0.0);
    grid->AddDiscLine(2, 1.0);
    grid->AddDiscLine(2, 2.0);

    auto* exc = new CSPropExcitation(csx->GetParameterSet());
    exc->SetName("test_excite");
    exc->SetExcitType(0); // soft E-field excite
    exc->SetExcitation(1.0, 2); // unit amplitude along z
    csx->AddProperty(exc);
    auto* excBox = new CSPrimBox(exc->GetParameterSet(), exc);
    excBox->SetCoord(0, 5.0);
    excBox->SetCoord(1, 5.0);
    excBox->SetCoord(2, 5.0);
    excBox->SetCoord(3, 5.0);
    excBox->SetCoord(4, 0.0);
    excBox->SetCoord(5, 1.0);

    return csx;
}

/// The same 11x11x3-line, 1mm, all-PEC vacuum box as buildTinyVacuumGrid(), but with *no*
/// excitation box placed anywhere -- used for Phase 2's CPU-vs-GPU parity check, where the
/// stimulus is a hand-seeded impulse (CopperEngine::writeFieldCell / Engine::SetVolt) rather than
/// openEMS's own excitation extension, so both engines must start from a genuinely identical,
/// otherwise-quiescent state. `SetGaussExcite` is still required on the `openEMS` object itself --
/// `SetupFDTD()` rejects a null excitation signal outright (`m_Exc==NULL` check) even though no
/// excitation box exists in the geometry -- but with nothing in the CSX to attach to,
/// Operator_Ext_Excitation ends up with zero excited cells, so it's a no-op on every timestep.
ContinuousStructure* buildPecCavityNoExcitation() {
    auto* csx = new ContinuousStructure();
    CSRectGrid* grid = csx->GetGrid();
    grid->SetDeltaUnit(1e-3);
    for (int i = 0; i <= 10; ++i) {
        grid->AddDiscLine(0, static_cast<double>(i));
        grid->AddDiscLine(1, static_cast<double>(i));
    }
    grid->AddDiscLine(2, 0.0);
    grid->AddDiscLine(2, 1.0);
    grid->AddDiscLine(2, 2.0);
    return csx;
}

/// Small fixture for checking CalcPEC's primitive-paint cache against the former per-edge priority
/// query. It deliberately combines overlapping metal/material boxes (the higher-priority material
/// must mask PEC) with a zero-thickness z-normal metal polygon, matching the primitive used for
/// real PCB copper and its unusual GetBoundBox() contract (valid values with a false return).
ContinuousStructure* buildPecPaintFixture() {
    auto* csx = new ContinuousStructure();
    CSRectGrid* grid = csx->GetGrid();
    grid->SetDeltaUnit(1e-3);
    for (int axis = 0; axis < 3; ++axis) {
        for (int i = 0; i <= 4; ++i) {
            grid->AddDiscLine(axis, static_cast<double>(i));
        }
    }

    auto* metal = new CSPropMetal(csx->GetParameterSet());
    metal->SetName("paint_metal");
    csx->AddProperty(metal);
    auto* metalBox = new CSPrimBox(metal->GetParameterSet(), metal);
    for (int axis = 0; axis < 3; ++axis) {
        metalBox->SetCoord(2 * axis, 0.75);
        metalBox->SetCoord(2 * axis + 1, 3.25);
    }
    metalBox->SetPriority(10);

    auto* metalPolygon = new CSPrimPolygon(metal->GetParameterSet(), metal);
    metalPolygon->ClearCoords();
    metalPolygon->AddCoord(0.5);
    metalPolygon->AddCoord(0.5);
    metalPolygon->AddCoord(3.5);
    metalPolygon->AddCoord(0.5);
    metalPolygon->AddCoord(3.5);
    metalPolygon->AddCoord(3.5);
    metalPolygon->AddCoord(0.5);
    metalPolygon->AddCoord(3.5);
    metalPolygon->SetNormDir(2);
    metalPolygon->SetElevation(4.0);
    metalPolygon->SetPriority(15);

    auto* material = new CSPropMaterial(csx->GetParameterSet());
    material->SetName("paint_material_mask");
    material->SetEpsilon(2.0);
    csx->AddProperty(material);
    auto* materialBox = new CSPrimBox(material->GetParameterSet(), material);
    materialBox->SetCoord(0, 1.75);
    materialBox->SetCoord(1, 3.25);
    materialBox->SetCoord(2, 0.75);
    materialBox->SetCoord(3, 3.25);
    materialBox->SetCoord(4, 0.75);
    materialBox->SetCoord(5, 3.25);
    materialBox->SetPriority(20);

    return csx;
}

/// TEMPORARY diagnostic fixture: same PEC vacuum cavity shape as buildPecCavityNoExcitation(), but
/// at the real Keyboard Hub board's own length scale -- SetDeltaUnit(1e-6) (1 micron, not 1mm) and
/// 50-native-unit (50 micron) cell spacing, matching that board's own near-port cell size -- to
/// isolate whether openEMS's own vi/vv coefficients scale differently at this drawing-unit/cell-size
/// combination than the existing 1mm fixture, independent of any hand-derived (and, twice now,
/// wrong) dimensional-analysis reasoning about what "should" happen.
[[maybe_unused]] ContinuousStructure* buildMicronScaleVacuumGrid() {
    auto* csx = new ContinuousStructure();
    CSRectGrid* grid = csx->GetGrid();
    grid->SetDeltaUnit(1e-6);
    for (int i = 0; i <= 10; ++i) {
        grid->AddDiscLine(0, static_cast<double>(i) * 50.0);
        grid->AddDiscLine(1, static_cast<double>(i) * 50.0);
    }
    grid->AddDiscLine(2, 0.0);
    grid->AddDiscLine(2, 50.0);
    grid->AddDiscLine(2, 100.0);
    return csx;
}

/// A wider vacuum box (40 lines in x, instead of buildPecCavityNoExcitation()'s 10) with PML on the
/// x-min/x-max faces and PEC everywhere else, no excitation box -- used for Phase 3's CPU-vs-GPU PML
/// parity check. Needs to be wide enough that Operator_Ext_UPML::Create_UPML doesn't fall back to
/// PEC (its own guard requires the combined PML depth on an axis to be strictly less than that
/// axis's own line count; 8+8=16 against 40 lines leaves a comfortable margin).
ContinuousStructure* buildPmlCavityNoExcitation() {
    auto* csx = new ContinuousStructure();
    CSRectGrid* grid = csx->GetGrid();
    grid->SetDeltaUnit(1e-3);
    for (int i = 0; i <= 40; ++i) {
        grid->AddDiscLine(0, static_cast<double>(i));
    }
    for (int i = 0; i <= 10; ++i) {
        grid->AddDiscLine(1, static_cast<double>(i));
    }
    grid->AddDiscLine(2, 0.0);
    grid->AddDiscLine(2, 1.0);
    grid->AddDiscLine(2, 2.0);
    return csx;
}

/// A cube large enough on all 3 axes to hold buildCPMLShells()'s own uniform-6-face
/// kPmlDepthCellsForTest (8) PML shells with real interior left over -- unlike
/// buildPmlCavityNoExcitation() (deliberately thin, 2 cells, in Z; fine for Phase 3's own X-only
/// UPML test, but buildCPMLShells() now always builds all 6 faces uniformly, see its own doc
/// comment, so it needs every axis to comfortably exceed 2*pmlDepthCells). No boundary condition set
/// here -- callers must use Set_BC_Type()+MUR (or PEC) on every face, never Set_BC_PML(), matching
/// how a real CPML run is actually configured (see Simulation::setBoundaryConditions()'s own
/// comment) -- so buildCPMLShells() is the only thing providing PML absorption at all.
ContinuousStructure* buildCpmlCavityNoExcitation() {
    auto* csx = new ContinuousStructure();
    CSRectGrid* grid = csx->GetGrid();
    grid->SetDeltaUnit(1e-3);
    for (int axis = 0; axis < 3; ++axis) {
        for (int i = 0; i <= 30; ++i) {
            grid->AddDiscLine(axis, static_cast<double>(i));
        }
    }
    return csx;
}

/// buildTinyVacuumGrid()'s same domain/excitation, plus a voltage probe and a current probe laid
/// out the same way LumpedPort::LumpedPort (libgerber2ems/gerber2ems/ports.cpp) lays its own real
/// u/i probes relative to a port box -- a voltage probe spanning the excitation direction at the
/// port's center point, and a current probe forming a loop around the port's footprint at its
/// midpoint along that same direction. Used for Phase 4b's probe discovery/sampling check.
ContinuousStructure* buildProbeFixture() {
    auto* csx = new ContinuousStructure();
    CSRectGrid* grid = csx->GetGrid();
    grid->SetDeltaUnit(1e-3);
    for (int i = 0; i <= 10; ++i) {
        grid->AddDiscLine(0, static_cast<double>(i));
        grid->AddDiscLine(1, static_cast<double>(i));
    }
    grid->AddDiscLine(2, 0.0);
    grid->AddDiscLine(2, 1.0);
    grid->AddDiscLine(2, 2.0);

    auto* exc = new CSPropExcitation(csx->GetParameterSet());
    exc->SetName("test_excite");
    exc->SetExcitType(0);
    exc->SetExcitation(1.0, 2);
    csx->AddProperty(exc);
    auto* excBox = new CSPrimBox(exc->GetParameterSet(), exc);
    excBox->SetCoord(0, 5.0);
    excBox->SetCoord(1, 5.0);
    excBox->SetCoord(2, 5.0);
    excBox->SetCoord(3, 5.0);
    excBox->SetCoord(4, 0.0);
    excBox->SetCoord(5, 1.0);

    auto* uProbe = new CSPropProbeBox(csx->GetParameterSet());
    uProbe->SetName("test_ut");
    uProbe->SetProbeType(0); // voltage
    uProbe->SetWeighting(-1.0);
    csx->AddProperty(uProbe);
    auto* uBox = new CSPrimBox(uProbe->GetParameterSet(), uProbe);
    uBox->SetCoord(0, 5.0);
    uBox->SetCoord(1, 5.0);
    uBox->SetCoord(2, 5.0);
    uBox->SetCoord(3, 5.0);
    uBox->SetCoord(4, 0.0);
    uBox->SetCoord(5, 1.0);

    auto* iProbe = new CSPropProbeBox(csx->GetParameterSet());
    iProbe->SetName("test_it");
    iProbe->SetProbeType(1); // current
    iProbe->SetWeighting(1.0);
    iProbe->SetNormalDir(2);
    csx->AddProperty(iProbe);
    auto* iBox = new CSPrimBox(iProbe->GetParameterSet(), iProbe);
    iBox->SetCoord(0, 3.0);
    iBox->SetCoord(1, 7.0);
    iBox->SetCoord(2, 3.0);
    iBox->SetCoord(3, 7.0);
    iBox->SetCoord(4, 0.5);
    iBox->SetCoord(5, 0.5);

    return csx;
}

/// A minimal ad-hoc reimplementation of libgerber2ems/gerber2ems/ports.cpp's own `_loadUiFile`
/// parsing rule (skip blank/`%`-prefixed lines, take the first 2 whitespace-separated tokens of
/// every other line as time/value) -- used to confirm CopperProbeWriter's actual file output
/// round-trips through *that exact* rule, not just a rule this file assumes is equivalent.
std::vector<std::pair<double, double>> loadProbeFileLikePortsCpp(const std::filesystem::path& path) {
    std::ifstream file(path);
    std::vector<std::pair<double, double>> rows;
    std::string line;
    while (std::getline(file, line)) {
        if (line.empty() || line[0] == '%') {
            continue;
        }
        std::istringstream iss(line);
        double t = 0.0, v = 0.0;
        if (iss >> t >> v) {
            rows.emplace_back(t, v);
        }
    }
    return rows;
}

} // namespace

int main() {
    copper::CopperOpenEMS fdtd;
    fdtd.SetCSX(buildTinyVacuumGrid()); // ownership transfers to fdtd here -- see the doc comment above
    fdtd.SetGaussExcite(2.5e9, 2.5e9); // 0-5 GHz broadband pulse, matching this project's own default range
    for (int side = 0; side < 6; ++side) {
        fdtd.Set_BC_Type(side, 0); // PEC on every side -- simplest possible closed box
    }
    // 150, not just enough for setup to succeed -- Phase 4a below actually steps this fixture's
    // engine partway into the Gaussian pulse's ramp-up, and a too-short signal (e.g. 10 samples)
    // stays too close to the pulse's near-zero start to meaningfully exercise apply_excitation_e.
    fdtd.SetNumberOfTimeSteps(150);

    const int setupResult = fdtd.SetupFDTD();
    if (setupResult != 0) {
        fail("openEMS::SetupFDTD() returned non-zero");
    }

    Operator* op = fdtd.GetOperatorForGPU();
    if (op == nullptr) {
        fail("CopperOpenEMS::GetOperatorForGPU() returned null after SetupFDTD()");
    }

    // --- Phase 0b: CalcPEC's paint cache must be exactly equivalent to its old priority query. ---
    {
        ContinuousStructure* pecCsx = buildPecPaintFixture();
        copper::CopperOpenEMS pecFdtd;
        pecFdtd.SetCSX(pecCsx);
        pecFdtd.SetGaussExcite(2.5e9, 2.5e9);
        for (int side = 0; side < 6; ++side) {
            pecFdtd.Set_BC_Type(side, 0);
        }
        pecFdtd.SetNumberOfTimeSteps(10);
        if (pecFdtd.SetupFDTD() != 0) {
            fail("Phase 0b fixture: openEMS::SetupFDTD() returned non-zero");
        }
        Operator* pecOp = pecFdtd.GetOperatorForGPU();
        if (pecOp == nullptr) {
            fail("Phase 0b fixture: GetOperatorForGPU() returned null");
        }
        auto* pecAccess = static_cast<copper::CopperOperatorAccess*>(pecOp);

        unsigned int paintedMetal[3] = {0, 0, 0};
        unsigned int pos[3] = {0, 0, 0};
        double coord[3];
        OperatorPECColumnCache cache;
        for (pos[0] = 0; pos[0] < pecOp->GetNumberOfLines(0); ++pos[0]) {
            for (pos[1] = 0; pos[1] < pecOp->GetNumberOfLines(1); ++pos[1]) {
                pecAccess->PaintPECColumn(pos[0], pos[1], cache);
                const std::vector<CSPrimitives*> candidates = pecOp->GetPrimitivesBoundBox(
                    static_cast<int>(pos[0]), static_cast<int>(pos[1]), -1,
                    static_cast<CSProperties::PropertyType>(CSProperties::MATERIAL | CSProperties::METAL));
                for (pos[2] = 0; pos[2] < pecOp->GetNumberOfLines(2); ++pos[2]) {
                    for (int axis = 0; axis < 3; ++axis) {
                        pecOp->GetYeeCoords(axis, pos, coord, false);
                        CSPrimitives* referenceWinner = nullptr;
                        pecCsx->GetPropertyByCoordPriority(coord, candidates, false, &referenceWinner);
                        if (cache.data[axis][pos[2]] != referenceWinner) {
                            fail("Phase 0b: CalcPEC paint-cache winner differs from the legacy priority query");
                        }
                        if (referenceWinner && referenceWinner->GetProperty()->GetType() == CSProperties::METAL) {
                            ++paintedMetal[axis];
                        }
                    }
                }
            }
        }
        for (int axis = 0; axis < 3; ++axis) {
            if (paintedMetal[axis] != pecAccess->m_Nr_PEC[axis]) {
                fail("Phase 0b: CalcPEC's applied PEC count differs from the paint-cache reference");
            }
        }
        std::printf("Phase 0b: CalcPEC paint cache matches legacy lookup (%u/%u/%u PEC edges)\n",
                    paintedMetal[0], paintedMetal[1], paintedMetal[2]);
    }

    const unsigned int nx = op->GetNumberOfLines(0);
    const unsigned int ny = op->GetNumberOfLines(1);
    const unsigned int nz = op->GetNumberOfLines(2);
    std::printf("Grid lines: %u x %u x %u\n", nx, ny, nz);
    if (nx != 11 || ny != 11 || nz != 3) {
        fail("grid line counts don't match the hand-built 11x11x3 fixture");
    }

    // A bare vacuum cell strictly inside the domain: vv should be close to 1 (lossless E-update
    // decay factor) and vi should be positive and finite (nonzero E-update gain from curl(H)).
    const FDTD_FLOAT vv = op->GetVV(0, 5, 5, 1);
    const FDTD_FLOAT vi = op->GetVI(0, 5, 5, 1);
    std::printf("Interior vv[0](5,5,1) = %f, vi[0](5,5,1) = %e\n", vv, vi);
    if (!(vv > 0.99F && vv <= 1.0F)) {
        fail("interior vv coefficient outside the expected lossless-vacuum range");
    }
    if (!std::isfinite(vi) || vi <= 0.0F) {
        fail("interior vi coefficient not a sane positive finite value");
    }

    // --- Phase 1: CopperYeeGrid extraction, cross-checked against the same Operator directly. ---
    const copper::CopperYeeGrid grid = copper::buildYeeGrid(*op);
    if (grid.dims.nx != nx || grid.dims.ny != ny || grid.dims.nz != nz) {
        fail("CopperYeeGrid dims don't match Operator::GetNumberOfLines");
    }
    if (grid.timestepSeconds != op->GetTimestep()) {
        fail("CopperYeeGrid timestepSeconds doesn't match Operator::GetTimestep()");
    }
    // Every (axis, x, y, z) coefficient, not just a sample -- this is cheap (363 cells x 3 axes)
    // and Phase 1's whole point is proving the extraction/indexing never silently mismaps a value.
    for (unsigned int axis = 0; axis < 3; ++axis) {
        for (unsigned int z = 0; z < nz; ++z) {
            for (unsigned int y = 0; y < ny; ++y) {
                for (unsigned int x = 0; x < nx; ++x) {
                    const std::uint32_t idx = copper::copperGridIndex(grid.dims, x, y, z);
                    if (grid.vv[axis][idx] != op->GetVV(axis, x, y, z) ||
                        grid.vi[axis][idx] != op->GetVI(axis, x, y, z) ||
                        grid.ii[axis][idx] != op->GetII(axis, x, y, z) ||
                        grid.iv[axis][idx] != op->GetIV(axis, x, y, z)) {
                        fail("CopperYeeGrid coefficient mismatch against direct Operator query");
                    }
                }
            }
        }
    }
    // Primary/dual line positions, spot-checked at a few points including domain edges (where dual
    // mesh mirroring kicks in). Cast to float before comparing, matching CopperYeeGrid's own
    // double-to-float narrowing internally -- otherwise this compares a once-narrowed float against
    // a full-precision double and spuriously fails on the last bit or two.
    if (grid.lineX[0] != static_cast<float>(op->GetDiscLine(0, 0, false) * op->GetGridDelta()) ||
        grid.lineX[nx - 1] != static_cast<float>(op->GetDiscLine(0, nx - 1, false) * op->GetGridDelta()) ||
        grid.dualLineX[0] != static_cast<float>(op->GetDiscLine(0, 0, true) * op->GetGridDelta()) ||
        grid.dualLineX[nx - 1] != static_cast<float>(op->GetDiscLine(0, nx - 1, true) * op->GetGridDelta())) {
        fail("CopperYeeGrid line position mismatch against direct Operator query");
    }
    std::printf("CopperYeeGrid: %u cells, dT = %e s -- matches direct Operator query exactly\n",
                grid.dims.cellCount(), grid.timestepSeconds);

    // --- Phase 1: CopperExcitation extraction. ---
    const copper::CopperExcitation excitation = copper::buildExcitation(*op);
    Excitation* exc = op->GetExcitationSignal();
    if (exc == nullptr) {
        fail("Operator::GetExcitationSignal() returned null -- SetGaussExcite wasn't honored");
    }
    if (excitation.voltageSignal.size() != exc->GetLength() || excitation.currentSignal.size() != exc->GetLength()) {
        fail("CopperExcitation signal length doesn't match Excitation::GetLength()");
    }
    for (unsigned int i = 0; i < exc->GetLength(); ++i) {
        if (excitation.voltageSignal[i] != exc->GetVoltageSignal()[i] ||
            excitation.currentSignal[i] != exc->GetCurrentSignal()[i]) {
            fail("CopperExcitation signal sample mismatch against direct Excitation query");
        }
    }
    if (excitation.voltageCells.empty()) {
        fail("CopperExcitation found no excited cells -- the test fixture's excitation box wasn't picked up");
    }
    const copper::CopperExcitationCell& cell = excitation.voltageCells.front();
    std::printf("Excitation: %zu voltage cell(s), signal length %u, first cell (%u,%u,%u) axis=%u amp=%f\n",
                excitation.voltageCells.size(), exc->GetLength(), cell.x, cell.y, cell.z, cell.axis, cell.amplitude);
    if (cell.axis != 2) {
        fail("excited cell's axis isn't z, contradicting the test fixture's own excitation direction");
    }
    if (!std::isfinite(cell.amplitude) || cell.amplitude == 0.0F) {
        fail("excited cell's amplitude isn't a sane nonzero value");
    }

    // --- Phase 4a: Metal excitation kernel vs. the real CPU openEMS Engine, on the *same* grid and
    // *same* real excitation `fdtd`/`op`/`grid`/`excitation` already built above for Phase 0/1 --
    // its engine hasn't been stepped yet, so it's still a fresh, valid CPU reference here. No hand
    // seeding this time (unlike Phase 2/3): both engines start from E=H=0 and get their only
    // nonzero state from apply_excitation_e injecting the real Gaussian-pulse signal each step, the
    // same way Engine_Ext_Excitation::Apply2VoltagesImpl does on the CPU side. This fixture's
    // excitation is soft-E-field-only (Curr_Count==0, see buildTinyVacuumGrid()'s own doc comment),
    // so this exercises apply_excitation_e but not apply_excitation_h -- the real gerber2ems port
    // excitation is the same soft-E-field type, so that's the path that actually matters.
    {
        Engine* cpuEngine = fdtd.GetEngineForCPU();
        if (cpuEngine == nullptr) {
            fail("Phase 4a: CopperOpenEMS::GetEngineForCPU() returned null");
        }
        copper::CopperEngine gpuEngine(grid, {}, excitation);

        const std::uint32_t steps = 100;
        gpuEngine.run(steps);
        cpuEngine->IterateTS(steps);

        const copper::CopperEngine::Field fields[6] = {
            copper::CopperEngine::Field::Ex, copper::CopperEngine::Field::Ey, copper::CopperEngine::Field::Ez,
            copper::CopperEngine::Field::Hx, copper::CopperEngine::Field::Hy, copper::CopperEngine::Field::Hz,
        };
        const unsigned int axisForField[6] = {0, 1, 2, 0, 1, 2};
        bool anyNonzero = false;
        float maxAbsDiff = 0.0F;
        float maxAbsValue = 0.0F;
        for (int f = 0; f < 6; ++f) {
            const bool isH = f >= 3;
            const std::vector<float> gpuField = gpuEngine.readField(fields[f]);
            for (std::uint32_t z = 0; z < grid.dims.nz; ++z) {
                for (std::uint32_t y = 0; y < grid.dims.ny; ++y) {
                    for (std::uint32_t x = 0; x < grid.dims.nx; ++x) {
                        const float cpuValue = isH ? cpuEngine->GetCurr(axisForField[f], x, y, z)
                                                    : cpuEngine->GetVolt(axisForField[f], x, y, z);
                        const std::uint32_t idx = copper::copperGridIndex(grid.dims, x, y, z);
                        const float gpuValue = gpuField[idx];
                        maxAbsDiff = std::max(maxAbsDiff, std::fabs(gpuValue - cpuValue));
                        maxAbsValue = std::max(maxAbsValue, std::fabs(cpuValue));
                        if (cpuValue != 0.0F) {
                            anyNonzero = true;
                        }
                    }
                }
            }
        }
        std::printf("Phase 4a: after %u steps (excitation only, no PML), max|GPU-CPU| = %e (max|CPU field| = %e)\n",
                    steps, static_cast<double>(maxAbsDiff), static_cast<double>(maxAbsValue));
        if (!anyNonzero) {
            fail("Phase 4a: CPU reference engine's fields are all still zero -- excitation never landed");
        }
        const float tolerance = 1e-4F * std::max(maxAbsValue, 1.0F);
        if (maxAbsDiff > tolerance) {
            fail("Phase 4a: GPU excitation field values diverge from the real CPU openEMS engine beyond "
                 "float-rounding tolerance");
        }
    }

    // --- Phase 2: Metal interior engine vs. the real CPU openEMS Engine, on the identical grid. ---
    // A single impulse is seeded by hand into one Ez cell on *both* engines identically (see
    // buildPecCavityNoExcitation()'s doc comment for why no excitation box is used instead), then
    // both step forward the same number of timesteps and every field cell is diffed. This is also
    // the Copper implementation plan's PEC-boundary hypothesis check: if PEC needed anything beyond
    // the per-cell vv/vi/ii/iv coefficients CopperYeeGrid already extracts, the GPU and CPU runs
    // would diverge right at the domain edges -- and with nz=3 here, every H update touches a
    // boundary cell (the "shift" trick), so this fixture exercises that path immediately, not just
    // eventually.
    {
        copper::CopperOpenEMS cavityFdtd;
        cavityFdtd.SetCSX(buildPecCavityNoExcitation());
        cavityFdtd.SetGaussExcite(2.5e9, 2.5e9);
        for (int side = 0; side < 6; ++side) {
            cavityFdtd.Set_BC_Type(side, 0);
        }
        cavityFdtd.SetNumberOfTimeSteps(10);
        if (cavityFdtd.SetupFDTD() != 0) {
            fail("Phase 2 fixture: openEMS::SetupFDTD() returned non-zero");
        }

        Operator* cavityOp = cavityFdtd.GetOperatorForGPU();
        Engine* cpuEngine = cavityFdtd.GetEngineForCPU();
        if (cavityOp == nullptr || cpuEngine == nullptr) {
            fail("Phase 2 fixture: GetOperatorForGPU()/GetEngineForCPU() returned null");
        }

        const copper::CopperYeeGrid cavityGrid = copper::buildYeeGrid(*cavityOp);
        copper::CopperEngine gpuEngine(cavityGrid);

        // Interior cell, away from every wall -- chosen the same way as the earlier vv/vi sample.
        const std::uint32_t seedX = 5, seedY = 5, seedZ = 1;
        const float seedValue = 1.0F;
        gpuEngine.writeFieldCell(copper::CopperEngine::Field::Ez, seedX, seedY, seedZ, seedValue);
        cpuEngine->SetVolt(2, seedX, seedY, seedZ, seedValue); // axis 2 = z, same convention throughout

        const std::uint32_t steps = 5;
        gpuEngine.run(steps);
        cpuEngine->IterateTS(steps);

        const copper::CopperEngine::Field fields[6] = {
            copper::CopperEngine::Field::Ex, copper::CopperEngine::Field::Ey, copper::CopperEngine::Field::Ez,
            copper::CopperEngine::Field::Hx, copper::CopperEngine::Field::Hy, copper::CopperEngine::Field::Hz,
        };
        const unsigned int axisForField[6] = {0, 1, 2, 0, 1, 2};
        bool anyNonzero = false;
        float maxAbsDiff = 0.0F;
        float maxAbsValue = 0.0F;
        for (int f = 0; f < 6; ++f) {
            const bool isH = f >= 3;
            const std::vector<float> gpuField = gpuEngine.readField(fields[f]);
            for (std::uint32_t z = 0; z < cavityGrid.dims.nz; ++z) {
                for (std::uint32_t y = 0; y < cavityGrid.dims.ny; ++y) {
                    for (std::uint32_t x = 0; x < cavityGrid.dims.nx; ++x) {
                        const float cpuValue = isH ? cpuEngine->GetCurr(axisForField[f], x, y, z)
                                                    : cpuEngine->GetVolt(axisForField[f], x, y, z);
                        const std::uint32_t idx = copper::copperGridIndex(cavityGrid.dims, x, y, z);
                        const float gpuValue = gpuField[idx];
                        maxAbsDiff = std::max(maxAbsDiff, std::fabs(gpuValue - cpuValue));
                        maxAbsValue = std::max(maxAbsValue, std::fabs(cpuValue));
                        if (cpuValue != 0.0F) {
                            anyNonzero = true;
                        }
                    }
                }
            }
        }
        std::printf("Phase 2: after %u steps, max|GPU-CPU| = %e (max|CPU field| = %e)\n", steps,
                    static_cast<double>(maxAbsDiff), static_cast<double>(maxAbsValue));
        if (!anyNonzero) {
            fail("Phase 2: CPU reference engine's fields are all still zero -- the seeded impulse never propagated");
        }
        // Float-rounding tolerance, not bit-exact equality -- Metal's compiler may fuse the
        // multiply-add differently than the CPU's, even though the kernel ports the exact same
        // operation order (see CopperFDTD.metal's own comment on where these formulas came from).
        const float tolerance = 1e-5F * std::max(maxAbsValue, 1.0F);
        if (maxAbsDiff > tolerance) {
            fail("Phase 2: GPU field values diverge from the real CPU openEMS engine beyond float-rounding "
                 "tolerance");
        }
    }

    // --- Phase 3: Metal PML boundary kernels vs. the real CPU openEMS Engine (PML enabled). ---
    // Same CPU-vs-GPU parity methodology as Phase 2, but now with PML on the x-min/x-max faces
    // instead of PEC everywhere. If pml_pre_e/pml_post_e/pml_pre_h/pml_post_h didn't faithfully
    // reproduce Engine_Ext_UPML's own flux recursion, this diverges from the CPU engine as soon as
    // the seeded impulse (placed inside the x-min PML shell itself) is touched by it. This is a
    // strictly stronger check than the Copper implementation plan's own "reflected energy within an
    // order of magnitude of PML_8's ~1e-6" pass criterion -- exact field parity with the real PML
    // implementation implies correct reflection behavior, not just roughly-right magnitude.
    {
        copper::CopperOpenEMS pmlFdtd;
        pmlFdtd.SetCSX(buildPmlCavityNoExcitation());
        pmlFdtd.SetGaussExcite(2.5e9, 2.5e9);
        pmlFdtd.Set_BC_PML(0, 8); // x-min PML, 8 cells deep
        pmlFdtd.Set_BC_PML(1, 8); // x-max PML, 8 cells deep
        pmlFdtd.Set_BC_Type(2, 0);
        pmlFdtd.Set_BC_Type(3, 0);
        pmlFdtd.Set_BC_Type(4, 0);
        pmlFdtd.Set_BC_Type(5, 0);
        pmlFdtd.SetNumberOfTimeSteps(30);
        if (pmlFdtd.SetupFDTD() != 0) {
            fail("Phase 3 fixture: openEMS::SetupFDTD() returned non-zero");
        }

        Operator* pmlOp = pmlFdtd.GetOperatorForGPU();
        Engine* pmlCpuEngine = pmlFdtd.GetEngineForCPU();
        if (pmlOp == nullptr || pmlCpuEngine == nullptr) {
            fail("Phase 3 fixture: GetOperatorForGPU()/GetEngineForCPU() returned null");
        }

        const copper::CopperYeeGrid pmlGrid = copper::buildYeeGrid(*pmlOp);
        const std::vector<copper::CopperPMLShell> pmlShells = copper::buildPMLShells(*pmlOp);
        if (pmlShells.size() != 2) {
            fail("Phase 3 fixture: expected exactly 2 PML shells (x-min, x-max) -- the fixture's grid "
                 "might be too small and fallen back to PEC (see Create_UPML's own size guard)");
        }
        copper::CopperEngine gpuEngine(pmlGrid, pmlShells);

        // Seeded at x=6, inside the x-min PML shell's own depth-8 box -- so the run exercises the
        // PML sandwich kernels directly on the seeded cell, not just eventual propagation into them.
        const std::uint32_t seedX = 6, seedY = 5, seedZ = 1;
        const float seedValue = 1.0F;
        gpuEngine.writeFieldCell(copper::CopperEngine::Field::Ez, seedX, seedY, seedZ, seedValue);
        pmlCpuEngine->SetVolt(2, seedX, seedY, seedZ, seedValue);

        const std::uint32_t steps = 20;
        gpuEngine.run(steps);
        pmlCpuEngine->IterateTS(steps);

        const copper::CopperEngine::Field fields[6] = {
            copper::CopperEngine::Field::Ex, copper::CopperEngine::Field::Ey, copper::CopperEngine::Field::Ez,
            copper::CopperEngine::Field::Hx, copper::CopperEngine::Field::Hy, copper::CopperEngine::Field::Hz,
        };
        const unsigned int axisForField[6] = {0, 1, 2, 0, 1, 2};
        bool anyNonzero = false;
        float maxAbsDiff = 0.0F;
        float maxAbsValue = 0.0F;
        for (int f = 0; f < 6; ++f) {
            const bool isH = f >= 3;
            const std::vector<float> gpuField = gpuEngine.readField(fields[f]);
            for (std::uint32_t z = 0; z < pmlGrid.dims.nz; ++z) {
                for (std::uint32_t y = 0; y < pmlGrid.dims.ny; ++y) {
                    for (std::uint32_t x = 0; x < pmlGrid.dims.nx; ++x) {
                        const float cpuValue = isH ? pmlCpuEngine->GetCurr(axisForField[f], x, y, z)
                                                    : pmlCpuEngine->GetVolt(axisForField[f], x, y, z);
                        const std::uint32_t idx = copper::copperGridIndex(pmlGrid.dims, x, y, z);
                        const float gpuValue = gpuField[idx];
                        maxAbsDiff = std::max(maxAbsDiff, std::fabs(gpuValue - cpuValue));
                        maxAbsValue = std::max(maxAbsValue, std::fabs(cpuValue));
                        if (cpuValue != 0.0F) {
                            anyNonzero = true;
                        }
                    }
                }
            }
        }
        std::printf("Phase 3: after %u steps (PML on x-min/x-max, %zu shell(s)), max|GPU-CPU| = %e "
                    "(max|CPU field| = %e)\n",
                    steps, pmlShells.size(), static_cast<double>(maxAbsDiff), static_cast<double>(maxAbsValue));
        if (!anyNonzero) {
            fail("Phase 3: CPU reference engine's fields are all still zero -- the seeded impulse never propagated");
        }
        // A looser tolerance than Phase 2's: the PML recursion does several extra multiply-adds per
        // axis per stage, so float-rounding error compounds a bit faster over the same step count.
        const float tolerance = 1e-4F * std::max(maxAbsValue, 1.0F);
        if (maxAbsDiff > tolerance) {
            fail("Phase 3: GPU PML field values diverge from the real CPU openEMS engine beyond float-rounding "
                 "tolerance");
        }
    }

    // --- Phase 3b: buildCPMLShells()'s own CFS coefficients are well-formed. ---
    // See Internal/CopperCPML.hpp's own top comment: real CPML (Roden & Gedney 2000, derived here
    // from Taflove & Hagness 3rd ed. eq. 7.93-7.110) is a *structurally different* formulation from
    // openEMS's own UPML (Section 7.8's "EC-FDTD" tensor/ADE approach) -- not a generalization of
    // it -- so there is no reference CPU implementation to diff against the way Phase 3's own
    // buildPMLShells() check has (openEMS itself has no CPML). What this phase *can* verify from the
    // formula alone (eq. 7.99/7.102, kappa=1): b[w] = exp(-(sigma_w+alpha_w)*dT/EPS0) is a decaying
    // exponential of a non-negative exponent, so it's bounded to (0,1] for every physically real
    // sigma/alpha/dT; c[w] = sigma_w*(b[w]-1)/(sigma_w+alpha_w) is a product of a non-negative
    // fraction (sigma_w/(sigma_w+alpha_w) in [0,1]) and a non-positive term (b[w]-1 in [-1,0]), so
    // it's bounded to [-1,0]. Fixture uses MUR on every face, never Set_BC_PML() -- buildCPMLShells()
    // no longer discovers its own shells from an actual Operator_Ext_UPML extension at all (see
    // CopperCPML.hpp's own top comment for why: openEMS unconditionally overwrites grid.vv/vi/ii/iv
    // at PML cells the moment Set_BC_PML() is ever called, regardless of which algorithm the caller
    // actually wants), so there's no buildPMLShells() reference to diff shell geometry against here
    // any more either -- this phase now only checks buildCPMLShells()'s own coefficients are
    // well-formed and it built the expected 6 (one per face; the whole domain, unlike Phase 3's own
    // thin-in-Z fixture, is large enough on every axis for a uniform 6-face shell).
    {
        copper::CopperOpenEMS cpmlFdtd;
        cpmlFdtd.SetCSX(buildCpmlCavityNoExcitation());
        cpmlFdtd.SetGaussExcite(2.5e9, 2.5e9);
        for (int side = 0; side < 6; ++side) {
            cpmlFdtd.Set_BC_Type(side, 2); // MUR -- see this phase's own comment for why never PML.
        }
        cpmlFdtd.SetNumberOfTimeSteps(30);
        if (cpmlFdtd.SetupFDTD() != 0) {
            fail("Phase 3b fixture: openEMS::SetupFDTD() returned non-zero");
        }
        Operator* cpmlOp = cpmlFdtd.GetOperatorForGPU();
        if (cpmlOp == nullptr) {
            fail("Phase 3b fixture: GetOperatorForGPU() returned null");
        }

        constexpr std::uint32_t kPmlDepthCellsForTest = 8;
        const double alphaMax = 2 * M_PI * 100e6 * EPS0; // matches runFDTDPortOnGPU's own default
        const std::vector<copper::CopperCPMLShell> cpmlShells =
            copper::buildCPMLShells(*cpmlOp, alphaMax, kPmlDepthCellsForTest);
        if (cpmlShells.size() != 6) {
            fail("Phase 3b: expected exactly 6 CPML shells (one per domain face)");
        }

        std::size_t checkedCount = 0;
        for (const copper::CopperCPMLShell& shell : cpmlShells) {
            for (int axis = 0; axis < 3; ++axis) {
                const std::vector<float>* arrays[4] = {&shell.bE[axis], &shell.bH[axis], &shell.cE[axis],
                                                         &shell.cH[axis]};
                static const char* names[4] = {"bE", "bH", "cE", "cH"};
                for (int a = 0; a < 4; ++a) {
                    const bool isB = a < 2;
                    for (const float v : *arrays[a]) {
                        ++checkedCount;
                        if (!std::isfinite(v)) {
                            fail(("Phase 3b: non-finite " + std::string(names[a]) + " coefficient").c_str());
                        }
                        // Small tolerance above the exact [0,1]/[-1,0] bound for float rounding.
                        if (isB ? (v < -1e-4F || v > 1.0F + 1e-4F) : (v < -1.0F - 1e-4F || v > 1e-4F)) {
                            std::printf("Phase 3b: shell coeff=%s axis=%d out of bound: %e\n", names[a], axis,
                                        static_cast<double>(v));
                            fail(("Phase 3b: " + std::string(names[a]) +
                                  " coefficient outside its mathematically guaranteed bound")
                                     .c_str());
                        }
                    }
                }
            }
        }
        std::printf("Phase 3b: buildCPMLShells() coefficients well-formed (%zu shell(s), %zu value(s) checked)\n",
                    cpmlShells.size(), checkedCount);
    }

    // --- Phase 3c: cpml_correct_e/cpml_correct_h actually run, end-to-end, without crashing or
    // producing garbage. --- Unlike Phase 3's own CPU-vs-GPU parity check, there's no CPU reference
    // to diff against here (see Phase 3b's own comment: openEMS has no CPML implementation at all),
    // so this is a basic stability/sanity smoke test -- it exercises the new kernels' buffer bindings
    // and dispatch sizes for the first time (Phase 3b only built shells on the CPU side, never ran
    // the GPU engine with them), and confirms a seeded impulse absorbed by a CPML boundary decays
    // rather than exploding, over more steps than this fixture's small size would survive if the
    // PML were reflecting the impulse back into the domain undamped.
    {
        copper::CopperOpenEMS cpmlRunFdtd;
        cpmlRunFdtd.SetCSX(buildCpmlCavityNoExcitation());
        cpmlRunFdtd.SetGaussExcite(2.5e9, 2.5e9);
        for (int side = 0; side < 6; ++side) {
            cpmlRunFdtd.Set_BC_Type(side, 2); // MUR -- see Phase 3b's own comment for why never PML.
        }
        cpmlRunFdtd.SetNumberOfTimeSteps(30);
        if (cpmlRunFdtd.SetupFDTD() != 0) {
            fail("Phase 3c fixture: openEMS::SetupFDTD() returned non-zero");
        }
        Operator* cpmlRunOp = cpmlRunFdtd.GetOperatorForGPU();
        if (cpmlRunOp == nullptr) {
            fail("Phase 3c fixture: GetOperatorForGPU() returned null");
        }

        constexpr std::uint32_t kPmlDepthCellsForTest = 8;
        const copper::CopperYeeGrid cpmlRunGrid = copper::buildYeeGrid(*cpmlRunOp);
        const double alphaMax = 2 * M_PI * 100e6 * EPS0;
        const std::vector<copper::CopperCPMLShell> cpmlRunShells =
            copper::buildCPMLShells(*cpmlRunOp, alphaMax, kPmlDepthCellsForTest);
        if (cpmlRunShells.size() != 6) {
            fail("Phase 3c fixture: expected exactly 6 CPML shells (one per domain face)");
        }
        copper::CopperEngine cpmlEngine(cpmlRunGrid, {}, {}, cpmlRunShells);

        // Inside the x-min shell's own depth-8 box, comfortably interior on Y/Z (only one shell's own
        // correction should apply here, matching the original single-face-PML seed's own intent) --
        // so the run exercises cpml_correct_e/h directly on the seeded cell from step 0.
        const std::uint32_t seedX = 6, seedY = 15, seedZ = 15;
        cpmlEngine.writeFieldCell(copper::CopperEngine::Field::Ez, seedX, seedY, seedZ, 1.0F);

        const double energyAtStart = cpmlEngine.estimateEnergy();
        const std::uint32_t steps = 60; // several round trips across this fixture's 30-cell x extent
        cpmlEngine.run(steps);
        const double energyAfter = cpmlEngine.estimateEnergy();

        const copper::CopperEngine::Field fields[6] = {
            copper::CopperEngine::Field::Ex, copper::CopperEngine::Field::Ey, copper::CopperEngine::Field::Ez,
            copper::CopperEngine::Field::Hx, copper::CopperEngine::Field::Hy, copper::CopperEngine::Field::Hz,
        };
        float maxAbsValue = 0.0F;
        for (const copper::CopperEngine::Field field : fields) {
            for (const float v : cpmlEngine.readField(field)) {
                if (!std::isfinite(v)) {
                    fail("Phase 3c: CPML run produced a non-finite field value");
                }
                maxAbsValue = std::max(maxAbsValue, std::fabs(v));
            }
        }
        std::printf("Phase 3c: after %u steps, energy %e -> %e, max|field| = %e\n", steps, energyAtStart,
                    energyAfter, static_cast<double>(maxAbsValue));
        if (energyAfter > energyAtStart) {
            fail("Phase 3c: CPML run's energy grew instead of decaying -- the seeded impulse is being "
                 "amplified, not absorbed");
        }
    }

    // --- Phase 4b: probe discovery + sampling, and the real ASCII file output. ---
    // Two cross-checks in one: (a) sampleVoltageProbe/sampleCurrentProbe applied to Copper's own
    // GPU-read-back fields vs. the identical formula applied straight to the real CPU engine's
    // fields -- this isolates CopperProbes' own indexing/sign logic from FDTD field parity, which
    // Phase 2/3/4a already cover; (b) CopperProbeWriter's actual file output, read back through a
    // reimplementation of ports.cpp's own `_loadUiFile` parsing rule, confirming the file Copper
    // writes is the file gerber2ems's existing reader already expects, unmodified.
    {
        ContinuousStructure* probeCsx = buildProbeFixture();
        copper::CopperOpenEMS probeFdtd;
        probeFdtd.SetCSX(probeCsx); // ownership transfers to probeFdtd -- probeCsx stays valid and
                                     // usable (non-owning) until probeFdtd is destroyed, same pattern
                                     // as libgerber2ems::Simulation::_csx
        probeFdtd.SetGaussExcite(2.5e9, 2.5e9);
        for (int side = 0; side < 6; ++side) {
            probeFdtd.Set_BC_Type(side, 0);
        }
        probeFdtd.SetNumberOfTimeSteps(150);
        if (probeFdtd.SetupFDTD() != 0) {
            fail("Phase 4b fixture: openEMS::SetupFDTD() returned non-zero");
        }

        Operator* probeOp = probeFdtd.GetOperatorForGPU();
        Engine* probeCpuEngine = probeFdtd.GetEngineForCPU();
        if (probeOp == nullptr || probeCpuEngine == nullptr) {
            fail("Phase 4b fixture: GetOperatorForGPU()/GetEngineForCPU() returned null");
        }

        const copper::CopperYeeGrid probeGrid = copper::buildYeeGrid(*probeOp);
        const copper::CopperExcitation probeExcitation = copper::buildExcitation(*probeOp);
        const std::vector<copper::CopperProbe> probes = copper::discoverProbes(*probeCsx, *probeOp);
        if (probes.size() != 2) {
            fail("Phase 4b: expected exactly 2 discovered probes (voltage + current)");
        }
        const copper::CopperProbe* voltageProbe = nullptr;
        const copper::CopperProbe* currentProbe = nullptr;
        for (const copper::CopperProbe& p : probes) {
            if (p.type == copper::CopperProbeType::Voltage) {
                voltageProbe = &p;
            } else {
                currentProbe = &p;
            }
        }
        if (voltageProbe == nullptr || currentProbe == nullptr) {
            fail("Phase 4b: didn't discover exactly one voltage and one current probe");
        }

        copper::CopperEngine gpuEngine(probeGrid, {}, probeExcitation);
        const std::filesystem::path tmpDir = std::filesystem::temp_directory_path();
        const std::filesystem::path voltagePath = tmpDir / voltageProbe->name;
        const std::filesystem::path currentPath = tmpDir / currentProbe->name;

        const std::uint32_t steps = 100;
        double lastGpuVoltage = 0.0;
        double lastGpuCurrent = 0.0;
        {
            // Scoped so both writers close their files (ofstream destructor) before the file
            // round-trip check below tries to read them back.
            copper::CopperProbeWriter voltageWriter(tmpDir, *voltageProbe);
            copper::CopperProbeWriter currentWriter(tmpDir, *currentProbe);
            auto gpuE = [&](std::uint32_t axis, std::uint32_t x, std::uint32_t y, std::uint32_t z) {
                return gpuEngine.readFieldCell(static_cast<copper::CopperEngine::Field>(static_cast<int>(axis)), x, y,
                                                z);
            };
            auto gpuH = [&](std::uint32_t axis, std::uint32_t x, std::uint32_t y, std::uint32_t z) {
                return gpuEngine.readFieldCell(static_cast<copper::CopperEngine::Field>(static_cast<int>(axis) + 3),
                                                x, y, z);
            };
            gpuEngine.runWithProbeSampling(steps, [&](std::uint32_t globalTimestep) -> bool {
                lastGpuVoltage = copper::sampleVoltageProbe(*voltageProbe, gpuE);
                lastGpuCurrent = copper::sampleCurrentProbe(*currentProbe, gpuH);
                // Voltage probes sample at t=numTS*dT; current probes at t=(numTS+0.5)*dT (the
                // half-timestep leapfrog/dual-mesh offset -- see
                // Engine_Interface_Base::GetTime(dualTime) and openems.cpp's own
                // SetDualTime(true) for ProbeType==1).
                voltageWriter.sample(static_cast<double>(globalTimestep) * probeGrid.timestepSeconds, lastGpuVoltage);
                currentWriter.sample((static_cast<double>(globalTimestep) + 0.5) * probeGrid.timestepSeconds,
                                     lastGpuCurrent);
                return true; // no early-exit test here -- see Phase 4c for that
            });
        }
        probeCpuEngine->IterateTS(steps);

        auto cpuE = [&](std::uint32_t axis, std::uint32_t x, std::uint32_t y, std::uint32_t z) {
            return probeCpuEngine->GetVolt(axis, x, y, z);
        };
        auto cpuH = [&](std::uint32_t axis, std::uint32_t x, std::uint32_t y, std::uint32_t z) {
            return probeCpuEngine->GetCurr(axis, x, y, z);
        };
        const double cpuVoltage = copper::sampleVoltageProbe(*voltageProbe, cpuE);
        const double cpuCurrent = copper::sampleCurrentProbe(*currentProbe, cpuH);

        std::printf("Phase 4b: voltage probe GPU=%e CPU=%e, current probe GPU=%e CPU=%e\n", lastGpuVoltage,
                    cpuVoltage, lastGpuCurrent, cpuCurrent);
        if (cpuVoltage == 0.0 && cpuCurrent == 0.0) {
            fail("Phase 4b: both probes read zero on the real CPU engine -- fixture excitation/timing looks wrong");
        }
        const double voltageTolerance = 1e-4 * std::max(std::fabs(cpuVoltage), 1e-6);
        const double currentTolerance = 1e-4 * std::max(std::fabs(cpuCurrent), 1e-6);
        if (std::fabs(lastGpuVoltage - cpuVoltage) > voltageTolerance) {
            fail("Phase 4b: voltage probe GPU/CPU mismatch beyond float-rounding tolerance");
        }
        if (std::fabs(lastGpuCurrent - cpuCurrent) > currentTolerance) {
            fail("Phase 4b: current probe GPU/CPU mismatch beyond float-rounding tolerance");
        }

        // --- File round-trip, through ports.cpp's own parsing rule. ---
        const std::vector<std::pair<double, double>> voltageRows = loadProbeFileLikePortsCpp(voltagePath);
        const std::vector<std::pair<double, double>> currentRows = loadProbeFileLikePortsCpp(currentPath);
        std::printf("Phase 4b: %s has %zu data row(s), %s has %zu data row(s)\n", voltagePath.c_str(),
                    voltageRows.size(), currentPath.c_str(), currentRows.size());
        if (voltageRows.size() != steps || currentRows.size() != steps) {
            fail("Phase 4b: probe file row count doesn't match the number of sample() calls -- header/blank "
                 "lines are probably leaking through as data rows, or vice versa");
        }
        // Last row should be the last sample() call's (t, value) -- reparsed through decimal text at
        // 12 significant digits (CopperProbeWriter's own precision), so a tight but not bit-exact
        // relative tolerance.
        const auto& [lastVoltageTime, lastVoltageValue] = voltageRows.back();
        const auto& [lastCurrentTime, lastCurrentValue] = currentRows.back();
        const double expectedLastVoltageTime = static_cast<double>(steps) * probeGrid.timestepSeconds;
        const double expectedLastCurrentTime = (static_cast<double>(steps) + 0.5) * probeGrid.timestepSeconds;
        if (std::fabs(lastVoltageTime - expectedLastVoltageTime) > 1e-9 * expectedLastVoltageTime ||
            std::fabs(lastCurrentTime - expectedLastCurrentTime) > 1e-9 * expectedLastCurrentTime) {
            fail("Phase 4b: probe file's last row time doesn't match the last runWithProbeSampling() timestep");
        }
        // CopperProbeWriter::sample() writes rawValue*probe.weight (matching
        // ProcessIntegral::Process's own `m_Results[n] * m_weight`), so the file's value is the
        // *weighted* sample, not lastGpuVoltage/lastGpuCurrent themselves.
        const double expectedVoltageValue = lastGpuVoltage * voltageProbe->weight;
        const double expectedCurrentValue = lastGpuCurrent * currentProbe->weight;
        if (std::fabs(lastVoltageValue - expectedVoltageValue) >
                1e-10 * std::max(std::fabs(expectedVoltageValue), 1e-6) ||
            std::fabs(lastCurrentValue - expectedCurrentValue) >
                1e-10 * std::max(std::fabs(expectedCurrentValue), 1e-6)) {
            fail("Phase 4b: probe file's last row value doesn't round-trip the last sampled (weighted) value");
        }
        std::filesystem::remove(voltagePath);
        std::filesystem::remove(currentPath);
    }

    // --- Phase 4c: estimateEnergy() correctness + runWithProbeSampling()'s early-exit contract. ---
    {
        copper::CopperOpenEMS energyFdtd;
        energyFdtd.SetCSX(buildTinyVacuumGrid());
        energyFdtd.SetGaussExcite(2.5e9, 2.5e9);
        for (int side = 0; side < 6; ++side) {
            energyFdtd.Set_BC_Type(side, 0);
        }
        energyFdtd.SetNumberOfTimeSteps(150);
        if (energyFdtd.SetupFDTD() != 0) {
            fail("Phase 4c fixture: openEMS::SetupFDTD() returned non-zero");
        }
        Operator* energyOp = energyFdtd.GetOperatorForGPU();
        if (energyOp == nullptr) {
            fail("Phase 4c fixture: GetOperatorForGPU() returned null");
        }
        const copper::CopperYeeGrid energyGrid = copper::buildYeeGrid(*energyOp);
        const copper::CopperExcitation energyExcitation = copper::buildExcitation(*energyOp);

        // estimateEnergy() vs. a naive full-grid CPU computation of the identical formula
        // (EPS0*sum(E^2) + MUE0*sum(H^2)) -- a genuinely separate code path (plain loop over
        // readField()'s own full-array copies, not vDSP_svesq against GPU-shared memory), so a bug
        // in either implementation is very unlikely to cancel out and pass both.
        {
            copper::CopperEngine engine(energyGrid, {}, energyExcitation);
            engine.run(20); // real steps, not just a seeded impulse, so both E and H are nonzero
            const double fastEnergy = engine.estimateEnergy();

            double naiveESumSq = 0.0, naiveHSumSq = 0.0;
            const copper::CopperEngine::Field eFields[3] = {
                copper::CopperEngine::Field::Ex, copper::CopperEngine::Field::Ey, copper::CopperEngine::Field::Ez};
            const copper::CopperEngine::Field hFields[3] = {
                copper::CopperEngine::Field::Hx, copper::CopperEngine::Field::Hy, copper::CopperEngine::Field::Hz};
            for (int axis = 0; axis < 3; ++axis) {
                for (float v : engine.readField(eFields[axis])) {
                    naiveESumSq += static_cast<double>(v) * static_cast<double>(v);
                }
                for (float v : engine.readField(hFields[axis])) {
                    naiveHSumSq += static_cast<double>(v) * static_cast<double>(v);
                }
            }
            const double naiveEnergy = EPS0 * naiveESumSq + MUE0 * naiveHSumSq;

            std::printf("Phase 4c: estimateEnergy() = %e, naive full-grid computation = %e\n", fastEnergy,
                        naiveEnergy);
            if (naiveEnergy == 0.0) {
                fail("Phase 4c: naive energy computation is zero -- fixture excitation never propagated");
            }
            if (std::fabs(fastEnergy - naiveEnergy) > 1e-4 * naiveEnergy) {
                fail("Phase 4c: estimateEnergy() disagrees with a naive full-grid computation of the same formula");
            }
        }

        // runWithProbeSampling()'s early-exit contract: returning false after N calls must leave the
        // engine's field state identical to a plain run(N) -- not run() the full requested step
        // count regardless of what the sampler returns.
        {
            copper::CopperEngine stoppedEarly(energyGrid, {}, energyExcitation);
            std::uint32_t callCount = 0;
            stoppedEarly.runWithProbeSampling(50, [&](std::uint32_t) -> bool {
                ++callCount;
                return callCount < 7; // stop after the 7th call
            });
            if (callCount != 7) {
                fail("Phase 4c: runWithProbeSampling() didn't stop as soon as the sampler returned false");
            }

            copper::CopperEngine ranSeven(energyGrid, {}, energyExcitation);
            ranSeven.run(7);

            bool fieldsMatch = true;
            for (int f = 0; f < 6 && fieldsMatch; ++f) {
                const auto field = static_cast<copper::CopperEngine::Field>(f);
                const std::vector<float> a = stoppedEarly.readField(field);
                const std::vector<float> b = ranSeven.readField(field);
                for (std::size_t i = 0; i < a.size(); ++i) {
                    if (a[i] != b[i]) {
                        fieldsMatch = false;
                        break;
                    }
                }
            }
            if (!fieldsMatch) {
                fail("Phase 4c: early-exit-at-7 field state doesn't bit-match a "
                     "plain run(7) -- "
                     "runWithProbeSampling() ran a different number of "
                     "iterations than the sampler requested");
            }
            std::printf("Phase 4c: early exit after %u/50 calls matches a "
                        "plain run(7) bit-for-bit\n",
                        callCount);
        }
    }

    // --- Phase 4d: a mid-step E correction must feed this same timestep's H
    // update. ---
    {
        copper::CopperOpenEMS correctionFdtd;
        correctionFdtd.SetCSX(buildPecCavityNoExcitation());
        correctionFdtd.SetGaussExcite(2.5e9, 2.5e9);
        for (int side = 0; side < 6; ++side) {
            correctionFdtd.Set_BC_Type(side, 0);
        }
        correctionFdtd.SetNumberOfTimeSteps(1);
        if (correctionFdtd.SetupFDTD() != 0) {
            fail("Phase 4d fixture: openEMS::SetupFDTD() returned non-zero");
        }
        Operator* correctionOp = correctionFdtd.GetOperatorForGPU();
        if (correctionOp == nullptr) {
            fail("Phase 4d fixture: GetOperatorForGPU() returned null");
        }

        const copper::CopperYeeGrid correctionGrid = copper::buildYeeGrid(*correctionOp);
        copper::CopperEngine corrected(correctionGrid);
        std::uint32_t correctionCalls = 0;
        corrected.runWithProbeSampling(
            1, [](std::uint32_t) { return true; },
            [&]() {
                ++correctionCalls;
                // update_h_interior's Hx curl at (1,1,1) directly consumes
                // Ez(1,1,1). With the old post-H callback this write arrived one
                // timestep too late and Hx stayed zero.
                corrected.writeFieldCell(copper::CopperEngine::Field::Ez, 1, 1, 1, 1.0F);
            });

        const float transportedCurrent = corrected.readFieldCell(copper::CopperEngine::Field::Hx, 1, 1, 1);
        if (correctionCalls != 1) {
            fail("Phase 4d: mid-step correction wasn't called exactly once");
        }
        if (transportedCurrent == 0.0F) {
            fail("Phase 4d: current update did not consume the same timestep's "
                 "corrected voltage");
        }
        std::printf("Phase 4d: corrected Ez produced same-step Hx=%e\n", transportedCurrent);
    }

    std::printf("Copper_smoketest: PASS\n");
    return EXIT_SUCCESS;
}
