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

/// TEMPORARY diagnostic fixture: same PEC vacuum cavity shape as buildPecCavityNoExcitation(), but
/// at the real Keyboard Hub board's own length scale -- SetDeltaUnit(1e-6) (1 micron, not 1mm) and
/// 50-native-unit (50 micron) cell spacing, matching that board's own near-port cell size -- to
/// isolate whether openEMS's own vi/vv coefficients scale differently at this drawing-unit/cell-size
/// combination than the existing 1mm fixture, independent of any hand-derived (and, twice now,
/// wrong) dimensional-analysis reasoning about what "should" happen.
ContinuousStructure* buildMicronScaleVacuumGrid() {
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
        // TEMPORARY diagnostic: sanity-check coefficient magnitude on a simple, well-understood
        // 1mm-cell vacuum cavity -- comparing against a real board's own ~1e-9-magnitude vi/iv to
        // determine whether that's a plausible physical scale or a sign of a units/extraction bug.
        {
            const std::uint32_t idx = copper::copperGridIndex(cavityGrid.dims, 5, 5, 1);
            std::printf("[DIAG] 1mm vacuum cavity: dt=%.6e vv2=%.6e vi2=%.6e (cellCount=%u)\n",
                        cavityGrid.timestepSeconds, cavityGrid.vv[2][idx], cavityGrid.vi[2][idx],
                        cavityGrid.dims.cellCount());
        }
        {
            // TEMPORARY diagnostic: same PEC vacuum cavity, but at the real board's own drawing
            // unit (1 micron) and cell size (50 microns) -- see buildMicronScaleVacuumGrid()'s own
            // doc comment.
            copper::CopperOpenEMS micronFdtd;
            micronFdtd.SetCSX(buildMicronScaleVacuumGrid());
            micronFdtd.SetGaussExcite(2.5e9, 2.5e9);
            for (int side = 0; side < 6; ++side) {
                micronFdtd.Set_BC_Type(side, 0);
            }
            micronFdtd.SetNumberOfTimeSteps(10);
            if (micronFdtd.SetupFDTD() != 0) {
                fail("[DIAG] micron-scale fixture: openEMS::SetupFDTD() returned non-zero");
            }
            Operator* micronOp = micronFdtd.GetOperatorForGPU();
            if (micronOp == nullptr) {
                fail("[DIAG] micron-scale fixture: GetOperatorForGPU() returned null");
            }
            const copper::CopperYeeGrid micronGrid = copper::buildYeeGrid(*micronOp);
            const std::uint32_t idx = copper::copperGridIndex(micronGrid.dims, 5, 5, 1);
            std::printf("[DIAG] 50-micron vacuum cavity (same code, real board's own drawing unit): dt=%.6e "
                        "vv2=%.6e vi2=%.6e (cellCount=%u)\n",
                        micronGrid.timestepSeconds, micronGrid.vv[2][idx], micronGrid.vi[2][idx],
                        micronGrid.dims.cellCount());
        }
        {
            // TEMPORARY diagnostic: same 50-micron cavity, but filled with a uniform eps_r=4.5
            // dielectric (matching this board's own substrate) -- isolates whether a plain
            // dielectric at this cell size reproduces the real board's own anomalous vi, or whether
            // it's specific to the real board's own graded, non-uniform mesh.
            auto* dielCsx = new ContinuousStructure();
            CSRectGrid* dielGridLines = dielCsx->GetGrid();
            dielGridLines->SetDeltaUnit(1e-6);
            for (int i = 0; i <= 10; ++i) {
                dielGridLines->AddDiscLine(0, static_cast<double>(i) * 50.0);
                dielGridLines->AddDiscLine(1, static_cast<double>(i) * 50.0);
            }
            dielGridLines->AddDiscLine(2, 0.0);
            dielGridLines->AddDiscLine(2, 50.0);
            dielGridLines->AddDiscLine(2, 100.0);
            auto* dielectric = new CSPropMaterial(dielCsx->GetParameterSet());
            dielectric->SetEpsilon(4.5);
            dielCsx->AddProperty(dielectric);
            auto* box = new CSPrimBox(dielCsx->GetParameterSet(), dielectric);
            box->SetCoord(0, 0.0);
            box->SetCoord(1, 500.0);
            box->SetCoord(2, 0.0);
            box->SetCoord(3, 500.0);
            box->SetCoord(4, 0.0);
            box->SetCoord(5, 100.0);

            copper::CopperOpenEMS dielFdtd;
            dielFdtd.SetCSX(dielCsx);
            dielFdtd.SetGaussExcite(2.5e9, 2.5e9);
            for (int side = 0; side < 6; ++side) {
                dielFdtd.Set_BC_Type(side, 0);
            }
            dielFdtd.SetNumberOfTimeSteps(10);
            if (dielFdtd.SetupFDTD() != 0) {
                fail("[DIAG] micron-scale dielectric fixture: openEMS::SetupFDTD() returned non-zero");
            }
            Operator* dielOp = dielFdtd.GetOperatorForGPU();
            if (dielOp == nullptr) {
                fail("[DIAG] micron-scale dielectric fixture: GetOperatorForGPU() returned null");
            }
            const copper::CopperYeeGrid dielGrid = copper::buildYeeGrid(*dielOp);
            const std::uint32_t idx = copper::copperGridIndex(dielGrid.dims, 5, 5, 1);
            std::printf("[DIAG] 50-micron eps_r=4.5 dielectric cavity (same code/scale, uniform dielectric): "
                        "dt=%.6e vv2=%.6e vi2=%.6e (cellCount=%u)\n",
                        dielGrid.timestepSeconds, dielGrid.vv[2][idx], dielGrid.vi[2][idx],
                        dielGrid.dims.cellCount());
        }
        {
            // TEMPORARY diagnostic: same 50-micron eps_r=4.5 dielectric, but now sandwiched between
            // two PEC (copper) planes in Z -- top and bottom of the domain -- matching the real
            // board's own trace/dielectric/reference-plane cross-section at the excited port (unlike
            // the plain-dielectric fixture above, which has no conductor anywhere nearby). Z gets 4
            // cells (5 lines) instead of 2, so the sampled cell isn't immediately adjacent to *both*
            // PEC planes at once -- closer to the real excitation gap's own 4-cell Z span.
            auto* sandwichCsx = new ContinuousStructure();
            CSRectGrid* sandwichGridLines = sandwichCsx->GetGrid();
            sandwichGridLines->SetDeltaUnit(1e-6);
            for (int i = 0; i <= 10; ++i) {
                sandwichGridLines->AddDiscLine(0, static_cast<double>(i) * 50.0);
                sandwichGridLines->AddDiscLine(1, static_cast<double>(i) * 50.0);
            }
            for (int i = 0; i <= 4; ++i) {
                sandwichGridLines->AddDiscLine(2, static_cast<double>(i) * 50.0);
            }
            auto* sandwichDielectric = new CSPropMaterial(sandwichCsx->GetParameterSet());
            sandwichDielectric->SetEpsilon(4.5);
            sandwichCsx->AddProperty(sandwichDielectric);
            auto* sandwichBox = new CSPrimBox(sandwichCsx->GetParameterSet(), sandwichDielectric);
            sandwichBox->SetCoord(0, 0.0);
            sandwichBox->SetCoord(1, 500.0);
            sandwichBox->SetCoord(2, 0.0);
            sandwichBox->SetCoord(3, 500.0);
            sandwichBox->SetCoord(4, 0.0);
            sandwichBox->SetCoord(5, 200.0);
            auto* pec = new CSPropMetal(sandwichCsx->GetParameterSet());
            sandwichCsx->AddProperty(pec);
            auto* bottomPlane = new CSPrimBox(sandwichCsx->GetParameterSet(), pec);
            bottomPlane->SetCoord(0, 0.0);
            bottomPlane->SetCoord(1, 500.0);
            bottomPlane->SetCoord(2, 0.0);
            bottomPlane->SetCoord(3, 500.0);
            bottomPlane->SetCoord(4, 0.0);
            bottomPlane->SetCoord(5, 0.0);
            auto* topPlane = new CSPrimBox(sandwichCsx->GetParameterSet(), pec);
            topPlane->SetCoord(0, 0.0);
            topPlane->SetCoord(1, 500.0);
            topPlane->SetCoord(2, 0.0);
            topPlane->SetCoord(3, 500.0);
            topPlane->SetCoord(4, 200.0);
            topPlane->SetCoord(5, 200.0);

            copper::CopperOpenEMS sandwichFdtd;
            sandwichFdtd.SetCSX(sandwichCsx);
            sandwichFdtd.SetGaussExcite(2.5e9, 2.5e9);
            for (int side = 0; side < 6; ++side) {
                sandwichFdtd.Set_BC_Type(side, 0);
            }
            sandwichFdtd.SetNumberOfTimeSteps(10);
            if (sandwichFdtd.SetupFDTD() != 0) {
                fail("[DIAG] PEC-sandwich fixture: openEMS::SetupFDTD() returned non-zero");
            }
            Operator* sandwichOp = sandwichFdtd.GetOperatorForGPU();
            if (sandwichOp == nullptr) {
                fail("[DIAG] PEC-sandwich fixture: GetOperatorForGPU() returned null");
            }
            const copper::CopperYeeGrid sandwichGrid = copper::buildYeeGrid(*sandwichOp);
            const std::uint32_t idx = copper::copperGridIndex(sandwichGrid.dims, 5, 5, 2);
            std::printf("[DIAG] 50-micron eps_r=4.5 dielectric BETWEEN two PEC planes (microstrip-like Z "
                        "cross-section): dt=%.6e vv2=%.6e vi2=%.6e (cellCount=%u)\n",
                        sandwichGrid.timestepSeconds, sandwichGrid.vv[2][idx], sandwichGrid.vi[2][idx],
                        sandwichGrid.dims.cellCount());
        }
        {
            // TEMPORARY diagnostic: same uniform eps_r=4.5 dielectric, no PEC, but with the real
            // Keyboard Hub board's own actual Z-axis cell thicknesses (36 cells, 25um to 551um, up
            // to a ~4x neighbor-to-neighbor grading ratio) instead of a uniform 50um spacing --
            // isolates whether the *grading itself* (not a material discontinuity) is what triggers
            // the anomaly. X/Y stay uniform, 50um, matching every fixture above.
            static const double kRealZThicknessesUm[] = {
                551.031647, 500.000000, 358.618138, 233.393072, 151.895067, 98.855168,  64.336153,
                41.870756,  27.250000,  27.250000,  27.250000,  27.250000,  25.000000,  25.000000,
                25.000000,  25.000000,  101.500000, 101.500000, 101.500000, 101.500000, 25.000000,
                25.000000,  25.000000,  25.000000,  27.250000,  27.250000,  27.250000,  27.250000,
                42.345938,  65.804713,  102.259166, 158.908634, 246.940738, 383.740811, 500.000000,
                500.000000,
            };
            auto* gradedCsx = new ContinuousStructure();
            CSRectGrid* gradedGridLines = gradedCsx->GetGrid();
            gradedGridLines->SetDeltaUnit(1e-6);
            for (int i = 0; i <= 10; ++i) {
                gradedGridLines->AddDiscLine(0, static_cast<double>(i) * 50.0);
                gradedGridLines->AddDiscLine(1, static_cast<double>(i) * 50.0);
            }
            double zPos = 0.0;
            gradedGridLines->AddDiscLine(2, zPos);
            for (const double thickness : kRealZThicknessesUm) {
                zPos += thickness;
                gradedGridLines->AddDiscLine(2, zPos);
            }
            const double zTotal = zPos;
            auto* gradedDielectric = new CSPropMaterial(gradedCsx->GetParameterSet());
            gradedDielectric->SetEpsilon(4.5);
            gradedCsx->AddProperty(gradedDielectric);
            auto* gradedBox = new CSPrimBox(gradedCsx->GetParameterSet(), gradedDielectric);
            gradedBox->SetCoord(0, 0.0);
            gradedBox->SetCoord(1, 500.0);
            gradedBox->SetCoord(2, 0.0);
            gradedBox->SetCoord(3, 500.0);
            gradedBox->SetCoord(4, 0.0);
            gradedBox->SetCoord(5, zTotal);

            copper::CopperOpenEMS gradedFdtd;
            gradedFdtd.SetCSX(gradedCsx);
            gradedFdtd.SetGaussExcite(2.5e9, 2.5e9);
            for (int side = 0; side < 6; ++side) {
                gradedFdtd.Set_BC_Type(side, 0);
            }
            gradedFdtd.SetNumberOfTimeSteps(10);
            if (gradedFdtd.SetupFDTD() != 0) {
                fail("[DIAG] graded-Z fixture: openEMS::SetupFDTD() returned non-zero");
            }
            Operator* gradedOp = gradedFdtd.GetOperatorForGPU();
            if (gradedOp == nullptr) {
                fail("[DIAG] graded-Z fixture: GetOperatorForGPU() returned null");
            }
            const copper::CopperYeeGrid gradedGrid = copper::buildYeeGrid(*gradedOp);
            // Sample around z-index 24, matching the real excitation's own relative position (24 of
            // 37 lines) in this identically-36-cell Z axis.
            const std::uint32_t idx = copper::copperGridIndex(gradedGrid.dims, 5, 5, 24);
            std::printf("[DIAG] 50-micron XY, real board's own graded Z (36 cells, uniform eps_r=4.5, no PEC): "
                        "dt=%.6e vv2=%.6e vi2=%.6e (cellCount=%u)\n",
                        gradedGrid.timestepSeconds, gradedGrid.vv[2][idx], gradedGrid.vi[2][idx],
                        gradedGrid.dims.cellCount());
        }
        {
            // TEMPORARY diagnostic: the full real stackup -- same graded Z axis as above, but now
            // cells 0..7 and 28..35 (the PML/margin region above/below the actual board, per the
            // real log's own 8+20+8 structure) are left as vacuum/air, cells 8..27 are the real
            // 5-layer substrate (eps_r 4.1/4.6/4.16/4.6/4.1, matching the real board's own KiCad
            // stackup exactly), and thin PEC (copper) planes sit at each of the 6 layer boundaries
            // (F.Cu/In1-4.Cu/B.Cu). The closest reproduction yet of the real excited cell's own
            // surroundings, short of the real (irregular) copper trace/via/pad geometry itself.
            static const double kRealZThicknessesUm2[] = {
                551.031647, 500.000000, 358.618138, 233.393072, 151.895067, 98.855168,  64.336153,
                41.870756,  27.250000,  27.250000,  27.250000,  27.250000,  25.000000,  25.000000,
                25.000000,  25.000000,  101.500000, 101.500000, 101.500000, 101.500000, 25.000000,
                25.000000,  25.000000,  25.000000,  27.250000,  27.250000,  27.250000,  27.250000,
                42.345938,  65.804713,  102.259166, 158.908634, 246.940738, 383.740811, 500.000000,
                500.000000,
            };
            std::vector<double> zLines;
            zLines.push_back(0.0);
            double cum = 0.0;
            for (const double thickness : kRealZThicknessesUm2) {
                cum += thickness;
                zLines.push_back(cum);
            }
            auto* stackCsx = new ContinuousStructure();
            CSRectGrid* stackGridLines = stackCsx->GetGrid();
            stackGridLines->SetDeltaUnit(1e-6);
            for (int i = 0; i <= 10; ++i) {
                stackGridLines->AddDiscLine(0, static_cast<double>(i) * 50.0);
                stackGridLines->AddDiscLine(1, static_cast<double>(i) * 50.0);
            }
            for (const double z : zLines) {
                stackGridLines->AddDiscLine(2, z);
            }

            const std::array<double, 5> layerEpsilon = {4.1, 4.6, 4.16, 4.6, 4.1};
            const std::array<std::uint32_t, 5> layerStartIdx = {8, 12, 16, 20, 24}; // indices into zLines
            for (std::size_t layer = 0; layer < layerEpsilon.size(); ++layer) {
                auto* layerMat = new CSPropMaterial(stackCsx->GetParameterSet());
                layerMat->SetEpsilon(layerEpsilon[layer]);
                stackCsx->AddProperty(layerMat);
                auto* layerBox = new CSPrimBox(stackCsx->GetParameterSet(), layerMat);
                layerBox->SetCoord(0, 0.0);
                layerBox->SetCoord(1, 500.0);
                layerBox->SetCoord(2, 0.0);
                layerBox->SetCoord(3, 500.0);
                layerBox->SetCoord(4, zLines[layerStartIdx[layer]]);
                layerBox->SetCoord(5, zLines[layerStartIdx[layer] + 4]);
            }
            auto* stackCopper = new CSPropMetal(stackCsx->GetParameterSet());
            stackCsx->AddProperty(stackCopper);
            for (const std::uint32_t boundaryIdx : {8u, 12u, 16u, 20u, 24u, 28u}) {
                auto* copperPlane = new CSPrimBox(stackCsx->GetParameterSet(), stackCopper);
                copperPlane->SetCoord(0, 0.0);
                copperPlane->SetCoord(1, 500.0);
                copperPlane->SetCoord(2, 0.0);
                copperPlane->SetCoord(3, 500.0);
                copperPlane->SetCoord(4, zLines[boundaryIdx]);
                copperPlane->SetCoord(5, zLines[boundaryIdx]);
            }

            copper::CopperOpenEMS stackFdtd;
            stackFdtd.SetCSX(stackCsx);
            stackFdtd.SetGaussExcite(2.5e9, 2.5e9);
            for (int side = 0; side < 6; ++side) {
                stackFdtd.Set_BC_Type(side, 0);
            }
            stackFdtd.SetNumberOfTimeSteps(10);
            if (stackFdtd.SetupFDTD() != 0) {
                fail("[DIAG] full-stackup fixture: openEMS::SetupFDTD() returned non-zero");
            }
            Operator* stackOp = stackFdtd.GetOperatorForGPU();
            if (stackOp == nullptr) {
                fail("[DIAG] full-stackup fixture: GetOperatorForGPU() returned null");
            }
            const copper::CopperYeeGrid stackGrid = copper::buildYeeGrid(*stackOp);
            // Sample at z-index 25, inside the eps_r=4.1 layer 5 -- matches the real excited cell's
            // own layer (24..27) as closely as this fixture's coarser 4-cells-per-layer allows.
            const std::uint32_t idx = copper::copperGridIndex(stackGrid.dims, 5, 5, 25);
            std::printf("[DIAG] full 5-layer stackup (real eps_r per layer, PEC layer boundaries, air "
                        "margin): dt=%.6e vv2=%.6e vi2=%.6e (cellCount=%u)\n",
                        stackGrid.timestepSeconds, stackGrid.vv[2][idx], stackGrid.vi[2][idx],
                        stackGrid.dims.cellCount());
        }
        {
            // TEMPORARY diagnostic: identical fixture to the block above (same real Z stackup,
            // same real epsilon per layer, same PEC layer boundaries), but with the real board's
            // own XY line COUNT (137 x 136, not 11 x 11) at uniform 50um spacing -- isolates
            // whether domain *scale* (not structure -- every fixture so far used a tiny ~10x10
            // cell XY domain) is the missing variable, since a structurally-identical small-domain
            // fixture did not reproduce the anomaly.
            static const double kRealZThicknessesUm4[] = {
                551.031647, 500.000000, 358.618138, 233.393072, 151.895067, 98.855168,  64.336153,
                41.870756,  27.250000,  27.250000,  27.250000,  27.250000,  25.000000,  25.000000,
                25.000000,  25.000000,  101.500000, 101.500000, 101.500000, 101.500000, 25.000000,
                25.000000,  25.000000,  25.000000,  27.250000,  27.250000,  27.250000,  27.250000,
                42.345938,  65.804713,  102.259166, 158.908634, 246.940738, 383.740811, 500.000000,
                500.000000,
            };
            std::vector<double> bigZLines;
            bigZLines.push_back(0.0);
            double bigCum = 0.0;
            for (const double thickness : kRealZThicknessesUm4) {
                bigCum += thickness;
                bigZLines.push_back(bigCum);
            }
            auto* bigCsx = new ContinuousStructure();
            CSRectGrid* bigGridLines = bigCsx->GetGrid();
            bigGridLines->SetDeltaUnit(1e-6);
            for (int i = 0; i <= 136; ++i) {
                bigGridLines->AddDiscLine(0, static_cast<double>(i) * 50.0);
            }
            for (int i = 0; i <= 135; ++i) {
                bigGridLines->AddDiscLine(1, static_cast<double>(i) * 50.0);
            }
            for (const double z : bigZLines) {
                bigGridLines->AddDiscLine(2, z);
            }
            const double bigXMax = 136.0 * 50.0;
            const double bigYMax = 135.0 * 50.0;
            const std::array<double, 5> bigLayerEpsilon = {4.1, 4.6, 4.16, 4.6, 4.1};
            const std::array<std::uint32_t, 5> bigLayerStartIdx = {8, 12, 16, 20, 24};
            for (std::size_t layer = 0; layer < bigLayerEpsilon.size(); ++layer) {
                auto* layerMat = new CSPropMaterial(bigCsx->GetParameterSet());
                layerMat->SetEpsilon(bigLayerEpsilon[layer]);
                bigCsx->AddProperty(layerMat);
                auto* layerBox = new CSPrimBox(bigCsx->GetParameterSet(), layerMat);
                layerBox->SetCoord(0, 0.0);
                layerBox->SetCoord(1, bigXMax);
                layerBox->SetCoord(2, 0.0);
                layerBox->SetCoord(3, bigYMax);
                layerBox->SetCoord(4, bigZLines[bigLayerStartIdx[layer]]);
                layerBox->SetCoord(5, bigZLines[bigLayerStartIdx[layer] + 4]);
            }
            auto* bigCopper = new CSPropMetal(bigCsx->GetParameterSet());
            bigCsx->AddProperty(bigCopper);
            for (const std::uint32_t boundaryIdx : {8u, 12u, 16u, 20u, 24u, 28u}) {
                auto* copperPlane = new CSPrimBox(bigCsx->GetParameterSet(), bigCopper);
                copperPlane->SetCoord(0, 0.0);
                copperPlane->SetCoord(1, bigXMax);
                copperPlane->SetCoord(2, 0.0);
                copperPlane->SetCoord(3, bigYMax);
                copperPlane->SetCoord(4, bigZLines[boundaryIdx]);
                copperPlane->SetCoord(5, bigZLines[boundaryIdx]);
            }

            copper::CopperOpenEMS bigFdtd;
            bigFdtd.SetCSX(bigCsx);
            bigFdtd.SetGaussExcite(2.5e9, 2.5e9);
            for (int side = 0; side < 6; ++side) {
                bigFdtd.Set_BC_Type(side, 0);
            }
            bigFdtd.SetNumberOfTimeSteps(10);
            if (bigFdtd.SetupFDTD() != 0) {
                fail("[DIAG] real-scale-XY fixture: openEMS::SetupFDTD() returned non-zero");
            }
            Operator* bigOp = bigFdtd.GetOperatorForGPU();
            if (bigOp == nullptr) {
                fail("[DIAG] real-scale-XY fixture: GetOperatorForGPU() returned null");
            }
            const copper::CopperYeeGrid bigGrid = copper::buildYeeGrid(*bigOp);
            const std::uint32_t bigCenterIdx = copper::copperGridIndex(bigGrid.dims, 68, 68, 25);
            const std::uint32_t bigThickIdx = copper::copperGridIndex(bigGrid.dims, 68, 68, 18);
            std::printf("[DIAG] REAL-SCALE XY (137x136), real Z stackup, sampled in a thin layer "
                        "(68,68,25): dt=%.6e vv2=%.6e vi2=%.6e (cellCount=%u)\n",
                        bigGrid.timestepSeconds, bigGrid.vv[2][bigCenterIdx], bigGrid.vi[2][bigCenterIdx],
                        bigGrid.dims.cellCount());
            std::printf("[DIAG] REAL-SCALE XY (137x136), real Z stackup, sampled in the thick layer "
                        "(68,68,18): dt=%.6e vv2=%.6e vi2=%.6e\n",
                        bigGrid.timestepSeconds, bigGrid.vv[2][bigThickIdx], bigGrid.vi[2][bigThickIdx]);
        }
        {
            // TEMPORARY diagnostic: the same full 5-layer stackup, freshly rebuilt (not reusing the
            // already-SetupFDTD()'d fixture above), plus a 200um-square copper via barrel straight
            // through the whole Z stack at x/y=[150,350] -- roughly the real board's own via
            // drill+annular-ring scale. Tests whether a *localized* copper feature (mixed
            // copper/dielectric material averaging within/around a handful of cells), unlike every
            // full-XY-extent flat plane tested so far, is what triggers the anomaly -- sampled both
            // inside the via's own footprint and at/outside its edge.
            static const double kRealZThicknessesUm3[] = {
                551.031647, 500.000000, 358.618138, 233.393072, 151.895067, 98.855168,  64.336153,
                41.870756,  27.250000,  27.250000,  27.250000,  27.250000,  25.000000,  25.000000,
                25.000000,  25.000000,  101.500000, 101.500000, 101.500000, 101.500000, 25.000000,
                25.000000,  25.000000,  25.000000,  27.250000,  27.250000,  27.250000,  27.250000,
                42.345938,  65.804713,  102.259166, 158.908634, 246.940738, 383.740811, 500.000000,
                500.000000,
            };
            std::vector<double> viaZLines;
            viaZLines.push_back(0.0);
            double viaCum = 0.0;
            for (const double thickness : kRealZThicknessesUm3) {
                viaCum += thickness;
                viaZLines.push_back(viaCum);
            }
            const double viaZTotal = viaCum;

            auto* viaCsx = new ContinuousStructure();
            CSRectGrid* viaGridLines = viaCsx->GetGrid();
            viaGridLines->SetDeltaUnit(1e-6);
            for (int i = 0; i <= 10; ++i) {
                viaGridLines->AddDiscLine(0, static_cast<double>(i) * 50.0);
                viaGridLines->AddDiscLine(1, static_cast<double>(i) * 50.0);
            }
            for (const double z : viaZLines) {
                viaGridLines->AddDiscLine(2, z);
            }
            const std::array<double, 5> viaLayerEpsilon = {4.1, 4.6, 4.16, 4.6, 4.1};
            const std::array<std::uint32_t, 5> viaLayerStartIdx = {8, 12, 16, 20, 24};
            for (std::size_t layer = 0; layer < viaLayerEpsilon.size(); ++layer) {
                auto* layerMat = new CSPropMaterial(viaCsx->GetParameterSet());
                layerMat->SetEpsilon(viaLayerEpsilon[layer]);
                viaCsx->AddProperty(layerMat);
                auto* layerBox = new CSPrimBox(viaCsx->GetParameterSet(), layerMat);
                layerBox->SetCoord(0, 0.0);
                layerBox->SetCoord(1, 500.0);
                layerBox->SetCoord(2, 0.0);
                layerBox->SetCoord(3, 500.0);
                layerBox->SetCoord(4, viaZLines[viaLayerStartIdx[layer]]);
                layerBox->SetCoord(5, viaZLines[viaLayerStartIdx[layer] + 4]);
            }
            auto* viaCopper = new CSPropMetal(viaCsx->GetParameterSet());
            viaCsx->AddProperty(viaCopper);
            for (const std::uint32_t boundaryIdx : {8u, 12u, 16u, 20u, 24u, 28u}) {
                auto* copperPlane = new CSPrimBox(viaCsx->GetParameterSet(), viaCopper);
                copperPlane->SetCoord(0, 0.0);
                copperPlane->SetCoord(1, 500.0);
                copperPlane->SetCoord(2, 0.0);
                copperPlane->SetCoord(3, 500.0);
                copperPlane->SetCoord(4, viaZLines[boundaryIdx]);
                copperPlane->SetCoord(5, viaZLines[boundaryIdx]);
            }
            // Offset from the mesh's own 50um grid lines (150/350) by 25um -- 175/325 -- so the
            // via's own edge falls *mid-cell* (cells x=3 [150,200] and x=6 [300,350] are genuinely
            // half copper/half dielectric), not exactly on a cell boundary like the first attempt
            // (which made every cell either fully inside or fully outside, never actually exercising
            // quarter-cell averaging at all).
            auto* viaBarrel = new CSPrimBox(viaCsx->GetParameterSet(), viaCopper);
            viaBarrel->SetCoord(0, 175.0);
            viaBarrel->SetCoord(1, 325.0);
            viaBarrel->SetCoord(2, 175.0);
            viaBarrel->SetCoord(3, 325.0);
            viaBarrel->SetCoord(4, 0.0);
            viaBarrel->SetCoord(5, viaZTotal);
            // Higher priority than the dielectric layer boxes (left at CSXCAD's own default, 0) --
            // without this, the via has no visible effect at all (confirmed: identical vi2 whether
            // sampled inside, outside, or at the via's own edge), matching the real gerber2ems code's
            // own convention of always setting explicit priorities for overlapping primitives.
            viaBarrel->SetPriority(10);

            copper::CopperOpenEMS viaFdtd;
            viaFdtd.SetCSX(viaCsx);
            viaFdtd.SetGaussExcite(2.5e9, 2.5e9);
            for (int side = 0; side < 6; ++side) {
                viaFdtd.Set_BC_Type(side, 0);
            }
            viaFdtd.SetNumberOfTimeSteps(10);
            if (viaFdtd.SetupFDTD() != 0) {
                fail("[DIAG] via-barrel fixture: openEMS::SetupFDTD() returned non-zero");
            }
            Operator* viaOp = viaFdtd.GetOperatorForGPU();
            if (viaOp == nullptr) {
                fail("[DIAG] via-barrel fixture: GetOperatorForGPU() returned null");
            }
            const copper::CopperYeeGrid viaGrid = copper::buildYeeGrid(*viaOp);
            const std::uint32_t insideIdx = copper::copperGridIndex(viaGrid.dims, 5, 5, 25);
            const std::uint32_t outsideIdx = copper::copperGridIndex(viaGrid.dims, 8, 8, 25);
            const std::uint32_t edgeIdx = copper::copperGridIndex(viaGrid.dims, 3, 5, 25);
            std::printf("[DIAG] full stackup + 200um copper via barrel, sampled INSIDE via footprint "
                        "(x=5,y=5): dt=%.6e vv2=%.6e vi2=%.6e\n",
                        viaGrid.timestepSeconds, viaGrid.vv[2][insideIdx], viaGrid.vi[2][insideIdx]);
            std::printf("[DIAG] full stackup + 200um copper via barrel, sampled OUTSIDE via footprint "
                        "(x=8,y=8): dt=%.6e vv2=%.6e vi2=%.6e\n",
                        viaGrid.timestepSeconds, viaGrid.vv[2][outsideIdx], viaGrid.vi[2][outsideIdx]);
            std::printf("[DIAG] full stackup + 200um copper via barrel, sampled at via's own EDGE, "
                        "genuinely mixed copper/dielectric cell (x=3,y=5): dt=%.6e vv2=%.6e vi2=%.6e\n",
                        viaGrid.timestepSeconds, viaGrid.vv[2][edgeIdx], viaGrid.vi[2][edgeIdx]);
        }
        {
            // TEMPORARY diagnostic: the real remaining untested piece -- LumpedPort places a
            // CSPropLumpedElement (resistance=portConfig.impedance(), here 45 ohms, matching the
            // real board's own involved_nets entry) at the *exact same box* as the excitation
            // itself (ports.cpp's own LumpedPort constructor). Unlike every plain dielectric/metal
            // material tested so far, a lumped element directly rewrites vv/vi within its own box
            // via Operator_Ext_LumpedRLC -- the same *category* of mechanism (coefficient
            // overwriting) as PML, just for a different reason. Small XY footprint (100um square,
            // matching the real port's own ~150-200um scale) placed in the thin layer nearest the
            // board's own top (z-index 24..27 in this fixture, matching the real excited cell's own
            // Z range), sampled both inside the resistor box and just outside it.
            static const double kRealZThicknessesUm5[] = {
                551.031647, 500.000000, 358.618138, 233.393072, 151.895067, 98.855168,  64.336153,
                41.870756,  27.250000,  27.250000,  27.250000,  27.250000,  25.000000,  25.000000,
                25.000000,  25.000000,  101.500000, 101.500000, 101.500000, 101.500000, 25.000000,
                25.000000,  25.000000,  25.000000,  27.250000,  27.250000,  27.250000,  27.250000,
                42.345938,  65.804713,  102.259166, 158.908634, 246.940738, 383.740811, 500.000000,
                500.000000,
            };
            std::vector<double> leZLines;
            leZLines.push_back(0.0);
            double leCum = 0.0;
            for (const double thickness : kRealZThicknessesUm5) {
                leCum += thickness;
                leZLines.push_back(leCum);
            }
            auto* leCsx = new ContinuousStructure();
            CSRectGrid* leGridLines = leCsx->GetGrid();
            leGridLines->SetDeltaUnit(1e-6);
            for (int i = 0; i <= 10; ++i) {
                leGridLines->AddDiscLine(0, static_cast<double>(i) * 50.0);
                leGridLines->AddDiscLine(1, static_cast<double>(i) * 50.0);
            }
            for (const double z : leZLines) {
                leGridLines->AddDiscLine(2, z);
            }
            const std::array<double, 5> leLayerEpsilon = {4.1, 4.6, 4.16, 4.6, 4.1};
            const std::array<std::uint32_t, 5> leLayerStartIdx = {8, 12, 16, 20, 24};
            for (std::size_t layer = 0; layer < leLayerEpsilon.size(); ++layer) {
                auto* layerMat = new CSPropMaterial(leCsx->GetParameterSet());
                layerMat->SetEpsilon(leLayerEpsilon[layer]);
                leCsx->AddProperty(layerMat);
                auto* layerBox = new CSPrimBox(leCsx->GetParameterSet(), layerMat);
                layerBox->SetCoord(0, 0.0);
                layerBox->SetCoord(1, 500.0);
                layerBox->SetCoord(2, 0.0);
                layerBox->SetCoord(3, 500.0);
                layerBox->SetCoord(4, leZLines[leLayerStartIdx[layer]]);
                layerBox->SetCoord(5, leZLines[leLayerStartIdx[layer] + 4]);
            }
            auto* leCopper = new CSPropMetal(leCsx->GetParameterSet());
            leCsx->AddProperty(leCopper);
            for (const std::uint32_t boundaryIdx : {8u, 12u, 16u, 20u, 24u, 28u}) {
                auto* copperPlane = new CSPrimBox(leCsx->GetParameterSet(), leCopper);
                copperPlane->SetCoord(0, 0.0);
                copperPlane->SetCoord(1, 500.0);
                copperPlane->SetCoord(2, 0.0);
                copperPlane->SetCoord(3, 500.0);
                copperPlane->SetCoord(4, leZLines[boundaryIdx]);
                copperPlane->SetCoord(5, leZLines[boundaryIdx]);
            }
            // The lumped resistor, exactly mirroring LumpedPort::LumpedPort's own addLumpedElement()
            // call: direction=2 (z, the excitation axis), caps=true, resistance=45 (this board's own
            // involved_nets impedance), placed as a box spanning the thin layer at z-index 24..27,
            // a small 100x100um XY footprint (matching the real port's own scale), NOT the full
            // domain (a real port's own gap is small, not a full-plane feature).
            auto* resistProp = new CSPropLumpedElement(leCsx->GetParameterSet());
            resistProp->SetDirection(2);
            resistProp->SetCaps(true);
            resistProp->SetResistance(45.0);
            resistProp->SetLEtype(CSPropLumpedElement::PARALLEL);
            leCsx->AddProperty(resistProp);
            auto* resistBox = new CSPrimBox(leCsx->GetParameterSet(), resistProp);
            resistBox->SetCoord(0, 175.0);
            resistBox->SetCoord(1, 275.0);
            resistBox->SetCoord(2, 175.0);
            resistBox->SetCoord(3, 275.0);
            resistBox->SetCoord(4, leZLines[24]);
            resistBox->SetCoord(5, leZLines[28]);
            resistBox->SetPriority(10);

            copper::CopperOpenEMS leFdtd;
            leFdtd.SetCSX(leCsx);
            leFdtd.SetGaussExcite(2.5e9, 2.5e9);
            for (int side = 0; side < 6; ++side) {
                leFdtd.Set_BC_Type(side, 0);
            }
            leFdtd.SetNumberOfTimeSteps(10);
            if (leFdtd.SetupFDTD() != 0) {
                fail("[DIAG] lumped-element fixture: openEMS::SetupFDTD() returned non-zero");
            }
            Operator* leOp = leFdtd.GetOperatorForGPU();
            if (leOp == nullptr) {
                fail("[DIAG] lumped-element fixture: GetOperatorForGPU() returned null");
            }
            const copper::CopperYeeGrid leGrid = copper::buildYeeGrid(*leOp);
            const std::uint32_t leInsideIdx = copper::copperGridIndex(leGrid.dims, 5, 5, 25);
            const std::uint32_t leOutsideIdx = copper::copperGridIndex(leGrid.dims, 8, 8, 25);
            std::printf("[DIAG] full stackup + 45-ohm LumpedElement resistor (matches real LumpedPort), "
                        "sampled INSIDE resistor box (5,5,25): dt=%.6e vv2=%.6e vi2=%.6e\n",
                        leGrid.timestepSeconds, leGrid.vv[2][leInsideIdx], leGrid.vi[2][leInsideIdx]);
            std::printf("[DIAG] full stackup + 45-ohm LumpedElement resistor, sampled OUTSIDE resistor "
                        "box (8,8,25): dt=%.6e vv2=%.6e vi2=%.6e\n",
                        leGrid.timestepSeconds, leGrid.vv[2][leOutsideIdx], leGrid.vi[2][leOutsideIdx]);
        }
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
                fail("Phase 4c: early-exit-at-7 field state doesn't bit-match a plain run(7) -- "
                     "runWithProbeSampling() ran a different number of iterations than the sampler requested");
            }
            std::printf("Phase 4c: early exit after %u/50 calls matches a plain run(7) bit-for-bit\n", callCount);
        }
    }

    std::printf("Copper_smoketest: PASS\n");
    return EXIT_SUCCESS;
}
