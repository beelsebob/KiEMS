#include "component_sim_model.hpp"

#include <algorithm>
#include <cmath>
#include <map>
#include <optional>
#include <tuple>
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

ComponentSimNetwork _unsupported(std::string reason) {
    return {false, std::move(reason), {}};
}

/// A two-terminal R/L/C combination, in whichever of the two forms the engine can represent it --
/// or, once a combination fits neither, not at all. Each form holds sums: a series impedance
/// R + sL + S/s (S the elastance, 1/C), a parallel admittance G + sC + Γ/s (Γ the inverse
/// inductance, 1/L). Zero means absent, so an all-zero series is a short and an all-zero parallel
/// an open circuit.
struct Impedance {
    enum class Form { Series, Parallel };
    Form form = Form::Series;
    double a = 0; // R or G
    double b = 0; // L or C
    double c = 0; // S or Γ

    static Impedance element(char kind, double value) {
        switch (kind) {
        case 'R': return value == 0 ? Impedance{} : Impedance{Form::Parallel, 1 / value, 0, 0};
        case 'L': return value == 0 ? Impedance{} : Impedance{Form::Parallel, 0, 0, 1 / value};
        default: return Impedance{Form::Parallel, 0, value, 0}; // 'C'
        }
    }

    bool isShort() const { return form == Form::Series && a == 0 && b == 0 && c == 0; }
    bool isOpen() const { return form == Form::Parallel && a == 0 && b == 0 && c == 0; }

    /// This impedance in `target` form, if it has one: a single R, L or C converts either way.
    std::optional<Impedance> as(Form target) const {
        if (form == target) return *this;
        const int present = (a != 0) + (b != 0) + (c != 0);
        if (present > 1) return std::nullopt;
        // A short has no parallel form, nor an open circuit a series one.
        if (present == 0) return std::nullopt;
        // R <-> G, L <-> 1/Γ, S <-> 1/C: the series L slot pairs with the parallel Γ slot.
        Impedance converted{target, 0, 0, 0};
        if (a != 0) converted.a = 1 / a;
        if (b != 0) converted.c = 1 / b;
        if (c != 0) converted.b = 1 / c;
        return converted;
    }

    static std::optional<Impedance> combine(const Impedance& first, const Impedance& second, Form form) {
        const std::optional<Impedance> x = first.as(form);
        const std::optional<Impedance> y = second.as(form);
        if (!x || !y) return std::nullopt;
        return Impedance{form, x->a + y->a, x->b + y->b, x->c + y->c};
    }
};

struct Edge {
    std::string node1;
    std::string node2;
    Impedance impedance;
    /// The elements this edge stands for, for messages.
    std::vector<std::string> elements;
};

std::string _nodeKey(const libkicad::ComponentSimNode& node) {
    using Kind = libkicad::ComponentSimNode::Kind;
    switch (node.kind) {
    case Kind::Pin: return "pin:" + node.name;
    case Kind::Ground: return "gnd:";
    case Kind::Internal: return "int:" + node.name;
    }
    return "int:" + node.name;
}

bool _isInternal(const std::string& key) {
    return key.starts_with("int:");
}

/// "pin 3", "ground" or "internal node C1.mid", for messages.
std::string _nodeDescription(const std::string& key) {
    if (key.starts_with("pin:")) return "pin " + key.substr(4);
    if (key == "gnd:") return "ground (SPICE node 0)";
    return "internal node " + key.substr(4);
}

std::string _elementList(const std::vector<std::string>& elements) {
    std::string list;
    for (std::size_t i = 0; i < std::min(elements.size(), kListedUnsupportedElements); ++i) {
        if (i > 0) list += ", ";
        list += elements[i];
    }
    if (elements.size() > kListedUnsupportedElements) {
        list += " and " + std::to_string(elements.size() - kListedUnsupportedElements) + " more";
    }
    return list;
}

/// One simplification pass over `edges`; true if anything changed. Fails (with `reason`) on a
/// combination neither form can represent, or a short between two external nodes.
bool _simplify(std::vector<Edge>& edges, std::string& reason) {
    // Self-loops and open circuits carry no current between distinct nodes.
    const std::size_t before = edges.size();
    std::erase_if(edges, [](const Edge& edge) { return edge.node1 == edge.node2 || edge.impedance.isOpen(); });
    if (edges.size() != before) return true;

    // A short merges its nodes; only internal ones can be renamed away.
    for (std::size_t i = 0; i < edges.size(); ++i) {
        if (!edges[i].impedance.isShort()) continue;
        std::string from = edges[i].node1;
        std::string to = edges[i].node2;
        if (!_isInternal(from)) std::swap(from, to);
        if (!_isInternal(from)) {
            reason = "SPICE model shorts " + _nodeDescription(edges[i].node1) + " to " +
                     _nodeDescription(edges[i].node2) + " (" + _elementList(edges[i].elements) + ")";
            return false;
        }
        edges.erase(edges.begin() + static_cast<std::ptrdiff_t>(i));
        for (Edge& edge : edges) {
            if (edge.node1 == from) edge.node1 = to;
            if (edge.node2 == from) edge.node2 = to;
        }
        return true;
    }

    std::map<std::string, std::vector<std::size_t>> incident;
    for (std::size_t i = 0; i < edges.size(); ++i) {
        incident[edges[i].node1].push_back(i);
        incident[edges[i].node2].push_back(i);
    }

    // A dead end: an internal node only one edge reaches carries no current.
    for (const auto& [node, list] : incident) {
        if (_isInternal(node) && list.size() == 1) {
            edges.erase(edges.begin() + static_cast<std::ptrdiff_t>(list[0]));
            return true;
        }
    }

    auto merge = [&](std::size_t keep, std::size_t drop, Impedance::Form form) {
        const std::optional<Impedance> combined = Impedance::combine(edges[keep].impedance, edges[drop].impedance, form);
        std::vector<std::string> elements = edges[keep].elements;
        elements.insert(elements.end(), edges[drop].elements.begin(), edges[drop].elements.end());
        if (!combined) {
            reason = std::string("SPICE model has ") + (form == Impedance::Form::Series ? "a series" : "a parallel") +
                     " combination that can't be one lumped element (" + _elementList(elements) + ")";
            return false;
        }
        edges[keep].impedance = *combined;
        edges[keep].elements = std::move(elements);
        edges.erase(edges.begin() + static_cast<std::ptrdiff_t>(drop));
        return true;
    };

    // Parallel: two edges between the same pair of nodes.
    for (std::size_t i = 0; i < edges.size(); ++i) {
        for (std::size_t j = i + 1; j < edges.size(); ++j) {
            const bool same = (edges[i].node1 == edges[j].node1 && edges[i].node2 == edges[j].node2) ||
                              (edges[i].node1 == edges[j].node2 && edges[i].node2 == edges[j].node1);
            if (same) return merge(i, j, Impedance::Form::Parallel);
        }
    }

    // Series: an internal node exactly two edges meet at.
    for (const auto& [node, list] : incident) {
        if (!_isInternal(node) || list.size() != 2) continue;
        const std::size_t keep = list[0];
        const std::size_t drop = list[1];
        const std::string farEnd = edges[drop].node1 == node ? edges[drop].node2 : edges[drop].node1;
        if (edges[keep].node1 == node) {
            edges[keep].node1 = farEnd;
        } else {
            edges[keep].node2 = farEnd;
        }
        return merge(keep, drop, Impedance::Form::Series);
    }
    return false;
}

} // namespace

ComponentSimNetwork componentSimNetwork(const libkicad::ComponentSimModel& model) {
    using Status = libkicad::ComponentSimModelStatus;
    switch (model.status) {
    case Status::NoSymbol:
        return _unsupported("No schematic symbol, so no SPICE model");
    case Status::ExcludedFromSimulation:
        return _unsupported("Excluded from simulation in the schematic");
    case Status::NoModel:
        return _unsupported("No SPICE model");
    case Status::Error:
        return _unsupported(model.message.empty() ? "The SPICE model could not be loaded"
                                                  : "The SPICE model could not be loaded: " + _firstLine(model.message));
    case Status::Resolved:
        break;
    }

    if (model.elements.empty()) {
        return _unsupported("The SPICE model contains no elements");
    }
    std::vector<std::string> unsupported;
    for (const libkicad::ComponentSimElement& element : model.elements) {
        if (!_isSupportedElement(element.kind)) unsupported.push_back(_elementDescription(element));
    }
    if (!unsupported.empty()) {
        return _unsupported("SPICE model contains un-simulatable parts: " + _elementList(unsupported));
    }

    std::vector<Edge> edges;
    for (const libkicad::ComponentSimElement& element : model.elements) {
        if (element.nodes.size() != 2) {
            return _unsupported("SPICE model element " + element.name + " doesn't have two terminals");
        }
        if (!element.numericValue || !std::isfinite(*element.numericValue)) {
            return _unsupported("SPICE model element " + element.name + "'s value \"" + element.value +
                                "\" couldn't be evaluated");
        }
        if (*element.numericValue < 0) {
            return _unsupported("SPICE model element " + element.name + " has a negative value");
        }
        edges.push_back({_nodeKey(element.nodes[0]), _nodeKey(element.nodes[1]),
                         Impedance::element(element.kind, *element.numericValue), {element.name}});
    }

    std::string reason;
    while (_simplify(edges, reason)) {
    }
    if (!reason.empty()) return _unsupported(reason);

    // Ground first: a shunt to ground usually also leaves its internal node unsimplified, and ground
    // is the better explanation.
    for (const Edge& edge : edges) {
        if (edge.node1 == "gnd:" || edge.node2 == "gnd:") {
            return _unsupported("SPICE model connects " +
                                _nodeDescription(edge.node1 == "gnd:" ? edge.node2 : edge.node1) +
                                " to ground (SPICE node 0), which can't be simulated yet (" +
                                _elementList(edge.elements) + ")");
        }
    }
    for (const Edge& edge : edges) {
        for (const std::string* node : {&edge.node1, &edge.node2}) {
            if (_isInternal(*node)) {
                return _unsupported("SPICE model's network doesn't simplify to series and parallel elements between "
                                    "its pins (at " + _nodeDescription(*node) + ")");
            }
        }
    }

    ComponentSimNetwork network{true, "", {}};
    for (const Edge& edge : edges) {
        ComponentSimBranch branch;
        branch.pin1 = edge.node1.substr(4);
        branch.pin2 = edge.node2.substr(4);
        auto present = [](double value) { return value != 0 ? value : std::numeric_limits<double>::quiet_NaN(); };
        // A single R, L or C stays a series element, as 2-pin parts always have been; only a
        // genuine R||C needs the parallel form.
        const Impedance z = edge.impedance.as(Impedance::Form::Series).value_or(edge.impedance);
        if (z.form == Impedance::Form::Parallel && z.c != 0) {
            // Copper's parallel elements have no inductance: only a lone inductor fits, as a series one.
            const std::optional<Impedance> series = z.as(Impedance::Form::Series);
            if (!series) {
                return _unsupported("SPICE model has an inductor in parallel with other elements, which can't be "
                                    "simulated yet (" + _elementList(edge.elements) + ")");
            }
            branch.topology = LumpedComponentTopology::Series;
            branch.inductance = series->b;
        } else if (z.form == Impedance::Form::Parallel) {
            branch.topology = LumpedComponentTopology::Parallel;
            branch.resistance = z.a != 0 ? 1 / z.a : std::numeric_limits<double>::quiet_NaN();
            branch.capacitance = present(z.b);
        } else {
            branch.topology = LumpedComponentTopology::Series;
            branch.resistance = present(z.a);
            branch.inductance = present(z.b);
            branch.capacitance = z.c != 0 ? 1 / z.c : std::numeric_limits<double>::quiet_NaN();
        }
        if (branch.pin2 < branch.pin1) std::swap(branch.pin1, branch.pin2);
        network.branches.push_back(std::move(branch));
    }
    std::ranges::sort(network.branches, [](const ComponentSimBranch& x, const ComponentSimBranch& y) {
        return std::tie(x.pin1, x.pin2) < std::tie(y.pin1, y.pin2);
    });
    return network;
}

ComponentSimModelSupport assessComponentSimModel(const libkicad::ComponentSimModel& model) {
    ComponentSimNetwork network = componentSimNetwork(model);
    return {network.supported, std::move(network.reason)};
}

} // namespace kiems
