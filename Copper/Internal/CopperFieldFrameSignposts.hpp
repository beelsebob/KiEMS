#pragma once

#include <os/signpost.h>

namespace copper {

inline os_log_t fieldFrameSignpostLog() {
    static os_log_t log = os_log_create("com.tdavie.gerber2ems", "FieldFrames");
    return log;
}

} // namespace copper
