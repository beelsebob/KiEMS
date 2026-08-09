#include "port_resolution.hpp"

#include <algorithm>
#include <cmath>
#include <cstdlib>
#include <filesystem>
#include <limits>
#include <numbers>
#include <optional>
#include <string>
#include <unordered_map>
#include <utility>
#include <vector>

#include "config.hpp"
#include "constants.hpp"
#include "gerber_io.hpp"
#include "libkicad_query.hpp"
#include "logging.hpp"

namespace gerber2ems {

namespace {

using libkicad_query::PadIdentity;

std::string _normalizeLayerName(std::string name) {
    std::replace(name.begin(), name.end(), '.', '_');
    return name;
}

// Duplicates the small Edge_Cuts-bounding-box scan already performed independently by
// importer.cpp's getDimensions() and gerber_composite.cpp's edgeCutsBoundingBox() -- this
// project's established pattern for board extent (see gerber_composite.cpp's comment on
// edgeCutsBoundingBox: re-derived at each use site rather than threading a shared cache through
// unrelated modules for a parse that costs microseconds). Needed here so pad positions (from
// libkicad, aux-origin-relative) land in the exact same re-origined frame gerber_composite.cpp
// places composited copper triangles in.
Position _edgeCutsOrigin() {
    std::error_code ec;
    const std::filesystem::path fabDir = std::filesystem::current_path() / "fab";
    std::optional<std::filesystem::path> edgeCutsPath;
    if (std::filesystem::is_directory(fabDir, ec)) {
        for (const auto& entry : std::filesystem::directory_iterator(fabDir, ec)) {
            const std::string name = entry.path().filename().string();
            if (name.size() >= 13 && name.compare(name.size() - 13, 13, "Edge_Cuts.gbr") == 0) {
                edgeCutsPath = entry.path();
                break;
            }
        }
    }
    if (!edgeCutsPath.has_value()) {
        logError("No EdgeCuts gerber in fab dir(" + fabDir.string() + ")");
        std::exit(1);
    }
    double xMin = std::numeric_limits<double>::infinity();
    double yMin = std::numeric_limits<double>::infinity();
    const GerberFile edgeCuts(*edgeCutsPath);
    for (const auto& seg : edgeCuts.traceForNet("no-net").segments()) {
        xMin = std::min({seg.start().x(), seg.stop().x(), xMin});
        yMin = std::min({seg.start().y(), seg.stop().y(), yMin});
    }
    return Position(xMin, yMin);
}

// mm -> simulation units, matching FileFormat's own gerber-value scale (gerber_io.cpp) and the
// identical conversion getPortsFromFile used to apply to pos.csv's mm values.
double _mmToSimUnits(double mm) { return mm / 1000.0 / constants::baseUnit * constants::unitMultiplier; }

Position _padPositionInSimFrame(const PadIdentity& pad, const Position& edgeCutsOrigin) {
    return Position(_mmToSimUnits(pad.xMm) - edgeCutsOrigin.x(), _mmToSimUnits(pad.yMm) - edgeCutsOrigin.y());
}

// Caches parsed copper GerberFiles across every pad direction lookup in one resolveSimulationPorts()
// call -- several pads typically share a layer (and even a net), and re-parsing the same file per
// pad would be wasteful.
class _CopperLayerCache {
public:
    const GerberFile* forLayerFileName(const std::string& layerFileName) {
        const auto it = _files.find(layerFileName);
        if (it != _files.end()) {
            return it->second.has_value() ? &*it->second : nullptr;
        }

        const std::filesystem::path fabDir = std::filesystem::current_path() / "fab";
        const std::string suffix = "-" + layerFileName + ".gbr";
        std::optional<std::filesystem::path> gerberPath;
        std::error_code ec;
        if (std::filesystem::is_directory(fabDir, ec)) {
            for (const auto& entry : std::filesystem::directory_iterator(fabDir, ec)) {
                const std::string name = entry.path().filename().string();
                if (name.size() >= suffix.size() &&
                    name.compare(name.size() - suffix.size(), suffix.size(), suffix) == 0) {
                    gerberPath = entry.path();
                    break;
                }
            }
        }
        if (!gerberPath.has_value()) {
            return &*_files.emplace(layerFileName, std::nullopt).first->second;
        }
        return &*_files.emplace(layerFileName, GerberFile(*gerberPath)).first->second;
    }

private:
    std::unordered_map<std::string, std::optional<GerberFile>> _files;
};

// Snaps an angle (radians) to the nearest cardinal direction (0/90/180/270 degrees), returning
// nullopt if it's further than `toleranceDegrees` from all of them.
std::optional<double> _snapToCardinal(double angleRadians, double toleranceDegrees) {
    double degrees = angleRadians * 180.0 / std::numbers::pi;
    degrees = std::fmod(degrees, 360.0);
    if (degrees < 0) {
        degrees += 360.0;
    }
    static const double cardinals[] = {0.0, 90.0, 180.0, 270.0, 360.0};
    for (const double candidate : cardinals) {
        if (std::abs(degrees - candidate) <= toleranceDegrees) {
            return std::fmod(candidate, 360.0);
        }
    }
    return std::nullopt;
}

constexpr double kMinPositionToleranceSimUnits = 50.0; // 5 microns, at 10 sim-units/micron
// Real trace-to-pad connections often land near the pad's edge rather than its geometric center
// (e.g. a large/elongated SMD pad on a connector), so the search radius has to scale with the pad
// itself -- half its diagonal covers any point on its (possibly rotated) outline -- plus a fixed
// margin for the small extension KiCad's plotter typically adds at a pad/track junction.
constexpr double kPadToleranceMarginMm = 0.1;
constexpr double kDirectionToleranceDegrees = 5.0;

double _padSearchToleranceSimUnits(double padWidthMm, double padHeightMm) {
    const double halfDiagonalMm = std::hypot(padWidthMm, padHeightMm) / 2.0;
    return std::max(kMinPositionToleranceSimUnits, _mmToSimUnits(halfDiagonalMm + kPadToleranceMarginMm));
}

// Derives an MSLPort's propagation direction from the departure angle of `netName`'s own routed
// copper at `padPositionSim` on `layerFileName`, snapped to the nearest cardinal -- NOT from the
// pad's own footprint rotation, which doesn't necessarily match the direction its routed trace
// departs in (angled fanouts, connectors, etc.). Returns nullopt (having logged why) if no trace
// segment endpoint is close enough to the pad, or its angle isn't close enough to cardinal.
std::optional<double> _deriveDirection(_CopperLayerCache& cache, const Position& padPositionSim,
                                        const Position& edgeCutsOrigin, double padWidthMm, double padHeightMm,
                                        const std::string& netName, const std::string& layerFileName,
                                        const std::string& portLabel) {
    const GerberFile* gerber = cache.forLayerFileName(layerFileName);
    if (!gerber) {
        logError("No copper gerber found for layer \"" + layerFileName + "\" (port " + portLabel + ")");
        return std::nullopt;
    }

    const double toleranceSimUnits = _padSearchToleranceSimUnits(padWidthMm, padHeightMm);

    // A pad often has more than one segment touching it exactly (e.g. a short 45-degree corner
    // chamfer immediately at the pad, before the trace straightens into its real, cardinal
    // direction) -- collect every segment with an endpoint within tolerance, ordered by distance,
    // and take the first whose departure angle actually snaps to cardinal, rather than assuming
    // the single geometrically-nearest one is representative.
    //
    // GerberFile::traceForNet() returns segments in the gerber's own raw, un-re-origined
    // coordinates (the same convention gerber_composite.cpp's compositeOps() takes an explicit
    // origin argument to correct for), while padPositionSim has already been re-origined against
    // edgeCutsOrigin (see _padPositionInSimFrame) -- so every segment endpoint has to be shifted
    // by the same origin before it's comparable to padPositionSim at all.
    struct Candidate {
        double distance;
        Position from;
        Position to;
    };
    std::vector<Candidate> candidates;
    const Trace trace = gerber->traceForNet(netName);
    for (const TraceSegment& segment : trace.segments()) {
        const Position start(segment.start().x() - edgeCutsOrigin.x(), segment.start().y() - edgeCutsOrigin.y());
        const Position stop(segment.stop().x() - edgeCutsOrigin.x(), segment.stop().y() - edgeCutsOrigin.y());
        const double startDist = std::hypot(start.x() - padPositionSim.x(), start.y() - padPositionSim.y());
        const double stopDist = std::hypot(stop.x() - padPositionSim.x(), stop.y() - padPositionSim.y());
        if (startDist <= toleranceSimUnits) {
            candidates.push_back({startDist, start, stop});
        }
        if (stopDist <= toleranceSimUnits) {
            candidates.push_back({stopDist, stop, start});
        }
    }
    std::sort(candidates.begin(), candidates.end(),
              [](const Candidate& a, const Candidate& b) { return a.distance < b.distance; });

    if (candidates.empty()) {
        logError("Could not find net \"" + netName + "\"'s own routed copper departing pad for port " + portLabel +
                  " -- set an explicit \"direction\" override for this involved_nets entry");
        return std::nullopt;
    }

    for (const Candidate& candidate : candidates) {
        // Departure direction: away from the pad, along the segment.
        const double angle = std::atan2(candidate.to.y() - candidate.from.y(), candidate.to.x() - candidate.from.x());
        const std::optional<double> snapped = _snapToCardinal(angle, kDirectionToleranceDegrees);
        if (snapped.has_value()) {
            return snapped;
        }
    }

    logError("Net \"" + netName + "\"'s routed copper departs pad for port " + portLabel +
              " at a non-cardinal angle -- set an explicit \"direction\" override for this involved_nets entry");
    return std::nullopt;
}

/// One (footprintRef, padNumber) -> resolved port index -- built once per simulation while placing
/// ports, then reused to resolve ExcitationConfig/PortRef targets without re-deriving identity.
struct _PortIndex {
    std::optional<std::int32_t> find(const std::string& footprintRef, const std::string& padNumber) const {
        for (std::size_t i = 0; i < entries.size(); ++i) {
            if (entries[i].first == footprintRef && entries[i].second == padNumber) {
                return static_cast<std::int32_t>(i);
            }
        }
        return std::nullopt;
    }
    std::vector<std::pair<std::string, std::string>> entries; // parallel to SimulationConfig::ports()
};

void _resolvePortRef(PortRef& ref, const _PortIndex& index, const std::vector<std::string>& involvedNets,
                      const std::string& simName, const std::string& fieldLabel) {
    const PadIdentity resolved =
        libkicad_query::resolvePin(ref.footprint(), ref.pin(),
                                    "Simulation \"" + simName + "\": " + fieldLabel + " (" + ref.footprint() + "." +
                                        ref.pin() + ")");
    if (std::find(involvedNets.begin(), involvedNets.end(), resolved.netName) == involvedNets.end()) {
        logError("Simulation \"" + simName + "\": " + fieldLabel + " (" + ref.footprint() + "." + ref.pin() +
                  ", net \"" + resolved.netName + "\") is not part of this simulation's involved_nets");
        std::exit(1);
    }
    const std::optional<std::int32_t> portIndex = index.find(resolved.footprintRef, resolved.padNumber);
    if (!portIndex.has_value()) {
        logError("Simulation \"" + simName + "\": " + fieldLabel + " (" + ref.footprint() + "." + ref.pin() +
                  ") did not resolve to a placed port");
        std::exit(1);
    }
    ref.setResolvedIndex(*portIndex);
}

} // namespace

void resolveSimulationPorts() {
    const Position edgeCutsOrigin = _edgeCutsOrigin();

    for (SimulationConfig& sim : Config::sharedConfig().simulations()) {
        _CopperLayerCache layerCache;
        _PortIndex portIndex;

        // Map from resolved net name -> which InvolvedNetConfig entry claimed it (for error
        // messages and to detect conflicting duplicate claims), preserving resolution order.
        std::unordered_map<std::string, const InvolvedNetConfig*> netOwner;
        std::vector<std::string> orderedNets;

        for (const InvolvedNetConfig& entry : sim.involvedNets()) {
            for (const std::string& netName : libkicad_query::resolveInvolvedNetNames(entry)) {
                const auto [it, inserted] = netOwner.emplace(netName, &entry);
                if (!inserted) {
                    logError("Simulation \"" + sim.name() + "\": net \"" + netName +
                              "\" is claimed by more than one involved_nets entry");
                    std::exit(1);
                }
                orderedNets.push_back(netName);
            }
        }
        if (orderedNets.empty()) {
            logError("Simulation \"" + sim.name() + "\": involved_nets resolved to zero nets");
            std::exit(1);
        }
        sim.resolvedNets() = orderedNets;
        // Resolved purely to confirm the ground net(s) actually exist -- the ground copper itself
        // is consumed by board_slicing.cpp, not here.
        (void)libkicad_query::resolveGroundNetNames(sim.groundNet());

        for (const std::string& netName : orderedNets) {
            const InvolvedNetConfig& entry = *netOwner.at(netName);
            const std::vector<PadIdentity> pads = libkicad_query::padsOnNet(
                netName, "Simulation \"" + sim.name() + "\": enumerating pads on net \"" + netName + "\"");

            if (pads.size() > 32) {
                logWarning("Simulation \"" + sim.name() + "\": net \"" + netName + "\" resolved to " +
                           std::to_string(pads.size()) +
                           " pads -- confirm this is intended (a broad net_class or a power/ground net will "
                           "place a port, and run an FDTD excitation, on every one of them)");
            }

            for (const PadIdentity& pad : pads) {
                const std::string portLabel = netName + "@" + pad.footprintRef + "." + pad.padNumber;
                const Position positionSim = _padPositionInSimFrame(pad, edgeCutsOrigin);
                const std::string layerFileName = _normalizeLayerName(pad.copperLayerName);

                const std::optional<std::int32_t> layer =
                    Config::sharedConfig().metalLayerIndexForFileName(layerFileName);
                if (!layer.has_value()) {
                    logError("Port " + portLabel + ": copper layer \"" + pad.copperLayerName +
                              "\" not found in stackup (through-hole pads, which span every copper layer, aren't "
                              "supported yet -- v1 requires SMD pads)");
                    std::exit(1);
                }

                double direction = 0;
                if (entry.direction().has_value()) {
                    direction = *entry.direction();
                } else {
                    const std::optional<double> derived =
                        _deriveDirection(layerCache, positionSim, edgeCutsOrigin, pad.widthMm, pad.heightMm, netName,
                                          layerFileName, portLabel);
                    if (!derived.has_value()) {
                        std::exit(1);
                    }
                    direction = *derived;
                }

                PortConfig port;
                port.setName(portLabel);
                port.setFootprintRef(pad.footprintRef);
                port.setPadNumber(pad.padNumber);
                port.setPosition({positionSim.x(), positionSim.y()});
                port.setDirection(direction);
                port.setLayer(*layer);
                port.setPlane(entry.plane());
                port.setImpedance(entry.impedance());
                port.setLength(entry.length());
                if (entry.width().has_value()) {
                    port.setWidth(*entry.width());
                }
                if (entry.dBMargin().has_value()) {
                    port.setDBMargin(*entry.dBMargin());
                }
                port.setExcite(true); // every involved-net port is excited; results generated for all of them
                port.scaleToSimulationUnits(constants::unitMultiplier);

                portIndex.entries.emplace_back(pad.footprintRef, pad.padNumber);
                sim.ports().push_back(std::move(port));
            }
        }

        for (ExcitationConfig& excitation : sim.excitations()) {
            const PadIdentity resolved = libkicad_query::resolvePin(
                excitation.footprint(), excitation.pin(),
                "Simulation \"" + sim.name() + "\": excitation on " + excitation.footprint() + "." +
                    excitation.pin());
            if (std::find(orderedNets.begin(), orderedNets.end(), resolved.netName) == orderedNets.end()) {
                logError("Simulation \"" + sim.name() + "\": excitation targets " + excitation.footprint() + "." +
                          excitation.pin() + " (net \"" + resolved.netName +
                          "\") but that net is not part of this simulation's involved_nets");
                std::exit(1);
            }
            const std::optional<std::int32_t> index = portIndex.find(resolved.footprintRef, resolved.padNumber);
            if (!index.has_value()) {
                logError("Simulation \"" + sim.name() + "\": excitation on " + excitation.footprint() + "." +
                          excitation.pin() + " did not resolve to a placed port");
                std::exit(1);
            }
            excitation.setDrivenPortIndex(*index);
        }

        for (SingleEndedConfig& trace : sim.traces()) {
            _resolvePortRef(trace.start(), portIndex, orderedNets, sim.name(), "trace start");
            _resolvePortRef(trace.stop(), portIndex, orderedNets, sim.name(), "trace stop");
            trace.postInit();
        }

        for (DifferentialPairConfig& pair : sim.diffPairs()) {
            _resolvePortRef(pair.startP(), portIndex, orderedNets, sim.name(), "differential pair start_p");
            _resolvePortRef(pair.stopP(), portIndex, orderedNets, sim.name(), "differential pair stop_p");
            _resolvePortRef(pair.startN(), portIndex, orderedNets, sim.name(), "differential pair start_n");
            _resolvePortRef(pair.stopN(), portIndex, orderedNets, sim.name(), "differential pair stop_n");
            pair.postInit();
        }
    }
}

} // namespace gerber2ems
