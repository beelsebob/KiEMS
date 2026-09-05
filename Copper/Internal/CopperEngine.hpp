// Drives the Metal FDTD leapfrog loop.
#pragma once

#include <cstdint>
#include <functional>
#include <memory>
#include <vector>

#include "CopperCPML.hpp"
#include "CopperExcitation.hpp"
#include "CopperPML.hpp"
#include "CopperYeeGrid.hpp"

namespace copper {

/// Interior E/H update kernels, plus an optional set of PML boundary shells -- either `pmlShells`
/// (classic UPML, Phase 3 -- see CopperPML.hpp) or `cpmlShells` (real CFS-PML -- see CopperCPML.hpp),
/// mutually exclusive in practice (a run picks one CopperBoundaryKind), though nothing stops a
/// caller passing both -- plus optional excitation injection (Phase 4 -- see CopperExcitation.hpp).
/// A PEC-only run (neither shell list) needs no extra state or update pass. An unexcited run (no
/// `excitation` cells) never dispatches the excitation kernels at all -- the fields just stay at
/// their seeded/zero initial condition, which is what Phase 2/3's own verification fixtures rely on.
///
/// Pure-C++ public interface (pimpl) so plain C++ callers (e.g. Copper_smoketest) don't need to
/// become Objective-C++ themselves just to use this -- CopperEngine.mm's implementation is where
/// all the actual Metal/Objective-C API usage lives.
class CopperEngine {
public:
    /// Uploads `grid`'s coefficients (and each `pmlShells`/`cpmlShells`/`excitation` entry's, if any)
    /// to the GPU and zero-initializes every E/H field and auxiliary PML state buffer (matching
    /// FDTD's own E=H=0 initial condition). Throws std::runtime_error if no Metal device is available
    /// or the shader library fails to load/compile.
    explicit CopperEngine(const CopperYeeGrid& grid, const std::vector<CopperPMLShell>& pmlShells = {},
                          const CopperExcitation& excitation = {},
                          const std::vector<CopperCPMLShell>& cpmlShells = {});
    ~CopperEngine();

    CopperEngine(const CopperEngine&) = delete;
    CopperEngine& operator=(const CopperEngine&) = delete;

    /// Runs `steps` full E-then-H leapfrog iterations (interior + PML + excitation, memory-barriered
    /// between every dispatch so each read sees the immediately-preceding write -- Metal doesn't
    /// guarantee that ordering across dispatches within one encoder on its own), matching openEMS's
    /// own Engine::IterateTS stage ordering. All `steps` iterations are batched into one command
    /// buffer; blocks until the GPU work completes. No probe access between iterations -- use
    /// runWithProbeSampling() if the caller needs to read fields mid-run.
    void run(std::uint32_t steps);

    /// Invoked once per iteration, after that iteration's H-update (and any PML/excitation on top of
    /// it) has fully landed and is CPU-visible -- `globalTimestep` is the value openEMS's own probe
    /// files would label that row with (i.e. *after* increment, matching Engine::numTS at the point
    /// ProcessFields::Process() samples it in the real CPU RunFDTD() loop). The callback typically
    /// calls readField()/readFieldCell() itself to sample probe cells; CopperEngine doesn't know
    /// anything about probe geometry. Return `false` to stop the run before `steps` iterations
    /// complete (e.g. an energy-decay end criteria matching openEMS's own -- see
    /// CopperFDTDRunner.cpp's use of estimateEnergy() below); `true` to continue.
    using ProbeSampler = std::function<bool(std::uint32_t globalTimestep)>;

    /// Invoked once per iteration, between that iteration's voltage (E) update and its current (H)
    /// update -- i.e. after apply_excitation_e has landed and is CPU-visible, before pml_pre_h/
    /// update_h_interior have even been encoded. Mirrors exactly where openEMS's own Engine::IterateTS
    /// calls Apply2Voltages() (engine.cpp): after UpdateVoltages()/DoPostVoltageUpdates(), before
    /// DoPreCurrentUpdates()/UpdateCurrents(). A lumped-element lumped-RLC correction (or any other
    /// per-timestep voltage-domain extension) *must* land here, not after the current update -- the
    /// current update is the only place voltage differences actually get converted into transported
    /// current, so a correction applied afterward only ever affects the next iteration's own seed
    /// voltage and probe readout, never the current that already crossed whatever gap the correction
    /// was modeling (see CopperLumpedRLC.hpp's own top comment for the concrete case this was added
    /// for). Called with no arguments -- typically calls writeFieldCell() itself to apply the
    /// correction; CopperEngine doesn't know anything about which cells need one.
    using MidStepCorrection = std::function<void()>;

    /// Same per-iteration work as run(), but commits and waits on a separate command buffer for each
    /// of the `steps` iterations (rather than batching all of them into one), calling `sampler`
    /// after each -- so a caller can sample probes at every timestep without racing the GPU. Slower
    /// than run() for a large step count (see the Copper implementation plan's own "Output
    /// collection" design for the batched-gather alternative this doesn't implement yet) -- fine for
    /// Phase 4's real-board *correctness* verification; revisit if a production run needs the
    /// throughput.
    ///
    /// `midStepCorrection`, if non-null, splits each iteration into two command buffers (voltage
    /// update, then the correction, then current update) instead of the usual one -- see
    /// MidStepCorrection's own doc comment for why the split matters. Omitting it (the default)
    /// keeps the original single-command-buffer-per-iteration behavior and cost for callers with
    /// nothing that needs a mid-step hook.
    void runWithProbeSampling(std::uint32_t steps, const ProbeSampler& sampler,
                               const MidStepCorrection& midStepCorrection = nullptr);

    enum class Field { Ex, Ey, Ez, Hx, Hy, Hz };

    /// Reads one field component's entire current buffer back from the GPU, in the same flat
    /// (x fastest-varying) layout as CopperYeeGrid's own coefficient arrays -- see
    /// copperGridIndex(). MTLStorageModeShared means the underlying memory access itself is free
    /// (no GPU->CPU transfer), but this still allocates and copies a full `cellCount()`-length
    /// vector -- expensive when called every timestep on a large grid just to read a handful of
    /// probe cells (confirmed in practice: this was the dominant cost of a real-board
    /// runWithProbeSampling() run before readFieldCell() below existed). Prefer readFieldCell() for
    /// per-timestep probe sampling; this is for bulk/debug reads (e.g. Phase 2/3's own CPU-vs-GPU
    /// parity checks, which already want the whole grid).
    std::vector<float> readField(Field field) const;

    /// Copies a complete component into caller-owned storage. Unlike the value-returning overload,
    /// this retains `destination`'s allocation when its capacity is already large enough. Field
    /// frame persistence uses two such reusable sets of vectors so simulation and compression can
    /// ping-pong without allocating another six full-grid arrays for every captured frame.
    void readField(Field field, std::vector<float>& destination) const;

    /// Reads a single field cell directly from GPU-shared memory -- O(1), no allocation, safe to
    /// call many times per timestep (this is what probe sampling should use). Same indexing/layout
    /// as readField()/copperGridIndex().
    float readFieldCell(Field field, std::uint32_t x, std::uint32_t y, std::uint32_t z) const;

    /// Sum of squares of every current field value across all 6 components -- a cheap,
    /// GPU-buffer-direct approximation of openEMS's own
    /// Engine_Interface_FDTD::CalcFastEnergy() == EPS0*sum(E^2) + MUE0*sum(H^2) (see
    /// CopperFDTDRunner.cpp for how this drives the same energy-decay end criteria openEMS's own
    /// RunFDTD() uses). Computed via Accelerate's vDSP_svesq directly on each field buffer's
    /// MTLStorageModeShared memory -- no GPU->CPU copy, no custom Metal reduction kernel needed,
    /// since the buffer's own `.contents` pointer already *is* CPU-visible memory on Apple
    /// Silicon's unified memory architecture. Approximates openEMS's own
    /// (nx-1)*(ny-1)*(nz-1) summation range with the full nx*ny*nz grid instead (the outermost
    /// cell layer in each dimension -- a tiny fraction of cells for any real grid) -- acceptable
    /// since this is only ever used as a stop/continue decision threshold, never written to any
    /// output file, matching openEMS's own "fast"/approximate framing of the same estimate.
    double estimateEnergy() const;

    /// Directly overwrites one field component's single cell. Originally test-only (seeding an
    /// identical initial impulse on both Copper's GPU engine and a real CPU openEMS Engine for
    /// parity checks, without needing the excitation kernel); now also a real production caller --
    /// CopperFDTDRunner.cpp's own lumped-RLC pass (see CopperLumpedRLC.hpp) uses this every timestep
    /// to write back its corrected voltage, the GPU-side equivalent of Engine::SetVolt().
    void writeFieldCell(Field field, std::uint32_t x, std::uint32_t y, std::uint32_t z, float value);

    const CopperGridDims& dims() const;

private:
    struct Impl;
    std::unique_ptr<Impl> _impl;
};

} // namespace copper
