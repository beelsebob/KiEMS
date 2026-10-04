// Shared CSX fixture builders + small cross-check helpers for CopperTests. Deliberately independent
// of kiems/libkiems:
// these build synthetic CSXCAD structures directly, so CopperTests never depends on anything outside
// Copper itself plus CSXCAD.
//
// Uses the flat (unnamespaced) CSXCAD includes throughout, matching Copper's own sources -- those
// can't mix with the installed, namespaced `<CSXCAD/...>` forms in one translation unit.
#pragma once

#include <algorithm>
#include <cstdint>
#include <cstdlib>
#include <initializer_list>
#include <optional>
#include <string>
#include <utility>
#include <vector>

#include <ContinuousStructure.h>

#include "Internal/CopperEngine.hpp"
#include "Internal/CopperOperator.hpp"
#include "Internal/CopperYeeGrid.hpp"

namespace copper::test {

/// A trivial 11x11x3-line vacuum grid (1mm cells, PEC on every side), with a single soft E-field
/// (excitation type 0) excitation box in the middle of the domain, oriented along z -- the same
/// shape kiems's own MSLPort excitation uses. Heap-allocated, matching every builder below.
ContinuousStructure* buildTinyVacuumGrid();

/// buildTinyVacuumGrid()'s same domain, but with *no* excitation box anywhere -- used wherever the
/// stimulus is a hand-seeded impulse (CopperEngine::writeFieldCell) instead, so every engine under
/// comparison starts from a genuinely identical, otherwise-quiescent state.
ContinuousStructure* buildPecCavityNoExcitation();

/// Small fixture for CalcPEC's primitive-paint cache: overlapping metal/material boxes (the
/// higher-priority material must mask PEC) plus a zero-thickness z-normal metal polygon, matching
/// the primitive real PCB copper uses and its unusual GetBoundBox() contract (valid values with a
/// false return).
ContinuousStructure* buildPecPaintFixture();

/// A cube large enough on all 3 axes to hold a uniform-6-face, depth-8-cell CPML shell set with real
/// interior left over. Pair it with CopperOperator's default (Open) boundary on every face, matching
/// how a real CPML run is actually configured (see Internal/CopperCPML.hpp's own top comment).
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

/// Sets environment variables for its lifetime, then puts back whatever they were -- how a test turns
/// on the Metal backend's opt-in field-storage experiments (COPPER_FIELD_Q16, COPPER_FUSED, ...), which
/// an engine reads when built, without disturbing a suite run with one of them set throughout.
struct ScopedEnvironment {
    std::vector<std::pair<std::string, std::optional<std::string>>> previous;
    explicit ScopedEnvironment(std::initializer_list<std::pair<const char*, const char*>> variables) {
        for (const auto& [name, value] : variables) {
            const char* old = std::getenv(name);
            previous.emplace_back(name, old != nullptr ? std::optional<std::string>(old) : std::nullopt);
            setenv(name, value, 1);
        }
    }
    ~ScopedEnvironment() {
        for (auto it = previous.rbegin(); it != previous.rend(); ++it) {
            if (it->second) {
                setenv(it->first.c_str(), it->second->c_str(), 1);
            } else {
                unsetenv(it->first.c_str());
            }
        }
    }
    ScopedEnvironment(const ScopedEnvironment&) = delete;
    ScopedEnvironment& operator=(const ScopedEnvironment&) = delete;
};

/// A Metal-vs-reference parity tolerance written for fp32 fields, relaxed to 1e-4 when the suite runs
/// with COPPER_FIELD_Q16=1 or COPPER_FIELD_MIXED=1: a 16-bit store is up to half a tile step (~1e-5 of
/// the tile's range) off every timestep, which these short exact-match runs see directly (MIXED keeps
/// Q16 for the quieter tiles, and for every tile until its first promotion) -- and to 2e-3 under
/// COPPER_FIELD_FP16=1, whose 11-bit mantissa is relative to each value rather than a tile's range.
/// Their real accuracy check is the board comparison against fp32 S-parameters.
inline bool environmentFlag(const char* name) {
    const char* value = std::getenv(name);
    return value != nullptr && std::string(value) == "1";
}
inline float fieldParityTolerance(float fp32Tolerance) {
    if (environmentFlag("COPPER_FIELD_FP16")) return std::max(fp32Tolerance, 2e-3F);
    // MIXED is the Metal engine's default: only COPPER_FIELD_MIXED=0 gives plain fp32 fields.
    const char* mixed = std::getenv("COPPER_FIELD_MIXED");
    if (environmentFlag("COPPER_FIELD_Q16") || mixed == nullptr || std::string(mixed) != "0") {
        return std::max(fp32Tolerance, 1e-4F);
    }
    return fp32Tolerance;
}

/// A CopperOperator config with the test fixtures' standard 2.5 GHz Gaussian pulse, either a closed
/// PEC box (every face PEC) or CopperOperator's own default open boundary on every face.
CopperOperator::Config pulseConfig(std::uint32_t maxTimesteps, bool pecBox = true);

/// The largest |a-b| and |a| over every cell of every field component of two engines on the same
/// grid -- the comparison every engine-vs-engine check in this suite needs.
struct FieldDiff {
    float maxAbsDiff = 0.0F;
    float maxAbsValue = 0.0F;
};

FieldDiff diffFields(const CopperEngine& a, const CopperEngine& b);

} // namespace copper::test
