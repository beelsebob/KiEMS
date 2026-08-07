// Minimal leveled logger. Ported (loosely) from the `logging`/`coloredlogs` usage throughout
// the Python sources: timestamped, level-coloured lines matching coloredlogs' default format.
// Colour is only emitted when the destination stream looks like a colour-capable terminal.
//
// Mirrors main.py's setup_logging(): at Info/Warning/Error the format is
// `[%(asctime)s][%(levelname).4s] %(message)s`, e.g. "[19:23:57][INFO] message"; once the debug
// level is active, every line (not just debug-level ones) additionally carries a
// `[source:line]` field, matching Python's `[%(asctime)s][%(name)s:%(lineno)d][%(levelname).4s]
// %(message)s`. Using std::source_location::current() as a default argument captures the caller's
// location transparently, so no call site elsewhere needs to pass it explicitly.
#pragma once

#include <source_location>
#include <string_view>

namespace gerber2ems {

enum class LogLevel {
    Debug,
    Info,
    Warning,
    Error,
};

/// Set the minimum level that will actually be printed. Default: Info.
void setLogLevel(LogLevel level);

void logDebug(std::string_view message, std::source_location loc = std::source_location::current());
void logInfo(std::string_view message, std::source_location loc = std::source_location::current());
void logWarning(std::string_view message, std::source_location loc = std::source_location::current());
void logError(std::string_view message, std::source_location loc = std::source_location::current());

} // namespace gerber2ems
