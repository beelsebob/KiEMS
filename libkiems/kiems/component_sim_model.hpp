// Decides whether KiEMS can simulate a component from the SPICE model KiCad resolves for it
// (libkicad::Board::componentSimModels()), and reduces a simulatable model to the lumped elements
// that stand in for it.
#pragma once

#include "config.hpp"
#include "libkicad/libkicad_result.hpp"

#include <limits>
#include <string>
#include <vector>

namespace kiems {

/// One lumped element between two of a component's pins, equivalent to the part of its SPICE
/// model connecting them. NaN means that quantity is absent, as LumpedComponentConfig has it.
struct ComponentSimBranch {
    /// Pad numbers.
    std::string pin1;
    std::string pin2;
    LumpedComponentTopology topology = LumpedComponentTopology::Series;
    double resistance = std::numeric_limits<double>::quiet_NaN();
    double inductance = std::numeric_limits<double>::quiet_NaN();
    double capacitance = std::numeric_limits<double>::quiet_NaN();
};

struct ComponentSimNetwork {
    bool supported = false;
    /// Empty when supported; otherwise one sentence saying why not, for display.
    std::string reason;
    /// When supported: one branch per pair of pins the model connects, in pin order. Empty for a
    /// model that connects nothing (every element open-circuited).
    std::vector<ComponentSimBranch> branches;
};

/// Reduces a model made only of resistors, capacitors and inductors to its lumped branches. Its
/// network is simplified by merging parallel elements, collapsing series chains through internal
/// nodes and dropping dead ends; every pin-to-pin branch left must then be one element the engine
/// supports -- a series R+L+C or a parallel R||C (any of each may be absent). A model with any
/// other element, a value that can't be evaluated, a branch to ground (SPICE node 0), a bridged
/// network that doesn't simplify, or a branch that isn't one of those two forms isn't supported.
ComponentSimNetwork componentSimNetwork(const libkicad::ComponentSimModel& model);

struct ComponentSimModelSupport {
    bool supported = false;
    /// Empty when supported; otherwise one sentence saying why not, for display.
    std::string reason;
};

/// Whether componentSimNetwork() supports the model, and if not why.
ComponentSimModelSupport assessComponentSimModel(const libkicad::ComponentSimModel& model);

} // namespace kiems
