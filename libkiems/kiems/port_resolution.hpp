// Resolves a SimulationConfig's involved_nets (net class / net / footprint+pin selectors) into
// concrete PortConfig objects, one per pad on each resolved net, via libkicad board queries and
// this pipeline's own copper Gerbers. Ported from the design in the "board slicing + net-driven
// ports and excitations" plan, not from any Python source (this whole feature is new).
#pragma once

#include <expected>
#include <string>
#include <string_view>

#include "config.hpp"
#include "paths_config.hpp"

namespace kiems {

/// Returns the shared signal name for a conventional P/N net pair. For example,
/// `/X/Y/Z/ABC+` and `/X/Y/Z/ABC-` become `/X/Y/Z/ABC`. Falls back to the two explicit net names
/// when they do not use a recognised complementary suffix.
std::string differentialPairBaseName(std::string_view positiveNet, std::string_view negativeNet);

/// A net's reference plane is one metal index counted from F.Cu, so it names the plane under the
/// top-side pads. A port on B.Cu gets the plane at the same depth from B.Cu instead: referenced to
/// the configured one, its z-directed box would run through the whole stack, and Copper's lumped
/// elements override PEC, so every via barrel inside it (a via-in-pad decoupling cap, say) would
/// become the port's resistor. Inner-layer ports keep the configured plane.
std::int32_t referencePlaneForPortLayer(std::int32_t layer, std::int32_t plane, std::int32_t metalCount);

/// The schematic pin types which represent a receiving/load-capable endpoint get a real 45-ohm
/// termination by default. Ground pins never do; explicit per-pin configuration can still override
/// this default in either direction.
bool pinTypeAbsorbsByDefault(std::string_view pinType, bool directlyConnectedToGround);

/// Whether a pin on an Included-in-Simulation (GeometryOnly) net still needs a physical absorbing
/// termination. Its Probe flag is deliberately irrelevant here: geometry-only nets cannot expose
/// reportable probes, but an enabled Absorb choice must still load the trace.
bool geometryOnlyPinNeedsAbsorbingPort(const InvolvedNetConfig& entry,
                                       const std::string& footprint, const std::string& pin);

/// Populates every SimulationConfig's ports() (one PortConfig per pad on each resolved involved
/// net, always excite()==true), resolves each ExcitationConfig's driven port and each
/// SingleEndedConfig/DifferentialPairConfig PortRef against those ports (running their postInit()
/// validation once resolved), for every simulation in config.simulations().
///
/// Requires `fab/board.kicad_pcb` (written by exportKicadPcb()) to exist; `net_class`-kind
/// involved-net/ground-net entries additionally require a sibling `fab/board.kicad_pro`. Fails on
/// any unresolvable reference (unknown net/net class/footprint/pin, a pad whose port direction
/// can't be derived, an excitation or trace/differential-pair endpoint that doesn't belong to its
/// simulation's involved nets).
std::expected<void, std::string> resolveSimulationPorts(EMSConfig& config, const libkicad::Board& board);

} // namespace kiems
