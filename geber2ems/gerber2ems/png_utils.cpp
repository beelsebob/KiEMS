#include "png_utils.hpp"

#include <algorithm>
#include <csetjmp>
#include <cstdio>
#include <stdexcept>

#include <png.h>

namespace gerber2ems {

namespace {

struct _FileGuard {
    explicit _FileGuard(FILE* file) : file(file) {}
    ~_FileGuard() {
        if (file != nullptr) {
            std::fclose(file);
        }
    }
    FILE* file;
};

// Applies the standard libpng transforms needed to always end up with 8-bit RGBA, regardless of
// the source PNG's colour type/bit depth.
void _normalizeToRgba8(png_structp png, png_infop info) {
    const png_byte colorType = png_get_color_type(png, info);
    const png_byte bitDepth = png_get_bit_depth(png, info);

    if (bitDepth == 16) {
        png_set_strip_16(png);
    }
    if (colorType == PNG_COLOR_TYPE_PALETTE) {
        png_set_palette_to_rgb(png);
    }
    if (colorType == PNG_COLOR_TYPE_GRAY && bitDepth < 8) {
        png_set_expand_gray_1_2_4_to_8(png);
    }
    if (png_get_valid(png, info, PNG_INFO_tRNS) != 0) {
        png_set_tRNS_to_alpha(png);
    }
    if (colorType == PNG_COLOR_TYPE_GRAY || colorType == PNG_COLOR_TYPE_GRAY_ALPHA) {
        png_set_gray_to_rgb(png);
    }
    if (colorType == PNG_COLOR_TYPE_RGB || colorType == PNG_COLOR_TYPE_GRAY ||
        colorType == PNG_COLOR_TYPE_PALETTE) {
        png_set_filler(png, 0xFF, PNG_FILLER_AFTER);
    }
}

} // namespace

std::pair<std::int32_t, std::int32_t> readPngSize(const std::filesystem::path& path) {
    FILE* fp = std::fopen(path.c_str(), "rb");
    if (fp == nullptr) {
        throw std::runtime_error("Failed to open PNG: " + path.string());
    }
    const _FileGuard guard(fp);

    png_structp png = png_create_read_struct(PNG_LIBPNG_VER_STRING, nullptr, nullptr, nullptr);
    png_infop info = png_create_info_struct(png);
    if (setjmp(png_jmpbuf(png)) != 0) {
        png_destroy_read_struct(&png, &info, nullptr);
        throw std::runtime_error("Failed to read PNG header: " + path.string());
    }
    png_init_io(png, fp);
    png_read_info(png, info);
    const auto width = static_cast<std::int32_t>(png_get_image_width(png, info));
    const auto height = static_cast<std::int32_t>(png_get_image_height(png, info));
    png_destroy_read_struct(&png, &info, nullptr);
    return {width, height};
}

RgbaImage readPng(const std::filesystem::path& path) {
    FILE* fp = std::fopen(path.c_str(), "rb");
    if (fp == nullptr) {
        throw std::runtime_error("Failed to open PNG: " + path.string());
    }
    const _FileGuard guard(fp);

    png_structp png = png_create_read_struct(PNG_LIBPNG_VER_STRING, nullptr, nullptr, nullptr);
    png_infop info = png_create_info_struct(png);
    if (setjmp(png_jmpbuf(png)) != 0) {
        png_destroy_read_struct(&png, &info, nullptr);
        throw std::runtime_error("Failed to read PNG: " + path.string());
    }
    png_init_io(png, fp);
    png_read_info(png, info);

    _normalizeToRgba8(png, info);
    png_read_update_info(png, info);

    RgbaImage image;
    image.width = static_cast<std::int32_t>(png_get_image_width(png, info));
    image.height = static_cast<std::int32_t>(png_get_image_height(png, info));
    image.pixels.resize(static_cast<std::size_t>(image.width) * static_cast<std::size_t>(image.height) * 4);

    std::vector<png_bytep> rowPointers(static_cast<std::size_t>(image.height));
    for (std::int32_t y = 0; y < image.height; ++y) {
        rowPointers[static_cast<std::size_t>(y)] =
            image.pixels.data() + static_cast<std::size_t>(y) * static_cast<std::size_t>(image.width) * 4;
    }
    png_read_image(png, rowPointers.data());
    png_destroy_read_struct(&png, &info, nullptr);
    return image;
}

void writePng(const std::filesystem::path& path, const RgbaImage& image) {
    FILE* fp = std::fopen(path.c_str(), "wb");
    if (fp == nullptr) {
        throw std::runtime_error("Failed to open PNG for writing: " + path.string());
    }
    const _FileGuard guard(fp);

    png_structp png = png_create_write_struct(PNG_LIBPNG_VER_STRING, nullptr, nullptr, nullptr);
    png_infop info = png_create_info_struct(png);
    if (setjmp(png_jmpbuf(png)) != 0) {
        png_destroy_write_struct(&png, &info);
        throw std::runtime_error("Failed to write PNG: " + path.string());
    }
    png_init_io(png, fp);
    png_set_IHDR(png, info, static_cast<png_uint_32>(image.width), static_cast<png_uint_32>(image.height), 8,
                 PNG_COLOR_TYPE_RGBA, PNG_INTERLACE_NONE, PNG_COMPRESSION_TYPE_DEFAULT, PNG_FILTER_TYPE_DEFAULT);
    png_write_info(png, info);

    std::vector<png_bytep> rowPointers(static_cast<std::size_t>(image.height));
    for (std::int32_t y = 0; y < image.height; ++y) {
        rowPointers[static_cast<std::size_t>(y)] = const_cast<png_bytep>(
            image.pixels.data() + static_cast<std::size_t>(y) * static_cast<std::size_t>(image.width) * 4);
    }
    png_write_image(png, rowPointers.data());
    png_write_end(png, nullptr);
    png_destroy_write_struct(&png, &info);
}

RgbaImage cropImage(const RgbaImage& image, std::int32_t x0, std::int32_t y0, std::int32_t x1, std::int32_t y1) {
    RgbaImage result;
    result.width = x1 - x0;
    result.height = y1 - y0;
    result.pixels.resize(static_cast<std::size_t>(result.width) * static_cast<std::size_t>(result.height) * 4);
    for (std::int32_t y = 0; y < result.height; ++y) {
        const std::uint8_t* srcRow =
            image.pixels.data() +
            (static_cast<std::size_t>(y + y0) * static_cast<std::size_t>(image.width) + static_cast<std::size_t>(x0)) *
                4;
        std::uint8_t* dstRow = result.pixels.data() + static_cast<std::size_t>(y) *
                                                            static_cast<std::size_t>(result.width) * 4;
        std::copy(srcRow, srcRow + static_cast<std::size_t>(result.width) * 4, dstRow);
    }
    return result;
}

} // namespace gerber2ems
