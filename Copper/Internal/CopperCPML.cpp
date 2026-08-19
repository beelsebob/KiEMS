#include "CopperCPML.hpp"

#include <algorithm>
#include <cmath>

#include "CopperOpenEMSAccess.hpp"
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
/// Identical to the old CopperCPML.cpp's own BaseGrading/computeBaseGrading -- this is pure Yee-mesh
/// geometry (which cells fall in which PML face's depth range), not PML-algorithm-specific, so it's
/// unchanged by the UPML->CPML rewrite. Mirrors the first half of Operator_Ext_UPML::
/// CalcGradingKappa() (operator_ext_upml.cpp) exactly.
struct BaseGrading {
    bool inPML = false;
    bool lower = false;
    double depth = 0;
    double width = 0;
    double dl = 0;
};

BaseGrading computeBaseGrading(Operator& op, CopperUPMLAccess& ext, int axis, const unsigned int pos[3]) {
    BaseGrading g;
    if (pos[axis] <= ext.m_Size[2 * axis] && ext.m_BC[2 * axis] == 3) {
        g.inPML = true;
        g.lower = true;
        g.width = (op.GetDiscLine(axis, ext.m_Size[2 * axis]) - op.GetDiscLine(axis, 0)) * op.GetGridDelta();
        g.depth = g.width - (op.GetDiscLine(axis, pos[axis]) - op.GetDiscLine(axis, 0)) * op.GetGridDelta();
        g.dl = g.width / ext.m_Size[2 * axis];
    } else if (pos[axis] >= op.GetNumberOfLines(axis, true) - 1 - ext.m_Size[2 * axis + 1] &&
               ext.m_BC[2 * axis + 1] == 3) {
        g.inPML = true;
        g.lower = false;
        g.width = (op.GetDiscLine(axis, op.GetNumberOfLines(axis, true) - 1) -
                    op.GetDiscLine(axis, op.GetNumberOfLines(axis, true) - ext.m_Size[2 * axis + 1] - 1)) *
                   op.GetGridDelta();
        g.depth = g.width - (op.GetDiscLine(axis, op.GetNumberOfLines(axis, true) - 1) -
                               op.GetDiscLine(axis, pos[axis])) *
                                 op.GetGridDelta();
        g.dl = g.width / ext.m_Size[2 * axis + 1];
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

void calcGrading(Operator& op, CopperUPMLAccess& ext, int ny, const unsigned int pos[3], bool isVSide,
                  double alphaMax, Grading out[3]) {
    for (int axis = 0; axis < 3; ++axis) {
        const BaseGrading base = computeBaseGrading(op, ext, axis, pos);
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

std::vector<CopperCPMLShell> buildCPMLShells(Operator& op, double alphaMax) {
    std::vector<CopperCPMLShell> shells;
    for (std::size_t i = 0; i < op.GetNumberOfExtentions(); ++i) {
        auto* extBase = dynamic_cast<Operator_Ext_UPML*>(op.GetExtension(i));
        if (extBase == nullptr) {
            continue;
        }
        auto* ext = static_cast<CopperUPMLAccess*>(extBase);

        CopperCPMLShell shell;
        shell.startX = ext->m_StartPos[0];
        shell.startY = ext->m_StartPos[1];
        shell.startZ = ext->m_StartPos[2];
        shell.dims.nx = ext->m_numLines[0];
        shell.dims.ny = ext->m_numLines[1];
        shell.dims.nz = ext->m_numLines[2];
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

                    // b[w]/c[w] hold *grading*-axis w's off-axis (axis != field-component) CFS
                    // coefficients -- the only ones psi ever needs (a component's own two psi terms
                    // are always driven by the *other* two axes' curl derivatives, never its own
                    // axis; see this file's finishGrading()). finishGrading()'s V-side/I-side
                    // "matches" branches only ever test axis==ny, never ny's specific value, so any
                    // ny != w gives the identical off-axis result -- calcGrading(..., ny=(w+1)%3,
                    // ...) is exactly that, chosen arbitrarily among the two valid choices.
                    for (int w = 0; w < 3; ++w) {
                        const int ny = (w + 1) % 3;
                        Grading gV[3];
                        Grading gI[3];
                        calcGrading(op, *ext, ny, pos, /*isVSide=*/true, alphaMax, gV);
                        calcGrading(op, *ext, ny, pos, /*isVSide=*/false, alphaMax, gI);

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
