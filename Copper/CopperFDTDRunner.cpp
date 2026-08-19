#include "CopperFDTDRunner.h"

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <limits>
#include <sstream>
#include <string>
#include <vector>

#include "Internal/CopperCPML.hpp"
#include "Internal/CopperEngine.hpp"
#include "Internal/CopperExcitation.hpp"
#include "Internal/CopperOpenEMSAccess.hpp"
#include "Internal/CopperPML.hpp"
#include "Internal/CopperProbes.hpp"
#include "Internal/CopperYeeGrid.hpp"
#include "tools/constants.h"

namespace copper {

namespace {

// openEMS's own CPU RunFDTD() prints live "grab a cup of coffee" timestep/speed progress to
// stdout throughout the run -- runFDTDPortOnGPU had none of that until this instrumentation, which
// made a genuinely slow phase indistinguishable from a hung one (this is what prompted adding it:
// a real run against a large board looked stuck with zero visibility into which phase it was even
// in). Written to stdout (matching openems.cpp's own `cout <<`, not stderr) at the same cadence
// openEMS's own reporter uses -- `t_diff>4` (openems.cpp's RunFDTD loop): print at most once every
// 4 seconds of wall time, not every N steps, so the two backends' progress output reads at a
// comparable rate regardless of how many steps/second either one is actually managing. Kept
// intentionally lightweight (plain fprintf) rather than piped through gerber2ems's own logging.hpp,
// since Copper.framework doesn't link libgerber2ems (see the Copper implementation plan's "no
// dependency on Copper" rule, which cuts both ways).
class PhaseTimer {
public:
    void mark(const char* phase) {
        const auto now = std::chrono::steady_clock::now();
        const double elapsed = std::chrono::duration<double>(now - _last).count();
        std::fprintf(stdout, "Copper: %s took %.2fs\n", phase, elapsed);
        _last = now;
    }

private:
    std::chrono::steady_clock::time_point _last = std::chrono::steady_clock::now();
};

} // namespace

CopperFDTDRunResult runFDTDPortOnGPU(openEMS& fdtd, ContinuousStructure& csx,
                                      const CopperFDTDProgressCallback& onProgress,
                                      CopperBoundaryKind boundaryKind, double cpmlAlphaMax) {
    CopperFDTDRunResult result;
    // See CopperFDTDRunner.h's own doc comment on cpmlAlphaMax's default -- 100MHz is every real
    // board this codebase has actually simulated so far, not an arbitrary round number.
    constexpr double kDefaultCpmlLowFrequencyHz = 100e6;
    if (cpmlAlphaMax < 0.0) {
        cpmlAlphaMax = 2 * M_PI * kDefaultCpmlLowFrequencyHz * EPS0;
    }
    PhaseTimer timer;
    try {
        if (onProgress) {
            onProgress(CopperFDTDProgress{CopperFDTDPhase::Setup, 0, 1, 0.0, 0.0, 0.0});
        }

        // Downcast of an object never actually constructed as CopperOpenEMS -- `fdtd` came from
        // gerber2ems::Simulation, which knows nothing about Copper (see
        // CopperOpenEMSAccess.hpp's own file comment for why this specific downcast is accepted:
        // identical layout, no new data members, no vtable change).
        auto& copperFdtd = static_cast<CopperOpenEMS&>(fdtd);
        Operator* op = copperFdtd.GetOperatorForGPU();
        if (op == nullptr) {
            result.errorMessage = "Copper: GetOperatorForGPU() returned null -- was SetupFDTD() run first?";
            return result;
        }

        // CPML never touches `grid` at all (see CopperCPML.hpp's own top comment for why: unlike
        // UPML, it's a pure additive correction on top of the host medium's own, unmodified
        // coefficients) -- grid stays a plain, single, const build for both boundary kinds.
        const CopperYeeGrid grid = buildYeeGrid(*op);
        if (!onProgress) {
            timer.mark("buildYeeGrid (reading Operator's already-computed vv/vi/ii/iv coefficients)");
        }

        std::vector<CopperPMLShell> upmlShells;
        std::vector<CopperCPMLShell> cpmlShells;
        std::uint64_t pmlCellTotal = 0;
        std::size_t shellCount = 0;
        if (boundaryKind == CopperBoundaryKind::CPML) {
            cpmlShells = buildCPMLShells(*op, cpmlAlphaMax);
            shellCount = cpmlShells.size();
            for (const CopperCPMLShell& shell : cpmlShells) {
                pmlCellTotal += shell.dims.cellCount();
            }
        } else {
            upmlShells = buildPMLShells(*op);
            shellCount = upmlShells.size();
            for (const CopperPMLShell& shell : upmlShells) {
                pmlCellTotal += shell.dims.cellCount();
            }
        }
        if (!onProgress) {
            timer.mark("buildPMLShells");
            std::fprintf(stdout, "Copper: %zu PML shell(s), %llu cell(s) total\n", shellCount,
                         static_cast<unsigned long long>(pmlCellTotal));
        }
        const CopperExcitation excitation = buildExcitation(*op);
        if (!onProgress) {
            timer.mark("buildExcitation");
        }
        CopperEngine engine(grid, upmlShells, excitation, cpmlShells);
        if (!onProgress) {
            timer.mark("CopperEngine construction (GPU buffer upload)");
        }

        const std::vector<CopperProbe> probes = discoverProbes(csx, *op);
        const std::uint32_t steps = copperFdtd.GetNumberOfTimestepsForGPU();

        // Accumulated in memory, not streamed to disk -- see CopperFDTDRunResult's own doc comment.
        // One entry per probe, sized/reserved up front so the per-timestep loop below never
        // reallocates.
        result.probes.resize(probes.size());
        for (std::size_t i = 0; i < probes.size(); ++i) {
            result.probes[i].name = probes[i].name;
            result.probes[i].kind =
                probes[i].type == CopperProbeType::Voltage ? CopperProbeKind::Voltage : CopperProbeKind::Current;
            result.probes[i].samples.reserve(steps);
        }
        if (!onProgress) {
            timer.mark("discoverProbes");
        }

        if (onProgress) {
            onProgress(CopperFDTDProgress{CopperFDTDPhase::Setup, 1, 1, 0.0, 0.0, 0.0});
        } else {
            std::fprintf(stdout, "Copper: running %u timesteps on %zu cell(s), %zu probe(s)...\n", steps,
                         static_cast<std::size_t>(grid.dims.cellCount()), probes.size());
        }
        const auto runStart = std::chrono::steady_clock::now();
        auto lastPrint = runStart;
        std::uint32_t lastPrintStep = 0;
        // Per-cell accessors, not full-array reads -- a probe box only ever touches a handful of
        // cells, so reading it via CopperEngine::readFieldCell (O(1), no allocation) rather than
        // readField() (a full cellCount()-length copy) is the difference between this loop costing
        // a few dozen memory reads per timestep and multiple hundred-megabyte copies per timestep.
        // Confirmed in practice: the latter was the dominant cost of a real multi-million-cell board
        // run before this existed.
        auto eField = [&](std::uint32_t axis, std::uint32_t x, std::uint32_t y, std::uint32_t z) {
            return engine.readFieldCell(static_cast<CopperEngine::Field>(static_cast<int>(axis)), x, y, z);
        };
        auto hField = [&](std::uint32_t axis, std::uint32_t x, std::uint32_t y, std::uint32_t z) {
            return engine.readFieldCell(static_cast<CopperEngine::Field>(static_cast<int>(axis) + 3), x, y, z);
        };

        // Energy-decay end criteria, matching openEMS's own RunFDTD() loop (openems.cpp) exactly:
        // `endCrit = 1e-6` is openEMS's own default (-60dB, `endCrit = pow(10, -dB/10)`; openEMS
        // itself hardcodes this same default, see openems.cpp's own `endCrit = 1e-6` -- not
        // currently exposed as a config option on either backend, so hardcoding it here matches
        // reality rather than pretending it's configurable). `maxEnergy` tracks the highest energy
        // ever observed (effectively the excitation pulse's own peak, once it's fully entered the
        // domain); `energyChange = currentEnergy/maxEnergy` is compared against `endCriteria` at the
        // same >4s cadence as the progress print below (openEMS's own RunFDTD() computes both in the
        // same `t_diff>4` block) -- CalcFastEnergy()/estimateEnergy() is cheap enough (a couple of
        // vDSP sum-of-squares calls) that computing it more often would just be wasted work, not
        // more useful information.
        constexpr double endCriteria = 1e-6;
        double maxEnergy = 0.0;
        double energyChange = 1.0; // matches RunFDTD()'s own `double change=1;` initial value
        bool endCriteriaReached = false;
        std::uint32_t stepsActuallyRun = 0;

        engine.runWithProbeSampling(steps, [&](std::uint32_t globalTimestep) -> bool {
            stepsActuallyRun = globalTimestep;

            for (std::size_t i = 0; i < probes.size(); ++i) {
                const CopperProbe& probe = probes[i];
                // Voltage probes sample at t=numTS*dT; current probes at t=(numTS+0.5)*dT -- see
                // Engine_Interface_Base::GetTime(dualTime) and openems.cpp's own SetDualTime(true)
                // for ProbeType==1, which this mirrors (see CopperProbes.hpp's own doc comments).
                // Weight applied here (matching ProcessIntegral::Process's own
                // `m_Results[n] * m_weight`) so every stored sample is already final -- see
                // CopperProbeResult's own doc comment.
                if (probe.type == CopperProbeType::Voltage) {
                    const double t = static_cast<double>(globalTimestep) * grid.timestepSeconds;
                    result.probes[i].samples.push_back({t, sampleVoltageProbe(probe, eField) * probe.weight});
                } else {
                    const double t = (static_cast<double>(globalTimestep) + 0.5) * grid.timestepSeconds;
                    result.probes[i].samples.push_back({t, sampleCurrentProbe(probe, hField) * probe.weight});
                }
            }

            const auto now = std::chrono::steady_clock::now();
            const double sinceLastPrint = std::chrono::duration<double>(now - lastPrint).count();
            if (sinceLastPrint > 4.0 || globalTimestep == steps) {
                const double elapsed = std::chrono::duration<double>(now - runStart).count();
                const double stepRate = sinceLastPrint / static_cast<double>(globalTimestep - lastPrintStep);

                const double currentEnergy = engine.estimateEnergy();
                if (currentEnergy > maxEnergy) {
                    maxEnergy = currentEnergy;
                }
                if (maxEnergy > 0.0) {
                    energyChange = currentEnergy / maxEnergy;
                }
                const double energyChangeDB = std::fabs(10.0 * std::log10(energyChange));
                const double targetDB = std::fabs(10.0 * std::log10(endCriteria));

                if (onProgress) {
                    const bool duringExcitation = globalTimestep < excitation.voltageSignal.size();
                    onProgress(CopperFDTDProgress{CopperFDTDPhase::FDTDRun, globalTimestep, steps, energyChangeDB,
                                                   targetDB, currentEnergy, duringExcitation});
                } else {
                    std::fprintf(
                        stdout, "Copper: [@ %7.1fs] timestep %u/%u || Speed: %.4f s/step || Energy: ~%.2e (-%.2fdB)\n",
                        elapsed, globalTimestep, steps, stepRate, currentEnergy, energyChangeDB);
                }
                lastPrint = now;
                lastPrintStep = globalTimestep;

                if (energyChange <= endCriteria) {
                    endCriteriaReached = true;
                }
            }
            return !endCriteriaReached;
        });
        if (!onProgress) {
            timer.mark("FDTD run (all timesteps + per-timestep probe sampling)");
            if (endCriteriaReached) {
                std::fprintf(stdout, "Copper: end criteria of -%.2fdB reached after %u timesteps, stopping early\n",
                             std::fabs(10.0 * std::log10(endCriteria)), stepsActuallyRun);
            } else {
                std::fprintf(stdout,
                              "Copper: RunFDTD: Warning: Max. number of timesteps was reached before the "
                              "end-criteria of -%.2fdB was reached...\n",
                              std::fabs(10.0 * std::log10(endCriteria)));
            }
        }

        result.success = true;
    } catch (const std::exception& error) {
        result.errorMessage = std::string("Copper GPU FDTD run failed: ") + error.what();
    }
    return result;
}

std::string CopperProbeResult::data() const {
    std::ostringstream out;
    const char* kindName = kind == CopperProbeKind::Voltage ? "voltage" : "current";
    out << "% time-domain " << kindName << " probe, written by Copper\n";
    out << "% t/s\t" << kindName << "\n";
    out.precision(12);
    for (const CopperProbeSample& sample : samples) {
        out << sample.timeSeconds << "\t" << sample.value << "\n";
    }
    return out.str();
}

} // namespace copper
