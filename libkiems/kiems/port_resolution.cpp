#include "port_resolution.hpp"

#include <algorithm>
#include <cctype>
#include <cmath>
#include <cstdlib>
#include <expected>
#include <iomanip>
#include <limits>
#include <map>
#include <numbers>
#include <optional>
#include <sstream>
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
#include "../../libkicad/libkicad.hpp"
#include "board_slicing.hpp"
#include "logging.hpp"
#include "net_name.hpp"
#include "paths_config.hpp"

namespace kiems {

using namespace Cu;

std::string differentialPairBaseName(std::string_view positiveNet, std::string_view negativeNet) {
    struct SuffixPair {
        std::string_view positive;
        std::string_view negative;
    };
    // Check the more-specific underscore convention before bare P/N so `ABC_P` does not retain
    // the underscore. The + / - convention is the common KiCad spelling.
    constexpr SuffixPair suffixes[] = {{"+", "-"}, {"_P", "_N"}, {"P", "N"}};
    for (const SuffixPair& suffix : suffixes) {
        if (!positiveNet.ends_with(suffix.positive) || !negativeNet.ends_with(suffix.negative)) {
            continue;
        }
        const std::string_view positiveBase = positiveNet.substr(0, positiveNet.size() - suffix.positive.size());
        const std::string_view negativeBase = negativeNet.substr(0, negativeNet.size() - suffix.negative.size());
        if (!positiveBase.empty() && positiveBase == negativeBase) {
            return std::string(positiveBase);
        }
    }
    return std::string(positiveNet) + " / " + std::string(negativeNet);
}

bool pinTypeAbsorbsByDefault(std::string_view pinType, bool directlyConnectedToGround) {
    if (directlyConnectedToGround) return false;
    return pinType == "input" || pinType == "bidirectional" || pinType == "power_in";
}

namespace {

using PadIdentity = libkicad::PadPosition;

std::string _normalizeLayerName(std::string name) {
    std::replace(name.begin(), name.end(), '.', '_');
    return name;
}

// KiCad reserves a bare "/" as its hierarchical-sheet path separator within a net name, so a net
// actually named with a literal slash in it comes back from libkicad already escaped as "{slash}"
// (see KiEMS/NetNameFormatting.swift's own doc comment for the fuller picture, including
// the other markup tokens KiCad net names can carry -- this is deliberately just the one token that
// renders wrong as plain, unformatted text, which is all a std::string error/log message ever is).
// Every net name this file interpolates into a human-facing message should be passed through this
// first -- but never the net name used as an actual ki lookup KEY, which must stay in
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

double _mmToSimUnits(double mm);

std::expected<Position, std::string> _edgeCutsOrigin(const PathsConfig& paths) {
    auto geometry = libkicad::boardGeometry(paths.kicadBoardPaths());
    if (!geometry) {
        return std::unexpected(std::move(geometry).error());
    }
    double xMin = std::numeric_limits<double>::infinity();
    double yMin = std::numeric_limits<double>::infinity();
    for (const libkicad::PolygonLoop& loop : geometry->outline) {
        for (const auto& [xMm, yMm] : loop.pointsMm) {
            xMin = std::min(xMin, _mmToSimUnits(xMm));
            yMin = std::min(yMin, _mmToSimUnits(yMm));
        }
    }
    if (!std::isfinite(xMin) || !std::isfinite(yMin)) {
        return std::unexpected("KiCad board geometry has no usable Edge.Cuts points");
    }
    return Position(xMin, yMin);
}

// mm -> simulation units, matching FileFormat's own gerber-value scale (gerber_io.cpp) and the
// identical conversion getPortsFromFile used to apply to pos.csv's mm values.
double _mmToSimUnits(double mm) { return mm / 1000.0 / constants::baseUnit * constants::unitMultiplier; }

Position _padPositionInSimFrame(const PadIdentity& pad, const Position& edgeCutsOrigin) {
    return Position(_mmToSimUnits(pad.xMm) - edgeCutsOrigin.x(), _mmToSimUnits(pad.yMm) - edgeCutsOrigin.y());
}

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
// own curved lead-in extended further than the previous, smaller 0.1mm margin reached. Used by
// _findTraceProbePoints()'s own tooCloseToPad() below, to reject an impedance-probe candidate run
// that passes too close to a pad rather than a genuinely clear straight section of trace.
constexpr double kPadToleranceMarginMm = 0.4;
constexpr double kDirectionToleranceDegrees = 5.0;

double _padSearchToleranceSimUnits(double padWidthMm, double padHeightMm) {
    const double halfDiagonalMm = std::hypot(padWidthMm, padHeightMm) / 2.0;
    return std::max(kMinPositionToleranceSimUnits, _mmToSimUnits(halfDiagonalMm + kPadToleranceMarginMm));
}

/// Upper bound on how many trace-impedance probes InvolvedNetConfig::probeImpedance() places on any
/// one net -- bounds both simulation port count (each probe is its own FDTD measurement point) and
/// results-view clutter. A handful of samples along a net's straight runs is enough to see whether
/// its measured impedance is flat (well-matched line) or spread out (a discontinuity somewhere on
/// it); more than a few adds little.
constexpr std::size_t kMaxTraceProbesPerNet = 3;

/// One candidate trace-impedance probe location -- the midpoint of a straight, pad-clear run of
/// `netName`'s own routed copper, wide/oriented/layered to match the real trace there.
struct _TraceProbeCandidate {
    Position position;
    double direction; // PortConfig::direction()'s own convention (0/90/180/270 degrees)
    double width;     // config/file units (microns), scaled exactly once with the other ports
    double length;    // heuristic measurement span, also in config/file units
    std::int32_t layer;
};

/// Finds up to kMaxTraceProbesPerNet reasonable spots to place a non-loading impedance probe on
/// `netName`'s own routed copper -- see Simulation::addImpedanceProbe(). Walks KiCad's semantic
/// straight-track primitives, chains consecutive same-direction/same-width segments into maximal
/// straight runs (a bend, via, or aperture change naturally ends a run, since none of those keep
/// both direction and width identical across the join), discards any run too short to safely fit a
/// probe or whose midpoint sits too close to one of this net's own pads (a probe right at a
/// component termination would measure near-field fringing, not the line's characteristic
/// impedance), and returns the longest surviving runs' midpoints, longest first.
std::expected<std::vector<_TraceProbeCandidate>, std::string> _findTraceProbePoints(
    const PathsConfig& paths, const Position& edgeCutsOrigin, const EMSConfig& config,
    const std::string& netName, const std::vector<PadIdentity>& pads) {
    struct _Run {
        Position start;
        Position end;
        double direction;
        double width;
        std::int32_t layer;
        double length;
    };
    struct _Seg {
        Position start;
        Position stop;
        double width;
        double direction;
    };

    auto tracksResult = libkicad::tracksOnNet(paths.kicadBoardPaths(), netName);
    if (!tracksResult) return std::unexpected(std::move(tracksResult).error());

    // KiCad track primitives carry the routing semantics Gerber loses: true segment endpoints,
    // designed width and layer. Gerber remains authoritative for the FDTD copper polygons; these
    // primitives are only the probe-placement guide.
    std::vector<_Seg> segs;
    std::vector<std::int32_t> segLayers;
    for (const libkicad::TrackSegment& track : *tracksResult) {
        Position start(_mmToSimUnits(track.startXMm) - edgeCutsOrigin.x(),
                       _mmToSimUnits(track.startYMm) - edgeCutsOrigin.y());
        Position stop(_mmToSimUnits(track.endXMm) - edgeCutsOrigin.x(),
                      _mmToSimUnits(track.endYMm) - edgeCutsOrigin.y());
        const std::optional<double> snapped =
            _snapToCardinal(std::atan2(stop.y() - start.y(), stop.x() - start.x()), kDirectionToleranceDegrees);
        const std::optional<std::int32_t> layer =
            config.metalLayerIndexForFileName(_normalizeLayerName(track.copperLayerName));
        if (!snapped.has_value() || !layer.has_value() || track.widthMm <= 0) {
            continue;
        }
        // A straight line's propagation orientation is unsigned for placement. Canonicalizing to
        // +X/+Y also lets reversed KiCad segments join the same run.
        const double direction = (*snapped == 90 || *snapped == 270) ? 90.0 : 0.0;
        if ((direction == 0 && start.x() > stop.x()) || (direction == 90 && start.y() > stop.y())) {
            std::swap(start, stop);
        }
        segs.push_back({start, stop, _mmToSimUnits(track.widthMm), direction});
        segLayers.push_back(*layer);
    }

    std::vector<_Run> runs;
    std::vector<bool> used(segs.size(), false);
    for (std::size_t i = 0; i < segs.size(); ++i) {
        if (used[i]) continue;
        Position runStart = segs[i].start;
        Position runEnd = segs[i].stop;
        const double direction = segs[i].direction;
        const double width = segs[i].width;
        const std::int32_t layer = segLayers[i];
        used[i] = true;
        bool extended = true;
        while (extended) {
            extended = false;
            for (std::size_t j = 0; j < segs.size(); ++j) {
                if (used[j] || segLayers[j] != layer || segs[j].direction != direction ||
                    std::abs(segs[j].width - width) > 1e-6) {
                    continue;
                }
                const bool collinear = direction == 0
                    ? std::abs(segs[j].start.y() - runStart.y()) <= kMinPositionToleranceSimUnits
                    : std::abs(segs[j].start.x() - runStart.x()) <= kMinPositionToleranceSimUnits;
                if (!collinear) continue;
                const double joinsEnd = std::hypot(segs[j].start.x() - runEnd.x(), segs[j].start.y() - runEnd.y());
                const double joinsStart =
                    std::hypot(segs[j].stop.x() - runStart.x(), segs[j].stop.y() - runStart.y());
                if (joinsEnd <= kMinPositionToleranceSimUnits) {
                    runEnd = segs[j].stop;
                } else if (joinsStart <= kMinPositionToleranceSimUnits) {
                    runStart = segs[j].start;
                } else {
                    continue;
                }
                used[j] = true;
                extended = true;
            }
        }
        runs.push_back({runStart, runEnd, direction, width, layer,
                        std::hypot(runEnd.x() - runStart.x(), runEnd.y() - runStart.y())});
    }

    auto tooCloseToPad = [&](const Position& point) {
        for (const PadIdentity& pad : pads) {
            const Position padPos = _padPositionInSimFrame(pad, edgeCutsOrigin);
            const double tolerance = _padSearchToleranceSimUnits(pad.widthMm, pad.heightMm);
            if (std::hypot(point.x() - padPos.x(), point.y() - padPos.y()) <= tolerance) {
                return true;
            }
        }
        return false;
    };

    std::vector<_Run> candidates;
    for (const _Run& run : runs) {
        // Enough room for MSLPort's own 3-plane measurement span plus margin from both ends (see
        // Simulation::addImpedanceProbe()) -- a shorter run either can't fit a probe at all or would
        // place one too close to whatever's at either end (a pad, a bend, a via).
        // Four trace widths provides transverse/longitudinal separation around the three voltage
        // planes while still admitting compact fan-out routes (TestSim's pre-capacitor USB run is
        // about 0.68 mm long). The probe's own span is chosen below; no user Length field applies.
        const double minLength = std::max(4.0 * run.width, _mmToSimUnits(0.5));
        if (run.length < minLength) {
            continue;
        }
        const Position mid((run.start.x() + run.end.x()) / 2.0, (run.start.y() + run.end.y()) / 2.0);
        if (tooCloseToPad(mid)) {
            continue;
        }
        candidates.push_back(run);
    }
    std::sort(candidates.begin(), candidates.end(), [](const _Run& a, const _Run& b) { return a.length > b.length; });

    std::vector<_TraceProbeCandidate> result;
    for (const _Run& run : candidates) {
        if (result.size() >= kMaxTraceProbesPerNet) {
            break;
        }
        const Position mid((run.start.x() + run.end.x()) / 2.0, (run.start.y() + run.end.y()) / 2.0);
        // PortConfig widths are still in microns here; scaledToSimulationUnits() multiplies them
        // once later. `run.width` is already in simulation units, so undo only that multiplier.
        const double probeLength = std::min(_mmToSimUnits(1.0), run.length * 0.8);
        result.push_back({mid, run.direction, run.width / constants::unitMultiplier,
                          probeLength / constants::unitMultiplier, run.layer});
    }
    return result;
}

/// One (footprintRef, padNumber) -> resolved port index -- built once per simulation while placing
/// ports, then reused to resolve ExcitationConfig/PortRef targets without re-deriving identity.
struct _PortIndex {
    std::optional<std::int32_t> find(const std::string& footprintRef, const std::string& padNumber) const {
        for (const Entry& entry : entries) {
            if (entry.footprintRef == footprintRef && entry.padNumber == padNumber) {
                return entry.portIndex;
            }
        }
        return std::nullopt;
    }

    struct Entry {
        std::string footprintRef;
        std::string padNumber;
        std::int32_t portIndex = 0;
    };
    // Trace-impedance probes also occupy SimulationConfig::ports(), but are intentionally absent
    // here because they aren't pad-anchored. Therefore this vector is not positionally parallel to
    // ports(): every entry must retain the real port index it referred to at insertion time.
    std::vector<Entry> entries;
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
// matching KiEMS/ComponentCategory.swift's effective behavior for these three single-
// letter designators, without porting its whole IEEE-315 category table.
std::optional<std::pair<LumpedComponentType, ComponentUnit>> _lumpedComponentKind(const std::string& letterPrefix) {
    if (letterPrefix == "R") {
        return std::make_pair(LumpedComponentType::Resistor, ComponentUnit::Resistance);
    }
    if (letterPrefix == "L") {
        return std::make_pair(LumpedComponentType::Inductor, ComponentUnit::Inductance);
    }
    if (letterPrefix == "C") {
        return std::make_pair(LumpedComponentType::Capacitor, ComponentUnit::Capacitance);
    }
    return std::nullopt;
}

// Auto-discovers every 2-pin R/L/C on the board whose both pins sit on any net included in `sim`
// (at either SimulationNet or GeometryOnly level), or its ground net, and folds each into a
// LumpedComponentConfig -- see that type's own doc
// comment. Silently skips anything not R/L/C-with-2-qualifying-pins (the overwhelming majority of
// components on any real board); logs and skips a component that *is* in scope but couldn't
// actually be modeled (unparseable value, pins on different/unknown layers, non-axis-aligned pins).
std::expected<void, std::string> _resolveLumpedComponents(const EMSConfig& config, SimulationConfig& sim,
                                                            const PathsConfig& paths, const Position& edgeCutsOrigin,
                                                            const std::vector<std::string>& orderedNets) {
    sim.lumpedComponents().clear();

    auto groundNetsResult = resolveGroundNetNames(paths, sim.groundNet());
    if (!groundNetsResult) {
        return std::unexpected(std::move(groundNetsResult).error());
    }
    std::unordered_set<std::string> membership(orderedNets.begin(), orderedNets.end());
    // orderedNets deliberately contains only SimulationNet entries because it also drives ports.
    // Lumped components have broader geometry semantics: a passive between any two nets whose
    // copper is included must exist in the model, even when one or both nets are GeometryOnly.
    for (const InvolvedNetConfig& entry : sim.involvedNets()) {
        if (entry.inclusionLevel() != NetInclusionLevel::GeometryOnly) continue;
        auto nets = resolveInvolvedNetNames(paths, entry);
        if (!nets) return std::unexpected(std::move(nets).error());
        membership.insert(nets->begin(), nets->end());
    }
    membership.insert(groundNetsResult->begin(), groundNetsResult->end());

    auto footprintsResult = libkicad::footprints(paths.kicadBoardPaths());
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
                     "\") -- neither/only one net is included in this simulation or its ground nets, skipping");
            continue;
        }

        const auto [type, unit] = *kind;
        const std::optional<double> parsedValue = parseSensibleComponentValue(footprint.value, unit);
        if (!parsedValue.has_value()) {
            logWarning("Simulation \"" + sim.name() + "\": component " + footprint.reference +
                       " is on a simulated net but its value \"" + footprint.value +
                       "\" isn't a usable finite value -- skipping");
            continue;
        }

        auto pad1Result = libkicad::resolvePin(paths.kicadBoardPaths(), footprint.reference, pin1.number);
        if (!pad1Result) {
            return std::unexpected(std::move(pad1Result).error());
        }
        auto pad2Result = libkicad::resolvePin(paths.kicadBoardPaths(), footprint.reference, pin2.number);
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

        LumpedComponentConfig component;
        component.setReference(footprint.reference);
        component.setType(type);
        component.setNet1(_unescapeForDisplay(pin1.netName));
        component.setNet2(_unescapeForDisplay(pin2.netName));
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
        component.setLayer(*layer);

        if (snapped.has_value()) {
            component.setDirection(*snapped);
        } else {
            // Neither Operator_Ext_LumpedRLC nor CSPropLumpedElement has any concept of a "diagonal"
            // element -- a lumped component is a modification to one E-field edge's own update
            // equation along a single Cartesian axis, not a filled 3D region like real copper, which
            // staircases across a Yee grid automatically just by being a solid volume spanning many
            // cells. Route an L-shaped bridge through a synthetic corner instead -- each leg
            // individually cardinal-aligned even though the true pad1->pad2 line isn't (see
            // LumpedComponentConfig::cornerBridge()'s own doc comment for why this replaced an
            // earlier, geometry-free "remote pair" mechanism, and why Simulation::addLumpedComponents()
            // routes it through open airspace above/below the board rather than along its own copper
            // layer -- a real board very commonly has a ground pour covering most of a layer near any
            // given component, which would make an on-layer route fail an interference check almost
            // everywhere; nothing occupies the airspace just off the board, so no such check is needed
            // here at all, and either of the two possible corners works equally well). Arbitrarily
            // picks (position2.x, position1.y) as the corner.
            const Position corner(pos2.x(), pos1.y());
            component.setCornerBridge(true);
            component.setBridgeCorner({corner.x(), corner.y()});
            component.setDirection(pos1.x() < corner.x() ? 0.0 : 180.0);
            component.setDirection2(corner.y() < pos2.y() ? 90.0 : 270.0);
            logInfo("Simulation \"" + sim.name() + "\": component " + footprint.reference +
                     "'s two pads aren't axis-aligned -- bridging via a synthetic corner at (" +
                     std::to_string(corner.x()) + ", " + std::to_string(corner.y()) + ") through open airspace");
        }
        sim.lumpedComponents().push_back(std::move(component));
    }
    return {};
}

std::expected<void, std::string> _resolvePortRef(const PathsConfig& paths, PortRef& ref, const _PortIndex& index,
                                                  const std::vector<std::string>& involvedNets,
                                                  const std::string& simName, const std::string& fieldLabel) {
    auto resolvedResult = libkicad::resolvePin(paths.kicadBoardPaths(), ref.footprint(), ref.pin());
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

// A net is connected to another (across DifferentialPairConfig::positiveNets()/negativeNets())
// only through a supported two-pin series R/L/C. Board copper on one net obviously stays connected
// to itself, but two *different* nets (the common AC-coupling-cap case) share no copper at all.
// Deliberately do not union every pin of an arbitrary multi-pin footprint: doing that would claim
// every lane, supply, and ground touching a mux/redriver/ESD array was one conductive path. Built
// once per resolveSimulationPorts() call (not once per pair) since it only depends on the board.
class _NetConnectivity {
public:
    static std::expected<_NetConnectivity, std::string> build(const PathsConfig& paths) {
        auto fps = libkicad::footprints(paths.kicadBoardPaths());
        if (!fps) return std::unexpected(std::move(fps).error());
        _NetConnectivity nc;
        for (const libkicad::FootprintInfo& fp : *fps) {
            if (fp.pins.size() != 2 || !_lumpedComponentKind(_letterPrefix(fp.reference)).has_value()) continue;
            const std::string& first = fp.pins[0].netName;
            const std::string& second = fp.pins[1].netName;
            // Ports and involved-net metadata use the display spelling internally after board
            // lookup, so connectivity must use that same canonical spelling as well. In
            // particular, KiCad's literal "{slash}" escape must not split one logical net into
            // two identities during differential-pair validation/grouping.
            if (!first.empty() && !second.empty()) {
                nc._union(_unescapeForDisplay(first), _unescapeForDisplay(second));
            }
        }
        return nc;
    }

    bool connected(const std::string& a, const std::string& b) { return _find(a) == _find(b); }

private:
    std::string _find(const std::string& x) {
        const auto it = _parent.find(x);
        if (it == _parent.end()) {
            _parent.emplace(x, x);
            return x;
        }
        if (it->second == x) return x;
        const std::string root = _find(it->second);
        _parent[x] = root;
        return root;
    }

    void _union(const std::string& a, const std::string& b) {
        const std::string ra = _find(a);
        const std::string rb = _find(b);
        if (ra != rb) _parent[ra] = rb;
    }

    std::unordered_map<std::string, std::string> _parent;
};

std::expected<std::vector<std::string>, std::string> _resolveDiffPairNetNames(
    const PathsConfig& paths, const std::vector<DiffPairNetMember>& members, const std::string& context) {
    std::vector<std::string> names;
    for (const DiffPairNetMember& member : members) {
        if (member.kind() == DiffPairNetKind::NetClass) {
            auto classNets = libkicad::netsInNetClass(paths.kicadBoardPaths(), *member.netClass());
            if (!classNets) return std::unexpected(std::move(classNets).error());
            for (const std::string& classNet : *classNets) {
                names.push_back(_unescapeForDisplay(classNet));
            }
        } else {
            names.push_back(_unescapeForDisplay(*member.net()));
        }
    }
    std::sort(names.begin(), names.end());
    names.erase(std::unique(names.begin(), names.end()), names.end());
    return names;
}

// Validates one half (positiveNets()/negativeNets()) of a differential pair: every net it names
// must actually be reachable from every other purely through component pins (see
// _NetConnectivity's own doc comment), and the excitation/probe pins already resolved for that
// half must each land on one of those nets -- otherwise the net list doesn't actually describe the
// path between them, and any downstream Sdd/impedance/combined-field result would silently be
// reporting across the wrong span of board. Returns a human-readable failure reason (soft failure
// -- caller marks the pair incorrect and logs a warning) or nullopt (valid); std::unexpected is
// reserved for a hard board-query failure (a net-class lookup subprocess failing outright), which
// aborts resolution entirely like every other libkicad call in this file.
std::expected<std::optional<std::string>, std::string> _validateDiffPairSide(
    const PathsConfig& paths, _NetConnectivity& connectivity, const std::vector<DiffPairNetMember>& netMembers,
    const std::string& excitationNet, const std::string& probeNet, const std::string& sideLabel,
    const std::string& context) {
    if (netMembers.empty()) {
        return sideLabel + " lists no nets";
    }
    auto namesResult = _resolveDiffPairNetNames(paths, netMembers, context);
    if (!namesResult) return std::unexpected(std::move(namesResult).error());
    const std::vector<std::string>& names = *namesResult;

    const auto contains = [&](const std::string& net) {
        return std::find(names.begin(), names.end(), net) != names.end();
    };
    if (!contains(excitationNet)) {
        return sideLabel + "'s excitation pin is on net \"" + _unescapeForDisplay(excitationNet) +
               "\", which isn't in its own net list";
    }
    if (!contains(probeNet)) {
        return sideLabel + "'s probe pin is on net \"" + _unescapeForDisplay(probeNet) +
               "\", which isn't in its own net list";
    }
    for (std::size_t i = 1; i < names.size(); ++i) {
        if (!connectivity.connected(names[0], names[i])) {
            return sideLabel + "'s nets \"" + _unescapeForDisplay(names[0]) + "\" and \"" +
                   _unescapeForDisplay(names[i]) +
                   "\" aren't connected by any component's pins -- every listed net must be joined to every "
                   "other by series components only";
        }
    }
    return std::nullopt;
}

} // namespace

bool geometryOnlyPinNeedsAbsorbingPort(const InvolvedNetConfig& entry,
                                       const std::string& footprint, const std::string& pin) {
    return entry.inclusionLevel() == NetInclusionLevel::GeometryOnly &&
           entry.probedPinAbsorbs(footprint, pin).value_or(false);
}

std::expected<void, std::string> resolveSimulationPorts(EMSConfig& config, const PathsConfig& paths) {
    auto edgeCutsOriginResult = _edgeCutsOrigin(paths);
    if (!edgeCutsOriginResult) return std::unexpected(std::move(edgeCutsOriginResult).error());
    const Position& edgeCutsOrigin = *edgeCutsOriginResult;

    // Built lazily, once, the first time any simulation actually has a differential pair to
    // validate -- it's one extra whole-board query (see _NetConnectivity::build()) that every
    // other simulation with diff pairs reuses, and simulations without any never pay for at all.
    std::optional<_NetConnectivity> netConnectivity;

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
        for (ExcitationConfig& excitation : sim.excitations()) {
            excitation.clearDrivenPortIndex();
        }
        std::erase_if(sim.diffPairs(), [](const DifferentialPairConfig& pair) { return pair.automatic(); });
        _PortIndex portIndex;

        auto groundNamesResult = resolveGroundNetNames(paths, sim.groundNet());
        if (!groundNamesResult) return std::unexpected(std::move(groundNamesResult).error());
        std::unordered_set<NetName, NetNameHash> groundNets;
        for (const std::string& name : *groundNamesResult) groundNets.insert(NetName(name));

        struct ExplicitAbsorbingChoice {
            bool enabled;
            const InvolvedNetConfig* source;
            int selectorPriority;
        };
        using PhysicalPin = std::pair<std::string, std::string>;
        std::map<PhysicalPin, ExplicitAbsorbingChoice> explicitAbsorbingChoices;
        for (const InvolvedNetConfig& entry : sim.involvedNets()) {
            const int priority = entry.kind() == NetSelectorKind::Net ? 1 : 0;
            for (const ProbedPin& pin : entry.probedPins()) {
                const PhysicalPin key{pin.footprint, pin.pin};
                const auto existing = explicitAbsorbingChoices.find(key);
                if (existing == explicitAbsorbingChoices.end() || priority >= existing->second.selectorPriority) {
                    explicitAbsorbingChoices.insert_or_assign(
                        key, ExplicitAbsorbingChoice{pin.absorbSignal, &entry, priority});
                }
            }
        }

        // Map from resolved net name -> which InvolvedNetConfig entry claimed it (for error
        // messages and to detect conflicting duplicate claims), preserving resolution order.
        std::unordered_map<std::string, const InvolvedNetConfig*> netOwner;
        std::vector<std::string> orderedNets;

        for (const InvolvedNetConfig& entry : sim.involvedNets()) {
            // GeometryOnly-kind entries ("Included in Simulation") deliberately never reach this
            // loop at all -- their whole point is to exist in the simulated geometry (handled
            // entirely by board_slicing.cpp/grid_gen.cpp's own separate treatment) without becoming
            // port/probe/excitation-eligible or entering resolvedNets(). Their pins can still get an
            // absorb-only termination port, but that's handled entirely by the separate pass just
            // below -- see its own doc comment. See NetInclusionLevel's own doc comment.
            if (entry.inclusionLevel() == NetInclusionLevel::GeometryOnly) {
                continue;
            }
            auto nets = resolveInvolvedNetNames(paths, entry);
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

        // GeometryOnly-kind entries ("Included in Simulation") never grow resolvedNets()/the hull --
        // that's still entirely handled by board_slicing.cpp/grid_gen.cpp's own separate treatment,
        // untouched by this pass -- but a pin explicitly marked absorb-only via setPinAbsorbOnly()
        // still needs a real resistive termination port, so an otherwise-completely-unmodeled
        // downstream trace (one running to an IC or resistor outside this simulation's own involved
        // set) doesn't behave as an open, fully-reflecting stub in the FDTD field. This is
        // deliberately a *separate*, narrower pass from the main per-pad loop below: it only ever
        // creates absorb-only (probe()==false) ports, never lets a GeometryOnly entry's pin become
        // excitation-eligible (excite() stays false, and these ports are never added to portIndex,
        // matching isTraceProbe() ports' own "not pad-anchored enough to be an excitation/PortRef
        // target" treatment). A stale/retained probe==true flag is intentionally ignored when
        // deciding whether to build the termination: the net cannot expose that probe while it is
        // geometry-only, but its independent Absorb choice still has to load the trace.
        std::vector<const InvolvedNetConfig*> geometryOnlyEntries;
        for (const InvolvedNetConfig& entry : sim.involvedNets()) {
            if (entry.inclusionLevel() == NetInclusionLevel::GeometryOnly) geometryOnlyEntries.push_back(&entry);
        }
        // Prefer a concrete net selector over a broad net class when both include the same pad.
        std::stable_sort(geometryOnlyEntries.begin(), geometryOnlyEntries.end(), [](const auto* lhs, const auto* rhs) {
            return lhs->kind() == NetSelectorKind::Net && rhs->kind() != NetSelectorKind::Net;
        });
        std::set<PhysicalPin> geometryAbsorbersAdded;
        for (const InvolvedNetConfig* entryPtr : geometryOnlyEntries) {
            const InvolvedNetConfig& entry = *entryPtr;
            auto nets = resolveInvolvedNetNames(paths, entry);
            if (!nets) return std::unexpected(std::move(nets).error());
            for (const std::string& netName : *nets) {
                // A broad geometry-only selector (typically a net class) can also cover a net that
                // another entry fully involves. That net's pads get their real ports from the main
                // per-pad loop below; terminating them here too would put a second lumped load on
                // the same pad, doubling every result column and loading the driven port.
                if (netOwner.contains(netName)) continue;
                auto padsResult = libkicad::padsOnNet(paths.kicadBoardPaths(), netName);
                if (!padsResult) return std::unexpected(std::move(padsResult).error());
                for (const PadIdentity& pad : *padsResult) {
                    const PhysicalPin pinKey{pad.footprintRef, pad.padNumber};
                    const auto explicitChoice = explicitAbsorbingChoices.find(pinKey);
                    const bool automatic = explicitChoice == explicitAbsorbingChoices.end();
                    const bool shouldAbsorb = automatic
                        ? pinTypeAbsorbsByDefault(pad.pinType, groundNets.contains(NetName(netName)))
                        : explicitChoice->second.enabled;
                    if (!shouldAbsorb || !geometryAbsorbersAdded.insert(pinKey).second) continue;
                    const InvolvedNetConfig& portEntry = automatic ? entry : *explicitChoice->second.source;
                    const Position positionSim = _padPositionInSimFrame(pad, edgeCutsOrigin);
                    const std::string layerFileName = _normalizeLayerName(pad.copperLayerName);
                    const std::optional<std::int32_t> layer = config.metalLayerIndexForFileName(layerFileName);
                    const std::string portLabel = pad.footprintRef + " pin " + pad.padNumber + " (" +
                                                   _unescapeForDisplay(netName) + ", absorb only)";
                    if (!layer.has_value()) {
                        return std::unexpected("Port " + portLabel + ": copper layer \"" + pad.copperLayerName +
                                                "\" not found in stackup (through-hole pads, which span every "
                                                "copper layer, aren't supported yet -- v1 requires SMD pads)");
                    }
                    // Only ever consumed by addResistivePort()/addPassiveProbe() (never
                    // addImpedanceProbe(), which derives its own direction independently from a
                    // routed track run, not from any pad) -- and both of those use it purely to
                    // orient/size a box to the pad's own real footprint, never as a genuine
                    // current-carrying axis (that's always Z; see either function's own doc
                    // comment). Falls back to the pad's own real rotation, not a trace-departure
                    // search: a pad with traces entering from more than one side has no single
                    // "departure direction" to search for in the first place, but its own physical
                    // rotation is always well-defined regardless of how many traces connect to it.
                    double direction = pad.orientationDeg;
                    if (const auto pinOverride = portEntry.pinDirectionOverride(pad.footprintRef, pad.padNumber);
                        pinOverride.has_value()) {
                        direction = *pinOverride;
                    } else if (portEntry.direction().has_value()) {
                        direction = *portEntry.direction();
                    }
                    PortConfig port;
                    port.setName(portLabel);
                    port.setFootprintRef(pad.footprintRef);
                    port.setPadNumber(pad.padNumber);
                    port.setNetName(_unescapeForDisplay(netName));
                    port.setPosition({positionSim.x(), positionSim.y()});
                    port.setDirection(direction);
                    port.setLayer(*layer);
                    port.setPlane(portEntry.plane());
                    port.setImpedance(automatic ? 45.0 :
                        portEntry.pinImpedance(pad.footprintRef, pad.padNumber).value_or(portEntry.impedance()));
                    if (portEntry.width().has_value()) {
                        port.setWidth(*portEntry.width());
                    } else {
                        const double padAngle = pad.orientationDeg * std::numbers::pi / 180.0;
                        const double transverseAngle = (direction + 90.0) * std::numbers::pi / 180.0;
                        const double relative = padAngle - transverseAngle;
                        const double transverseWidthMm = std::abs(std::cos(relative)) * pad.widthMm +
                                                          std::abs(std::sin(relative)) * pad.heightMm;
                        port.setWidth(transverseWidthMm * 1000.0);
                    }
                    const double padAngle = pad.orientationDeg * std::numbers::pi / 180.0;
                    const double longitudinalAngle = direction * std::numbers::pi / 180.0;
                    const double longitudinalRelative = padAngle - longitudinalAngle;
                    const double longitudinalLengthMm = std::abs(std::cos(longitudinalRelative)) * pad.widthMm +
                                                        std::abs(std::sin(longitudinalRelative)) * pad.heightMm;
                    port.setLength(longitudinalLengthMm * 1000.0);
                    port.setExcite(false);
                    port.setAbsorbSignal(true);
                    port.setProbe(false);
                    logInfo("Resolved geometry-only absorbing port \"" + portLabel + "\" at (" +
                            std::to_string(positionSim.x()) + ", " + std::to_string(positionSim.y()) +
                            "), layer " + std::to_string(*layer) + " -> plane " +
                            std::to_string(portEntry.plane()) + ", impedance " +
                            std::to_string(port.impedance()) + " ohms");
                    sim.ports().push_back(std::move(port));
                }
            }
        }

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
            auto padsResult = libkicad::padsOnNet(paths.kicadBoardPaths(), netName);
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
                std::optional<bool> isProbe;
                bool automaticAbsorber = false;
                const auto explicitChoice = explicitAbsorbingChoices.find(
                    PhysicalPin{pad.footprintRef, pad.padNumber});
                if (explicitChoice != explicitAbsorbingChoices.end()) {
                    absorb = explicitChoice->second.enabled;
                    isProbe = explicitChoice->second.source
                        ->probedPinIsProbe(pad.footprintRef, pad.padNumber).value_or(false);
                } else if (!entry.hasExplicitPinSelections()) {
                    // Legacy (opt-out) mode predates setPinAbsorbOnly() entirely -- every
                    // non-excluded pin is a full, reportable probe, same as it always was.
                    if (!entry.isPinExcluded(pad.footprintRef, pad.padNumber)) {
                        absorb = true;
                        isProbe = true;
                    }
                } else {
                    if (pinTypeAbsorbsByDefault(pad.pinType, groundNets.contains(NetName(netName)))) {
                        absorb = true;
                        isProbe = false;
                        automaticAbsorber = true;
                    }
                }
                // probe=false/absorb=false is a deliberately persisted no-port override (see
                // InvolvedNetConfig::setPinAbsorbOnly()). Presence in probedPins() alone is not
                // enough to build a port; either behavior must actually be enabled.
                if (!isExcitationTarget && !absorb.value_or(false) && !isProbe.value_or(false)) {
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
                // the net-wide override, then the pad's own real rotation -- see
                // PinDirectionOverride's own doc comment for why a single net-wide value can be
                // wrong for one end of a routed net while correct for the other, and per-pad is the
                // escape hatch for that case specifically, without disturbing whichever end the
                // net-wide value already suits.
                //
                // The fallback is the pad's own physical rotation, not a trace-departure search
                // (this used to call _deriveDirection(), which picks whichever nearby routed
                // segment happens to be nearest and cardinal-snapping) -- only ever consumed by
                // addResistivePort()/addPassiveProbe() below, both of which use it purely to
                // orient/size a box to the pad's own real footprint (current there is always
                // vertical, Z; see either function's own doc comment), never as a genuine
                // current-carrying axis the way addImpedanceProbe()'s own, entirely separate
                // direction resolution needs. A pad with traces entering from more than one side
                // has no single "departure direction" to search for in the first place -- its own
                // rotation is always well-defined regardless of how many traces connect to it, and
                // for the overwhelmingly common case of one trace per pad, a component's own
                // placement rotation already tracks its trace's departure closely in normal layout
                // practice anyway.
                double direction = pad.orientationDeg;
                if (const auto pinOverride = entry.pinDirectionOverride(pad.footprintRef, pad.padNumber);
                    pinOverride.has_value()) {
                    direction = *pinOverride;
                } else if (entry.direction().has_value()) {
                    direction = *entry.direction();
                }

                PortConfig port;
                port.setName(portLabel);
                port.setFootprintRef(pad.footprintRef);
                port.setPadNumber(pad.padNumber);
                port.setNetName(_unescapeForDisplay(netName));
                port.setPosition({positionSim.x(), positionSim.y()});
                port.setDirection(direction);
                port.setLayer(*layer);
                port.setPlane(entry.plane());
                port.setImpedance(automaticAbsorber ? 45.0 :
                    entry.pinImpedance(pad.footprintRef, pad.padNumber).value_or(entry.impedance()));
                port.setLength(entry.length());
                if (entry.width().has_value()) {
                    port.setWidth(*entry.width());
                } else {
                    // A component-facing lumped port sits directly on the pad and spans its real
                    // transverse copper extent. Project the rotated pad rectangle onto the axis
                    // perpendicular to the departing trace; this is exact for cardinal rectangular
                    // pads and a conservative axis-aligned span for rotated ones.
                    const double padAngle = pad.orientationDeg * std::numbers::pi / 180.0;
                    const double transverseAngle = (direction + 90.0) * std::numbers::pi / 180.0;
                    const double relative = padAngle - transverseAngle;
                    const double transverseWidthMm = std::abs(std::cos(relative)) * pad.widthMm +
                                                      std::abs(std::sin(relative)) * pad.heightMm;
                    port.setWidth(transverseWidthMm * 1000.0); // millimetres -> config microns
                }
                // A component-facing LumpedPort is a vertical sheet over the pad, so it needs the
                // pad's real extent along the departing trace as well as its transverse width. A
                // zero-thickness sheet in this direction only excites anything when a primary Yee
                // line happens to land on its exact coordinate; normal mesh deduplication can move
                // that line and leave Operator_Ext_Excitation with no cells at all. `length` used
                // to describe an MSL measurement span, but component ports no longer use MSLPort;
                // their correct longitudinal size is now the corresponding projection of the pad.
                const double padAngle = pad.orientationDeg * std::numbers::pi / 180.0;
                const double longitudinalAngle = direction * std::numbers::pi / 180.0;
                const double longitudinalRelative = padAngle - longitudinalAngle;
                const double longitudinalLengthMm = std::abs(std::cos(longitudinalRelative)) * pad.widthMm +
                                                    std::abs(std::sin(longitudinalRelative)) * pad.heightMm;
                port.setLength(longitudinalLengthMm * 1000.0); // millimetres -> config microns
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
                port.setAbsorbSignal(isExcitationTarget || absorb.value_or(false));
                // Automatic terminations are physical loads only, not reportable probes. An
                // excitation remains reportable regardless of the explicit/default pin state.
                port.setProbe(isExcitationTarget || isProbe.value_or(false));
                // width/length deliberately left unscaled here, matching entry.length()/entry.width()'s
                // own file units -- SimulationConfig::scaleToSimulationUnits() (called once, by
                // EMSConfig::scaledToSimulationUnits(), at the FDTD-facing boundary) scales every
                // resolved port along with the rest of the config. position is already in simulation
                // units (see positionSim above), since it comes from board/gerber geometry, not a
                // JSON field this config's own scaling concerns itself with.

                const auto actualPortIndex = static_cast<std::int32_t>(sim.ports().size());
                portIndex.entries.push_back({pad.footprintRef, pad.padNumber, actualPortIndex});
                sim.ports().push_back(std::move(port));
            }

            // Net-level, in addition to whatever the per-pad loop above just resolved -- see
            // InvolvedNetConfig::probeImpedance()'s own doc comment. Meaningless for a
            // FootprintPin-kind entry (it names a single pad, not a net to search for straight
            // trace runs on), so that kind is excluded even if somehow set.
            // `probeImpedance` is the user-facing "Impedance Probed" setting and is authoritative.
            // Differential-pair interpretation affects the configured pad ports and mixed-mode
            // results, but must not silently add trace probes when that separate setting is off.
            if (entry.kind() != NetSelectorKind::FootprintPin && entry.probeImpedance()) {
                auto candidatesResult = _findTraceProbePoints(paths, edgeCutsOrigin, config, netName, pads);
                if (!candidatesResult) return std::unexpected(std::move(candidatesResult).error());
                if (candidatesResult->empty()) {
                    logWarning("Simulation \"" + sim.name() + "\": net \"" +
                               _unescapeForDisplay(netName) +
                               "\" needs impedance probing, but no sufficiently long, straight, "
                               "pad-clear cardinal track run could be found");
                }
                std::size_t probeNumber = 0;
                for (const _TraceProbeCandidate& candidate : *candidatesResult) {
                    ++probeNumber;
                    PortConfig probe;
                    probe.setName(_unescapeForDisplay(netName) + " impedance probe " + std::to_string(probeNumber));
                    probe.setNetName(_unescapeForDisplay(netName));
                    probe.setPosition({candidate.position.x(), candidate.position.y()});
                    // Diagnostic: exact placement, in both simulation-frame sim-units (matches the
                    // Geometry Preview's own coordinate space -- see GeometryPreviewBridge.mm) and mm
                    // (constants::unitMultiplier sim-units per micron), plus the run length it was
                    // picked from -- lets a real board be checked for what's actually nearby (a
                    // ground-plane gap, a component, a bend) without guessing from the algorithm
                    // alone.
                    logInfo("### Port Resolution: impedance probe \"" + probe.name() + "\" placed at (" +
                             std::to_string(candidate.position.x()) + ", " + std::to_string(candidate.position.y()) +
                             ") sim-units = (" + std::to_string(candidate.position.x() / constants::unitMultiplier / 1000.0) +
                             ", " + std::to_string(candidate.position.y() / constants::unitMultiplier / 1000.0) +
                             ") mm, layer=" + std::to_string(candidate.layer) + ", direction=" +
                             std::to_string(candidate.direction) + " deg, probe length=" +
                             std::to_string(candidate.length) + " um ###");
                    probe.setDirection(candidate.direction);
                    probe.setWidth(candidate.width);
                    probe.setLength(candidate.length);
                    probe.setLayer(candidate.layer);
                    probe.setPlane(entry.plane());
                    probe.setExcite(false);
                    probe.setAbsorbSignal(false);
                    probe.setIsTraceProbe(true);
                    // Not added to portIndex -- a trace probe isn't pad-anchored, so nothing ever
                    // resolves an ExcitationConfig/PortRef/DifferentialPairConfig to it (see
                    // PortConfig::isTraceProbe()'s own doc comment).
                    sim.ports().push_back(std::move(probe));
                }
            }
        }

        std::unordered_set<std::string> excitedHullCutPorts;
        for (const ExcitationConfig& excitation : sim.excitations()) {
            if (excitation.hullCutPortID().has_value()) {
                excitedHullCutPorts.insert(*excitation.hullCutPortID());
            }
        }

        std::unordered_map<std::string, std::int32_t> hullCutPortIndices;
        for (const HullCutPortConfig& authored : sim.hullCutPorts()) {
            if (authored.id().empty()) {
                return std::unexpected("Simulation \"" + sim.name() + "\": hull-cut port has no id");
            }
            // Keep an authored marker around so its impedance and future role choices survive,
            // but do not turn a completely disabled marker into an implicit passive probe.
            if (!authored.probe() && !authored.absorbSignal() &&
                !excitedHullCutPorts.contains(authored.id())) {
                continue;
            }
            const auto layer = config.metalLayerIndexForFileName(_normalizeLayerName(authored.layer()));
            if (!layer.has_value()) {
                return std::unexpected("Simulation \"" + sim.name() + "\": hull-cut port \"" + authored.id() +
                                       "\" references copper layer \"" + authored.layer() +
                                       "\" which is not present in the stackup");
            }
            PortConfig port;
            std::ostringstream portName;
            portName << _unescapeForDisplay(authored.net()) << " hull cut (" << authored.layer()
                     << " @ " << std::fixed << std::setprecision(3) << authored.x() / 1000.0
                     << ", " << authored.y() / 1000.0 << " mm)";
            port.setName(portName.str());
            port.setNetName(_unescapeForDisplay(authored.net()));
            port.setPosition({authored.x() * constants::unitMultiplier,
                              authored.y() * constants::unitMultiplier});
            port.setDirection(authored.direction());
            port.setWidth(authored.width());
            port.setLength(authored.length());
            port.setLayer(*layer);
            port.setPlane(authored.plane());
            port.setImpedance(authored.impedance());
            port.setAbsorbSignal(authored.absorbSignal());
            port.setProbe(authored.probe());
            port.setExcite(false);
            const auto index = static_cast<std::int32_t>(sim.ports().size());
            if (!hullCutPortIndices.emplace(authored.id(), index).second) {
                return std::unexpected("Simulation \"" + sim.name() + "\": duplicate hull-cut port id \"" +
                                       authored.id() + "\"");
            }
            sim.ports().push_back(std::move(port));
        }

        for (ExcitationConfig& excitation : sim.excitations()) {
            if (excitation.hullCutPortID().has_value()) {
                const auto index = hullCutPortIndices.find(*excitation.hullCutPortID());
                if (index == hullCutPortIndices.end()) {
                    return std::unexpected("Simulation \"" + sim.name() + "\": excitation references missing "
                                           "hull-cut port \"" + *excitation.hullCutPortID() + "\"");
                }
                excitation.setDrivenPortIndex(index->second);
                PortConfig& drivenPort = sim.ports()[static_cast<std::size_t>(index->second)];
                drivenPort.setExcite(true);
                drivenPort.setAbsorbSignal(true);
                drivenPort.setProbe(true);
                continue;
            }
            auto resolvedResult = libkicad::resolvePin(paths.kicadBoardPaths(), excitation.footprint(),
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
            const PortConfig& drivenPort = sim.ports()[static_cast<std::size_t>(*index)];
            if (drivenPort.footprintRef() != resolved.footprintRef || drivenPort.padNumber() != resolved.padNumber) {
                return std::unexpected("Simulation \"" + sim.name() +
                                       "\": internal port-index mismatch while resolving excitation on " +
                                       excitation.footprint() + "." + excitation.pin());
            }
            excitation.setDrivenPortIndex(*index);
            sim.ports()[static_cast<std::size_t>(*index)].setExcite(true);
        }

        // Turn reciprocal, enabled net-pair metadata into the four single-ended port references
        // the existing mixed-mode postprocessor consumes. Consecutive pair sections joined on both
        // legs by supported series R/L/C components are one end-to-end pair: e.g. CTx+/- on the
        // source side of two AC-coupling capacitors and Tx+/- on their destination side. The FDTD
        // still sweeps each source port independently; linear superposition of those two columns is
        // exactly the odd-mode (+ on P, - on N) stimulus used by SDD.
        //
        // Gated on isDifferentialPair(): a net pair that merely *looks* reciprocal (matching
        // differentialPairPartner names both ways) shouldn't silently turn an otherwise normal,
        // single-ended simulation's results into a mixed-mode one -- this whole auto-generation
        // only runs once the simulation itself is explicitly marked as being about a differential
        // pair (see SimulationConfig::isDifferentialPair()'s own doc comment).
        struct PairSection {
            std::string positiveNet;
            std::string negativeNet;
        };
        std::vector<PairSection> sections;
        std::set<std::pair<std::string, std::string>> seenSections;
        const auto isPositiveName = [](const std::string& name) {
            return name.ends_with("+") || name.ends_with("_P") ||
                   (name.ends_with("P") && !name.ends_with("_N"));
        };
        for (const InvolvedNetConfig& entry : sim.involvedNets()) {
            if (!sim.isDifferentialPair()) break;
            if (entry.inclusionLevel() != NetInclusionLevel::SimulationNet ||
                entry.kind() != NetSelectorKind::Net || !entry.net().has_value() ||
                !entry.differentialPairPartner().has_value() || !entry.simulateAsDifferentialPair()) {
                continue;
            }
            const std::string firstName = _unescapeForDisplay(*entry.net());
            const std::string secondName = _unescapeForDisplay(*entry.differentialPairPartner());
            const auto sectionKey = std::minmax(firstName, secondName);
            if (!seenSections.emplace(sectionKey.first, sectionKey.second).second) {
                continue;
            }
            const auto reciprocal = std::find_if(sim.involvedNets().begin(), sim.involvedNets().end(),
                                                   [&](const InvolvedNetConfig& candidate) {
                return candidate.inclusionLevel() == NetInclusionLevel::SimulationNet &&
                       candidate.kind() == NetSelectorKind::Net && candidate.net().has_value() &&
                       _unescapeForDisplay(*candidate.net()) == secondName &&
                       candidate.differentialPairPartner().has_value() &&
                       _unescapeForDisplay(*candidate.differentialPairPartner()) == firstName &&
                       candidate.simulateAsDifferentialPair();
            });
            if (reciprocal == sim.involvedNets().end()) {
                logWarning("Simulation \"" + sim.name() + "\": differential pair " + firstName + " / " +
                           secondName + " is not reciprocal; skipping mixed-mode analysis");
                continue;
            }
            const std::string pName = isPositiveName(firstName) ? firstName : secondName;
            const std::string nName = pName == firstName ? secondName : firstName;
            sections.push_back({pName, nName});
        }

        if (!sections.empty() && !netConnectivity.has_value()) {
            auto built = _NetConnectivity::build(paths);
            if (!built) return std::unexpected(std::move(built).error());
            netConnectivity = std::move(*built);
        }

        std::vector<bool> consumedSections(sections.size(), false);
        for (std::size_t seed = 0; seed < sections.size(); ++seed) {
            if (consumedSections[seed]) continue;
            consumedSections[seed] = true;
            std::vector<std::size_t> group = {seed};
            // Transitive closure: a path can contain more than one series element and therefore
            // more than two named net-pair sections.
            for (std::size_t cursor = 0; cursor < group.size(); ++cursor) {
                const PairSection& current = sections[group[cursor]];
                for (std::size_t candidate = 0; candidate < sections.size(); ++candidate) {
                    if (consumedSections[candidate]) continue;
                    if (netConnectivity->connected(current.positiveNet, sections[candidate].positiveNet) &&
                        netConnectivity->connected(current.negativeNet, sections[candidate].negativeNet)) {
                        consumedSections[candidate] = true;
                        group.push_back(candidate);
                    }
                }
            }

            std::set<std::string> positiveNets;
            std::set<std::string> negativeNets;
            for (const std::size_t sectionIndex : group) {
                positiveNets.insert(sections[sectionIndex].positiveNet);
                negativeNets.insert(sections[sectionIndex].negativeNet);
            }

            std::optional<std::pair<std::int32_t, std::int32_t>> source;
            for (std::size_t pi = 0; pi < sim.ports().size() && !source.has_value(); ++pi) {
                const PortConfig& p = sim.ports()[pi];
                if (!p.excite() || !positiveNets.contains(p.netName()) || p.isTraceProbe()) continue;
                for (std::size_t ni = 0; ni < sim.ports().size(); ++ni) {
                    const PortConfig& n = sim.ports()[ni];
                    if (n.excite() && negativeNets.contains(n.netName()) && !n.isTraceProbe() &&
                        n.footprintRef() == p.footprintRef()) {
                        source = {static_cast<std::int32_t>(pi), static_cast<std::int32_t>(ni)};
                        break;
                    }
                }
            }
            if (!source.has_value()) {
                logWarning("Simulation \"" + sim.name() + "\": differential pair " +
                           *positiveNets.begin() + " / " + *negativeNets.begin() +
                           " has no pair of excited pins on the same component");
                continue;
            }

            std::optional<std::pair<std::int32_t, std::int32_t>> destination;
            for (std::size_t pi = 0; pi < sim.ports().size() && !destination.has_value(); ++pi) {
                const PortConfig& p = sim.ports()[pi];
                if (p.excite() || !p.absorbSignal() || !positiveNets.contains(p.netName()) || p.isTraceProbe()) continue;
                for (std::size_t ni = 0; ni < sim.ports().size(); ++ni) {
                    const PortConfig& n = sim.ports()[ni];
                    if (!n.excite() && n.absorbSignal() && negativeNets.contains(n.netName()) && !n.isTraceProbe() &&
                        n.footprintRef() == p.footprintRef()) {
                        destination = {static_cast<std::int32_t>(pi), static_cast<std::int32_t>(ni)};
                        break;
                    }
                }
            }
            if (!destination.has_value()) {
                logWarning("Simulation \"" + sim.name() + "\": differential pair " +
                           *positiveNets.begin() + " / " + *negativeNets.begin() +
                           " has no matching pair of absorbing destination pins; skipping mixed-mode analysis");
                continue;
            }

            const auto setRef = [&](PortRef& ref, std::int32_t index) {
                const PortConfig& port = sim.ports()[static_cast<std::size_t>(index)];
                ref.setFootprint(port.footprintRef());
                ref.setPin(port.padNumber());
            };
            const auto setNet = [&](std::vector<DiffPairNetMember>& nets, const std::string& netName) {
                DiffPairNetMember member;
                member.setKind(DiffPairNetKind::Net);
                member.setNet(netName);
                nets.push_back(std::move(member));
            };
            DifferentialPairConfig pair;
            setRef(pair.positiveExcitation(), source->first);
            setRef(pair.negativeExcitation(), source->second);
            setRef(pair.positiveProbe(), destination->first);
            setRef(pair.negativeProbe(), destination->second);
            for (const std::string& net : positiveNets) setNet(pair.positiveNets(), net);
            for (const std::string& net : negativeNets) setNet(pair.negativeNets(), net);
            const PortConfig& sourceP = sim.ports()[static_cast<std::size_t>(source->first)];
            const PortConfig& sourceN = sim.ports()[static_cast<std::size_t>(source->second)];
            pair.setName(differentialPairBaseName(sourceP.netName(), sourceN.netName()));
            pair.setAutomatic(true);
            sim.diffPairs().push_back(std::move(pair));
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
            if (auto r = _resolvePortRef(paths, pair.positiveExcitation(), portIndex, orderedNets, sim.name(),
                                          "differential pair positive_excitation");
                !r) {
                return r;
            }
            if (auto r = _resolvePortRef(paths, pair.positiveProbe(), portIndex, orderedNets, sim.name(),
                                          "differential pair positive_probe");
                !r) {
                return r;
            }
            if (auto r = _resolvePortRef(paths, pair.negativeExcitation(), portIndex, orderedNets, sim.name(),
                                          "differential pair negative_excitation");
                !r) {
                return r;
            }
            if (auto r = _resolvePortRef(paths, pair.negativeProbe(), portIndex, orderedNets, sim.name(),
                                          "differential pair negative_probe");
                !r) {
                return r;
            }
            pair.postInit();
            if (!pair.correct()) continue;

            if (!netConnectivity.has_value()) {
                auto built = _NetConnectivity::build(paths);
                if (!built) return std::unexpected(std::move(built).error());
                netConnectivity = std::move(*built);
            }
            const std::string pairLabel =
                "Simulation \"" + sim.name() + "\": differential pair " + pair.name().value_or("(unnamed)");
            const std::string positiveExcitationNet =
                sim.ports()[static_cast<std::size_t>(*pair.positiveExcitation().resolvedIndex())].netName();
            const std::string positiveProbeNet =
                sim.ports()[static_cast<std::size_t>(*pair.positiveProbe().resolvedIndex())].netName();
            auto positiveResult = _validateDiffPairSide(paths, *netConnectivity, pair.positiveNets(),
                                                          positiveExcitationNet, positiveProbeNet,
                                                          pairLabel + "'s positive_nets", sim.name());
            if (!positiveResult) return std::unexpected(std::move(positiveResult).error());
            if (positiveResult->has_value()) {
                logWarning(**positiveResult);
                pair.setCorrect(false);
            }

            const std::string negativeExcitationNet =
                sim.ports()[static_cast<std::size_t>(*pair.negativeExcitation().resolvedIndex())].netName();
            const std::string negativeProbeNet =
                sim.ports()[static_cast<std::size_t>(*pair.negativeProbe().resolvedIndex())].netName();
            auto negativeResult = _validateDiffPairSide(paths, *netConnectivity, pair.negativeNets(),
                                                          negativeExcitationNet, negativeProbeNet,
                                                          pairLabel + "'s negative_nets", sim.name());
            if (!negativeResult) return std::unexpected(std::move(negativeResult).error());
            if (negativeResult->has_value()) {
                logWarning(**negativeResult);
                pair.setCorrect(false);
            }
        }

        if (auto r = _resolveLumpedComponents(config, sim, paths, edgeCutsOrigin, orderedNets); !r) {
            return r;
        }
    }
    return {};
}

} // namespace kiems
