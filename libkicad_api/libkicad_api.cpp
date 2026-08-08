// Public libkicad::countPads(), translating the c++20 implementation's plain RawPadCountsResult
// (libkicad.cpp, which can't be c++23 -- it includes KiCad headers that don't compile there) into
// the std::expected-based API declared in libkicad.hpp. This file has no KiCad includes, so it's
// compiled at c++23 via a per-file override rather than the libkicad target's default c++20.
#include "../libkicad/libkicad.hpp"

namespace libkicad {

std::expected<PadCounts, std::string> countPads(const std::string& projectPath, const std::string& boardPath) {
    detail::RawPadCountsResult raw = detail::countPadsRaw(projectPath, boardPath);
    if (!raw.ok) {
        return std::unexpected(std::move(raw.error));
    }
    return raw.counts;
}

} // namespace libkicad
