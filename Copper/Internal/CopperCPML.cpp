#include "CopperCPML.hpp"

#include <algorithm>
#include <array>
#include <cmath>

#include "tools/constants.h"

namespace copper {

namespace {

// Mirrors Operator_Ext_UPML's own default grading function string exactly (see the identical
// function in the old CopperCPML.cpp / openEMS's operator_ext_upml.cpp constructor) -- this is
// *sigma*'s own depth grading, unrelated to CPML's alpha, and applies identically regardless of
// which PML formulation (UPML or CPML) consumes it: it's a property of the depth profile, not the
// algorithm.
double defaultSigmaGrading(double D, double dl, double W, double Z) {
    if (D <= 0) {
        return 0;
    }
    const double scale = -std::log(1e-6) * std::log(2.5) / (2 * dl * Z * (std::pow(2.5, W / dl) - 1));
    return scale * std::pow(2.5, D / dl);
}

// Standard CPML convention: alpha_max at the PML's own *inner* edge (D=0 -- where sigma's own
// grading is weakest), decreasing linearly to 0 at the outer, PEC-backed edge (D=W). Opposite grading
// direction from sigma's own, deliberately -- see CopperCPML.hpp's own top comment for why this is
// what bounds CPML's psi decay away from marginal stability everywhere in the PML, including where
// sigma alone would not.
double alphaGrading(double D, double W, double alphaMax) {
    if (W <= 0) {
        return 0;
    }
    return alphaMax * std::clamp(1.0 - D / W, 0.0, 1.0);
}

struct Grading {
    double sigma = 0;
    double sigmaEff = 0; // sigma + alphaGrading(...)
};

/// Depth/width geometry for `axis`, shared between the V-side and I-side grading of that axis.
/// Pure Yee-mesh geometry (which cells fall in which PML face's depth range) -- mirrors the first
/// half of Operator_Ext_UPML::CalcGradingKappa() (operator_ext_upml.cpp)'s own math, but computed
/// directly from `pmlDepthCells` and `op`'s own line counts rather than from an actual
/// Operator_Ext_UPML extension's m_BC/m_Size (see CopperCPML.hpp's own top comment for why no such
/// extension exists for a CPML run at all). `pmlDepthCells` is uniform across all 6 faces, matching
/// the single value gerber2ems would otherwise pass to Set_BC_PML() for every face.
struct BaseGrading {
    bool inPML = false;
    bool lower = false;
    double depth = 0;
    double width = 0;
    double dl = 0;
};

BaseGrading computeBaseGrading(Operator& op, std::uint32_t pmlDepthCells, int axis, const unsigned int pos[3]) {
    BaseGrading g;
    if (pmlDepthCells == 0) {
        return g;
    }
    const auto totalLines = static_cast<unsigned int>(op.GetNumberOfLines(axis, true));
    if (pos[axis] <= pmlDepthCells) {
        g.inPML = true;
        g.lower = true;
        g.width = (op.GetDiscLine(axis, pmlDepthCells) - op.GetDiscLine(axis, 0)) * op.GetGridDelta();
        g.depth = g.width - (op.GetDiscLine(axis, pos[axis]) - op.GetDiscLine(axis, 0)) * op.GetGridDelta();
        g.dl = g.width / pmlDepthCells;
    } else if (pos[axis] >= totalLines - 1 - pmlDepthCells) {
        g.inPML = true;
        g.lower = false;
        g.width = (op.GetDiscLine(axis, totalLines - 1) - op.GetDiscLine(axis, totalLines - pmlDepthCells - 1)) *
                   op.GetGridDelta();
        g.depth =
            g.width - (op.GetDiscLine(axis, totalLines - 1) - op.GetDiscLine(axis, pos[axis])) * op.GetGridDelta();
        g.dl = g.width / pmlDepthCells;
    }
    return g;
}

/// Applies the V-side ("kappa_v"-equivalent, n==ny offset, depth<0 clamp) or I-side ("kappa_i"-
/// equivalent, n!=ny offset, depth>width clamp) half-cell adjustment to `base`'s own depth -- exactly
/// mirroring the second half of CalcGradingKappa(), since this is Yee-staggering geometry shared by
/// both UPML and CPML, not specific to either. `axis` is the grading axis; `ny` is the field
/// component axis being updated.
Grading finishGrading(const BaseGrading& base, Operator& op, int axis, const unsigned int pos[3], bool isVSide,
                       int ny, double alphaMax) {
    if (!base.inPML) {
        return {0, 0};
    }
    double depth = base.depth;
    const double half = op.GetEdgeLength(axis, pos) / 2;
    const bool matches = (axis == ny);
    if (base.lower) {
        if (isVSide) {
            if (matches) {
                depth -= half;
            }
        } else {
            if (!matches) {
                depth -= half;
            }
            if (depth < 0) {
                depth = 0;
            }
        }
    } else {
        if (isVSide) {
            if (matches) {
                depth += half;
            }
        } else {
            if (!matches) {
                depth += half;
            }
            if (depth > base.width) {
                depth = 0;
            }
        }
    }
    if (depth <= 0) {
        return {0, 0};
    }
    const double sigma = defaultSigmaGrading(depth, base.dl, base.width, Z0);
    return {sigma, sigma + alphaGrading(depth, base.width, alphaMax)};
}

void calcGrading(Operator& op, std::uint32_t pmlDepthCells, int ny, const unsigned int pos[3], bool isVSide,
                  double alphaMax, Grading out[3]) {
    for (int axis = 0; axis < 3; ++axis) {
        const BaseGrading base = computeBaseGrading(op, pmlDepthCells, axis, pos);
        out[axis] = finishGrading(base, op, axis, pos, isVSide, ny, alphaMax);
    }
}

// eq. (7.99)/(7.102), kappa=1: b = exp(-(sigma+alpha)*dT/EPS0), c = sigma*(b-1)/(sigma+alpha).
// sigma=alpha=0 (outside any graded region) gives b=1, c=0 -- psi's own recursive update (eq. 7.101,
// psi[n] = b*psi[n-1] + c*curlTerm) then leaves psi permanently at its zero initial value, so this is
// a true no-op there, not an approximation of one.
void computeBC(const Grading& g, double dT, float& b, float& c) {
    const double sigmaEff = g.sigmaEff; // sigma + alpha
    if (sigmaEff <= 0) {
        b = 1.0F;
        c = 0.0F;
        return;
    }
    const double bd = std::exp(-sigmaEff * dT / EPS0);
    b = static_cast<float>(bd);
    c = static_cast<float>(g.sigma * (bd - 1.0) / sigmaEff);
}

} // namespace

std::vector<CopperCPMLShell> buildCPMLShells(Operator& op, double alphaMax, std::uint32_t pmlDepthCells) {
    std::vector<CopperCPMLShell> shells;
    if (pmlDepthCells == 0) {
        return shells;
    }

    // domainN{x,y,z}, not n{x,y,z} -- "ny" specifically is already the field-component-axis
    // parameter name used throughout this file's own grading helpers (calcGrading() et al.), and the
    // per-cell loop below needs its own local `ny` with that same meaning.
    const auto domainNx = static_cast<std::uint32_t>(op.GetNumberOfLines(0, true));
    const auto domainNy = static_cast<std::uint32_t>(op.GetNumberOfLines(1, true));
    const auto domainNz = static_cast<std::uint32_t>(op.GetNumberOfLines(2, true));
    // gerber2ems's own grid generation (grid_gen.cpp's _extendPMLBand()/GridGeneratorAxis::
    // compileGrid()) always reserves at least pmlDepthCells dedicated cells on every face -- this
    // should never actually trigger, but a shell narrower than the domain it claims to span would
    // silently produce nonsense geometry below, so fail loudly instead.
    if (domainNx <= 2 * pmlDepthCells || domainNy <= 2 * pmlDepthCells || domainNz <= 2 * pmlDepthCells) {
        return shells;
    }

    // One shell per *face* (X-lo, X-hi, Y-lo, Y-hi, Z-lo, Z-hi -- matching Set_BC_PML()'s own idx
    // convention, and openEMS's own Operator_Ext_UPML::Create_UPML()'s box construction, which this
    // mirrors even though no such extension is ever created for a CPML run -- see CopperCPML.hpp's
    // own top comment): each face spans the *full* width of the other two axes, "a pml in
    // x-direction over the full width of yz-space" per that function's own comment. That overlap at
    // edges/corners is harmless for UPML (SetVV/SetVI/etc. are plain overwrites -- whichever shell's
    // BuildExtension() runs last just wins, still numerically bounded either way) but not for CPML:
    // each shell here keeps its own independent psi accumulator state, and the engine dispatches one
    // cpml_correct_e/h kernel *per shell* -- so without deduplication, an edge/corner cell claimed by
    // two (or, at a true corner, three) overlapping shells gets its additive psi correction applied
    // that many times *every single timestep*. That's precisely the kind of compounding double-count
    // that turns an individually-stable (|b|<1 by construction) correction into unbounded growth over
    // a few hundred timesteps -- confirmed in practice: a real board's first NaN traced back to
    // exactly such an edge cell (near both a Y-face and a Z-face simultaneously). `claimed` tracks,
    // across every shell built so far, which global cells already got their correction computed by an
    // earlier shell in this loop; a cell already claimed gets the inert b=1/c=0 (no-op) coefficient
    // here instead of a second real one, and is left off subsequent shells' psi-driving grading
    // entirely -- each cell's correction is computed and applied exactly once, regardless of how many
    // faces' PML regions it geometrically falls within.
    struct FaceSpec {
        std::uint32_t startX, startY, startZ, nX, nY, nZ;
    };
    const std::array<FaceSpec, 6> faces = {{
        {0, 0, 0, pmlDepthCells, domainNy, domainNz},                              // X-lo
        {domainNx - pmlDepthCells, 0, 0, pmlDepthCells, domainNy, domainNz},       // X-hi
        {0, 0, 0, domainNx, pmlDepthCells, domainNz},                              // Y-lo
        {0, domainNy - pmlDepthCells, 0, domainNx, pmlDepthCells, domainNz},       // Y-hi
        {0, 0, 0, domainNx, domainNy, pmlDepthCells},                              // Z-lo
        {0, 0, domainNz - pmlDepthCells, domainNx, domainNy, pmlDepthCells},       // Z-hi
    }};

    std::vector<bool> claimed(static_cast<std::size_t>(domainNx) * domainNy * domainNz, false);
    auto globalIndex = [&](unsigned int x, unsigned int y, unsigned int z) {
        return static_cast<std::size_t>(x) +
               static_cast<std::size_t>(domainNx) * (static_cast<std::size_t>(y) + static_cast<std::size_t>(domainNy) * z);
    };

    for (const FaceSpec& face : faces) {
        CopperCPMLShell shell;
        shell.startX = face.startX;
        shell.startY = face.startY;
        shell.startZ = face.startZ;
        shell.dims.nx = face.nX;
        shell.dims.ny = face.nY;
        shell.dims.nz = face.nZ;
        const std::uint32_t localCellCount = shell.dims.cellCount();
        for (int axis = 0; axis < 3; ++axis) {
            shell.bE[axis].resize(localCellCount);
            shell.cE[axis].resize(localCellCount);
            shell.bH[axis].resize(localCellCount);
            shell.cH[axis].resize(localCellCount);
            shell.psiE0[axis].assign(localCellCount, 0.0F);
            shell.psiE1[axis].assign(localCellCount, 0.0F);
            shell.psiH0[axis].assign(localCellCount, 0.0F);
            shell.psiH1[axis].assign(localCellCount, 0.0F);
        }

        const double dT = op.GetTimestep();
        unsigned int pos[3];
        for (unsigned int lz = 0; lz < shell.dims.nz; ++lz) {
            pos[2] = lz + shell.startZ;
            for (unsigned int ly = 0; ly < shell.dims.ny; ++ly) {
                pos[1] = ly + shell.startY;
                for (unsigned int lx = 0; lx < shell.dims.nx; ++lx) {
                    pos[0] = lx + shell.startX;
                    const std::uint32_t localIdx = copperGridIndex(shell.dims, lx, ly, lz);

                    // See buildCPMLShells()'s own top comment: a cell already claimed by an earlier
                    // shell in this same loop gets the inert b=1/c=0 coefficient below instead of a
                    // second real one, so its correction is never applied twice.
                    const std::size_t globalIdx = globalIndex(pos[0], pos[1], pos[2]);
                    const bool alreadyClaimed = claimed[globalIdx];
                    claimed[globalIdx] = true;

                    // b[w]/c[w] hold *grading*-axis w's off-axis (axis != field-component) CFS
                    // coefficients -- the only ones psi ever needs (a component's own two psi terms
                    // are always driven by the *other* two axes' curl derivatives, never its own
                    // axis; see this file's finishGrading()). finishGrading()'s V-side/I-side
                    // "matches" branches only ever test axis==ny, never ny's specific value, so any
                    // ny != w gives the identical off-axis result -- calcGrading(..., ny=(w+1)%3,
                    // ...) is exactly that, chosen arbitrarily among the two valid choices.
                    for (int w = 0; w < 3; ++w) {
                        if (alreadyClaimed) {
                            shell.bE[w][localIdx] = 1.0F;
                            shell.cE[w][localIdx] = 0.0F;
                            shell.bH[w][localIdx] = 1.0F;
                            shell.cH[w][localIdx] = 0.0F;
                            continue;
                        }
                        const int ny = (w + 1) % 3;
                        Grading gV[3];
                        Grading gI[3];
                        calcGrading(op, pmlDepthCells, ny, pos, /*isVSide=*/true, alphaMax, gV);
                        calcGrading(op, pmlDepthCells, ny, pos, /*isVSide=*/false, alphaMax, gI);

                        float b, c;
                        computeBC(gV[w], dT, b, c);
                        shell.bE[w][localIdx] = b;
                        shell.cE[w][localIdx] = c;
                        computeBC(gI[w], dT, b, c);
                        shell.bH[w][localIdx] = b;
                        shell.cH[w][localIdx] = c;
                    }
                }
            }
        }

        shells.push_back(std::move(shell));
    }
    return shells;
}

} // namespace copper
