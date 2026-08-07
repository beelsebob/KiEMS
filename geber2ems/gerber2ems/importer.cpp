#include "importer.hpp"

#include <algorithm>
#include <array>
#include <cmath>
#include <cstdlib>
#include <fcntl.h>
#include <fstream>
#include <limits>
#include <map>
#include <regex>
#include <sstream>
#include <string_view>
#include <thread>
#include <unistd.h>
#include <sys/wait.h>
#include <spawn.h>

#include <nlohmann/json.hpp>

#include "config.hpp"
#include "constants.hpp"
#include "logging.hpp"
#include "png_utils.hpp"

extern char** environ;

namespace gerber2ems {

using namespace gerber2ems::constants;

namespace {

// ---- process spawning (replaces subprocess.run for invoking the external `gerbv` binary) ----

/// Runs `argv[0]` with the given arguments, discarding its stdout/stderr, and waits for it to
/// exit. Uses posix_spawn directly (no shell) so filenames never need escaping.
void _runProcess(const std::vector<std::string>& args) {
    std::vector<char*> argv;
    argv.reserve(args.size() + 1);
    for (const auto& arg : args) {
        argv.push_back(const_cast<char*>(arg.c_str()));
    }
    argv.push_back(nullptr);

    posix_spawn_file_actions_t actions;
    posix_spawn_file_actions_init(&actions);
    posix_spawn_file_actions_addopen(&actions, STDOUT_FILENO, "/dev/null", O_WRONLY, 0);
    posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, "/dev/null", O_WRONLY, 0);

    pid_t pid = 0;
    const int rc = posix_spawnp(&pid, argv[0], &actions, nullptr, argv.data(), environ);
    posix_spawn_file_actions_destroy(&actions);
    if (rc != 0) {
        logError("Failed to spawn process: " + args[0]);
        return;
    }
    int status = 0;
    waitpid(pid, &status, 0);
}

// ---- small filesystem helpers ----

bool _endsWith(const std::string& s, std::string_view suffix) {
    return s.size() >= suffix.size() && s.compare(s.size() - suffix.size(), suffix.size(), suffix) == 0;
}

std::vector<std::filesystem::path> _globSuffix(const std::filesystem::path& dir, std::string_view suffix) {
    std::vector<std::filesystem::path> result;
    std::error_code ec;
    if (!std::filesystem::is_directory(dir, ec)) {
        return result;
    }
    for (const auto& entry : std::filesystem::directory_iterator(dir, ec)) {
        if (_endsWith(entry.path().filename().string(), suffix)) {
            result.push_back(entry.path());
        }
    }
    return result;
}

std::string _afterLastDash(const std::string& s) {
    const std::size_t pos = s.rfind('-');
    return pos == std::string::npos ? s : s.substr(pos + 1);
}

std::vector<std::string> _splitDot(const std::string& s) {
    std::vector<std::string> parts;
    std::stringstream ss(s);
    std::string part;
    while (std::getline(ss, part, '.')) {
        parts.push_back(part);
    }
    return parts;
}

// ---- gerbv rendering ----

void _gbrToPng(const std::filesystem::path& edgeFilename, const std::filesystem::path& gerberFilename) {
    const std::filesystem::path outputFilename =
        std::filesystem::current_path() / geometryDir / _afterLastDash(gerberFilename.stem().string() + ".png");

    const double dpi = 1.0 / (static_cast<double>(Config::sharedConfig().pixelSize()) * baseUnit / 0.0254);
    logDebug("Generating PNG (DPI: " + std::to_string(static_cast<std::int64_t>(dpi)) + ") for " +
             gerberFilename.string());

    std::filesystem::path notCroppedName = outputFilename;
    notCroppedName.replace_filename(outputFilename.stem().string() + "_not_cropped" + outputFilename.extension().string());

    _runProcess({
        "gerbv",
        gerberFilename.string(),
        edgeFilename.string(),
        "--background=#000000",
        "--foreground=#ffffffff",
        "--foreground=#00007f",
        "-o",
        notCroppedName.string(),
        "--dpi",
        std::to_string(dpi),
        "--border=0",
        "--export=png",
        "-a",
    });

    const RgbaImage notCroppedImage = readPng(notCroppedName);

    std::int32_t edgeWidth = 0;
    const std::int32_t vProbe = notCroppedImage.height / 2;
    for (std::int32_t i = 0; i < notCroppedImage.width; ++i) {
        const std::uint8_t blue = notCroppedImage.blue(i, vProbe);
        if (blue > 0x3F && blue < 0xBF) {
            edgeWidth += 1;
            continue;
        }
        if (edgeWidth != 0) {
            break;
        }
    }
    const std::int32_t ew2 = edgeWidth / 2;
    const RgbaImage croppedImage =
        cropImage(notCroppedImage, ew2, ew2, notCroppedImage.width - ew2, notCroppedImage.height - ew2);
    writePng(outputFilename, croppedImage);

    if (!Config::sharedConfig().arguments().debug()) {
        std::error_code ec;
        std::filesystem::remove(notCroppedName, ec);
    }
}

// ---- copper mesh triangulation (replaces nanomesh + triangle) ----
//
// nanomesh/triangle are Python-only dependencies with no source to port; this is a from-scratch
// replacement rather than a translation. It traces the exact rectilinear boundary of the
// thresholded copper raster (correctly handling holes, e.g. via/pad clearances inside a copper
// pour), removes redundant collinear vertices (lossless), bridges each hole into its enclosing
// outer boundary (closest-vertex-pair heuristic -- not a full visibility algorithm, but reliable
// for the well-separated clearance shapes real board layouts produce), and ear-clips the result.

using GridVertex = std::pair<std::int32_t, std::int32_t>;

// 2x the signed area (shoelace), avoiding a division for the sign check. In this (x-right, y-down)
// coordinate system with boundary edges traced "foreground on the left", outer boundaries come out
// negative and holes positive.
double _signedArea2(const std::vector<GridVertex>& loop) {
    double sum = 0;
    for (std::size_t i = 0; i < loop.size(); ++i) {
        const auto& [x1, y1] = loop[i];
        const auto& [x2, y2] = loop[(i + 1) % loop.size()];
        sum += static_cast<double>(x1) * static_cast<double>(y2) - static_cast<double>(x2) * static_cast<double>(y1);
    }
    return sum;
}

/// Traces every boundary loop (outer and hole alike) of the foreground region of `mask`, as
/// closed sequences of grid-vertex coordinates (pixel corners, not centers).
std::vector<std::vector<GridVertex>> _traceBoundaryLoops(const std::vector<std::uint8_t>& mask, std::int32_t width,
                                                          std::int32_t height) {
    auto isForeground = [&](std::int32_t x, std::int32_t y) {
        if (x < 0 || y < 0 || x >= width || y >= height) {
            return false;
        }
        return mask[static_cast<std::size_t>(y) * static_cast<std::size_t>(width) + static_cast<std::size_t>(x)] != 0;
    };

    // Directed boundary edges, built so that foreground is always on the left of the direction of
    // travel (see the porting notes for the per-case derivation).
    std::map<GridVertex, std::vector<GridVertex>> outgoing;
    for (std::int32_t y = 0; y < height; ++y) {
        for (std::int32_t x = 0; x < width; ++x) {
            if (!isForeground(x, y)) {
                continue;
            }
            if (!isForeground(x - 1, y)) {
                outgoing[{x, y}].push_back({x, y + 1});
            }
            if (!isForeground(x + 1, y)) {
                outgoing[{x + 1, y + 1}].push_back({x + 1, y});
            }
            if (!isForeground(x, y - 1)) {
                outgoing[{x + 1, y}].push_back({x, y});
            }
            if (!isForeground(x, y + 1)) {
                outgoing[{x, y + 1}].push_back({x + 1, y + 1});
            }
        }
    }

    std::map<GridVertex, std::size_t> nextUnused; // index into outgoing[v] of the next unused edge
    std::vector<std::vector<GridVertex>> loops;
    for (auto& [start, edges] : outgoing) {
        for (std::size_t startEdgeIdx = 0; startEdgeIdx < edges.size(); ++startEdgeIdx) {
            if (nextUnused[start] > startEdgeIdx) {
                continue;
            }
            // Walk a loop starting with this edge, if not already consumed.
            std::vector<GridVertex> loop;
            GridVertex current = start;
            std::size_t edgeIdx = startEdgeIdx;
            const std::size_t maxSteps = (static_cast<std::size_t>(width) + 1) * (static_cast<std::size_t>(height) + 1) * 4 + 4;
            for (std::size_t step = 0; step < maxSteps; ++step) {
                auto& currentEdges = outgoing[current];
                if (edgeIdx >= currentEdges.size()) {
                    break;
                }
                loop.push_back(current);
                const GridVertex next = currentEdges[edgeIdx];
                nextUnused[current] = edgeIdx + 1;
                current = next;
                if (current == start) {
                    break;
                }
                // Pick the first not-yet-used outgoing edge at the new vertex.
                edgeIdx = nextUnused[current];
            }
            if (loop.size() >= 4) {
                loops.push_back(std::move(loop));
            }
        }
    }
    return loops;
}

/// Removes vertices that lie exactly on the segment between their neighbours (lossless -- the
/// represented polygon area is unchanged). Only removes *exact* collinearity, so it does nothing
/// for rasterized curves (every pixel-step point on a circle is *almost* but not exactly
/// collinear with its neighbours) -- see _douglasPeucker below for that case.
std::vector<GridVertex> _removeCollinear(const std::vector<GridVertex>& loop) {
    if (loop.size() < 3) {
        return loop;
    }
    std::vector<GridVertex> result;
    const std::size_t n = loop.size();
    for (std::size_t i = 0; i < n; ++i) {
        const auto& prev = loop[(i + n - 1) % n];
        const auto& cur = loop[i];
        const auto& next = loop[(i + 1) % n];
        const std::int64_t cross = static_cast<std::int64_t>(cur.first - prev.first) * (next.second - prev.second) -
                                    static_cast<std::int64_t>(cur.second - prev.second) * (next.first - prev.first);
        if (cross != 0) {
            result.push_back(cur);
        }
    }
    return result.size() >= 3 ? result : loop;
}

double _perpendicularDistance(GridVertex p, GridVertex lineStart, GridVertex lineEnd) {
    const double dx = static_cast<double>(lineEnd.first - lineStart.first);
    const double dy = static_cast<double>(lineEnd.second - lineStart.second);
    const double lengthSq = dx * dx + dy * dy;
    if (lengthSq == 0) {
        const double px = static_cast<double>(p.first - lineStart.first);
        const double py = static_cast<double>(p.second - lineStart.second);
        return std::sqrt(px * px + py * py);
    }
    const double cross = dx * static_cast<double>(p.second - lineStart.second) -
                          dy * static_cast<double>(p.first - lineStart.first);
    return std::abs(cross) / std::sqrt(lengthSq);
}

// Standard Ramer-Douglas-Peucker simplification of an open polyline; endpoints are always kept.
std::vector<GridVertex> _douglasPeuckerOpen(const std::vector<GridVertex>& points, double epsilon) {
    if (points.size() < 3) {
        return points;
    }
    double maxDist = 0;
    std::size_t splitIdx = 0;
    for (std::size_t i = 1; i + 1 < points.size(); ++i) {
        const double dist = _perpendicularDistance(points[i], points.front(), points.back());
        if (dist > maxDist) {
            maxDist = dist;
            splitIdx = i;
        }
    }
    if (maxDist <= epsilon) {
        return {points.front(), points.back()};
    }
    std::vector<GridVertex> left(points.begin(), points.begin() + static_cast<std::ptrdiff_t>(splitIdx) + 1);
    std::vector<GridVertex> right(points.begin() + static_cast<std::ptrdiff_t>(splitIdx), points.end());
    std::vector<GridVertex> leftResult = _douglasPeuckerOpen(left, epsilon);
    const std::vector<GridVertex> rightResult = _douglasPeuckerOpen(right, epsilon);
    leftResult.pop_back(); // avoid duplicating the shared split point
    leftResult.insert(leftResult.end(), rightResult.begin(), rightResult.end());
    return leftResult;
}

/// Simplifies a closed loop (lossy, within `epsilon` grid units) by splitting it into two open
/// chains at the point farthest from the first vertex, simplifying each independently, and
/// recombining. This is what actually controls triangle count for curved copper features (pads,
/// rounded traces): nanomesh's mesher applied comparable coarsening internally; this is this
/// port's from-scratch equivalent, tuned empirically against a real board so triangle counts land
/// in the same order of magnitude as the Python tool's output.
std::vector<GridVertex> _douglasPeucker(const std::vector<GridVertex>& loop, double epsilon) {
    if (loop.size() < 4) {
        return loop;
    }
    std::size_t farIdx = 0;
    double maxDist = -1;
    for (std::size_t i = 1; i < loop.size(); ++i) {
        const double dx = static_cast<double>(loop[i].first - loop[0].first);
        const double dy = static_cast<double>(loop[i].second - loop[0].second);
        const double dist = dx * dx + dy * dy;
        if (dist > maxDist) {
            maxDist = dist;
            farIdx = i;
        }
    }
    std::vector<GridVertex> chainA(loop.begin(), loop.begin() + static_cast<std::ptrdiff_t>(farIdx) + 1);
    std::vector<GridVertex> chainB(loop.begin() + static_cast<std::ptrdiff_t>(farIdx), loop.end());
    chainB.push_back(loop.front());

    std::vector<GridVertex> simplifiedA = _douglasPeuckerOpen(chainA, epsilon);
    std::vector<GridVertex> simplifiedB = _douglasPeuckerOpen(chainB, epsilon);
    simplifiedA.pop_back();
    simplifiedB.pop_back();
    simplifiedA.insert(simplifiedA.end(), simplifiedB.begin(), simplifiedB.end());
    return simplifiedA.size() >= 3 ? simplifiedA : loop;
}

bool _pointInPolygon(GridVertex p, const std::vector<GridVertex>& poly) {
    bool inside = false;
    for (std::size_t i = 0, j = poly.size() - 1; i < poly.size(); j = i++) {
        const auto [xi, yi] = poly[i];
        const auto [xj, yj] = poly[j];
        const bool intersects =
            ((yi > p.second) != (yj > p.second)) &&
            (static_cast<double>(p.first) <
             static_cast<double>(xj - xi) * (p.second - yi) / static_cast<double>(yj - yi) + xi);
        if (intersects) {
            inside = !inside;
        }
    }
    return inside;
}

double _distance2(GridVertex a, GridVertex b) {
    const double dx = static_cast<double>(a.first - b.first);
    const double dy = static_cast<double>(a.second - b.second);
    return dx * dx + dy * dy;
}

/// Bridges each hole into `outer` (closest-vertex-pair heuristic), producing a single polygon
/// boundary suitable for ear clipping.
std::vector<GridVertex> _bridgeHoles(std::vector<GridVertex> outer, const std::vector<std::vector<GridVertex>>& holes) {
    for (const auto& hole : holes) {
        if (hole.empty()) {
            continue;
        }
        std::size_t bestOuterIdx = 0;
        std::size_t bestHoleIdx = 0;
        double bestDist = std::numeric_limits<double>::infinity();
        for (std::size_t oi = 0; oi < outer.size(); ++oi) {
            for (std::size_t hi = 0; hi < hole.size(); ++hi) {
                const double d = _distance2(outer[oi], hole[hi]);
                if (d < bestDist) {
                    bestDist = d;
                    bestOuterIdx = oi;
                    bestHoleIdx = hi;
                }
            }
        }
        std::vector<GridVertex> merged;
        merged.reserve(outer.size() + hole.size() + 2);
        for (std::size_t i = 0; i <= bestOuterIdx; ++i) {
            merged.push_back(outer[i]);
        }
        for (std::size_t i = 0; i <= hole.size(); ++i) {
            merged.push_back(hole[(bestHoleIdx + i) % hole.size()]);
        }
        for (std::size_t i = bestOuterIdx; i < outer.size(); ++i) {
            merged.push_back(outer[i]);
        }
        outer = std::move(merged);
    }
    return outer;
}

/// Standard O(n^2)-per-ear polygon triangulation (fan-free ear clipping) of a simple polygon.
std::vector<std::array<GridVertex, 3>> _earClip(std::vector<GridVertex> poly) {
    std::vector<std::array<GridVertex, 3>> triangles;
    // Ensure counter-clockwise winding in a y-down system (positive shoelace here == CCW visually
    // flipped, but all that matters is consistency with the cross-product sign checks below).
    if (_signedArea2(poly) < 0) {
        std::reverse(poly.begin(), poly.end());
    }

    std::vector<std::size_t> indices(poly.size());
    for (std::size_t i = 0; i < poly.size(); ++i) {
        indices[i] = i;
    }

    std::size_t guard = 0;
    const std::size_t maxGuard = poly.size() * poly.size() + 16;
    while (indices.size() > 3 && guard < maxGuard) {
        ++guard;
        bool clipped = false;
        for (std::size_t i = 0; i < indices.size(); ++i) {
            const std::size_t iPrev = (i + indices.size() - 1) % indices.size();
            const std::size_t iNext = (i + 1) % indices.size();
            const GridVertex a = poly[indices[iPrev]];
            const GridVertex b = poly[indices[i]];
            const GridVertex c = poly[indices[iNext]];

            const std::int64_t cross =
                static_cast<std::int64_t>(b.first - a.first) * (c.second - a.second) -
                static_cast<std::int64_t>(b.second - a.second) * (c.first - a.first);
            if (cross <= 0) {
                continue; // reflex or degenerate vertex, cannot be an ear
            }

            bool anyInside = false;
            for (std::size_t k = 0; k < indices.size(); ++k) {
                if (k == iPrev || k == i || k == iNext) {
                    continue;
                }
                const GridVertex p = poly[indices[k]];
                if (p == a || p == b || p == c) {
                    continue; // coincident duplicate vertex (from a hole bridge), not real containment
                }
                // Point-in-triangle via barycentric sign test.
                const auto sign = [](GridVertex p1, GridVertex p2, GridVertex p3) {
                    return static_cast<std::int64_t>(p1.first - p3.first) * (p2.second - p3.second) -
                           static_cast<std::int64_t>(p2.first - p3.first) * (p1.second - p3.second);
                };
                const std::int64_t d1 = sign(p, a, b);
                const std::int64_t d2 = sign(p, b, c);
                const std::int64_t d3 = sign(p, c, a);
                const bool hasNeg = (d1 < 0) || (d2 < 0) || (d3 < 0);
                const bool hasPos = (d1 > 0) || (d2 > 0) || (d3 > 0);
                if (!(hasNeg && hasPos)) {
                    anyInside = true;
                    break;
                }
            }
            if (anyInside) {
                continue;
            }

            triangles.push_back({a, b, c});
            indices.erase(indices.begin() + static_cast<std::ptrdiff_t>(i));
            clipped = true;
            break;
        }
        if (!clipped) {
            break; // Numerically degenerate polygon; stop rather than loop forever.
        }
    }
    if (indices.size() == 3) {
        triangles.push_back({poly[indices[0]], poly[indices[1]], poly[indices[2]]});
    }
    return triangles;
}

} // namespace

void processGbrsToPngs() {
    logInfo("Processing gerber files (may take a while for larger boards)");

    const std::filesystem::path fab = std::filesystem::current_path() / "fab";
    const std::vector<std::filesystem::path> edgeMatches = _globSuffix(fab, "Edge_Cuts.gbr");
    if (edgeMatches.empty()) {
        logError("No edge_cuts gerber found");
        std::exit(1);
    }
    const std::filesystem::path edge = edgeMatches.front();

    const std::vector<std::filesystem::path> layers = _globSuffix(fab, "_Cu.gbr");
    if (layers.empty()) {
        logWarning("No copper gerbers found");
    }

    std::vector<std::thread> threads;
    threads.reserve(layers.size());
    for (const auto& layer : layers) {
        threads.emplace_back(_gbrToPng, edge, layer);
    }
    for (auto& t : threads) {
        t.join();
    }
}

std::pair<double, double> getDimensions(const std::string& inputFilename) {
    const std::int32_t pixelSize = Config::sharedConfig().pixelSize();
    const std::filesystem::path path = geometryDir / inputFilename;
    const auto [imageWidth, imageHeight] = readPngSize(path);
    const double height = static_cast<double>(imageHeight) * pixelSize * unitMultiplier;
    const double width = static_cast<double>(imageWidth) * pixelSize * unitMultiplier;
    logDebug("Board dimensions read from file are: height:" + std::to_string(height) +
             " width:" + std::to_string(width));
    return {width, height};
}

std::vector<Triangle> getTriangles(const std::string& inputFilename) {
    const std::filesystem::path imgPath = geometryDir / inputFilename;
    const RgbaImage image = readPng(imgPath);

    std::uint8_t maxGray = 0;
    for (std::int32_t y = 0; y < image.height; ++y) {
        for (std::int32_t x = 0; x < image.width; ++x) {
            maxGray = std::max(maxGray, image.gray(x, y));
        }
    }
    if (maxGray < 230) {
        return {}; // Image is empty -- no copper features on this layer.
    }

    std::vector<std::uint8_t> mask(static_cast<std::size_t>(image.width) * static_cast<std::size_t>(image.height));
    for (std::int32_t y = 0; y < image.height; ++y) {
        for (std::int32_t x = 0; x < image.width; ++x) {
            mask[static_cast<std::size_t>(y) * static_cast<std::size_t>(image.width) + static_cast<std::size_t>(x)] =
                image.gray(x, y) >= 230 ? 1 : 0;
        }
    }

    std::vector<std::vector<GridVertex>> loops = _traceBoundaryLoops(mask, image.width, image.height);

    std::vector<std::vector<GridVertex>> outers;
    std::vector<std::vector<GridVertex>> holes;
    for (auto& loop : loops) {
        if (_signedArea2(loop) < 0) {
            outers.push_back(std::move(loop));
        } else {
            holes.push_back(std::move(loop));
        }
    }

    // Assign each hole to its smallest enclosing outer loop.
    std::vector<std::vector<std::vector<GridVertex>>> holesByOuter(outers.size());
    for (const auto& hole : holes) {
        if (hole.empty()) {
            continue;
        }
        std::int64_t bestOuter = -1;
        double bestArea = std::numeric_limits<double>::infinity();
        for (std::size_t oi = 0; oi < outers.size(); ++oi) {
            if (_pointInPolygon(hole.front(), outers[oi])) {
                const double area = std::abs(_signedArea2(outers[oi]));
                if (area < bestArea) {
                    bestArea = area;
                    bestOuter = static_cast<std::int64_t>(oi);
                }
            }
        }
        if (bestOuter >= 0) {
            holesByOuter[static_cast<std::size_t>(bestOuter)].push_back(hole);
        }
    }

    std::vector<Triangle> result;
    const double scale = static_cast<double>(Config::sharedConfig().pixelSize()) * unitMultiplier;
    constexpr double kSimplifyEpsilonPixels = 2.0;
    for (std::size_t oi = 0; oi < outers.size(); ++oi) {
        std::vector<GridVertex> outer = _douglasPeucker(_removeCollinear(outers[oi]), kSimplifyEpsilonPixels);
        std::vector<std::vector<GridVertex>> simplifiedHoles;
        simplifiedHoles.reserve(holesByOuter[oi].size());
        for (const auto& hole : holesByOuter[oi]) {
            simplifiedHoles.push_back(_douglasPeucker(_removeCollinear(hole), kSimplifyEpsilonPixels));
        }
        const std::vector<GridVertex> merged = _bridgeHoles(std::move(outer), simplifiedHoles);
        const std::vector<std::array<GridVertex, 3>> triangles = _earClip(merged);
        for (const auto& tri : triangles) {
            // NOTE axis order deliberately swapped here (see Triangle's doc comment): the first
            // component carries the image row, the second the column, matching the Python
            // source's mesh point convention that simulation.cpp's add_contours depends on.
            Triangle t;
            t.a = Position(tri[0].second * scale, tri[0].first * scale);
            t.b = Position(tri[1].second * scale, tri[1].first * scale);
            t.c = Position(tri[2].second * scale, tri[2].first * scale);
            result.push_back(t);
        }
    }

    logDebug("Found " + std::to_string(result.size()) + " triangles for " + inputFilename);
    return result;
}

std::vector<ViaHole> getVias() {
    const std::filesystem::path fabDir = std::filesystem::current_path() / "fab";
    std::vector<std::filesystem::path> drillFiles = _globSuffix(fabDir, "-PTH.drl");
    if (drillFiles.empty()) {
        logError("Couldn't find drill file");
        std::exit(1);
    }

    std::map<std::int32_t, double> drills = {{0, 0.0}};
    std::int32_t currentDrill = 0;
    std::vector<ViaHole> vias;

    static const std::regex drillDefPattern(R"(T([0-9]+)C([0-9]+.[0-9]+))");
    static const std::regex drillSelectPattern(R"(T([0-9]+))");
    static const std::regex holePattern(R"(X([0-9]+.[0-9]+)Y([0-9]+.[0-9]+))");

    std::ifstream drillFile(drillFiles.front());
    std::string line;
    while (std::getline(drillFile, line)) {
        std::smatch match;
        if (std::regex_match(line, match, drillDefPattern)) {
            drills[std::stoi(match[1].str())] = std::stod(match[2].str()) / 1000 / baseUnit * unitMultiplier;
        }
        if (std::regex_match(line, match, drillSelectPattern)) {
            currentDrill = std::stoi(match[1].str());
        }
        if (std::regex_match(line, match, holePattern)) {
            const auto it = drills.find(currentDrill);
            if (it != drills.end()) {
                ViaHole via;
                via.x = std::stod(match[1].str()) / 1000 / baseUnit * unitMultiplier;
                via.y = std::stod(match[2].str()) / 1000 / baseUnit * unitMultiplier;
                via.diameter = it->second;
                vias.push_back(via);
            } else {
                logWarning("Drill file parsing failed. Drill with specifed number wasn't found");
            }
        }
    }
    logDebug("Found " + std::to_string(vias.size()) + " vias");
    return vias;
}

void importStackup() {
    const std::filesystem::path filename = "fab/stackup.json";
    std::ifstream file(filename);
    if (!file.is_open()) {
        logError("Couldn't open stackup file: " + filename.string());
        std::exit(1);
    }
    nlohmann::json stackup;
    try {
        file >> stackup;
    } catch (const nlohmann::json::parse_error& error) {
        logError(std::string("JSON decoding failed: ") + error.what());
        std::exit(1);
    }

    const std::string ver = stackup.value("format_version", std::string());
    const std::vector<std::string> verParts = _splitDot(ver);
    const std::vector<std::string> stackupParts = _splitDot(std::string(stackupFormatVersion));

    const bool ok = !ver.empty() && verParts.size() >= 2 && stackupParts.size() >= 2 && verParts[0] == stackupParts[0] &&
                    verParts[1] >= stackupParts[1]; // mirrors the Python source's string comparison
    if (ok) {
        Config::sharedConfig().loadStackup(stackup);
    } else {
        logError("Stackup format (" + ver + ") is not supported (supported: " + std::string(stackupFormatVersion) + ")");
        std::exit(1);
    }
}

void importPortPositions() {
    std::vector<std::tuple<std::int32_t, std::pair<double, double>, double>> ports;
    for (const auto& filename : _globSuffix(std::filesystem::current_path() / "fab", "pos.csv")) {
        auto found = getPortsFromFile(filename);
        ports.insert(ports.end(), found.begin(), found.end());
    }

    for (const auto& [number, position, direction] : ports) {
        // Guards against a negative index (e.g. a board using differently-numbered refdes than
        // expected): rather than replicate Python's `cfg.ports[-1]` wraparound-to-last-port
        // behavior, skip with a warning below via the "not defined on board" pass.
        if (number >= 0 && static_cast<std::int32_t>(Config::sharedConfig().ports().size()) > number) {
            PortConfig& port = Config::sharedConfig().ports()[static_cast<std::size_t>(number)];
            if (!port.position().has_value()) {
                port.setPosition(position);
                port.setDirection(direction);
            } else {
                logWarning("Port #" + std::to_string(number) + " is defined twice on the board. Ignoring the second instance");
            }
        }
    }
    for (std::size_t index = 0; index < Config::sharedConfig().ports().size(); ++index) {
        if (!Config::sharedConfig().ports()[index].position().has_value()) {
            logError("Port #" + std::to_string(index) + " is not defined on board. It will be skipped");
        }
    }
}

} // namespace gerber2ems
