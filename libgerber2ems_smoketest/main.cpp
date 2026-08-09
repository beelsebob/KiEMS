// Minimal compile/link/behavior smoke test for libgerber2ems, mirroring libkicad_smoketest's
// role: a small executable that links the library from outside its own target, so signature
// churn in later refactor phases fails here at compile time rather than only being caught by a
// full CLI re-run. Not a test framework -- plain asserts, pass/fail printed to stdout.

#include <cstdlib>
#include <iostream>

#include "gerber2ems/config.hpp"
#include "gerber2ems/constants.hpp"
#include "gerber2ems/logging.hpp"

using namespace gerber2ems;

namespace {

bool checkConstants() {
    const std::string dir = constants::simGeometryDir("smoketest_sim").string();
    if (dir.find("smoketest_sim") == std::string::npos) {
        std::cerr << "FAIL: constants::simGeometryDir did not include the simulation name\n";
        return false;
    }
    return true;
}

bool checkConfigDefaults() {
    const Config& cfg = Config::sharedConfig();
    if (!cfg.simulations().empty()) {
        std::cerr << "FAIL: default Config::sharedConfig() should have no simulations configured\n";
        return false;
    }
    return true;
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
    ok &= checkConfigDefaults();
    ok &= checkLogging();

    if (ok) {
        std::cout << "libgerber2ems_smoketest: PASS\n";
        return EXIT_SUCCESS;
    }
    std::cout << "libgerber2ems_smoketest: FAIL\n";
    return EXIT_FAILURE;
}
