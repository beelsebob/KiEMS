// CopperEngine's field updates checked without a second solver. Two kinds of reference:
//  - ReferenceYee below: a plain, per-cell, double-precision Yee leapfrog written from the textbook
//    curl form (one generic formula, cyclically permuted per axis) over the same CopperYeeGrid
//    coefficients. It shares no code with either backend -- not the Metal kernels, not the CPU
//    backend's vDSP row updates -- so a mis-indexed neighbour, a dropped boundary clamp or a wrong
//    excitation sample shows up as a field mismatch.
//  - Physics: a closed PEC cavity must ring at the Yee scheme's own discrete TM110 eigenfrequency,
//    which checks the coefficients, timestep and update together against an analytic answer.
// Plus Metal-vs-CPU agreement on the paths ReferenceYee doesn't model (CPML).
#import <XCTest/XCTest.h>

#include <algorithm>
#include <cmath>
#include <memory>
#include <vector>

#include <CSRectGrid.h>

#include "CopperTestFixtures.hpp"
#include "Internal/CopperCPML.hpp"
#include "Internal/CopperExcitation.hpp"
#include "Internal/CopperLumpedRLC.hpp"
#include "Internal/CopperOperator.hpp"
#include "Internal/CopperPhysicalConstants.hpp"
#include "Internal/CopperYeeGrid.hpp"

using namespace copper::test;
using Engine = copper::CopperEngine;

namespace {

class ReferenceYee {
public:
    ReferenceYee(const copper::CopperYeeGrid& grid, const copper::CopperExcitation& excitation)
        : _grid(grid), _excitation(excitation) {
        for (int axis = 0; axis < 3; ++axis) {
            _e[axis].assign(grid.dims.cellCount(), 0.0);
            _h[axis].assign(grid.dims.cellCount(), 0.0);
        }
    }

    void seedE(int axis, std::uint32_t x, std::uint32_t y, std::uint32_t z, double value) {
        _e[axis][copper::copperGridIndex(_grid.dims, x, y, z)] = value;
    }

    void run(std::uint32_t steps) {
        for (std::uint32_t step = 0; step < steps; ++step) {
            stepE();
            for (const copper::CopperExcitationCell& cell : _excitation.voltageCells) {
                const std::int64_t k = static_cast<std::int64_t>(_timestep) - cell.delaySteps;
                if (k > 0 && k < static_cast<std::int64_t>(_excitation.voltageSignal.size())) {
                    _e[cell.axis][copper::copperGridIndex(_grid.dims, cell.x, cell.y, cell.z)] +=
                        static_cast<double>(cell.amplitude) * _excitation.voltageSignal[static_cast<std::size_t>(k)];
                }
            }
            stepH();
            ++_timestep;
        }
    }

    /// Largest |engine - reference| and |reference| over every component of every cell.
    FieldDiff diff(const Engine& engine) const {
        FieldDiff result;
        for (int f = 0; f < 6; ++f) {
            const std::vector<float> field = engine.readField(kAllFields[f]);
            const std::vector<double>& reference = f < 3 ? _e[f] : _h[f - 3];
            for (std::size_t i = 0; i < reference.size(); ++i) {
                result.maxAbsDiff = std::max(result.maxAbsDiff, static_cast<float>(std::fabs(field[i] - reference[i])));
                result.maxAbsValue = std::max(result.maxAbsValue, static_cast<float>(std::fabs(reference[i])));
            }
        }
        return result;
    }

private:
    // E[n] at p: vv*E + vi*((H[nPP](p) - H[nPP](p - e_nP)) - (H[nP](p) - H[nP](p - e_nPP))), with a
    // neighbour below index 0 taken as the cell itself (its difference vanishes).
    void stepE() {
        const std::uint32_t n[3] = {_grid.dims.nx, _grid.dims.ny, _grid.dims.nz};
        std::uint32_t p[3];
        for (p[2] = 0; p[2] < n[2]; ++p[2]) {
            for (p[1] = 0; p[1] < n[1]; ++p[1]) {
                for (p[0] = 0; p[0] < n[0]; ++p[0]) {
                    const std::uint32_t i = index(p);
                    for (int a = 0; a < 3; ++a) {
                        const int aP = (a + 1) % 3, aPP = (a + 2) % 3;
                        const double curl = (_h[aPP][i] - _h[aPP][index(p, aP, -1)]) -
                                            (_h[aP][i] - _h[aP][index(p, aPP, -1)]);
                        _e[a][i] = _grid.vv[a][i] * _e[a][i] + _grid.vi[a][i] * curl;
                    }
                }
            }
        }
    }

    // H[n] at p (one cell short of the E grid on every axis):
    // ii*H + iv*((E[nPP](p) - E[nPP](p + e_nP)) - (E[nP](p) - E[nP](p + e_nPP))).
    void stepH() {
        const std::uint32_t n[3] = {_grid.dims.nx, _grid.dims.ny, _grid.dims.nz};
        std::uint32_t p[3];
        for (p[2] = 0; p[2] + 1 < n[2]; ++p[2]) {
            for (p[1] = 0; p[1] + 1 < n[1]; ++p[1]) {
                for (p[0] = 0; p[0] + 1 < n[0]; ++p[0]) {
                    const std::uint32_t i = index(p);
                    for (int a = 0; a < 3; ++a) {
                        const int aP = (a + 1) % 3, aPP = (a + 2) % 3;
                        const double curl = (_e[aPP][i] - _e[aPP][index(p, aP, +1)]) -
                                            (_e[aP][i] - _e[aP][index(p, aPP, +1)]);
                        _h[a][i] = _grid.ii[a][i] * _h[a][i] + _grid.iv[a][i] * curl;
                    }
                }
            }
        }
    }

    std::uint32_t index(const std::uint32_t p[3], int axis = 0, int offset = 0) const {
        std::uint32_t q[3] = {p[0], p[1], p[2]};
        if (offset < 0 && q[axis] == 0) offset = 0;
        q[axis] = static_cast<std::uint32_t>(static_cast<std::int64_t>(q[axis]) + offset);
        return copper::copperGridIndex(_grid.dims, q[0], q[1], q[2]);
    }

    const copper::CopperYeeGrid& _grid;
    const copper::CopperExcitation& _excitation;
    std::vector<double> _e[3], _h[3];
    std::uint32_t _timestep = 0;
};

constexpr Engine::Backend kBackends[2] = {Engine::Backend::Metal, Engine::Backend::CPU};

NSString* backendName(Engine::Backend backend) { return backend == Engine::Backend::Metal ? @"Metal" : @"CPU"; }

} // namespace

@interface CopperEngineReferenceTests : XCTestCase
@end

@implementation CopperEngineReferenceTests

/// A single hand-seeded Ez impulse in a PEC box, no excitation. With nz=3 every H update touches a
/// boundary cell, so the boundary clamp is exercised from the first step.
- (void)testHandSeededImpulseMatchesReferenceLeapfrogOnBothBackends {
    const std::unique_ptr<ContinuousStructure> csx(buildPecCavityNoExcitation());
    const copper::CopperOperator op(*csx, pulseConfig(10));
    ReferenceYee reference(op.grid(), {});
    reference.seedE(2, 5, 5, 1, 1.0);
    reference.run(5);

    for (const Engine::Backend backend : kBackends) {
        Engine engine(op.grid(), {}, {}, backend);
        engine.writeFieldCell(Engine::Field::Ez, 5, 5, 1, 1.0F);
        engine.run(5);
        const FieldDiff diff = reference.diff(engine);
        XCTAssertGreaterThan(diff.maxAbsValue, 0.0F, @"%@: impulse never propagated", backendName(backend));
        XCTAssertLessThanOrEqual(diff.maxAbsDiff, fieldParityTolerance(1e-5F) * std::max(diff.maxAbsValue, 1.0F), @"%@", backendName(backend));
    }
}

/// COPPER_FIELD_Q16 regression: a whole board went NaN by step 160. The lumped-RLC correction writes
/// cells through writeFieldCell, which re-encodes the cell's tile on the CPU; in the tail of a
/// wavefront that tile spans next to nothing, its scale came out subnormal, and -- the CPU keeping
/// subnormals where Metal flushes them -- 1/scale was infinite and the tile's bias 0 * inf = NaN.
/// Tiles spanning under 2^-110 must flush to zero instead, then run on finitely.
- (void)testQ16TinyCellWritesStayFinite {
    const std::unique_ptr<ContinuousStructure> csx(buildPecCavityNoExcitation());
    const copper::CopperOperator op(*csx, pulseConfig(10));
    const copper::CopperGridDims dims = op.dims();
    const ScopedEnvironment q16({{"COPPER_FIELD_Q16", "1"}, {"COPPER_FIELD_FP16", "0"}});
    Engine engine(op.grid(), {}, {}, Engine::Backend::Metal);
    const std::uint32_t x = dims.nx / 2, y = dims.ny / 2, z = dims.nz / 2;

    // A unit impulse to propagate, plus tiny values alone in otherwise-zero tiles: one subnormal, one
    // just under the flush threshold, one just over it (which must survive).
    engine.writeFieldCell(Engine::Field::Ez, x, y, z, 1.0F);
    engine.writeFieldCell(Engine::Field::Ex, 1, 1, z, 1e-40F);
    engine.writeFieldCell(Engine::Field::Ey, 1, 1, z, 0x1p-111F);
    engine.writeFieldCell(Engine::Field::Hz, 1, 1, z, 0x1p-109F);
    XCTAssertEqual(engine.readFieldCell(Engine::Field::Ex, 1, 1, z), 0.0F);
    XCTAssertEqual(engine.readFieldCell(Engine::Field::Ey, 1, 1, z), 0.0F);
    XCTAssertEqual(engine.readFieldCell(Engine::Field::Hz, 1, 1, z), 0x1p-109F);
    XCTAssertEqual(engine.readFieldCell(Engine::Field::Ez, x, y, z), 1.0F);

    std::vector<float> values;
    for (std::uint32_t step = 0; step < 20; ++step) {
        engine.run(1);
        // Re-touch a cell each step, as the lumped-RLC correction does, with a value in the tail.
        engine.writeFieldCell(Engine::Field::Ex, 1, 1, z, 1e-40F);
        for (const Engine::Field field : kAllFields) {
            engine.readField(field, values);
            if (!std::all_of(values.begin(), values.end(), [](float value) { return std::isfinite(value); })) {
                XCTFail(@"field %d went non-finite at step %u", static_cast<int>(field), step + 1);
                return;
            }
        }
    }
    XCTAssertTrue(std::isfinite(engine.estimateEnergy()));
    XCTAssertGreaterThan(engine.estimateEnergy(), 0.0);
}

/// COPPER_FUSED: the fused E+H kernel must reproduce the separate E and H kernels -- over a CPML
/// cavity, so the interior runs fused while the absorbing slabs around it (and the tiles whose halo
/// reaches into them) run the separate kernels, against the same ping-ponged buffers. Tiles held in
/// fp32 (COPPER_FIELD_MIXED with every tile pinned) must agree to float rounding. Q16 tiles agree
/// only to Q16's own precision: the fused H update uses the new E straight from registers, the
/// separate one reads it back after it was rounded to 16 bits.
- (void)testFusedEHKernelMatchesSeparateKernels {
    const std::unique_ptr<ContinuousStructure> csx(buildCpmlCavityNoExcitation());
    copper::CopperOperator op(*csx, pulseConfig(30, /*pecBox=*/false));
    const copper::CopperCPML cpml =
        copper::buildCPML(op, 2 * copper::physical::pi * 100e6 * copper::physical::epsilon0, 8);

    struct Mode {
        const char* label;
        std::initializer_list<std::pair<const char*, const char*>> vars;
        float tolerance;
    };
    const Mode modes[] = {
        {"fp32 tiles", {{"COPPER_FIELD_MIXED", "1"}, {"COPPER_MIXED_PIN_ALL", "1"}, {"COPPER_FIELD_FP16", "0"}}, 1e-6F},
        {"Q16 tiles", {{"COPPER_FIELD_Q16", "1"}, {"COPPER_FIELD_MIXED", "0"}, {"COPPER_FIELD_FP16", "0"}}, 1e-4F},
    };
    for (const auto& [label, vars, tolerance] : modes) {
        // Whatever the suite as a whole is running with, this test picks its own modes.
        const ScopedEnvironment mode(vars);
        std::unique_ptr<Engine> separateEngine;
        {
            const ScopedEnvironment separateEnv({{"COPPER_FUSED", "0"}});
            separateEngine = std::make_unique<Engine>(op.grid(), copper::CopperExcitation{}, cpml, Engine::Backend::Metal);
        }
        Engine& separate = *separateEngine;
        std::unique_ptr<Engine> fused;
        {
            const ScopedEnvironment fusedEnv({{"COPPER_FUSED", "1"}});
            fused = std::make_unique<Engine>(op.grid(), copper::CopperExcitation{}, cpml, Engine::Backend::Metal);
        }
        for (Engine* engine : {&separate, fused.get()}) {
            engine->writeFieldCell(Engine::Field::Ez, 15, 15, 15, 1.0F); // fused interior
            // Inside the CPML -- small, since an H seed drives E two orders of magnitude larger.
            engine->writeFieldCell(Engine::Field::Hy, 6, 15, 15, 0.005F);
            engine->run(40);
        }
        XCTAssertGreaterThan(fused->fusedTileCount(), static_cast<std::size_t>(0), @"%s: nothing ran fused", label);
        float maxValue = 0.0F, maxDifference = 0.0F;
        for (const Engine::Field field : kAllFields) {
            const std::vector<float> a = separate.readField(field), b = fused->readField(field);
            for (std::size_t i = 0; i < a.size(); ++i) {
                maxValue = std::max(maxValue, std::fabs(a[i]));
                maxDifference = std::max(maxDifference, std::fabs(a[i] - b[i]));
            }
        }
        XCTAssertGreaterThan(maxValue, 0.0F);
        XCTAssertLessThanOrEqual(maxDifference, tolerance * maxValue, @"%s: fused E+H differs from separate E, H", label);
    }
}

/// COPPER_FUSED with its E corrections (the default): tiles holding voltage excitation or GPU lumped
/// RLC elements run fused too, the kernel applying both after its E update -- including to the
/// neighbouring cells it computes as halo, from their elements' old state. With fp32 tiles it must
/// match the separate kernels (and COPPER_FUSED_CORRECTIONS=0, which leaves those tiles to them) to
/// float rounding.
- (void)testFusedEHKernelAppliesExcitationAndLumpedRLC {
    const std::unique_ptr<ContinuousStructure> csx(buildTinyVacuumGrid());
    const copper::CopperOperator op(*csx, pulseConfig(150));
    XCTAssertFalse(op.excitation().voltageCells.empty());
    const std::unique_ptr<ContinuousStructure> lumpedCsx(buildSeriesLumpedRLCFixture(50.0, 2e-9, 1e-12));
    copper::CopperOperator lumpedOp(*lumpedCsx, pulseConfig(150));
    // The same 11x11x3 grid: put the fixture's element on the excited grid, one cell over.
    std::vector<copper::CopperLumpedRLCCell> lumpedRLC = copper::discoverLumpedRLC(*lumpedCsx, lumpedOp.grid(), lumpedOp);
    XCTAssertEqual(lumpedRLC.size(), static_cast<std::size_t>(1));
    lumpedRLC[0].x = 4;

    const ScopedEnvironment fp32Tiles({{"COPPER_FIELD_MIXED", "1"}, {"COPPER_MIXED_PIN_ALL", "1"}, {"COPPER_FIELD_FP16", "0"}});
    std::unique_ptr<Engine> separateEngine, fused, fusedWithout;
    {
        const ScopedEnvironment separateEnv({{"COPPER_FUSED", "0"}});
        separateEngine = std::make_unique<Engine>(op.grid(), op.excitation(), copper::CopperCPML{},
                                                  Engine::Backend::Metal);
    }
    Engine& separate = *separateEngine;
    {
        const ScopedEnvironment fusedEnv({{"COPPER_FUSED", "1"}, {"COPPER_FUSED_CORRECTIONS", "1"}});
        fused = std::make_unique<Engine>(op.grid(), op.excitation(), copper::CopperCPML{},
                                         Engine::Backend::Metal);
        const ScopedEnvironment without({{"COPPER_FUSED_CORRECTIONS", "0"}});
        fusedWithout = std::make_unique<Engine>(op.grid(), op.excitation(), copper::CopperCPML{},
                                                Engine::Backend::Metal);
    }
    for (Engine* engine : {&separate, fused.get(), fusedWithout.get()}) {
        engine->setLumpedRLC(lumpedRLC);
        engine->runWithProbeSampling(100, [](std::uint32_t) { return true; });
    }
    // Every tile of this PEC box is plain once excitation and lumped RLC can be fused; without the
    // corrections, the excited/lumped tile and those whose halo reaches it can't be.
    XCTAssertGreaterThan(fused->fusedTileCount(), fusedWithout->fusedTileCount());
    for (Engine* engine : {fused.get(), fusedWithout.get()}) {
        const FieldDiff diff = diffFields(*engine, separate);
        XCTAssertGreaterThan(diff.maxAbsValue, 0.0F);
        XCTAssertLessThanOrEqual(diff.maxAbsDiff, 1e-6F * diff.maxAbsValue);
    }
}

/// No seeding: both start from zero and get their only state from the Gaussian soft source, so this
/// pins apply_excitation_e's sample indexing as well as the interior update.
- (void)testExcitedRunMatchesReferenceLeapfrogOnBothBackends {
    const std::unique_ptr<ContinuousStructure> csx(buildTinyVacuumGrid());
    const copper::CopperOperator op(*csx, pulseConfig(150));
    XCTAssertFalse(op.excitation().voltageCells.empty());
    ReferenceYee reference(op.grid(), op.excitation());
    reference.run(100);

    for (const Engine::Backend backend : kBackends) {
        Engine engine(op.grid(), op.excitation(), {}, backend);
        engine.run(100);
        const FieldDiff diff = reference.diff(engine);
        XCTAssertGreaterThan(diff.maxAbsValue, 0.0F, @"%@: excitation never landed", backendName(backend));
        XCTAssertLessThanOrEqual(diff.maxAbsDiff, fieldParityTolerance(1e-4F) * std::max(diff.maxAbsValue, 1.0F), @"%@", backendName(backend));
    }
}

/// Graded mesh with lossy dielectric, lossy magnetic and metal blocks: every coefficient differs, so
/// a backend reading the wrong cell's coefficient (or a coefficient-table lookup gone wrong) diverges.
- (void)testGradedMaterialRunMatchesReferenceLeapfrogOnBothBackends {
    const std::unique_ptr<ContinuousStructure> csx(buildGradedMaterialFixture());
    const copper::CopperOperator op(*csx, pulseConfig(10));
    const copper::CopperGridDims dims = op.dims();
    ReferenceYee reference(op.grid(), {});
    reference.seedE(2, dims.nx / 3, dims.ny / 2, dims.nz / 4, 1.0);
    reference.seedE(0, 2 * dims.nx / 3, dims.ny / 3, dims.nz / 2, 1.0);
    reference.run(30);

    for (const Engine::Backend backend : kBackends) {
        Engine engine(op.grid(), {}, {}, backend);
        engine.writeFieldCell(Engine::Field::Ez, dims.nx / 3, dims.ny / 2, dims.nz / 4, 1.0F);
        engine.writeFieldCell(Engine::Field::Ex, 2 * dims.nx / 3, dims.ny / 3, dims.nz / 2, 1.0F);
        engine.run(30);
        const FieldDiff diff = reference.diff(engine);
        XCTAssertGreaterThan(diff.maxAbsValue, 0.0F);
        XCTAssertLessThanOrEqual(diff.maxAbsDiff, fieldParityTolerance(1e-4F) * std::max(diff.maxAbsValue, 1.0F), @"%@", backendName(backend));
    }
}

/// A 20x20 mm PEC box, two cells thick, seeded uniformly in z, so the TM110 mode is exactly 2D. The
/// Yee scheme's own eigenfrequency for that mode on a uniform mesh is
///   sin(w*dT/2)^2 / (c*dT)^2 = 2 * sin(pi*dx/(2a))^2 / dx^2,
/// slightly below the continuum value c/(2a)*sqrt(2). An off-centre impulse rings every TMmn0 mode;
/// TM110 is the only one between 8 and 13 GHz (TM120/TM210 sit at 16.8 GHz). A Hann-windowed DFT
/// scan of a probe's Ez must peak at the discrete frequency.
- (void)testPECCavityRingsAtTheYeeSchemeTM110Eigenfrequency {
    constexpr int cells = 20;
    constexpr double dx = 1e-3, a = cells * dx;
    auto csx = std::make_unique<ContinuousStructure>();
    CSRectGrid* mesh = csx->GetGrid();
    mesh->SetDeltaUnit(1e-3);
    for (int i = 0; i <= cells; ++i) {
        mesh->AddDiscLine(0, i);
        mesh->AddDiscLine(1, i);
    }
    for (int i = 0; i <= 2; ++i) mesh->AddDiscLine(2, i);
    const copper::CopperOperator op(*csx, pulseConfig(10));
    const double dT = op.timestepSeconds();

    const double c0 = 1.0 / std::sqrt(copper::physical::epsilon0 * copper::physical::mu0);
    constexpr double kPi = copper::physical::pi;
    const double continuum = c0 / (2.0 * a) * std::sqrt(2.0);
    const double s = std::sin(kPi * dx / (2.0 * a));
    const double discrete = 2.0 / (2.0 * kPi * dT) * std::asin(c0 * dT * std::sqrt(2.0) * s / dx);
    XCTAssertLessThan(discrete, continuum);
    XCTAssertGreaterThan(discrete, 0.99 * continuum);

    constexpr std::uint32_t steps = 4096;
    for (const Engine::Backend backend : kBackends) {
        Engine engine(op.grid(), {}, {}, backend);
        for (std::uint32_t z = 0; z < 2; ++z) engine.writeFieldCell(Engine::Field::Ez, 6, 8, z, 1.0F);
        std::vector<double> samples;
        samples.reserve(steps);
        engine.runWithProbeSampling(steps, [&](std::uint32_t) {
            samples.push_back(engine.readFieldCell(Engine::Field::Ez, 13, 11, 0));
            return true;
        });
        XCTAssertEqual(samples.size(), static_cast<std::size_t>(steps));

        double bestFrequency = 0.0, bestPower = -1.0;
        for (double f = 8e9; f <= 13e9; f += 1e6) {
            double re = 0.0, im = 0.0;
            for (std::size_t n = 0; n < samples.size(); ++n) {
                const double window = 0.5 - 0.5 * std::cos(2.0 * kPi * static_cast<double>(n) / static_cast<double>(samples.size() - 1));
                const double phase = 2.0 * kPi * f * static_cast<double>(n) * dT;
                re += window * samples[n] * std::cos(phase);
                im -= window * samples[n] * std::sin(phase);
            }
            if (re * re + im * im > bestPower) {
                bestPower = re * re + im * im;
                bestFrequency = f;
            }
        }
        NSLog(@"%@: TM110 peak %.4f GHz, Yee eigenfrequency %.4f GHz, continuum %.4f GHz", backendName(backend),
              bestFrequency / 1e9, discrete / 1e9, continuum / 1e9);
        XCTAssertEqualWithAccuracy(bestFrequency, discrete, 1e-3 * discrete, @"%@", backendName(backend));
    }
}

/// A no-op run (steps=0) must leave every field exactly at its zero-initialized state.
- (void)testZeroStepsLeavesFieldsAtZeroInitialCondition {
    const std::unique_ptr<ContinuousStructure> csx(buildPecCavityNoExcitation());
    const copper::CopperOperator op(*csx, pulseConfig(10));
    for (const Engine::Backend backend : kBackends) {
        Engine engine(op.grid(), {}, {}, backend);
        engine.run(0);
        for (const Engine::Field field : kAllFields) {
            for (const float v : engine.readField(field)) {
                XCTAssertEqual(v, 0.0F);
            }
        }
    }
}

/// CPML isn't modelled by ReferenceYee, so the backends are held to each other: a seeded impulse
/// inside the x-min slab, absorbed for several domain crossings, must come out the same on both,
/// stay finite, and lose energy.
- (void)testCPMLRunAgreesAcrossBackendsAndAbsorbs {
    const std::unique_ptr<ContinuousStructure> csx(buildCpmlCavityNoExcitation());
    copper::CopperOperator op(*csx, pulseConfig(30, /*pecBox=*/false));
    const copper::CopperCPML cpml =
        copper::buildCPML(op, 2 * copper::physical::pi * 100e6 * copper::physical::epsilon0, 8);
    XCTAssertFalse(cpml.empty());

    Engine metal(op.grid(), {}, cpml, Engine::Backend::Metal);
    Engine cpu(op.grid(), {}, cpml, Engine::Backend::CPU);
    double energyAtStart = 0.0;
    for (Engine* engine : {&metal, &cpu}) {
        engine->writeFieldCell(Engine::Field::Ez, 6, 15, 15, 1.0F);
        energyAtStart = engine->estimateEnergy();
        engine->run(60);
        XCTAssertLessThanOrEqual(engine->estimateEnergy(), energyAtStart);
        for (const Engine::Field field : kAllFields) {
            for (const float v : engine->readField(field)) {
                XCTAssertTrue(std::isfinite(v));
            }
        }
    }
    const FieldDiff diff = diffFields(metal, cpu);
    XCTAssertGreaterThan(diff.maxAbsValue, 0.0F);
    XCTAssertLessThanOrEqual(diff.maxAbsDiff, fieldParityTolerance(1e-4F) * std::max(diff.maxAbsValue, 1.0F));
}

@end
