#import <XCTest/XCTest.h>

#include <algorithm>
#include <cmath>
#include <complex>
#include <limits>
#include <string>
#include <unordered_set>
#include <vector>

#include <nlohmann/json.hpp>

#include "kiems/component_value.hpp"
#include "kiems/config.hpp"
#include "kiems/eye_diagram.hpp"
#include "kiems/fft_postprocess.hpp"
#include "kiems/net_name.hpp"

@interface LibkiemsTests : XCTestCase
@end

@implementation LibkiemsTests

- (void)testComponentValueParsing {
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
        XCTAssertTrue(result.has_value(), @"Rejected valid component value: %s", testCase.input.c_str());
        if (result.has_value()) {
            const double tolerance = std::max(std::abs(testCase.expected) * 1e-12, 1e-15);
            XCTAssertEqualWithAccuracy(*result, testCase.expected, tolerance,
                                       @"Parsed the wrong component value for %s", testCase.input.c_str());
        }
    }

    const std::vector<std::string> invalidCases = {"", "   ", "LED", "4k7k", "R", "10kF", "1.2.3"};
    for (const std::string& input : invalidCases) {
        XCTAssertFalse(kiems::parseComponentValue(input, 'R').has_value(),
                       @"Accepted invalid resistor value: %s", input.c_str());
    }
}

- (void)testNetNameNormalization {
    const kiems::NetName escaped("/MCU{slash}USB{slash}D+");
    const kiems::NetName literal("/MCU/USB/D+");

    XCTAssertTrue(escaped.raw() == "/MCU{slash}USB{slash}D+");
    XCTAssertTrue(escaped.unescaped() == "/MCU/USB/D+");
    XCTAssertTrue(escaped == literal);
    XCTAssertEqual(kiems::NetNameHash{}(escaped), kiems::NetNameHash{}(literal));

    std::unordered_set<kiems::NetName, kiems::NetNameHash> names;
    names.insert(escaped);
    names.insert(literal);
    XCTAssertEqual(names.size(), static_cast<std::size_t>(1));

    const nlohmann::json json = escaped;
    XCTAssertTrue(json == escaped.raw());
    XCTAssertTrue(json.get<kiems::NetName>().raw() == escaped.raw());
}

- (void)testWaveformSynthesis {
    const auto tone = kiems::synthesizeToneBurst(1e9, 2.0, 0.0, 1e-9, 4e-9, 0.25e-9, 32);
    XCTAssertEqual(tone.samples.size(), static_cast<std::size_t>(32));
    XCTAssertEqualWithAccuracy(tone.dt, 0.25e-9, 1e-21);
    XCTAssertTrue(tone.samples[0] == 0.0 && tone.samples[1] == 0.0 && tone.samples[2] == 0.0);

    const auto silent = kiems::synthesizeToneBurst(1e9, 2.0, 0.0, 0.0, 0.0, 1e-9, 8);
    XCTAssertTrue(std::all_of(silent.samples.begin(), silent.samples.end(), [](double value) { return value == 0.0; }));

    const kiems::TimeWaveform first{0.5, {1.0, 2.0, 3.0}};
    const kiems::TimeWaveform second{0.5, {-0.5, 4.0, 1.0}};
    const auto sum = kiems::superpose({first, second});
    XCTAssertEqual(sum.dt, 0.5);
    XCTAssertTrue(sum.samples == std::vector<double>({0.5, 6.0, 4.0}));
    XCTAssertTrue(kiems::superpose({}).samples.empty());
}

- (void)testEyeDiagramValidation {
    const std::vector<double> frequencies = {0.0, 1e9, 2e9};
    const std::vector<std::complex<double>> transfer(frequencies.size(), {1.0, 0.0});
    XCTAssertFalse(kiems::computeEyeDiagram({}, {}, 1e9).has_value());
    XCTAssertFalse(kiems::computeEyeDiagram(frequencies, {{1.0, 0.0}}, 1e9).has_value());
    XCTAssertFalse(kiems::computeEyeDiagram(frequencies, transfer, 0.0).has_value());
    XCTAssertFalse(kiems::computeEyeDiagram(frequencies, transfer,
                                             std::numeric_limits<double>::infinity()).has_value());
}

- (void)testEyeDiagramIdentityChannel {
    constexpr std::size_t frequencyCount = 129;
    std::vector<double> frequencies(frequencyCount);
    std::vector<std::complex<double>> transfer(frequencyCount, {1.0, 0.0});
    for (std::size_t index = 0; index < frequencyCount; ++index) {
        frequencies[index] = static_cast<double>(index) * 4e9 / static_cast<double>(frequencyCount - 1);
    }

    const auto first = kiems::computeEyeDiagram(frequencies, transfer, 1e9);
    const auto second = kiems::computeEyeDiagram(frequencies, transfer, 1e9);
    XCTAssertTrue(first.has_value());
    XCTAssertTrue(second.has_value());
    if (!first.has_value() || !second.has_value()) {
        return;
    }

    XCTAssertEqual(first->bitRate, 1e9);
    XCTAssertEqual(first->timeUI.size(), static_cast<std::size_t>(65));
    XCTAssertEqualWithAccuracy(first->timeUI.front(), -0.5, 1e-12);
    XCTAssertEqualWithAccuracy(first->timeUI.back(), 1.5, 1e-12);
    XCTAssertFalse(first->traces.empty());
    XCTAssertTrue(first->traces == second->traces);
    for (const auto& trace : first->traces) {
        XCTAssertEqual(trace.size(), first->timeUI.size());
        XCTAssertTrue(std::all_of(trace.begin(), trace.end(), [](double value) { return std::isfinite(value); }));
    }
}

@end


