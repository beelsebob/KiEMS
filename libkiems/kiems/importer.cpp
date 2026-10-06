#include "importer.hpp"

#include <cmath>
#include <numbers>

#include "config.hpp"
#include "constants.hpp"
#include "libkicad/libkicad.hpp"
#include "logging.hpp"

namespace kiems {

using namespace Cu;

using namespace kiems::constants;

namespace {

template <typename HoleT>
void _setHoleCapsule(HoleT& destination, double xMm, double yMm, double widthMm, double heightMm,
                     double orientationDeg, double originX, double originY) {
    const auto toSimUnits = [](double mm) { return mm / 1000 / baseUnit * unitMultiplier; };
    const double centerX = toSimUnits(xMm) - originX;
    const double centerY = toSimUnits(yMm) - originY;
    const double centerlineLength = toSimUnits(std::abs(widthMm - heightMm));
    // libkicad has already flipped KiCad's Y-down coordinates to this pipeline's Y-up frame, so
    // the pad rotation must flip too. A height-dominant slot runs along the pad's local Y axis.
    double angle = -orientationDeg * std::numbers::pi / 180.0;
    if (heightMm > widthMm) {
        angle += std::numbers::pi / 2.0;
    }
    const double dx = std::cos(angle) * centerlineLength / 2.0;
    const double dy = std::sin(angle) * centerlineLength / 2.0;
    destination.x1 = centerX - dx;
    destination.y1 = centerY - dy;
    destination.x2 = centerX + dx;
    destination.y2 = centerY + dy;
    destination.diameter = toSimUnits(std::min(widthMm, heightMm));
}

} // namespace

std::expected<void, std::string> exportKicadPcb(const PathsConfig& paths, const std::filesystem::path& kicadPcbPath) {
    logInfo("Importing KiCad board " + kicadPcbPath.string());
    std::filesystem::create_directories(paths.fabDir);

    // Every geometry query needs a board -- and, for net_class
    // involved-net entries, a linked project -- to query, potentially in a later, separate `-g`/
    // `-s`/`-p` invocation than this one. Keep persistent copies rather than requiring `-i` to be
    // repeated on every invocation.
    std::error_code copyEc;
    std::filesystem::copy_file(kicadPcbPath, paths.fabBoardFile, std::filesystem::copy_options::overwrite_existing,
                                copyEc);
    if (copyEc) {
        return std::unexpected("Failed to copy " + kicadPcbPath.string() + " to fab/: " + copyEc.message());
    }
    const std::filesystem::path projectPath = std::filesystem::path(kicadPcbPath).replace_extension(".kicad_pro");
    if (std::filesystem::is_regular_file(projectPath)) {
        std::filesystem::copy_file(projectPath, paths.fabProjectFile, std::filesystem::copy_options::overwrite_existing,
                                    copyEc);
        if (copyEc) {
            return std::unexpected("Failed to copy " + projectPath.string() + " to fab/: " + copyEc.message());
        }
    } else {
        logWarning("No sibling .kicad_pro found for " + kicadPcbPath.string() +
                   "; involved_nets entries using \"net_class\" will fail to resolve");
    }
    return {};
}

std::expected<std::vector<ViaHole>, std::string> getVias(const libkicad::Board& board, double originX, double originY) {
    auto source = board.throughHoles();
    if (!source) return std::unexpected(std::move(source).error());
    std::vector<ViaHole> vias;
    vias.reserve(source->size());
    for (const libkicad::ThroughHole& hole : *source) {
        NPTHHole capsule;
        _setHoleCapsule(capsule, hole.xMm, hole.yMm, hole.drillWidthMm, hole.drillHeightMm,
                        hole.orientationDeg, originX, originY);
        ViaHole via;
        via.x = capsule.x1;
        via.y = capsule.y1;
        via.x2 = capsule.x2;
        via.y2 = capsule.y2;
        via.diameter = capsule.diameter;
        vias.push_back(via);
    }
    logDebug("Found " + std::to_string(vias.size()) + " vias");
    return vias;
}

std::expected<std::vector<NPTHHole>, std::string> getNPTHHoles(const libkicad::Board& board, double originX,
                                                                  double originY) {
    auto source = board.nonPlatedHoles();
    if (!source) return std::unexpected(std::move(source).error());
    std::vector<NPTHHole> holes;
    holes.reserve(source->size());
    for (const libkicad::NonPlatedHole& sourceHole : *source) {
        NPTHHole hole;
        _setHoleCapsule(hole, sourceHole.xMm, sourceHole.yMm, sourceHole.drillWidthMm,
                        sourceHole.drillHeightMm, sourceHole.orientationDeg, originX, originY);
        holes.push_back(hole);
    }
    logDebug("Found " + std::to_string(holes.size()) + " NPTH holes");
    return holes;
}

std::expected<void, std::string> importStackup(const libkicad::Board& board, EMSConfig& config) {
    // Queries the live board's own Board Setup > Board Stackup data via libkicad rather than a hand-maintained
    // stackup.json: the board file is the actual source of truth, and keeping a second,
    // easily-stale copy of the same data in sync by hand was never anything but a workaround for
    // not having this query available yet. Requires fab/board.kicad_pcb (persisted by
    // exportKicadPcb()), exactly like port_resolution.cpp's own ki calls.
    auto stackupResult = board.stackup();
    if (!stackupResult) {
        return std::unexpected(stackupResult.error());
    }

    std::vector<LayerConfig> layers;
    layers.reserve(stackupResult->size());
    for (const auto& layer : *stackupResult) {
        if (layer.kind == libkicad::StackupLayerKind::Copper) {
            layers.emplace_back(LayerKind::Metal, layer.name, layer.thicknessMm);
        } else if (layer.kind == libkicad::StackupLayerKind::SolderMaskTop) {
            layers.emplace_back(LayerKind::SolderMaskTop, layer.name, layer.thicknessMm, layer.epsilonR,
                                 layer.lossTangent);
        } else if (layer.kind == libkicad::StackupLayerKind::SolderMaskBottom) {
            layers.emplace_back(LayerKind::SolderMaskBottom, layer.name, layer.thicknessMm, layer.epsilonR,
                                 layer.lossTangent);
        } else {
            layers.emplace_back(LayerKind::Substrate, layer.name, layer.thicknessMm, layer.epsilonR,
                                 layer.lossTangent);
        }
    }
    config.loadStackup(std::move(layers));
    return {};
}

} // namespace kiems
