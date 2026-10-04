#include "FieldFrameSeriesWriter.hpp"

#include <algorithm>
#include <array>
#include <bit>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <limits>
#include <numeric>
#include <hdf5.h>
#include <os/signpost.h>

#include "Internal/CopperFieldFrameSignposts.hpp"
#include "Internal/CopperHDF5Blosc2.hpp"

namespace copper {

namespace {

// RAII wrapper for an hid_t, so no early-return error path can leak an open file/dataspace/
// dataset/property-list handle -- HDF5's own C API has no such safety net. `Closer` is a plain
// function pointer (H5Fclose/H5Dclose/... all share the `herr_t(hid_t)` signature), not a
// std::function, so this stays trivially cheap to move around.
class HId {
public:
    using Closer = herr_t (*)(hid_t);

    HId() = default;
    HId(hid_t id, Closer closer) : _id(id), _closer(closer) {}
    HId(const HId&) = delete;
    HId& operator=(const HId&) = delete;
    HId(HId&& other) noexcept : _id(other._id), _closer(other._closer) { other._id = -1; }
    HId& operator=(HId&& other) noexcept {
        if (this != &other) {
            reset();
            _id = other._id;
            _closer = other._closer;
            other._id = -1;
        }
        return *this;
    }
    ~HId() { reset(); }

    hid_t get() const { return _id; }
    bool valid() const { return _id >= 0; }
    void reset() {
        if (_id >= 0 && _closer != nullptr) {
            _closer(_id);
        }
        _id = -1;
    }

private:
    hid_t _id = -1;
    Closer _closer = nullptr;
};

// Disables HDF5's own default stderr-printing error handler for this whole process -- every
// failure path below already builds its own std::string error message; HDF5's own auto-printed
// stack trace would just be noise duplicating that.
struct DisableHDF5ErrorPrinting {
    DisableHDF5ErrorPrinting() { H5Eset_auto2(H5E_DEFAULT, nullptr, nullptr); }
};
const DisableHDF5ErrorPrinting kDisableHDF5ErrorPrinting;

std::expected<hid_t, std::string> createExtendibleDataset(hid_t file, const char* name, int rank,
                                                             const hsize_t* dims, const hsize_t* maxdims,
                                                             const hsize_t* chunkDims, hid_t nativeType,
                                                             bool useBlosc2,
                                                             std::vector<HId>& owned) {
    HId space(H5Screate_simple(rank, dims, maxdims), H5Sclose);
    if (!space.valid()) {
        return std::unexpected(std::string("H5Screate_simple failed for ") + name);
    }
    HId dcpl(H5Pcreate(H5P_DATASET_CREATE), H5Pclose);
    if (!dcpl.valid() || H5Pset_chunk(dcpl.get(), rank, chunkDims) < 0) {
        return std::unexpected(std::string("H5Pset_chunk failed for ") + name);
    }
    if (useBlosc2) {
        if (auto filtered = setHDF5Blosc2Filter(dcpl.get()); !filtered) {
            return std::unexpected(filtered.error() + " for " + name);
        }
    }
    // Large grids are spatially tiled, so never let HDF5 quietly scale a per-dataset cache to the
    // whole grid. Six such caches were a significant part of the simulation's resident memory.
    std::size_t chunkBytes = H5Tget_size(nativeType);
    for (int i = 0; i < rank; ++i) {
        chunkBytes *= chunkDims[i];
    }
    HId dapl(H5Pcreate(H5P_DATASET_ACCESS), H5Pclose);
    constexpr std::size_t kMaximumChunkCacheBytes = 32ULL * 1024 * 1024;
    const std::size_t cacheBytes = std::min(chunkBytes * 2, kMaximumChunkCacheBytes);
    if (!dapl.valid() || H5Pset_chunk_cache(dapl.get(), 1009, cacheBytes, 0.75) < 0) {
        return std::unexpected(std::string("H5Pset_chunk_cache failed for ") + name);
    }
    hid_t dataset =
        H5Dcreate2(file, name, nativeType, space.get(), H5P_DEFAULT, dcpl.get(), dapl.get());
    if (dataset < 0) {
        return std::unexpected(std::string("H5Dcreate2 failed for ") + name);
    }
    owned.emplace_back(dataset, H5Dclose);
    return dataset;
}

std::expected<void, std::string> writeStringAttribute(hid_t loc, const char* name, const std::string& value) {
    HId type(H5Tcopy(H5T_C_S1), H5Tclose);
    if (!type.valid() || H5Tset_size(type.get(), value.empty() ? 1 : value.size()) < 0) {
        return std::unexpected(std::string("H5Tset_size failed for attribute ") + name);
    }
    HId space(H5Screate(H5S_SCALAR), H5Sclose);
    HId attr(H5Acreate2(loc, name, type.get(), space.get(), H5P_DEFAULT, H5P_DEFAULT), H5Aclose);
    if (!attr.valid() || H5Awrite(attr.get(), type.get(), value.c_str()) < 0) {
        return std::unexpected(std::string("H5Awrite failed for attribute ") + name);
    }
    return {};
}

template <typename T>
std::expected<void, std::string> writeScalarAttribute(hid_t loc, const char* name, hid_t nativeType, T value) {
    HId space(H5Screate(H5S_SCALAR), H5Sclose);
    HId attr(H5Acreate2(loc, name, nativeType, space.get(), H5P_DEFAULT, H5P_DEFAULT), H5Aclose);
    if (!attr.valid() || H5Awrite(attr.get(), nativeType, &value) < 0) {
        return std::unexpected(std::string("H5Awrite failed for attribute ") + name);
    }
    return {};
}

std::expected<void, std::string> writeDoubleArrayDataset(hid_t file, const char* name,
                                                            const std::vector<double>& values) {
    const hsize_t dims[1] = {values.empty() ? 1 : values.size()};
    HId space(H5Screate_simple(1, dims, nullptr), H5Sclose);
    HId dataset(H5Dcreate2(file, name, H5T_NATIVE_DOUBLE, space.get(), H5P_DEFAULT, H5P_DEFAULT, H5P_DEFAULT),
                H5Dclose);
    if (!dataset.valid()) {
        return std::unexpected(std::string("H5Dcreate2 failed for ") + name);
    }
    if (!values.empty() && H5Dwrite(dataset.get(), H5T_NATIVE_DOUBLE, H5S_ALL, H5S_ALL, H5P_DEFAULT, values.data()) < 0) {
        return std::unexpected(std::string("H5Dwrite failed for ") + name);
    }
    return {};
}

std::expected<void, std::string> writeUInt8ArrayDataset(hid_t file, const char* name,
                                                         const std::vector<std::uint8_t>& values) {
    const hsize_t dims[1] = {values.size()};
    HId space(H5Screate_simple(1, dims, nullptr), H5Sclose);
    HId dataset(H5Dcreate2(file, name, H5T_NATIVE_UINT8, space.get(), H5P_DEFAULT, H5P_DEFAULT, H5P_DEFAULT),
                H5Dclose);
    if (!space.valid() || !dataset.valid() ||
        H5Dwrite(dataset.get(), H5T_NATIVE_UINT8, H5S_ALL, H5S_ALL, H5P_DEFAULT, values.data()) < 0) {
        return std::unexpected(std::string("Could not write ") + name);
    }
    return {};
}

} // namespace

/// Every open HDF5 handle this writer holds for the file's lifetime, plus running frame count.
/// `bigDatasets`/`smallDatasets` are indexed in a fixed order (see the constructor) matching
/// writeFrame()'s own parameter order, so appendFrame() can loop over them generically.
struct FieldFrameSeriesWriter::Impl {
    HId file;
    std::array<hid_t, 6> component{}; // Ex,Ey,Ez,Hx,Hy,Hz -- owned via `owned`, not closed directly
    hid_t previewEnergy = -1;
    std::array<hid_t, 6> previewComponent{};
    hid_t refinementOrder = -1;
    hid_t timestepDataset = -1;
    hid_t timeSecondsDataset = -1;
    hid_t minEnergyDataset = -1;
    hid_t maxEnergyDataset = -1;
    std::array<hid_t, 6> componentMinDataset{};
    std::array<hid_t, 6> componentMaxDataset{};
    hid_t publishedFrameCountDataset = -1;
    std::vector<HId> owned; // keeps every dataset/property-list handle alive for the file's lifetime
    std::uint32_t nx = 0, ny = 0, nz = 0;
    std::uint32_t previewNx = 0, previewNy = 0, previewNz = 0;
    std::uint32_t previewFactorX = 16, previewFactorY = 16, previewFactorZ = 2;
    std::uint32_t frameCount = 0;
    std::uint32_t publishedFrameCount = 0;
    std::uint32_t chunkFrames = 16;
    os_signpost_id_t encodingBlockSignpost = OS_SIGNPOST_ID_INVALID;
    bool closed = false;

    std::expected<void, std::string> publishFrames() {
        if (publishedFrameCount == frameCount) {
            return {};
        }
        // SWMR has no transaction spanning all extendible datasets in this file. Flush all
        // field and metadata data first, then publish the new count through its own scalar dataset
        // and flush that dataset second. A reader which observes the new count is therefore
        // guaranteed that every byte belonging to those frames was already made visible first.
        if (H5Fflush(file.get(), H5F_SCOPE_GLOBAL) < 0) {
            return std::unexpected("H5Fflush failed while publishing field frames");
        }
        const std::uint32_t count = frameCount;
        if (H5Dwrite(publishedFrameCountDataset, H5T_NATIVE_UINT32, H5S_ALL, H5S_ALL, H5P_DEFAULT,
                     &count) < 0 ||
            H5Dflush(publishedFrameCountDataset) < 0) {
            return std::unexpected("Could not publish the field-frame count");
        }
        publishedFrameCount = count;
        return {};
    }
};

FieldFrameSeriesWriter::FieldFrameSeriesWriter(std::unique_ptr<Impl> impl) : _impl(std::move(impl)) {}
FieldFrameSeriesWriter::FieldFrameSeriesWriter(FieldFrameSeriesWriter&&) noexcept = default;
FieldFrameSeriesWriter& FieldFrameSeriesWriter::operator=(FieldFrameSeriesWriter&&) noexcept = default;
FieldFrameSeriesWriter::~FieldFrameSeriesWriter() {
    if (_impl) {
        (void)close();
    }
}

std::expected<FieldFrameSeriesWriter, std::string> FieldFrameSeriesWriter::create(const std::filesystem::path& path,
                                                                                     const Header& header,
                                                                                     std::uint32_t chunkFrames) {
    if (header.nx == 0 || header.ny == 0 || header.nz == 0) {
        return std::unexpected("FieldFrameSeriesWriter::create: nx/ny/nz must all be non-zero");
    }
    if (header.lineX.size() != header.nx || header.lineY.size() != header.ny || header.lineZ.size() != header.nz) {
        return std::unexpected("FieldFrameSeriesWriter::create: lineX/Y/Z must have exactly nx/ny/nz entries");
    }
    const std::size_t xyCount = static_cast<std::size_t>(header.nx) * header.ny;
    if (!header.domainXYClass.empty() && header.domainXYClass.size() != xyCount) {
        return std::unexpected("FieldFrameSeriesWriter::create: domainXYClass must be empty or contain nx*ny entries");
    }
    if (chunkFrames == 0) {
        chunkFrames = 1;
    }
    // `chunkFrames` is now only the atomic SWMR publication cadence. Field samples themselves are
    // one-frame spatial tiles, so a compression call never scales with the whole mesh.
    const std::uint64_t frameBytes =
        static_cast<std::uint64_t>(header.nx) * header.ny * header.nz * sizeof(float);
    if (frameBytes == 0) {
        return std::unexpected("FieldFrameSeriesWriter::create: computed frame size is zero");
    }
    // Plain stdout fprintf, matching CopperFDTDRunner.cpp's own progress-reporting convention --
    // Copper.framework doesn't link libkiems, so kiems's own Cu::logInfo isn't reachable
    // here. One line per series (only at create() time, not per-frame), giving the grid size and
    // per-frame/per-chunk byte counts that actually determine whether the size clamp above engages --
    // the real board sizes that trigger it are much larger than the unit tests' tiny synthetic grids,
    // so this is the only way to see the true numbers from a real run's own console output.
    std::fprintf(stdout,
                 "Copper: field frame-series %s: grid=%ux%ux%u, frame=%llu bytes/component, "
                 "publishFrames=%u, detailTile=16x16x2\n",
                 path.string().c_str(), header.nx, header.ny, header.nz,
                 static_cast<unsigned long long>(frameBytes), chunkFrames);
    if (auto registered = registerHDF5Blosc2Filter(); !registered) {
        return std::unexpected(registered.error());
    }

    auto impl = std::make_unique<Impl>();
    impl->nx = header.nx;
    impl->ny = header.ny;
    impl->nz = header.nz;
    impl->previewNx = (header.nx + impl->previewFactorX - 1) / impl->previewFactorX;
    impl->previewNy = (header.ny + impl->previewFactorY - 1) / impl->previewFactorY;
    impl->previewNz = (header.nz + impl->previewFactorZ - 1) / impl->previewFactorZ;
    const std::uint64_t previewCellCount64 =
        static_cast<std::uint64_t>(impl->previewNx) * impl->previewNy * impl->previewNz;
    if (previewCellCount64 > std::numeric_limits<std::uint32_t>::max()) {
        return std::unexpected("Field preview has too many cells for uint32 refinement indices");
    }
    impl->chunkFrames = chunkFrames;

    HId fileAccess(H5Pcreate(H5P_FILE_ACCESS), H5Pclose);
    if (!fileAccess.valid() ||
        H5Pset_libver_bounds(fileAccess.get(), H5F_LIBVER_LATEST, H5F_LIBVER_LATEST) < 0) {
        return std::unexpected("Could not configure the HDF5 file for SWMR");
    }
    impl->file = HId(H5Fcreate(path.string().c_str(), H5F_ACC_TRUNC, H5P_DEFAULT, fileAccess.get()), H5Fclose);
    if (!impl->file.valid()) {
        return std::unexpected("Could not create " + path.string());
    }
    const hid_t file = impl->file.get();

    // Root attributes.
    if (auto r = writeScalarAttribute<std::int32_t>(file, "format_version", H5T_NATIVE_INT32, 4); !r) return std::unexpected(r.error());
    if (auto r = writeStringAttribute(file, "simulation_name", header.simulationName); !r) return std::unexpected(r.error());
    if (auto r = writeScalarAttribute<std::int32_t>(file, "excited_port", H5T_NATIVE_INT32, header.excitedPort); !r) return std::unexpected(r.error());
    if (auto r = writeScalarAttribute<std::int32_t>(file, "nx", H5T_NATIVE_INT32, static_cast<std::int32_t>(header.nx)); !r) return std::unexpected(r.error());
    if (auto r = writeScalarAttribute<std::int32_t>(file, "ny", H5T_NATIVE_INT32, static_cast<std::int32_t>(header.ny)); !r) return std::unexpected(r.error());
    if (auto r = writeScalarAttribute<std::int32_t>(file, "nz", H5T_NATIVE_INT32, static_cast<std::int32_t>(header.nz)); !r) return std::unexpected(r.error());
    if (auto r = writeScalarAttribute<std::int32_t>(file, "preview_factor_x", H5T_NATIVE_INT32, static_cast<std::int32_t>(impl->previewFactorX)); !r) return std::unexpected(r.error());
    if (auto r = writeScalarAttribute<std::int32_t>(file, "preview_factor_y", H5T_NATIVE_INT32, static_cast<std::int32_t>(impl->previewFactorY)); !r) return std::unexpected(r.error());
    if (auto r = writeScalarAttribute<std::int32_t>(file, "preview_factor_z", H5T_NATIVE_INT32, static_cast<std::int32_t>(impl->previewFactorZ)); !r) return std::unexpected(r.error());
    if (auto r = writeScalarAttribute<std::int32_t>(file, "preview_nx", H5T_NATIVE_INT32, static_cast<std::int32_t>(impl->previewNx)); !r) return std::unexpected(r.error());
    if (auto r = writeScalarAttribute<std::int32_t>(file, "preview_ny", H5T_NATIVE_INT32, static_cast<std::int32_t>(impl->previewNy)); !r) return std::unexpected(r.error());
    if (auto r = writeScalarAttribute<std::int32_t>(file, "preview_nz", H5T_NATIVE_INT32, static_cast<std::int32_t>(impl->previewNz)); !r) return std::unexpected(r.error());
    if (auto r = writeScalarAttribute<double>(file, "timestep_seconds", H5T_NATIVE_DOUBLE, header.timestepSeconds); !r) return std::unexpected(r.error());
    if (auto r = writeScalarAttribute<double>(file, "board_z_min", H5T_NATIVE_DOUBLE, header.boardZMin); !r) return std::unexpected(r.error());
    if (auto r = writeScalarAttribute<double>(file, "board_z_max", H5T_NATIVE_DOUBLE, header.boardZMax); !r) return std::unexpected(r.error());

    // /grid group + its three static datasets.
    {
        HId grid(H5Gcreate2(file, "/grid", H5P_DEFAULT, H5P_DEFAULT, H5P_DEFAULT), H5Gclose);
        if (!grid.valid()) {
            return std::unexpected("H5Gcreate2 failed for /grid");
        }
        if (auto r = writeDoubleArrayDataset(file, "/grid/line_x", header.lineX); !r) return std::unexpected(r.error());
        if (auto r = writeDoubleArrayDataset(file, "/grid/line_y", header.lineY); !r) return std::unexpected(r.error());
        if (auto r = writeDoubleArrayDataset(file, "/grid/line_z", header.lineZ); !r) return std::unexpected(r.error());
        const std::vector<std::uint8_t> rectangularDomain = header.domainXYClass.empty()
            ? std::vector<std::uint8_t>(xyCount, 1) : header.domainXYClass;
        if (auto r = writeUInt8ArrayDataset(file, "/grid/domain_xy_class", rectangularDomain); !r)
            return std::unexpected(r.error());
    }

    // The viewer normally reads only this small pyramid base. Energy is max pooled so a thin,
    // high-energy feature cannot disappear; signed components are block averaged so differential
    // combinations remain meaningful instead of max-pooling positive and negative fields.
    {
        HId preview(H5Gcreate2(file, "/preview", H5P_DEFAULT, H5P_DEFAULT, H5P_DEFAULT), H5Gclose);
        if (!preview.valid()) return std::unexpected("H5Gcreate2 failed for /preview");
        const hsize_t dims[4] = {0, impl->previewNz, impl->previewNy, impl->previewNx};
        const hsize_t maxdims[4] = {H5S_UNLIMITED, impl->previewNz, impl->previewNy, impl->previewNx};
        const hsize_t chunks[4] = {1, impl->previewNz, impl->previewNy, impl->previewNx};
        auto energy = createExtendibleDataset(file, "/preview/energy_max", 4, dims, maxdims, chunks,
                                              H5T_NATIVE_FLOAT, true, impl->owned);
        if (!energy) return std::unexpected(energy.error());
        impl->previewEnergy = *energy;
        static const char* const names[6] = {"/preview/Ex_mean", "/preview/Ey_mean", "/preview/Ez_mean",
                                             "/preview/Hx_mean", "/preview/Hy_mean", "/preview/Hz_mean"};
        for (std::size_t i = 0; i < 6; ++i) {
            auto dataset = createExtendibleDataset(file, names[i], 4, dims, maxdims, chunks,
                                                   H5T_NATIVE_FLOAT, true, impl->owned);
            if (!dataset) return std::unexpected(dataset.error());
            impl->previewComponent[i] = *dataset;
        }
        // One permutation per frame, containing x-fastest linear preview-cell indices ordered by
        // descending normalized high-resolution variation. Its chunks match one complete ordering,
        // so a decoder can fetch the small preview plus this list, then spend a bounded amount of
        // time reading the most informative independently-compressed detail cells first.
        const hsize_t orderDims[2] = {0, static_cast<hsize_t>(previewCellCount64)};
        const hsize_t orderMaxDims[2] = {H5S_UNLIMITED, orderDims[1]};
        const hsize_t orderChunks[2] = {1, orderDims[1]};
        auto order = createExtendibleDataset(file, "/preview/refinement_order", 2, orderDims,
                                             orderMaxDims, orderChunks, H5T_NATIVE_UINT32, true,
                                             impl->owned);
        if (!order) return std::unexpected(order.error());
        impl->refinementOrder = *order;
    }

    // /frames group + the six big extendible component datasets, chunked+compressed.
    {
        HId frames(H5Gcreate2(file, "/frames", H5P_DEFAULT, H5P_DEFAULT, H5P_DEFAULT), H5Gclose);
        if (!frames.valid()) {
            return std::unexpected("H5Gcreate2 failed for /frames");
        }
        static const char* const kComponentNames[6] = {"/frames/Ex_xor", "/frames/Ey_xor", "/frames/Ez_xor",
                                                       "/frames/Hx_xor", "/frames/Hy_xor", "/frames/Hz_xor"};
        const hsize_t dims4[4] = {0, header.nz, header.ny, header.nx};
        const hsize_t maxdims4[4] = {H5S_UNLIMITED, header.nz, header.ny, header.nx};
        const hsize_t chunk4[4] = {1, std::min<hsize_t>(header.nz, impl->previewFactorZ),
                                  std::min<hsize_t>(header.ny, impl->previewFactorY),
                                  std::min<hsize_t>(header.nx, impl->previewFactorX)};
        for (int i = 0; i < 6; ++i) {
            auto ds = createExtendibleDataset(file, kComponentNames[i], 4, dims4, maxdims4, chunk4,
                                              H5T_NATIVE_UINT32, true, impl->owned);
            if (!ds) return std::unexpected(ds.error());
            impl->component[static_cast<std::size_t>(i)] = *ds;
        }

        // Small per-frame metadata: extendible (a dataset with an unlimited dimension must be
        // chunked, even though these are never compressed), 1D, one entry per frame, each its own
        // element type.
        const hsize_t dims1[1] = {0};
        const hsize_t maxdims1[1] = {H5S_UNLIMITED};
        const hsize_t chunk1[1] = {chunkFrames};
        auto createTyped1D = [&](const char* name, hid_t nativeType) -> std::expected<hid_t, std::string> {
            HId space(H5Screate_simple(1, dims1, maxdims1), H5Sclose);
            if (!space.valid()) return std::unexpected(std::string("H5Screate_simple failed for ") + name);
            HId dcpl(H5Pcreate(H5P_DATASET_CREATE), H5Pclose);
            if (!dcpl.valid() || H5Pset_chunk(dcpl.get(), 1, chunk1) < 0) {
                return std::unexpected(std::string("H5Pset_chunk failed for ") + name);
            }
            hid_t dataset = H5Dcreate2(file, name, nativeType, space.get(), H5P_DEFAULT, dcpl.get(), H5P_DEFAULT);
            if (dataset < 0) return std::unexpected(std::string("H5Dcreate2 failed for ") + name);
            impl->owned.emplace_back(dataset, H5Dclose);
            return dataset;
        };
        auto timestepDs = createTyped1D("/frames/timestep", H5T_NATIVE_UINT32);
        if (!timestepDs) return std::unexpected(timestepDs.error());
        impl->timestepDataset = *timestepDs;
        auto timeSecondsDs = createTyped1D("/frames/time_seconds", H5T_NATIVE_DOUBLE);
        if (!timeSecondsDs) return std::unexpected(timeSecondsDs.error());
        impl->timeSecondsDataset = *timeSecondsDs;
        auto minEnergyDs = createTyped1D("/frames/min_energy", H5T_NATIVE_FLOAT);
        if (!minEnergyDs) return std::unexpected(minEnergyDs.error());
        impl->minEnergyDataset = *minEnergyDs;
        auto maxEnergyDs = createTyped1D("/frames/max_energy", H5T_NATIVE_FLOAT);
        if (!maxEnergyDs) return std::unexpected(maxEnergyDs.error());
        impl->maxEnergyDataset = *maxEnergyDs;
        static const char* const kComponentMinNames[6] = {
            "/frames/Ex_min", "/frames/Ey_min", "/frames/Ez_min",
            "/frames/Hx_min", "/frames/Hy_min", "/frames/Hz_min"};
        static const char* const kComponentMaxNames[6] = {
            "/frames/Ex_max", "/frames/Ey_max", "/frames/Ez_max",
            "/frames/Hx_max", "/frames/Hy_max", "/frames/Hz_max"};
        for (std::size_t i = 0; i < impl->component.size(); ++i) {
            auto minDataset = createTyped1D(kComponentMinNames[i], H5T_NATIVE_FLOAT);
            if (!minDataset) return std::unexpected(minDataset.error());
            impl->componentMinDataset[i] = *minDataset;
            auto maxDataset = createTyped1D(kComponentMaxNames[i], H5T_NATIVE_FLOAT);
            if (!maxDataset) return std::unexpected(maxDataset.error());
            impl->componentMaxDataset[i] = *maxDataset;
        }

        // The writer advances this only after every dataset making up a completed block has been
        // flushed. Readers treat it as the sole authoritative extent; see publishFrames().
        HId publishedSpace(H5Screate(H5S_SCALAR), H5Sclose);
        if (!publishedSpace.valid()) {
            return std::unexpected("H5Screate failed for /frames/published_frame_count");
        }
        const hid_t publishedDataset =
            H5Dcreate2(file, "/frames/published_frame_count", H5T_NATIVE_UINT32, publishedSpace.get(),
                       H5P_DEFAULT, H5P_DEFAULT, H5P_DEFAULT);
        if (publishedDataset < 0) {
            return std::unexpected("H5Dcreate2 failed for /frames/published_frame_count");
        }
        impl->owned.emplace_back(publishedDataset, H5Dclose);
        impl->publishedFrameCountDataset = publishedDataset;
        const std::uint32_t zero = 0;
        if (H5Dwrite(publishedDataset, H5T_NATIVE_UINT32, H5S_ALL, H5S_ALL, H5P_DEFAULT, &zero) < 0) {
            return std::unexpected("H5Dwrite failed for /frames/published_frame_count");
        }
    }

    // Every object/attribute the file will ever contain now exists. SWMR permits extending and
    // writing those datasets while another process/handle reads them, but forbids creating new
    // objects after this point.
    if (H5Fflush(file, H5F_SCOPE_GLOBAL) < 0 || H5Fstart_swmr_write(file) < 0) {
        return std::unexpected("Could not start HDF5 SWMR writing");
    }

    return FieldFrameSeriesWriter(std::move(impl));
}

std::expected<void, std::string> FieldFrameSeriesWriter::writeFrame(std::uint32_t timestep, double timeSeconds,
                                                                        const std::vector<float>& ex,
                                                                        const std::vector<float>& ey,
                                                                        const std::vector<float>& ez,
                                                                        const std::vector<float>& hx,
                                                                        const std::vector<float>& hy,
                                                                        const std::vector<float>& hz) {
    if (!_impl || _impl->closed) {
        return std::unexpected("FieldFrameSeriesWriter::writeFrame called after close()");
    }
    Impl& impl = *_impl;
    const std::size_t cellCount = static_cast<std::size_t>(impl.nx) * impl.ny * impl.nz;
    const std::array<const std::vector<float>*, 6> components = {&ex, &ey, &ez, &hx, &hy, &hz};
    for (const auto* component : components) {
        if (component->size() != cellCount) {
            return std::unexpected("FieldFrameSeriesWriter::writeFrame: component size doesn't match nx*ny*nz");
        }
    }

    const std::uint32_t frameIndex = impl.frameCount;
    if (frameIndex % impl.chunkFrames == 0) {
        impl.encodingBlockSignpost = os_signpost_id_generate(fieldFrameSignpostLog());
        os_signpost_interval_begin(fieldFrameSignpostLog(), impl.encodingBlockSignpost,
                                   "Encode field-frame block", "block=%u first_frame=%u capacity=%u",
                                   frameIndex / impl.chunkFrames, frameIndex, impl.chunkFrames);
    }
    auto appendScalar = [&](hid_t dataset, hid_t nativeType, const void* value) -> std::expected<void, std::string> {
        const hsize_t newExtent1[1] = {frameIndex + 1};
        const hsize_t start1[1] = {frameIndex};
        const hsize_t count1[1] = {1};
        if (H5Dset_extent(dataset, newExtent1) < 0) {
            return std::unexpected("H5Dset_extent failed for per-frame metadata");
        }
        HId filespace(H5Dget_space(dataset), H5Sclose);
        HId memspace(H5Screate_simple(1, count1, nullptr), H5Sclose);
        if (!filespace.valid() || !memspace.valid() ||
            H5Sselect_hyperslab(filespace.get(), H5S_SELECT_SET, start1, nullptr, count1, nullptr) < 0) {
            return std::unexpected("H5Sselect_hyperslab failed for per-frame metadata");
        }
        if (H5Dwrite(dataset, nativeType, memspace.get(), filespace.get(), H5P_DEFAULT, value) < 0) {
            return std::unexpected("H5Dwrite failed for per-frame metadata");
        }
        return {};
    };

    float minEnergy = 0.0F;
    float maxEnergy = 0.0F;
    const std::size_t previewCellCount = static_cast<std::size_t>(impl.previewNx) * impl.previewNy * impl.previewNz;
    std::vector<float> previewEnergy(previewCellCount, 0.0F);
    std::vector<float> previewEnergyMin(previewCellCount, std::numeric_limits<float>::infinity());
    std::array<std::vector<float>, 6> previewComponents;
    for (auto& component : previewComponents) component.assign(previewCellCount, 0.0F);
    std::vector<std::uint32_t> previewSampleCounts(previewCellCount, 0);
    std::array<float, 6> componentMin;
    std::array<float, 6> componentMax;
    for (std::size_t component = 0; component < components.size(); ++component) {
        componentMin[component] = components[component]->front();
        componentMax[component] = components[component]->front();
    }
    // eps0/mu0 -- matching CopperFDTDRunner.cpp's own captureFieldFrame() formula exactly (see
    // <openEMS's own tools/constants.h> EPS0/MUE0); duplicated here (not `#include`d) since this
    // file is deliberately kept free of any include that would drag the flat/source-checkout vs.
    // installed openEMS header-form clash into a PIMPL'd, otherwise openEMS-agnostic codec -- see
    // this header's own file comment on why FieldFrameSeriesWriter.hpp stays free of even a
    // forward-declared openEMS type.
    constexpr double kEps0 = 8.8541878128e-12;
    constexpr double kMu0 = 1.25663706212e-6;
    for (std::uint32_t z = 0; z < impl.nz; ++z) {
        for (std::uint32_t y = 0; y < impl.ny; ++y) {
            for (std::uint32_t x = 0; x < impl.nx; ++x) {
                const std::size_t i = x + static_cast<std::size_t>(impl.nx) * (y + static_cast<std::size_t>(impl.ny) * z);
                const std::size_t previewIndex = (x / impl.previewFactorX) +
                    static_cast<std::size_t>(impl.previewNx) * ((y / impl.previewFactorY) +
                    static_cast<std::size_t>(impl.previewNy) * (z / impl.previewFactorZ));
                for (std::size_t component = 0; component < components.size(); ++component) {
                    const float value = (*components[component])[i];
                    componentMin[component] = std::min(componentMin[component], value);
                    componentMax[component] = std::max(componentMax[component], value);
                    previewComponents[component][previewIndex] += value;
                }
                ++previewSampleCounts[previewIndex];
                const float eSq = ex[i] * ex[i] + ey[i] * ey[i] + ez[i] * ez[i];
                const float hSq = hx[i] * hx[i] + hy[i] * hy[i] + hz[i] * hz[i];
                const float energy = static_cast<float>(kEps0) * eSq + static_cast<float>(kMu0) * hSq;
                if (i == 0 || energy < minEnergy) minEnergy = energy;
                if (i == 0 || energy > maxEnergy) maxEnergy = energy;
                previewEnergy[previewIndex] = std::max(previewEnergy[previewIndex], energy);
                previewEnergyMin[previewIndex] = std::min(previewEnergyMin[previewIndex], energy);
            }
        }
    }
    for (std::size_t i = 0; i < previewCellCount; ++i) {
        const float divisor = static_cast<float>(previewSampleCounts[i]);
        for (auto& component : previewComponents) component[i] /= divisor;
    }

    // Rank preview cells by the detail lost in their low-resolution representation. Component
    // residuals are normalized by each component's own frame range so E and H units cannot dominate
    // one another; energy span is normalized independently. Taking the maximum makes a cell rank
    // highly when *any* selectable field needs detail. Non-finite residuals are intentionally first:
    // they are diagnostically important and must not make std::sort's ordering undefined.
    std::vector<float> refinementScore(previewCellCount, 0.0F);
    const float energyRange = maxEnergy - minEnergy;
    for (std::size_t i = 0; i < previewCellCount; ++i) {
        if (energyRange > 0.0F) {
            refinementScore[i] = std::max(refinementScore[i],
                                          (previewEnergy[i] - previewEnergyMin[i]) / energyRange);
        }
    }

    const hsize_t previewExtent[4] = {frameIndex + 1, impl.previewNz, impl.previewNy, impl.previewNx};
    const hsize_t previewStart[4] = {frameIndex, 0, 0, 0};
    const hsize_t previewCount[4] = {1, impl.previewNz, impl.previewNy, impl.previewNx};
    HId previewMemspace(H5Screate_simple(4, previewCount, nullptr), H5Sclose);
    auto appendPreview = [&](hid_t dataset, const float* values) -> std::expected<void, std::string> {
        if (H5Dset_extent(dataset, previewExtent) < 0) {
            return std::unexpected("H5Dset_extent failed while appending a preview frame");
        }
        HId filespace(H5Dget_space(dataset), H5Sclose);
        if (!filespace.valid() || !previewMemspace.valid() ||
            H5Sselect_hyperslab(filespace.get(), H5S_SELECT_SET, previewStart, nullptr, previewCount, nullptr) < 0 ||
            H5Dwrite(dataset, H5T_NATIVE_FLOAT, previewMemspace.get(), filespace.get(), H5P_DEFAULT, values) < 0) {
            return std::unexpected("H5Dwrite failed while appending a preview frame");
        }
        return {};
    };
    if (auto result = appendPreview(impl.previewEnergy, previewEnergy.data()); !result) return result;
    for (std::size_t i = 0; i < previewComponents.size(); ++i) {
        if (auto result = appendPreview(impl.previewComponent[i], previewComponents[i].data()); !result) return result;
    }
    // Lossless detail residuals. Arithmetic float subtraction cannot guarantee bit-exact recovery,
    // so store originalBits XOR previewMeanBits. Within a coarse block the shared high bits usually
    // become zero and compress well; decoding is exact and each 16x16x2 preview-cell tile is independent.
    const hsize_t detailExtent[4] = {frameIndex + 1, impl.nz, impl.ny, impl.nx};
    const std::uint32_t kTileX = impl.previewFactorX;
    const std::uint32_t kTileY = impl.previewFactorY;
    const std::uint32_t kTileZ = impl.previewFactorZ;
    std::vector<std::uint32_t> residual;
    residual.reserve(static_cast<std::size_t>(kTileX) * kTileY * kTileZ);
    for (std::size_t component = 0; component < components.size(); ++component) {
        const hid_t dataset = impl.component[component];
        const float componentRange = componentMax[component] - componentMin[component];
        if (H5Dset_extent(dataset, detailExtent) < 0) {
            return std::unexpected("H5Dset_extent failed while appending field detail");
        }
        for (std::uint32_t z0 = 0; z0 < impl.nz; z0 += kTileZ) {
            const std::uint32_t tileNz = std::min(kTileZ, impl.nz - z0);
            for (std::uint32_t y0 = 0; y0 < impl.ny; y0 += kTileY) {
                const std::uint32_t tileNy = std::min(kTileY, impl.ny - y0);
                for (std::uint32_t x0 = 0; x0 < impl.nx; x0 += kTileX) {
                    const std::uint32_t tileNx = std::min(kTileX, impl.nx - x0);
                    residual.clear();
                    for (std::uint32_t z = z0; z < z0 + tileNz; ++z) {
                        for (std::uint32_t y = y0; y < y0 + tileNy; ++y) {
                            for (std::uint32_t x = x0; x < x0 + tileNx; ++x) {
                                const std::size_t fullIndex = x + static_cast<std::size_t>(impl.nx) *
                                    (y + static_cast<std::size_t>(impl.ny) * z);
                                const std::size_t previewIndex = (x / impl.previewFactorX) +
                                    static_cast<std::size_t>(impl.previewNx) * ((y / impl.previewFactorY) +
                                    static_cast<std::size_t>(impl.previewNy) * (z / impl.previewFactorZ));
                                if (componentRange > 0.0F) {
                                    const float normalized =
                                        std::abs((*components[component])[fullIndex] -
                                                 previewComponents[component][previewIndex]) / componentRange;
                                    refinementScore[previewIndex] =
                                        std::max(refinementScore[previewIndex],
                                                 std::isfinite(normalized)
                                                     ? normalized
                                                     : std::numeric_limits<float>::infinity());
                                }
                                residual.push_back(std::bit_cast<std::uint32_t>((*components[component])[fullIndex]) ^
                                                   std::bit_cast<std::uint32_t>(previewComponents[component][previewIndex]));
                            }
                        }
                    }
                    const hsize_t start[4] = {frameIndex, z0, y0, x0};
                    const hsize_t count[4] = {1, tileNz, tileNy, tileNx};
                    HId filespace(H5Dget_space(dataset), H5Sclose);
                    HId memspace(H5Screate_simple(4, count, nullptr), H5Sclose);
                    if (!filespace.valid() || !memspace.valid() ||
                        H5Sselect_hyperslab(filespace.get(), H5S_SELECT_SET, start, nullptr, count, nullptr) < 0 ||
                        H5Dwrite(dataset, H5T_NATIVE_UINT32, memspace.get(), filespace.get(), H5P_DEFAULT,
                                 residual.data()) < 0) {
                        return std::unexpected("H5Dwrite failed while appending field detail residual");
                    }
                }
            }
        }
    }

    std::vector<std::uint32_t> refinementOrder(previewCellCount);
    std::iota(refinementOrder.begin(), refinementOrder.end(), 0U);
    std::sort(refinementOrder.begin(), refinementOrder.end(), [&](std::uint32_t lhs, std::uint32_t rhs) {
        if (refinementScore[lhs] != refinementScore[rhs]) return refinementScore[lhs] > refinementScore[rhs];
        return lhs < rhs;
    });
    {
        const hsize_t extent[2] = {frameIndex + 1, previewCellCount};
        const hsize_t start[2] = {frameIndex, 0};
        const hsize_t count[2] = {1, previewCellCount};
        HId memspace(H5Screate_simple(2, count, nullptr), H5Sclose);
        if (H5Dset_extent(impl.refinementOrder, extent) < 0) {
            return std::unexpected("H5Dset_extent failed while appending refinement order");
        }
        HId filespace(H5Dget_space(impl.refinementOrder), H5Sclose);
        if (!filespace.valid() || !memspace.valid() ||
            H5Sselect_hyperslab(filespace.get(), H5S_SELECT_SET, start, nullptr, count, nullptr) < 0 ||
            H5Dwrite(impl.refinementOrder, H5T_NATIVE_UINT32, memspace.get(), filespace.get(),
                     H5P_DEFAULT, refinementOrder.data()) < 0) {
            return std::unexpected("H5Dwrite failed while appending refinement order");
        }
    }

    if (auto r = appendScalar(impl.timestepDataset, H5T_NATIVE_UINT32, &timestep); !r) return r;
    if (auto r = appendScalar(impl.timeSecondsDataset, H5T_NATIVE_DOUBLE, &timeSeconds); !r) return r;
    if (auto r = appendScalar(impl.minEnergyDataset, H5T_NATIVE_FLOAT, &minEnergy); !r) return r;
    if (auto r = appendScalar(impl.maxEnergyDataset, H5T_NATIVE_FLOAT, &maxEnergy); !r) return r;
    for (std::size_t component = 0; component < components.size(); ++component) {
        if (auto r = appendScalar(impl.componentMinDataset[component], H5T_NATIVE_FLOAT,
                                  &componentMin[component]); !r) return r;
        if (auto r = appendScalar(impl.componentMaxDataset[component], H5T_NATIVE_FLOAT,
                                  &componentMax[component]); !r) return r;
    }

    impl.frameCount = frameIndex + 1;
    if (impl.frameCount % impl.chunkFrames == 0) {
        // See the format doc's own "Streaming write / durability" section -- a completed chunk is
        // the natural point to make the file safely reopenable, in case this process is killed
        // before ever reaching close().
        if (auto published = impl.publishFrames(); !published) {
            return published;
        }
        os_signpost_interval_end(fieldFrameSignpostLog(), impl.encodingBlockSignpost,
                                 "Encode field-frame block", "block=%u frames=%u",
                                 (impl.frameCount - 1) / impl.chunkFrames, impl.chunkFrames);
        impl.encodingBlockSignpost = OS_SIGNPOST_ID_INVALID;
    }
    return {};
}

std::expected<void, std::string> FieldFrameSeriesWriter::close() {
    if (!_impl || _impl->closed) {
        return {};
    }
    _impl->closed = true;
    const auto published = _impl->publishFrames();
    const bool flushFailed = !published.has_value();
    // A partial HDF5 chunk is actually compressed by the flush above. Keep its interval open until
    // after that work, otherwise Instruments would report only the preceding H5Dwrite calls and
    // omit the encoding cost we are trying to measure.
    if (_impl->encodingBlockSignpost != OS_SIGNPOST_ID_INVALID) {
        const std::uint32_t partialFrames = _impl->frameCount % _impl->chunkFrames;
        os_signpost_interval_end(fieldFrameSignpostLog(), _impl->encodingBlockSignpost,
                                 "Encode field-frame block", "block=%u frames=%u partial=1 success=%d",
                                 _impl->frameCount / _impl->chunkFrames, partialFrames,
                                 flushFailed ? 0 : 1);
        _impl->encodingBlockSignpost = OS_SIGNPOST_ID_INVALID;
    }
    // Reverse of acquisition order -- datasets/groups (owned) before the file itself, matching
    // HDF5's own recommendation to close child objects before their parent file (Impl's member
    // declaration order already gets this right via destructor order too, but close() is callable
    // well before the destructor runs, so it has to do the same thing explicitly here).
    _impl->owned.clear();
    _impl->file.reset();
    if (flushFailed) {
        return std::unexpected(published.error());
    }
    return {};
}

} // namespace copper
