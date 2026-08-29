// Minimal leveled logger. Ported (loosely) from the `logging`/`coloredlogs` usage throughout
// the Python sources: timestamped, level-coloured lines matching coloredlogs' default format.
// Colour is only emitted when the destination stream looks like a colour-capable terminal.
//
// Lines use `HH:MM:SS [LEVEL] message (file:line function)`. Using
// std::source_location::current() as a default argument captures the caller's location
// transparently, so no call site needs to pass it.
#pragma once

#include <ios>
#include <ostream>
#include <sstream>
#include <source_location>
#include <string_view>
#include <utility>

namespace Cu {

enum class LogLevel {
    Debug,
    Info,
    Warning,
    Error,
    Assert,
};

/// Set the minimum level that will actually be printed. Default: Info.
void setLogLevel(LogLevel level);

/// A single in-progress log line. The log factory functions below return this by value; each
/// operator<< returns a reference to that same temporary, and its destructor emits the completed
/// line at the end of the full expression.
class LogMessage {
public:
    LogMessage(LogLevel level, std::source_location location);
    LogMessage(LogLevel level, std::source_location location, std::string_view initialMessage);
    ~LogMessage() noexcept;

    LogMessage(const LogMessage&) = delete;
    LogMessage& operator=(const LogMessage&) = delete;
    LogMessage(LogMessage&&) = delete;
    LogMessage& operator=(LogMessage&&) = delete;

    template <typename T>
    LogMessage& operator<<(T&& value) {
        _stream << std::forward<T>(value);
        return *this;
    }

    LogMessage& operator<<(std::ostream& (*manipulator)(std::ostream&)) {
        manipulator(_stream);
        return *this;
    }

    LogMessage& operator<<(std::ios& (*manipulator)(std::ios&)) {
        manipulator(_stream);
        return *this;
    }

    LogMessage& operator<<(std::ios_base& (*manipulator)(std::ios_base&)) {
        manipulator(_stream);
        return *this;
    }

private:
    LogLevel _level;
    std::source_location _location;
    std::ostringstream _stream;
};

/// The failure path of a streamable assertion. The assert macro only constructs this object after
/// its condition has evaluated false. Its destructor logs the completed message and aborts at the
/// end of the full expression.
class AssertionMessage {
public:
    AssertionMessage(std::string_view conditionText, std::source_location location);
    ~AssertionMessage() noexcept;

    AssertionMessage(const AssertionMessage&) = delete;
    AssertionMessage& operator=(const AssertionMessage&) = delete;
    AssertionMessage(AssertionMessage&&) = delete;
    AssertionMessage& operator=(AssertionMessage&&) = delete;

    template <typename T>
    AssertionMessage& operator<<(T&& value) {
        _stream << std::forward<T>(value);
        return *this;
    }

    AssertionMessage& operator<<(std::ostream& (*manipulator)(std::ostream&)) {
        manipulator(_stream);
        return *this;
    }

    AssertionMessage& operator<<(std::ios& (*manipulator)(std::ios&)) {
        manipulator(_stream);
        return *this;
    }

    AssertionMessage& operator<<(std::ios_base& (*manipulator)(std::ios_base&)) {
        manipulator(_stream);
        return *this;
    }

private:
    std::string_view _conditionText;
    std::source_location _location;
    std::ostringstream _stream;
};

/// Turns the lazy assertion expression into void without affecting the AssertionMessage
/// temporary's lifetime.
class AssertionVoidify {
public:
    void operator&(AssertionMessage&) const noexcept {}
};

LogMessage logDebug(std::source_location location = std::source_location::current());
LogMessage logInfo(std::source_location location = std::source_location::current());
LogMessage logWarning(std::source_location location = std::source_location::current());
LogMessage logError(std::source_location location = std::source_location::current());

// A complete initial message is still convenient, and returns the same stream-builder so callers
// can append more fields with operator<< when useful.
LogMessage logDebug(std::string_view message, std::source_location location = std::source_location::current());
LogMessage logInfo(std::string_view message, std::source_location location = std::source_location::current());
LogMessage logWarning(std::string_view message, std::source_location location = std::source_location::current());
LogMessage logError(std::string_view message, std::source_location location = std::source_location::current());

} // namespace Cu

#ifdef NDEBUG
// The unevaluated branch preserves `CU_ASSERT(x) << details` syntax and type checking, while release
// builds evaluate neither the condition nor the streamed details and construct no message.
#define CU_ASSERT(condition) \
    true ? (void)0 : ::Cu::AssertionVoidify() & \
                         ::Cu::AssertionMessage(#condition, std::source_location::current())
#else
// ?: is lazy: the AssertionMessage and every streamed operand exist only on the failure path.
#define CU_ASSERT(condition) \
    static_cast<bool>(condition) ? (void)0 : ::Cu::AssertionVoidify() & \
                                               ::Cu::AssertionMessage(#condition, std::source_location::current())
#endif
