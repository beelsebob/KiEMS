// KiCad net names come back from libkicad_query with a literal '/' escaped as the placeholder token
// "{slash}" (KiCad's own internal/UI convention for hierarchical-sheet-path net names, e.g.
// "/MCU/USB/Upstream/SSRx-"). Gerber files' own %TO.N net-name attributes carry the real, unescaped
// character -- KiCad's Gerber export never applies that placeholder scheme. Comparing a net name
// pulled from one of these two sources directly against one pulled from the other via plain
// std::string equality silently fails to match for any net with a slash in it (a real bug this
// project hit once already). NetName exists so that mistake becomes structurally impossible: it
// stores whatever string it was constructed from unaltered, and normalizes internally before ever
// comparing two instances, so it does not matter which of the two source conventions either side
// came from.
#pragma once

#include <cstddef>
#include <functional>
#include <string>
#include <string_view>

#include <nlohmann/json.hpp>

namespace gerber2ems {

class NetName {
public:
    NetName() = default;
    explicit NetName(std::string original) : _original(std::move(original)) {}

    /// The exact string this NetName was constructed from, unaltered. Pass this back into any
    /// libkicad_query call, JSON field, or Obj-C++/Swift bridge boundary expecting to round-trip the
    /// same representation this NetName came from -- never use it to compare against or look up in
    /// Gerber-derived data (CopperOp::net, Pad::net(), GerberFile::traceForNet()), which is in the
    /// other, unescaped convention.
    const std::string& raw() const { return _original; }

    /// The "/"-unescaped form -- safe for comparing against or looking up in Gerber-derived data, and
    /// safe to interpolate into a human-facing log/error message. A NetName built from Gerber data
    /// already has no "{slash}" token to replace, so this is always a safe no-op for that case --
    /// meaning it is correct to call regardless of which of the two source conventions this
    /// particular NetName came from.
    std::string unescaped() const;

    /// Comparisons always normalize via unescaped() first, so a NetName built from KiCad's own
    /// escaped form and one built from raw Gerber data compare equal correctly when they name the
    /// same real net -- nobody has to remember which form they are holding before comparing two
    /// NetNames.
    bool operator==(const NetName& other) const { return unescaped() == other.unescaped(); }
    bool operator!=(const NetName& other) const { return !(*this == other); }
    bool operator<(const NetName& other) const { return unescaped() < other.unescaped(); }

    bool empty() const { return _original.empty(); }

private:
    std::string _original;
};

/// Hash consistent with NetName::operator== (hashes the normalized/unescaped form).
struct NetNameHash {
    std::size_t operator()(const NetName& name) const {
        return std::hash<std::string>{}(name.unescaped());
    }
};

inline std::string NetName::unescaped() const {
    constexpr std::string_view kEscapedSlash = "{slash}";
    std::string result = _original;
    std::size_t pos = 0;
    while ((pos = result.find(kEscapedSlash, pos)) != std::string::npos) {
        result.replace(pos, kEscapedSlash.size(), "/");
        pos += 1;
    }
    return result;
}

/// Serializes/deserializes via raw() -- the on-disk (KiCad-escaped) form, matching what every
/// existing net-name JSON field already stored before NetName existed, so no config migration is
/// needed.
inline void to_json(nlohmann::json& j, const NetName& name) { j = name.raw(); }
inline void from_json(const nlohmann::json& j, NetName& name) { name = NetName(j.get<std::string>()); }

} // namespace gerber2ems
