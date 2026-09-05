#include "CopperHDF5Blosc2.hpp"

#include <algorithm>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <limits>
#include <mutex>
#include <thread>

#include <blosc2.h>

namespace copper {

namespace {

constexpr H5Z_filter_t kBlosc2FilterId = 32026;

// Shared by both directions below so decompression gets exactly as many worker threads as
// compression does -- a plain `blosc2_decompress()` call (no explicit context) defaults to
// BLOSC2_DPARAMS_DEFAULTS' nthreads=1 and serializes through Blosc2's own global lock, which was
// the actual bottleneck keeping playback decode single-threaded even though encoding (which already
// built its own multithreaded blosc2_cctx below) was not.
std::int16_t blosc2WorkerThreadCount() {
    const unsigned int hardwareThreads = std::max(1U, std::thread::hardware_concurrency());
    return static_cast<std::int16_t>(
        std::min(hardwareThreads, static_cast<unsigned int>(std::numeric_limits<std::int16_t>::max())));
}

// One multithreaded blosc2_context per direction, created once per thread and reused for every
// subsequent filter invocation on that same thread -- never freed (a bounded, one-time-per-thread
// leak, not a per-call one; acceptable for the small, stable set of threads that ever actually touch
// this filter -- the writer thread and whatever GCD worker threads FieldFrameSeriesReader's own
// background prefetch/refresh calls land on). This used to create *and tear down* a fresh
// hardwareThreads-worker context on every single chunk read/write -- real OS thread-pool churn, not
// free -- and once the reader started staying open across live UI polls (reading far more often, far
// more concurrently with the writer's own in-flight compress calls) that churn started actually
// failing under load: blosc2_create_cctx()/blosc2_create_dctx() returning nullptr, which this filter
// correctly treated as a hard failure and reported to HDF5 -- surfacing as "filter returned failure"
// inside H5Fflush(), the exact symptom that prompted this fix. Reuse eliminates the churn (and is
// also just faster, since building a thread pool per call was pure overhead even when it succeeded).
blosc2_context* threadLocalCompressContext() {
    thread_local blosc2_context* context = nullptr;
    if (context == nullptr) {
        blosc2_cparams parameters = BLOSC2_CPARAMS_DEFAULTS;
        parameters.compcode = BLOSC_ZSTD;
        parameters.clevel = 1;
        parameters.typesize = sizeof(float);
        parameters.filters[BLOSC2_MAX_FILTERS - 1] = BLOSC_BITSHUFFLE;
        parameters.nthreads = blosc2WorkerThreadCount();
        context = blosc2_create_cctx(parameters);
    }
    return context;
}

blosc2_context* threadLocalDecompressContext() {
    thread_local blosc2_context* context = nullptr;
    if (context == nullptr) {
        blosc2_dparams parameters = BLOSC2_DPARAMS_DEFAULTS;
        parameters.nthreads = blosc2WorkerThreadCount();
        context = blosc2_create_dctx(parameters);
    }
    return context;
}

// Serializes the whole filter body (both directions) across every thread that ever calls into it --
// belt-and-suspenders alongside the vendored HDF5 build's own --enable-threadsafe global lock, not a
// substitute for it. Added after context-reuse alone (see threadLocal*Context()'s own doc comment)
// did *not* stop a real, reproduced-in-the-field failure: the writer thread's own H5Fflush() calling
// into this filter (forward direction) while a live viewer's FieldFrameSeriesReader background
// prefetch/refresh was concurrently calling into it (reverse direction) on the SAME SWMR file,
// surfacing as HDF5's own "H5Z_pipeline(): filter returned failure". SWMR's whole consistency model
// is designed around a writer and readers that don't need to coordinate through the *same* in-process
// lock at all (its usual deployment is separate processes, where thread-safety builds are moot) --
// there's real reason to suspect SWMR-mode operations take an internal path that isn't as fully
// covered by the general thread-safe global lock as an ordinary (non-SWMR) call would be, which would
// let this filter genuinely be re-entered from two threads at once despite --enable-threadsafe.
// Scoped to just this filter's own body (not a broader lock around every HDF5 call either side makes)
// since that's the exact boundary the failure was actually observed at, and it doesn't cost real
// throughput: two chunks decoding fully concurrently would already oversubscribe the CPU against each
// other (each filter invocation already uses a full hardwareThreads-worker context internally), so
// serializing chunk-at-a-time while keeping each one's own internal multithreading is no real loss.
std::mutex& blosc2FilterMutex() {
    static std::mutex mutex;
    return mutex;
}

// Every failure path below logs to stderr with enough detail (direction, sizes, the actual blosc2
// return code/message where one exists) to tell apart the candidates that have already been ruled
// out by two straight failed fix attempts (thread-pool churn; concurrent re-entry -- the whole-body
// mutex above makes that structurally impossible now) from ones not yet considered, e.g. this specific
// chunk's own byte count genuinely exceeding a hard limit somewhere in the int32-sized Blosc2/HDF5
// filter-callback API (BLOSC2_MAX_OVERHEAD, cd_values, etc. are all int32_t under the hood) -- a real
// board's mesh is enormously larger than the smoketest's synthetic 3x2x2 grid, so a size-class failure
// that only manifests on real data would never show up there. Prior fixes were shipped on plausible-
// but-ultimately-wrong theories with no actual evidence from a failing run; this doesn't repeat that.
size_t filterBlosc2(unsigned int flags, size_t /*parameterCount*/, const unsigned int* /*parameters*/,
                    size_t inputBytes, size_t* bufferBytes, void** buffer) {
    std::lock_guard lock(blosc2FilterMutex());
    const bool reverse = (flags & H5Z_FLAG_REVERSE) != 0;
    if (buffer == nullptr || *buffer == nullptr || bufferBytes == nullptr) {
        std::fprintf(stderr, "Copper: Blosc2 filter (%s): null buffer/bufferBytes argument\n",
                     reverse ? "decompress" : "compress");
        return 0;
    }
    if (inputBytes > static_cast<size_t>(std::numeric_limits<std::int32_t>::max())) {
        std::fprintf(stderr,
                     "Copper: Blosc2 filter (%s): inputBytes=%zu exceeds INT32_MAX -- this chunk is too "
                     "large for Blosc2/HDF5's int32-sized filter API\n",
                     reverse ? "decompress" : "compress", inputBytes);
        return 0;
    }

    if (reverse) {
        std::int32_t outputBytes = 0;
        std::int32_t encodedBytes = 0;
        if (blosc2_cbuffer_sizes(*buffer, &outputBytes, &encodedBytes, nullptr) < 0) {
            std::fprintf(stderr, "Copper: Blosc2 filter (decompress): blosc2_cbuffer_sizes failed "
                                  "(inputBytes=%zu, buffer likely not a valid Blosc2 frame)\n",
                         inputBytes);
            return 0;
        }
        if (outputBytes <= 0 || encodedBytes <= 0 || static_cast<size_t>(encodedBytes) > inputBytes) {
            std::fprintf(stderr,
                         "Copper: Blosc2 filter (decompress): implausible header sizes -- outputBytes=%d "
                         "encodedBytes=%d inputBytes=%zu\n",
                         outputBytes, encodedBytes, inputBytes);
            return 0;
        }
        void* output = std::malloc(static_cast<size_t>(outputBytes));
        if (output == nullptr) {
            std::fprintf(stderr, "Copper: Blosc2 filter (decompress): malloc(%d) failed\n", outputBytes);
            return 0;
        }

        // blosc2_decompress_ctx() (unlike plain blosc2_decompress()) both accepts an explicit
        // nthreads and, per its own doc comment, runs "without the global lock being used" --
        // letting this filter's own decompress calls (each one currently a single HDF5 chunk, i.e.
        // one field component's worth of one block) actually run with real parallelism instead of
        // fighting over Blosc2's process-wide single-threaded default.
        blosc2_context* decompressContext = threadLocalDecompressContext();
        if (decompressContext == nullptr) {
            std::fprintf(stderr, "Copper: Blosc2 filter (decompress): blosc2_create_dctx returned null\n");
            std::free(output);
            return 0;
        }
        const int decoded = blosc2_decompress_ctx(decompressContext, *buffer, encodedBytes, output, outputBytes);
        if (decoded != outputBytes) {
            std::fprintf(stderr,
                         "Copper: Blosc2 filter (decompress): blosc2_decompress_ctx returned %d, expected "
                         "%d (encodedBytes=%d, error=%s)\n",
                         decoded, outputBytes, encodedBytes, decoded < 0 ? print_error(decoded) : "n/a");
            std::free(output);
            return 0;
        }
        std::free(*buffer);
        *buffer = output;
        *bufferBytes = static_cast<size_t>(outputBytes);
        return static_cast<size_t>(outputBytes);
    }

    const size_t maximumOutput = inputBytes + BLOSC2_MAX_OVERHEAD;
    if (maximumOutput > static_cast<size_t>(std::numeric_limits<std::int32_t>::max())) {
        std::fprintf(stderr,
                     "Copper: Blosc2 filter (compress): inputBytes=%zu + BLOSC2_MAX_OVERHEAD exceeds "
                     "INT32_MAX\n",
                     inputBytes);
        return 0;
    }
    void* output = std::malloc(maximumOutput);
    if (output == nullptr) {
        std::fprintf(stderr, "Copper: Blosc2 filter (compress): malloc(%zu) failed\n", maximumOutput);
        return 0;
    }

    blosc2_context* context = threadLocalCompressContext();
    if (context == nullptr) {
        std::fprintf(stderr, "Copper: Blosc2 filter (compress): blosc2_create_cctx returned null\n");
        std::free(output);
        return 0;
    }
    const int encoded = blosc2_compress_ctx(context, *buffer, static_cast<std::int32_t>(inputBytes), output,
                                             static_cast<std::int32_t>(maximumOutput));
    if (encoded <= 0) {
        std::fprintf(stderr,
                     "Copper: Blosc2 filter (compress): blosc2_compress_ctx returned %d (inputBytes=%zu, "
                     "maximumOutput=%zu, error=%s)\n",
                     encoded, inputBytes, maximumOutput, encoded < 0 ? print_error(encoded) : "n/a");
        std::free(output);
        return 0;
    }

    std::free(*buffer);
    *buffer = output;
    *bufferBytes = maximumOutput;
    return static_cast<size_t>(encoded);
}

const H5Z_class2_t kBlosc2Filter = {
    H5Z_CLASS_T_VERS,
    kBlosc2FilterId,
    1,
    1,
    "Blosc2 Zstd level 1 + bitshuffle",
    nullptr,
    nullptr,
    filterBlosc2,
};

} // namespace

std::expected<void, std::string> registerHDF5Blosc2Filter() {
    static std::once_flag once;
    static herr_t registrationResult = -1;
    std::call_once(once, [] { registrationResult = H5Zregister(&kBlosc2Filter); });
    if (registrationResult < 0 || H5Zfilter_avail(kBlosc2FilterId) <= 0) {
        return std::unexpected("Could not register the HDF5 Blosc2 filter");
    }
    return {};
}

std::expected<void, std::string> setHDF5Blosc2Filter(hid_t dcpl) {
    if (auto registered = registerHDF5Blosc2Filter(); !registered) {
        return registered;
    }
    if (H5Pset_filter(dcpl, kBlosc2FilterId, H5Z_FLAG_MANDATORY, 0, nullptr) < 0) {
        return std::unexpected("H5Pset_filter failed for Blosc2");
    }
    return {};
}

} // namespace copper
