// Round-trip tests for the field frame-series encoder/decoder (FieldFrameSeriesWriter/Reader) --
// see docs/field_frame_series_format.md for the on-disk schema. A small synthetic grid (12 cells)
// and 17 frames with chunkFrames=16 exercises both a full chunk (0-15) and a trailing partial chunk
// (16 alone), the two cases the writer's H5Dset_extent/hyperslab logic actually needs to get right.
#import <XCTest/XCTest.h>

#include <array>
#include <algorithm>
#include <filesystem>
#include <thread>
#include <vector>

#include "FieldFrameSeriesReader.hpp"
#include "FieldFrameSeriesWriter.hpp"

namespace {

constexpr std::uint32_t kNx = 3, kNy = 2, kNz = 2;
constexpr std::size_t kCellCount = kNx * kNy * kNz;
constexpr std::uint32_t kFrameCount = 17;

copper::FieldFrameSeriesWriter::Header makeHeader() {
    copper::FieldFrameSeriesWriter::Header header;
    header.simulationName = "CopperTestsFieldFrames";
    header.excitedPort = 2;
    header.nx = kNx;
    header.ny = kNy;
    header.nz = kNz;
    header.timestepSeconds = 1.5e-12;
    header.boardZMin = -0.001;
    header.boardZMax = 0.0;
    for (std::uint32_t i = 0; i < kNx; ++i) header.lineX.push_back(static_cast<double>(i) * 1e-4);
    for (std::uint32_t i = 0; i < kNy; ++i) header.lineY.push_back(static_cast<double>(i) * 2e-4);
    for (std::uint32_t i = 0; i < kNz; ++i) header.lineZ.push_back(static_cast<double>(i) * 3e-4);
    header.domainXYClass.assign(static_cast<std::size_t>(kNx) * kNy, 1);
    header.domainXYClass.front() = 0;
    return header;
}

/// frame f, component c (0..5, Ex..Hz order), cell i -> a value unique per (f, c, i) triple, so any
/// read-back mismatch anywhere is immediately distinguishable from any other. The negative offset
/// exercises signed component ranges too.
float valueFor(std::uint32_t f, int c, std::size_t i) {
    return static_cast<float>(f) * 1000.0F + static_cast<float>(c) * 100.0F + static_cast<float>(i) - 250.0F;
}

std::vector<float> makeComponent(std::uint32_t f, int c) {
    std::vector<float> values(kCellCount);
    for (std::size_t i = 0; i < kCellCount; ++i) values[i] = valueFor(f, c, i);
    return values;
}

std::expected<void, std::string> writeSyntheticFrame(copper::FieldFrameSeriesWriter& writer,
                                                        const copper::FieldFrameSeriesWriter::Header& header,
                                                        std::uint32_t frame) {
    return writer.writeFrame(frame * 10, static_cast<double>(frame) * header.timestepSeconds, makeComponent(frame, 0),
                              makeComponent(frame, 1), makeComponent(frame, 2), makeComponent(frame, 3),
                              makeComponent(frame, 4), makeComponent(frame, 5));
}

} // namespace

@interface FieldFrameSeriesTests : XCTestCase {
    std::filesystem::path _path;
}
@end

@implementation FieldFrameSeriesTests

- (void)setUp {
    _path = std::filesystem::temp_directory_path() /
            ("copper_tests_field_frames_" + std::to_string(reinterpret_cast<std::uintptr_t>(self)) + ".h5");
    std::error_code ec;
    std::filesystem::remove(_path, ec);
}

- (void)tearDown {
    std::error_code ec;
    std::filesystem::remove(_path, ec);
}

- (void)testRoundTripMatchesBitExactAcrossFullAndPartialChunks {
    const copper::FieldFrameSeriesWriter::Header header = makeHeader();
    {
        auto writer = copper::FieldFrameSeriesWriter::create(_path, header, /*chunkFrames=*/16);
        XCTAssertTrue(writer.has_value(), @"create failed: %s", writer.has_value() ? "" : writer.error().c_str());
        for (std::uint32_t f = 0; f < kFrameCount; ++f) {
            auto written = writeSyntheticFrame(*writer, header, f);
            XCTAssertTrue(written.has_value());
        }
        auto closed = writer->close();
        XCTAssertTrue(closed.has_value());
    }

    auto reader = copper::FieldFrameSeriesReader::open(_path);
    XCTAssertTrue(reader.has_value());
    XCTAssertEqual(reader->frameCount(), kFrameCount);

    const auto& readHeader = reader->header();
    XCTAssertEqual(readHeader.simulationName, header.simulationName);
    XCTAssertEqual(readHeader.excitedPort, header.excitedPort);
    XCTAssertEqual(readHeader.nx, header.nx);
    XCTAssertEqual(readHeader.ny, header.ny);
    XCTAssertEqual(readHeader.nz, header.nz);
    XCTAssertEqual(readHeader.timestepSeconds, header.timestepSeconds);
    XCTAssertEqual(readHeader.boardZMin, header.boardZMin);
    XCTAssertEqual(readHeader.boardZMax, header.boardZMax);
    XCTAssertEqual(readHeader.lineX, header.lineX);
    XCTAssertEqual(readHeader.lineY, header.lineY);
    XCTAssertEqual(readHeader.lineZ, header.lineZ);
    XCTAssertEqual(readHeader.domainXYClass.size(), header.domainXYClass.size());
    for (std::size_t i = 0; i < std::min(readHeader.domainXYClass.size(), header.domainXYClass.size()); ++i) {
        XCTAssertEqual(readHeader.domainXYClass[i], header.domainXYClass[i], @"domain class mismatch at %zu", i);
    }

    for (std::uint32_t f = 0; f < kFrameCount; ++f) {
        std::vector<float> ex, ey, ez, hx, hy, hz;
        auto readResult = reader->readFrame(f, ex, ey, ez, hx, hy, hz);
        XCTAssertTrue(readResult.has_value());
        const std::array<const std::vector<float>*, 6> components = {&ex, &ey, &ez, &hx, &hy, &hz};
        for (int c = 0; c < 6; ++c) {
            XCTAssertEqual(components[static_cast<std::size_t>(c)]->size(), kCellCount);
            for (std::size_t i = 0; i < kCellCount; ++i) {
                XCTAssertEqual((*components[static_cast<std::size_t>(c)])[i], valueFor(f, c, i));
            }
        }
        XCTAssertEqual(reader->timeSeconds(f), static_cast<double>(f) * header.timestepSeconds);
        XCTAssertEqual(reader->timestep(f), f * 10);
        XCTAssertLessThanOrEqual(reader->minEnergy(f), reader->maxEnergy(f));

        for (int c = 0; c < 6; ++c) {
            const auto component = static_cast<copper::FieldComponent>(c);
            const copper::FieldComponentRange frameRange = reader->componentRange(component, f);
            XCTAssertEqual(frameRange.minimum, valueFor(f, c, 0));
            XCTAssertEqual(frameRange.maximum, valueFor(f, c, kCellCount - 1));

            const std::optional<copper::FieldComponentRange> seriesRange = reader->componentRange(component);
            XCTAssertTrue(seriesRange.has_value());
            XCTAssertEqual(seriesRange->minimum, valueFor(0, c, 0));
            XCTAssertEqual(seriesRange->maximum, valueFor(kFrameCount - 1, c, kCellCount - 1));
        }
    }

    std::vector<float> ex, ey, ez, hx, hy, hz;
    auto region = reader->readRegion(16, /*x=*/1, /*y=*/1, /*z=*/0,
                                     /*nx=*/2, /*ny=*/1, /*nz=*/2, ex, ey, ez, hx, hy, hz);
    XCTAssertTrue(region.has_value());
    const std::array<std::size_t, 4> sourceIndices = {4, 5, 10, 11};
    const std::array<const std::vector<float>*, 6> regionComponents = {&ex, &ey, &ez, &hx, &hy, &hz};
    for (int component = 0; component < 6; ++component) {
        XCTAssertEqual(regionComponents[static_cast<std::size_t>(component)]->size(), sourceIndices.size());
        for (std::size_t i = 0; i < sourceIndices.size(); ++i) {
            XCTAssertEqual((*regionComponents[static_cast<std::size_t>(component)])[i],
                           valueFor(16, component, sourceIndices[i]));
        }
    }
}

- (void)testPreviewUsesMaxEnergyAndMeanSignedComponents {
    const copper::FieldFrameSeriesWriter::Header header = makeHeader();
    {
        auto writer = copper::FieldFrameSeriesWriter::create(_path, header, /*chunkFrames=*/16);
        XCTAssertTrue(writer.has_value());
        XCTAssertTrue(writeSyntheticFrame(*writer, header, 0).has_value());
        XCTAssertTrue(writer->close().has_value());
    }

    auto reader = copper::FieldFrameSeriesReader::open(_path);
    XCTAssertTrue(reader.has_value());
    const auto& preview = reader->previewHeader();
    XCTAssertEqual(preview.nx, 1U);
    XCTAssertEqual(preview.ny, 1U);
    XCTAssertEqual(preview.nz, 1U);
    XCTAssertEqual(preview.lineX.front(), (header.lineX.front() + header.lineX.back()) * 0.5);
    XCTAssertEqual(preview.lineY.front(), (header.lineY.front() + header.lineY.back()) * 0.5);
    XCTAssertEqual(preview.lineZ.front(), (header.lineZ.front() + header.lineZ.back()) * 0.5);

    std::vector<float> energy, ex, ey, ez, hx, hy, hz;
    XCTAssertTrue(reader->readPreviewFrame(0, energy, ex, ey, ez, hx, hy, hz).has_value());
    XCTAssertEqual(energy.size(), 1U);
    const std::array<const std::vector<float>*, 6> components = {&ex, &ey, &ez, &hx, &hy, &hz};
    for (int component = 0; component < 6; ++component) {
        float sum = 0.0F;
        for (std::size_t cell = 0; cell < kCellCount; ++cell) sum += valueFor(0, component, cell);
        XCTAssertEqualWithAccuracy(components[static_cast<std::size_t>(component)]->front(),
                                   sum / static_cast<float>(kCellCount), 1e-5F);
    }
    constexpr float kEps0 = 8.8541878128e-12F;
    constexpr float kMu0 = 1.25663706212e-6F;
    float expectedMaximum = 0.0F;
    for (std::size_t cell = 0; cell < kCellCount; ++cell) {
        float eSquared = 0.0F;
        float hSquared = 0.0F;
        for (int component = 0; component < 3; ++component) {
            const float value = valueFor(0, component, cell);
            eSquared += value * value;
        }
        for (int component = 3; component < 6; ++component) {
            const float value = valueFor(0, component, cell);
            hSquared += value * value;
        }
        expectedMaximum = std::max(expectedMaximum, kEps0 * eSquared + kMu0 * hSquared);
    }
    XCTAssertEqual(energy.front(), expectedMaximum);
}

- (void)testPreviewCeilDimensionsKeepAnEdgePeakInItsOwnCell {
    copper::FieldFrameSeriesWriter::Header header;
    header.simulationName = "PreviewEdges";
    header.nx = 17;
    header.ny = 17;
    header.nz = 3;
    header.lineX.resize(header.nx);
    header.lineY.resize(header.ny);
    header.lineZ.resize(header.nz);
    const std::size_t count = static_cast<std::size_t>(header.nx) * header.ny * header.nz;
    std::vector<float> ex(count, 0.0F);
    std::vector<float> zero(count, 0.0F);
    ex.back() = 100.0F;
    {
        auto writer = copper::FieldFrameSeriesWriter::create(_path, header);
        XCTAssertTrue(writer.has_value());
        XCTAssertTrue(writer->writeFrame(0, 0.0, ex, zero, zero, zero, zero, zero).has_value());
        XCTAssertTrue(writer->close().has_value());
    }
    auto reader = copper::FieldFrameSeriesReader::open(_path);
    XCTAssertTrue(reader.has_value());
    XCTAssertEqual(reader->previewHeader().nx, 2U);
    XCTAssertEqual(reader->previewHeader().ny, 2U);
    XCTAssertEqual(reader->previewHeader().nz, 2U);
    XCTAssertEqual(reader->previewFactorX(), 16U);
    XCTAssertEqual(reader->previewFactorY(), 16U);
    XCTAssertEqual(reader->previewFactorZ(), 2U);
    std::vector<float> energy, pEx, ey, ez, hx, hy, hz;
    XCTAssertTrue(reader->readPreviewFrame(0, energy, pEx, ey, ez, hx, hy, hz).has_value());
    XCTAssertEqual(energy.size(), 8U);
    for (std::size_t i = 0; i + 1 < energy.size(); ++i) XCTAssertEqual(energy[i], 0.0F);
    XCTAssertEqualWithAccuracy(energy.back(), 8.8541878128e-12F * 10000.0F, 1e-12F);
    XCTAssertEqual(pEx.back(), 100.0F);
    auto order = reader->readRefinementOrder(0);
    XCTAssertTrue(order.has_value());
    XCTAssertEqual(*order, std::vector<std::uint32_t>({0, 1, 2, 3, 4, 5, 6, 7}));

    auto batch = reader->readPreviewCellDetails(0, *order);
    XCTAssertTrue(batch.has_value());
    XCTAssertEqual(batch->size(), order->size());
    for (std::size_t i = 0; i < batch->size(); ++i) {
        std::vector<float> dEx, dEy, dEz, dHx, dHy, dHz;
        XCTAssertTrue(reader->readPreviewCellDetail(0, (*order)[i], dEx, dEy, dEz, dHx, dHy, dHz).has_value());
        const std::array<const std::vector<float>*, 6> expected = {&dEx, &dEy, &dEz, &dHx, &dHy, &dHz};
        XCTAssertEqual((*batch)[i].previewCellIndex, (*order)[i]);
        for (std::size_t component = 0; component < expected.size(); ++component) {
            XCTAssertEqual((*batch)[i].components[component], *expected[component]);
        }
    }
}

- (void)testRefinementOrderPrioritizesThePreviewCellWithMostSignedDetail {
    copper::FieldFrameSeriesWriter::Header header;
    header.simulationName = "RefinementOrder";
    header.nx = 32;
    header.ny = 1;
    header.nz = 1;
    header.lineX.resize(header.nx);
    header.lineY.resize(header.ny);
    header.lineZ.resize(header.nz);
    std::vector<float> ex(header.nx, 5.0F);
    for (std::size_t i = 0; i < 16; ++i) ex[i] = (i % 2 == 0) ? -10.0F : 10.0F;
    std::vector<float> zero(header.nx, 0.0F);
    {
        auto writer = copper::FieldFrameSeriesWriter::create(_path, header);
        XCTAssertTrue(writer.has_value());
        XCTAssertTrue(writer->writeFrame(0, 0.0, ex, zero, zero, zero, zero, zero).has_value());
        XCTAssertTrue(writer->close().has_value());
    }

    auto reader = copper::FieldFrameSeriesReader::open(_path);
    XCTAssertTrue(reader.has_value());
    auto order = reader->readRefinementOrder(0);
    XCTAssertTrue(order.has_value());
    XCTAssertEqual(*order, std::vector<std::uint32_t>({0, 1}));

    std::vector<float> detailEx, ey, ez, hx, hy, hz;
    XCTAssertTrue(reader->readPreviewCellDetail(0, order->front(), detailEx, ey, ez, hx, hy, hz).has_value());
    XCTAssertEqual(detailEx.size(), 16U);
    for (std::size_t i = 0; i < detailEx.size(); ++i) {
        XCTAssertEqual(detailEx[i], (i % 2 == 0) ? -10.0F : 10.0F);
    }
    XCTAssertTrue(reader->readPreviewCellDetail(0, order->back(), detailEx, ey, ez, hx, hy, hz).has_value());
    XCTAssertEqual(detailEx, std::vector<float>(16, 5.0F));
}

/// prefetchFrame() from a background thread while readFrame() runs on this one: exercises the
/// two-frame cache and confirms concurrent calls into the reader from two real threads don't
/// crash/deadlock/race, and that the prefetched frame still reads back bit-exact via the promotion
/// path (not a second decode).
- (void)testPrefetchFromBackgroundThreadThenReadReturnsBitExactData {
    const copper::FieldFrameSeriesWriter::Header header = makeHeader();
    {
        auto writer = copper::FieldFrameSeriesWriter::create(_path, header, /*chunkFrames=*/16);
        XCTAssertTrue(writer.has_value());
        for (std::uint32_t f = 0; f < kFrameCount; ++f) {
            XCTAssertTrue(writeSyntheticFrame(*writer, header, f).has_value());
        }
        XCTAssertTrue(writer->close().has_value());
    }

    auto reader = copper::FieldFrameSeriesReader::open(_path);
    XCTAssertTrue(reader.has_value());
    std::vector<float> ex, ey, ez, hx, hy, hz;
    XCTAssertTrue(reader->readFrame(0, ex, ey, ez, hx, hy, hz).has_value()); // warm up the primary slot

    std::thread prefetchThread([&reader] { reader->prefetchFrame(16); });
    prefetchThread.join();

    XCTAssertTrue(reader->readFrame(16, ex, ey, ez, hx, hy, hz).has_value());
    const std::array<const std::vector<float>*, 6> components = {&ex, &ey, &ez, &hx, &hy, &hz};
    for (int c = 0; c < 6; ++c) {
        for (std::size_t i = 0; i < kCellCount; ++i) {
            XCTAssertEqual((*components[static_cast<std::size_t>(c)])[i], valueFor(16, c, i));
        }
    }

    // Leaving the viewer discards both resident frame slots without closing the reader. Returning
    // to the same series must transparently stream the requested frame again.
    reader->clearFrameCache();
    XCTAssertTrue(reader->readFrame(16, ex, ey, ez, hx, hy, hz).has_value());
    XCTAssertEqual(ex.front(), valueFor(16, 0, 0));
}

/// A SWMR reader follows complete blocks while the writer remains open, and only observes the final
/// partial block once the writer publishes it by closing -- the transaction boundary a live field
/// viewer relies on: it can never observe a mixture of old and new component arrays.
- (void)testSWMRReaderFollowsCompleteAndFinalPartialBlocks {
    const copper::FieldFrameSeriesWriter::Header header = makeHeader();
    auto writer = copper::FieldFrameSeriesWriter::create(_path, header, /*chunkFrames=*/16);
    XCTAssertTrue(writer.has_value());
    for (std::uint32_t f = 0; f < 16; ++f) {
        XCTAssertTrue(writeSyntheticFrame(*writer, header, f).has_value());
    }

    auto reader = copper::FieldFrameSeriesReader::open(_path);
    XCTAssertTrue(reader.has_value());
    XCTAssertEqual(reader->frameCount(), 16U, @"SWMR reader did not see the first published block");

    XCTAssertTrue(writeSyntheticFrame(*writer, header, 16).has_value());
    auto beforeClose = reader->refresh();
    XCTAssertTrue(beforeClose.has_value());
    XCTAssertEqual(*beforeClose, 16U, @"SWMR reader observed an unpublished partial block");

    XCTAssertTrue(writer->close().has_value());
    auto afterClose = reader->refresh();
    XCTAssertTrue(afterClose.has_value());
    XCTAssertEqual(*afterClose, 17U, @"SWMR reader did not discover the final published partial block");

    std::vector<float> ex, ey, ez, hx, hy, hz;
    auto read = reader->readFrame(16, ex, ey, ez, hx, hy, hz);
    XCTAssertTrue(read.has_value());
    XCTAssertEqual(ex.front(), valueFor(16, 0, 0));
    XCTAssertEqual(hz.back(), valueFor(16, 5, kCellCount - 1));
}

/// readFrame() on an out-of-range index must fail cleanly (std::expected error), not crash or
/// return garbage -- the boundary condition every playback UI's own "last frame" edge relies on.
- (void)testReadFrameOutOfRangeReturnsError {
    const copper::FieldFrameSeriesWriter::Header header = makeHeader();
    {
        auto writer = copper::FieldFrameSeriesWriter::create(_path, header, /*chunkFrames=*/16);
        XCTAssertTrue(writer.has_value());
        XCTAssertTrue(writeSyntheticFrame(*writer, header, 0).has_value());
        XCTAssertTrue(writer->close().has_value());
    }
    auto reader = copper::FieldFrameSeriesReader::open(_path);
    XCTAssertTrue(reader.has_value());
    XCTAssertEqual(reader->frameCount(), 1U);

    std::vector<float> ex, ey, ez, hx, hy, hz;
    auto result = reader->readFrame(1, ex, ey, ez, hx, hy, hz);
    XCTAssertFalse(result.has_value());
}

- (void)testOpeningNonexistentFileReturnsError {
    auto reader = copper::FieldFrameSeriesReader::open(std::filesystem::temp_directory_path() /
                                                          "copper_tests_does_not_exist.h5");
    XCTAssertFalse(reader.has_value());
}

@end
