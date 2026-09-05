// Reaches into openEMS/CSXCAD internals that are `protected`, with no public getter, purely so
// Copper can read the *setup* results (grid, coefficients, PML data, excitation signal) that
// openEMS's own `Operator`/`Excitation`/`Operator_Ext_UPML` already compute -- Copper never
// reimplements that math itself (see the Copper implementation plan's rationale for why: every
// number here is openEMS's own already-computed answer, not a second, independently-derived path
// that could silently drift from it).
//
// `openEMS::FDTD_Op` access (CopperOpenEMS) is ordinary, well-defined protected-member access via
// inheritance *when Copper constructs its own `openEMS` object as `CopperOpenEMS` from the start*
// (every Copper_smoketest fixture does exactly this). `copper_fdtd_worker/main.cpp` is a different
// situation: it reaches a `Simulation::fdtdEngine()`-returned `openEMS&` -- an object
// libgerber2ems itself constructed as plain `openEMS`, with no idea Copper exists -- via
// `static_cast<CopperOpenEMS&>`, which *is* a downcast of an object never actually constructed as
// that derived type. Same accepted, documented risk category as CopperUPMLAccess/
// CopperExcitationAccess below (identical layout, no new data members, no vtable change), not a new
// one -- worth calling out explicitly here since this class's own two accessors (GetOperatorForGPU/
// GetEngineForCPU/GetNumberOfTimestepsForGPU) get used both ways depending on caller.
//
// `Operator_Ext_UPML`'s coefficient/geometry access (CopperUPMLAccess) is a different situation:
// the actual `Operator_Ext_UPML` instance is constructed internally by openEMS's own PML-attachment
// code (`Operator_Ext_UPML::Create_UPML`, invoked from boundary-condition setup), not by Copper --
// so reaching its members via `static_cast<CopperUPMLAccess*>` is a downcast of an object that was
// never actually constructed as a `CopperUPMLAccess`. Formally UB per the strict C++ object model,
// but a long-established, practically-safe idiom given the derived class adds no data members and
// no new virtuals (identical layout, no vtable change, no compiler mainstream or otherwise treats
// this differently from the base type) -- accepted here as a deliberate, documented risk rather
// than something to rediscover later.
//
// IMPORTANT for every file that includes this header (directly or transitively): openEMS's own
// internal headers pull in CSXCAD via flat, unnamespaced includes (e.g. "ContinuousStructure.h"),
// resolved against the CSXCAD *source checkout* (see the Copper target's own
// SYSTEM_HEADER_SEARCH_PATHS), not the installed, namespaced `<CSXCAD/ContinuousStructure.h>`
// public headers the rest of this app uses. Never mix the two forms in one translation unit --
// they're independent copies of the same classes with no shared include guards, and the compiler
// will report "redefinition" errors. Any Copper source touching openEMS internals must use the
// flat form throughout (`#include <ContinuousStructure.h>`, not `<CSXCAD/ContinuousStructure.h>`).
#pragma once

#include "FDTD/engine.h"
#include "FDTD/extensions/operator_ext_excitation.h"
#include "FDTD/extensions/operator_ext_upml.h"
#include "openems.h"

namespace copper {

class CopperOpenEMS : public openEMS {
public:
    Operator* GetOperatorForGPU() { return FDTD_Op; }

    /// The real CPU `Engine` openEMS's own `SetupFDTD()` builds from the same `Operator` returned by
    /// `GetOperatorForGPU()` -- exists purely so a debug/verification build can diff Copper's GPU
    /// leapfrog against openEMS's own CPU one on the identical grid (see the Copper implementation
    /// plan's Phase 2 pass criterion); not used by any shipped (non-test) Copper code path.
    Engine* GetEngineForCPU() { return FDTD_Eng; }

    /// The configured max-timestep count (`openEMS::SetNumberOfTimeSteps`, e.g. from
    /// `EMSConfig::maxSteps()`) -- how many iterations `copper_fdtd_worker` should run
    /// `CopperEngine::runWithProbeSampling` for. openEMS's own CPU RunFDTD() additionally supports
    /// stopping early once its own energy-decay end criterion is met; Copper's GPU worker doesn't
    /// implement that yet and always runs the full configured count (see copper_fdtd_worker's own
    /// file comment).
    unsigned int GetNumberOfTimestepsForGPU() { return NrTS; }
};

/// Test-only access to CalcPEC's protected paint pass and counters. Same zero-data-member access
/// pattern as CopperUPMLAccess below; production Copper code does not use this class.
class CopperOperatorAccess : public Operator {
public:
    using Operator::m_Nr_PEC;
    using Operator::PaintPECColumn;
};

class CopperUPMLAccess : public Operator_Ext_UPML {
public:
    using Operator_Ext_UPML::m_BC;
    using Operator_Ext_UPML::m_Size;
    using Operator_Ext_UPML::m_StartPos;
    using Operator_Ext_UPML::m_numLines;
    using Operator_Ext_UPML::GetVV;
    using Operator_Ext_UPML::GetVVFO;
    using Operator_Ext_UPML::GetVVFN;
    using Operator_Ext_UPML::GetII;
    using Operator_Ext_UPML::GetIIFO;
    using Operator_Ext_UPML::GetIIFN;
};

/// Same downcast-of-an-object-Copper-didn't-construct situation as CopperUPMLAccess above (openEMS
/// attaches this extension itself, inside SetupFDTD()) -- same accepted, documented risk.
class CopperExcitationAccess : public Operator_Ext_Excitation {
public:
    using Operator_Ext_Excitation::Volt_Count;
    using Operator_Ext_Excitation::Volt_index;
    using Operator_Ext_Excitation::Volt_dir;
    using Operator_Ext_Excitation::Volt_amp;
    using Operator_Ext_Excitation::Volt_delay;
    using Operator_Ext_Excitation::Curr_Count;
    using Operator_Ext_Excitation::Curr_index;
    using Operator_Ext_Excitation::Curr_dir;
    using Operator_Ext_Excitation::Curr_amp;
    using Operator_Ext_Excitation::Curr_delay;
};

} // namespace copper
