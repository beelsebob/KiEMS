#include "CopperCPML.hpp"

#include <algorithm>
#include <array>
#include <cmath>
#include <utility>

#include "CopperPhysicalConstants.hpp"

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
/// the single value kiems would otherwise pass to Set_BC_PML() for every face.
struct BaseGrading {
    bool inPML = false;
    bool lower = false;
    double depth = 0;
    double width = 0;
    double dl = 0;
};

BaseGrading computeBaseGrading(CopperOperator& op, std::uint32_t pmlDepthCells, int axis, const unsigned int pos[3]) {
    BaseGrading g;
    if (pmlDepthCells == 0) {
        return g;
    }
    // Depth is measured from the PML's inner edge directly, never as width minus the distance from
    // the outer edge: the compiler contracts `width - distance * delta` into an FMA, which leaves the
    // inner edge at width's own rounding error instead of exactly 0 wherever the line positions
    // don't scale to metres exactly -- and defaultSigmaGrading() jumps to its full inner-edge value
    // for any depth above 0. On the Keyboard Hub board that graded the E side of the upper X and Y
    // faces' first planes and, in the per-face shells this file used to build, the plane just inside
    // each lower face wherever another face's shell covered it: a non-separable stretch.
    const auto totalLines = static_cast<unsigned int>(op.numberOfLines(axis));
    if (pos[axis] <= pmlDepthCells) {
        g.inPML = true;
        g.lower = true;
        g.width = (op.discLine(axis, pmlDepthCells) - op.discLine(axis, 0)) * op.gridDeltaMetres();
        g.depth = (op.discLine(axis, pmlDepthCells) - op.discLine(axis, pos[axis])) * op.gridDeltaMetres();
        g.dl = g.width / pmlDepthCells;
    } else if (pos[axis] >= totalLines - 1 - pmlDepthCells) {
        g.inPML = true;
        g.lower = false;
        const unsigned int inner = totalLines - 1 - pmlDepthCells;
        g.width = (op.discLine(axis, totalLines - 1) - op.discLine(axis, inner)) * op.gridDeltaMetres();
        g.depth = (op.discLine(axis, pos[axis]) - op.discLine(axis, inner)) * op.gridDeltaMetres();
        g.dl = g.width / pmlDepthCells;
    }
    return g;
}

/// Applies the V-side ("kappa_v"-equivalent, n==ny offset, depth<0 clamp) or I-side ("kappa_i"-
/// equivalent, n!=ny offset, depth>width clamp) half-cell adjustment to `base`'s own depth -- exactly
/// mirroring the second half of CalcGradingKappa(), since this is Yee-staggering geometry shared by
/// both UPML and CPML, not specific to either. `axis` is the grading axis; `ny` is the field
/// component axis being updated.
Grading finishGrading(const BaseGrading& base, CopperOperator& op, int axis, const unsigned int pos[3], bool isVSide,
                       int ny, double alphaMax) {
    if (!base.inPML) {
        return {0, 0};
    }
    double depth = base.depth;
    const double half = op.edgeLength(axis, pos) / 2;
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
    const double sigma = defaultSigmaGrading(depth, base.dl, base.width, physical::impedance0);
    return {sigma, sigma + alphaGrading(depth, base.width, alphaMax)};
}

// computeBaseGrading() puts line `pmlDepthCells` of the lower face and line `n-1-pmlDepthCells` of
// the upper face on the PML's inner edge. At the lower one both E (on the line) and H (half a cell
// further in) grade to zero, but the upper one's H sits half a cell *inside* the PML and grades to
// sigma(dl/2) -- so an upper face needs that extra plane to own every nonzero grading of its axis.
std::uint32_t upperFaceDepth(std::uint32_t pmlDepthCells) { return pmlDepthCells + 1; }

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
    const double bd = std::exp(-sigmaEff * dT / physical::epsilon0);
    b = static_cast<float>(bd);
    c = static_cast<float>(g.sigma * (bd - 1.0) / sigmaEff);
}

} // namespace

std::size_t CopperCPML::psiCount(const CopperGridDims& dims, int axis) const {
    const std::size_t layers = axes[axis].layerCount();
    switch (axis) {
    case 0: return layers * dims.ny * dims.nz;
    case 1: return static_cast<std::size_t>(dims.nx) * layers * dims.nz;
    default: return static_cast<std::size_t>(dims.nx) * dims.ny * layers;
    }
}

CopperCPML buildCPML(CopperOperator& op, double alphaMax, std::uint32_t pmlDepthCells, CopperCPMLFaces faces) {
    CopperCPML cpml;
    if (pmlDepthCells == 0) return cpml;
    const std::uint32_t lines[3] = {static_cast<std::uint32_t>(op.numberOfLines(0)),
                                    static_cast<std::uint32_t>(op.numberOfLines(1)),
                                    static_cast<std::uint32_t>(op.numberOfLines(2))};
    auto graded = [&](int axis) { return faces == CopperCPMLFaces::All || axis == 2; };
    // kiems's own grid generation (grid_gen.cpp's _extendPMLBand()/GridGeneratorAxis::compileGrid())
    // always reserves at least pmlDepthCells dedicated cells on every face, so this should never
    // trigger -- but overlapping slabs would silently produce nonsense, so give up instead.
    for (int axis = 0; axis < 3; ++axis) {
        if (graded(axis) && lines[axis] <= 2 * pmlDepthCells) return cpml;
    }

    const double dT = op.timestepSeconds();
    const std::uint32_t upperDepth = upperFaceDepth(pmlDepthCells);
    for (int axis = 0; axis < 3; ++axis) {
        CopperCPML::Axis& out = cpml.axes[axis];
        out.layerOf.assign(lines[axis], CopperCPML::kNoLayer);
        if (!graded(axis)) continue;
        const std::array<std::pair<std::uint32_t, std::uint32_t>, 2> slabs = {
            {{0U, pmlDepthCells}, {lines[axis] - upperDepth, upperDepth}}};
        // The grading along `axis` depends on pos[axis] alone (computeBaseGrading/finishGrading
        // never read the others). Any component off `axis` gives the staggering psi needs: a
        // component's psi is only ever driven along one of the other two axes.
        unsigned int pos[3] = {0, 0, 0};
        const int component = (axis + 1) % 3;
        for (const auto& [start, depth] : slabs) {
            for (std::uint32_t line = start; line < start + depth; ++line) {
                pos[axis] = line;
                const BaseGrading base = computeBaseGrading(op, pmlDepthCells, axis, pos);
                float bE, cE, bH, cH;
                computeBC(finishGrading(base, op, axis, pos, /*isVSide=*/true, component, alphaMax), dT, bE, cE);
                computeBC(finishGrading(base, op, axis, pos, /*isVSide=*/false, component, alphaMax), dT, bH, cH);
                out.layerOf[line] = out.layerCount();
                out.bE.push_back(bE);
                out.cE.push_back(cE);
                out.bH.push_back(bH);
                out.cH.push_back(cH);
            }
        }
    }
    return cpml;
}

namespace {

// Adds q to an existing (a, b) = (vv, vi) or (ii, iv) pair: with g = G*dt/(2C) the host's own
// loss, a = (1-g)/(1+g) and b = (dt/C)/(1+g), so recover g and dt/C, add q, and rebuild. Adding
// the same *rate* to both the E and H sides keeps sigma_e/eps = sigma_m/mu (impedance matched)
// whatever the host permittivity/permeability. a=b=0 marks a PEC edge or the never-updated
// outer H layer -- left alone.
void foldLoss(float& a, float& b, double qAdd) {
    if (qAdd == 0.0 || (a == 0.0F && b == 0.0F) || a <= -1.0F) return;
    const double g = (1.0 - a) / (1.0 + a);
    const double dtOverC = b * (1.0 + g);
    const double total = g + qAdd;
    a = static_cast<float>((1.0 - total) / (1.0 + total));
    b = static_cast<float>(dtOverC / (1.0 + total));
}

// Where each component lives in XY (see CopperDomainMask::StaggeredPosition).
constexpr CopperDomainMask::StaggeredPosition kEPosition[3] = {CopperDomainMask::HalfX, CopperDomainMask::HalfY,
                                                               CopperDomainMask::Node};
constexpr CopperDomainMask::StaggeredPosition kHPosition[3] = {CopperDomainMask::HalfY, CopperDomainMask::HalfX,
                                                               CopperDomainMask::HalfXY};

} // namespace

CopperRingAbsorber::CopperRingAbsorber(const CopperDomainMask& domainMask, double timestepSeconds,
                                       const CopperGridDims& dims) {
    const std::uint32_t depth = domainMask.pmlDepth;
    if (domainMask.empty() || domainMask.ringLayerMetres <= 0.0 || depth == 0 || domainMask.nx != dims.nx ||
        domainMask.ny != dims.ny) {
        return;
    }
    _mask = &domainMask;

    // Per-layer half-step damping q = (sigma/eps0)*dt/2, sigma taken at the layer's centre from the
    // same depth profile the rectangular CPML uses (whose round-trip normal-incidence attenuation
    // exp(-2*Z0*integral(sigma)) is the designed 1e-6 -- identical for a matched lossy layer).
    const double dl = domainMask.ringLayerMetres;
    const double width = dl * depth;
    _q.assign(static_cast<std::size_t>(depth) + 1, 0.0);
    for (std::uint32_t layer = 1; layer <= depth; ++layer) {
        const double sigma =
            defaultSigmaGrading((static_cast<double>(layer) - 0.5) * dl, dl, width, physical::impedance0);
        _q[layer] = sigma / physical::epsilon0 * timestepSeconds / 2.0;
    }
}

void CopperRingAbsorber::foldE(int n, std::uint32_t x, std::uint32_t y, float& vv, float& vi) const {
    if (_q.empty() || _mask->at(x, y) == 0) return; // inactive, or external: never updated
    const std::uint32_t depth = _mask->pmlDepth;
    foldLoss(vv, vi, _q[std::min<std::uint32_t>(_mask->layerAt(kEPosition[n], x, y), depth)]);
}

void CopperRingAbsorber::foldH(int n, std::uint32_t x, std::uint32_t y, float& ii, float& iv) const {
    if (_q.empty() || _mask->at(x, y) == 0) return;
    const std::uint32_t depth = _mask->pmlDepth;
    foldLoss(ii, iv, _q[std::min<std::uint32_t>(_mask->layerAt(kHPosition[n], x, y), depth)]);
}

void applyRingAbsorber(const CopperDomainMask& domainMask, double timestepSeconds, const CopperGridDims& dims,
                       float* const vv[3], float* const vi[3], float* const ii[3], float* const iv[3]) {
    const CopperRingAbsorber ring(domainMask, timestepSeconds, dims);
    if (!ring.active()) return;
    for (std::uint32_t z = 0; z < dims.nz; ++z) {
        for (std::uint32_t y = 0; y < dims.ny; ++y) {
            for (std::uint32_t x = 0; x < dims.nx; ++x) {
                const std::size_t i = copperGridIndex(dims, x, y, z);
                for (int n = 0; n < 3; ++n) {
                    ring.foldE(n, x, y, vv[n][i], vi[n][i]);
                    ring.foldH(n, x, y, ii[n][i], iv[n][i]);
                }
            }
        }
    }
}

} // namespace copper
