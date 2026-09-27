#include "geometry.hpp"

#include <cmath>

namespace Cu {

void Position::rotate(double angle) {
    const double newX = _x * std::cos(angle) + _y * std::sin(angle);
    const double newY = _x * std::sin(angle) + _y * std::cos(angle);
    _x = newX;
    _y = newY;
}

void Position::scale(double factor) {
    _x *= factor;
    _y *= factor;
}

void Position::move(const Position& offset) {
    _x += offset._x;
    _y += offset._y;
}

void to_json(nlohmann::json& j, const Position& p) { j = nlohmann::json{{"x", p._x}, {"y", p._y}}; }

void from_json(const nlohmann::json& j, Position& p) {
    j.at("x").get_to(p._x);
    j.at("y").get_to(p._y);
}

} // namespace Cu
