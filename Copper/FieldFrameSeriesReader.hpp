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

/// Reads a field frame-series file written by FieldFrameSeriesWriter. Opens once; header() and
/// every per-frame metadata array (timestep/time/energy and component ranges -- 68 bytes per frame)
/// are read eagerly at open() time. readFrame() maps the requested frame to its
/// HDF5 chunk, caches that one chunk, and copies the frame from it; adjacent playback frames incur
/// no further HDF5 reads until playback crosses a chunk boundary.
///
/// readFrame() and prefetchFrame() are safe to call concurrently from different threads (internally
/// serialized) -- intended usage is readFrame() from a UI/playback thread while prefetchFrame() warms
/// the next chunk from a background queue, so crossing a chunk boundary during playback doesn't stall
/// waiting on disk I/O + decompression.
class FieldFrameSeriesReader {
public:
    static std::expected<FieldFrameSeriesReader, std::string> open(const std::filesystem::path& path);

    FieldFrameSeriesReader(FieldFrameSeriesReader&&) noexcept;
    FieldFrameSeriesReader& operator=(FieldFrameSeriesReader&&) noexcept;
    FieldFrameSeriesReader(const FieldFrameSeriesReader&) = delete;
    FieldFrameSeriesReader& operator=(const FieldFrameSeriesReader&) = delete;
    ~FieldFrameSeriesReader();

    const FieldFrameSeriesWriter::Header& header() const;
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

    /// Decodes the chunk containing `index` into a second, independent cache slot that doesn't
    /// disturb whatever chunk readFrame() is currently serving from -- lets a caller warm the chunk
    /// playback is about to cross into ahead of time (e.g. from a background queue) without evicting
    /// the chunk still needed for in-progress playback. The next readFrame() call that needs this
    /// chunk picks it up from the prefetch slot at no extra decode cost. A no-op if `index` is out of
    /// range, or already the primary or prefetch slot's own chunk. Errors are swallowed -- a failed
    /// prefetch just means the next readFrame() for that chunk falls back to its own normal decode,
    /// which will surface any real error there instead.
    void prefetchFrame(std::uint32_t index) const;

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
