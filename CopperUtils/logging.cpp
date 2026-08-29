#include "logging.hpp"

#include <cstdio>
#include <cstdint>
#include <cstdlib>
#include <ctime>
#include <iostream>
#include <mutex>
#include <string_view>
#include <unistd.h>

extern "C" void CuSwiftSetLogLevel(int level);
extern "C" void CuSwiftLog(int level, const char* message, const char* file, std::uint_least32_t line,
                           const char* function);

namespace Cu {

namespace {

LogLevel _globalLevel = LogLevel::Info;
std::mutex _logMutex;

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
            return "DEBUG";
        case LogLevel::Info:
            return "INFO ";
        case LogLevel::Warning:
            return "WARN ";
        case LogLevel::Error:
            return "ERROR";
        case LogLevel::Assert:
            return "ASSRT";
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
        case LogLevel::Assert:
            return "\033[38;5;208m";
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

std::string_view _sourceFilename(std::string_view filePath) {
    std::size_t begin = filePath.find_last_of("/\\");
    begin = (begin == std::string_view::npos) ? 0 : begin + 1;
    return filePath.substr(begin);
}

void _logAt(LogLevel level, std::string_view message, std::string_view file, std::uint_least32_t line,
            std::string_view function) {
    std::lock_guard lock(_logMutex);
    if (level < _globalLevel) {
        return;
    }
    const bool useErrorStream = level == LogLevel::Error || level == LogLevel::Warning || level == LogLevel::Assert;
    std::ostream& stream = useErrorStream ? std::cerr : std::cout;
    FILE* rawStream = useErrorStream ? stderr : stdout;

    const std::string timestamp = _currentTimestamp();
    const std::string_view label = _levelLabel(level);
    const bool color = _streamSupportsColor(rawStream);
    const std::string_view colorCode = color ? _levelColorCode(level) : std::string_view();
    const std::string_view resetCode = (color && !colorCode.empty()) ? std::string_view("\033[0m") : std::string_view();

    stream << colorCode << timestamp << " [" << label << "] " << message << " ("
           << _sourceFilename(file) << ":" << line << " " << function << ")"
           << resetCode << "\n";
    stream.flush();
}

void _log(LogLevel level, std::string_view message, const std::source_location& loc) {
    _logAt(level, message, loc.file_name(), loc.line(), loc.function_name());
}

} // namespace

void setLogLevel(LogLevel level) {
    std::lock_guard lock(_logMutex);
    _globalLevel = level;
}

LogMessage::LogMessage(LogLevel level, std::source_location location) : _level(level), _location(location) {}

LogMessage::LogMessage(LogLevel level, std::source_location location, std::string_view initialMessage)
    : _level(level), _location(location) {
    _stream << initialMessage;
}

LogMessage::~LogMessage() noexcept {
    try {
        _log(_level, _stream.str(), _location);
    } catch (...) {
        // Logging must never make stack unwinding terminate the process.
    }
}

AssertionMessage::AssertionMessage(std::string_view conditionText, std::source_location location)
    : _conditionText(conditionText), _location(location) {}

AssertionMessage::~AssertionMessage() noexcept {
    try {
        std::string message = "Assertion `" + std::string(_conditionText) + "` failed";
        const std::string details = _stream.str();
        if (!details.empty()) {
            message += ": " + details;
        }
        _log(LogLevel::Assert, message, _location);
    } catch (...) {
        // A failed assertion must still terminate even if formatting or output fails.
    }
    std::abort();
}

LogMessage logDebug(std::source_location location) { return LogMessage(LogLevel::Debug, location); }
LogMessage logInfo(std::source_location location) { return LogMessage(LogLevel::Info, location); }
LogMessage logWarning(std::source_location location) { return LogMessage(LogLevel::Warning, location); }
LogMessage logError(std::source_location location) { return LogMessage(LogLevel::Error, location); }

LogMessage logDebug(std::string_view message, std::source_location location) {
    return LogMessage(LogLevel::Debug, location, message);
}
LogMessage logInfo(std::string_view message, std::source_location location) {
    return LogMessage(LogLevel::Info, location, message);
}
LogMessage logWarning(std::string_view message, std::source_location location) {
    return LogMessage(LogLevel::Warning, location, message);
}
LogMessage logError(std::string_view message, std::source_location location) {
    return LogMessage(LogLevel::Error, location, message);
}

// A small C ABI keeps the Swift and C++ frontends on the same logger state and output path.
extern "C" void CuSwiftSetLogLevel(int level) {
    if (level >= static_cast<int>(LogLevel::Debug) && level <= static_cast<int>(LogLevel::Assert)) {
        setLogLevel(static_cast<LogLevel>(level));
    }
}

extern "C" void CuSwiftLog(int level, const char* message, const char* file, std::uint_least32_t line,
                           const char* function) {
    if (level < static_cast<int>(LogLevel::Debug) || level > static_cast<int>(LogLevel::Assert)) {
        return;
    }
    _logAt(static_cast<LogLevel>(level), message, file, line, function);
}

} // namespace Cu
