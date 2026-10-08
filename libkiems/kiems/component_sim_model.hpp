// Decides whether KiEMS can simulate a component from the SPICE model KiCad resolves for it
// (libkicad::Board::componentSimModels()).
#pragma once

#include "libkicad/libkicad_result.hpp"

#include <string>

namespace kiems {

struct ComponentSimModelSupport {
    bool supported = false;
    /// Empty when supported; otherwise one sentence saying why not, for display.
    std::string reason;
};

/// Only resistors, capacitors and inductors can become lumped elements today, so a model is
/// supported when KiCad resolved it to at least one element and every element is an R, L or C.
ComponentSimModelSupport assessComponentSimModel(const libkicad::ComponentSimModel& model);

} // namespace kiems
