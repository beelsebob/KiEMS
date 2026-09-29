#include "via_stitching.hpp"

#include <algorithm>
#include <cmath>
#include <limits>

#include "constants.hpp"
#include "logging.hpp"

namespace kiems {

using namespace Cu;

namespace {

/// Shortest distance from `pt` to the polyline formed by `path`'s edges (treated as a closed loop).
double _distancePointToPolyline(const Position& pt, const Polygon& path) {
    double best = std::numeric_limits<double>::infinity();
    for (std::size_t i = 0; i < path.size(); ++i) {
        const Position& a = path[i];
        const Position& b = path[(i + 1) % path.size()];
        const double abx = b.x() - a.x();
        const double aby = b.y() - a.y();
        const double lenSq = abx * abx + aby * aby;
        double t = 0;
        if (lenSq > 0) {
            t = ((pt.x() - a.x()) * abx + (pt.y() - a.y()) * aby) / lenSq;
            t = std::clamp(t, 0.0, 1.0);
        }
        const double px = a.x() + t * abx;
        const double py = a.y() + t * aby;
        const double dx = pt.x() - px;
        const double dy = pt.y() - py;
        best = std::min(best, std::hypot(dx, dy));
    }
    return best;
}

double _distancePointToPolylines(const Position& pt, const PolygonSet& paths) {
    double best = std::numeric_limits<double>::infinity();
    for (const Polygon& path : paths) {
        best = std::min(best, _distancePointToPolyline(pt, path));
    }
    return best;
}

/// Point-membership test against a non-zero-fill composited region, including nested holes/islands.
} // namespace

StitchingViaPlacement placeStitchingVias(const SlicingConfig& slicing, const PolygonSet& cutout,
                                          const PolygonSet& boardOutline,
                                          const std::vector<PolygonSet>& groundPerLayer,
                                          const std::vector<PolygonSet>& nonGroundCopperObstaclesPerLayer,
                                          const std::vector<ViaHole>& existingVias) {
    // Real vias near this simulation, seeding the clearance/spacing checks below -- a stitching via
    // must never collide with one, and (if the real via is itself on the ground net) must respect
    // the same slicing.viaSpacing from it as from another stitching via.
    struct ExistingVia {
        double x = 0;
        double y = 0;
        double outerRadius = 0; // For the clearance check (edge-to-edge, not center-to-center).
        bool isGround = false;  // For the slicing.viaSpacing check, which only applies among ground-net vias.
    };
    std::vector<ExistingVia> seenVias;
    seenVias.reserve(existingVias.size());
    for (const ViaHole& via : existingVias) {
        // Midpoint of the via's own capsule centerline -- exactly (via.x, via.y) for a plain
        // round via (x2==x, y2==y), the center of the pad for an elongated one.
        const double midX = (via.x + via.x2) / 2;
        const double midY = (via.y + via.y2) / 2;
        const Position pos(midX, midY);
        const bool isGround = std::any_of(groundPerLayer.begin(), groundPerLayer.end(),
                                         [&](const PolygonSet& ground) { return containsPoint(ground, pos); });
        // Circumscribing radius from the midpoint -- half the centerline length plus the pad's
        // own half-width -- so an elongated pad's clearance footprint is never underestimated,
        // even though this treats it as round for the purpose of this check (a conservative
        // over-approximation, not an exact capsule-to-capsule distance).
        const double halfLength = std::hypot(via.x2 - via.x, via.y2 - via.y) / 2;
        const double outerRadius = halfLength + via.diameter / 2 + slicing.platingThickness;
        seenVias.push_back({midX, midY, outerRadius, isGround});
    }

    // True if placing a stitchingViaAnnularRingDiameter()-sized via centered at (x, y) would either
    // physically collide with an existing via (real or already placed in this same pass -- any net,
    // checked edge-to-edge against slicing.viaClearance) or sit closer than slicing.viaSpacing
    // to an existing *ground-net* via specifically (real or already placed -- a stitching via is
    // always ground, so this also naturally keeps freshly-placed stitching vias that spacing apart
    // from each other, alongside real ground vias).
    const double candidateRadius = slicing.stitchingViaAnnularRingDiameter / 2;
    auto intersectsNonGroundCopper = [&](const Position& position) {
        return std::any_of(nonGroundCopperObstaclesPerLayer.begin(),
                           nonGroundCopperObstaclesPerLayer.end(),
                           [&](const PolygonSet& obstacles) {
                               // The via occupies its full annular-ring disc, not just its centre.
                               // Point membership catches a disc centred inside a wide trace or
                               // pad; boundary distance catches every partial overlap and tangency.
                               return containsPoint(obstacles, position) ||
                                      _distancePointToPolylines(position, obstacles) <= candidateRadius;
                           });
    };
    auto tooCloseToExistingVia = [&](double x, double y) {
        for (const ExistingVia& existing : seenVias) {
            const double dist = std::hypot(x - existing.x, y - existing.y);
            if (dist < candidateRadius + existing.outerRadius + slicing.viaClearance) {
                return true;
            }
            if (existing.isGround && dist < slicing.viaSpacing) {
                return true;
            }
        }
        return false;
    };

    // Walk every outer boundary loop of the cutout, classify each edge against the real board
    // outline (on/near it -> pre-existing, no stitching needed there), and place vias along
    // new-cut edges only -- spaced slicing.viaSpacing apart along the *whole contiguous run* of
    // new-cut edges, not restarted at every individual polygon edge. The cutout boundary comes out
    // of polygon boolean ops (in particular round buffer joins) tessellated into many short
    // segments, most of them far shorter than any real via spacing -- stepping per-edge like the
    // rest of this pipeline's per-segment code would place a minimum of one via at *every* edge
    // regardless of its length, since floor(shortSegLen / slicing.viaSpacing) always floors to 0 and gets
    // clamped back up to the "at least 1" minimum. That's what actually produced the reported bug:
    // clusters of near-duplicate vias at every tessellated vertex, spaced by tessellation
    // granularity rather than slicing.viaSpacing.
    StitchingViaPlacement result;
    // TEMPORARY diagnostic counters -- see the "electrically floating" warning below, which can't
    // currently tell "no ground copper reachable here at all" apart from "a real board via already
    // sits right there, so a redundant stitching via was correctly skipped" -- those mean very
    // different things for whether the edge is actually disconnected.
    std::size_t diagNoGroundCopperCount = 0;
    std::size_t diagNonGroundCopperCount = 0;
    std::size_t diagTooCloseCount = 0;
    constexpr double kOnEdgeToleranceSimUnits = 100.0; // 10 microns, at 10 sim-units/micron
    for (const Polygon& loop : cutout) {
        const double loopArea = signedArea(loop);
        if (std::abs(loopArea) < 1.0) {
            continue; // degenerate
        }
        const bool isHole = loopArea < 0;
        if (isHole) {
            continue; // Never stitch a hole's own boundary (e.g. a real board cutout) -- it's a
                      // genuine board edge already, per the same logic as the outer loop check.
        }

        const std::size_t n = loop.size();
        std::vector<bool> isNewCut(n, false);
        std::vector<double> segLens(n, 0.0);
        for (std::size_t i = 0; i < n; ++i) {
            const Position& a = loop[i];
            const Position& b = loop[(i + 1) % n];
            segLens[i] = std::hypot(b.x() - a.x(), b.y() - a.y());
            if (segLens[i] < 1.0) {
                continue; // degenerate edge: leave isNewCut false, it'll just be skipped
            }
            const Position midpoint((a.x() + b.x()) / 2, (a.y() + b.y()) / 2);
            isNewCut[i] = _distancePointToPolylines(midpoint, boardOutline) > kOnEdgeToleranceSimUnits;
        }

        // Run-start indices: an edge starts a new run if it's a new cut and its predecessor isn't
        // -- except when literally every edge is a new cut (the whole loop is deep inside the real
        // board, touching it nowhere), which is one single run that can start anywhere; index 0 is
        // picked arbitrarily for that case.
        const bool allNewCut = std::all_of(isNewCut.begin(), isNewCut.end(), [](bool v) { return v; });
        std::vector<std::size_t> runStarts;
        if (allNewCut && n > 0) {
            runStarts.push_back(0);
        } else {
            for (std::size_t i = 0; i < n; ++i) {
                const std::size_t prev = (i + n - 1) % n;
                if (isNewCut[i] && !isNewCut[prev]) {
                    runStarts.push_back(i);
                }
            }
        }

        for (std::size_t runStart : runStarts) {
            std::vector<std::size_t> runEdges;
            std::size_t idx = runStart;
            for (std::size_t count = 0; count < n; ++count) {
                if (!isNewCut[idx]) {
                    break;
                }
                runEdges.push_back(idx);
                idx = (idx + 1) % n;
                if (idx == runStart) {
                    break; // Wrapped fully around -- only possible in the allNewCut case.
                }
            }
            if (runEdges.empty()) {
                continue;
            }

            // Flatten the run into cumulative-arc-length vertices, so a via's position can be found
            // by distance along the *whole run* regardless of which underlying edge that distance
            // falls in.
            struct RunVertex {
                double cumDist = 0;
                Position point;
            };
            std::vector<RunVertex> vertices;
            vertices.reserve(runEdges.size() + 1);
            vertices.push_back({0.0, loop[runStart]});
            double cum = 0.0;
            for (std::size_t e : runEdges) {
                cum += segLens[e];
                vertices.push_back({cum, loop[(e + 1) % n]});
            }
            const double totalLength = cum;

            // Via center (post slicing.viaEdgeDistance inward offset) at a given arc-length distance along
            // this run -- the same interpolation the old fixed-step loop did inline, factored out so
            // the adaptive walk below can probe arbitrary distances while searching for the next
            // candidate.
            auto viaCenterAtArcLength = [&](double dist) -> std::pair<double, double> {
                std::size_t k = 0;
                while (k + 2 < vertices.size() && vertices[k + 1].cumDist < dist) {
                    ++k;
                }
                const RunVertex& v0 = vertices[k];
                const RunVertex& v1 = vertices[k + 1];
                const double vertexSegLen = v1.cumDist - v0.cumDist;
                const double t = vertexSegLen > 1e-6 ? (dist - v0.cumDist) / vertexSegLen : 0.0;
                const double edgeX = v0.point.x() + t * (v1.point.x() - v0.point.x());
                const double edgeY = v0.point.y() + t * (v1.point.y() - v0.point.y());
                // Inward normal (cutout's outer loops are wound so the interior is to the left of
                // each directed edge, per the default orientation for positive-area outer
                // paths).
                const double dx = vertexSegLen > 1e-6 ? (v1.point.x() - v0.point.x()) / vertexSegLen : 1.0;
                const double dy = vertexSegLen > 1e-6 ? (v1.point.y() - v0.point.y()) / vertexSegLen : 0.0;
                return {edgeX - dy * slicing.viaEdgeDistance, edgeY + dx * slicing.viaEdgeDistance};
            };

            // Walk the run placing candidates spaced slicing.viaSpacing apart by *straight-line*
            // (crow-flies) distance between successive via centers, not by equal arc length -- on
            // any edge that isn't dead straight, the arc length between two points always exceeds
            // their straight-line distance, so stepping by a fixed arc length alone systematically
            // overshoots on curvature: consecutive candidates land closer together (as the crow
            // flies) than slicing.viaSpacing, and every other one then gets rejected by tooCloseToExistingVia
            // below -- "every second via never appears" on any edge that isn't perfectly straight.
            // Finds each next arc-length position with a simple secant-style correction: walk a
            // guessed distance, measure the shortfall between the resulting straight-line distance
            // and the target, and correct the walk by that shortfall (scaled by kViaWalkOvershoot so
            // it converges in a handful of iterations for a gently-curved edge rather than creeping
            // up on the target asymptotically); tooCloseToExistingVia below is still the actual
            // safety net if a tight curve keeps this from converging exactly.
            constexpr double kViaWalkOvershoot = 1.2;
            constexpr int kViaWalkMaxIterations = 20;
            const double viaWalkMinStep = std::max(slicing.viaSpacing * 0.01, kOnEdgeToleranceSimUnits);

            std::vector<double> candidateDists{0.0};
            {
                double curDist = 0.0;
                auto [curX, curY] = viaCenterAtArcLength(0.0);
                while (curDist < totalLength) {
                    // Search for the next arc-length position whose straight-line distance from
                    // (curX, curY) reaches slicing.viaSpacing -- NOT decided by comparing against the
                    // run's own endpoint up front: on a run that curves back near where it started
                    // (an arc hugging a rounded board corner, or the whole-loop case where the run's
                    // end literally coincides with its start), that chord can be far shorter than
                    // slicing.viaSpacing even though there's plenty of arc length still ahead to place vias
                    // along -- checking it early terminated the whole run after only one or two
                    // candidates instead of walking it properly.
                    double walk = std::min(totalLength - curDist, slicing.viaSpacing * kViaWalkOvershoot);
                    double dist = curDist;
                    double crow = 0.0;
                    bool converged = false;
                    for (int iter = 0; iter < kViaWalkMaxIterations; ++iter) {
                        dist = std::min(curDist + walk, totalLength);
                        const auto [x, y] = viaCenterAtArcLength(dist);
                        crow = std::hypot(x - curX, y - curY);
                        // A one-sided threshold, not "closest to the target": stop at the *first*
                        // walk whose straight-line distance reaches slicing.viaSpacing, never one that
                        // falls even slightly short of it. tooCloseToExistingVia() below rejects
                        // anything strictly closer than slicing.viaSpacing to the previous via -- and
                        // since this walk always continues from the last *computed* candidate
                        // regardless of whether it end up accepted (see the accept/reject loop
                        // below), a symmetric "closest approach" tolerance would let convergence land
                        // just under the target roughly half the time, get rejected, and then have
                        // the next candidate walk on from that same too-close point -- reproducing
                        // exactly the "every second via never appears" bug this whole loop exists to
                        // fix. Overshooting slightly is harmless; undershooting is not.
                        if (crow >= slicing.viaSpacing) {
                            converged = true;
                            break;
                        }
                        if (dist >= totalLength) {
                            break; // Can't walk any further even though we haven't converged.
                        }
                        const double error = slicing.viaSpacing - crow;
                        walk = std::max(walk + error * kViaWalkOvershoot, viaWalkMinStep);
                    }
                    if (!converged && dist >= totalLength) {
                        // Ran out of run before reaching a full slicing.viaSpacing crow-flies distance --
                        // take the run's own end as one last candidate if it's a meaningfully
                        // different point, then stop.
                        if (crow > viaWalkMinStep) {
                            candidateDists.push_back(totalLength);
                        }
                        break;
                    }
                    candidateDists.push_back(dist);
                    curDist = dist;
                    std::tie(curX, curY) = viaCenterAtArcLength(curDist);
                }
            }

            const std::size_t stitchingViasBeforeRun = result.vias.size();
            for (const double dist : candidateDists) {
                const auto [viaXRaw, viaYRaw] = viaCenterAtArcLength(dist);
                const Position viaPos(viaXRaw, viaYRaw);
                const double viaX = viaPos.x();
                const double viaY = viaPos.y();
                const bool onAnyGroundLayer = std::any_of(groundPerLayer.begin(), groundPerLayer.end(),
                                                          [&](const PolygonSet& ground) {
                                                              return containsPoint(ground, viaPos);
                                                          });
                if (!onAnyGroundLayer) {
                    result.failedAttempts.emplace_back(viaX, viaY);
                    ++diagNoGroundCopperCount;
                    continue; // No ground copper here to stitch to -- skip rather than place a
                              // floating via.
                }
                if (intersectsNonGroundCopper(viaPos)) {
                    result.failedAttempts.emplace_back(viaX, viaY);
                    ++diagNonGroundCopperCount;
                    continue;
                }
                if (tooCloseToExistingVia(viaX, viaY)) {
                    result.failedAttempts.emplace_back(viaX, viaY);
                    ++diagTooCloseCount;
                    continue;
                }
                result.vias.push_back(
                    StitchingVia{viaX, viaY, slicing.stitchingViaHoleDiameter, slicing.stitchingViaAnnularRingDiameter});
                seenVias.push_back({viaX, viaY, candidateRadius, true});
            }
            // Every candidate along this run got rejected (no ground copper there, intersection
            // with non-ground trace/pad copper, or too close to another via) -- this cut edge is
            // left with no return-path connection at all, i.e. a
            // floating plane segment. Physically, a plane segment that's
            // only reconnected by sparse stitching vias (or not reconnected at all) behaves like a
            // slot/comb resonator: it can trap energy near-field rather than letting it radiate or
            // dissipate, which shows up as the FDTD's total domain energy plateauing instead of
            // decaying toward the end criteria. Warned rather than failed outright, since a
            // genuinely tiny cut edge with nowhere valid to stitch may be harmless -- but a long run
            // with zero vias is worth a user's attention.
            if (result.vias.size() == stitchingViasBeforeRun) {
                logWarning("A " + std::to_string(totalLength / constants::unitMultiplier) +
                           " um cut edge of the ground/power plane got no stitching vias at all (every "
                           "candidate position was rejected) -- this leaves that plane segment "
                           "electrically floating, which can trap energy and prevent FDTD convergence. "
                           "Consider a smaller via, tighter via_spacing, or more per-net hull padding so the cut "
                           "falls somewhere with room to stitch.");
            }
        }
    }

    logInfo(std::to_string(result.vias.size()) + " stitching via(s), " +
             std::to_string(result.failedAttempts.size()) + " failed attempt(s) [DIAG: " +
             std::to_string(diagNoGroundCopperCount) + " no-ground-copper, " +
             std::to_string(diagNonGroundCopperCount) + " non-ground-copper, " +
             std::to_string(diagTooCloseCount) + " too-close-to-existing-via]");
    return result;
}

} // namespace kiems
