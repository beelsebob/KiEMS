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

#include "libkicad_result.hpp"

namespace libkicad {

std::expected<PadCounts, std::string> countPads(const std::string& projectPath, const std::string& boardPath);

} // namespace libkicad
