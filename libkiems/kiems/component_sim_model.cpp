#include "component_sim_model.hpp"

#include <algorithm>
#include <vector>

namespace kiems {

namespace {

/// How many offending elements a reason lists before summarizing the rest.
constexpr std::size_t kListedUnsupportedElements = 3;

bool _isSupportedElement(char kind) {
    return kind == 'R' || kind == 'L' || kind == 'C';
}

std::string _elementDescription(const libkicad::ComponentSimElement& element) {
    const char* kind = nullptr;
    switch (element.kind) {
    case 'A': kind = "code model"; break;
    case 'B': kind = "behavioral source"; break;
    case 'D': kind = "diode"; break;
    case 'E': case 'F': case 'G': case 'H': kind = "controlled source"; break;
    case 'I': kind = "current source"; break;
    case 'J': kind = "JFET"; break;
    case 'K': kind = "coupled inductors"; break;
    case 'M': kind = "MOSFET"; break;
    case 'O': case 'T': case 'U': kind = "transmission line"; break;
    case 'Q': kind = "bipolar transistor"; break;
    case 'S': case 'W': kind = "switch"; break;
    case 'V': kind = "voltage source"; break;
    case 'Z': kind = "MESFET"; break;
    default: break;
    }
    // An unexpanded subcircuit carries its own explanation.
    if (element.kind == 'X') return element.name + " (" + element.value + ")";
    return kind ? element.name + " (" + kind + ")" : element.name;
}

std::string _firstLine(const std::string& text) {
    return text.substr(0, text.find('\n'));
}

} // namespace

ComponentSimModelSupport assessComponentSimModel(const libkicad::ComponentSimModel& model) {
    using Status = libkicad::ComponentSimModelStatus;
    switch (model.status) {
    case Status::NoSymbol:
        return {false, "No schematic symbol, so no SPICE model"};
    case Status::ExcludedFromSimulation:
        return {false, "Excluded from simulation in the schematic"};
    case Status::NoModel:
        return {false, "No SPICE model"};
    case Status::Error:
        return {false, model.message.empty() ? "The SPICE model could not be loaded"
                                             : "The SPICE model could not be loaded: " + _firstLine(model.message)};
    case Status::Resolved:
        break;
    }

    if (model.elements.empty()) {
        return {false, "The SPICE model contains no elements"};
    }
    std::vector<const libkicad::ComponentSimElement*> unsupported;
    for (const libkicad::ComponentSimElement& element : model.elements) {
        if (!_isSupportedElement(element.kind)) unsupported.push_back(&element);
    }
    if (unsupported.empty()) {
        return {true, ""};
    }

    std::string reason = "SPICE model contains un-simulatable parts: ";
    for (std::size_t i = 0; i < std::min(unsupported.size(), kListedUnsupportedElements); ++i) {
        if (i > 0) reason += ", ";
        reason += _elementDescription(*unsupported[i]);
    }
    if (unsupported.size() > kListedUnsupportedElements) {
        reason += " and " + std::to_string(unsupported.size() - kListedUnsupportedElements) + " more";
    }
    return {false, reason};
}

} // namespace kiems
