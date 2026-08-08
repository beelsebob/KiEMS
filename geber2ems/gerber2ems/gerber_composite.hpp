// Vector-based (Clipper2) copper-layer geometry reconstruction. Replaces the old raster
// (gerbv-render + boundary-trace) pipeline.
#pragma once

#include <filesystem>
#include <vector>

#include "importer.hpp"

namespace gerber2ems {

/// Builds the true copper region for one layer by compositing every paint operation (stroke, pad
/// flash, zone fill) captured on `gerberPath`'s GerberFile::copperOps(), strictly in original file
/// order: Clipper2 Union for dark polarity, Difference for clear -- reproducing Gerber's actual
/// painter's-algorithm compositing semantics -- then triangulating the result (reusing the same
/// hole-bridging/ear-clipping approach the old raster pipeline used on traced pixel contours).
///
/// Coordinates are re-origined so the board's Edge_Cuts bounding-box minimum corner maps to (0,0),
/// matching getDimensions() and the rest of the codebase's [0, pcbWidth] x [0, pcbHeight]
/// convention (mirroring what the old raster pipeline did implicitly via its "crop to content"
/// step).
std::vector<Triangle> compositeLayerTriangles(const std::filesystem::path& gerberPath);

} // namespace gerber2ems
