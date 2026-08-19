// Extracts the per-shell data openEMS's own Operator_Ext_UPML/Engine_Ext_UPML already compute for
// uniaxial PML boundaries, in the same spirit as CopperYeeGrid/CopperExcitation: read openEMS's own
// already-computed answer, don't re-derive the PML math independently.
//
// openEMS attaches one *separate* Operator_Ext_UPML instance per active PML face (up to 6, since a
// grid can have PML on any subset of its six faces) -- see Operator_Ext_UPML::Create_UPML. Each
// instance covers its own StartPos/numLines box, sized so faces processed later don't re-cover
// corner/edge regions an earlier face's box already claimed. Copper mirrors this directly: one
// CopperPMLShell per extension instance, not one shell per face conceptually merged into a single
// box -- there's no unified "PML region", just however many of these boxes openEMS itself built.
//
// Critically, Operator_Ext_UPML::BuildExtension() doesn't just compute its own shell-local
// coefficients (vv/vvfo/vvfn/ii/iifo/iifn below) -- it also *overwrites* the underlying Operator's
// own per-cell vv/vi/ii/iv for every PML cell (Operator::SetVV/SetVI/...), replacing them with the
// PML "flux update" recursion coefficients. That means CopperYeeGrid's extraction (which reads
// Operator::GetVV/GetVI/GetII/GetIV verbatim, unchanged from Phase 1) *already* captures the correct
// per-cell flux-update step for PML cells -- update_e_interior/update_h_interior need no PML-specific
// change at all. All this file adds is the "sandwich" openEMS's own Engine_Ext_UPML wraps around
// that: swap the real field for the old flux before the interior update runs, then reconstruct the
// real field from old-and-new flux after it runs, using these shell-local coefficients.
#pragma once

#include <cstdint>
#include <vector>

#include "CopperYeeGrid.hpp"

namespace copper {

struct CopperPMLShell {
    std::uint32_t startX = 0, startY = 0, startZ = 0; // this shell's box origin, in *global* grid coords
    CopperGridDims dims;                              // this shell's own *local* box dimensions

    // Local-indexed (copperGridIndex(dims, lx, ly, lz)), one array per axis -- exactly mirroring
    // Operator_Ext_UPML's own vv/vvfo/vvfn (voltage/E side) and ii/iifo/iifn (current/H side; see
    // CopperUPMLAccess). vv/ii here are Operator_Ext_UPML's *shell-local* coefficients, distinct
    // from (and not to be confused with) Operator::GetVV/GetII, which CopperYeeGrid extracts
    // separately and which already has its PML cells' values overwritten as described above.
    std::vector<float> vv[3], vvfo[3], vvfn[3];
    std::vector<float> ii[3], iifo[3], iifn[3];
};

/// One entry per Operator_Ext_UPML extension attached to `op` (i.e. per active PML face) -- empty if
/// the grid has no PML boundaries at all (e.g. the Phase 2 all-PEC cavity fixture).
std::vector<CopperPMLShell> buildPMLShells(Operator& op);

} // namespace copper
