// Streaming decoder for the field frame-series format -- see docs/field_frame_series_format.md and
// FieldFrameSeriesWriter.hpp's own file comment for the format/PIMPL rationale this mirrors.
#pragma once

#include <array>
#include <cstdint>
#include <filesystem>
#include <memory>
#include <optional>
#include <string>
#include <vector>

#include "FieldFrameSeriesWriter.hpp"
// FieldFrameSeriesWriter.hpp already pulls in <expected> (for std::expected<T, std::string>, used
// throughout this header too).

namespace copper {

enum class FieldComponent : std::uint8_t { Ex, Ey, Ez, Hx, Hy, Hz };

struct FieldComponentRange {
    float minimum = 0.0F;
    float maximum = 0.0F;

    bool operator==(const FieldComponentRange&) const = default;
};

struct FieldPreviewCellDetail {
    std::uint32_t previewCellIndex = 0;
    std::uint32_t nx = 0, ny = 0, nz = 0;
    std::array<std::vector<float>, 6> components;
};

/// Reads a field frame-series file written by FieldFrameSeriesWriter. Opens once; header() and
/// every scalar per-frame metadata array (timestep/time/energy and component ranges) is read eagerly
/// at open() time. Refinement permutations and field samples remain on disk: readFrame() reads and retains only
/// the requested frame, even when the file's compression chunk contains several frames.
///
/// readFrame() and prefetchFrame() are safe to call concurrently from different threads. Background
/// prefetch decodes one frame into an independent slot without holding the cache lock, so cached
/// playback can continue while the next frame is read and decompressed. HDF5 access remains
/// serialized separately. Resident decoded field data is therefore bounded to two frames.
class FieldFrameSeriesReader {
public:
    static std::expected<FieldFrameSeriesReader, std::string> open(const std::filesystem::path& path);

    FieldFrameSeriesReader(FieldFrameSeriesReader&&) noexcept;
    FieldFrameSeriesReader& operator=(FieldFrameSeriesReader&&) noexcept;
    FieldFrameSeriesReader(const FieldFrameSeriesReader&) = delete;
    FieldFrameSeriesReader& operator=(const FieldFrameSeriesReader&) = delete;
    ~FieldFrameSeriesReader();

    const FieldFrameSeriesWriter::Header& header() const;
    /// Downsampled grid used for normal playback. X/Y are reduced by 16 and Z by 2 (ceil at
    /// boundaries); its coordinates are the centres of the represented full-resolution spans.
    const FieldFrameSeriesWriter::Header& previewHeader() const;
    std::uint32_t previewFactorX() const;
    std::uint32_t previewFactorY() const;
    std::uint32_t previewFactorZ() const;
    /// Refreshes this SWMR reader and returns the number of complete frames the writer has
    /// published. A completed 16-frame block becomes visible atomically; the final partial block
    /// becomes visible when the writer closes it.
    std::expected<std::uint32_t, std::string> refresh() const;
    std::uint32_t frameCount() const;

    /// Fills every one of the six caller-provided buffers (resized as needed) with frame `index`'s
    /// own `nx*ny*nz` values, x-fastest-varying -- same convention as FieldFrameSeriesWriter::
    /// writeFrame()'s own inputs. Returns an error if `index >= frameCount()`.
    std::expected<void, std::string> readFrame(std::uint32_t index, std::vector<float>& ex, std::vector<float>& ey,
                                                 std::vector<float>& ez, std::vector<float>& hx,
                                                 std::vector<float>& hy, std::vector<float>& hz) const;

    /// Reads the small playback representation. `energy` is max pooled (preserves narrow peaks),
    /// while the six signed fields are block means (supports approximate differential combining).
    std::expected<void, std::string> readPreviewFrame(std::uint32_t index, std::vector<float>& energy,
                                                        std::vector<float>& ex, std::vector<float>& ey,
                                                        std::vector<float>& ez, std::vector<float>& hx,
                                                        std::vector<float>& hy, std::vector<float>& hz) const;

    /// Returns every x-fastest linear preview-cell index, ordered from greatest to least detail
    /// lost by the preview representation. A time-budgeted decoder reads the preview first, then
    /// walks this list and calls readPreviewCellDetail() until its deadline. Ties are stable by
    /// ascending cell index, so files are deterministic.
    std::expected<std::vector<std::uint32_t>, std::string>
    readRefinementOrder(std::uint32_t frameIndex) const;

    /// Reads the full-resolution block represented by one preview cell. Detail chunks are aligned
    /// one-to-one with these 16x16x2 blocks (smaller at grid edges), so each call independently
    /// decompresses exactly the next refinement unit selected from readRefinementOrder().
    std::expected<void, std::string> readPreviewCellDetail(
        std::uint32_t frameIndex, std::uint32_t previewCellIndex,
        std::vector<float>& ex, std::vector<float>& ey, std::vector<float>& ez,
        std::vector<float>& hx, std::vector<float>& hy, std::vector<float>& hz) const;

    /// Reads compressed payloads for several independent preview-cell tiles while holding the
    /// HDF5 lock, then decompresses and reconstructs those tiles concurrently after releasing it.
    /// Results retain `previewCellIndices` order.
    std::expected<std::vector<FieldPreviewCellDetail>, std::string> readPreviewCellDetails(
        std::uint32_t frameIndex, const std::vector<std::uint32_t>& previewCellIndices) const;

    /// Reads only a full-resolution cuboid. HDF5 touches the independently compressed 16x16x2
    /// chunks intersecting this region, providing the bounded detail path a zoomed viewer needs.
    std::expected<void, std::string> readRegion(std::uint32_t frameIndex,
                                                  std::uint32_t x, std::uint32_t y, std::uint32_t z,
                                                  std::uint32_t nx, std::uint32_t ny, std::uint32_t nz,
                                                  std::vector<float>& ex, std::vector<float>& ey,
                                                  std::vector<float>& ez, std::vector<float>& hx,
                                                  std::vector<float>& hy, std::vector<float>& hz) const;

    /// Decodes `index` into a second, independent cache slot that doesn't disturb the frame
    /// readFrame() is currently serving -- lets a caller warm the next playback frame on a background
    /// queue without evicting the current one. The next readFrame() call for that frame promotes it
    /// at no extra decode cost. A no-op if `index` is out of range, already cached/prefetched, or a
    /// prefetch is already in flight. Errors are swallowed -- a failed prefetch means the next
    /// readFrame() for that frame falls back to its own normal decode,
    /// which will surface any real error there instead.
    void prefetchFrame(std::uint32_t index) const;

    /// Releases both decoded-frame cache slots. An in-flight prefetch may finish its disk read, but
    /// is prevented from repopulating the cache after this call. Metadata and the open SWMR reader
    /// remain available, so a later read resumes normally without reopening the series.
    void clearFrameCache() const;

    std::uint32_t timestep(std::uint32_t index) const;
    double timeSeconds(std::uint32_t index) const;
    float minEnergy(std::uint32_t index) const;
    float maxEnergy(std::uint32_t index) const;

    /// Signed extrema for one component in one frame. The overload without a frame index returns
    /// the aggregate range across the whole series, allowing stable playback normalization without
    /// reading any field-data chunk; it is nullopt only when the series contains no frames.
    FieldComponentRange componentRange(FieldComponent component, std::uint32_t index) const;
    std::optional<FieldComponentRange> componentRange(FieldComponent component) const;

private:
    struct Impl;
    explicit FieldFrameSeriesReader(std::unique_ptr<Impl> impl);
    std::unique_ptr<Impl> _impl;
};

} // namespace copper
