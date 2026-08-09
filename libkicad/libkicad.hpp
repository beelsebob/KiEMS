// Experimental in-process KiCad board query: drives the same API_HANDLER_PCB / protobuf command
// path KiCad's own IPC API server uses, without a PCB_EDIT_FRAME, KIWAY, or wx GUI window. See
// libkicad.cpp for the chain: SETTINGS_MANAGER -> PCB_IO_KICAD_SEXPR -> HEADLESS_PCB_CONTEXT ->
// API_HANDLER_PCB::Handle(GetItems).
//
// This header requires c++23 (std::expected) and must never be included from a translation unit
// that also includes KiCad's own headers -- those don't compile at c++23 on this checkout. See
// libkicad_result.hpp for the plain-data type shared across the c++20/c++23 boundary, and
// libkicad_api.cpp for where the two sides meet.
#pragma once

#include <expected>
#include <string>
#include <vector>

#include "libkicad_result.hpp"

namespace libkicad {

std::expected<PadCounts, std::string> countPads(const std::string& projectPath, const std::string& boardPath);

/// Resolves the net connected to one footprint's pin. `pin` is tried first as a pad number
/// (PAD::GetNumber(), e.g. "3"), then as a schematic pin name (PAD::GetPinFunction(), e.g. "GND")
/// if no pad matches by number.
std::expected<std::string, std::string> netForFootprintPin(const std::string& projectPath,
                                                             const std::string& boardPath,
                                                             const std::string& footprintRef, const std::string& pin);

/// Resolves one footprint's pin to its full pad identity (including position/orientation/layer and
/// which net it's on) -- the same pad lookup as netForFootprintPin, but returning everything about
/// that specific pad rather than just its net name. Used to match a footprint+pin selector
/// (ExcitationConfig, a trace/differential-pair PortRef) back to one already-resolved port.
std::expected<PadPosition, std::string> resolvePin(const std::string& projectPath, const std::string& boardPath,
                                                     const std::string& footprintRef, const std::string& pin);

/// Every net assigned to the given netclass (by name). Requires the board to have a linked
/// project (a sibling .kicad_pro) for netclass assignment to be resolvable at all.
std::expected<std::vector<std::string>, std::string> netsInNetClass(const std::string& projectPath,
                                                                      const std::string& boardPath,
                                                                      const std::string& netClassName);

/// Every pad connected to the given net, with position/orientation/layer for port placement.
std::expected<std::vector<PadPosition>, std::string> padsOnNet(const std::string& projectPath,
                                                                 const std::string& boardPath,
                                                                 const std::string& netName);

/// The board's physical stackup (Board Setup > Board Stackup), top-to-bottom -- solder mask/paste/
/// silkscreen entries are omitted, only copper and dielectric layers are returned. If the board's
/// file has no explicit stackup section, this is KiCad's own computed default for its layer count,
/// not an error.
std::expected<std::vector<StackupLayer>, std::string> stackup(const std::string& projectPath,
                                                                const std::string& boardPath);

} // namespace libkicad
