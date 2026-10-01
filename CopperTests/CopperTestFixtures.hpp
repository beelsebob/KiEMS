// Shared CSX fixture builders + small cross-check helpers for CopperTests. Deliberately independent
// of kiems/libkiems (Copper_smoketest's own design choice, kept here too -- see its file comment):
// these build synthetic CSXCAD structures directly, the same minimal way Copper_smoketest's own
// fixtures do, so CopperTests never depends on anything outside Copper itself plus openEMS/CSXCAD.
//
// Uses the flat (unnamespaced) CSXCAD/openEMS includes throughout, matching every other file that
// touches Internal/CopperOpenEMSAccess.hpp -- see that header's own file comment for why those can't
// mix with the installed, namespaced `<CSXCAD/...>` forms in one translation unit.
#pragma once

#include <cstdint>
#include <vector>

#include <ContinuousStructure.h>

#include "Internal/CopperEngine.hpp"
#include "Internal/CopperYeeGrid.hpp"

class Engine;

namespace copper::test {

/// A trivial 11x11x3-line vacuum grid (1mm cells, PEC on every side), with a single soft E-field
/// (excitation type 0) excitation box in the middle of the domain, oriented along z -- the same
/// shape kiems's own MSLPort excitation uses. Heap-allocated: `openEMS::SetCSX()` takes ownership
/// (see ContinuousStructure's own destruction contract) -- never construct one of these on the stack.
ContinuousStructure* buildTinyVacuumGrid();

/// buildTinyVacuumGrid()'s same domain, but with *no* excitation box anywhere -- used wherever the
/// stimulus is a hand-seeded impulse (CopperEngine::writeFieldCell / Engine::SetVolt) instead, so
/// both engines under comparison start from a genuinely identical, otherwise-quiescent state.
/// `SetGaussExcite` is still required on the `openEMS` object itself (SetupFDTD() rejects a null
/// excitation signal outright), but with nothing in the CSX to attach to, it's a no-op every step.
ContinuousStructure* buildPecCavityNoExcitation();

/// Small fixture for CalcPEC's primitive-paint cache: overlapping metal/material boxes (the
/// higher-priority material must mask PEC) plus a zero-thickness z-normal metal polygon, matching
/// the primitive real PCB copper uses and its unusual GetBoundBox() contract (valid values with a
/// false return).
ContinuousStructure* buildPecPaintFixture();

/// A cube large enough on all 3 axes to hold a uniform-6-face, depth-8-cell CPML shell set with real
/// interior left over. No boundary condition set here -- callers must use Set_BC_Type()+MUR (never
/// Set_BC_PML()) on every face, matching how a real CPML run is actually configured (see
/// Internal/CopperCPML.hpp's own top comment for why).
ContinuousStructure* buildCpmlCavityNoExcitation();

/// A no-excitation box whose mesh spacing grows geometrically along every axis (at a different rate
/// per axis), holding a lossy dielectric block, a lossy magnetic block and a metal block whose faces
/// mostly fall between mesh lines -- so its cells carry many distinct geometries and quarter-cell
/// material blends. The other fixtures' uniform 1 mm meshes can't tell whether coefficient geometry
/// is being handled per axis correctly. Boundary is PEC (CopperOperator's default).
ContinuousStructure* buildGradedMaterialFixture();

/// buildTinyVacuumGrid()'s same domain/excitation, plus a voltage probe and a current probe laid out
/// the way a real LumpedPort's own u/i probes are: a voltage probe spanning the excitation direction
/// at the port's center point, a current probe forming a loop around the port's footprint at its
/// midpoint along that same direction.
ContinuousStructure* buildProbeFixture();

/// buildPecCavityNoExcitation()'s same domain, plus a single-cell SERIES lumped R/L/C element
/// (CSPropLumpedElement) oriented along z, spanning the same single cell buildPecCavityNoExcitation's
/// own hand-seeded-impulse tests use -- so a lumped-element test can seed and read back the identical
/// cell. `resistance`/`inductance`/`capacitance` follow addLumpedElement()'s own NaN-means-absent
/// convention (libkiems/kiems/csx_helpers.hpp) -- pass NaN to omit L or C.
ContinuousStructure* buildSeriesLumpedRLCFixture(double resistance, double inductance, double capacitance);

/// Every field component, matching CopperEngine::Field's own declaration order -- iterate this
/// instead of hand-listing the 6 enumerators at every call site.
inline constexpr CopperEngine::Field kAllFields[6] = {
    CopperEngine::Field::Ex, CopperEngine::Field::Ey, CopperEngine::Field::Ez,
    CopperEngine::Field::Hx, CopperEngine::Field::Hy, CopperEngine::Field::Hz,
};
/// axisForField()'s own copperGridIndex-style axis (0=x/1=y/2=z) for each of kAllFields, in the same
/// order -- Ex/Hx->0, Ey/Hy->1, Ez/Hz->2.
inline constexpr unsigned int kAxisForField[6] = {0, 1, 2, 0, 1, 2};

/// Result of diffing every one of a CopperEngine's 6 field components against a real CPU openEMS
/// Engine's GetVolt()/GetCurr() -- the same comparison every GPU-vs-CPU parity check in this test
/// suite needs, pulled into one place instead of six copy-pasted nested loops per test.
struct FieldParityResult {
    float maxAbsDiff = 0.0F;
    float maxAbsValue = 0.0F;
    bool anyNonzero = false;
};

FieldParityResult compareGpuCpuFields(const CopperEngine& gpuEngine, Engine& cpuEngine, const CopperGridDims& dims);

} // namespace copper::test
