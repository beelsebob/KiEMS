// Test/reference adapters that reach into openEMS/CSXCAD internals with no public getter. Copper's
// production path builds its own operator; these shims retain an independent implementation for
// parity and regression comparisons.
//
// `openEMS::FDTD_Op` access (CopperOpenEMS) is ordinary, well-defined protected-member access via
// inheritance *when Copper constructs its own `openEMS` object as `CopperOpenEMS` from the start*
// (every Copper_smoketest fixture does exactly this).
//
// IMPORTANT for every file that includes this header (directly or transitively): openEMS's own
// internal headers pull in CSXCAD via flat, unnamespaced includes (e.g. "ContinuousStructure.h"),
// resolved against the CSXCAD *source checkout* (see the Copper target's own
// SYSTEM_HEADER_SEARCH_PATHS), not the installed, namespaced `<CSXCAD/ContinuousStructure.h>`
// public headers the rest of this app uses. Never mix the two forms in one translation unit --
// they're independent copies of the same classes with no shared include guards, and the compiler
// will report "redefinition" errors. Any Copper source touching openEMS internals must use the
// flat form throughout (`#include <ContinuousStructure.h>`, not `<CSXCAD/ContinuousStructure.h>`).
#pragma once

#include "FDTD/engine.h"
#include "FDTD/extensions/operator_ext_excitation.h"
#include "openems.h"

#include "CopperExcitation.hpp"
#include "CopperYeeGrid.hpp"

namespace copper {

class CopperOpenEMS : public openEMS {
public:
    Operator* GetOperatorForGPU() { return FDTD_Op; }

    /// The real CPU `Engine` openEMS's own `SetupFDTD()` builds from the same `Operator` returned by
    /// `GetOperatorForGPU()` -- exists purely so a debug/verification build can diff Copper's GPU
    /// leapfrog against openEMS's own CPU one on the identical grid (see the Copper implementation
    /// plan's Phase 2 pass criterion); not used by any shipped (non-test) Copper code path.
    Engine* GetEngineForCPU() { return FDTD_Eng; }

    /// Test-only access to the configured max-timestep count.
    unsigned int GetNumberOfTimestepsForGPU() { return NrTS; }
};

/// Test-only access to CalcPEC's protected paint pass and counters. Same zero-data-member access
/// pattern as the other test-access shims below; production Copper code does not use this class.
class CopperOperatorAccess : public Operator {
public:
    using Operator::m_Nr_PEC;
    using Operator::PaintPECColumn;
};

/// Downcast-of-an-object-Copper-didn't-construct situation (openEMS attaches this extension itself,
/// inside SetupFDTD()) -- an accepted, documented test-only risk.
class CopperExcitationAccess : public Operator_Ext_Excitation {
public:
    using Operator_Ext_Excitation::Volt_Count;
    using Operator_Ext_Excitation::Volt_index;
    using Operator_Ext_Excitation::Volt_dir;
    using Operator_Ext_Excitation::Volt_amp;
    using Operator_Ext_Excitation::Volt_delay;
    using Operator_Ext_Excitation::Curr_Count;
    using Operator_Ext_Excitation::Curr_index;
    using Operator_Ext_Excitation::Curr_dir;
    using Operator_Ext_Excitation::Curr_amp;
    using Operator_Ext_Excitation::Curr_delay;
};

namespace reference {

inline std::vector<float> primaryLines(Operator& op, int axis, std::uint32_t count, double gridDelta) {
    std::vector<float> lines(count);
    for (std::uint32_t i = 0; i < count; ++i) {
        lines[i] = static_cast<float>(op.GetDiscLine(axis, i, false) * gridDelta);
    }
    return lines;
}

inline std::vector<float> dualLines(Operator& op, int axis, std::uint32_t count, double gridDelta) {
    std::vector<float> lines(count);
    for (std::uint32_t i = 0; i < count; ++i) {
        lines[i] = static_cast<float>(op.GetDiscLine(axis, i, true) * gridDelta);
    }
    return lines;
}

inline void coefficients(Operator& op, const CopperGridDims& dims, unsigned int axis,
                         std::vector<float>& vv, std::vector<float>& vi,
                         std::vector<float>& ii, std::vector<float>& iv) {
    const std::uint32_t count = dims.cellCount();
    vv.resize(count);
    vi.resize(count);
    ii.resize(count);
    iv.resize(count);
    for (std::uint32_t z = 0; z < dims.nz; ++z) {
        for (std::uint32_t y = 0; y < dims.ny; ++y) {
            for (std::uint32_t x = 0; x < dims.nx; ++x) {
                const std::uint32_t index = copperGridIndex(dims, x, y, z);
                vv[index] = op.GetVV(axis, x, y, z);
                vi[index] = op.GetVI(axis, x, y, z);
                ii[index] = op.GetII(axis, x, y, z);
                iv[index] = op.GetIV(axis, x, y, z);
            }
        }
    }
}

inline std::vector<CopperExcitationCell> excitationCells(unsigned int count,
                                                          unsigned int* const index[3],
                                                          unsigned short* direction,
                                                          FDTD_FLOAT* amplitude,
                                                          unsigned int* delay) {
    std::vector<CopperExcitationCell> cells(count);
    for (unsigned int n = 0; n < count; ++n) {
        cells[n].x = index[0][n];
        cells[n].y = index[1][n];
        cells[n].z = index[2][n];
        cells[n].axis = direction[n];
        cells[n].amplitude = amplitude[n];
        cells[n].delaySteps = delay[n];
    }
    return cells;
}

} // namespace reference

inline CopperYeeGrid buildYeeGrid(Operator& op) {
    CopperYeeGrid grid;
    grid.dims.nx = op.GetNumberOfLines(0);
    grid.dims.ny = op.GetNumberOfLines(1);
    grid.dims.nz = op.GetNumberOfLines(2);
    grid.timestepSeconds = op.GetTimestep();

    const double gridDelta = op.GetGridDelta();
    grid.lineX = reference::primaryLines(op, 0, grid.dims.nx, gridDelta);
    grid.lineY = reference::primaryLines(op, 1, grid.dims.ny, gridDelta);
    grid.lineZ = reference::primaryLines(op, 2, grid.dims.nz, gridDelta);
    grid.dualLineX = reference::dualLines(op, 0, grid.dims.nx, gridDelta);
    grid.dualLineY = reference::dualLines(op, 1, grid.dims.ny, gridDelta);
    grid.dualLineZ = reference::dualLines(op, 2, grid.dims.nz, gridDelta);
    for (unsigned int axis = 0; axis < 3; ++axis) {
        reference::coefficients(op, grid.dims, axis, grid.vv[axis], grid.vi[axis],
                                grid.ii[axis], grid.iv[axis]);
        const unsigned int lines = op.GetNumberOfLines(static_cast<int>(axis));
        grid.primaryDelta[axis].resize(lines);
        grid.dualDelta[axis].resize(lines);
        for (unsigned int i = 0; i < lines; ++i) {
            grid.primaryDelta[axis][i] = op.GetDiscDelta(static_cast<int>(axis), i, false) * gridDelta;
            grid.dualDelta[axis][i] = op.GetDiscDelta(static_cast<int>(axis), i, true) * gridDelta;
        }
    }
    return grid;
}

inline CopperExcitation buildExcitation(Operator& op) {
    CopperExcitation result;
    Excitation* excitation = op.GetExcitationSignal();
    if (excitation == nullptr) {
        return result;
    }
    const unsigned int length = excitation->GetLength();
    result.voltageSignal.assign(excitation->GetVoltageSignal(), excitation->GetVoltageSignal() + length);
    result.currentSignal.assign(excitation->GetCurrentSignal(), excitation->GetCurrentSignal() + length);
    result.signalPeriodSeconds = excitation->GetSignalPeriod();

    Operator_Ext_Excitation* extension = nullptr;
    for (std::size_t i = 0; i < op.GetNumberOfExtentions(); ++i) {
        if (auto* candidate = dynamic_cast<Operator_Ext_Excitation*>(op.GetExtension(i))) {
            extension = candidate;
            break;
        }
    }
    if (extension == nullptr) {
        return result;
    }
    auto* access = static_cast<CopperExcitationAccess*>(extension);
    result.voltageCells = reference::excitationCells(
        access->Volt_Count, access->Volt_index, access->Volt_dir, access->Volt_amp, access->Volt_delay);
    result.currentCells = reference::excitationCells(
        access->Curr_Count, access->Curr_index, access->Curr_dir, access->Curr_amp, access->Curr_delay);
    return result;
}

} // namespace copper
