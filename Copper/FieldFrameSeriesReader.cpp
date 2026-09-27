#include "FieldFrameSeriesReader.hpp"

#include <algorithm>
#include <array>
#include <bit>
#include <limits>
#include <mutex>
#include <hdf5.h>

#include "Internal/CopperFieldFrameSignposts.hpp"
#include "Internal/CopperHDF5Blosc2.hpp"

namespace copper {

namespace {

constexpr std::array<const char*, 6> kComponentNames = {
    "/frames/Ex_xor", "/frames/Ey_xor", "/frames/Ez_xor",
    "/frames/Hx_xor", "/frames/Hy_xor", "/frames/Hz_xor"};
constexpr std::array<const char*, 6> kComponentMinNames = {
    "/frames/Ex_min", "/frames/Ey_min", "/frames/Ez_min",
    "/frames/Hx_min", "/frames/Hy_min", "/frames/Hz_min"};
constexpr std::array<const char*, 6> kComponentMaxNames = {
    "/frames/Ex_max", "/frames/Ey_max", "/frames/Ez_max",
    "/frames/Hx_max", "/frames/Hy_max", "/frames/Hz_max"};
constexpr std::array<const char*, 6> kPreviewComponentNames = {
    "/preview/Ex_mean", "/preview/Ey_mean", "/preview/Ez_mean",
    "/preview/Hx_mean", "/preview/Hy_mean", "/preview/Hz_mean"};

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
    HId previewEnergy;
    std::array<HId, 6> previewComponent;
    HId refinementOrder;
    HId publishedFrameCountDataset;
    FieldFrameSeriesWriter::Header header;
    FieldFrameSeriesWriter::Header previewHeader;
    std::uint32_t previewFactorX = 1, previewFactorY = 1, previewFactorZ = 1;
    std::uint32_t frameCount = 0;
    std::vector<std::uint32_t> timesteps;
    std::vector<double> timeSeconds;
    std::vector<float> minEnergy;
    std::vector<float> maxEnergy;
    std::array<std::vector<float>, 6> componentMin;
    std::array<std::vector<float>, 6> componentMax;
    std::array<std::optional<FieldComponentRange>, 6> seriesComponentRange;
    mutable std::uint32_t cachedFrameIndex = std::numeric_limits<std::uint32_t>::max();
    mutable std::array<std::vector<float>, 6> cachedComponents;
    // Second, independent slot warmed by prefetchFrame() -- kept separate so a background read of
    // the next frame never evicts the frame still being displayed.
    mutable std::uint32_t prefetchedFrameIndex = std::numeric_limits<std::uint32_t>::max();
    mutable std::array<std::vector<float>, 6> prefetchedComponents;
    mutable std::uint32_t prefetchInFlightFrameIndex = std::numeric_limits<std::uint32_t>::max();
    mutable std::uint64_t cacheGeneration = 0;
    // Guards published metadata and both cache slots. Background prefetch performs its expensive
    // decode into local storage without holding this lock, so a cached foreground read remains
    // available throughout that work.
    mutable std::mutex mutex;
    // HDF5 dataset handles may be touched by refresh(), a foreground cache miss, and background
    // prefetch. Keep those operations serialized independently of the cheap cache bookkeeping.
    mutable std::mutex hdf5Mutex;

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
        if (H5Drefresh(previewEnergy.get()) < 0) {
            return std::unexpected("H5Drefresh failed for /preview/energy_max");
        }
        for (std::size_t index = 0; index < previewComponent.size(); ++index) {
            if (H5Drefresh(previewComponent[index].get()) < 0) {
                return std::unexpected(std::string("H5Drefresh failed for ") + kPreviewComponentNames[index]);
            }
        }
        if (H5Drefresh(refinementOrder.get()) < 0) {
            return std::unexpected("H5Drefresh failed for /preview/refinement_order");
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

    /// Reads one frame's hyperslab from each component dataset. HDF5 still decompresses the
    /// containing on-disk chunk internally, but only this frame is copied into caller-owned memory;
    /// retaining an entire multi-frame chunk here was the source of multi-gigabyte viewer RSS.
    std::expected<void, std::string> decodeFrame(std::uint32_t frameIndex,
                                                  std::uint32_t availableFrameCount,
                                                  std::array<std::vector<float>, 6>& outComponents) const {
        std::lock_guard hdf5Lock(hdf5Mutex);
        const std::size_t cellCount = static_cast<std::size_t>(header.nx) * header.ny * header.nz;
        if (frameIndex >= availableFrameCount) {
            return std::unexpected("Field frame is outside the published range");
        }
        const os_signpost_id_t signpost = os_signpost_id_generate(fieldFrameSignpostLog());
        os_signpost_interval_begin(fieldFrameSignpostLog(), signpost, "Decode field frame",
                                   "frame=%u", frameIndex);
        const auto finishSignpost = [&](bool success) {
            os_signpost_interval_end(fieldFrameSignpostLog(), signpost, "Decode field frame",
                                     "frame=%u success=%d", frameIndex, success ? 1 : 0);
        };
        const hsize_t start4[4] = {frameIndex, 0, 0, 0};
        const hsize_t count4[4] = {1, header.nz, header.ny, header.nx};
        HId memspace(H5Screate_simple(4, count4, nullptr), H5Sclose);
        if (!memspace.valid()) {
            finishSignpost(false);
            return std::unexpected("H5Screate_simple failed while reading a field frame");
        }
        const std::size_t previewCellCount =
            static_cast<std::size_t>(previewHeader.nx) * previewHeader.ny * previewHeader.nz;
        const hsize_t previewStart[4] = {frameIndex, 0, 0, 0};
        const hsize_t previewCount[4] = {1, previewHeader.nz, previewHeader.ny, previewHeader.nx};
        HId previewMemspace(H5Screate_simple(4, previewCount, nullptr), H5Sclose);
        std::vector<std::uint32_t> residual(cellCount);
        for (std::size_t i = 0; i < outComponents.size(); ++i) {
            std::vector<float> baseline(previewCellCount);
            HId previewFilespace(H5Dget_space(previewComponent[i].get()), H5Sclose);
            if (!previewMemspace.valid() || !previewFilespace.valid() ||
                H5Sselect_hyperslab(previewFilespace.get(), H5S_SELECT_SET, previewStart, nullptr,
                                    previewCount, nullptr) < 0 ||
                H5Dread(previewComponent[i].get(), H5T_NATIVE_FLOAT, previewMemspace.get(),
                        previewFilespace.get(), H5P_DEFAULT, baseline.data()) < 0) {
                finishSignpost(false);
                return std::unexpected("H5Dread failed while reading a field-detail baseline");
            }
            outComponents[i].resize(cellCount);
            HId filespace(H5Dget_space(component[i].get()), H5Sclose);
            if (!filespace.valid() ||
                H5Sselect_hyperslab(filespace.get(), H5S_SELECT_SET, start4, nullptr, count4, nullptr) < 0) {
                finishSignpost(false);
                return std::unexpected("H5Sselect_hyperslab failed while reading a field frame");
            }
            if (H5Dread(component[i].get(), H5T_NATIVE_UINT32, memspace.get(), filespace.get(), H5P_DEFAULT,
                        residual.data()) < 0) {
                finishSignpost(false);
                return std::unexpected("H5Dread failed while reading a field frame");
            }
            for (std::uint32_t z = 0; z < header.nz; ++z) {
                for (std::uint32_t y = 0; y < header.ny; ++y) {
                    for (std::uint32_t x = 0; x < header.nx; ++x) {
                        const std::size_t fullIndex = x + static_cast<std::size_t>(header.nx) *
                            (y + static_cast<std::size_t>(header.ny) * z);
                        const std::size_t previewIndex = (x / previewFactorX) +
                            static_cast<std::size_t>(previewHeader.nx) * ((y / previewFactorY) +
                            static_cast<std::size_t>(previewHeader.ny) * (z / previewFactorZ));
                        outComponents[i][fullIndex] = std::bit_cast<float>(
                            residual[fullIndex] ^ std::bit_cast<std::uint32_t>(baseline[previewIndex]));
                    }
                }
            }
        }
        finishSignpost(true);
        return {};
    }

    std::expected<void, std::string> decodePreviewFrame(
        std::uint32_t frameIndex, std::uint32_t availableFrameCount, std::vector<float>& energy,
        std::array<std::vector<float>*, 6> outputs) const {
        std::lock_guard hdf5Lock(hdf5Mutex);
        if (frameIndex >= availableFrameCount) return std::unexpected("Preview frame is outside the published range");
        const std::size_t count = static_cast<std::size_t>(previewHeader.nx) * previewHeader.ny * previewHeader.nz;
        const hsize_t start[4] = {frameIndex, 0, 0, 0};
        const hsize_t dimensions[4] = {1, previewHeader.nz, previewHeader.ny, previewHeader.nx};
        HId memspace(H5Screate_simple(4, dimensions, nullptr), H5Sclose);
        auto read = [&](hid_t dataset, float* values) -> bool {
            HId filespace(H5Dget_space(dataset), H5Sclose);
            return filespace.valid() &&
                H5Sselect_hyperslab(filespace.get(), H5S_SELECT_SET, start, nullptr, dimensions, nullptr) >= 0 &&
                H5Dread(dataset, H5T_NATIVE_FLOAT, memspace.get(), filespace.get(), H5P_DEFAULT, values) >= 0;
        };
        energy.resize(count);
        if (!memspace.valid() || !read(previewEnergy.get(), energy.data())) {
            return std::unexpected("H5Dread failed for /preview/energy_max");
        }
        for (std::size_t i = 0; i < outputs.size(); ++i) {
            outputs[i]->resize(count);
            if (!read(previewComponent[i].get(), outputs[i]->data())) {
                return std::unexpected(std::string("H5Dread failed for ") + kPreviewComponentNames[i]);
            }
        }
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
    if (*formatVersion != 3) {
        return std::unexpected("Obsolete field frame-series format_version " + std::to_string(*formatVersion) +
                               "; rerun the simulation to create format version 3");
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

    auto previewNx = readInt32Attribute(file, "preview_nx");
    auto previewNy = readInt32Attribute(file, "preview_ny");
    auto previewNz = readInt32Attribute(file, "preview_nz");
    auto factorX = readInt32Attribute(file, "preview_factor_x");
    auto factorY = readInt32Attribute(file, "preview_factor_y");
    auto factorZ = readInt32Attribute(file, "preview_factor_z");
    if (!previewNx || !previewNy || !previewNz || !factorX || !factorY || !factorZ) {
        return std::unexpected("Field frame-series preview metadata is incomplete");
    }
    if (*previewNx <= 0 || *previewNy <= 0 || *previewNz <= 0 ||
        *factorX <= 0 || *factorY <= 0 || *factorZ <= 0) {
        return std::unexpected("Field frame-series preview dimensions are invalid");
    }
    if (static_cast<std::uint64_t>(*previewNx) * static_cast<std::uint64_t>(*previewNy) *
            static_cast<std::uint64_t>(*previewNz) > std::numeric_limits<std::uint32_t>::max()) {
        return std::unexpected("Field preview has too many cells for uint32 refinement indices");
    }
    impl->previewHeader = impl->header;
    impl->previewHeader.nx = static_cast<std::uint32_t>(*previewNx);
    impl->previewHeader.ny = static_cast<std::uint32_t>(*previewNy);
    impl->previewHeader.nz = static_cast<std::uint32_t>(*previewNz);
    impl->previewFactorX = static_cast<std::uint32_t>(*factorX);
    impl->previewFactorY = static_cast<std::uint32_t>(*factorY);
    impl->previewFactorZ = static_cast<std::uint32_t>(*factorZ);
    auto reducedLine = [](const std::vector<double>& full, std::uint32_t factor) {
        std::vector<double> reduced;
        reduced.reserve((full.size() + factor - 1) / factor);
        for (std::size_t begin = 0; begin < full.size(); begin += factor) {
            const std::size_t end = std::min(begin + factor, full.size());
            reduced.push_back((full[begin] + full[end - 1]) * 0.5);
        }
        return reduced;
    };
    impl->previewHeader.lineX = reducedLine(impl->header.lineX, static_cast<std::uint32_t>(*factorX));
    impl->previewHeader.lineY = reducedLine(impl->header.lineY, static_cast<std::uint32_t>(*factorY));
    impl->previewHeader.lineZ = reducedLine(impl->header.lineZ, static_cast<std::uint32_t>(*factorZ));

    impl->publishedFrameCountDataset =
        HId(H5Dopen2(file, "/frames/published_frame_count", H5P_DEFAULT), H5Dclose);
    if (!impl->publishedFrameCountDataset.valid() ||
        H5Dread(impl->publishedFrameCountDataset.get(), H5T_NATIVE_UINT32, H5S_ALL, H5S_ALL,
                H5P_DEFAULT, &impl->frameCount) < 0) {
        return std::unexpected("Could not read /frames/published_frame_count");
    }

    // The application's own two-frame cache is the sole retention policy for large decoded data.
    // Disable HDF5's per-dataset raw chunk cache for the six component datasets: their physical
    // chunks contain several frames and allowing each open dataset to retain one would quietly
    // reintroduce many-frame residency beneath our bounded cache.
    HId componentDatasetAccess(H5Pcreate(H5P_DATASET_ACCESS), H5Pclose);
    if (!componentDatasetAccess.valid() ||
        H5Pset_chunk_cache(componentDatasetAccess.get(), 1, 1, 0.0) < 0) {
        return std::unexpected("Could not disable the field component chunk cache");
    }
    for (std::size_t i = 0; i < kComponentNames.size(); ++i) {
        HId dataset(H5Dopen2(file, kComponentNames[i], componentDatasetAccess.get()), H5Dclose);
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

        }
        impl->component[i] = std::move(dataset);
    }
    impl->previewEnergy = HId(H5Dopen2(file, "/preview/energy_max", componentDatasetAccess.get()), H5Dclose);
    if (!impl->previewEnergy.valid()) return std::unexpected("H5Dopen2 failed for /preview/energy_max");
    for (std::size_t i = 0; i < kPreviewComponentNames.size(); ++i) {
        impl->previewComponent[i] =
            HId(H5Dopen2(file, kPreviewComponentNames[i], componentDatasetAccess.get()), H5Dclose);
        if (!impl->previewComponent[i].valid()) {
            return std::unexpected(std::string("H5Dopen2 failed for ") + kPreviewComponentNames[i]);
        }
    }
    impl->refinementOrder =
        HId(H5Dopen2(file, "/preview/refinement_order", componentDatasetAccess.get()), H5Dclose);
    if (!impl->refinementOrder.valid()) {
        return std::unexpected("H5Dopen2 failed for /preview/refinement_order");
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
const FieldFrameSeriesWriter::Header& FieldFrameSeriesReader::previewHeader() const { return _impl->previewHeader; }
std::expected<std::uint32_t, std::string> FieldFrameSeriesReader::refresh() const {
    // Take the HDF5 lock first, without excluding cached reads while waiting for an in-progress
    // prefetch. No other path holds the cache mutex while acquiring hdf5Mutex.
    std::lock_guard hdf5Lock(_impl->hdf5Mutex);
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
    std::array<std::vector<float>*, 6> outputs = {&ex, &ey, &ez, &hx, &hy, &hz};
    std::uint32_t availableFrameCount = 0;

    {
        std::unique_lock lock(impl.mutex);
        if (index >= impl.frameCount) {
            return std::unexpected("FieldFrameSeriesReader::readFrame: index out of range");
        }
        availableFrameCount = impl.frameCount;
        if (impl.cachedFrameIndex != index && impl.prefetchedFrameIndex == index) {
            // Already warmed by a prior prefetchFrame() call -- promote it rather than decoding.
            impl.cachedComponents = std::move(impl.prefetchedComponents);
            impl.cachedFrameIndex = index;
            impl.prefetchedFrameIndex = std::numeric_limits<std::uint32_t>::max();
        }
        if (impl.cachedFrameIndex == index) {
            for (std::size_t i = 0; i < outputs.size(); ++i) {
                *outputs[i] = impl.cachedComponents[i];
            }
            return {};
        }
    }

    // Decode outside the cache lock so the current frame remains available while HDF5 serves a miss.
    std::array<std::vector<float>, 6> decodedComponents;
    auto decoded = impl.decodeFrame(index, availableFrameCount, decodedComponents);
    if (!decoded) {
        return std::unexpected(decoded.error());
    }

    std::lock_guard lock(impl.mutex);
    impl.cachedComponents = std::move(decodedComponents);
    impl.cachedFrameIndex = index;
    for (std::size_t i = 0; i < outputs.size(); ++i) {
        *outputs[i] = impl.cachedComponents[i];
    }
    return {};
}

std::expected<void, std::string> FieldFrameSeriesReader::readPreviewFrame(
    std::uint32_t index, std::vector<float>& energy, std::vector<float>& ex, std::vector<float>& ey,
    std::vector<float>& ez, std::vector<float>& hx, std::vector<float>& hy, std::vector<float>& hz) const {
    std::uint32_t availableFrameCount = 0;
    {
        std::lock_guard lock(_impl->mutex);
        if (index >= _impl->frameCount) {
            return std::unexpected("FieldFrameSeriesReader::readPreviewFrame: index out of range");
        }
        availableFrameCount = _impl->frameCount;
    }
    return _impl->decodePreviewFrame(index, availableFrameCount, energy, {&ex, &ey, &ez, &hx, &hy, &hz});
}

std::expected<std::vector<std::uint32_t>, std::string>
FieldFrameSeriesReader::readRefinementOrder(std::uint32_t frameIndex) const {
    Impl& impl = *_impl;
    {
        std::lock_guard lock(impl.mutex);
        if (frameIndex >= impl.frameCount) {
            return std::unexpected("Field refinement-order frame is out of range");
        }
    }
    const std::size_t previewCellCount =
        static_cast<std::size_t>(impl.previewHeader.nx) * impl.previewHeader.ny * impl.previewHeader.nz;
    std::vector<std::uint32_t> order(previewCellCount);
    const hsize_t start[2] = {frameIndex, 0};
    const hsize_t count[2] = {1, previewCellCount};
    HId memspace(H5Screate_simple(2, count, nullptr), H5Sclose);
    std::lock_guard hdf5Lock(impl.hdf5Mutex);
    HId filespace(H5Dget_space(impl.refinementOrder.get()), H5Sclose);
    if (!filespace.valid() || !memspace.valid() ||
        H5Sselect_hyperslab(filespace.get(), H5S_SELECT_SET, start, nullptr, count, nullptr) < 0 ||
        H5Dread(impl.refinementOrder.get(), H5T_NATIVE_UINT32, memspace.get(), filespace.get(),
                H5P_DEFAULT, order.data()) < 0) {
        return std::unexpected("Could not read /preview/refinement_order");
    }
    std::vector<bool> seen(previewCellCount, false);
    for (const std::uint32_t cell : order) {
        if (cell >= previewCellCount || seen[cell]) {
            return std::unexpected("Field refinement order is not a valid preview-cell permutation");
        }
        seen[cell] = true;
    }
    return order;
}

std::expected<void, std::string> FieldFrameSeriesReader::readPreviewCellDetail(
    std::uint32_t frameIndex, std::uint32_t previewCellIndex,
    std::vector<float>& ex, std::vector<float>& ey, std::vector<float>& ez,
    std::vector<float>& hx, std::vector<float>& hy, std::vector<float>& hz) const {
    const Impl& impl = *_impl;
    const std::uint64_t previewCellCount =
        static_cast<std::uint64_t>(impl.previewHeader.nx) * impl.previewHeader.ny * impl.previewHeader.nz;
    if (previewCellIndex >= previewCellCount) {
        return std::unexpected("Preview-cell detail index is outside the grid");
    }
    const std::uint32_t previewX = previewCellIndex % impl.previewHeader.nx;
    const std::uint32_t previewYZ = previewCellIndex / impl.previewHeader.nx;
    const std::uint32_t previewY = previewYZ % impl.previewHeader.ny;
    const std::uint32_t previewZ = previewYZ / impl.previewHeader.ny;
    const std::uint32_t x = previewX * impl.previewFactorX;
    const std::uint32_t y = previewY * impl.previewFactorY;
    const std::uint32_t z = previewZ * impl.previewFactorZ;
    return readRegion(frameIndex, x, y, z,
                      std::min(impl.previewFactorX, impl.header.nx - x),
                      std::min(impl.previewFactorY, impl.header.ny - y),
                      std::min(impl.previewFactorZ, impl.header.nz - z),
                      ex, ey, ez, hx, hy, hz);
}

std::expected<void, std::string> FieldFrameSeriesReader::readRegion(
    std::uint32_t frameIndex, std::uint32_t x, std::uint32_t y, std::uint32_t z,
    std::uint32_t nx, std::uint32_t ny, std::uint32_t nz, std::vector<float>& ex,
    std::vector<float>& ey, std::vector<float>& ez, std::vector<float>& hx,
    std::vector<float>& hy, std::vector<float>& hz) const {
    Impl& impl = *_impl;
    {
        std::lock_guard lock(impl.mutex);
        if (frameIndex >= impl.frameCount) return std::unexpected("Field detail frame is out of range");
    }
    if (nx == 0 || ny == 0 || nz == 0 || x > impl.header.nx || y > impl.header.ny || z > impl.header.nz ||
        nx > impl.header.nx - x || ny > impl.header.ny - y || nz > impl.header.nz - z) {
        return std::unexpected("Field detail region is empty or outside the grid");
    }
    const std::size_t cellCount = static_cast<std::size_t>(nx) * ny * nz;
    const hsize_t start[4] = {frameIndex, z, y, x};
    const hsize_t count[4] = {1, nz, ny, nx};
    HId memspace(H5Screate_simple(4, count, nullptr), H5Sclose);
    if (!memspace.valid()) return std::unexpected("Could not create field detail memory space");
    std::array<std::vector<float>*, 6> outputs = {&ex, &ey, &ez, &hx, &hy, &hz};
    std::lock_guard hdf5Lock(impl.hdf5Mutex);
    const std::uint32_t previewX = x / impl.previewFactorX;
    const std::uint32_t previewY = y / impl.previewFactorY;
    const std::uint32_t previewZ = z / impl.previewFactorZ;
    const std::uint32_t previewNx = (x + nx - 1) / impl.previewFactorX - previewX + 1;
    const std::uint32_t previewNy = (y + ny - 1) / impl.previewFactorY - previewY + 1;
    const std::uint32_t previewNz = (z + nz - 1) / impl.previewFactorZ - previewZ + 1;
    const std::size_t previewCellCount =
        static_cast<std::size_t>(previewNx) * previewNy * previewNz;
    const hsize_t previewStart[4] = {frameIndex, previewZ, previewY, previewX};
    const hsize_t previewCount[4] = {1, previewNz, previewNy, previewNx};
    HId previewMemspace(H5Screate_simple(4, previewCount, nullptr), H5Sclose);
    std::vector<std::uint32_t> residual(cellCount);
    for (std::size_t i = 0; i < outputs.size(); ++i) {
        std::vector<float> baseline(previewCellCount);
        HId previewFilespace(H5Dget_space(impl.previewComponent[i].get()), H5Sclose);
        if (!previewMemspace.valid() || !previewFilespace.valid() ||
            H5Sselect_hyperslab(previewFilespace.get(), H5S_SELECT_SET, previewStart, nullptr,
                                previewCount, nullptr) < 0 ||
            H5Dread(impl.previewComponent[i].get(), H5T_NATIVE_FLOAT, previewMemspace.get(),
                    previewFilespace.get(), H5P_DEFAULT, baseline.data()) < 0) {
            return std::unexpected("Could not read field detail baseline");
        }
        outputs[i]->resize(cellCount);
        HId filespace(H5Dget_space(impl.component[i].get()), H5Sclose);
        if (!filespace.valid() ||
            H5Sselect_hyperslab(filespace.get(), H5S_SELECT_SET, start, nullptr, count, nullptr) < 0 ||
            H5Dread(impl.component[i].get(), H5T_NATIVE_UINT32, memspace.get(), filespace.get(),
                    H5P_DEFAULT, residual.data()) < 0) {
            return std::unexpected(std::string("Could not read field detail region from ") + kComponentNames[i]);
        }
        for (std::uint32_t localZ = 0; localZ < nz; ++localZ) {
            for (std::uint32_t localY = 0; localY < ny; ++localY) {
                for (std::uint32_t localX = 0; localX < nx; ++localX) {
                    const std::uint32_t globalX = x + localX;
                    const std::uint32_t globalY = y + localY;
                    const std::uint32_t globalZ = z + localZ;
                    const std::size_t localIndex = localX + static_cast<std::size_t>(nx) *
                        (localY + static_cast<std::size_t>(ny) * localZ);
                    const std::size_t previewIndex = (globalX / impl.previewFactorX - previewX) +
                        static_cast<std::size_t>(previewNx) *
                        ((globalY / impl.previewFactorY - previewY) + static_cast<std::size_t>(previewNy) *
                         (globalZ / impl.previewFactorZ - previewZ));
                    (*outputs[i])[localIndex] = std::bit_cast<float>(
                        residual[localIndex] ^ std::bit_cast<std::uint32_t>(baseline[previewIndex]));
                }
            }
        }
    }
    return {};
}

void FieldFrameSeriesReader::prefetchFrame(std::uint32_t index) const {
    Impl& impl = *_impl;
    std::uint32_t availableFrameCount = 0;
    std::uint64_t cacheGeneration = 0;
    {
        std::lock_guard lock(impl.mutex);
        if (index >= impl.frameCount) {
            return;
        }
        if (impl.cachedFrameIndex == index || impl.prefetchedFrameIndex == index ||
            impl.prefetchInFlightFrameIndex != std::numeric_limits<std::uint32_t>::max()) {
            return; // Already have it, or the one background decode slot is currently occupied.
        }
        impl.prefetchInFlightFrameIndex = index;
        availableFrameCount = impl.frameCount;
        cacheGeneration = impl.cacheGeneration;
    }

    // Decode locally while leaving the cache mutex available to foreground reads. decodeFrame()
    // separately serializes access to the shared HDF5 handles.
    std::array<std::vector<float>, 6> decodedComponents;
    auto decoded = impl.decodeFrame(index, availableFrameCount, decodedComponents);

    std::lock_guard lock(impl.mutex);
    if (impl.prefetchInFlightFrameIndex == index) {
        impl.prefetchInFlightFrameIndex = std::numeric_limits<std::uint32_t>::max();
    }
    if (decoded && cacheGeneration == impl.cacheGeneration && impl.cachedFrameIndex != index &&
        impl.prefetchedFrameIndex != index) {
        impl.prefetchedComponents = std::move(decodedComponents);
        impl.prefetchedFrameIndex = index;
    }
    // On failure, leave the prefetch slot untouched (still pointing at whatever it held before, or
    // still empty) -- the next readFrame() for this frame will decode it normally and
    // surface any real error there.
}

void FieldFrameSeriesReader::clearFrameCache() const {
    Impl& impl = *_impl;
    std::lock_guard lock(impl.mutex);
    ++impl.cacheGeneration;
    impl.cachedFrameIndex = std::numeric_limits<std::uint32_t>::max();
    impl.prefetchedFrameIndex = std::numeric_limits<std::uint32_t>::max();
    // Swap with empty vectors rather than clear(): capacity is the expensive part and would
    // otherwise keep the full frame allocations resident after leaving/switching the viewer.
    for (std::vector<float>& component : impl.cachedComponents) {
        std::vector<float>().swap(component);
    }
    for (std::vector<float>& component : impl.prefetchedComponents) {
        std::vector<float>().swap(component);
    }
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
