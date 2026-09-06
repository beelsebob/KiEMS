#pragma once

#include <os/signpost.h>

namespace copper {

inline os_log_t fieldFrameSignpostLog() {
    static os_log_t log = os_log_create("com.tdavie.kicad_ems", "FieldFrames");
    return log;
}

} // namespace copper
