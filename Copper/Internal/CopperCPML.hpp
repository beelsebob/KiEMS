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

#include "CopperOperator.hpp"
#include "CopperDomain.hpp"
#include "CopperYeeGrid.hpp"

namespace copper {

/// One PML face's auxiliary CPML state. This never touches grid.vv/vi/ii/iv or needs any "flux"
/// swap: it is a pure additive correction, applied by
/// cpml_correct_e/cpml_correct_h kernels dispatched *after* update_e_interior/update_h_interior (same
/// H/E snapshot either order, since neither kernel here writes the field it reads).
///
/// All arrays are local-indexed (copperGridIndex(dims, lx, ly, lz)) and axis-major merged for GPU
/// upload.
struct CopperCPMLShell {
    std::uint32_t startX = 0, startY = 0, startZ = 0;
    CopperGridDims dims;

    // Per-*grading*-axis (w=x,y,z) CFS coefficients (eq. 7.99/7.102, kappa=1):
    //   b[w] = exp(-(sigma_w + alpha_w) * dT / EPS0)
    //   c[w] = sigma_w * (b[w] - 1) / (sigma_w + alpha_w)      (0 if sigma_w=alpha_w=0)
    // Evaluated at the V-side (E-update, eq. 7.105) and I-side (H-update, eq. 7.110) positions
    // separately -- these differ by the same half-cell Yee-staggering offset the vv/vi (V-side) vs
    // ii/iv (I-side) split already accounts for, so two separate coefficient sets
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

/// `alphaMax` is CPML's own alpha (CFS) parameter, S/m, graded per axis alongside sigma (see
/// CopperCPML.cpp) -- standard choice is `2*pi*f_low*EPS0` for this
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
std::vector<CopperCPMLShell> buildCPMLShells(CopperOperator& op, double alphaMax, std::uint32_t pmlDepthCells);
/// Irregular-domain CPML: the conventional lower and upper Z slabs only, graded along Z alone and
/// spanning every active XY column. Absorption across the irregular XY outline is NOT a CPML -- it's
/// applyRingAbsorber() below.
///
/// Why the XY rings can't be a CPML: the stretched-coordinate PML this file implements is only
/// stable when each axis's stretch depends on that axis alone -- sigma_x(x), sigma_y(y),
/// sigma_z(z) -- because only then is it a genuine complex coordinate transformation of Maxwell's
/// equations (the stretched derivatives d/dx~ and d/dy~ commute, so div(curl) stays zero). An
/// outline-following ring necessarily makes sigma_x vary along y (every curved or diagonal
/// section, and wherever an axis's grading switches on or off), and then any field variation along
/// z drives an exponentially growing mode pinned to where sigma_x varies with y (or sigma_y with
/// x). This is not a tuning problem: an earlier ring-graded CPML here diverged from roundoff within
/// a few hundred steps whatever sigma/alpha/grading-selection rule was used, stayed stable in pure
/// 2D (kz=0) runs, and a plain rectangular CPML whose X-lo face was merely truncated halfway along y
/// diverges the same way, with the growing mode sitting exactly on the truncation line. Z grading
/// is still separable (the ring absorber is Z-invariant), which is why the Z slabs stay a CPML.
///
/// Grading along Z alone shrinks the state a CopperCPMLShell would need. The coefficients depend on
/// z only, so they're one set per graded plane rather than per cell. And of each component's two
/// psi terms only the one driven by a d/dz curl term can ever be non-zero -- Ex's (dHy/dz) and Ey's
/// (dHx/dz), Hx's (dEy/dz) and Hy's (dEx/dz); every other term has b=1, c=0, so it starts at zero
/// and stays there. Ez and Hz have no d/dz term, so a Z-only CPML never touches them. The engines
/// fold the correction into the interior update itself (it needs only the cell's freshly updated
/// value and curl differences the update already read), which leaves two psi read-modify-writes
/// per graded cell as its only extra memory traffic. The psi state itself is allocated, zeroed, by
/// the engine: one value per XY node per graded plane for each of those four terms.
struct CopperZCPML {
    static constexpr std::uint32_t kNoLayer = 0xFFFFFFFFu;

    /// Per grid z-plane: the index of its entry in the per-plane arrays below, or kNoLayer outside
    /// the slabs.
    std::vector<std::uint32_t> layerOfZ;
    /// Per graded plane, eq. (7.99)/(7.102) for the Z axis exactly as CopperCPMLShell's b[2]/c[2],
    /// at the V-side (E update) and I-side (H update) positions.
    std::vector<float> bE, cE, bH, cH;

    std::uint32_t layerCount() const { return static_cast<std::uint32_t>(bE.size()); }
    bool empty() const { return bE.empty(); }
};

/// Builds the irregular domain's Z-only CPML: `pmlDepthCells` planes at the bottom and one more at
/// the top (see upperFaceDepth() in CopperCPML.cpp), graded exactly like the rectangular overload's
/// Z faces. Empty when `pmlDepthCells` is 0 or the grid is too thin to hold both slabs.
CopperZCPML buildZCPML(CopperOperator& op, double alphaMax, std::uint32_t pmlDepthCells);

/// Folds the irregular domain's XY absorbing rings into one engine backend's own copies of the
/// Yee coefficients (both backends call this at construction; `vv`/`vi`/`ii`/`iv` are per-axis
/// cellCount-length arrays in copperGridIndex() layout, `timestepSeconds` is grid.timestepSeconds).
/// No-op for an empty mask or one without a physical ring thickness (a preview-only mask).
///
/// The rings are an isotropic, impedance-matched lossy medium: every component gains the damping
/// rate sigma/eps0 = sigma_m/mu0 (added on top of whatever loss the host medium already has, so a
/// dielectric host stays matched too), with sigma graded over the ring depth by the same profile
/// the rectangular CPML uses and sampled at each component's own staggered XY position (see
/// CopperDomainMask::staggeredLayer). A passive lossy medium is energy-dissipative for any spatial
/// profile, so unlike an outline-following CPML (see above) it is unconditionally stable. It is
/// reflectionless only at normal incidence, though -- oblique incidence reflects more than a true
/// PML, and so does quasi-static near-field content, which at low frequency sees the lossy ring
/// as a conducting shell. Keep the ring well clear of the board.
void applyRingAbsorber(const CopperDomainMask& domainMask, double timestepSeconds, const CopperGridDims& dims,
                       float* const vv[3], float* const vi[3], float* const ii[3], float* const iv[3]);

/// applyRingAbsorber()'s damping one coefficient pair at a time, for a caller that never holds a
/// mutable copy of the whole grid's coefficients (the Metal engine folds it into its coefficient
/// table as it builds it). Inactive -- every fold a no-op -- for the same masks applyRingAbsorber()
/// ignores.
class CopperRingAbsorber {
public:
    CopperRingAbsorber(const CopperDomainMask& domainMask, double timestepSeconds, const CopperGridDims& dims);

    bool active() const { return !_q.empty(); }
    /// Folds the absorber into component n's (vv, vi) at node (x, y), any z.
    void foldE(int n, std::uint32_t x, std::uint32_t y, float& vv, float& vi) const;
    /// Folds the absorber into component n's (ii, iv) at node (x, y), any z.
    void foldH(int n, std::uint32_t x, std::uint32_t y, float& ii, float& iv) const;

private:
    const CopperDomainMask* _mask = nullptr;
    std::vector<double> _q; // per ring layer; empty when inactive
};

} // namespace copper
