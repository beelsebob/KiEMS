// Streaming encoder for the field frame-series format -- see docs/field_frame_series_format.md for
// the full on-disk schema this writes. Public (not Internal/) because both this framework's own
// CopperFDTDRunner.cpp (the producer) and KiEMS (the eventual consumer, which already
// links Copper.framework) need it -- see this repo's own implementation plan for why a whole new
// Xcode target wasn't worth the risk just to share this one file pair.
//
// Deliberately PIMPL'd: every HDF5 type (`hid_t` and friends) stays inside FieldFrameSeriesWriter.cpp
// -- nothing here requires `<hdf5.h>` to be on a caller's own header search path, only to be linked
// at the framework level (which Copper's own build now does; see project.pbxproj's Copper target).
#pragma once

#include <cstdint>
#include <expected>
#include <filesystem>
#include <memory>
#include <string>
#include <vector>

namespace copper {

/// Writes one field frame-series file (one per simulation name + excited port -- see the format
/// doc's own "File identity" section). Every `writeFrame()` call extends the file's six big
/// component datasets by exactly one frame; there is no separate "flush"/"finish" step beyond
/// close() (also run, best-effort, from the destructor) -- see the format doc's own "Streaming
/// write / durability" section for why every `chunkFrames`-th frame already triggers an internal
/// H5Fflush.
class FieldFrameSeriesWriter {
public:
    /// Everything the format's root attributes / `/grid` datasets need -- see the format doc's own
    /// schema table. `lineX`/`lineY`/`lineZ` must have exactly `nx`/`ny`/`nz` entries respectively
    /// (E-field *sample* positions, not `nx+1` cell boundaries -- see the format doc's own
    /// "conventions this format deliberately does NOT get wrong" section), in meters.
    struct Header {
        std::string simulationName;
        std::int32_t excitedPort = 0;
        std::uint32_t nx = 0;
        std::uint32_t ny = 0;
        std::uint32_t nz = 0;
        double timestepSeconds = 0.0;
        double boardZMin = 0.0;
        double boardZMax = 0.0;
        std::vector<double> lineX;
        std::vector<double> lineY;
        std::vector<double> lineZ;
    };

    /// Creates (truncating any existing file at `path`) and writes the static header/grid content
    /// immediately -- everything up to `/frames/*` existing with zero frames. `chunkFrames` is both
    /// the compression and the read/seek granularity for the six big per-frame datasets -- see the
    /// format doc's own "Chunking / compression rationale" section.
    static std::expected<FieldFrameSeriesWriter, std::string> create(const std::filesystem::path& path,
                                                                        const Header& header,
                                                                        std::uint32_t chunkFrames = 16);

    FieldFrameSeriesWriter(FieldFrameSeriesWriter&&) noexcept;
    FieldFrameSeriesWriter& operator=(FieldFrameSeriesWriter&&) noexcept;
    FieldFrameSeriesWriter(const FieldFrameSeriesWriter&) = delete;
    FieldFrameSeriesWriter& operator=(const FieldFrameSeriesWriter&) = delete;
    ~FieldFrameSeriesWriter();

    /// Appends one frame -- each of `ex`/`ey`/`ez`/`hx`/`hy`/`hz` must have exactly `nx*ny*nz`
    /// entries, x-fastest-varying (matching CopperFieldFrame's own existing convention), in the
    /// same order `CopperEngine::readField()` already returns them in -- no reordering needed at
    /// the call site.
    std::expected<void, std::string> writeFrame(std::uint32_t timestep, double timeSeconds,
                                                  const std::vector<float>& ex, const std::vector<float>& ey,
                                                  const std::vector<float>& ez, const std::vector<float>& hx,
                                                  const std::vector<float>& hy, const std::vector<float>& hz);

    /// Flushes and closes the file. Safe to call more than once (a no-op after the first). Also run,
    /// best-effort (errors swallowed -- a destructor can't report them), from the destructor, so a
    /// caller that only cares about the common case doesn't have to remember this step.
    std::expected<void, std::string> close();

private:
    struct Impl;
    explicit FieldFrameSeriesWriter(std::unique_ptr<Impl> impl);
    std::unique_ptr<Impl> _impl;
};

} // namespace copper
