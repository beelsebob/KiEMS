#include "FieldFrameSeriesWriter.hpp"

#include <algorithm>
#include <array>
#include <cstdint>
#include <cstdio>
#include <limits>
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
                                                             const hsize_t* chunkDims, bool useBlosc2,
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
    // Sized to comfortably hold one full chunk (every slot -- HDF5's own chunk cache is per
    // dataset, not shared) so a chunk being filled one frame at a time is never evicted/
    // recompressed before it's actually complete. rdcc_nbytes is the byte budget; rdcc_nslots
    // (a hash-table size, conventionally a prime well above the expected number of simultaneously
    // "hot" chunks) and rdcc_w0 (eviction policy, 0=LRU..1=always-prefer-more-accessed) are left at
    // HDF5's own sane defaults' shape, just with a bigger byte budget.
    std::size_t chunkBytes = sizeof(float);
    for (int i = 0; i < rank; ++i) {
        chunkBytes *= chunkDims[i];
    }
    HId dapl(H5Pcreate(H5P_DATASET_ACCESS), H5Pclose);
    if (!dapl.valid() || H5Pset_chunk_cache(dapl.get(), 1009, chunkBytes * 2, 0.75) < 0) {
        return std::unexpected(std::string("H5Pset_chunk_cache failed for ") + name);
    }
    hid_t dataset =
        H5Dcreate2(file, name, H5T_NATIVE_FLOAT, space.get(), H5P_DEFAULT, dcpl.get(), dapl.get());
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

} // namespace

/// Every open HDF5 handle this writer holds for the file's lifetime, plus running frame count.
/// `bigDatasets`/`smallDatasets` are indexed in a fixed order (see the constructor) matching
/// writeFrame()'s own parameter order, so appendFrame() can loop over them generically.
struct FieldFrameSeriesWriter::Impl {
    HId file;
    std::array<hid_t, 6> component{}; // Ex,Ey,Ez,Hx,Hy,Hz -- owned via `owned`, not closed directly
    hid_t timestepDataset = -1;
    hid_t timeSecondsDataset = -1;
    hid_t minEnergyDataset = -1;
    hid_t maxEnergyDataset = -1;
    std::array<hid_t, 6> componentMinDataset{};
    std::array<hid_t, 6> componentMaxDataset{};
    hid_t publishedFrameCountDataset = -1;
    std::vector<HId> owned; // keeps every dataset/property-list handle alive for the file's lifetime
    std::uint32_t nx = 0, ny = 0, nz = 0;
    std::uint32_t frameCount = 0;
    std::uint32_t publishedFrameCount = 0;
    std::uint32_t chunkFrames = 16;
    os_signpost_id_t encodingBlockSignpost = OS_SIGNPOST_ID_INVALID;
    bool closed = false;

    std::expected<void, std::string> publishFrames() {
        if (publishedFrameCount == frameCount) {
            return {};
        }
        // SWMR has no transaction spanning the nineteen extendible datasets in this file. Flush all
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
    if (chunkFrames == 0) {
        chunkFrames = 1;
    }
    // Blosc2/HDF5's filter-callback API is int32_t-sized throughout (nbytes/buf_size, and the
    // BLOSC2_MAX_OVERHEAD compressor headroom added on top of that on the compress side) -- a single
    // filter invocation's own input (one dataset's whole chunk: chunkFrames * nx * ny * nz *
    // sizeof(float)) must stay well under that ~2GiB ceiling, or the filter callback fails outright.
    // That never showed up against the smoketest's tiny synthetic grid, but a large real board's mesh
    // with the caller's requested chunkFrames (16 by default) can push a single component's own chunk
    // well past it. Shrinks chunkFrames for this specific series so its own per-chunk byte count stays
    // under a budget with real headroom below the hard limit -- never below 1 frame, this format's own
    // finest granularity; a single frame's own chunk gets no inter-frame compression benefit, but at
    // least writes successfully instead of failing the whole run's field capture outright.
    constexpr std::uint64_t kMaxChunkBytes = 1536ULL * 1024 * 1024; // 1.5 GiB -- well under Blosc2/
                                                                     // HDF5's hard ~2GiB (INT32_MAX)
                                                                     // per-filter-call ceiling.
    const std::uint64_t frameBytes =
        static_cast<std::uint64_t>(header.nx) * header.ny * header.nz * sizeof(float);
    if (frameBytes == 0) {
        return std::unexpected("FieldFrameSeriesWriter::create: computed frame size is zero");
    }
    if (frameBytes > static_cast<std::uint64_t>(std::numeric_limits<std::int32_t>::max())) {
        return std::unexpected("FieldFrameSeriesWriter::create: a single frame (" + std::to_string(frameBytes) +
                               " bytes) already exceeds Blosc2/HDF5's own filter size limit -- this mesh "
                               "is too large for the field frame-series format at its current resolution");
    }
    const std::uint64_t maxFramesPerChunk = std::max<std::uint64_t>(kMaxChunkBytes / frameBytes, 1);
    chunkFrames = static_cast<std::uint32_t>(std::min<std::uint64_t>(chunkFrames, maxFramesPerChunk));
    // Plain stdout fprintf, matching CopperFDTDRunner.cpp's own progress-reporting convention --
    // Copper.framework doesn't link libkicadems, so kicad_ems's own Cu::logInfo isn't reachable
    // here. One line per series (only at create() time, not per-frame), giving the grid size and
    // per-frame/per-chunk byte counts that actually determine whether the size clamp above engages --
    // the real board sizes that trigger it are much larger than the smoketest's tiny synthetic grid,
    // so this is the only way to see the true numbers from a real run's own console output.
    std::fprintf(stdout,
                 "Copper: field frame-series %s: grid=%ux%ux%u, frame=%llu bytes/component, "
                 "chunkFrames=%u (%llu bytes/component/chunk)\n",
                 path.string().c_str(), header.nx, header.ny, header.nz,
                 static_cast<unsigned long long>(frameBytes), chunkFrames,
                 static_cast<unsigned long long>(frameBytes) * chunkFrames);
    if (auto registered = registerHDF5Blosc2Filter(); !registered) {
        return std::unexpected(registered.error());
    }

    auto impl = std::make_unique<Impl>();
    impl->nx = header.nx;
    impl->ny = header.ny;
    impl->nz = header.nz;
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
    if (auto r = writeScalarAttribute<std::int32_t>(file, "format_version", H5T_NATIVE_INT32, 1); !r) return std::unexpected(r.error());
    if (auto r = writeStringAttribute(file, "simulation_name", header.simulationName); !r) return std::unexpected(r.error());
    if (auto r = writeScalarAttribute<std::int32_t>(file, "excited_port", H5T_NATIVE_INT32, header.excitedPort); !r) return std::unexpected(r.error());
    if (auto r = writeScalarAttribute<std::int32_t>(file, "nx", H5T_NATIVE_INT32, static_cast<std::int32_t>(header.nx)); !r) return std::unexpected(r.error());
    if (auto r = writeScalarAttribute<std::int32_t>(file, "ny", H5T_NATIVE_INT32, static_cast<std::int32_t>(header.ny)); !r) return std::unexpected(r.error());
    if (auto r = writeScalarAttribute<std::int32_t>(file, "nz", H5T_NATIVE_INT32, static_cast<std::int32_t>(header.nz)); !r) return std::unexpected(r.error());
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
    }

    // /frames group + the six big extendible component datasets, chunked+compressed.
    {
        HId frames(H5Gcreate2(file, "/frames", H5P_DEFAULT, H5P_DEFAULT, H5P_DEFAULT), H5Gclose);
        if (!frames.valid()) {
            return std::unexpected("H5Gcreate2 failed for /frames");
        }
        static const char* const kComponentNames[6] = {"/frames/Ex", "/frames/Ey", "/frames/Ez",
                                                          "/frames/Hx", "/frames/Hy", "/frames/Hz"};
        const hsize_t dims4[4] = {0, header.nx, header.ny, header.nz};
        const hsize_t maxdims4[4] = {H5S_UNLIMITED, header.nx, header.ny, header.nz};
        const hsize_t chunk4[4] = {chunkFrames, header.nx, header.ny, header.nz};
        for (int i = 0; i < 6; ++i) {
            auto ds = createExtendibleDataset(file, kComponentNames[i], 4, dims4, maxdims4, chunk4, true,
                                              impl->owned);
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
    const hsize_t newExtent4[4] = {frameIndex + 1, impl.nx, impl.ny, impl.nz};
    const hsize_t start4[4] = {frameIndex, 0, 0, 0};
    const hsize_t count4[4] = {1, impl.nx, impl.ny, impl.nz};
    HId memspace4(H5Screate_simple(4, count4, nullptr), H5Sclose);
    if (!memspace4.valid()) {
        return std::unexpected("H5Screate_simple failed for a field-component frame write");
    }
    for (std::size_t i = 0; i < components.size(); ++i) {
        const hid_t dataset = impl.component[i];
        if (H5Dset_extent(dataset, newExtent4) < 0) {
            return std::unexpected("H5Dset_extent failed while appending a frame");
        }
        HId filespace(H5Dget_space(dataset), H5Sclose);
        if (!filespace.valid() ||
            H5Sselect_hyperslab(filespace.get(), H5S_SELECT_SET, start4, nullptr, count4, nullptr) < 0) {
            return std::unexpected("H5Sselect_hyperslab failed while appending a frame");
        }
        if (H5Dwrite(dataset, H5T_NATIVE_FLOAT, memspace4.get(), filespace.get(), H5P_DEFAULT,
                     components[i]->data()) < 0) {
            return std::unexpected("H5Dwrite failed while appending a frame");
        }
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
    for (std::size_t i = 0; i < cellCount; ++i) {
        for (std::size_t component = 0; component < components.size(); ++component) {
            componentMin[component] = std::min(componentMin[component], (*components[component])[i]);
            componentMax[component] = std::max(componentMax[component], (*components[component])[i]);
        }
        const float eSq = ex[i] * ex[i] + ey[i] * ey[i] + ez[i] * ez[i];
        const float hSq = hx[i] * hx[i] + hy[i] * hy[i] + hz[i] * hz[i];
        const float energy = static_cast<float>(kEps0) * eSq + static_cast<float>(kMu0) * hSq;
        if (i == 0 || energy < minEnergy) minEnergy = energy;
        if (i == 0 || energy > maxEnergy) maxEnergy = energy;
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
