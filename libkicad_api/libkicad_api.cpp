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

std::expected<std::string, std::string> netForFootprintPin(const std::string& projectPath,
                                                             const std::string& boardPath,
                                                             const std::string& footprintRef, const std::string& pin) {
    detail::RawNetNameResult raw = detail::netForFootprintPinRaw(projectPath, boardPath, footprintRef, pin);
    if (!raw.ok) {
        return std::unexpected(std::move(raw.error));
    }
    return raw.netName;
}

std::expected<PadPosition, std::string> resolvePin(const std::string& projectPath, const std::string& boardPath,
                                                     const std::string& footprintRef, const std::string& pin) {
    detail::RawPadResult raw = detail::resolvePinRaw(projectPath, boardPath, footprintRef, pin);
    if (!raw.ok) {
        return std::unexpected(std::move(raw.error));
    }
    return raw.pad;
}

std::expected<std::vector<std::string>, std::string> netsInNetClass(const std::string& projectPath,
                                                                      const std::string& boardPath,
                                                                      const std::string& netClassName) {
    detail::RawNetClassMembersResult raw = detail::netsInNetClassRaw(projectPath, boardPath, netClassName);
    if (!raw.ok) {
        return std::unexpected(std::move(raw.error));
    }
    return raw.netNames;
}

std::expected<std::vector<PadPosition>, std::string> padsOnNet(const std::string& projectPath,
                                                                 const std::string& boardPath,
                                                                 const std::string& netName) {
    detail::RawPadsOnNetResult raw = detail::padsOnNetRaw(projectPath, boardPath, netName);
    if (!raw.ok) {
        return std::unexpected(std::move(raw.error));
    }
    return raw.pads;
}

} // namespace libkicad
