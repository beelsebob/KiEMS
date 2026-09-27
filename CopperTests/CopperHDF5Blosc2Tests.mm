// Direct coverage for Internal/CopperHDF5Blosc2.hpp -- registering and applying the Blosc2 HDF5
// filter in isolation, rather than only indirectly via FieldFrameSeriesWriter/Reader's own much
// larger round trip (FieldFrameSeriesTests.mm). Pinpoints a filter-registration/application
// regression precisely instead of surfacing as a vaguer field-frame-series failure.
#import <XCTest/XCTest.h>

#include <filesystem>
#include <vector>

#include <hdf5.h>

#include "Internal/CopperHDF5Blosc2.hpp"

@interface CopperHDF5Blosc2Tests : XCTestCase
@end

@implementation CopperHDF5Blosc2Tests

- (void)testRegisterFilterSucceedsAndIsIdempotent {
    auto first = copper::registerHDF5Blosc2Filter();
    XCTAssertTrue(first.has_value(), @"registerHDF5Blosc2Filter failed: %s",
                  first.has_value() ? "" : first.error().c_str());
    // Registering a second time (e.g. a second FieldFrameSeriesWriter/Reader in the same process)
    // must not error -- HDF5 filter registration is process-global and every writer/reader calls
    // this independently.
    auto second = copper::registerHDF5Blosc2Filter();
    XCTAssertTrue(second.has_value());
}

- (void)testSetFilterOnChunkedPropertyListSucceeds {
    XCTAssertTrue(copper::registerHDF5Blosc2Filter().has_value());

    const hid_t dcpl = H5Pcreate(H5P_DATASET_CREATE);
    XCTAssertGreaterThanOrEqual(dcpl, 0);
    hsize_t chunkDims[1] = {4};
    XCTAssertGreaterThanOrEqual(H5Pset_chunk(dcpl, 1, chunkDims), 0);

    auto result = copper::setHDF5Blosc2Filter(dcpl);
    XCTAssertTrue(result.has_value(), @"setHDF5Blosc2Filter failed: %s", result.has_value() ? "" : result.error().c_str());

    // The registered Blosc2 filter id (32026, see this header's own doc comment) must actually be
    // present in the property list's own filter pipeline afterward.
    const int nFilters = H5Pget_nfilters(dcpl);
    XCTAssertEqual(nFilters, 1);
    unsigned int flags = 0;
    std::size_t cdNelmts = 0;
    const H5Z_filter_t filterId = H5Pget_filter2(dcpl, 0, &flags, &cdNelmts, nullptr, 0, nullptr, nullptr);
    XCTAssertEqual(filterId, 32026);

    H5Pclose(dcpl);
}

/// A minimal end-to-end dataset write/read round trip through the actual filter, direct against the
/// HDF5 C API -- not through FieldFrameSeriesWriter -- confirming the filter this file registers is
/// really what compresses/decompresses the bytes, losslessly, not just that it's present in the
/// pipeline.
- (void)testDatasetRoundTripThroughBlosc2FilterIsLossless {
    XCTAssertTrue(copper::registerHDF5Blosc2Filter().has_value());

    const std::filesystem::path path =
        std::filesystem::temp_directory_path() / "copper_tests_hdf5_blosc2_roundtrip.h5";
    std::error_code ec;
    std::filesystem::remove(path, ec);

    constexpr hsize_t kCount = 256;
    std::vector<float> written(kCount);
    for (hsize_t i = 0; i < kCount; ++i) {
        written[i] = static_cast<float>(i) * 0.5F - 37.0F;
    }

    {
        const hid_t file = H5Fcreate(path.c_str(), H5F_ACC_TRUNC, H5P_DEFAULT, H5P_DEFAULT);
        XCTAssertGreaterThanOrEqual(file, 0);
        hsize_t dims[1] = {kCount};
        const hid_t space = H5Screate_simple(1, dims, nullptr);
        const hid_t dcpl = H5Pcreate(H5P_DATASET_CREATE);
        hsize_t chunkDims[1] = {64};
        H5Pset_chunk(dcpl, 1, chunkDims);
        XCTAssertTrue(copper::setHDF5Blosc2Filter(dcpl).has_value());

        const hid_t dataset = H5Dcreate2(file, "values", H5T_NATIVE_FLOAT, space, H5P_DEFAULT, dcpl, H5P_DEFAULT);
        XCTAssertGreaterThanOrEqual(dataset, 0);
        XCTAssertGreaterThanOrEqual(H5Dwrite(dataset, H5T_NATIVE_FLOAT, H5S_ALL, H5S_ALL, H5P_DEFAULT, written.data()),
                                    0);

        H5Dclose(dataset);
        H5Pclose(dcpl);
        H5Sclose(space);
        H5Fclose(file);
    }

    {
        const hid_t file = H5Fopen(path.c_str(), H5F_ACC_RDONLY, H5P_DEFAULT);
        XCTAssertGreaterThanOrEqual(file, 0);
        const hid_t dataset = H5Dopen2(file, "values", H5P_DEFAULT);
        XCTAssertGreaterThanOrEqual(dataset, 0);

        std::vector<float> readBack(kCount, 0.0F);
        XCTAssertGreaterThanOrEqual(
            H5Dread(dataset, H5T_NATIVE_FLOAT, H5S_ALL, H5S_ALL, H5P_DEFAULT, readBack.data()), 0);

        for (hsize_t i = 0; i < kCount; ++i) {
            XCTAssertEqual(readBack[i], written[i]);
        }

        H5Dclose(dataset);
        H5Fclose(file);
    }

    std::filesystem::remove(path, ec);
}

@end
