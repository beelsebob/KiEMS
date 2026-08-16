// Minimal compile/link/behavior smoke test for libgerber2ems, mirroring libkicad_smoketest's
// role: a small executable that links the library from outside its own target, so signature
// churn in later refactor phases fails here at compile time rather than only being caught by a
// full CLI re-run. Not a test framework -- plain asserts, pass/fail printed to stdout.

#include <cmath>
#include <complex>
#include <cstdlib>
#include <filesystem>
#include <iostream>
#include <vector>

#include "gerber2ems/config.hpp"
#include "gerber2ems/constants.hpp"
#include "gerber2ems/logging.hpp"
#include "gerber2ems/postprocess.hpp"

using namespace gerber2ems;

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
    sim.groundNet().setKind(GroundSelectorKind::Net);
    sim.groundNet().setNet("GND");

    InvolvedNetConfig net;
    net.setKind(NetSelectorKind::Net);
    net.setNet("USB_DP");
    net.setImpedance(45);
    net.setLength(1200);
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
    auto result = EMSConfig::parse("/nonexistent/libgerber2ems_smoketest/simulation.json", false);
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
            std::filesystem::temp_directory_path() / "libgerber2ems_smoketest_roundtrip.json";
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
    if (reparsed.simulations().front().involvedNets().size() != 1 ||
        reparsed.simulations().front().involvedNets().front().net() != std::optional<std::string>("USB_DP")) {
        std::cerr << "FAIL: involved_nets entry didn't round-trip\n";
        ok = false;
    }
    if (reparsed.simulations().front().excitations().size() != 1 ||
        !reparsed.simulations().front().excitations().front().isMain()) {
        std::cerr << "FAIL: excitation entry didn't round-trip\n";
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

// Exercises the raw numeric accessors Gerber2EMSStudio's results GUI drives directly (frequencies,
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
    pair.startP().setResolvedIndex(0);
    pair.startN().setResolvedIndex(1);
    pair.stopP().setResolvedIndex(2);
    pair.stopN().setResolvedIndex(3);
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

bool checkLogging() {
    // Purely checks that logging.hpp's free functions link and run without crashing.
    setLogLevel(LogLevel::Error);
    logInfo("this should be suppressed at Error level");
    logError("libgerber2ems_smoketest: logging path exercised");
    return true;
}

} // namespace

int main() {
    bool ok = true;
    ok &= checkConstants();
    ok &= checkConfigParseFailsCleanly();
    ok &= checkConfigMutateSaveRoundTrip();
    ok &= checkScaledToSimulationUnitsIsAPureCopy();
    ok &= checkPostprocessorRawAccessors();
    ok &= checkLogging();

    if (ok) {
        std::cout << "libgerber2ems_smoketest: PASS\n";
        return EXIT_SUCCESS;
    }
    std::cout << "libgerber2ems_smoketest: FAIL\n";
    return EXIT_FAILURE;
}
