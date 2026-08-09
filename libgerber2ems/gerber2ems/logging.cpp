#include "logging.hpp"

#include <cstdio>
#include <cstdlib>
#include <ctime>
#include <iostream>
#include <unistd.h>

namespace gerber2ems {

namespace {

LogLevel _globalLevel = LogLevel::Info;

bool _streamSupportsColor(FILE* stream) {
    if (::isatty(::fileno(stream)) == 0) {
        return false;
    }
    if (const char* noColor = std::getenv("NO_COLOR"); noColor != nullptr && noColor[0] != '\0') {
        return false;
    }
    if (const char* term = std::getenv("TERM"); term != nullptr && std::string_view(term) == "dumb") {
        return false;
    }
    return true;
}

std::string_view _levelLabel(LogLevel level) {
    switch (level) {
        case LogLevel::Debug:
            return "DEBU";
        case LogLevel::Info:
            return "INFO";
        case LogLevel::Warning:
            return "WARN";
        case LogLevel::Error:
            return "ERRO";
    }
    return "????";
}

// Mirrors coloredlogs' default level styles: debug=green, info=uncoloured, warning=yellow,
// error=red.
std::string_view _levelColorCode(LogLevel level) {
    switch (level) {
        case LogLevel::Debug:
            return "\033[32m";
        case LogLevel::Info:
            return "";
        case LogLevel::Warning:
            return "\033[33m";
        case LogLevel::Error:
            return "\033[31m";
    }
    return "";
}

std::string _currentTimestamp() {
    const std::time_t now = std::time(nullptr);
    std::tm local{};
    ::localtime_r(&now, &local);
    char buffer[16];
    const std::size_t written = std::strftime(buffer, sizeof(buffer), "%H:%M:%S", &local);
    return std::string(buffer, written);
}

// Mirrors Python's `pathlib`-free module name: just the filename stem, not the full path.
std::string _sourceStem(std::string_view filePath) {
    std::size_t begin = filePath.find_last_of("/\\");
    begin = (begin == std::string_view::npos) ? 0 : begin + 1;
    std::size_t end = filePath.find_last_of('.');
    if (end == std::string_view::npos || end < begin) {
        end = filePath.size();
    }
    return std::string(filePath.substr(begin, end - begin));
}

void _log(LogLevel level, std::string_view message, const std::source_location& loc) {
    if (level < _globalLevel) {
        return;
    }
    std::ostream& stream = (level == LogLevel::Error || level == LogLevel::Warning) ? std::cerr : std::cout;
    FILE* rawStream = (level == LogLevel::Error || level == LogLevel::Warning) ? stderr : stdout;

    const std::string timestamp = _currentTimestamp();
    const std::string_view label = _levelLabel(level);
    const bool color = _streamSupportsColor(rawStream);
    const std::string_view colorCode = color ? _levelColorCode(level) : std::string_view();
    const std::string_view resetCode = (color && !colorCode.empty()) ? std::string_view("\033[0m") : std::string_view();

    stream << colorCode << "[" << timestamp << "]";
    if (_globalLevel == LogLevel::Debug) {
        stream << "[" << _sourceStem(loc.file_name()) << ":" << loc.line() << "]";
    }
    stream << "[" << label << "] " << message << resetCode << "\n";
}

} // namespace

void setLogLevel(LogLevel level) { _globalLevel = level; }

void logDebug(std::string_view message, std::source_location loc) { _log(LogLevel::Debug, message, loc); }
void logInfo(std::string_view message, std::source_location loc) { _log(LogLevel::Info, message, loc); }
void logWarning(std::string_view message, std::source_location loc) { _log(LogLevel::Warning, message, loc); }
void logError(std::string_view message, std::source_location loc) { _log(LogLevel::Error, message, loc); }

} // namespace gerber2ems
