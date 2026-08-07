// Minimal PNG read/write/crop helpers built on libpng, standing in for the PIL usage in
// importer.py (PIL isn't available in C++; libpng is a small, already-installed dependency).
#pragma once

#include <cstdint>
#include <filesystem>
#include <utility>
#include <vector>

namespace gerber2ems {

/// An 8-bit-per-channel RGBA image, row-major, top-to-bottom (matching PIL/libpng's convention).
struct RgbaImage {
    std::int32_t width = 0;
    std::int32_t height = 0;
    std::vector<std::uint8_t> pixels; // size == width * height * 4

    std::uint8_t red(std::int32_t x, std::int32_t y) const { return at(x, y, 0); }
    std::uint8_t green(std::int32_t x, std::int32_t y) const { return at(x, y, 1); }
    std::uint8_t blue(std::int32_t x, std::int32_t y) const { return at(x, y, 2); }
    std::uint8_t alpha(std::int32_t x, std::int32_t y) const { return at(x, y, 3); }

    /// ITU-R 601-2 luma transform, matching PIL's default RGB -> "L" (grayscale) conversion.
    std::uint8_t gray(std::int32_t x, std::int32_t y) const {
        const double value = 0.299 * red(x, y) + 0.587 * green(x, y) + 0.114 * blue(x, y);
        return static_cast<std::uint8_t>(value);
    }

private:
    std::uint8_t at(std::int32_t x, std::int32_t y, std::int32_t channel) const {
        return pixels[(static_cast<std::size_t>(y) * static_cast<std::size_t>(width) + static_cast<std::size_t>(x)) *
                          4 +
                      static_cast<std::size_t>(channel)];
    }
};

/// Reads just the width/height of a PNG file without decoding pixel data (matching PIL's lazy
/// Image.open(), where .size doesn't force a full decode).
std::pair<std::int32_t, std::int32_t> readPngSize(const std::filesystem::path& path);

/// Fully decodes a PNG file to RGBA.
RgbaImage readPng(const std::filesystem::path& path);

/// Writes an RGBA image to a PNG file.
void writePng(const std::filesystem::path& path, const RgbaImage& image);

/// Returns the sub-rectangle [x0,y0) to [x1,y1) of `image` (matching PIL's Image.crop box semantics).
RgbaImage cropImage(const RgbaImage& image, std::int32_t x0, std::int32_t y0, std::int32_t x1, std::int32_t y1);

} // namespace gerber2ems
