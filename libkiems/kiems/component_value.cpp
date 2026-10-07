#include "component_value.hpp"

#include <algorithm>
#include <cctype>
#include <cmath>
#include <cstdlib>

namespace kiems {

namespace {

std::string _trim(const std::string& s) {
    std::size_t start = 0;
    while (start < s.size() && std::isspace(static_cast<unsigned char>(s[start])) != 0) {
        ++start;
    }
    std::size_t end = s.size();
    while (end > start && std::isspace(static_cast<unsigned char>(s[end - 1])) != 0) {
        --end;
    }
    return s.substr(start, end - start);
}

// Strips a trailing unit word (case-insensitive) matching `unitLetter`, if present. 'R' additionally
// accepts both Unicode spellings commonly used for ohms: U+03A9 GREEK CAPITAL LETTER OMEGA and
// U+2126 OHM SIGN, plus the word "ohm"/"ohms". 'H'/'F' only ever appear as the bare letter in
// KiCad's own convention.
std::string _stripUnitWord(const std::string& s, char unitLetter) {
    if (unitLetter == 'R') {
        constexpr char kGreekOmega[] = "\xCE\xA9"; // U+03A9 GREEK CAPITAL LETTER OMEGA
        constexpr char kOhmSign[] = "\xE2\x84\xA6"; // U+2126 OHM SIGN
        if (s.size() >= 2 && s.compare(s.size() - 2, 2, kGreekOmega) == 0) {
            return s.substr(0, s.size() - 2);
        }
        if (s.size() >= 3 && s.compare(s.size() - 3, 3, kOhmSign) == 0) {
            return s.substr(0, s.size() - 3);
        }
        auto lower = s;
        std::transform(lower.begin(), lower.end(), lower.begin(),
                        [](unsigned char c) { return static_cast<char>(std::tolower(c)); });
        if (lower.size() >= 4 && lower.compare(lower.size() - 4, 4, "ohms") == 0) {
            return s.substr(0, s.size() - 4);
        }
        if (lower.size() >= 3 && lower.compare(lower.size() - 3, 3, "ohm") == 0) {
            return s.substr(0, s.size() - 3);
        }
        return s;
    }
    if (!s.empty() && std::toupper(static_cast<unsigned char>(s.back())) == unitLetter) {
        return s.substr(0, s.size() - 1);
    }
    return s;
}

// Multiplier for a marker character, or 0 if `c` isn't a recognized marker. `allowBareUnit` permits
// 'R'/Ohm-sign as a 1x marker (resistors only -- KiCad's "0R1"/"4R7"/"1R" forms).
double _markerMultiplier(char c, bool allowBareUnit) {
    switch (c) {
    case 'T':
        return 1e12;
    case 'G':
        return 1e9;
    case 'M':
        return 1e6;
    case 'k':
    case 'K':
        return 1e3;
    case 'm':
        return 1e-3;
    case 'u':
        return 1e-6;
    case 'n':
        return 1e-9;
    case 'p':
        return 1e-12;
    case 'R':
        return allowBareUnit ? 1.0 : 0.0;
    default:
        return 0.0;
    }
}

bool _isMarkerChar(char c, bool allowBareUnit) { return _markerMultiplier(c, allowBareUnit) != 0.0 || c == 'R'; }

// The trailing-unit-word letter _stripUnitWord() looks for -- 'R' additionally accepts the UTF-8
// Ohm sign and "ohm"/"ohms" (see that function's own doc comment), 'H'/'F' only ever appear as the
// bare letter in KiCad's own convention.
char _unitLetter(ComponentUnit unit) {
    switch (unit) {
    case ComponentUnit::Resistance:
        return 'R';
    case ComponentUnit::Inductance:
        return 'H';
    case ComponentUnit::Capacitance:
        return 'F';
    }

    return '\0';
}

} // namespace

std::optional<double> parseComponentValue(const std::string& raw, ComponentUnit unit) {
    const char unitLetter = _unitLetter(unit);
    std::string s = _trim(raw);
    if (s.empty()) {
        return std::nullopt;
    }
    // 'µ' (U+00B5 MICRO SIGN, UTF-8 0xC2 0xB5) is a common alternate spelling of 'u' -- normalize
    // before the rest of the scan, which otherwise only knows about plain ASCII markers.
    for (std::size_t i = 0; i + 1 < s.size();) {
        if (static_cast<unsigned char>(s[i]) == 0xC2 && static_cast<unsigned char>(s[i + 1]) == 0xB5) {
            s.replace(i, 2, "u");
            ++i;
        } else {
            ++i;
        }
    }
    s = _stripUnitWord(s, unitLetter);
    if (s.empty()) {
        return std::nullopt;
    }

    const bool allowBareUnit = (unitLetter == 'R');
    std::optional<std::size_t> markerPos;
    for (std::size_t i = 0; i < s.size(); ++i) {
        if (_isMarkerChar(s[i], allowBareUnit)) {
            if (markerPos.has_value()) {
                return std::nullopt; // more than one marker -- ambiguous, refuse to guess
            }
            markerPos = i;
        }
    }

    std::string numeric;
    double multiplier = 1.0;
    if (!markerPos.has_value()) {
        numeric = s;
    } else {
        const char marker = s[*markerPos];
        multiplier = _markerMultiplier(marker, allowBareUnit);
        if (*markerPos + 1 == s.size()) {
            // Trailing multiplier suffix, e.g. "10k", "100n" -- drop the marker, no substitution.
            numeric = s.substr(0, *markerPos);
        } else {
            // Decimal-substitution form, e.g. "4k7" -> "4.7", "0R1" -> "0.1".
            numeric = s.substr(0, *markerPos) + "." + s.substr(*markerPos + 1);
        }
    }
    if (numeric.empty() || numeric == ".") {
        return std::nullopt;
    }

    char* end = nullptr;
    const double value = std::strtod(numeric.c_str(), &end);
    if (end == nullptr || *end != '\0' || end == numeric.c_str()) {
        return std::nullopt;
    }
    return value * multiplier;
}

std::optional<double> parseSensibleComponentValue(const std::string& raw, ComponentUnit unit) {
    const std::optional<double> parsed = parseComponentValue(raw, unit);
    if (!parsed.has_value() || !std::isfinite(*parsed) || *parsed < 0.0) {
        return std::nullopt;
    }
    if (*parsed == 0.0) {
        // "0 ohm" is the conventional value marking for a real conductive jumper, not an absent
        // component. Ordinary chip jumpers are commonly in the low tens of milliohms; 10 mOhm is
        // a conservative generic substitute when the board carries no exact part specification.
        return unit == ComponentUnit::Resistance ? std::optional<double>(0.01) : std::nullopt;
    }
    return parsed;
}

} // namespace kiems
