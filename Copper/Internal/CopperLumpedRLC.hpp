// Discovers SERIES CSPropLumpedElement primitives (auto-placed by gerber2ems::Simulation::
// addLumpedComponents(), see libgerber2ems/gerber2ems/simulation.cpp) and computes the same
// per-cell ADE coefficients openEMS's own Engine_Ext_LumpedRLC would -- but as a clean-room
// reimplementation of just the SERIES branch of Operator_Ext_LumpedRLC::BuildExtension()
// (openEMS/FDTD/extensions/operator_ext_lumpedRLC.cpp), using only public Operator/
// CSPropLumpedElement API, since that extension's own already-computed coefficients are `protected`
// (only `friend class Engine_Ext_LumpedRLC`, see operator_ext_lumpedRLC.h) and its Operator-mutating
// helpers (EC_C/EC_G/Calc_ECOperatorPos) are likewise inaccessible from outside the extension
// mechanism -- reimplementing the SERIES branch (rather than reading its state) is the only route
// available that doesn't touch vendor headers.
//
// PARALLEL-type lumped elements deliberately have no equivalent here: BuildExtension()'s PARALLEL
// branch bakes its capacitance/conductance straight into the Operator's own EC_C/EC_G (via
// Calc_ECOperatorPos), and that extension *does* still run for the GPU backend too (extension
// building is part of the openEMS::SetupFDTD() call both backends share -- see
// Copper/CopperFDTDRunner.h's own doc comment on runFDTDPortOnGPU's precondition) -- so by the time
// buildYeeGrid() reads vv/vi, a PARALLEL element's static effect is already there for free. Only
// SERIES needs a dynamic, per-timestep correction, because its physics live entirely in a rolling
// auxiliary-differential-equation state that only ever gets computed inside a real openEMS Engine's
// per-timestep Apply2Voltages() call -- something Copper's own leapfrog loop never invokes.
//
// Uses the flat (unnamespaced) CSXCAD/openEMS includes, matching every other Copper/Internal/
// header -- see CopperOpenEMSAccess.hpp's file comment for why those can't mix with the installed,
// namespaced forms in one translation unit.
#pragma once

#include <cstdint>
#include <vector>

#include "CopperYeeGrid.hpp"
#include "FDTD/operator.h"
#include "ContinuousStructure.h"

namespace copper {

/// One Yee edge a SERIES lumped element's snapped box covers. `axis` matches CopperEngine::Field's
/// own Ex/Ey/Ez ordinals (0/1/2). The seven coefficients are exactly
/// Operator_Ext_LumpedRLC::BuildExtension()'s own SERIES-branch outputs (ib0/b1/b2/vv2/vj1/vj2/vvd,
/// see operator_ext_lumpedRLC.cpp) for this one cell -- ready to drive the same ADE update
/// Engine_Ext_LumpedRLC::Apply2VoltagesImpl applies, just via CopperEngine::readFieldCell/
/// writeFieldCell instead of Engine::GetVolt/SetVolt.
struct CopperLumpedRLCCell {
    std::uint32_t x = 0;
    std::uint32_t y = 0;
    std::uint32_t z = 0;
    std::uint32_t axis = 0;

    float ib0 = 0.0F;
    float b1 = 0.0F;
    float b2 = 0.0F;
    float vv2 = 0.0F;
    float vj1 = 0.0F;
    float vj2 = 0.0F;
    float vvd = 0.0F;
};

/// `grid` must already be built (buildYeeGrid(op)) -- the natural per-cell capacitance this needs
/// (Cd, in operator_ext_lumpedRLC.cpp's own naming) is recovered from `grid.vi` rather than read
/// directly off the Operator (see this file's own top comment for why): the real
/// Operator_Ext_LumpedRLC has already zeroed this cell's conductance by the time SetupFDTD()
/// returns, which collapses the standard voltage-update coefficient relation to vv=1, vi=dT/Cd --
/// so `Cd = op.GetTimestep() / grid.vi[axis][cellIndex]` recovers the exact same (possibly
/// stability-adjusted) value the vendor extension itself computed, with no vendor-internals access
/// at all. Returns one entry per (cell, axis) pair covered by every SERIES CSPropLumpedElement's
/// snapped box; empty if there are none (matching buildExcitation()'s own "empty, not an error"
/// tolerance for "nothing to do here").
std::vector<CopperLumpedRLCCell> discoverLumpedRLC(ContinuousStructure& csx, const CopperYeeGrid& grid, Operator& op);

} // namespace copper
