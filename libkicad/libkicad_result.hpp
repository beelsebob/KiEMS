// Plain data shared between libkicad.cpp (compiled at c++20, matching KiCad's own headers, which
// don't compile at c++23 on this checkout) and libkicad_api.cpp (compiled at c++23, so it can
// return the public std::expected-based API from libkicad.hpp). No KiCad headers and no
// <expected> here, so this stays includable from either translation unit.
#pragma once

#include <cstdint>
#include <string>

namespace libkicad {

struct PadCounts {
    std::int32_t footprintCount = 0;
    std::int32_t trackCount = 0;
    std::int32_t zoneCount = 0;
    std::int32_t padCount = 0;
};

namespace detail {

struct RawPadCountsResult {
    bool ok = false;
    std::string error;
    PadCounts counts;
};

RawPadCountsResult countPadsRaw(const std::string& projectPath, const std::string& boardPath);

} // namespace detail
} // namespace libkicad
