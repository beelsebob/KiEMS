#pragma once

#include <utility>

#ifdef __APPLE__
#include <os/signpost.h>
#endif

namespace libkicad {
// A unique interval per invocation, including concurrent queries and copper groups.
// Metadata is public so Instruments can show phase and group names.
class BoardLoadTiming {
public:
    explicit BoardLoadTiming(const char* phase, const char* detail = "",
                             unsigned long vertices = 0, unsigned long polygons = 0) {
#ifdef __APPLE__
        id = os_signpost_id_generate(log());
        os_signpost_interval_begin(log(), id, "Board load phase",
                                  "%{public}s | %{public}s | vertices=%lu polygons=%lu",
                                  phase, detail, vertices, polygons);
#else
        (void)phase; (void)detail; (void)vertices; (void)polygons;
#endif
    }
    // Transfer the interval when its owning lock guard moves out of the board loader.
    BoardLoadTiming(BoardLoadTiming&& other) noexcept {
#ifdef __APPLE__
        id = std::exchange(other.id, OS_SIGNPOST_ID_INVALID);
#else
        (void)other;
#endif
    }
    ~BoardLoadTiming() { end(); }
    BoardLoadTiming(const BoardLoadTiming&) = delete;
    BoardLoadTiming& operator=(const BoardLoadTiming&) = delete;
    void end() {
#ifdef __APPLE__
        if (id != OS_SIGNPOST_ID_INVALID) {
            os_signpost_interval_end(log(), id, "Board load phase");
            id = OS_SIGNPOST_ID_INVALID;
        }
#endif
    }
private:
#ifdef __APPLE__
    static os_log_t log() {
        static os_log_t value = os_log_create("com.kiems", "BoardLoad");
        return value;
    }
    os_signpost_id_t id = OS_SIGNPOST_ID_INVALID;
#endif
};
}
