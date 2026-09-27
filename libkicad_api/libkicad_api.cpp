// Public libkicad::countPads(), translating the c++20 implementation's plain RawPadCountsResult
// (libkicad.cpp, which can't be c++23 -- it includes KiCad headers that don't compile there) into
// the std::expected-based API declared in libkicad.hpp. This file has no KiCad includes, so it's
// compiled at c++23 via a per-file override rather than the libkicad target's default c++20.
#include "../libkicad/libkicad.hpp"

#include <algorithm>
#include <cmath>
#include <limits>

namespace libkicad {

std::expected<void, std::string> initialize() {
    std::string error;
    if (!detail::initializeRaw(error)) {
        return std::unexpected(std::move(error));
    }
    return {};
}

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

std::expected<std::string, std::string> netClassForNet(const std::string& projectPath,
                                                         const std::string& boardPath,
                                                         const std::string& netName) {
    detail::RawNetNameResult raw = detail::netClassForNetRaw(projectPath, boardPath, netName);
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

std::expected<std::vector<TrackSegment>, std::string> tracksOnNet(const std::string& projectPath,
                                                                    const std::string& boardPath,
                                                                    const std::string& netName) {
    detail::RawTracksOnNetResult raw = detail::tracksOnNetRaw(projectPath, boardPath, netName);
    if (!raw.ok) {
        return std::unexpected(std::move(raw.error));
    }
    return raw.tracks;
}

std::expected<std::vector<ZoneInfo>, std::string> zones(const std::string& projectPath,
                                                           const std::string& boardPath) {
    detail::RawZonesResult raw = detail::zonesRaw(projectPath, boardPath);
    if (!raw.ok) {
        return std::unexpected(std::move(raw.error));
    }
    return raw.zones;
}

std::expected<BoardGeometry, std::string> boardGeometry(const std::string& projectPath,
                                                           const std::string& boardPath) {
    detail::RawBoardGeometryResult raw = detail::boardGeometryRaw(projectPath, boardPath);
    if (!raw.ok) {
        return std::unexpected(std::move(raw.error));
    }
    return raw.geometry;
}

std::expected<std::vector<BoardLayerInfo>, std::string> boardLayers(const std::string& projectPath,
                                                                     const std::string& boardPath) {
    detail::RawBoardLayersResult raw = detail::boardLayersRaw(projectPath, boardPath);
    if (!raw.ok) return std::unexpected(std::move(raw.error));
    return raw.layers;
}

std::expected<BoardLayerGeometry, std::string> boardLayerGeometry(const std::string& projectPath,
                                                                   const std::string& boardPath,
                                                                   const std::string& layerName) {
    detail::RawBoardLayerGeometryResult raw =
        detail::boardLayerGeometryRaw(projectPath, boardPath, layerName);
    if (!raw.ok) return std::unexpected(std::move(raw.error));
    return raw.geometry;
}

std::expected<BoardBounds, std::string> boardBounds(const BoardGeometry& geometry) {
    BoardBounds result{std::numeric_limits<double>::infinity(), -std::numeric_limits<double>::infinity(),
                       std::numeric_limits<double>::infinity(), -std::numeric_limits<double>::infinity()};
    for (const PolygonLoop& loop : geometry.outline) {
        for (const auto& [x, y] : loop.pointsMm) {
            result.xMinMm = std::min(result.xMinMm, x);
            result.xMaxMm = std::max(result.xMaxMm, x);
            result.yMinMm = std::min(result.yMinMm, y);
            result.yMaxMm = std::max(result.yMaxMm, y);
        }
    }
    if (!std::isfinite(result.xMinMm) || !std::isfinite(result.yMinMm)) {
        return std::unexpected("Board geometry has no usable Edge.Cuts points");
    }
    return result;
}

std::expected<std::vector<PadPosition>, std::string> allPads(const std::string& projectPath,
                                                                const std::string& boardPath) {
    detail::RawPadsOnNetResult raw = detail::allPadsRaw(projectPath, boardPath);
    if (!raw.ok) {
        return std::unexpected(std::move(raw.error));
    }
    return raw.pads;
}

std::expected<std::vector<std::pair<std::string, TrackSegment>>, std::string> allTracks(
    const std::string& projectPath, const std::string& boardPath) {
    detail::RawAllTracksResult raw = detail::allTracksRaw(projectPath, boardPath);
    if (!raw.ok) {
        return std::unexpected(std::move(raw.error));
    }
    return raw.tracks;
}

std::expected<std::vector<StackupLayer>, std::string> stackup(const std::string& projectPath,
                                                                const std::string& boardPath) {
    detail::RawStackupResult raw = detail::stackupRaw(projectPath, boardPath);
    if (!raw.ok) {
        return std::unexpected(std::move(raw.error));
    }
    return raw.layers;
}

std::expected<std::vector<LayerColor>, std::string> layerColors(const std::string& projectPath,
                                                                  const std::string& boardPath) {
    detail::RawLayerColorsResult raw = detail::layerColorsRaw(projectPath, boardPath);
    if (!raw.ok) {
        return std::unexpected(std::move(raw.error));
    }
    return raw.colors;
}

std::expected<std::vector<NetColor>, std::string> netColors(const std::string& projectPath,
                                                              const std::string& boardPath) {
    detail::RawNetColorsResult raw = detail::netColorsRaw(projectPath, boardPath);
    if (!raw.ok) {
        return std::unexpected(std::move(raw.error));
    }
    return raw.colors;
}

std::expected<std::vector<std::string>, std::string> netClasses(const std::string& projectPath,
                                                                  const std::string& boardPath) {
    detail::RawStringListResult raw = detail::netClassesRaw(projectPath, boardPath);
    if (!raw.ok) {
        return std::unexpected(std::move(raw.error));
    }
    return raw.values;
}

std::expected<std::vector<std::string>, std::string> allNets(const std::string& projectPath,
                                                               const std::string& boardPath) {
    detail::RawStringListResult raw = detail::allNetsRaw(projectPath, boardPath);
    if (!raw.ok) {
        return std::unexpected(std::move(raw.error));
    }
    return raw.values;
}

std::expected<std::vector<FootprintInfo>, std::string> footprints(const std::string& projectPath,
                                                                    const std::string& boardPath) {
    detail::RawFootprintsResult raw = detail::footprintsRaw(projectPath, boardPath);
    if (!raw.ok) {
        return std::unexpected(std::move(raw.error));
    }
    return raw.footprints;
}

std::expected<std::vector<ThroughHole>, std::string> throughHoles(const std::string& projectPath,
                                                                     const std::string& boardPath) {
    detail::RawThroughHolesResult raw = detail::throughHolesRaw(projectPath, boardPath);
    if (!raw.ok) {
        return std::unexpected(std::move(raw.error));
    }
    return raw.holes;
}

std::expected<std::vector<NonPlatedHole>, std::string> nonPlatedHoles(const std::string& projectPath,
                                                                        const std::string& boardPath) {
    detail::RawNonPlatedHolesResult raw = detail::nonPlatedHolesRaw(projectPath, boardPath);
    if (!raw.ok) {
        return std::unexpected(std::move(raw.error));
    }
    return raw.holes;
}

std::expected<ComponentModelExportResult, std::string> exportComponentModels(const std::string& projectPath,
                                                                                const std::string& boardPath,
                                                                                const std::string& componentFilter,
                                                                                const std::string& outputStlPath) {
    detail::RawComponentModelExportResult raw =
        detail::exportComponentModelsRaw(projectPath, boardPath, componentFilter, outputStlPath);
    if (!raw.ok) {
        return std::unexpected(std::move(raw.error));
    }
    return raw.result;
}

} // namespace libkicad
