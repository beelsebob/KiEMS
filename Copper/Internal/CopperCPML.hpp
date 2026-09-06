// Real CFS-PML (Roden & Gedney 2000, "Convolutional PML"), derived directly from Taflove & Hagness,
// *Computational Electrodynamics* 3rd ed., Section 7.9 ("Efficient Implementation of CPML in FDTD"),
// eq. (7.93)-(7.110) -- read from the actual text, not reconstructed from memory (see git history for
// the earlier, incorrect attempt this replaces: it tried to generalize openEMS's own UPML/"EC-FDTD"
// coefficients (Section 7.8, what Operator_Ext_UPML implements) by substituting sigma -> sigma+alpha
// inside their bilinear-transform shape. That is NOT what CPML is: the book states explicitly that
// "the CPML is based on the stretched-coordinate form of the PML presented in Section 7.4" -- a
// structurally different formulation from Section 7.8's anisotropic UPML/ADE tensor approach, not a
// generalization of it. Retrofitting alpha into openEMS's own UPML coefficients produced a medium
// with the wrong reflection profile (confirmed: 10x alpha made a real-board run's divergence
// dramatically *worse*, the opposite of CFS's whole purpose).
//
// The real CPML, per (7.94)-(7.106): keeps every existing (non-PML) field-update coefficient exactly
// as-is (grid.vv/vi/ii/iv, computed for the real host medium -- vacuum in the PML region on every
// board this codebase simulates) and adds an independent auxiliary convolution term (psi, eq. 7.101/
// 7.105/7.110) directly onto each of the *two* raw curl-difference terms already computed inside
// update_e_interior/update_h_interior, scaled by the SAME vi/iv coefficient that already scales the
// ordinary curl term (7.106: `E_new = C_a*E_old + C_b*(ordinary_curl + psi_a - psi_b)`). psi's own
// decay is bounded away from 1 by alpha alone (b_w = exp(-(sigma_w+alpha_w)*dT/EPS0), independent of
// how weakly sigma is graded -- exactly the mechanism that fixes the late-time instability), and it
// decays to (and stays at) exactly zero outside the graded region, so this is a pure additive
// correction with no effect anywhere sigma=alpha=0.
//
// "grid.vv/vi/ii/iv represent the real host medium" is only true if nothing else has *also* graded
// them -- which is why, unlike an earlier version of this file, buildCPMLShells() no longer discovers
// its own shell geometry from an actual Operator_Ext_UPML extension at all. Set_BC_PML() causes
// openEMS's own Operator::CalcECOperator() to unconditionally call BuildExtension() on every extension
// it creates (operator.cpp's own CalcECOperator(), regardless of which boundary algorithm the *caller*
// ultimately wants) -- so if kiems ever called Set_BC_PML() before a CPML run, grid.vv/vi/ii/iv at
// PML cells would already be UPML's own graded, absorbing values by the time buildYeeGrid() reads them,
// and this file's additive psi correction would be stacked on top of a medium UPML had already turned
// absorbing -- two independent, incompatible PML formulations layered on the same cells. Confirmed in
// practice: a real board's first NaN traced to exactly this (grid.vi at a PML cell reading ~1e-11,
// eleven orders of magnitude off the ~217 a genuine vacuum cell reads, and reproducible with plain
// UPML -- no CPML involved at all -- disabled). kiems now uses Set_BC_Type()+MUR (never
// Set_BC_PML()) for a CPML run specifically so no Operator_Ext_UPML ever gets created, and this file
// computes its own shell geometry directly from `pmlDepthCells` (the same value kiems would
// otherwise have passed to Set_BC_PML()) and the Operator's own line counts instead.
//
// kappa (CPML's coordinate-*stretching* parameter, unrelated to openEMS's own same-named-but-
// different "kappa_v"/"kappa_i", which mean ordinary conductivity) is fixed at 1, matching this
// codebase's existing design decision (see CopperCPML.cpp's own comment) -- only alpha is needed for
// the late-time instability, and kappa=1 drops the `kappa_w` factor from every book equation cited
// above entirely.
#pragma once

#include <cstdint>
#include <vector>

#include "CopperYeeGrid.hpp"

namespace copper {

/// One PML face's auxiliary CPML state -- unlike CopperPMLShell (CopperPML.hpp), this never touches
/// grid.vv/vi/ii/iv or needs any "flux" swap: it is a pure additive correction, applied by new
/// cpml_correct_e/cpml_correct_h kernels dispatched *after* update_e_interior/update_h_interior (same
/// H/E snapshot either order, since neither kernel here writes the field it reads).
///
/// All arrays are local-indexed (copperGridIndex(dims, lx, ly, lz)) and axis-major merged for GPU
/// upload, mirroring CopperPMLShell's own convention.
struct CopperCPMLShell {
    std::uint32_t startX = 0, startY = 0, startZ = 0;
    CopperGridDims dims;

    // Per-*grading*-axis (w=x,y,z) CFS coefficients (eq. 7.99/7.102, kappa=1):
    //   b[w] = exp(-(sigma_w + alpha_w) * dT / EPS0)
    //   c[w] = sigma_w * (b[w] - 1) / (sigma_w + alpha_w)      (0 if sigma_w=alpha_w=0)
    // Evaluated at the V-side (E-update, eq. 7.105) and I-side (H-update, eq. 7.110) positions
    // separately -- these differ by the same half-cell Yee-staggering offset CopperPML.hpp's own
    // vv/vi (V-side) vs ii/iv (I-side) split already accounts for, so two separate coefficient sets
    // are needed, not one shared set.
    std::vector<float> bE[3], cE[3];
    std::vector<float> bH[3], cH[3];

    // Auxiliary convolution state (psi, eq. 7.101), zero-initialized. For field component n (0=x,
    // 1=y, 2=z), psiE0[n]/psiH0[n] is driven by the *nP*-axis curl term (nP=(n+1)%3) -- e.g. n=0
    // (Ex)'s own dHz/dy term -- and psiE1[n]/psiH1[n] by the *nPP*-axis term (e.g. Ex's dHy/dz),
    // mirroring the update_e_interior/update_h_interior kernels' own two-term curl construction
    // exactly (first term -> slot 0, second term -> slot 1) so cpml_correct_e/h can recompute the
    // identical raw difference each kernel already trusts, rather than re-deriving it.
    std::vector<float> psiE0[3], psiE1[3];
    std::vector<float> psiH0[3], psiH1[3];
};

/// `alphaMax` is CPML's own alpha (CFS) parameter, S/m, graded per axis exactly as CopperPML.hpp's
/// sigma grading already is (see CopperCPML.cpp) -- standard choice is `2*pi*f_low*EPS0` for this
/// simulation's own lowest frequency of interest. alphaMax=0 makes every b[w]/c[w] collapse to what
/// the same axis's *sigma-only* stretched-coordinate CPML would produce (not identical to plain UPML
/// bit-for-bit, since this is a structurally different formulation -- see this header's own top
/// comment -- but the psi correction itself becomes purely alpha-independent decay-toward-zero
/// bookkeeping with no effect on stability either way).
///
/// `pmlDepthCells` is the PML shell's own depth, in cells, uniform on all 6 domain faces -- the same
/// value the caller must *not* have passed to openEMS's own Set_BC_PML() (see this header's own top
/// comment for why); shell geometry here is computed directly from it and `op`'s own line counts,
/// with no Operator_Ext_UPML extension involved at all. 0 returns no shells (a caller with no PML on
/// this run -- e.g. a MUR-only smoketest -- can pass 0 rather than special-casing the call away).
std::vector<CopperCPMLShell> buildCPMLShells(Operator& op, double alphaMax, std::uint32_t pmlDepthCells);

} // namespace copper
