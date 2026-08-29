#include "port_resolution.hpp"

#include <algorithm>
#include <cctype>
#include <cmath>
#include <cstdlib>
#include <expected>
#include <filesystem>
#include <limits>
#include <numbers>
#include <optional>
#include <set>
#include <string>
#include <string_view>
#include <unordered_map>
#include <unordered_set>
#include <utility>
#include <vector>

#include "component_value.hpp"
#include "config.hpp"
#include "constants.hpp"
#include "gerber_io.hpp"
#include "libkicad_query.hpp"
#include "logging.hpp"
#include "paths_config.hpp"

namespace gerber2ems {

using namespace Cu;

namespace {

using libkicad_query::PadIdentity;

std::string _normalizeLayerName(std::string name) {
    std::replace(name.begin(), name.end(), '.', '_');
    return name;
}

// KiCad reserves a bare "/" as its hierarchical-sheet path separator within a net name, so a net
// actually named with a literal slash in it comes back from libkicad already escaped as "{slash}"
// (see Gerber2EMSStudio/NetNameFormatting.swift's own doc comment for the fuller picture, including
// the other markup tokens KiCad net names can carry -- this is deliberately just the one token that
// renders wrong as plain, unformatted text, which is all a std::string error/log message ever is).
// Every net name this file interpolates into a human-facing message should be passed through this
// first -- but never the net name used as an actual libkicad_query lookup KEY, which must stay in
// KiCad's own escaped form to match correctly.
std::string _unescapeForDisplay(std::string name) {
    constexpr std::string_view kEscapedSlash = "{slash}";
    std::size_t pos = 0;
    while ((pos = name.find(kEscapedSlash, pos)) != std::string::npos) {
        name.replace(pos, kEscapedSlash.size(), "/");
        pos += 1;
    }
    return name;
}

// Duplicates the small Edge_Cuts-bounding-box scan already performed independently by
// importer.cpp's getDimensions() and gerber_composite.cpp's edgeCutsBoundingBox() -- this
// project's established pattern for board extent (see gerber_composite.cpp's comment on
// edgeCutsBoundingBox: re-derived at each use site rather than threading a shared cache through
// unrelated modules for a parse that costs microseconds). Needed here so pad positions (from
// libkicad, aux-origin-relative) land in the exact same re-origined frame gerber_composite.cpp
// places composited copper triangles in.
std::expected<Position, std::string> _edgeCutsOrigin(const std::filesystem::path& fabDir,
                                                       double tessellationTolerance) {
    std::error_code ec;
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
        return std::unexpected("No EdgeCuts gerber in fab dir(" + fabDir.string() + ")");
    }
    double xMin = std::numeric_limits<double>::infinity();
    double yMin = std::numeric_limits<double>::infinity();
    auto edgeCutsResult = GerberFile::load(*edgeCutsPath, tessellationTolerance);
    if (!edgeCutsResult) {
        return std::unexpected(std::move(edgeCutsResult).error());
    }
    const GerberFile& edgeCuts = *edgeCutsResult;
    for (const auto& seg : edgeCuts.traceForNet(NetName("no-net")).segments()) {
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
    /// Returns nullptr (a success value, not an error) if there's legitimately no copper gerber for
    /// this layer; only a failure to parse a gerber that *was* found is reported as unexpected.
    std::expected<const GerberFile*, std::string> forLayerFileName(const std::filesystem::path& fabDir,
                                                                     const std::string& layerFileName,
                                                                     double tessellationTolerance) {
        const auto it = _files.find(layerFileName);
        if (it != _files.end()) {
            return it->second.has_value() ? &*it->second : nullptr;
        }

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
        auto gerberResult = GerberFile::load(*gerberPath, tessellationTolerance);
        if (!gerberResult) {
            return std::unexpected(std::move(gerberResult).error());
        }
        return &*_files.emplace(layerFileName, std::move(*gerberResult)).first->second;
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
// margin for the small extension KiCad's plotter typically adds at a pad/track junction. This
// margin is a fixed physical distance, not scaled with pad size, because a teardrop/fillet lead-in
// (the thing this margin exists to search past) is roughly a fixed real-world size regardless of
// how small the pad itself is -- confirmed against a real, tiny (0.46x0.4mm) capacitor pad whose
// own curved lead-in didn't straighten out to a cardinal angle until ~0.35mm from the pad center,
// which the previous, smaller 0.1mm margin didn't reach at all (see _deriveDirection's own
// candidate search -- it already takes the first candidate, ordered nearest-first, that actually
// snaps to cardinal, so widening this margin only ever adds *more distant* candidates to consider,
// never changes which nearer one wins if one already qualified).
constexpr double kPadToleranceMarginMm = 0.4;
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
std::expected<double, std::string> _deriveDirection(_CopperLayerCache& cache, const std::filesystem::path& fabDir,
                                                      const Position& padPositionSim, const Position& edgeCutsOrigin,
                                                      double padWidthMm, double padHeightMm,
                                                      const std::string& netName, const std::string& layerFileName,
                                                      const std::string& portLabel, double tessellationTolerance) {
    auto gerberResult = cache.forLayerFileName(fabDir, layerFileName, tessellationTolerance);
    if (!gerberResult) return std::unexpected(std::move(gerberResult).error());
    const GerberFile* gerber = *gerberResult;
    if (!gerber) {
        return std::unexpected("No copper gerber found for layer \"" + layerFileName + "\" (port " + portLabel + ")");
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
    const Trace trace = gerber->traceForNet(NetName(netName));
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
        return std::unexpected("Could not find net \"" + _unescapeForDisplay(netName) +
                                "\"'s own routed copper departing pad for port " + portLabel +
                                " -- set an explicit \"direction\" override for this involved_nets entry");
    }

    for (const Candidate& candidate : candidates) {
        // Departure direction: away from the pad, along the segment.
        const double angle = std::atan2(candidate.to.y() - candidate.from.y(), candidate.to.x() - candidate.from.x());
        const std::optional<double> snapped = _snapToCardinal(angle, kDirectionToleranceDegrees);
        if (snapped.has_value()) {
            return *snapped;
        }
    }

    return std::unexpected("Net \"" + _unescapeForDisplay(netName) + "\"'s routed copper departs pad for port " +
                            portLabel +
                            " at a non-cardinal angle -- set an explicit \"direction\" override for this "
                            "involved_nets entry");
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

// Everything before the first digit, uppercased -- e.g. "R1" -> "R", "RN2" -> "RN", "C89" -> "C".
std::string _letterPrefix(const std::string& reference) {
    std::string prefix;
    for (const char c : reference) {
        if (std::isdigit(static_cast<unsigned char>(c)) != 0) {
            break;
        }
        prefix += static_cast<char>(std::toupper(static_cast<unsigned char>(c)));
    }
    return prefix;
}

// Exact match only (not a prefix match) -- "RN"/"RT"/"RV"/"CN"/"CR"/etc. are deliberately excluded,
// matching Gerber2EMSStudio/ComponentCategory.swift's effective behavior for these three single-
// letter designators, without porting its whole IEEE-315 category table.
std::optional<std::pair<LumpedComponentType, char>> _lumpedComponentKind(const std::string& letterPrefix) {
    if (letterPrefix == "R") {
        return std::make_pair(LumpedComponentType::Resistor, 'R');
    }
    if (letterPrefix == "L") {
        return std::make_pair(LumpedComponentType::Inductor, 'H');
    }
    if (letterPrefix == "C") {
        return std::make_pair(LumpedComponentType::Capacitor, 'F');
    }
    return std::nullopt;
}

// Auto-discovers every 2-pin R/L/C on the board whose both pins sit on a net already involved in
// `sim` (or its ground net) and folds each into a LumpedComponentConfig -- see that type's own doc
// comment. Silently skips anything not R/L/C-with-2-qualifying-pins (the overwhelming majority of
// components on any real board); logs and skips a component that *is* in scope but couldn't
// actually be modeled (unparseable value, pins on different/unknown layers, non-axis-aligned pins).
std::expected<void, std::string> _resolveLumpedComponents(const EMSConfig& config, SimulationConfig& sim,
                                                            const PathsConfig& paths, const Position& edgeCutsOrigin,
                                                            const std::vector<std::string>& orderedNets) {
    sim.lumpedComponents().clear();

    auto groundNetsResult = libkicad_query::resolveGroundNetNames(paths, sim.groundNet());
    if (!groundNetsResult) {
        return std::unexpected(std::move(groundNetsResult).error());
    }
    std::unordered_set<std::string> membership(orderedNets.begin(), orderedNets.end());
    membership.insert(groundNetsResult->begin(), groundNetsResult->end());

    auto footprintsResult = libkicad_query::footprints(
        paths, "Simulation \"" + sim.name() + "\": enumerating footprints for lumped-component discovery");
    if (!footprintsResult) {
        return std::unexpected(std::move(footprintsResult).error());
    }

    for (const auto& footprint : *footprintsResult) {
        const auto kind = _lumpedComponentKind(_letterPrefix(footprint.reference));
        if (!kind.has_value()) {
            continue;
        }
        if (footprint.pins.size() != 2) {
            // Same visibility reasoning as the net-membership skip below -- an R/L/C-prefixed
            // footprint that isn't exactly 2 pins (a resistor network, a 4-pin common-mode choke,
            // an unpopulated/DNP third pad some capacitor footprint variants report) would
            // otherwise silently vanish, indistinguishable from "wrong prefix, never considered."
            logInfo("Simulation \"" + sim.name() + "\": component " + footprint.reference + " has " +
                     std::to_string(footprint.pins.size()) + " pin(s), not 2 -- skipping (not a supported R/L/C shape)");
            continue;
        }
        const auto& pin1 = footprint.pins[0];
        const auto& pin2 = footprint.pins[1];
        if (pin1.netName.empty() || pin2.netName.empty()) {
            logInfo("Simulation \"" + sim.name() + "\": component " + footprint.reference +
                     " has an unconnected pin -- skipping");
            continue;
        }
        if (membership.find(pin1.netName) == membership.end() || membership.find(pin2.netName) == membership.end()) {
            // logInfo, not logWarning: this is the ordinary, expected outcome for most R/L/C parts
            // on a real board (only a small minority ever sit between two simulated/ground nets) --
            // but it's the one skip reason every other branch below already logs an equivalent of
            // and this one didn't, leaving "found the part but its nets didn't match" completely
            // silent and indistinguishable from "never considered it at all" (wrong prefix/pin
            // count). Bounded volume: only ever printed for genuine 2-pin R/L/C footprints, already
            // a small subset of a real board.
            logInfo("Simulation \"" + sim.name() + "\": component " + footprint.reference + " (pins on \"" +
                     _unescapeForDisplay(pin1.netName) + "\" / \"" + _unescapeForDisplay(pin2.netName) +
                     "\") -- neither/only one net is in this simulation's involved or ground nets, skipping");
            continue;
        }

        const auto [type, unitLetter] = *kind;
        const std::optional<double> parsedValue = parseComponentValue(footprint.value, unitLetter);
        if (!parsedValue.has_value()) {
            logWarning("Simulation \"" + sim.name() + "\": component " + footprint.reference +
                       " is on a simulated net but its value \"" + footprint.value + "\" couldn't be parsed -- skipping");
            continue;
        }

        auto pad1Result = libkicad_query::resolvePin(
            paths, footprint.reference, pin1.number,
            "Simulation \"" + sim.name() + "\": lumped component " + footprint.reference + " pin " + pin1.number);
        if (!pad1Result) {
            return std::unexpected(std::move(pad1Result).error());
        }
        auto pad2Result = libkicad_query::resolvePin(
            paths, footprint.reference, pin2.number,
            "Simulation \"" + sim.name() + "\": lumped component " + footprint.reference + " pin " + pin2.number);
        if (!pad2Result) {
            return std::unexpected(std::move(pad2Result).error());
        }
        const PadIdentity& pad1 = *pad1Result;
        const PadIdentity& pad2 = *pad2Result;

        if (pad1.copperLayerName != pad2.copperLayerName) {
            logWarning("Simulation \"" + sim.name() + "\": component " + footprint.reference +
                       " has pins on different copper layers -- skipping (not supported)");
            continue;
        }
        const std::string layerFileName = _normalizeLayerName(pad1.copperLayerName);
        const std::optional<std::int32_t> layer = config.metalLayerIndexForFileName(layerFileName);
        if (!layer.has_value()) {
            logWarning("Simulation \"" + sim.name() + "\": component " + footprint.reference + ": copper layer \"" +
                       pad1.copperLayerName + "\" not found in stackup -- skipping");
            continue;
        }

        const Position pos1 = _padPositionInSimFrame(pad1, edgeCutsOrigin);
        const Position pos2 = _padPositionInSimFrame(pad2, edgeCutsOrigin);
        const double angle = std::atan2(pos2.y() - pos1.y(), pos2.x() - pos1.x());
        const std::optional<double> snapped = _snapToCardinal(angle, kDirectionToleranceDegrees);
        if (!snapped.has_value()) {
            logWarning("Simulation \"" + sim.name() + "\": component " + footprint.reference +
                       "'s two pads aren't axis-aligned -- skipping (not supported)");
            continue;
        }

        LumpedComponentConfig component;
        component.setReference(footprint.reference);
        component.setType(type);
        switch (type) {
        case LumpedComponentType::Resistor:
            component.setResistance(*parsedValue);
            break;
        case LumpedComponentType::Inductor:
            component.setInductance(*parsedValue);
            break;
        case LumpedComponentType::Capacitor:
            component.setCapacitance(*parsedValue);
            break;
        }
        component.setPosition1({pos1.x(), pos1.y()});
        component.setPosition2({pos2.x(), pos2.y()});
        component.setDirection(*snapped);
        component.setLayer(*layer);
        sim.lumpedComponents().push_back(std::move(component));
    }
    return {};
}

std::expected<void, std::string> _resolvePortRef(const PathsConfig& paths, PortRef& ref, const _PortIndex& index,
                                                  const std::vector<std::string>& involvedNets,
                                                  const std::string& simName, const std::string& fieldLabel) {
    auto resolvedResult =
        libkicad_query::resolvePin(paths, ref.footprint(), ref.pin(),
                                    "Simulation \"" + simName + "\": " + fieldLabel + " (" + ref.footprint() + "." +
                                        ref.pin() + ")");
    if (!resolvedResult) return std::unexpected(std::move(resolvedResult).error());
    const PadIdentity& resolved = *resolvedResult;
    if (std::find(involvedNets.begin(), involvedNets.end(), resolved.netName) == involvedNets.end()) {
        return std::unexpected("Simulation \"" + simName + "\": " + fieldLabel + " (" + ref.footprint() + "." +
                                ref.pin() + ", net \"" + _unescapeForDisplay(resolved.netName) +
                                "\") is not part of this simulation's involved_nets");
    }
    const std::optional<std::int32_t> portIndex = index.find(resolved.footprintRef, resolved.padNumber);
    if (!portIndex.has_value()) {
        return std::unexpected("Simulation \"" + simName + "\": " + fieldLabel + " (" + ref.footprint() + "." +
                                ref.pin() + ") did not resolve to a placed port");
    }
    ref.setResolvedIndex(*portIndex);
    return {};
}

} // namespace

std::expected<void, std::string> resolveSimulationPorts(EMSConfig& config, const PathsConfig& paths) {
    const double tessellationTolerance = static_cast<double>(config.pixelSize()) * constants::unitMultiplier;
    auto edgeCutsOriginResult = _edgeCutsOrigin(paths.fabDir, tessellationTolerance);
    if (!edgeCutsOriginResult) return std::unexpected(std::move(edgeCutsOriginResult).error());
    const Position& edgeCutsOrigin = *edgeCutsOriginResult;

    for (SimulationConfig& sim : config.simulations()) {
        // ports() is entirely derived by this function (see its own doc comment) -- resolving must
        // be idempotent, since both the Geometry and Simulation Results steps independently call
        // this on the same long-lived, in-memory EMSConfig. Without clearing first, a second call
        // (e.g. visiting Results after Geometry, or any cache-invalidating edit triggering a re-run)
        // would push_back a full second copy of every port onto the first, compounding on every
        // subsequent call -- and since portIndex below is rebuilt from 0 each call while ports()
        // itself kept growing, excitation/trace/diff-pair resolved indices would silently point at
        // the wrong (stale, duplicate) entries too.
        sim.ports().clear();
        _CopperLayerCache layerCache;
        _PortIndex portIndex;

        // Map from resolved net name -> which InvolvedNetConfig entry claimed it (for error
        // messages and to detect conflicting duplicate claims), preserving resolution order.
        std::unordered_map<std::string, const InvolvedNetConfig*> netOwner;
        std::vector<std::string> orderedNets;

        for (const InvolvedNetConfig& entry : sim.involvedNets()) {
            auto nets = libkicad_query::resolveInvolvedNetNames(paths, entry);
            if (!nets) return std::unexpected(std::move(nets).error());
            for (const std::string& netName : *nets) {
                const auto [it, inserted] = netOwner.emplace(netName, &entry);
                if (!inserted) {
                    return std::unexpected("Simulation \"" + sim.name() + "\": net \"" + _unescapeForDisplay(netName) +
                                            "\" is claimed by more than one involved_nets entry");
                }
                orderedNets.push_back(netName);
            }
        }
        if (orderedNets.empty()) {
            return std::unexpected("Simulation \"" + sim.name() + "\": involved_nets resolved to zero nets");
        }
        sim.resolvedNets() = orderedNets;

        // Every pad targeted by a SimulationConfig-level excitation always gets a PortConfig (with
        // absorbSignal()==true) regardless of that net's own Probe/Absorb Signal selections -- see
        // InvolvedNetConfig's own doc comment. footprint()/pin() are plain, unresolved identifiers
        // here (not yet matched to a specific pad), but that's exactly what pad.footprintRef/
        // pad.padNumber already are too, so a direct string-pair comparison below is enough --
        // resolvePin() is only needed later (in the excitations loop) to validate/derive the
        // driven port's own index, not to answer this membership question.
        std::set<std::pair<std::string, std::string>> excitationTargets;
        for (const ExcitationConfig& excitation : sim.excitations()) {
            excitationTargets.emplace(excitation.footprint(), excitation.pin());
        }

        for (const std::string& netName : orderedNets) {
            const InvolvedNetConfig& entry = *netOwner.at(netName);
            auto padsResult = libkicad_query::padsOnNet(
                paths, netName,
                "Simulation \"" + sim.name() + "\": enumerating pads on net \"" + _unescapeForDisplay(netName) + "\"");
            if (!padsResult) return std::unexpected(std::move(padsResult).error());
            const std::vector<PadIdentity>& pads = *padsResult;

            if (pads.size() > 32) {
                logWarning("Simulation \"" + sim.name() + "\": net \"" + _unescapeForDisplay(netName) + "\" resolved to " +
                           std::to_string(pads.size()) +
                           " pads -- confirm this is intended (a broad net_class or a power/ground net will "
                           "place a port, and run an FDTD excitation, on every one of them)");
            }

            for (const PadIdentity& pad : pads) {
                // Probe/Absorb Signal per pin (see InvolvedNetConfig's own doc comment for the
                // legacy-vs-explicit resolution modes this implements) -- this pad's net is
                // involved, but unless this specific pad is probed, excited, or (in legacy mode)
                // not excluded, it gets nothing at all: no port, no probe.
                const bool isExcitationTarget =
                    excitationTargets.find({pad.footprintRef, pad.padNumber}) != excitationTargets.end();
                std::optional<bool> absorb;
                if (!entry.hasExplicitPinSelections()) {
                    if (!entry.isPinExcluded(pad.footprintRef, pad.padNumber)) {
                        absorb = true;
                    }
                } else {
                    absorb = entry.probedPinAbsorbs(pad.footprintRef, pad.padNumber);
                }
                if (!absorb.has_value() && !isExcitationTarget) {
                    continue;
                }
                // netName un-escaped here, not left for each individual message to handle -- portLabel
                // is also persisted as PortConfig::name() (see port.setName(portLabel) below), reused
                // later as a plain display label (e.g. Simulation Results' own port/chart labeling),
                // not just built fresh for one-off error text.
                const std::string portLabel =
                    pad.footprintRef + " pin " + pad.padNumber + " (" + _unescapeForDisplay(netName) + ")";
                const Position positionSim = _padPositionInSimFrame(pad, edgeCutsOrigin);
                const std::string layerFileName = _normalizeLayerName(pad.copperLayerName);

                const std::optional<std::int32_t> layer = config.metalLayerIndexForFileName(layerFileName);
                if (!layer.has_value()) {
                    return std::unexpected(
                        "Port " + portLabel + ": copper layer \"" + pad.copperLayerName +
                        "\" not found in stackup (through-hole pads, which span every copper layer, aren't "
                        "supported yet -- v1 requires SMD pads)");
                }

                // Checked in this order: a per-pad override (this exact footprint+pin) first, then
                // the net-wide override, then auto-derivation -- see PinDirectionOverride's own doc
                // comment for why a single net-wide value can be wrong for one end of a routed net
                // while correct for the other, and per-pad is the escape hatch for that case
                // specifically, without disturbing whichever end the net-wide value already suits.
                double direction = 0;
                if (const auto pinOverride = entry.pinDirectionOverride(pad.footprintRef, pad.padNumber);
                    pinOverride.has_value()) {
                    direction = *pinOverride;
                } else if (entry.direction().has_value()) {
                    direction = *entry.direction();
                } else {
                    auto derived =
                        _deriveDirection(layerCache, paths.fabDir, positionSim, edgeCutsOrigin, pad.widthMm,
                                          pad.heightMm, netName, layerFileName, portLabel, tessellationTolerance);
                    if (!derived) return std::unexpected(std::move(derived).error());
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
                // Not every port on an involved net should be excited -- only the ones the user
                // actually configured an excitation for (see the excitations loop below, which
                // flips this back on for whichever ports it resolves to). SimulationResult::run()
                // spawns one FDTD worker process per excited port, so marking every involved-net
                // port excited by default -- as this used to do -- silently multiplied simulation
                // time by however many pads happened to be on the involved nets, not by how many
                // the user actually asked to drive.
                port.setExcite(false);
                // isExcitationTarget wins over a false/absent probedPins() entry -- an excited pad
                // always gets the full absorbing structure (see PortConfig::absorbSignal()'s own
                // doc comment); the excitations loop below flips excite() itself back on for
                // whichever port index this pad resolves to.
                port.setAbsorbSignal(isExcitationTarget || absorb.value_or(true));
                // width/length deliberately left unscaled here, matching entry.length()/entry.width()'s
                // own file units -- SimulationConfig::scaleToSimulationUnits() (called once, by
                // EMSConfig::scaledToSimulationUnits(), at the FDTD-facing boundary) scales every
                // resolved port along with the rest of the config. position is already in simulation
                // units (see positionSim above), since it comes from board/gerber geometry, not a
                // JSON field this config's own scaling concerns itself with.

                portIndex.entries.emplace_back(pad.footprintRef, pad.padNumber);
                sim.ports().push_back(std::move(port));
            }
        }

        for (ExcitationConfig& excitation : sim.excitations()) {
            auto resolvedResult = libkicad_query::resolvePin(
                paths, excitation.footprint(), excitation.pin(),
                "Simulation \"" + sim.name() + "\": excitation on " + excitation.footprint() + "." +
                    excitation.pin());
            if (!resolvedResult) return std::unexpected(std::move(resolvedResult).error());
            const PadIdentity& resolved = *resolvedResult;
            if (std::find(orderedNets.begin(), orderedNets.end(), resolved.netName) == orderedNets.end()) {
                return std::unexpected("Simulation \"" + sim.name() + "\": excitation targets " +
                                        excitation.footprint() + "." + excitation.pin() + " (net \"" +
                                        _unescapeForDisplay(resolved.netName) +
                                        "\") but that net is not part of this simulation's involved_nets");
            }
            const std::optional<std::int32_t> index = portIndex.find(resolved.footprintRef, resolved.padNumber);
            if (!index.has_value()) {
                return std::unexpected("Simulation \"" + sim.name() + "\": excitation on " + excitation.footprint() +
                                        "." + excitation.pin() + " did not resolve to a placed port");
            }
            excitation.setDrivenPortIndex(*index);
            sim.ports()[static_cast<std::size_t>(*index)].setExcite(true);
        }

        for (SingleEndedConfig& trace : sim.traces()) {
            if (auto r = _resolvePortRef(paths, trace.start(), portIndex, orderedNets, sim.name(), "trace start");
                !r) {
                return r;
            }
            if (auto r = _resolvePortRef(paths, trace.stop(), portIndex, orderedNets, sim.name(), "trace stop"); !r) {
                return r;
            }
            trace.postInit();
        }

        for (DifferentialPairConfig& pair : sim.diffPairs()) {
            if (auto r = _resolvePortRef(paths, pair.startP(), portIndex, orderedNets, sim.name(),
                                          "differential pair start_p");
                !r) {
                return r;
            }
            if (auto r = _resolvePortRef(paths, pair.stopP(), portIndex, orderedNets, sim.name(),
                                          "differential pair stop_p");
                !r) {
                return r;
            }
            if (auto r = _resolvePortRef(paths, pair.startN(), portIndex, orderedNets, sim.name(),
                                          "differential pair start_n");
                !r) {
                return r;
            }
            if (auto r = _resolvePortRef(paths, pair.stopN(), portIndex, orderedNets, sim.name(),
                                          "differential pair stop_n");
                !r) {
                return r;
            }
            pair.postInit();
        }

        if (auto r = _resolveLumpedComponents(config, sim, paths, edgeCutsOrigin, orderedNets); !r) {
            return r;
        }
    }
    return {};
}

} // namespace gerber2ems
