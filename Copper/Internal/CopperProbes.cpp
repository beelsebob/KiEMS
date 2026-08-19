#include "CopperProbes.hpp"

#include <stdexcept>

#include "CSPrimBox.h"
#include "CSPropProbeBox.h"

namespace copper {

namespace {

/// Voltage probes: a direct port of ProcessVoltage::DefineStartStopCoord, which -- unlike the
/// generic Processing::DefineStartStopCoord most other processings use -- snaps `dstart`/`dstop`
/// *independently*, each via its own Operator::SnapToMesh call, rather than swapping them into
/// min/max order first (Operator::SnapBox2Mesh's own behavior). That's deliberate on openEMS's
/// part: CalcVoltageIntegral's sign convention depends on start[n] vs stop[n] still encoding the
/// box's original direction, not just its extent.
CopperProbe discoverVoltageProbe(Operator& op, CSPropProbeBox& pb, CSPrimBox& box) {
    double dstart[3], dstop[3];
    for (int n = 0; n < 3; ++n) {
        dstart[n] = box.GetCoord(2 * n);
        dstop[n] = box.GetCoord(2 * n + 1);
    }

    CopperProbe probe;
    probe.name = pb.GetName();
    probe.type = CopperProbeType::Voltage;
    probe.weight = pb.GetWeighting();

    op.SnapToMesh(dstart, probe.start, /*dualMesh=*/false, /*fullMesh=*/false, nullptr);
    op.SnapToMesh(dstop, probe.stop, /*dualMesh=*/false, /*fullMesh=*/false, nullptr);
    return probe;
}

/// Current probes: a port of the base Processing::DefineStartStopCoord (Operator::SnapBox2Mesh with
/// SnapMethod=1, dualMesh=true -- matching ProcessCurrent's constructor/openEMS's own
/// SetDualMesh(true) for ProbeType==1) followed by ProcessCurrent::DefineStartStopCoord's own
/// padding of whichever in-plane axis (not the normal direction) came in as a single point, so the
/// Ampere loop actually encloses an area. gerber2ems's own ports.cpp always sets an explicit normal
/// direction (see csx_helpers.cpp's addProbe), so only that branch is ported here -- the
/// auto-infer-from-a-2D-box branch openEMS falls back to when no normal direction is given isn't
/// something gerber2ems's own probe construction ever exercises.
CopperProbe discoverCurrentProbe(Operator& op, CSPropProbeBox& pb, CSPrimBox& box) {
    double dstart[3], dstop[3];
    for (int n = 0; n < 3; ++n) {
        dstart[n] = box.GetCoord(2 * n);
        dstop[n] = box.GetCoord(2 * n + 1);
    }

    CopperProbe probe;
    probe.name = pb.GetName();
    probe.type = CopperProbeType::Current;
    probe.weight = pb.GetWeighting();
    probe.normalDir = pb.GetNormalDir();

    op.SnapBox2Mesh(dstart, dstop, probe.start, probe.stop, /*dualMesh=*/true, /*fullMesh=*/false,
                     /*SnapMethod=*/1, probe.startInside, probe.stopInside);

    if (probe.normalDir >= 0 && probe.normalDir <= 2) {
        for (int n = 0; n < 3; ++n) {
            if (n == probe.normalDir) {
                continue;
            }
            if (dstart[n] != dstop[n]) {
                continue;
            }
            // Two independent ifs, not if/else -- the second deliberately re-reads probe.start[n],
            // which the first may have just decremented. Ported exactly, not "cleaned up", because
            // that's what processcurrent.cpp itself does (see CopperProbes.hpp's file comment on why
            // this file favors verbatim porting over an obviously-equivalent rewrite).
            if (op.GetDiscLine(n, probe.start[n], true) > dstart[n] && probe.start[n] > 0) {
                --probe.start[n];
            }
            if (op.GetDiscLine(n, probe.start[n], true) < dstart[n] &&
                probe.stop[n] < op.GetNumberOfLines(n) - 1) {
                ++probe.stop[n];
            }
        }
    }
    return probe;
}

} // namespace

std::vector<CopperProbe> discoverProbes(ContinuousStructure& csx, Operator& op) {
    std::vector<CopperProbe> probes;
    for (CSProperties* prop : csx.GetPropertyByType(CSProperties::PROBEBOX)) {
        auto* pb = prop->ToProbeBox();
        if (pb == nullptr) {
            continue;
        }
        for (std::size_t n = 0; n < pb->GetQtyPrimitives(); ++n) {
            CSPrimBox* box = pb->GetPrimitive(n)->ToBox();
            if (box == nullptr) {
                continue;
            }
            if (pb->GetProbeType() == 0) {
                probes.push_back(discoverVoltageProbe(op, *pb, *box));
            } else if (pb->GetProbeType() == 1) {
                probes.push_back(discoverCurrentProbe(op, *pb, *box));
            }
        }
    }
    return probes;
}

CopperProbeWriter::CopperProbeWriter(const std::filesystem::path& directory, const CopperProbe& probe)
    : _weight(probe.weight) {
    _file.open(directory / probe.name);
    if (!_file.is_open()) {
        throw std::runtime_error("CopperProbeWriter: failed to open " + (directory / probe.name).string());
    }
    _file << "% time-domain " << (probe.type == CopperProbeType::Voltage ? "voltage" : "current")
          << " probe, written by Copper\n";
    _file << "% t/s\t" << (probe.type == CopperProbeType::Voltage ? "voltage" : "current") << "\n";
    _file.precision(12);
}

void CopperProbeWriter::sample(double timeSeconds, double rawValue) {
    _file << timeSeconds << "\t" << (rawValue * _weight) << "\n";
}

} // namespace copper
