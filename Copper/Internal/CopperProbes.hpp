// Discovers openEMS voltage/current probe boxes (CSPropProbeBox) from a ContinuousStructure, snaps
// them to the mesh, samples Copper's own field arrays with the exact same formulas openEMS's own
// Engine_Interface_FDTD::CalcVoltageIntegral / ProcessCurrent::CalcIntegral use, and writes them out
// in openEMS's own ASCII probe-file format -- so gerber2ems's existing reader
// (libgerber2ems/gerber2ems/ports.cpp's `_loadUiFile`) can consume Copper's output completely
// unmodified, exactly like the plan's Phase 4 requires.
//
// Snapping is intentionally NOT a single generic "snap this box to the mesh" call, even though
// Operator::SnapBox2Mesh exists and would look simpler: voltage and current probes snap
// differently, and porting the wrong one silently breaks sign conventions rather than failing
// loudly, so this file mirrors openEMS's own two distinct code paths on purpose (see
// discoverProbes()'s own comments for exactly which openEMS function each mirrors).
#pragma once

#include <cstdint>
#include <filesystem>
#include <fstream>
#include <string>
#include <vector>

#include "CopperYeeGrid.hpp"
#include "FDTD/operator.h"
#include "ContinuousStructure.h"

namespace copper {

enum class CopperProbeType { Voltage, Current };

/// A mesh-snapped probe box, ready to sample -- everything CalcVoltageIntegral/CalcCurrentIntegral
/// (see CopperProbes.cpp) needs, already resolved to grid indices so sampling never has to touch
/// CSXCAD or Operator again.
struct CopperProbe {
    std::string name;   // == the probe file's own filename, no extension (see CopperProbeWriter)
    CopperProbeType type = CopperProbeType::Voltage;
    double weight = 1.0; // CSPropProbeBox::GetWeighting() -- applied at write time, not sample time

    // Voltage probes: direction-preserving (start[n] may be > stop[n], encoding integration sign --
    // see Engine_Interface_FDTD::CalcVoltageIntegral). Current probes: min/max ordered (from
    // Operator::SnapBox2Mesh), with `normalDir`/`startInside`/`stopInside` filled in.
    std::uint32_t start[3] = {0, 0, 0};
    std::uint32_t stop[3] = {0, 0, 0};
    int normalDir = -1;                          // current probes only
    bool startInside[3] = {true, true, true};     // current probes only
    bool stopInside[3] = {true, true, true};      // current probes only
};

/// Walks every CSPropProbeBox in `csx` with ProbeType 0 (voltage) or 1 (current) -- the only two
/// types gerber2ems's own ports.cpp ever creates (see csx_helpers.cpp's `addProbe`) -- and snaps
/// each one's primitive box to `op`'s mesh. `op` must already be fully set up
/// (openEMS::SetupFDTD() already run).
std::vector<CopperProbe> discoverProbes(ContinuousStructure& csx, Operator& op);

/// Straight sum of E-field-edge ("volt") values along the probe's single non-degenerate axis -- a
/// direct port of Engine_Interface_FDTD::CalcVoltageIntegral. `field` is called as
/// `field(axis, x, y, z) -> float` and should be cheap: a real probe box only touches a handful of
/// cells, so a caller should pass something like `CopperEngine::readFieldCell` (O(1), no
/// allocation) rather than pre-copying a whole grid's worth of data -- that per-timestep full-array
/// copy was confirmed in practice to dominate a real board's runtime before this was templated on
/// the accessor instead of requiring a full `std::vector<float>[3]`. Undefined which axis
/// contributes if `probe` isn't actually a voltage probe (only one of `probe.start[n]`/
/// `probe.stop[n]` should differ).
template <typename FieldAccessor>
double sampleVoltageProbe(const CopperProbe& probe, FieldAccessor&& field) {
    double result = 0.0;
    for (std::uint32_t n = 0; n < 3; ++n) {
        if (probe.start[n] < probe.stop[n]) {
            std::uint32_t pos[3] = {probe.start[0], probe.start[1], probe.start[2]};
            for (; pos[n] < probe.stop[n]; ++pos[n]) {
                result += field(n, pos[0], pos[1], pos[2]);
            }
        } else if (probe.start[n] > probe.stop[n]) {
            std::uint32_t pos[3] = {probe.stop[0], probe.stop[1], probe.stop[2]};
            for (; pos[n] < probe.start[n]; ++pos[n]) {
                result -= field(n, pos[0], pos[1], pos[2]);
            }
        }
    }
    return result;
}

/// Signed 4-side Ampere-loop sum of H-field-edge ("curr") values around the probe's enclosed area --
/// a direct port of ProcessCurrent::CalcIntegral's per-normal-direction switch. Same `field`
/// accessor contract as sampleVoltageProbe.
template <typename FieldAccessor>
double sampleCurrentProbe(const CopperProbe& probe, FieldAccessor&& field) {
    const std::uint32_t* start = probe.start;
    const std::uint32_t* stop = probe.stop;
    const bool* startInside = probe.startInside;
    const bool* stopInside = probe.stopInside;

    // FDTD_FLOAT (== float) accumulator in the real openEMS source -- matched here for the same
    // rounding behavior, even though the final written value is a double (see CopperProbeWriter).
    float current = 0.0F;
    switch (probe.normalDir) {
    case 0: // x-normal loop, in the y-z plane
        if (stopInside[0] && startInside[2]) {
            for (std::uint32_t i = start[1] + 1; i <= stop[1]; ++i) {
                current += field(1, stop[0], i, start[2]);
            }
        }
        if (stopInside[0] && stopInside[1]) {
            for (std::uint32_t i = start[2] + 1; i <= stop[2]; ++i) {
                current += field(2, stop[0], stop[1], i);
            }
        }
        if (startInside[0] && stopInside[2]) {
            for (std::uint32_t i = start[1] + 1; i <= stop[1]; ++i) {
                current -= field(1, start[0], i, stop[2]);
            }
        }
        if (startInside[0] && startInside[1]) {
            for (std::uint32_t i = start[2] + 1; i <= stop[2]; ++i) {
                current -= field(2, start[0], start[1], i);
            }
        }
        break;
    case 1: // y-normal loop, in the z-x plane
        if (startInside[0] && startInside[1]) {
            for (std::uint32_t i = start[2] + 1; i <= stop[2]; ++i) {
                current += field(2, start[0], start[1], i);
            }
        }
        if (stopInside[1] && stopInside[2]) {
            for (std::uint32_t i = start[0] + 1; i <= stop[0]; ++i) {
                current += field(0, i, stop[1], stop[2]);
            }
        }
        if (stopInside[0] && stopInside[1]) {
            for (std::uint32_t i = start[2] + 1; i <= stop[2]; ++i) {
                current -= field(2, stop[0], stop[1], i);
            }
        }
        if (startInside[1] && startInside[2]) {
            for (std::uint32_t i = start[0] + 1; i <= stop[0]; ++i) {
                current -= field(0, i, start[1], start[2]);
            }
        }
        break;
    case 2: // z-normal loop, in the x-y plane
        if (startInside[1] && startInside[2]) {
            for (std::uint32_t i = start[0] + 1; i <= stop[0]; ++i) {
                current += field(0, i, start[1], start[2]);
            }
        }
        if (stopInside[0] && startInside[2]) {
            for (std::uint32_t i = start[1] + 1; i <= stop[1]; ++i) {
                current += field(1, stop[0], i, start[2]);
            }
        }
        if (stopInside[1] && stopInside[2]) {
            for (std::uint32_t i = start[0] + 1; i <= stop[0]; ++i) {
                current -= field(0, i, stop[1], stop[2]);
            }
        }
        if (startInside[0] && stopInside[2]) {
            for (std::uint32_t i = start[1] + 1; i <= stop[1]; ++i) {
                current -= field(1, start[0], i, stop[2]);
            }
        }
        break;
    default:
        break;
    }
    return static_cast<double>(current);
}

/// Opens `directory/probe.name` (no extension, matching openEMS's own naming -- see
/// ProcessIntegral::InitProcess) and writes openEMS's own ASCII probe-file shape: a few `%`-prefixed
/// header lines (content is cosmetic -- gerber2ems's own reader only checks the leading `%`, see
/// _loadUiFile), then one `time\tvalue` row per sample() call, value already multiplied by
/// `probe.weight` (matching ProcessIntegral::Process's own `m_Results[n] * m_weight`). Throws
/// std::runtime_error if the file can't be opened.
class CopperProbeWriter {
public:
    CopperProbeWriter(const std::filesystem::path& directory, const CopperProbe& probe);

    /// `rawValue` is the *unweighted* sampleVoltageProbe/sampleCurrentProbe result -- this multiplies
    /// by probe.weight before writing, so callers never need to apply the weight themselves.
    void sample(double timeSeconds, double rawValue);

private:
    std::ofstream _file;
    double _weight;
};

} // namespace copper
