#include "CopperCoefficientTable.hpp"

#include <algorithm>
#include <array>
#include <cmath>
#include <cstring>
#include <stdexcept>
#include <unordered_map>

#if defined(__APPLE__)
#include <dispatch/dispatch.h>
#endif

namespace copper {

namespace {

using Key = std::array<std::uint32_t, 6>; // bit patterns of decay[0..2], material[0..2]

struct KeyHash {
    std::size_t operator()(const Key& key) const {
        std::uint64_t h = 1469598103934665603ull; // FNV-1a over the six words
        for (const std::uint32_t word : key) h = (h ^ word) * 1099511628211ull;
        return static_cast<std::size_t>(h);
    }
};

std::uint32_t bitsOf(float value) {
    std::uint32_t bits;
    std::memcpy(&bits, &value, sizeof bits);
    return bits;
}

float floatOf(std::uint32_t bits) {
    float value;
    std::memcpy(&value, &bits, sizeof value);
    return value;
}

template <typename Body>
void parallelFor(std::size_t count, const Body& body) {
#if defined(__APPLE__)
    dispatch_apply_f(count, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), const_cast<Body*>(&body),
                     [](void* context, std::size_t i) { (*static_cast<const Body*>(context))(i); });
#else
    for (std::size_t i = 0; i < count; ++i) body(i);
#endif
}

} // namespace

CopperCoefficientTable buildCoefficientTable(const CopperYeeGrid& grid, CopperCoefficientSide side,
                                             const std::vector<CopperDomainMask::DispatchBox>& boxes,
                                             const CopperRingAbsorber& ring) {
    const bool electric = side == CopperCoefficientSide::E;
    const auto& own = electric ? grid.primaryDelta : grid.dualDelta;
    const auto& across = electric ? grid.dualDelta : grid.primaryDelta;
    const std::vector<float>* decay = electric ? grid.vv : grid.ii;
    const std::vector<float>* curl = electric ? grid.vi : grid.iv;
    const CopperGridDims& dims = grid.dims;
    const std::uint32_t lines[3] = {dims.nx, dims.ny, dims.nz};

    CopperCoefficientTable table;
    // Double-precision per-axis terms for dividing the geometry out, and their float images for the
    // kernels (and for measuring what the kernels will rebuild).
    std::array<std::vector<double>, 3> ownD, inverseAcrossD;
    std::array<std::vector<float>, 3> ownF, inverseAcrossF;
    for (std::size_t a = 0; a < 3; ++a) {
        if (own[a].size() != lines[a] || across[a].size() != lines[a]) {
            throw std::runtime_error("CopperEngine: the Yee grid has no mesh spacings to build a coefficient table from");
        }
        ownD[a] = own[a];
        inverseAcrossD[a].resize(lines[a]);
        ownF[a].resize(lines[a]);
        inverseAcrossF[a].resize(lines[a]);
        for (std::size_t i = 0; i < lines[a]; ++i) {
            if (!(own[a][i] > 0.0) || !(across[a][i] > 0.0)) {
                throw std::runtime_error("CopperEngine: the Yee grid has a non-positive mesh spacing");
            }
            inverseAcrossD[a][i] = 1.0 / across[a][i];
            ownF[a][i] = static_cast<float>(own[a][i]);
            inverseAcrossF[a][i] = static_cast<float>(inverseAcrossD[a][i]);
        }
    }
    for (const auto& axis : ownF) table.geometry.insert(table.geometry.end(), axis.begin(), axis.end());
    for (const auto& axis : inverseAcrossF) table.geometry.insert(table.geometry.end(), axis.begin(), axis.end());

    // Three passes so the work spreads over every core yet the result doesn't depend on scheduling:
    // each z-plane dedupes its own cells into plane-local entries; a serial merge, in plane order,
    // numbers the distinct entries globally; then each plane's cells are renumbered.
    table.index.assign(dims.cellCount(), 0);
    struct Plane {
        std::vector<Key> keys; // plane-local entries, in first-seen order
        std::vector<std::uint32_t> globalIndex;
        double worstRebuildError = 0.0;
    };
    std::vector<Plane> planes(dims.nz);
    parallelFor(dims.nz, [&](std::size_t zIndex) {
        const auto z = static_cast<std::uint32_t>(zIndex);
        Plane& plane = planes[z];
        std::unordered_map<Key, std::uint32_t, KeyHash> lookup;
        // Neighbouring cells along a row nearly always share an entry, so most cells never reach the
        // hash map.
        Key previous{};
        std::uint32_t previousIndex = 0;
        bool havePrevious = false;
        for (const auto& box : boxes) {
            for (std::uint32_t y = box.startY; y < box.startY + box.height; ++y) {
                for (std::uint32_t x = box.startX; x < box.startX + box.width; ++x) {
                    const std::size_t i = copperGridIndex(dims, x, y, z);
                    const std::uint32_t pos[3] = {x, y, z};
                    Key key;
                    for (std::size_t n = 0; n < 3; ++n) {
                        const std::size_t nP = (n + 1) % 3, nPP = (n + 2) % 3;
                        float a = decay[n][i], b = curl[n][i];
                        if (electric) {
                            ring.foldE(static_cast<int>(n), x, y, a, b);
                        } else {
                            ring.foldH(static_cast<int>(n), x, y, a, b);
                        }
                        const double geometry =
                            ownD[n][pos[n]] * inverseAcrossD[nP][pos[nP]] * inverseAcrossD[nPP][pos[nPP]];
                        const float material = static_cast<float>(static_cast<double>(b) / geometry);
                        key[n] = bitsOf(a);
                        key[3 + n] = bitsOf(material);
                        if (b != 0.0F) {
                            const float rebuilt =
                                material * ownF[n][pos[n]] * inverseAcrossF[nP][pos[nP]] * inverseAcrossF[nPP][pos[nPP]];
                            plane.worstRebuildError =
                                std::max(plane.worstRebuildError,
                                         std::abs(static_cast<double>(rebuilt) - b) / std::abs(static_cast<double>(b)));
                        }
                    }
                    if (!havePrevious || key != previous) {
                        const auto [it, inserted] =
                            lookup.try_emplace(key, static_cast<std::uint32_t>(plane.keys.size()));
                        if (inserted) plane.keys.push_back(key);
                        previous = key;
                        previousIndex = it->second;
                        havePrevious = true;
                    }
                    table.index[i] = previousIndex;
                }
            }
        }
    });

    std::unordered_map<Key, std::uint32_t, KeyHash> lookup;
    for (Plane& plane : planes) {
        table.worstRebuildError = std::max(table.worstRebuildError, plane.worstRebuildError);
        plane.globalIndex.reserve(plane.keys.size());
        for (const Key& key : plane.keys) {
            const auto [it, inserted] = lookup.try_emplace(key, static_cast<std::uint32_t>(table.entries.size()));
            if (inserted) {
                CopperCoefficientTable::Entry entry;
                for (std::size_t n = 0; n < 3; ++n) {
                    entry.decay[n] = floatOf(key[n]);
                    entry.material[n] = floatOf(key[3 + n]);
                }
                table.entries.push_back(entry);
            }
            plane.globalIndex.push_back(it->second);
        }
    }

    parallelFor(dims.nz, [&](std::size_t zIndex) {
        const auto z = static_cast<std::uint32_t>(zIndex);
        const std::vector<std::uint32_t>& globalIndex = planes[z].globalIndex;
        for (const auto& box : boxes) {
            for (std::uint32_t y = box.startY; y < box.startY + box.height; ++y) {
                std::uint32_t* row = table.index.data() + copperGridIndex(dims, box.startX, y, z);
                for (std::uint32_t x = 0; x < box.width; ++x) row[x] = globalIndex[row[x]];
            }
        }
    });
    if (table.entries.empty()) table.entries.push_back({}); // index 0 must always be valid
    return table;
}

} // namespace copper
