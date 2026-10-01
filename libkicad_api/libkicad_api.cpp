// Public libkicad::countPads(), translating the c++20 implementation's plain RawPadCountsResult
// (libkicad.cpp, which can't be c++23 -- it includes KiCad headers that don't compile there) into
// the std::expected-based API declared in libkicad.hpp. This file has no KiCad includes, so it's
// compiled at c++23 via a per-file override rather than the libkicad target's default c++20.
#include "../libkicad/libkicad.hpp"

#include <algorithm>
#include <cmath>
#include <limits>

namespace libkicad {

std::expected<Runtime, std::string> Runtime::create() {
    std::string error;
    detail::RuntimeState* state = detail::createRuntimeRaw(error);
    if (!state) {
        return std::unexpected(std::move(error));
    }
    return Runtime(state);
}

void Runtime::Deleter::operator()(detail::RuntimeState* state) const {
    detail::destroyRuntimeRaw(state);
}

Board::Board(Runtime& runtime, std::string projectPath, std::string boardPath)
    : _paths{std::move(projectPath), std::move(boardPath)},
      _state(detail::createBoardRaw(*runtime._state, _paths.projectPath, _paths.boardPath)) {}

void Board::Deleter::operator()(detail::BoardState* state) const {
    detail::destroyBoardRaw(state);
}

std::expected<PadCounts, std::string> Board::countPads() const {
    detail::RawPadCountsResult raw = detail::countPadsRaw(*_state);
    if (!raw.ok) {
        return std::unexpected(std::move(raw.error));
    }
    return raw.counts;
}

std::expected<std::string, std::string> Board::netForFootprintPin(const std::string& footprintRef,
        const std::string& pin) const {
    detail::RawNetNameResult raw = detail::netForFootprintPinRaw(*_state, footprintRef, pin);
    if (!raw.ok) {
        return std::unexpected(std::move(raw.error));
    }
    return raw.netName;
}

std::expected<std::string, std::string> Board::netClassForNet(const std::string& netName) const {
    detail::RawNetNameResult raw = detail::netClassForNetRaw(*_state, netName);
    if (!raw.ok) {
        return std::unexpected(std::move(raw.error));
    }
    return raw.netName;
}

std::expected<PadPosition, std::string> Board::resolvePin(const std::string& footprintRef,
        const std::string& pin) const {
    detail::RawPadResult raw = detail::resolvePinRaw(*_state, footprintRef, pin);
    if (!raw.ok) {
        return std::unexpected(std::move(raw.error));
    }
    return raw.pad;
}

std::expected<std::vector<std::string>, std::string> Board::netsInNetClass(const std::string& netClassName) const {
    detail::RawNetClassMembersResult raw = detail::netsInNetClassRaw(*_state, netClassName);
    if (!raw.ok) {
        return std::unexpected(std::move(raw.error));
    }
    return raw.netNames;
}

std::expected<std::vector<PadPosition>, std::string> Board::padsOnNet(const std::string& netName) const {
    detail::RawPadsOnNetResult raw = detail::padsOnNetRaw(*_state, netName);
    if (!raw.ok) {
        return std::unexpected(std::move(raw.error));
    }
    return raw.pads;
}

std::expected<std::vector<TrackSegment>, std::string> Board::tracksOnNet(const std::string& netName) const {
    detail::RawTracksOnNetResult raw = detail::tracksOnNetRaw(*_state, netName);
    if (!raw.ok) {
        return std::unexpected(std::move(raw.error));
    }
    return raw.tracks;
}

std::expected<std::vector<ZoneInfo>, std::string> Board::zones() const {
    detail::RawZonesResult raw = detail::zonesRaw(*_state);
    if (!raw.ok) {
        return std::unexpected(std::move(raw.error));
    }
    return raw.zones;
}

std::expected<BoardGeometry, std::string> Board::boardGeometry() const {
    detail::RawBoardGeometryResult raw = detail::boardGeometryRaw(*_state);
    if (!raw.ok) {
        return std::unexpected(std::move(raw.error));
    }
    return raw.geometry;
}

std::expected<std::vector<BoardLayerInfo>, std::string> Board::boardLayers() const {
    detail::RawBoardLayersResult raw = detail::boardLayersRaw(*_state);
    if (!raw.ok) return std::unexpected(std::move(raw.error));
    return raw.layers;
}

std::expected<BoardLayerGeometry, std::string> Board::boardLayerGeometry(const std::string& layerName) const {
    detail::RawBoardLayerGeometryResult raw =
        detail::boardLayerGeometryRaw(*_state, layerName);
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

std::expected<std::vector<PadPosition>, std::string> Board::allPads() const {
    detail::RawPadsOnNetResult raw = detail::allPadsRaw(*_state);
    if (!raw.ok) {
        return std::unexpected(std::move(raw.error));
    }
    return raw.pads;
}

std::expected<std::vector<std::pair<std::string, TrackSegment>>, std::string> Board::allTracks() const {
    detail::RawAllTracksResult raw = detail::allTracksRaw(*_state);
    if (!raw.ok) {
        return std::unexpected(std::move(raw.error));
    }
    return raw.tracks;
}

std::expected<std::vector<StackupLayer>, std::string> Board::stackup() const {
    detail::RawStackupResult raw = detail::stackupRaw(*_state);
    if (!raw.ok) {
        return std::unexpected(std::move(raw.error));
    }
    return raw.layers;
}

std::expected<std::vector<LayerColor>, std::string> Board::layerColors() const {
    detail::RawLayerColorsResult raw = detail::layerColorsRaw(*_state);
    if (!raw.ok) {
        return std::unexpected(std::move(raw.error));
    }
    return raw.colors;
}

std::expected<std::vector<NetColor>, std::string> Board::netColors() const {
    detail::RawNetColorsResult raw = detail::netColorsRaw(*_state);
    if (!raw.ok) {
        return std::unexpected(std::move(raw.error));
    }
    return raw.colors;
}

std::expected<std::vector<std::string>, std::string> Board::netClasses() const {
    detail::RawStringListResult raw = detail::netClassesRaw(*_state);
    if (!raw.ok) {
        return std::unexpected(std::move(raw.error));
    }
    return raw.values;
}

std::expected<std::vector<std::string>, std::string> Board::allNets() const {
    detail::RawStringListResult raw = detail::allNetsRaw(*_state);
    if (!raw.ok) {
        return std::unexpected(std::move(raw.error));
    }
    return raw.values;
}

std::expected<std::vector<FootprintInfo>, std::string> Board::footprints() const {
    detail::RawFootprintsResult raw = detail::footprintsRaw(*_state);
    if (!raw.ok) {
        return std::unexpected(std::move(raw.error));
    }
    return raw.footprints;
}

std::expected<std::vector<ThroughHole>, std::string> Board::throughHoles() const {
    detail::RawThroughHolesResult raw = detail::throughHolesRaw(*_state);
    if (!raw.ok) {
        return std::unexpected(std::move(raw.error));
    }
    return raw.holes;
}

std::expected<std::vector<NonPlatedHole>, std::string> Board::nonPlatedHoles() const {
    detail::RawNonPlatedHolesResult raw = detail::nonPlatedHolesRaw(*_state);
    if (!raw.ok) {
        return std::unexpected(std::move(raw.error));
    }
    return raw.holes;
}

std::expected<ComponentModelExportResult, std::string> Board::exportComponentModels(const std::string& componentFilter,
        const std::string& outputStlPath) const {
    detail::RawComponentModelExportResult raw =
        detail::exportComponentModelsRaw(*_state, componentFilter, outputStlPath);
    if (!raw.ok) {
        return std::unexpected(std::move(raw.error));
    }
    return raw.result;
}

} // namespace libkicad
