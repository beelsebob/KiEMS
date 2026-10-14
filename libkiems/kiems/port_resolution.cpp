#include "port_resolution.hpp"

#include <algorithm>
#include <cctype>
#include <cmath>
#include <cstdlib>
#include <expected>
#include <filesystem>
#include <functional>
#include <iomanip>
#include <limits>
#include <map>
#include <numbers>
#include <numeric>
#include <optional>
#include <sstream>
#include <set>
#include <string>
#include <string_view>
#include <tuple>
#include <unordered_map>
#include <unordered_set>
#include <utility>
#include <vector>

#include "component_sim_model.hpp"
#include "component_value.hpp"
#include "config.hpp"
#include "constants.hpp"
#include "gerber_io.hpp"
#include "libkicad/libkicad.hpp"
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

std::int32_t referencePlaneForPortLayer(std::int32_t layer, std::int32_t plane, std::int32_t metalCount) {
    const std::int32_t bottom = metalCount - 1;
    // Only a plane nearer F.Cu than B.Cu belongs to the top side.
    if (layer != bottom || plane < 0 || bottom - plane <= plane || bottom - plane >= layer) return plane;
    return bottom - plane;
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

std::int32_t _planeForPortLayer(const EMSConfig& config, std::int32_t layer, std::int32_t plane) {
    return referencePlaneForPortLayer(layer, plane, static_cast<std::int32_t>(config.getMetals().size()));
}

double _mmToSimUnits(double mm);

std::expected<Position, std::string> _edgeCutsOrigin(const libkicad::Board& board) {
    auto geometry = board.boardGeometry();
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
    const libkicad::Board& board, const Position& edgeCutsOrigin, const EMSConfig& config,
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

    auto tracksResult = board.tracksOnNet(netName);
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
std::optional<ComponentUnit> _lumpedComponentKind(const std::string& letterPrefix) {
    if (letterPrefix == "R") return ComponentUnit::Resistance;
    if (letterPrefix == "L") return ComponentUnit::Inductance;
    if (letterPrefix == "C") return ComponentUnit::Capacitance;
    return std::nullopt;
}

// A component without a schematic symbol, modelled from its designator and Value field alone: a
// 2-pin R, L or C. nullopt (logged) when it isn't one.
std::optional<ComponentSimBranch> _valueBranch(const libkicad::FootprintInfo& footprint, const std::string& simName) {
    const std::optional<ComponentUnit> unit = _lumpedComponentKind(_letterPrefix(footprint.reference));
    if (!unit.has_value()) {
        logWarning("Simulation \"" + simName + "\": included component " + footprint.reference +
                   " has no SPICE model and isn't an R, L or C -- skipping");
        return std::nullopt;
    }
    if (footprint.pins.size() != 2) {
        logWarning("Simulation \"" + simName + "\": included component " + footprint.reference + " has " +
                   std::to_string(footprint.pins.size()) + " pin(s), not 2 -- skipping (not a supported R/L/C shape)");
        return std::nullopt;
    }
    const std::optional<double> value = parseSensibleComponentValue(footprint.value, *unit);
    if (!value.has_value()) {
        logWarning("Simulation \"" + simName + "\": included component " + footprint.reference + "'s value \"" +
                   footprint.value + "\" isn't a usable finite value -- skipping");
        return std::nullopt;
    }
    ComponentSimBranch branch;
    branch.pin1 = footprint.pins[0].number;
    branch.pin2 = footprint.pins[1].number;
    switch (*unit) {
    case ComponentUnit::Resistance: branch.resistance = *value; break;
    case ComponentUnit::Inductance: branch.inductance = *value; break;
    case ComponentUnit::Capacitance: branch.capacitance = *value; break;
    }
    return branch;
}

// "series R=49.9 L=1e-09", for logs.
std::string _describeBranch(const ComponentSimBranch& branch) {
    std::ostringstream text;
    text << (branch.topology == LumpedComponentTopology::Series ? "series" : "parallel");
    for (const auto& [name, value] : {std::pair{"R", branch.resistance}, std::pair{"L", branch.inductance},
                                      std::pair{"C", branch.capacitance}}) {
        if (!std::isnan(value)) text << " " << name << "=" << value;
    }
    return text.str();
}

// The SPICE models of `board`'s components. `board` is normally the snapshot in fab/, which has
// the board and project files but not the schematic or the model libraries it names (relative to
// the project), so the models are read from the original project config.kicadPcbPath() names
// whenever it still exists.
std::expected<std::vector<libkicad::ComponentSimModel>, std::string> _componentSimModels(const EMSConfig& config,
                                                                                         const libkicad::Board& board) {
    if (config.kicadPcbPath().has_value()) {
        const std::filesystem::path boardPath = *config.kicadPcbPath();
        const std::filesystem::path projectPath = std::filesystem::path(boardPath).replace_extension(".kicad_pro");
        std::error_code ec;
        if (std::filesystem::is_regular_file(boardPath, ec) && std::filesystem::is_regular_file(projectPath, ec) &&
            boardPath != board.paths().boardPath) {
            const libkicad::Board source(board.runtime(), projectPath.string(), boardPath.string());
            return source.componentSimModels();
        }
    }
    return board.componentSimModels();
}

// Models every component the user included in `sim` (IncludedComponentConfig) as one
// LumpedComponentConfig per branch of its SPICE model (componentSimNetwork()) -- see that type's
// own doc comment. Nothing is modelled unless it was included; a component whose model isn't
// supported is skipped, and so is any branch that can't be placed (unconnected pin, pins on
// different/unknown layers), each logged.
std::expected<void, std::string> _resolveLumpedComponents(const EMSConfig& config, SimulationConfig& sim,
                                                            const libkicad::Board& board, const Position& edgeCutsOrigin,
                                                            const std::vector<std::string>& orderedNets) {
    sim.lumpedComponents().clear();
    if (sim.includedComponents().empty()) {
        return {};
    }

    auto groundNetsResult = resolveGroundNetNames(board, sim.groundNet());
    if (!groundNetsResult) {
        return std::unexpected(std::move(groundNetsResult).error());
    }
    // Only for diagnostics: a pin on a net whose copper isn't in the model leaves that end of the
    // element connected to nothing. orderedNets holds only SimulationNet entries (it also drives
    // ports), so add the GeometryOnly entries' nets and the ground net(s).
    std::unordered_set<std::string> membership(orderedNets.begin(), orderedNets.end());
    for (const InvolvedNetConfig& entry : sim.involvedNets()) {
        if (entry.inclusionLevel() != NetInclusionLevel::GeometryOnly) continue;
        auto nets = resolveInvolvedNetNames(board, entry);
        if (!nets) return std::unexpected(std::move(nets).error());
        membership.insert(nets->begin(), nets->end());
    }
    membership.insert(groundNetsResult->begin(), groundNetsResult->end());

    auto footprintsResult = board.footprints();
    if (!footprintsResult) {
        return std::unexpected(std::move(footprintsResult).error());
    }
    std::unordered_map<std::string, const libkicad::FootprintInfo*> footprintsByReference;
    for (const auto& footprint : *footprintsResult) {
        footprintsByReference.emplace(footprint.reference, &footprint);
    }

    // One lumped element between two of `footprint`'s pins; a branch that can't be placed is
    // logged and skipped.
    auto addBranch = [&](const libkicad::FootprintInfo& footprint, const ComponentSimBranch& branch,
                         const std::vector<ComponentSimBranch>& branches) -> std::expected<void, std::string> {
        const std::string label = branches.size() > 1
                                      ? footprint.reference + " (pins " + branch.pin1 + "-" + branch.pin2 + ")"
                                      : footprint.reference;
        const auto findPin = [&](const std::string& number) -> const libkicad::FootprintPin* {
            const auto pin = std::ranges::find(footprint.pins, number, &libkicad::FootprintPin::number);
            return pin == footprint.pins.end() ? nullptr : &*pin;
        };
        const libkicad::FootprintPin* pin1Pointer = findPin(branch.pin1);
        const libkicad::FootprintPin* pin2Pointer = findPin(branch.pin2);
        if (pin1Pointer == nullptr || pin2Pointer == nullptr) {
            logWarning("Simulation \"" + sim.name() + "\": included component " + label +
                       ": its SPICE model names a pin the footprint doesn't have -- skipping");
            return {};
        }
        const libkicad::FootprintPin& pin1 = *pin1Pointer;
        const libkicad::FootprintPin& pin2 = *pin2Pointer;
        if (pin1.netName.empty() || pin2.netName.empty()) {
            logWarning("Simulation \"" + sim.name() + "\": included component " + label +
                       " has an unconnected pin -- skipping");
            return {};
        }
        for (const auto* pin : {&pin1, &pin2}) {
            if (membership.find(pin->netName) == membership.end()) {
                logWarning("Simulation \"" + sim.name() + "\": included component " + footprint.reference + " pin " +
                           pin->number + " is on \"" + _unescapeForDisplay(pin->netName) +
                           "\", which isn't included in this simulation -- that end connects to nothing");
            }
        }

        auto pad1Result = board.resolvePin(footprint.reference, pin1.number);
        if (!pad1Result) {
            return std::unexpected(std::move(pad1Result).error());
        }
        auto pad2Result = board.resolvePin(footprint.reference, pin2.number);
        if (!pad2Result) {
            return std::unexpected(std::move(pad2Result).error());
        }
        const PadIdentity& pad1 = *pad1Result;
        const PadIdentity& pad2 = *pad2Result;

        if (pad1.copperLayerName != pad2.copperLayerName) {
            logWarning("Simulation \"" + sim.name() + "\": component " + label +
                       " has pins on different copper layers -- skipping (not supported)");
            return {};
        }
        const std::string layerFileName = _normalizeLayerName(pad1.copperLayerName);
        const std::optional<std::int32_t> layer = config.metalLayerIndexForFileName(layerFileName);
        if (!layer.has_value()) {
            logWarning("Simulation \"" + sim.name() + "\": component " + label + ": copper layer \"" +
                       pad1.copperLayerName + "\" not found in stackup -- skipping");
            return {};
        }

        const Position pos1 = _padPositionInSimFrame(pad1, edgeCutsOrigin);
        const Position pos2 = _padPositionInSimFrame(pad2, edgeCutsOrigin);
        const double angle = std::atan2(pos2.y() - pos1.y(), pos2.x() - pos1.x());
        const std::optional<double> snapped = _snapToCardinal(angle, kDirectionToleranceDegrees);

        LumpedComponentConfig component;
        component.setReference(footprint.reference);
        if (branches.size() > 1) component.setName(footprint.reference + "_" + branch.pin1 + "_" + branch.pin2);
        component.setTopology(branch.topology);
        component.setNet1(_unescapeForDisplay(pin1.netName));
        component.setNet2(_unescapeForDisplay(pin2.netName));
        component.setResistance(branch.resistance);
        component.setInductance(branch.inductance);
        component.setCapacitance(branch.capacitance);
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
            logInfo("Simulation \"" + sim.name() + "\": component " + label +
                     "'s two pads aren't axis-aligned -- bridging via a synthetic corner at (" +
                     std::to_string(corner.x()) + ", " + std::to_string(corner.y()) + ") through open airspace");
        }
        sim.lumpedComponents().push_back(std::move(component));
        return {};
    };

    // The SPICE models decide what each included component becomes. A part with no schematic
    // symbol -- or every part, when the schematic can't be read -- falls back to its designator
    // and Value field, as a single 2-pin R, L or C.
    std::unordered_map<std::string, libkicad::ComponentSimModel> modelsByReference;
    if (auto models = _componentSimModels(config, board)) {
        for (libkicad::ComponentSimModel& model : *models) {
            modelsByReference.emplace(model.reference, std::move(model));
        }
    } else {
        logWarning("Simulation \"" + sim.name() + "\": couldn't read the schematic's SPICE models (" +
                   models.error() + ") -- modelling included components from their values instead");
    }

    for (const IncludedComponentConfig& included : sim.includedComponents()) {
        const auto found = footprintsByReference.find(included.reference);
        if (found == footprintsByReference.end()) {
            logWarning("Simulation \"" + sim.name() + "\": included component " + included.reference +
                       " is not on the board -- skipping");
            continue;
        }
        const libkicad::FootprintInfo& footprint = *found->second;

        std::vector<ComponentSimBranch> branches;
        const auto model = modelsByReference.find(footprint.reference);
        if (model != modelsByReference.end() && model->second.status != libkicad::ComponentSimModelStatus::NoSymbol) {
            ComponentSimNetwork network = componentSimNetwork(model->second);
            if (!network.supported) {
                logWarning("Simulation \"" + sim.name() + "\": included component " + footprint.reference + ": " +
                           network.reason + " -- skipping");
                continue;
            }
            if (network.branches.empty()) {
                logWarning("Simulation \"" + sim.name() + "\": included component " + footprint.reference +
                           "'s SPICE model connects none of its pins -- skipping");
                continue;
            }
            branches = std::move(network.branches);
        } else {
            auto branch = _valueBranch(footprint, sim.name());
            if (!branch) continue;
            branches.push_back(std::move(*branch));
        }

        std::string summary;
        for (const ComponentSimBranch& branch : branches) {
            auto added = addBranch(footprint, branch, branches);
            if (!added) return std::unexpected(std::move(added).error());
            summary += "\n  pins " + branch.pin1 + "-" + branch.pin2 + ": " + _describeBranch(branch);
        }
        logInfo("Simulation \"" + sim.name() + "\": included component " + footprint.reference + " modelled as " +
                std::to_string(branches.size()) + " lumped element(s):" + summary);
    }
    return {};
}

std::expected<void, std::string> _resolvePortRef(const libkicad::Board& board, PortRef& ref, const _PortIndex& index,
                                                  const std::vector<std::string>& involvedNets,
                                                  const std::string& simName, const std::string& fieldLabel) {
    auto resolvedResult = board.resolvePin(ref.footprint(), ref.pin());
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
    static std::expected<_NetConnectivity, std::string> build(const libkicad::Board& board) {
        auto fps = board.footprints();
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
    const libkicad::Board& board, const std::vector<DiffPairNetMember>& members, const std::string& context) {
    std::vector<std::string> names;
    for (const DiffPairNetMember& member : members) {
        if (member.kind() == DiffPairNetKind::NetClass) {
            auto classNets = board.netsInNetClass(*member.netClass());
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
    const libkicad::Board& board, _NetConnectivity& connectivity, const std::vector<DiffPairNetMember>& netMembers,
    const std::string& excitationNet, const std::string& probeNet, const std::string& sideLabel,
    const std::string& context) {
    if (netMembers.empty()) {
        return sideLabel + " lists no nets";
    }
    auto namesResult = _resolveDiffPairNetNames(board, netMembers, context);
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

/// How far a return bridge may run to reach a ground pad: far enough for every ball of a x16 DDR
/// package, whose address balls sit up to ~5 mm (Manhattan) from the nearest VSS. A longer route
/// would add a loop no real package has.
constexpr double kMaxReturnBridgeDistanceMm = 5.0;

/// One piece of planned bridge metal, as an axis-aligned rectangle already grown by its clearance.
struct _BridgeShape {
    double x0 = 0;
    double y0 = 0;
    double x1 = 0;
    double y1 = 0;
    /// The pin's net for its pillar, the ground net for return metal, and a token unique to each
    /// element leg, which may touch nothing.
    std::string net;
};

/// The rectangle covering a leg of `width` from `a` to `b` (a pillar when they coincide), grown by
/// a quarter of `width` on every side: two pieces clash with less than about half a width between
/// them, which is a couple of cells at the density the mesh puts around a port.
_BridgeShape _bridgeShape(std::pair<double, double> a, std::pair<double, double> b, double width, std::string net) {
    const double grow = width / 2 + width / 4;
    return {std::min(a.first, b.first) - grow, std::min(a.second, b.second) - grow,
            std::max(a.first, b.first) + grow, std::max(a.second, b.second) + grow, std::move(net)};
}

bool _bridgeShapesClash(const _BridgeShape& a, const _BridgeShape& b) {
    if (a.net == b.net) return false;
    constexpr double kTouching = 1.0; // simulation units: pieces that only meet don't clash
    return a.x0 < b.x1 - kTouching && b.x0 < a.x1 - kTouching && a.y0 < b.y1 - kTouching &&
           b.y0 < a.y1 - kTouching;
}

/// Board geometry the return-bridge pass reads, loaded the first time a simulation needs it.
struct _ReturnBridgeBoard {
    std::vector<ViaHole> vias;
    std::unordered_map<std::string, std::vector<PadIdentity>> padsByFootprint;
};

std::expected<_ReturnBridgeBoard, std::string> _loadReturnBridgeBoard(const libkicad::Board& board,
                                                                      const Position& origin) {
    _ReturnBridgeBoard result;
    auto vias = getVias(board, origin.x(), origin.y());
    if (!vias) return std::unexpected(std::move(vias).error());
    result.vias = std::move(*vias);
    auto pads = board.allPads();
    if (!pads) return std::unexpected(std::move(pads).error());
    for (PadIdentity& pad : *pads) result.padsByFootprint[pad.footprintRef].push_back(std::move(pad));
    return result;
}

/// Whether any via barrel (drill plus plating) reaches into the XY footprint of `port`'s vertical
/// column -- the box Simulation::padColumn() would build for it.
bool _columnHitsViaBarrel(const PortConfig& port, const std::vector<ViaHole>& vias, double plating) {
    const PortGridFootprint footprint = portGridFootprint(port);
    const double halfX = footprint.width * constants::unitMultiplier / 2;
    const double halfY = footprint.height * constants::unitMultiplier / 2;
    for (const ViaHole& via : vias) {
        const double radius = via.diameter / 2 + plating;
        // An oblong hole is sampled along its centreline; a round one is a single point.
        constexpr int kSamples = 8;
        for (int i = 0; i <= kSamples; ++i) {
            const double t = static_cast<double>(i) / kSamples;
            const double x = via.x + (via.x2 - via.x) * t;
            const double y = via.y + (via.y2 - via.y) * t;
            const double dx = std::max(std::abs(x - footprint.centerX) - halfX, 0.0);
            const double dy = std::max(std::abs(y - footprint.centerY) - halfY, 0.0);
            if (std::hypot(dx, dy) < radius) return true;
            if (via.x == via.x2 && via.y == via.y2) break;
        }
    }
    return false;
}

BridgePad _bridgePad(const PadIdentity& pad, const Position& origin) {
    const Position centre = _padPositionInSimFrame(pad, origin);
    return {pad.padNumber, _unescapeForDisplay(pad.netName), centre.x(), centre.y(),
            _mmToSimUnits(std::min(pad.widthMm, pad.heightMm))};
}

/// Gives every pin port whose vertical column would swallow a via barrel a return bridge instead
/// (see PortConfig::returnBridge()). Each side of the board's bridges is planned together, so none
/// of them can touch. A port with no ground pad close enough, or no clear route to one, keeps its
/// column, with a warning: its readings and its loading will be wrong.
void _assignReturnBridges(const EMSConfig& config, SimulationConfig& sim, const _ReturnBridgeBoard& data,
                          const std::unordered_set<NetName, NetNameHash>& groundNets, const Position& origin) {
    const auto metalCount = static_cast<std::int32_t>(config.getMetals().size());
    const double plating = config.via().platingThickness() * constants::unitMultiplier;
    // Bridges only have open air to run through off the outer copper layers.
    for (const std::int32_t side : std::set<std::int32_t>{0, metalCount - 1}) {
        // Excitations and probes are routed ahead of plain absorbers, so the ports actually measured
        // get the shortest routes -- and absorbers whose pads the hull later drops can't crowd them.
        std::vector<std::size_t> order(sim.ports().size());
        std::iota(order.begin(), order.end(), std::size_t{0});
        std::ranges::stable_sort(order, std::greater{}, [&](std::size_t index) {
            const PortConfig& port = sim.ports()[index];
            return (port.excite() ? 2 : 0) + (port.probe() ? 1 : 0);
        });
        std::vector<std::size_t> portIndices;
        std::vector<ReturnBridgeRequest> requests;
        for (const std::size_t index : order) {
            const PortConfig& port = sim.ports()[index];
            if (port.isTraceProbe() || port.footprintRef().empty() || port.layer() != side ||
                !port.position().has_value() || !port.direction().has_value() ||
                !_columnHitsViaBarrel(port, data.vias, plating)) {
                continue;
            }
            const auto footprintPads = data.padsByFootprint.find(port.footprintRef());
            if (footprintPads == data.padsByFootprint.end()) continue;
            const auto own = std::ranges::find(footprintPads->second, port.padNumber(), &PadIdentity::padNumber);
            if (own == footprintPads->second.end() || groundNets.contains(NetName(own->netName))) continue;
            ReturnBridgeRequest request;
            request.pad = _bridgePad(*own, origin);
            for (const PadIdentity& candidate : footprintPads->second) {
                if (candidate.padNumber == own->padNumber || candidate.copperLayerName != own->copperLayerName ||
                    !groundNets.contains(NetName(candidate.netName))) {
                    continue;
                }
                request.returnPads.push_back(_bridgePad(candidate, origin));
            }
            sim.ports()[index].setColumnHitsVia(true);
            portIndices.push_back(index);
            requests.push_back(std::move(request));
        }
        if (requests.empty()) continue;

        const auto plans = planReturnBridges(requests, _mmToSimUnits(kMaxReturnBridgeDistanceMm));
        std::size_t bridged = 0;
        for (std::size_t i = 0; i < plans.size(); ++i) {
            PortConfig& port = sim.ports()[portIndices[i]];
            if (!plans[i].has_value()) {
                logWarning("Simulation \"" + sim.name() + "\": port " + port.name() +
                           " sits on a via, so a pad-to-plane port would replace the via's barrel, but no ground "
                           "pad on " + port.footprintRef() + " within " +
                           std::to_string(static_cast<int>(kMaxReturnBridgeDistanceMm)) +
                           " mm has a clear route -- " +
                           (port.excite() || port.probe() || port.isTraceProbe()
                                ? std::string("its readings and loading will be wrong")
                                : std::string("dropping it")));
                continue;
            }
            ++bridged;
            logDebug("Simulation \"" + sim.name() + "\": port " + port.name() + " returns to " +
                     port.footprintRef() + " pin " + plans[i]->padNumber +
                     (plans[i]->corner.has_value() ? " through an L route" : " in a straight run"));
            port.setReturnBridge(plans[i]);
        }
        logInfo("Simulation \"" + sim.name() + "\": " + std::to_string(bridged) + " of " +
                std::to_string(plans.size()) + " port(s) on via-in-pad pads bridged to a ground pad on " +
                (side == 0 ? "the top" : "the bottom"));
    }
}

} // namespace

bool geometryOnlyPinNeedsAbsorbingPort(const InvolvedNetConfig& entry,
                                       const std::string& footprint, const std::string& pin) {
    return entry.inclusionLevel() == NetInclusionLevel::GeometryOnly &&
           entry.probedPinAbsorbs(footprint, pin).value_or(false);
}

std::vector<std::optional<PortReturnBridge>> planReturnBridges(const std::vector<ReturnBridgeRequest>& requests,
                                                               double maxDistance) {
    std::vector<std::optional<PortReturnBridge>> plans(requests.size());
    // Every pin's pillar is reserved first, at the widest it can be (half its own pad). Entry i of
    // `placed` is request i's pillar until the reserved block ends.
    std::vector<_BridgeShape> placed;
    for (const ReturnBridgeRequest& request : requests) {
        const std::pair<double, double> at{request.pad.x, request.pad.y};
        placed.push_back(_bridgeShape(at, at, request.pad.size / 2, request.pad.netName));
    }

    for (std::size_t index = 0; index < requests.size(); ++index) {
        const BridgePad& pad = requests[index].pad;
        const std::pair<double, double> from{pad.x, pad.y};
        std::vector<const BridgePad*> candidates;
        for (const BridgePad& candidate : requests[index].returnPads) {
            const double distance = std::abs(candidate.x - pad.x) + std::abs(candidate.y - pad.y);
            if (distance > 0 && distance <= maxDistance) candidates.push_back(&candidate);
        }
        // Nearest first; at equal distance a straight run beats an L.
        const auto rank = [&](const BridgePad* candidate) {
            const double dx = std::abs(candidate->x - pad.x);
            const double dy = std::abs(candidate->y - pad.y);
            return std::tuple(dx + dy, std::min(dx, dy), candidate->padNumber);
        };
        std::ranges::sort(candidates, [&](const BridgePad* a, const BridgePad* b) { return rank(a) < rank(b); });

        const std::string elementNet = "\x01 element " + std::to_string(index);
        for (const BridgePad* candidate : candidates) {
            const double width = std::min(pad.size, candidate->size) / 2;
            const std::pair<double, double> to{candidate->x, candidate->y};
            // A straight run keeps the pin's own row or column; the return pillar absorbs a
            // misalignment of up to a quarter of its width.
            const bool sameRow = std::abs(to.second - from.second) <= width / 4;
            const bool sameColumn = std::abs(to.first - from.first) <= width / 4;
            std::vector<std::optional<std::pair<double, double>>> corners;
            if (sameRow || sameColumn) {
                corners.emplace_back(std::nullopt);
            } else {
                corners.emplace_back(std::pair{to.first, from.second});
                corners.emplace_back(std::pair{from.first, to.second});
            }
            for (const auto& corner : corners) {
                const std::pair<double, double> end =
                    corner.value_or(sameRow ? std::pair{to.first, from.second} : std::pair{from.first, to.second});
                std::vector<_BridgeShape> shapes;
                // The element is checked short of its far end, which is return metal (the pillar, or
                // the corner of the PEC leg) that other routes' return metal may share. The trim
                // clears the widest pillar another route could stand on this return pad.
                const double length = std::abs(end.first - from.first) + std::abs(end.second - from.second);
                const double trim = 0.75 * width + 0.375 * candidate->size;
                if (length > trim) {
                    const double kept = (length - trim) / length;
                    const std::pair<double, double> trimmed{from.first + (end.first - from.first) * kept,
                                                            from.second + (end.second - from.second) * kept};
                    shapes.push_back(_bridgeShape(from, trimmed, width, elementNet));
                }
                if (corner.has_value()) shapes.push_back(_bridgeShape(*corner, to, width, candidate->netName));
                shapes.push_back(_bridgeShape(to, to, width, candidate->netName));
                const bool clear = std::ranges::none_of(shapes, [&](const _BridgeShape& shape) {
                    for (std::size_t other = 0; other < placed.size(); ++other) {
                        if (other != index && _bridgeShapesClash(shape, placed[other])) return true;
                    }
                    return false;
                });
                if (!clear) continue;
                placed.insert(placed.end(), shapes.begin(), shapes.end());
                plans[index] = PortReturnBridge{candidate->padNumber, candidate->netName, to, corner, width};
                break;
            }
            if (plans[index].has_value()) break;
        }
    }
    return plans;
}

std::expected<void, std::string> resolveSimulationPorts(EMSConfig& config, const libkicad::Board& board) {
    auto edgeCutsOriginResult = _edgeCutsOrigin(board);
    if (!edgeCutsOriginResult) return std::unexpected(std::move(edgeCutsOriginResult).error());
    const Position& edgeCutsOrigin = *edgeCutsOriginResult;

    // Built lazily, once, the first time any simulation actually has a differential pair to
    // validate -- it's one extra whole-board query (see _NetConnectivity::build()) that every
    // other simulation with diff pairs reuses, and simulations without any never pay for at all.
    std::optional<_NetConnectivity> netConnectivity;
    // Likewise loaded once, the first time a simulation has a pin port to check for a via-in-pad.
    std::optional<_ReturnBridgeBoard> returnBridgeBoard;

    for (SimulationConfig& sim : config.simulations()) {
        // A Simulation Set template is never run itself -- only the simulations generated from it.
        if (sim.simulationSet()) continue;
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

        auto groundNamesResult = resolveGroundNetNames(board, sim.groundNet());
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
            auto nets = resolveInvolvedNetNames(board, entry);
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
            auto nets = resolveInvolvedNetNames(board, entry);
            if (!nets) return std::unexpected(std::move(nets).error());
            for (const std::string& netName : *nets) {
                // A broad geometry-only selector (typically a net class) can also cover a net that
                // another entry fully involves. That net's pads get their real ports from the main
                // per-pad loop below; terminating them here too would put a second lumped load on
                // the same pad, doubling every result column and loading the driven port.
                if (netOwner.contains(netName)) continue;
                auto padsResult = board.padsOnNet(netName);
                if (!padsResult) return std::unexpected(std::move(padsResult).error());
                for (const PadIdentity& pad : *padsResult) {
                    const PhysicalPin pinKey{pad.footprintRef, pad.padNumber};
                    const auto explicitChoice = explicitAbsorbingChoices.find(pinKey);
                    const bool automatic = explicitChoice == explicitAbsorbingChoices.end();
                    // A pad alone on its net (an NC ball's "unconnected-(...)" net) has no line to
                    // terminate, so it never absorbs by default; an explicit choice still applies.
                    const bool shouldAbsorb = automatic
                        ? padsResult->size() > 1 &&
                              pinTypeAbsorbsByDefault(pad.pinType, groundNets.contains(NetName(netName)))
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
                    port.setPlane(_planeForPortLayer(config, *layer, portEntry.plane()));
                    // A per-pin override wins over the entry's own impedance (45 ohms unless the
                    // board setup seeded another value when the net was included).
                    port.setImpedance(portEntry.pinImpedance(pad.footprintRef, pad.padNumber)
                                          .value_or(portEntry.impedance()));
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
                            std::to_string(port.plane()) + ", impedance " +
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
            auto padsResult = board.padsOnNet(netName);
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
                    // As for geometry-only nets: a pad alone on its net has nothing to terminate.
                    if (pads.size() > 1 &&
                        pinTypeAbsorbsByDefault(pad.pinType, groundNets.contains(NetName(netName)))) {
                        absorb = true;
                        isProbe = false;
                    }
                }
                // probe=false/absorb=false is a deliberately persisted no-port override (see
                // InvolvedNetConfig::setPinAbsorbOnly()). Presence in probedPins() alone is not
                // enough to build a port; either behavior must actually be enabled.
                // A load capacitance needs a port to hang from even on an otherwise port-less pin.
                const double loadCapacitance = entry.pinLoadCapacitance(pad.footprintRef, pad.padNumber).value_or(0);
                if (!isExcitationTarget && !absorb.value_or(false) && !isProbe.value_or(false) &&
                    loadCapacitance <= 0) {
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
                port.setPlane(_planeForPortLayer(config, *layer, entry.plane()));
                // A per-pin override wins over the entry's own impedance (see above).
                port.setImpedance(entry.pinImpedance(pad.footprintRef, pad.padNumber)
                                      .value_or(entry.impedance()));
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
                port.setLoadCapacitance(loadCapacitance);
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
                auto candidatesResult = _findTraceProbePoints(board, edgeCutsOrigin, config, netName, pads);
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
                    probe.setPlane(_planeForPortLayer(config, candidate.layer, entry.plane()));
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

        // A hull-cut port is keyed by its KiCad track, so it follows its cut as the hull moves along
        // that track; reconcileHullCutPorts() re-places it there. Once the hull no longer cuts the
        // track at all, the marker would otherwise still be built as a real port in the middle of
        // retained copper, so it is discarded along with anything driving it.
        if (!sim.hullCutPorts().empty()) {
            const auto simulationIndex = static_cast<std::size_t>(&sim - config.simulations().data());
            auto hullPlan = planHullCuts(config, simulationIndex, board);
            if (!hullPlan) return std::unexpected(std::move(hullPlan).error());
            reconcileHullCutPorts(sim, hullPlan->hullCuts);
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
            port.setPlane(_planeForPortLayer(config, *layer, authored.plane()));
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
            auto resolvedResult = board.resolvePin(excitation.footprint(),
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
            auto built = _NetConnectivity::build(board);
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

            // Every receiving component gets its own pair: the positive pin there is paired with the
            // negative pin opposite it on the same component (the nearest such pad, should a
            // footprint carry more than one). High-impedance receivers count -- a DQS strobe lands on
            // unterminated DRAM balls, and with two DRAMs on the bus there are four probed pins, not
            // two. Absorbing destinations sort first so a terminated far end stays the primary pair.
            const auto padDistance = [&](const PortConfig& a, const PortConfig& b) {
                if (!a.position().has_value() || !b.position().has_value()) return 0.0;
                return std::hypot(a.position()->first - b.position()->first,
                                  a.position()->second - b.position()->second);
            };
            std::vector<std::pair<std::int32_t, std::int32_t>> destinations;
            std::set<std::size_t> usedNegatives;
            for (const bool absorbing : {true, false}) {
                for (std::size_t pi = 0; pi < sim.ports().size(); ++pi) {
                    const PortConfig& p = sim.ports()[pi];
                    if (p.excite() || p.absorbSignal() != absorbing || !positiveNets.contains(p.netName()) ||
                        p.isTraceProbe() || p.footprintRef().empty()) {
                        continue;
                    }
                    std::optional<std::size_t> best;
                    for (std::size_t ni = 0; ni < sim.ports().size(); ++ni) {
                        const PortConfig& n = sim.ports()[ni];
                        if (n.excite() || n.absorbSignal() != absorbing || !negativeNets.contains(n.netName()) ||
                            n.isTraceProbe() || n.footprintRef() != p.footprintRef() || usedNegatives.contains(ni)) {
                            continue;
                        }
                        if (!best.has_value() || padDistance(p, n) < padDistance(p, sim.ports()[*best])) best = ni;
                    }
                    if (!best.has_value()) continue;
                    usedNegatives.insert(*best);
                    destinations.emplace_back(static_cast<std::int32_t>(pi), static_cast<std::int32_t>(*best));
                }
            }
            if (destinations.empty()) {
                logWarning("Simulation \"" + sim.name() + "\": differential pair " +
                           *positiveNets.begin() + " / " + *negativeNets.begin() +
                           " has no matching pair of destination pins on one component; skipping mixed-mode analysis");
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
            const PortConfig& sourceP = sim.ports()[static_cast<std::size_t>(source->first)];
            const PortConfig& sourceN = sim.ports()[static_cast<std::size_t>(source->second)];
            const std::string baseName = differentialPairBaseName(sourceP.netName(), sourceN.netName());
            for (const auto& destination : destinations) {
                DifferentialPairConfig pair;
                setRef(pair.positiveExcitation(), source->first);
                setRef(pair.negativeExcitation(), source->second);
                setRef(pair.positiveProbe(), destination.first);
                setRef(pair.negativeProbe(), destination.second);
                for (const std::string& net : positiveNets) setNet(pair.positiveNets(), net);
                for (const std::string& net : negativeNets) setNet(pair.negativeNets(), net);
                // One receiver keeps the bare pair name; several are told apart by component.
                const PortConfig& probeP = sim.ports()[static_cast<std::size_t>(destination.first)];
                pair.setName(destinations.size() == 1 ? baseName : baseName + " \u2192 " + probeP.footprintRef());
                pair.setAutomatic(true);
                sim.diffPairs().push_back(std::move(pair));
            }
        }

        for (SingleEndedConfig& trace : sim.traces()) {
            if (auto r = _resolvePortRef(board, trace.start(), portIndex, orderedNets, sim.name(), "trace start");
                !r) {
                return r;
            }
            if (auto r = _resolvePortRef(board, trace.stop(), portIndex, orderedNets, sim.name(), "trace stop"); !r) {
                return r;
            }
            trace.postInit();
        }

        for (DifferentialPairConfig& pair : sim.diffPairs()) {
            if (auto r = _resolvePortRef(board, pair.positiveExcitation(), portIndex, orderedNets, sim.name(),
                                          "differential pair positive_excitation");
                !r) {
                return r;
            }
            if (auto r = _resolvePortRef(board, pair.positiveProbe(), portIndex, orderedNets, sim.name(),
                                          "differential pair positive_probe");
                !r) {
                return r;
            }
            if (auto r = _resolvePortRef(board, pair.negativeExcitation(), portIndex, orderedNets, sim.name(),
                                          "differential pair negative_excitation");
                !r) {
                return r;
            }
            if (auto r = _resolvePortRef(board, pair.negativeProbe(), portIndex, orderedNets, sim.name(),
                                          "differential pair negative_probe");
                !r) {
                return r;
            }
            pair.postInit();
            if (!pair.correct()) continue;

            if (!netConnectivity.has_value()) {
                auto built = _NetConnectivity::build(board);
                if (!built) return std::unexpected(std::move(built).error());
                netConnectivity = std::move(*built);
            }
            const std::string pairLabel =
                "Simulation \"" + sim.name() + "\": differential pair " + pair.name().value_or("(unnamed)");
            const std::string positiveExcitationNet =
                sim.ports()[static_cast<std::size_t>(*pair.positiveExcitation().resolvedIndex())].netName();
            const std::string positiveProbeNet =
                sim.ports()[static_cast<std::size_t>(*pair.positiveProbe().resolvedIndex())].netName();
            auto positiveResult = _validateDiffPairSide(board, *netConnectivity, pair.positiveNets(),
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
            auto negativeResult = _validateDiffPairSide(board, *netConnectivity, pair.negativeNets(),
                                                          negativeExcitationNet, negativeProbeNet,
                                                          pairLabel + "'s negative_nets", sim.name());
            if (!negativeResult) return std::unexpected(std::move(negativeResult).error());
            if (negativeResult->has_value()) {
                logWarning(**negativeResult);
                pair.setCorrect(false);
            }
        }

        const bool hasPinPorts = std::ranges::any_of(
            sim.ports(), [](const PortConfig& port) { return !port.isTraceProbe() && !port.footprintRef().empty(); });
        if (hasPinPorts && !returnBridgeBoard.has_value()) {
            auto loaded = _loadReturnBridgeBoard(board, edgeCutsOrigin);
            if (!loaded) return std::unexpected(std::move(loaded).error());
            returnBridgeBoard = std::move(*loaded);
        }
        if (hasPinPorts) _assignReturnBridges(config, sim, *returnBridgeBoard, groundNets, edgeCutsOrigin);

        if (auto r = _resolveLumpedComponents(config, sim, board, edgeCutsOrigin, orderedNets); !r) {
            return r;
        }
    }
    return {};
}

} // namespace kiems
