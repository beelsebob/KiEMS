import Darwin

@_silgen_name("CuSwiftSetLogLevel")
private func setCppLogLevel(_ level: Int32)

@_silgen_name("CuSwiftLog")
private func emitCppLog(
    _ level: Int32,
    _ message: UnsafePointer<CChar>,
    _ file: UnsafePointer<CChar>,
    _ line: UInt32,
    _ function: UnsafePointer<CChar>
)

/// Swift logging utilities matching CopperUtils' C++ logger.
public enum Cu {
    public enum LogLevel: Int, Comparable, Sendable {
        case debug
        case info
        case warning
        case error
        case assertion

        public static func < (lhs: LogLevel, rhs: LogLevel) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }

    public static func setLogLevel(_ level: LogLevel) {
        setCppLogLevel(Int32(level.rawValue))
    }

    /// A log line under construction. Its deinitializer emits the complete line at the end of the
    /// expression in which it was created.
    public final class LogMessage {
        fileprivate let level: LogLevel
        fileprivate let file: String
        fileprivate let line: UInt
        fileprivate let function: String
        fileprivate var message = ""

        fileprivate init(level: LogLevel, file: StaticString, line: UInt, function: StaticString) {
            self.level = level
            self.file = String(describing: file)
            self.line = line
            self.function = String(describing: function)
        }

        fileprivate func append<T>(_ value: @autoclosure () -> T) {
            message += String(describing: value())
        }

        deinit {
            Cu.emit(level, message: message, file: file, line: line, function: function)
        }
    }

    /// The failure-only message builder returned by `CU_ASSERT` in debug builds.
    public final class AssertionMessage {
        fileprivate let file: String
        fileprivate let line: UInt
        fileprivate let function: String
        fileprivate var message = ""

        fileprivate init(file: StaticString, line: UInt, function: StaticString) {
            self.file = String(describing: file)
            self.line = line
            self.function = String(describing: function)
        }

        fileprivate func append<T>(_ value: @autoclosure () -> T) {
            message += String(describing: value())
        }

        deinit {
            let details = message.isEmpty ? "Assertion failed" : "Assertion failed: \(message)"
            Cu.emit(.assertion, message: details, file: file, line: line, function: function)
            abort()
        }
    }

    public static func logDebug(
        file: StaticString = #fileID,
        line: UInt = #line,
        function: StaticString = #function
    ) -> LogMessage {
        LogMessage(level: .debug, file: file, line: line, function: function)
    }

    @discardableResult
    public static func logDebug<T>(
        _ message: @autoclosure () -> T,
        file: StaticString = #fileID,
        line: UInt = #line,
        function: StaticString = #function
    ) -> LogMessage {
        let result = LogMessage(level: .debug, file: file, line: line, function: function)
        result.append(message())
        return result
    }

    public static func logInfo(
        file: StaticString = #fileID,
        line: UInt = #line,
        function: StaticString = #function
    ) -> LogMessage {
        LogMessage(level: .info, file: file, line: line, function: function)
    }

    @discardableResult
    public static func logInfo<T>(
        _ message: @autoclosure () -> T,
        file: StaticString = #fileID,
        line: UInt = #line,
        function: StaticString = #function
    ) -> LogMessage {
        let result = LogMessage(level: .info, file: file, line: line, function: function)
        result.append(message())
        return result
    }

    public static func logWarning(
        file: StaticString = #fileID,
        line: UInt = #line,
        function: StaticString = #function
    ) -> LogMessage {
        LogMessage(level: .warning, file: file, line: line, function: function)
    }

    @discardableResult
    public static func logWarning<T>(
        _ message: @autoclosure () -> T,
        file: StaticString = #fileID,
        line: UInt = #line,
        function: StaticString = #function
    ) -> LogMessage {
        let result = LogMessage(level: .warning, file: file, line: line, function: function)
        result.append(message())
        return result
    }

    public static func logError(
        file: StaticString = #fileID,
        line: UInt = #line,
        function: StaticString = #function
    ) -> LogMessage {
        LogMessage(level: .error, file: file, line: line, function: function)
    }

    @discardableResult
    public static func logError<T>(
        _ message: @autoclosure () -> T,
        file: StaticString = #fileID,
        line: UInt = #line,
        function: StaticString = #function
    ) -> LogMessage {
        let result = LogMessage(level: .error, file: file, line: line, function: function)
        result.append(message())
        return result
    }

    private static func emit(
        _ level: LogLevel,
        message: String,
        file: String,
        line: UInt,
        function: String
    ) {
        message.withCString { messagePointer in
            file.withCString { filePointer in
                function.withCString { functionPointer in
                    emitCppLog(
                        Int32(level.rawValue),
                        messagePointer,
                        filePointer,
                        UInt32(clamping: line),
                        functionPointer
                    )
                }
            }
        }
    }
}

precedencegroup CuLogStreamPrecedence {
    associativity: left
    higherThan: AssignmentPrecedence
}

infix operator <<<: CuLogStreamPrecedence

@discardableResult
public func <<< <T>(message: Cu.LogMessage, value: @autoclosure () -> T) -> Cu.LogMessage {
    message.append(value())
    return message
}

/// A lazy, streamable Swift assertion. In release builds neither the condition nor streamed values
/// are evaluated. Unlike a C macro, Swift cannot automatically include the condition's source text.
public func CU_ASSERT(
    _ condition: @autoclosure () -> Bool,
    file: StaticString = #fileID,
    line: UInt = #line,
    function: StaticString = #function
) -> Cu.AssertionMessage? {
#if DEBUG
    condition() ? nil : Cu.AssertionMessage(file: file, line: line, function: function)
#else
    nil
#endif
}

@discardableResult
public func <<< <T>(message: Cu.AssertionMessage?, value: @autoclosure () -> T) -> Cu.AssertionMessage? {
    message?.append(value())
    return message
}
