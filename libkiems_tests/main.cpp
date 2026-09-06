#include <algorithm>
#include <cmath>
#include <complex>
#include <cstdlib>
#include <functional>
#include <iostream>
#include <limits>
#include <string>
#include <unordered_set>
#include <utility>
#include <vector>

#include <nlohmann/json.hpp>

#include "kiems/component_value.hpp"
#include "kiems/config.hpp"
#include "kiems/eye_diagram.hpp"
#include "kiems/fft_postprocess.hpp"
#include "kiems/net_name.hpp"

namespace {

class TestContext {
public:
    void expect(bool condition, const std::string& message) {
        if (!condition) {
            ++_failures;
            std::cerr << "    " << message << '\n';
        }
    }

    void expectNear(double actual, double expected, double tolerance, const std::string& message) {
        expect(std::isfinite(actual) && std::abs(actual - expected) <= tolerance,
               message + " (expected " + std::to_string(expected) + ", got " + std::to_string(actual) + ")");
    }

    int failures() const { return _failures; }

private:
    int _failures = 0;
};

using Test = std::pair<std::string, std::function<void(TestContext&)>>;

void testComponentValueParsing(TestContext& context) {
    struct ValidCase {
        std::string input;
        char unit;
        double expected;
    };
    const std::vector<ValidCase> validCases = {
        {"10k", 'R', 10'000.0},
        {"4k7", 'R', 4'700.0},
        {"0R1", 'R', 0.1},
        {"1M2", 'R', 1.2e6},
        {"  22ohms  ", 'R', 22.0},
        {"47k\xCE\xA9", 'R', 47'000.0},
        {"100nF", 'F', 100e-9},
        {"4u7", 'F', 4.7e-6},
        {"4.7\xC2\xB5H", 'H', 4.7e-6},
        {"2mH", 'H', 2e-3},
    };

    for (const ValidCase& testCase : validCases) {
        const auto result = kiems::parseComponentValue(testCase.input, testCase.unit);
        context.expect(result.has_value(), "parseComponentValue rejected valid input: " + testCase.input);
        if (result.has_value()) {
            const double tolerance = std::max(std::abs(testCase.expected) * 1e-12, 1e-15);
            context.expectNear(*result, testCase.expected, tolerance,
                               "parseComponentValue returned the wrong value for " + testCase.input);
        }
    }

    const std::vector<std::string> invalidCases = {"", "   ", "LED", "4k7k", "R", "10kF", "1.2.3"};
    for (const std::string& input : invalidCases) {
        context.expect(!kiems::parseComponentValue(input, 'R').has_value(),
                       "parseComponentValue accepted invalid resistor input: " + input);
    }
}

void testNetNameNormalization(TestContext& context) {
    const kiems::NetName escaped("/MCU{slash}USB{slash}D+");
    const kiems::NetName literal("/MCU/USB/D+");

    context.expect(escaped.raw() == "/MCU{slash}USB{slash}D+", "NetName did not preserve its raw value");
    context.expect(escaped.unescaped() == "/MCU/USB/D+", "NetName did not unescape every slash token");
    context.expect(escaped == literal, "escaped and literal forms of the same net did not compare equal");
    context.expect(kiems::NetNameHash{}(escaped) == kiems::NetNameHash{}(literal),
                   "equal NetName values produced different hashes");

    std::unordered_set<kiems::NetName, kiems::NetNameHash> names;
    names.insert(escaped);
    names.insert(literal);
    context.expect(names.size() == 1, "NetName hashing did not deduplicate normalized names");

    const nlohmann::json json = escaped;
    context.expect(json == escaped.raw(), "NetName JSON serialization did not preserve the raw spelling");
    context.expect(json.get<kiems::NetName>().raw() == escaped.raw(), "NetName JSON round trip changed the raw value");
}

void testArgumentDefaultsAndMutation(TestContext& context) {
    kiems::Arguments arguments;
    context.expect(arguments.oversampling() == 4, "Arguments default oversampling changed");
    context.expect(arguments.backend() == kiems::FDTDBackend::OpenEMSCPU, "Arguments default backend changed");
    context.expect(arguments.pmlKind() == kiems::PMLKind::CPML, "Arguments default PML kind changed");
    context.expect(!arguments.geometry() && !arguments.simulate() && !arguments.postprocess() && !arguments.all(),
                   "Arguments action flags should default to false");

    arguments.setGeometry(true);
    arguments.setOversampling(8);
    arguments.setBackend(kiems::FDTDBackend::CopperGPU);
    arguments.setPmlKind(kiems::PMLKind::UPML);
    arguments.setConfigPath("board.json");
    context.expect(arguments.geometry(), "Arguments geometry setter did not persist");
    context.expect(arguments.oversampling() == 8, "Arguments oversampling setter did not persist");
    context.expect(arguments.backend() == kiems::FDTDBackend::CopperGPU, "Arguments backend setter did not persist");
    context.expect(arguments.pmlKind() == kiems::PMLKind::UPML, "Arguments PML setter did not persist");
    context.expect(arguments.configPath() == std::optional<std::string>("board.json"),
                   "Arguments config path setter did not persist");
}

void testWaveformSynthesis(TestContext& context) {
    const auto tone = kiems::synthesizeToneBurst(1e9, 2.0, 0.0, 1e-9, 4e-9, 0.25e-9, 32);
    context.expect(tone.samples.size() == 32, "tone synthesis returned the wrong sample count");
    context.expectNear(tone.dt, 0.25e-9, 1e-21, "tone synthesis changed the sample interval");
    context.expect(tone.samples[0] == 0.0 && tone.samples[1] == 0.0 && tone.samples[2] == 0.0,
                   "tone synthesis emitted samples before its start time");

    const auto silent = kiems::synthesizeToneBurst(1e9, 2.0, 0.0, 0.0, 0.0, 1e-9, 8);
    context.expect(std::all_of(silent.samples.begin(), silent.samples.end(), [](double value) { return value == 0.0; }),
                   "a zero-duration tone burst was not silent");

    kiems::TimeWaveform first{0.5, {1.0, 2.0, 3.0}};
    kiems::TimeWaveform second{0.5, {-0.5, 4.0, 1.0}};
    const auto sum = kiems::superpose({first, second});
    context.expect(sum.dt == 0.5, "superpose changed the sample interval");
    context.expect(sum.samples == std::vector<double>({0.5, 6.0, 4.0}), "superpose returned incorrect samples");
    context.expect(kiems::superpose({}).samples.empty(), "superpose of no waveforms should be empty");
}

void testEyeDiagramValidation(TestContext& context) {
    const std::vector<double> frequencies = {0.0, 1e9, 2e9};
    const std::vector<std::complex<double>> transfer(frequencies.size(), {1.0, 0.0});
    context.expect(!kiems::computeEyeDiagram({}, {}, 1e9).has_value(), "eye diagram accepted empty input");
    context.expect(!kiems::computeEyeDiagram(frequencies, {{1.0, 0.0}}, 1e9).has_value(),
                   "eye diagram accepted mismatched input lengths");
    context.expect(!kiems::computeEyeDiagram(frequencies, transfer, 0.0).has_value(),
                   "eye diagram accepted a zero bit rate");
    context.expect(!kiems::computeEyeDiagram(frequencies, transfer, std::numeric_limits<double>::infinity()).has_value(),
                   "eye diagram accepted an infinite bit rate");
}

void testEyeDiagramIdentityChannel(TestContext& context) {
    constexpr std::size_t frequencyCount = 129;
    std::vector<double> frequencies(frequencyCount);
    std::vector<std::complex<double>> transfer(frequencyCount, {1.0, 0.0});
    for (std::size_t index = 0; index < frequencyCount; ++index) {
        frequencies[index] = static_cast<double>(index) * 4e9 / static_cast<double>(frequencyCount - 1);
    }

    const auto first = kiems::computeEyeDiagram(frequencies, transfer, 1e9);
    const auto second = kiems::computeEyeDiagram(frequencies, transfer, 1e9);
    context.expect(first.has_value(), "identity channel did not produce an eye diagram");
    context.expect(second.has_value(), "repeated identity channel calculation failed");
    if (!first.has_value() || !second.has_value()) {
        return;
    }

    context.expect(first->bitRate == 1e9, "eye diagram did not retain its bit rate");
    context.expect(first->timeUI.size() == 65, "eye diagram axis did not span 65 two-UI samples");
    context.expectNear(first->timeUI.front(), -0.5, 1e-12, "eye diagram axis started at the wrong UI");
    context.expectNear(first->timeUI.back(), 1.5, 1e-12, "eye diagram axis ended at the wrong UI");
    context.expect(!first->traces.empty(), "identity channel produced no eye traces");
    context.expect(first->traces == second->traces, "eye diagram output was not deterministic");
    for (const auto& trace : first->traces) {
        context.expect(trace.size() == first->timeUI.size(), "eye trace length did not match the shared axis");
        context.expect(std::all_of(trace.begin(), trace.end(), [](double value) { return std::isfinite(value); }),
                       "eye trace contained a non-finite value");
    }
}

} // namespace

int main() {
    const std::vector<Test> tests = {
        {"component value parsing", testComponentValueParsing},
        {"net name normalization", testNetNameNormalization},
        {"argument defaults and mutation", testArgumentDefaultsAndMutation},
        {"waveform synthesis", testWaveformSynthesis},
        {"eye diagram validation", testEyeDiagramValidation},
        {"eye diagram identity channel", testEyeDiagramIdentityChannel},
    };

    int failedTests = 0;
    for (const auto& [name, test] : tests) {
        TestContext context;
        test(context);
        if (context.failures() == 0) {
            std::cout << "[PASS] " << name << '\n';
        } else {
            ++failedTests;
            std::cerr << "[FAIL] " << name << " (" << context.failures() << " assertion(s))\n";
        }
    }

    std::cout << tests.size() - static_cast<std::size_t>(failedTests) << '/' << tests.size() << " tests passed\n";
    return failedTests == 0 ? EXIT_SUCCESS : EXIT_FAILURE;
}

