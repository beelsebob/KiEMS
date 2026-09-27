// Minimal compile/link/behavior smoke test for libkiems, mirroring libkicad_smoketest's
// role: a small executable that links the library from outside its own target, so signature
// churn in later refactor phases fails here at compile time rather than only being caught by a
// full CLI re-run. Not a test framework -- plain asserts, pass/fail printed to stdout.

#include <algorithm>
#include <cmath>
#include <complex>
#include <cstdlib>
#include <filesystem>
#include <iostream>
#include <vector>

#include "kiems/component_value.hpp"
#include "kiems/config.hpp"
#include "kiems/constants.hpp"
#include "kiems/eye_diagram.hpp"
#include "logging.hpp"
#include "kiems/postprocess.hpp"

using namespace kiems;
using namespace Cu;

namespace {

// A minimal but from_json-round-trippable config: SimulationConfig::from_json requires a
// non-empty involved_nets and a ground_net, so both are set here.
EMSConfig makeSyntheticConfig() {
    EMSConfig config;
    config.setMaxSteps(12345);
    config.setPixelSize(7);
    config.via().setPlatingThickness(42);
    config.via().setFillingEpsilon(3.5);
    config.grid().setMax(600);

    SimulationConfig sim;
    sim.setName("smoketest_sim");
    sim.setHullPadding(2500);
    sim.setViaEdgeDistance(350);
    sim.setViaSpacing(550);
    sim.setEyeBitRate(5e9);
    sim.groundNet().setKind(GroundSelectorKind::Net);
    sim.groundNet().setNet("GND");

    InvolvedNetConfig net;
    net.setKind(NetSelectorKind::Net);
    net.setNet("USB_DP");
    net.setImpedance(45);
    net.setLength(1200);
    net.setProbeImpedance(true);
    net.setPinProbed("U8", "4", true);
    net.setPinProbed("U8", "5", false);
    sim.involvedNets().push_back(net);

    ExcitationConfig excitation;
    excitation.setFootprint("U8");
    excitation.setPin("4");
    excitation.setStartTime(1e-9);
    excitation.setDuration(5e-9);
    excitation.setIsMain(true);
    excitation.setPhaseDegrees(90);
    sim.excitations().push_back(excitation);

    config.simulations().push_back(std::move(sim));
    return config;
}

bool checkConstants() {
    const std::string dir = constants::simGeometryDir("smoketest_sim").string();
    if (dir.find("smoketest_sim") == std::string::npos) {
        std::cerr << "FAIL: constants::simGeometryDir did not include the simulation name\n";
        return false;
    }
    return true;
}

bool checkConfigParseFailsCleanly() {
    // EMSConfig::parse() against a path that can't exist should come back as a clean
    // std::expected failure, not a thrown exception or a crash -- exercises the library's
    // std::expected-based error boundary from outside its own target.
    auto result = EMSConfig::parse("/nonexistent/libkiems_smoketest/simulation.json", false);
    if (result.has_value()) {
        std::cerr << "FAIL: EMSConfig::parse() should have failed for a nonexistent path\n";
        return false;
    }
    if (result.error().empty()) {
        std::cerr << "FAIL: EMSConfig::parse() failure should carry a non-empty error message\n";
        return false;
    }
    return true;
}

bool checkConfigMutateSaveRoundTrip() {
    const EMSConfig original = makeSyntheticConfig();

    const std::filesystem::path tmpPath =
            std::filesystem::temp_directory_path() / "libkiems_smoketest_roundtrip.json";
    auto saveResult = original.save(tmpPath);
    if (!saveResult) {
        std::cerr << "FAIL: EMSConfig::save() failed: " << saveResult.error() << "\n";
        return false;
    }

    auto reparsedResult = EMSConfig::parse(tmpPath, false);
    std::filesystem::remove(tmpPath);
    if (!reparsedResult) {
        std::cerr << "FAIL: re-parse() of a saved config failed: " << reparsedResult.error() << "\n";
        return false;
    }
    const EMSConfig& reparsed = *reparsedResult;

    bool ok = true;
    if (reparsed.maxSteps() != 12345) {
        std::cerr << "FAIL: maxSteps() didn't round-trip (got " << reparsed.maxSteps() << ")\n";
        ok = false;
    }
    if (reparsed.via().platingThickness() != 42) {
        std::cerr << "FAIL: via().platingThickness() didn't round-trip, or was scaled (got "
                   << reparsed.via().platingThickness() << ")\n";
        ok = false;
    }
    if (reparsed.simulations().size() != 1 || reparsed.simulations().front().hullPadding() != 2500) {
        std::cerr << "FAIL: hullPadding() didn't round-trip, or was scaled\n";
        ok = false;
    }
    if (reparsed.simulations().empty() || reparsed.simulations().front().eyeBitRate() != 5e9) {
        std::cerr << "FAIL: eyeBitRate() didn't round-trip\n";
        ok = false;
    }
    if (reparsed.simulations().front().involvedNets().size() != 1 ||
        reparsed.simulations().front().involvedNets().front().net() != std::optional<std::string>("USB_DP")) {
        std::cerr << "FAIL: involved_nets entry didn't round-trip\n";
        ok = false;
    }
    {
        const InvolvedNetConfig& net = reparsed.simulations().front().involvedNets().front();
        if (!net.hasExplicitPinSelections()) {
            std::cerr << "FAIL: hasExplicitPinSelections() didn't round-trip as true\n";
            ok = false;
        }
        if (!net.probeImpedance()) {
            std::cerr << "FAIL: probeImpedance() didn't round-trip as true\n";
            ok = false;
        }
        if (net.probedPinAbsorbs("U8", "4") != std::optional<bool>(true)) {
            std::cerr << "FAIL: probedPinAbsorbs(\"U8\",\"4\") didn't round-trip as probed+absorbing\n";
            ok = false;
        }
        if (net.probedPinAbsorbs("U8", "5") != std::optional<bool>(false)) {
            std::cerr << "FAIL: probedPinAbsorbs(\"U8\",\"5\") didn't round-trip as probed, non-absorbing\n";
            ok = false;
        }
        if (net.probedPinAbsorbs("U8", "99").has_value()) {
            std::cerr << "FAIL: probedPinAbsorbs() should be nullopt for a pin never probed\n";
            ok = false;
        }
    }
    if (reparsed.simulations().front().excitations().size() != 1 ||
        !reparsed.simulations().front().excitations().front().isMain()) {
        std::cerr << "FAIL: excitation entry didn't round-trip\n";
        ok = false;
    }
    return ok;
}

// Exercises InvolvedNetConfig's own legacy-vs-explicit pin-selection resolution mode boundary (see
// its own doc comment) in isolation -- port_resolution.cpp's actual pad loop needs a real KiCad
// board to exercise end-to-end, out of reach for this
// smoketest, but the mode-switch behavior itself is plain C++ object state this can verify directly.
bool checkInvolvedNetPinSelectionResolutionMode() {
    bool ok = true;
    InvolvedNetConfig net;
    net.setKind(NetSelectorKind::Net);
    net.setNet("TEST_NET");

    // Fresh entry: legacy mode, nothing excluded -- every pad would resolve as probed+absorbing.
    if (net.hasExplicitPinSelections()) {
        std::cerr << "FAIL: a freshly-constructed InvolvedNetConfig should start in legacy mode\n";
        ok = false;
    }
    if (net.probedPinAbsorbs("U1", "1").has_value()) {
        std::cerr << "FAIL: probedPinAbsorbs() should be nullopt while in legacy mode (excludedPins() governs "
                      "instead)\n";
        ok = false;
    }
    net.excludedPins().push_back(ExcludedPin{"U1", "2"});
    if (!net.isPinExcluded("U1", "2") || net.isPinExcluded("U1", "1")) {
        std::cerr << "FAIL: legacy-mode excludedPins() behavior regressed\n";
        ok = false;
    }

    // First explicit edit flips the net permanently into strict opt-in mode.
    net.setPinProbed("U1", "1", true);
    if (!net.hasExplicitPinSelections()) {
        std::cerr << "FAIL: setPinProbed() should set hasExplicitPinSelections() true\n";
        ok = false;
    }
    if (net.probedPinAbsorbs("U1", "1") != std::optional<bool>(true)) {
        std::cerr << "FAIL: probedPinAbsorbs(\"U1\",\"1\") should be true after setPinProbed(..., true)\n";
        ok = false;
    }
    // A pin never explicitly probed no longer falls back to "probed by default" once in explicit
    // mode, even though it isn't in excludedPins() either -- that's the whole point of the mode
    // switch (see InvolvedNetConfig's own doc comment).
    if (net.probedPinAbsorbs("U1", "3").has_value()) {
        std::cerr << "FAIL: an untouched pin should not be probed once hasExplicitPinSelections() is true\n";
        ok = false;
    }

    // Un-probing (nullopt) still counts as an explicit edit, and clears just that one pin.
    net.setPinProbed("U1", "1", std::nullopt);
    if (!net.hasExplicitPinSelections()) {
        std::cerr << "FAIL: hasExplicitPinSelections() should never revert to false\n";
        ok = false;
    }
    if (net.probedPinAbsorbs("U1", "1").has_value()) {
        std::cerr << "FAIL: probedPinAbsorbs(\"U1\",\"1\") should be nullopt after un-probing it\n";
        ok = false;
    }
    return ok;
}

bool checkScaledToSimulationUnitsIsAPureCopy() {
    const EMSConfig original = makeSyntheticConfig();
    EMSConfig scaled = original.scaledToSimulationUnits();

    bool ok = true;
    // Unscaled: parse()/scaledToSimulationUnits() must not have mutated the original.
    if (original.simulations().front().hullPadding() != 2500) {
        std::cerr << "FAIL: scaledToSimulationUnits() mutated the original EMSConfig\n";
        ok = false;
    }
    // Scaled: the returned copy's spatial fields are multiplied by unitMultiplier.
    const double expectedHullPadding = 2500.0 * constants::unitMultiplier;
    if (scaled.simulations().front().hullPadding() != expectedHullPadding) {
        std::cerr << "FAIL: scaledToSimulationUnits() didn't scale hullPadding() (expected "
                   << expectedHullPadding << ", got " << scaled.simulations().front().hullPadding() << ")\n";
        ok = false;
    }
    const double expectedMax = 600.0 * constants::unitMultiplier;
    if (scaled.grid().max() != expectedMax) {
        std::cerr << "FAIL: scaledToSimulationUnits() didn't scale grid().max()\n";
        ok = false;
    }
    // fillingEpsilon is dimensionless (a ratio) -- must never be scaled.
    if (scaled.via().fillingEpsilon() != 3.5) {
        std::cerr << "FAIL: scaledToSimulationUnits() incorrectly scaled a dimensionless field "
                      "(via().fillingEpsilon())\n";
        ok = false;
    }

    // A resolved port's width/length scale the same way, via SimulationConfig::scaleToSimulationUnits().
    PortConfig port;
    port.setWidth(200);
    port.setLength(1000);
    scaled.simulations().front().ports().push_back(port);
    EMSConfig scaledAgain = scaled.scaledToSimulationUnits();
    const double expectedWidth = 200.0 * constants::unitMultiplier;
    if (scaledAgain.simulations().front().ports().front().width() != expectedWidth) {
        std::cerr << "FAIL: scaledToSimulationUnits() didn't scale a resolved port's width()\n";
        ok = false;
    }
    return ok;
}

// Exercises the raw numeric accessors KiEMS's results GUI drives directly (frequencies,
// getDelay, getDiffPairSdd, getDiffPairImpedance) -- there's no existing Postprocessor coverage
// here at all otherwise. Builds S-parameters by hand via setSParam() (the same "already have the
// data" path SimulationResult itself uses, see postprocess_result.cpp), rather than a real FDTD
// run, so this stays a fast, deterministic unit test.
bool checkPostprocessorRawAccessors() {
    SimulationConfig sim;
    sim.setName("smoketest_sim");
    for (int i = 0; i < 4; ++i) {
        PortConfig port;
        port.setName("P" + std::to_string(i));
        port.setImpedance(50);
        port.setExcite(true);
        sim.ports().push_back(port);
    }

    // A differential pair over ports 0/1 (P) and 2/3 (N) -- resolvedIndex is normally set by
    // port_resolution.cpp, but DifferentialPairConfig::correct() defaults to true and postInit()
    // is only needed to *detect* unresolved refs, so setting the indices directly is enough here.
    DifferentialPairConfig pair;
    pair.positiveExcitation().setResolvedIndex(0);
    pair.negativeExcitation().setResolvedIndex(1);
    pair.positiveProbe().setResolvedIndex(2);
    pair.negativeProbe().setResolvedIndex(3);
    sim.diffPairs().push_back(pair);

    const std::vector<double> freqs = {1e9, 2e9, 3e9};
    Postprocessor post(freqs, sim);

    for (int out = 0; out < 4; ++out) {
        for (int in = 0; in < 4; ++in) {
            std::vector<std::complex<double>> s(freqs.size());
            for (std::size_t f = 0; f < freqs.size(); ++f) {
                s[f] = (out == in) ? std::complex<double>(0.1 + 0.01 * static_cast<double>(f), 0.02 * static_cast<double>(f))
                                    : std::complex<double>(0.01 * (out + 1), -0.01 * (in + 1));
            }
            post.setSParam(out, in, s);
        }
    }
    post.processData();

    bool ok = true;
    if (post.frequencies() != freqs) {
        std::cerr << "FAIL: Postprocessor::frequencies() didn't return what was passed in\n";
        ok = false;
    }

    const auto delay = post.getDelay(0, 0);
    if (!delay.has_value() || delay->size() != freqs.size()) {
        std::cerr << "FAIL: Postprocessor::getDelay() didn't return a value for a computed S-parameter\n";
        ok = false;
    }
    if (post.getDelay(0, 99).has_value()) {
        std::cerr << "FAIL: Postprocessor::getDelay() should return nullopt for an out-of-range port\n";
        ok = false;
    }

    // Empty data means an absent/disabled probe, not a valid curve. If accepted, the app creates a
    // fixed-height chart section for it but has no samples to draw, leaving unexplained whitespace.
    post.addProbeData(0, 0, {}, {});
    if (post.getProbeVoltage(0, 0).has_value() || post.getProbeCurrent(0, 0).has_value()) {
        std::cerr << "FAIL: Postprocessor accepted an empty probe result as a valid curve\n";
        ok = false;
    }

    const auto sdd = post.getDiffPairSdd(0);
    if (!sdd.has_value() || !sdd->sdd11Db.has_value() || !sdd->sdd21Db.has_value() ||
        sdd->sdd11Db->size() != freqs.size() || sdd->sdd21Db->size() != freqs.size()) {
        std::cerr << "FAIL: Postprocessor::getDiffPairSdd() didn't return complete data for a fully-populated pair\n";
        ok = false;
    }
    if (post.getDiffPairSdd(1).has_value()) {
        std::cerr << "FAIL: Postprocessor::getDiffPairSdd() should return nullopt for an out-of-range pair index\n";
        ok = false;
    }
    // Cross-check SDD11's first frequency point against the same mixed-mode formula
    // renderDiffPairSParams uses, computed here from the raw S-parameters independently.
    if (sdd.has_value() && sdd->sdd11Db.has_value()) {
        const std::complex<double> spsp = post.getSParam(0, 0)->front();
        const std::complex<double> snsp = post.getSParam(1, 0)->front();
        const std::complex<double> spsn = post.getSParam(0, 1)->front();
        const std::complex<double> snsn = post.getSParam(1, 1)->front();
        const std::complex<double> expectedGamma = 0.5 * (spsp - snsp - spsn + snsn);
        const double expectedDb = 20 * std::log10(std::abs(expectedGamma));
        if (std::abs(sdd->sdd11Db->front() - expectedDb) > 1e-9) {
            std::cerr << "FAIL: Postprocessor::getDiffPairSdd()'s SDD11 didn't match the mixed-mode formula "
                          "(expected "
                       << expectedDb << ", got " << sdd->sdd11Db->front() << ")\n";
            ok = false;
        }
    }

    const auto diffZ = post.getDiffPairImpedance(0);
    if (!diffZ.has_value() || diffZ->magnitudeOhm.size() != freqs.size() || diffZ->angleDeg.size() != freqs.size()) {
        std::cerr << "FAIL: Postprocessor::getDiffPairImpedance() didn't return complete data\n";
        ok = false;
    } else if (std::isnan(diffZ->magnitudeOhm.front()) || std::isnan(diffZ->angleDeg.front())) {
        std::cerr << "FAIL: Postprocessor::getDiffPairImpedance() returned NaN for a fully-populated pair\n";
        ok = false;
    }

    return ok;
}

// KiCad Value-field parsing for auto-discovered lumped R/L/C components -- covers plain SI-suffix
// values, KiCad's decimal-substitution shorthand ("4k7"), the bare-ohms marker ("0R1"/"1M2"), the
// alternate micro-sign spelling, and a couple of strings that should be rejected rather than guessed.
bool checkParseComponentValue() {
    struct Case {
        std::string raw;
        ComponentUnit unit;
        std::optional<double> expected;
    };
    const std::vector<Case> cases = {
        {"10k", ComponentUnit::Resistance, 10000.0},
        {"4k7", ComponentUnit::Resistance, 4700.0},
        {"100nF", ComponentUnit::Capacitance, 1e-7},
        {"4u7", ComponentUnit::Capacitance, 4.7e-6},
        {"0R1", ComponentUnit::Resistance, 0.1},
        {"1M2", ComponentUnit::Resistance, 1.2e6},
        {"4.7uF", ComponentUnit::Capacitance, 4.7e-6},
        {"4.7\xC2\xB5H", ComponentUnit::Inductance, 4.7e-6}, // 'µ' UTF-8 spelling
        {"1M", ComponentUnit::Resistance, 1e6},
        {"", ComponentUnit::Resistance, std::nullopt},
        {"LED", ComponentUnit::Resistance, std::nullopt},
        {"4k7k", ComponentUnit::Resistance, std::nullopt}, // two markers -- ambiguous
    };
    bool ok = true;
    for (const Case& c : cases) {
        const std::optional<double> got = parseComponentValue(c.raw, c.unit);
        if (got.has_value() != c.expected.has_value()) {
            std::cerr << "FAIL: parseComponentValue(\"" << c.raw << "\") returned "
                       << (got.has_value() ? "a value" : "nullopt") << ", expected "
                       << (c.expected.has_value() ? "a value" : "nullopt") << "\n";
            ok = false;
            continue;
        }
        if (got.has_value() && std::abs(*got - *c.expected) > std::abs(*c.expected) * 1e-9 + 1e-15) {
            std::cerr << "FAIL: parseComponentValue(\"" << c.raw << "\") = " << *got << ", expected " << *c.expected
                       << "\n";
            ok = false;
        }
    }
    return ok;
}

bool checkEyeDiagram() {
    std::vector<double> frequencies(129);
    std::vector<std::complex<double>> transfer(frequencies.size(), {1.0, 0.0});
    for (std::size_t i = 0; i < frequencies.size(); ++i) {
        frequencies[i] = static_cast<double>(i) * 4e9 / static_cast<double>(frequencies.size() - 1);
    }
    const auto eye = computeEyeDiagram(frequencies, transfer, 1e9);
    if (!eye.has_value() || eye->timeUI.size() != 65 || eye->traces.empty()) {
        std::cerr << "FAIL: computeEyeDiagram() didn't produce a two-UI identity-channel eye\n";
        return false;
    }
    for (const auto& trace : eye->traces) {
        if (trace.size() != eye->timeUI.size() ||
            !std::all_of(trace.begin(), trace.end(), [](double value) { return std::isfinite(value); })) {
            std::cerr << "FAIL: computeEyeDiagram() produced a malformed/non-finite trace\n";
            return false;
        }
    }
    if (computeEyeDiagram(frequencies, transfer, 0).has_value()) {
        std::cerr << "FAIL: computeEyeDiagram() accepted a zero bit rate\n";
        return false;
    }
    return true;
}

bool checkLogging() {
    // Checks that the stream-building temporary accepts heterogeneous values and logs once when
    // its destructor runs at the end of the full expression.
    setLogLevel(LogLevel::Error);
    logInfo() << "this should be suppressed at Error level";
    const int actual = 5;
    const int expected = 23;
    logError() << "libkiems_smoketest: x was " << actual << " when it should have been " << expected;
    CU_ASSERT(actual == 5) << "x was " << actual << " when it should have been 5";
    return true;
}

} // namespace

int main() {
    bool ok = true;
    ok &= checkConstants();
    ok &= checkConfigParseFailsCleanly();
    ok &= checkConfigMutateSaveRoundTrip();
    ok &= checkInvolvedNetPinSelectionResolutionMode();
    ok &= checkScaledToSimulationUnitsIsAPureCopy();
    ok &= checkPostprocessorRawAccessors();
    ok &= checkParseComponentValue();
    ok &= checkEyeDiagram();
    ok &= checkLogging();

    if (ok) {
        std::cout << "libkiems_smoketest: PASS\n";
        return EXIT_SUCCESS;
    }
    std::cout << "libkiems_smoketest: FAIL\n";
    return EXIT_FAILURE;
}
