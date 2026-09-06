// Resolves a SimulationConfig's involved_nets (net class / net / footprint+pin selectors) into
// concrete PortConfig objects, one per pad on each resolved net, via libkicad board queries and
// this pipeline's own copper Gerbers. Ported from the design in the "board slicing + net-driven
// ports and excitations" plan, not from any Python source (this whole feature is new).
#pragma once

#include <expected>
#include <string>

#include "config.hpp"
#include "paths_config.hpp"

namespace kiems {

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
std::expected<void, std::string> resolveSimulationPorts(EMSConfig& config, const PathsConfig& paths);

} // namespace kiems
