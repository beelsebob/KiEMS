// Two layers of coverage for Internal/CopperProbes.hpp: pure formula unit tests against small,
// hand-built synthetic field accessors (isolating sampleVoltageProbe/sampleCurrentProbe's own
// indexing/sign logic from FDTD field correctness entirely -- no engine, no CSX at all), plus an
// end-to-end discovery + Metal-vs-CPU-backend sampling + real ASCII file round trip, confirming the
// file Copper writes is the file kiems's own ports.cpp reader already expects, unmodified.
#import <XCTest/XCTest.h>

#include <cmath>
#include <fstream>
#include <sstream>
#include <vector>

#include "CopperTestFixtures.hpp"
#include "Internal/CopperExcitation.hpp"
#include "Internal/CopperOperator.hpp"
#include "Internal/CopperProbes.hpp"
#include "Internal/CopperYeeGrid.hpp"

using namespace copper::test;

namespace {

/// A minimal ad-hoc reimplementation of libkiems/kiems/ports.cpp's own `_loadUiFile` parsing rule
/// (skip blank/`%`-prefixed lines, take the first 2 whitespace-separated tokens of every other line
/// as time/value) -- confirms CopperProbeWriter's actual file output round-trips through *that exact*
/// rule, not just a rule this file assumes is equivalent.
std::vector<std::pair<double, double>> loadProbeFileLikePortsCpp(const std::filesystem::path& path) {
    std::ifstream file(path);
    std::vector<std::pair<double, double>> rows;
    std::string line;
    while (std::getline(file, line)) {
        if (line.empty() || line[0] == '%') {
            continue;
        }
        std::istringstream iss(line);
        double t = 0.0, v = 0.0;
        if (iss >> t >> v) {
            rows.emplace_back(t, v);
        }
    }
    return rows;
}

} // namespace

@interface CopperProbeFormulaTests : XCTestCase
@end

@implementation CopperProbeFormulaTests

- (void)testVoltageProbeSumsForwardDirection {
    copper::CopperProbe probe;
    probe.start[0] = 2;
    probe.start[1] = 3;
    probe.start[2] = 4;
    probe.stop[0] = 2;
    probe.stop[1] = 3;
    probe.stop[2] = 7;
    auto field = [](std::uint32_t axis, std::uint32_t, std::uint32_t, std::uint32_t) -> float {
        return axis == 2 ? 1.0F : 0.0F;
    };
    // 3 cells (z=4,5,6) each contributing 1.0.
    XCTAssertEqualWithAccuracy(copper::sampleVoltageProbe(probe, field), 3.0, 1e-12);
}

/// start[n] > stop[n] encodes integration sign -- reversing start/stop must negate the result.
- (void)testVoltageProbeReversedDirectionNegatesResult {
    copper::CopperProbe probe;
    probe.start[0] = 2;
    probe.start[1] = 3;
    probe.start[2] = 7;
    probe.stop[0] = 2;
    probe.stop[1] = 3;
    probe.stop[2] = 4;
    auto field = [](std::uint32_t axis, std::uint32_t, std::uint32_t, std::uint32_t) -> float {
        return axis == 2 ? 1.0F : 0.0F;
    };
    XCTAssertEqualWithAccuracy(copper::sampleVoltageProbe(probe, field), -3.0, 1e-12);
}

- (void)testVoltageProbeDegenerateBoxReturnsZero {
    copper::CopperProbe probe;
    probe.start[0] = probe.stop[0] = 4;
    probe.start[1] = probe.stop[1] = 4;
    probe.start[2] = probe.stop[2] = 4;
    auto field = [](std::uint32_t, std::uint32_t, std::uint32_t, std::uint32_t) -> float { return 42.0F; };
    XCTAssertEqualWithAccuracy(copper::sampleVoltageProbe(probe, field), 0.0, 1e-12);
}

/// z-normal Ampere loop (case 2), every side "inside" the domain: cross-checks
/// sampleCurrentProbe()'s output against the same 4-term formula computed by hand from a
/// deterministic, spatially-varying field(axis,x,y,z) = 100*axis + 10*x + y.
- (void)testCurrentProbeZNormalLoopMatchesHandComputedFormula {
    copper::CopperProbe probe;
    probe.normalDir = 2;
    probe.start[0] = 2;
    probe.start[1] = 2;
    probe.start[2] = 0;
    probe.stop[0] = 5;
    probe.stop[1] = 5;
    probe.stop[2] = 0;
    for (int i = 0; i < 3; ++i) {
        probe.startInside[i] = true;
        probe.stopInside[i] = true;
    }
    auto field = [](std::uint32_t axis, std::uint32_t x, std::uint32_t y, std::uint32_t) -> float {
        return static_cast<float>(100 * axis + 10 * x + y);
    };
    // term1 (axis0,y=2,z=0) i=3..5: 32+42+52=126
    // term2 (axis1,x=5,z=0) i=3..5: 153+154+155=462
    // term3 (axis0,y=5,z=0) i=3..5: 35+45+55=135, subtracted
    // term4 (axis1,x=2,z=0) i=3..5: 123+124+125=372, subtracted
    // 126+462-135-372 = 81
    XCTAssertEqualWithAccuracy(copper::sampleCurrentProbe(probe, field), 81.0, 1e-6);
}

/// Toggling stopInside[0] off must drop exactly the one term that guards on it (term2), matching the
/// header's own per-term `stopInside[0] && startInside[2]` guard -- a probe box against the edge of
/// the domain (no neighbor on one side) shouldn't try to read past it.
- (void)testCurrentProbeZNormalLoopOmitsTermWhenStopOutsideDomain {
    copper::CopperProbe probe;
    probe.normalDir = 2;
    probe.start[0] = 2;
    probe.start[1] = 2;
    probe.start[2] = 0;
    probe.stop[0] = 5;
    probe.stop[1] = 5;
    probe.stop[2] = 0;
    for (int i = 0; i < 3; ++i) {
        probe.startInside[i] = true;
        probe.stopInside[i] = true;
    }
    probe.stopInside[0] = false;
    auto field = [](std::uint32_t axis, std::uint32_t x, std::uint32_t y, std::uint32_t) -> float {
        return static_cast<float>(100 * axis + 10 * x + y);
    };
    // term1 (126) - term3 (135) - term4 (372) = -381 (term2 omitted)
    XCTAssertEqualWithAccuracy(copper::sampleCurrentProbe(probe, field), -381.0, 1e-6);
}

- (void)testCurrentProbeWithoutValidNormalDirReturnsZero {
    copper::CopperProbe probe; // normalDir defaults to -1
    auto field = [](std::uint32_t, std::uint32_t, std::uint32_t, std::uint32_t) -> float { return 42.0F; };
    XCTAssertEqualWithAccuracy(copper::sampleCurrentProbe(probe, field), 0.0, 1e-12);
}

@end

@interface CopperProbeSamplingParityTests : XCTestCase
@end

@implementation CopperProbeSamplingParityTests

/// Discovery finds exactly one voltage + one current probe; values sampled from the Metal and CPU
/// backends (both via the identical sampleVoltageProbe/sampleCurrentProbe formulas, applied to each
/// engine's own fields) must agree; and CopperProbeWriter's real ASCII output must round-trip through
/// ports.cpp's own parsing rule with the exact weighted values/timestamps that were sampled.
- (void)testProbeDiscoverySamplingParityAndFileRoundTrip {
    ContinuousStructure* probeCsx = buildProbeFixture();
    copper::CopperOperator newOp(*probeCsx, pulseConfig(150));
    const copper::CopperYeeGrid& grid = newOp.grid();
    const copper::CopperExcitation& excitation = newOp.excitation();
    const std::vector<copper::CopperProbe> probes = copper::discoverProbes(*probeCsx, newOp);
    XCTAssertEqual(probes.size(), static_cast<std::size_t>(2));

    const copper::CopperProbe* voltageProbe = nullptr;
    const copper::CopperProbe* currentProbe = nullptr;
    for (const copper::CopperProbe& p : probes) {
        if (p.type == copper::CopperProbeType::Voltage) {
            voltageProbe = &p;
        } else {
            currentProbe = &p;
        }
    }
    XCTAssertTrue(voltageProbe != nullptr && currentProbe != nullptr);

    copper::CopperEngine gpuEngine(grid, excitation);
    const std::filesystem::path tmpDir = std::filesystem::temp_directory_path();
    const std::filesystem::path voltagePath = tmpDir / voltageProbe->name;
    const std::filesystem::path currentPath = tmpDir / currentProbe->name;

    const std::uint32_t steps = 100;
    double lastGpuVoltage = 0.0;
    double lastGpuCurrent = 0.0;
    {
        copper::CopperProbeWriter voltageWriter(tmpDir, *voltageProbe);
        copper::CopperProbeWriter currentWriter(tmpDir, *currentProbe);
        auto gpuE = [&](std::uint32_t axis, std::uint32_t x, std::uint32_t y, std::uint32_t z) {
            return gpuEngine.readFieldCell(static_cast<copper::CopperEngine::Field>(static_cast<int>(axis)), x, y, z);
        };
        auto gpuH = [&](std::uint32_t axis, std::uint32_t x, std::uint32_t y, std::uint32_t z) {
            return gpuEngine.readFieldCell(static_cast<copper::CopperEngine::Field>(static_cast<int>(axis) + 3), x, y,
                                            z);
        };
        gpuEngine.runWithProbeSampling(steps, [&](std::uint32_t globalTimestep) -> bool {
            lastGpuVoltage = copper::sampleVoltageProbe(*voltageProbe, gpuE);
            lastGpuCurrent = copper::sampleCurrentProbe(*currentProbe, gpuH);
            voltageWriter.sample(static_cast<double>(globalTimestep) * grid.timestepSeconds, lastGpuVoltage);
            currentWriter.sample((static_cast<double>(globalTimestep) + 0.5) * grid.timestepSeconds, lastGpuCurrent);
            return true;
        });
    }
    copper::CopperEngine cpuEngine(grid, excitation, {}, copper::CopperEngine::Backend::CPU);
    cpuEngine.run(steps);

    auto cpuE = [&](std::uint32_t axis, std::uint32_t x, std::uint32_t y, std::uint32_t z) {
        return cpuEngine.readFieldCell(static_cast<copper::CopperEngine::Field>(static_cast<int>(axis)), x, y, z);
    };
    auto cpuH = [&](std::uint32_t axis, std::uint32_t x, std::uint32_t y, std::uint32_t z) {
        return cpuEngine.readFieldCell(static_cast<copper::CopperEngine::Field>(static_cast<int>(axis) + 3), x, y, z);
    };
    const double cpuVoltage = copper::sampleVoltageProbe(*voltageProbe, cpuE);
    const double cpuCurrent = copper::sampleCurrentProbe(*currentProbe, cpuH);

    XCTAssertFalse(cpuVoltage == 0.0 && cpuCurrent == 0.0,
                   @"both probes read zero on the CPU backend -- fixture excitation/timing looks wrong");
    const double voltageTolerance = 1e-4 * std::max(std::fabs(cpuVoltage), 1e-6);
    const double currentTolerance = 1e-4 * std::max(std::fabs(cpuCurrent), 1e-6);
    XCTAssertLessThanOrEqual(std::fabs(lastGpuVoltage - cpuVoltage), voltageTolerance);
    XCTAssertLessThanOrEqual(std::fabs(lastGpuCurrent - cpuCurrent), currentTolerance);

    const std::vector<std::pair<double, double>> voltageRows = loadProbeFileLikePortsCpp(voltagePath);
    const std::vector<std::pair<double, double>> currentRows = loadProbeFileLikePortsCpp(currentPath);
    XCTAssertEqual(voltageRows.size(), static_cast<std::size_t>(steps));
    XCTAssertEqual(currentRows.size(), static_cast<std::size_t>(steps));

    const auto& [lastVoltageTime, lastVoltageValue] = voltageRows.back();
    const auto& [lastCurrentTime, lastCurrentValue] = currentRows.back();
    const double expectedLastVoltageTime = static_cast<double>(steps) * grid.timestepSeconds;
    const double expectedLastCurrentTime = (static_cast<double>(steps) + 0.5) * grid.timestepSeconds;
    XCTAssertEqualWithAccuracy(lastVoltageTime, expectedLastVoltageTime, 1e-9 * expectedLastVoltageTime);
    XCTAssertEqualWithAccuracy(lastCurrentTime, expectedLastCurrentTime, 1e-9 * expectedLastCurrentTime);

    // CopperProbeWriter::sample() writes rawValue*probe.weight, so the file's value is the
    // *weighted* sample, not lastGpuVoltage/lastGpuCurrent themselves.
    const double expectedVoltageValue = lastGpuVoltage * voltageProbe->weight;
    const double expectedCurrentValue = lastGpuCurrent * currentProbe->weight;
    XCTAssertEqualWithAccuracy(lastVoltageValue, expectedVoltageValue, 1e-10 * std::max(std::fabs(expectedVoltageValue), 1e-6));
    XCTAssertEqualWithAccuracy(lastCurrentValue, expectedCurrentValue, 1e-10 * std::max(std::fabs(expectedCurrentValue), 1e-6));

    std::filesystem::remove(voltagePath);
    std::filesystem::remove(currentPath);
    delete probeCsx;
}

@end
