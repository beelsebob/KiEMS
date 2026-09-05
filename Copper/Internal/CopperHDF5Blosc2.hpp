#pragma once

#include <expected>
#include <string>

#include <hdf5.h>

namespace copper {

/// Registers the standard HDF5 Blosc2 filter id (32026) in-process. The implementation uses
/// Blosc2's Zstd codec at clevel 1 with bitshuffle and its internal worker pool. Registering it
/// directly avoids a runtime HDF5_PLUGIN_PATH dependency while producing ordinary Blosc2 chunks
/// that the published HDF5 plugin can decode too.
std::expected<void, std::string> registerHDF5Blosc2Filter();

/// Adds the registered Blosc2 filter to a dataset-creation property list. Chunking must already be
/// configured on `dcpl`; HDF5 invokes this filter once for each complete component chunk.
std::expected<void, std::string> setHDF5Blosc2Filter(hid_t dcpl);

} // namespace copper
