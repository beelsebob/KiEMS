// Plain 2D geometry primitives shared across every consumer that needs simulation-unit (or
// millimetre, depending on call site) coordinates -- originally part of kiems' own Gerber-file
// model (gerber_io.hpp), kept here now that board geometry is sourced directly from KiCad rather
// than parsed Gerber files, since these two types never had anything Gerber-specific about them.
#pragma once

#include <nlohmann/json.hpp>

namespace Cu {

/// Coordinates of a 2D point.
class Position {
public:
    Position() = default;
    Position(double x, double y) : _x(x), _y(y) {}

    double x() const { return _x; }
    double y() const { return _y; }
    void setX(double value) { _x = value; }
    void setY(double value) { _y = value; }

    void mirrorX() { _x = -_x; }
    void mirrorY() { _y = -_y; }
    /// Rotate point around (0,0). NOTE: mirrors the original Python source's formula exactly, which
    /// passes its angle straight into std::cos/std::sin without a degrees->radians conversion
    /// despite callers treating the angle as degrees; preserved for behavioural fidelity.
    void rotate(double angle);
    void scale(double factor);
    void move(const Position& offset);

private:
    friend void to_json(nlohmann::json& j, const Position& p);
    friend void from_json(const nlohmann::json& j, Position& p);

    double _x = 0;
    double _y = 0;
};

void to_json(nlohmann::json& j, const Position& p);
void from_json(const nlohmann::json& j, Position& p);

/// A single mesh triangle, in whatever frame its own producer documents (simulation units,
/// already re-origined so some bounding-box minimum corner maps to (0,0), for every kiems
/// consumer). `a`/`b`/`c` are plain vertices in (x, y) order.
struct Triangle {
    Position a;
    Position b;
    Position c;
};

inline void to_json(nlohmann::json& j, const Triangle& t) { j = nlohmann::json{{"a", t.a}, {"b", t.b}, {"c", t.c}}; }

inline void from_json(const nlohmann::json& j, Triangle& t) {
    j.at("a").get_to(t.a);
    j.at("b").get_to(t.b);
    j.at("c").get_to(t.c);
}

} // namespace Cu
