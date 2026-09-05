#include "FieldFrameSeriesReader.hpp"

#include <algorithm>
#include <array>
#include <limits>
#include <mutex>
#include <hdf5.h>

#include "Internal/CopperFieldFrameSignposts.hpp"
#include "Internal/CopperHDF5Blosc2.hpp"

namespace copper {

namespace {

constexpr std::array<const char*, 6> kComponentNames = {
    "/frames/Ex", "/frames/Ey", "/frames/Ez", "/frames/Hx", "/frames/Hy", "/frames/Hz"};
constexpr std::array<const char*, 6> kComponentMinNames = {
    "/frames/Ex_min", "/frames/Ey_min", "/frames/Ez_min",
    "/frames/Hx_min", "/frames/Hy_min", "/frames/Hz_min"};
constexpr std::array<const char*, 6> kComponentMaxNames = {
    "/frames/Ex_max", "/frames/Ey_max", "/frames/Ez_max",
    "/frames/Hx_max", "/frames/Hy_max", "/frames/Hz_max"};

// Same RAII shape as FieldFrameSeriesWriter.cpp's own HId -- deliberately duplicated rather than
// shared through a private header, since these two files are the only two consumers and a shared
// tiny RAII helper isn't worth a third file just to avoid ~25 lines appearing twice.
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

struct DisableHDF5ErrorPrinting {
    DisableHDF5ErrorPrinting() { H5Eset_auto2(H5E_DEFAULT, nullptr, nullptr); }
};
const DisableHDF5ErrorPrinting kDisableHDF5ErrorPrinting;

std::expected<std::int32_t, std::string> readInt32Attribute(hid_t loc, const char* name) {
    HId attr(H5Aopen(loc, name, H5P_DEFAULT), H5Aclose);
    if (!attr.valid()) {
        return std::unexpected(std::string("H5Aopen failed for attribute ") + name);
    }
    std::int32_t value = 0;
    if (H5Aread(attr.get(), H5T_NATIVE_INT32, &value) < 0) {
        return std::unexpected(std::string("H5Aread failed for attribute ") + name);
    }
    return value;
}

std::expected<double, std::string> readDoubleAttribute(hid_t loc, const char* name) {
    HId attr(H5Aopen(loc, name, H5P_DEFAULT), H5Aclose);
    if (!attr.valid()) {
        return std::unexpected(std::string("H5Aopen failed for attribute ") + name);
    }
    double value = 0.0;
    if (H5Aread(attr.get(), H5T_NATIVE_DOUBLE, &value) < 0) {
        return std::unexpected(std::string("H5Aread failed for attribute ") + name);
    }
    return value;
}

std::expected<std::string, std::string> readStringAttribute(hid_t loc, const char* name) {
    HId attr(H5Aopen(loc, name, H5P_DEFAULT), H5Aclose);
    if (!attr.valid()) {
        return std::unexpected(std::string("H5Aopen failed for attribute ") + name);
    }
    HId type(H5Aget_type(attr.get()), H5Tclose);
    if (!type.valid()) {
        return std::unexpected(std::string("H5Aget_type failed for attribute ") + name);
    }
    const std::size_t size = H5Tget_size(type.get());
    if (size == 0) {
        return std::unexpected(std::string("H5Tget_size failed for attribute ") + name);
    }
    std::string value(size, '\0');
    if (H5Aread(attr.get(), type.get(), value.data()) < 0) {
        return std::unexpected(std::string("H5Aread failed for attribute ") + name);
    }
    return value;
}

std::expected<std::vector<double>, std::string> readDoubleArrayDataset(hid_t file, const char* name,
                                                                          std::uint32_t expectedCount) {
    HId dataset(H5Dopen2(file, name, H5P_DEFAULT), H5Dclose);
    if (!dataset.valid()) {
        return std::unexpected(std::string("H5Dopen2 failed for ") + name);
    }
    std::vector<double> values(expectedCount);
    if (expectedCount > 0 &&
        H5Dread(dataset.get(), H5T_NATIVE_DOUBLE, H5S_ALL, H5S_ALL, H5P_DEFAULT, values.data()) < 0) {
        return std::unexpected(std::string("H5Dread failed for ") + name);
    }
    return values;
}

/// Reads the published prefix of a small (one value per frame) 1D dataset eagerly. During SWMR the
/// physical dataset may already contain a later, not-yet-published block, so an extent larger than
/// frameCount is valid; only an extent smaller than the authoritative published count is corrupt.
template <typename T>
std::expected<std::vector<T>, std::string> readSmallArrayDataset(hid_t file, const char* name, hid_t nativeType,
                                                                     std::uint32_t frameCount) {
    HId dataset(H5Dopen2(file, name, H5P_DEFAULT), H5Dclose);
    if (!dataset.valid()) {
        return std::unexpected(std::string("H5Dopen2 failed for ") + name);
    }
    if (H5Drefresh(dataset.get()) < 0) {
        return std::unexpected(std::string("H5Drefresh failed for ") + name);
    }
    HId space(H5Dget_space(dataset.get()), H5Sclose);
    hsize_t dims[1] = {0};
    if (!space.valid() || H5Sget_simple_extent_ndims(space.get()) != 1 ||
        H5Sget_simple_extent_dims(space.get(), dims, nullptr) < 0 || dims[0] < frameCount) {
        return std::unexpected(std::string("Per-frame metadata extent mismatch for ") + name);
    }
    std::vector<T> values(frameCount);
    if (frameCount > 0) {
        const hsize_t start[1] = {0};
        const hsize_t count[1] = {frameCount};
        HId memorySpace(H5Screate_simple(1, count, nullptr), H5Sclose);
        if (!memorySpace.valid() ||
            H5Sselect_hyperslab(space.get(), H5S_SELECT_SET, start, nullptr, count, nullptr) < 0 ||
            H5Dread(dataset.get(), nativeType, memorySpace.get(), space.get(), H5P_DEFAULT,
                    values.data()) < 0) {
            return std::unexpected(std::string("H5Dread failed for ") + name);
        }
    }
    return values;
}

} // namespace

struct FieldFrameSeriesReader::Impl {
    HId file;
    std::array<HId, 6> component; // Ex,Ey,Ez,Hx,Hy,Hz, opened once and kept for the reader's lifetime
    HId publishedFrameCountDataset;
    FieldFrameSeriesWriter::Header header;
    std::uint32_t frameCount = 0;
    std::vector<std::uint32_t> timesteps;
    std::vector<double> timeSeconds;
    std::vector<float> minEnergy;
    std::vector<float> maxEnergy;
    std::array<std::vector<float>, 6> componentMin;
    std::array<std::vector<float>, 6> componentMax;
    std::array<std::optional<FieldComponentRange>, 6> seriesComponentRange;
    std::uint32_t chunkFrames = 1;
    mutable std::uint32_t cachedChunkIndex = std::numeric_limits<std::uint32_t>::max();
    mutable std::uint32_t cachedChunkFrameCount = 0;
    mutable std::array<std::vector<float>, 6> cachedComponents;
    // Second, independent slot warmed by prefetchFrame() -- kept separate from cachedChunkIndex/
    // cachedComponents above so a background prefetch of the *next* chunk can never evict the chunk
    // readFrame() is still actively serving in-progress playback from.
    mutable std::uint32_t prefetchedChunkIndex = std::numeric_limits<std::uint32_t>::max();
    mutable std::uint32_t prefetchedChunkFrameCount = 0;
    mutable std::array<std::vector<float>, 6> prefetchedComponents;
    // Guards every field above from cachedChunkIndex down through decodeChunk's own HDF5 calls --
    // readFrame() and prefetchFrame() each hold this for their whole body, so a background
    // prefetchFrame() call and a foreground readFrame() call are never calling into HDF5
    // concurrently (the vendored HDF5 build is not known to be configured thread-safe), and never
    // racing on the cache-slot bookkeeping (e.g. readFrame()'s own promotion check against
    // prefetchedChunkIndex, which prefetchFrame() writes from a different thread).
    mutable std::mutex mutex;

    std::expected<void, std::string> loadPublishedMetadata(std::uint32_t newFrameCount) {
        if (newFrameCount < frameCount) {
            return std::unexpected("Field-frame published count moved backwards");
        }
        for (std::size_t index = 0; index < component.size(); ++index) {
            if (H5Drefresh(component[index].get()) < 0) {
                return std::unexpected(std::string("H5Drefresh failed for ") + kComponentNames[index]);
            }
            HId space(H5Dget_space(component[index].get()), H5Sclose);
            hsize_t dims[4] = {0, 0, 0, 0};
            if (!space.valid() || H5Sget_simple_extent_dims(space.get(), dims, nullptr) < 0 ||
                dims[0] < newFrameCount) {
                return std::unexpected(std::string("Published extent is unavailable for ") +
                                       kComponentNames[index]);
            }
        }

        auto newTimesteps =
            readSmallArrayDataset<std::uint32_t>(file.get(), "/frames/timestep", H5T_NATIVE_UINT32,
                                                 newFrameCount);
        auto newTimes = readSmallArrayDataset<double>(file.get(), "/frames/time_seconds",
                                                      H5T_NATIVE_DOUBLE, newFrameCount);
        auto newMinEnergy = readSmallArrayDataset<float>(file.get(), "/frames/min_energy",
                                                         H5T_NATIVE_FLOAT, newFrameCount);
        auto newMaxEnergy = readSmallArrayDataset<float>(file.get(), "/frames/max_energy",
                                                         H5T_NATIVE_FLOAT, newFrameCount);
        if (!newTimesteps) return std::unexpected(newTimesteps.error());
        if (!newTimes) return std::unexpected(newTimes.error());
        if (!newMinEnergy) return std::unexpected(newMinEnergy.error());
        if (!newMaxEnergy) return std::unexpected(newMaxEnergy.error());

        std::array<std::vector<float>, 6> newComponentMin;
        std::array<std::vector<float>, 6> newComponentMax;
        std::array<std::optional<FieldComponentRange>, 6> newSeriesRanges;
        for (std::size_t index = 0; index < component.size(); ++index) {
            auto minima = readSmallArrayDataset<float>(file.get(), kComponentMinNames[index],
                                                       H5T_NATIVE_FLOAT, newFrameCount);
            auto maxima = readSmallArrayDataset<float>(file.get(), kComponentMaxNames[index],
                                                       H5T_NATIVE_FLOAT, newFrameCount);
            if (!minima) return std::unexpected(minima.error());
            if (!maxima) return std::unexpected(maxima.error());
            newComponentMin[index] = std::move(*minima);
            newComponentMax[index] = std::move(*maxima);
            if (newFrameCount > 0) {
                newSeriesRanges[index] = FieldComponentRange{
                    *std::min_element(newComponentMin[index].begin(), newComponentMin[index].end()),
                    *std::max_element(newComponentMax[index].begin(), newComponentMax[index].end())};
            }
        }

        timesteps = std::move(*newTimesteps);
        timeSeconds = std::move(*newTimes);
        minEnergy = std::move(*newMinEnergy);
        maxEnergy = std::move(*newMaxEnergy);
        componentMin = std::move(newComponentMin);
        componentMax = std::move(newComponentMax);
        seriesComponentRange = std::move(newSeriesRanges);
        frameCount = newFrameCount;
        return {};
    }

    std::expected<std::uint32_t, std::string> refreshPublishedFrames() {
        if (H5Drefresh(publishedFrameCountDataset.get()) < 0) {
            return std::unexpected("H5Drefresh failed for /frames/published_frame_count");
        }
        std::uint32_t publishedCount = 0;
        if (H5Dread(publishedFrameCountDataset.get(), H5T_NATIVE_UINT32, H5S_ALL, H5S_ALL,
                    H5P_DEFAULT, &publishedCount) < 0) {
            return std::unexpected("H5Dread failed for /frames/published_frame_count");
        }
        if (publishedCount != frameCount) {
            if (auto loaded = loadPublishedMetadata(publishedCount); !loaded) {
                return std::unexpected(loaded.error());
            }
        }
        return frameCount;
    }

    /// Decodes chunk `chunkIndex` (one hyperslab read per component, covering the whole chunk) into
    /// `outComponents`/`outFrameCount` -- shared by readFrame()'s cache-miss path and prefetchFrame(),
    /// which differ only in which slot they decode into. A member (rather than a free function) only
    /// because `Impl` itself is private to FieldFrameSeriesReader.
    std::expected<void, std::string> decodeChunk(std::uint32_t chunkIndex,
                                                   std::array<std::vector<float>, 6>& outComponents,
                                                   std::uint32_t& outFrameCount) const {
        const std::size_t cellCount = static_cast<std::size_t>(header.nx) * header.ny * header.nz;
        const std::uint32_t firstFrame = chunkIndex * chunkFrames;
        const std::uint32_t framesInChunk = std::min(chunkFrames, frameCount - firstFrame);
        const os_signpost_id_t signpost = os_signpost_id_generate(fieldFrameSignpostLog());
        os_signpost_interval_begin(fieldFrameSignpostLog(), signpost, "Decode field-frame block",
                                   "block=%u first_frame=%u frames=%u", chunkIndex, firstFrame,
                                   framesInChunk);
        const auto finishSignpost = [&](bool success) {
            os_signpost_interval_end(fieldFrameSignpostLog(), signpost, "Decode field-frame block",
                                     "block=%u frames=%u success=%d", chunkIndex, framesInChunk,
                                     success ? 1 : 0);
        };
        const hsize_t start4[4] = {firstFrame, 0, 0, 0};
        const hsize_t count4[4] = {framesInChunk, header.nx, header.ny, header.nz};
        HId memspace(H5Screate_simple(4, count4, nullptr), H5Sclose);
        if (!memspace.valid()) {
            finishSignpost(false);
            return std::unexpected("H5Screate_simple failed while reading a field-frame chunk");
        }
        for (std::size_t i = 0; i < outComponents.size(); ++i) {
            outComponents[i].resize(cellCount * framesInChunk);
            HId filespace(H5Dget_space(component[i].get()), H5Sclose);
            if (!filespace.valid() ||
                H5Sselect_hyperslab(filespace.get(), H5S_SELECT_SET, start4, nullptr, count4, nullptr) < 0) {
                finishSignpost(false);
                return std::unexpected("H5Sselect_hyperslab failed while reading a field-frame chunk");
            }
            if (H5Dread(component[i].get(), H5T_NATIVE_FLOAT, memspace.get(), filespace.get(), H5P_DEFAULT,
                        outComponents[i].data()) < 0) {
                finishSignpost(false);
                return std::unexpected("H5Dread failed while reading a field-frame chunk");
            }
        }
        outFrameCount = framesInChunk;
        finishSignpost(true);
        return {};
    }
};

FieldFrameSeriesReader::FieldFrameSeriesReader(std::unique_ptr<Impl> impl) : _impl(std::move(impl)) {}
FieldFrameSeriesReader::FieldFrameSeriesReader(FieldFrameSeriesReader&&) noexcept = default;
FieldFrameSeriesReader& FieldFrameSeriesReader::operator=(FieldFrameSeriesReader&&) noexcept = default;
FieldFrameSeriesReader::~FieldFrameSeriesReader() = default;

std::expected<FieldFrameSeriesReader, std::string> FieldFrameSeriesReader::open(const std::filesystem::path& path) {
    if (auto registered = registerHDF5Blosc2Filter(); !registered) {
        return std::unexpected(registered.error());
    }
    auto impl = std::make_unique<Impl>();
    HId fileAccess(H5Pcreate(H5P_FILE_ACCESS), H5Pclose);
    if (!fileAccess.valid() ||
        H5Pset_libver_bounds(fileAccess.get(), H5F_LIBVER_LATEST, H5F_LIBVER_LATEST) < 0) {
        return std::unexpected("Could not configure the HDF5 SWMR reader");
    }
    impl->file = HId(H5Fopen(path.string().c_str(), H5F_ACC_RDONLY | H5F_ACC_SWMR_READ,
                             fileAccess.get()), H5Fclose);
    if (!impl->file.valid()) {
        return std::unexpected("Could not open " + path.string());
    }
    const hid_t file = impl->file.get();

    auto formatVersion = readInt32Attribute(file, "format_version");
    if (!formatVersion) return std::unexpected(formatVersion.error());
    if (*formatVersion != 1) {
        return std::unexpected("Unsupported field frame-series format_version " + std::to_string(*formatVersion));
    }
    auto simulationName = readStringAttribute(file, "simulation_name");
    if (!simulationName) return std::unexpected(simulationName.error());
    impl->header.simulationName = *simulationName;
    auto excitedPort = readInt32Attribute(file, "excited_port");
    if (!excitedPort) return std::unexpected(excitedPort.error());
    impl->header.excitedPort = *excitedPort;
    auto nx = readInt32Attribute(file, "nx");
    auto ny = readInt32Attribute(file, "ny");
    auto nz = readInt32Attribute(file, "nz");
    if (!nx) return std::unexpected(nx.error());
    if (!ny) return std::unexpected(ny.error());
    if (!nz) return std::unexpected(nz.error());
    impl->header.nx = static_cast<std::uint32_t>(*nx);
    impl->header.ny = static_cast<std::uint32_t>(*ny);
    impl->header.nz = static_cast<std::uint32_t>(*nz);
    auto timestepSeconds = readDoubleAttribute(file, "timestep_seconds");
    if (!timestepSeconds) return std::unexpected(timestepSeconds.error());
    impl->header.timestepSeconds = *timestepSeconds;
    auto boardZMin = readDoubleAttribute(file, "board_z_min");
    auto boardZMax = readDoubleAttribute(file, "board_z_max");
    if (!boardZMin) return std::unexpected(boardZMin.error());
    if (!boardZMax) return std::unexpected(boardZMax.error());
    impl->header.boardZMin = *boardZMin;
    impl->header.boardZMax = *boardZMax;

    auto lineX = readDoubleArrayDataset(file, "/grid/line_x", impl->header.nx);
    auto lineY = readDoubleArrayDataset(file, "/grid/line_y", impl->header.ny);
    auto lineZ = readDoubleArrayDataset(file, "/grid/line_z", impl->header.nz);
    if (!lineX) return std::unexpected(lineX.error());
    if (!lineY) return std::unexpected(lineY.error());
    if (!lineZ) return std::unexpected(lineZ.error());
    impl->header.lineX = std::move(*lineX);
    impl->header.lineY = std::move(*lineY);
    impl->header.lineZ = std::move(*lineZ);

    impl->publishedFrameCountDataset =
        HId(H5Dopen2(file, "/frames/published_frame_count", H5P_DEFAULT), H5Dclose);
    if (!impl->publishedFrameCountDataset.valid() ||
        H5Dread(impl->publishedFrameCountDataset.get(), H5T_NATIVE_UINT32, H5S_ALL, H5S_ALL,
                H5P_DEFAULT, &impl->frameCount) < 0) {
        return std::unexpected("Could not read /frames/published_frame_count");
    }

    for (std::size_t i = 0; i < kComponentNames.size(); ++i) {
        HId dataset(H5Dopen2(file, kComponentNames[i], H5P_DEFAULT), H5Dclose);
        if (!dataset.valid()) {
            return std::unexpected(std::string("H5Dopen2 failed for ") + kComponentNames[i]);
        }
        if (i == 0) {
            // The scalar publication dataset above is authoritative. Ex's current physical extent
            // may already include a block the writer has not published yet.
            HId space(H5Dget_space(dataset.get()), H5Sclose);
            if (!space.valid()) {
                return std::unexpected("H5Dget_space failed for /frames/Ex");
            }
            hsize_t dims[4] = {0, 0, 0, 0};
            if (H5Sget_simple_extent_dims(space.get(), dims, nullptr) < 0) {
                return std::unexpected("H5Sget_simple_extent_dims failed for /frames/Ex");
            }
            if (dims[0] < impl->frameCount) {
                return std::unexpected("Published field-frame count exceeds /frames/Ex's extent");
            }

            // Discover the actual on-disk frame granularity rather than duplicating the writer's
            // default. A caller may choose a different chunkFrames value for a particular series.
            HId creationProperties(H5Dget_create_plist(dataset.get()), H5Pclose);
            hsize_t chunkDims[4] = {1, 0, 0, 0};
            if (creationProperties.valid() && H5Pget_layout(creationProperties.get()) == H5D_CHUNKED &&
                H5Pget_chunk(creationProperties.get(), 4, chunkDims) == 4 && chunkDims[0] > 0) {
                impl->chunkFrames = static_cast<std::uint32_t>(chunkDims[0]);
            }
        }
        impl->component[i] = std::move(dataset);
    }

    auto timestepValues = readSmallArrayDataset<std::uint32_t>(file, "/frames/timestep", H5T_NATIVE_UINT32, impl->frameCount);
    if (!timestepValues) return std::unexpected(timestepValues.error());
    auto timeSecondsValues = readSmallArrayDataset<double>(file, "/frames/time_seconds", H5T_NATIVE_DOUBLE, impl->frameCount);
    if (!timeSecondsValues) return std::unexpected(timeSecondsValues.error());
    auto minEnergyValues = readSmallArrayDataset<float>(file, "/frames/min_energy", H5T_NATIVE_FLOAT, impl->frameCount);
    if (!minEnergyValues) return std::unexpected(minEnergyValues.error());
    auto maxEnergyValues = readSmallArrayDataset<float>(file, "/frames/max_energy", H5T_NATIVE_FLOAT, impl->frameCount);
    if (!maxEnergyValues) return std::unexpected(maxEnergyValues.error());
    impl->timesteps = std::move(*timestepValues);
    impl->timeSeconds = std::move(*timeSecondsValues);
    impl->minEnergy = std::move(*minEnergyValues);
    impl->maxEnergy = std::move(*maxEnergyValues);

    for (std::size_t component = 0; component < impl->component.size(); ++component) {
        auto minima = readSmallArrayDataset<float>(file, kComponentMinNames[component], H5T_NATIVE_FLOAT,
                                                   impl->frameCount);
        if (!minima) return std::unexpected(minima.error());
        auto maxima = readSmallArrayDataset<float>(file, kComponentMaxNames[component], H5T_NATIVE_FLOAT,
                                                   impl->frameCount);
        if (!maxima) return std::unexpected(maxima.error());
        impl->componentMin[component] = std::move(*minima);
        impl->componentMax[component] = std::move(*maxima);
        if (impl->frameCount > 0) {
            impl->seriesComponentRange[component] = FieldComponentRange{
                *std::min_element(impl->componentMin[component].begin(), impl->componentMin[component].end()),
                *std::max_element(impl->componentMax[component].begin(), impl->componentMax[component].end())};
        }
    }

    return FieldFrameSeriesReader(std::move(impl));
}

const FieldFrameSeriesWriter::Header& FieldFrameSeriesReader::header() const { return _impl->header; }
std::expected<std::uint32_t, std::string> FieldFrameSeriesReader::refresh() const {
    std::lock_guard lock(_impl->mutex);
    return _impl->refreshPublishedFrames();
}

std::uint32_t FieldFrameSeriesReader::frameCount() const {
    std::lock_guard lock(_impl->mutex);
    return _impl->frameCount;
}

std::expected<void, std::string> FieldFrameSeriesReader::readFrame(std::uint32_t index, std::vector<float>& ex,
                                                                       std::vector<float>& ey, std::vector<float>& ez,
                                                                       std::vector<float>& hx, std::vector<float>& hy,
                                                                       std::vector<float>& hz) const {
    Impl& impl = *_impl;
    std::lock_guard lock(impl.mutex);
    if (index >= impl.frameCount) {
        return std::unexpected("FieldFrameSeriesReader::readFrame: index out of range");
    }
    const std::uint32_t chunkIndex = index / impl.chunkFrames;
    std::array<std::vector<float>*, 6> outputs = {&ex, &ey, &ez, &hx, &hy, &hz};
    const std::size_t cellCount = static_cast<std::size_t>(impl.header.nx) * impl.header.ny * impl.header.nz;
    if (impl.cachedChunkIndex != chunkIndex) {
        if (impl.prefetchedChunkIndex == chunkIndex) {
            // Already warmed by a prior prefetchFrame() call -- promote it into the primary slot
            // rather than decoding again.
            impl.cachedComponents = std::move(impl.prefetchedComponents);
            impl.cachedChunkFrameCount = impl.prefetchedChunkFrameCount;
            impl.cachedChunkIndex = chunkIndex;
            impl.prefetchedChunkIndex = std::numeric_limits<std::uint32_t>::max();
        } else {
            auto decoded = impl.decodeChunk(chunkIndex, impl.cachedComponents, impl.cachedChunkFrameCount);
            if (!decoded) {
                return std::unexpected(decoded.error());
            }
            impl.cachedChunkIndex = chunkIndex;
        }
    }

    const std::size_t frameWithinChunk = index % impl.chunkFrames;
    if (frameWithinChunk >= impl.cachedChunkFrameCount) {
        return std::unexpected("FieldFrameSeriesReader internal chunk index is out of range");
    }
    const std::size_t offset = frameWithinChunk * cellCount;
    for (std::size_t i = 0; i < outputs.size(); ++i) {
        outputs[i]->assign(impl.cachedComponents[i].begin() + static_cast<std::ptrdiff_t>(offset),
                           impl.cachedComponents[i].begin() + static_cast<std::ptrdiff_t>(offset + cellCount));
    }
    return {};
}

void FieldFrameSeriesReader::prefetchFrame(std::uint32_t index) const {
    Impl& impl = *_impl;
    std::lock_guard lock(impl.mutex);
    if (index >= impl.frameCount) {
        return;
    }
    const std::uint32_t chunkIndex = index / impl.chunkFrames;
    if (impl.cachedChunkIndex == chunkIndex || impl.prefetchedChunkIndex == chunkIndex) {
        return; // Already have it in one slot or the other -- nothing to do.
    }
    std::uint32_t decodedFrameCount = 0;
    auto decoded = impl.decodeChunk(chunkIndex, impl.prefetchedComponents, decodedFrameCount);
    if (decoded) {
        impl.prefetchedChunkIndex = chunkIndex;
        impl.prefetchedChunkFrameCount = decodedFrameCount;
    }
    // On failure, leave the prefetch slot untouched (still pointing at whatever it held before, or
    // still empty) -- the next readFrame() for this chunk will just decode it the normal way and
    // surface any real error there.
}

std::uint32_t FieldFrameSeriesReader::timestep(std::uint32_t index) const {
    std::lock_guard lock(_impl->mutex);
    return _impl->timesteps.at(index);
}
double FieldFrameSeriesReader::timeSeconds(std::uint32_t index) const {
    std::lock_guard lock(_impl->mutex);
    return _impl->timeSeconds.at(index);
}
float FieldFrameSeriesReader::minEnergy(std::uint32_t index) const {
    std::lock_guard lock(_impl->mutex);
    return _impl->minEnergy.at(index);
}
float FieldFrameSeriesReader::maxEnergy(std::uint32_t index) const {
    std::lock_guard lock(_impl->mutex);
    return _impl->maxEnergy.at(index);
}

FieldComponentRange FieldFrameSeriesReader::componentRange(FieldComponent component, std::uint32_t index) const {
    std::lock_guard lock(_impl->mutex);
    const std::size_t componentIndex = static_cast<std::size_t>(component);
    return {_impl->componentMin.at(componentIndex).at(index), _impl->componentMax.at(componentIndex).at(index)};
}

std::optional<FieldComponentRange> FieldFrameSeriesReader::componentRange(FieldComponent component) const {
    std::lock_guard lock(_impl->mutex);
    return _impl->seriesComponentRange.at(static_cast<std::size_t>(component));
}

} // namespace copper
