// Vector-based (Clipper2) copper-layer geometry reconstruction. Replaces the old raster
// (gerbv-render + boundary-trace) pipeline.
#pragma once

#include <expected>
#include <filesystem>
#include <functional>
#include <limits>
#include <string>
#include <vector>

#include <clipper2/clipper.h>

#include "gerber_io.hpp"
#include "importer.hpp"

namespace kiems {

/// Bounding box of the board's Edge_Cuts outline, in native (unshifted) simulation-unit
/// coordinates. Every consumer of board extent (getDimensions(), grid_gen.cpp's own independent
/// parse, board_slicing.cpp) derives it the same way -- from Edge_Cuts vector geometry directly,
/// not a rendered raster -- so this is intentionally re-derived at each use site rather than
/// threading a shared cache through unrelated modules for a parse that costs microseconds.
struct BoundingBox {
    double xMin = std::numeric_limits<double>::infinity();
    double xMax = -std::numeric_limits<double>::infinity();
    double yMin = std::numeric_limits<double>::infinity();
    double yMax = -std::numeric_limits<double>::infinity();
};

std::expected<BoundingBox, std::string> edgeCutsBoundingBox(const std::filesystem::path& fabDir,
                                                              double tessellationTolerance);

/// Composites `ops` (a caller-chosen subset of a GerberFile's copperOps() -- e.g. every op, or only
/// those on nets of interest, per CopperOp::net) into a single accumulated Clipper2 polygon set,
/// strictly in original file order: Union for a maximal-run of dark-polarity ops, Difference for
/// clear -- reproducing Gerber's actual painter's-algorithm compositing semantics (see CopperOp's
/// own doc comment for why grouping into maximal same-polarity runs is lossless, not just a
/// performance shortcut). `gerber` supplies the aperture definitions pad flashes in `ops` reference.
/// Coordinates are re-origined by (originX, originY) -- pass edgeCutsBoundingBox()'s xMin/yMin for
/// the same [0, pcbWidth] x [0, pcbHeight] convention the rest of the codebase uses.
Clipper2Lib::Paths64 compositeOps(const GerberFile& gerber, const std::vector<CopperOp>& ops, double originX,
                                    double originY, double tessellationTolerance);

/// Triangulates an already-composited polygon set (e.g. compositeOps()'s result, or a further
/// clipped/intersected derivative of it -- see board_slicing.cpp), handling arbitrarily-nested
/// holes/islands via PolyTree level (reusing the same hole-bridging/ear-clipping approach the old
/// raster pipeline used on traced pixel contours).
std::vector<Triangle> triangulate(const Clipper2Lib::Paths64& composited, double tessellationTolerance,
                                    const std::string& contextForErrors);

/// Builds the true copper region for one layer by compositing every paint operation on
/// `gerberPath`'s GerberFile::copperOps() (see compositeOps()) then triangulating the result
/// (see triangulate()).
///
/// Coordinates are re-origined so the board's Edge_Cuts bounding-box minimum corner maps to (0,0),
/// matching getDimensions() and the rest of the codebase's [0, pcbWidth] x [0, pcbHeight]
/// convention (mirroring what the old raster pipeline did implicitly via its "crop to content"
/// step).
std::expected<std::vector<Triangle>, std::string> compositeLayerTriangles(const std::filesystem::path& fabDir,
                                                                            const std::filesystem::path& gerberPath,
                                                                            double tessellationTolerance);

} // namespace kiems
