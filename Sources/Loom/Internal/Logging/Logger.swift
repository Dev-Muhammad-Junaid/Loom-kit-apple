//
//  Logger.swift
//  Loom
//
//  Created by Ethan Lipnik on 1/5/26.
//

import Foundation
import os

public enum LoomLogLevel: String, Sendable {
    case info
    case debug
    case error
    case fault
}

/// Centralized logging for Loom using Apple's unified logging system (`Logger`)
///
/// Logs appear in Console.app under the subsystem set via
/// ``configure(subsystem:)``, defaulting to `"com.loom"`.
///
/// Set `LOOM_LOG` environment variable in Xcode scheme:
/// - `all` - Enable Loom's known categories
/// - `none` - Disable all logging (except errors)
/// - `relay,cloud,trust` - Enable specific categories (comma-separated raw names)
/// - Not set - Default: essential Loom categories only
public struct LoomLogger: Sendable {
    private static let storage = LoggerStorage()

    /// The subsystem identifier used for all Loom log entries.
    public static var subsystem: String {
        storage.subsystem
    }

    /// Sets the subsystem identifier for all future log entries.
    ///
    /// Call this once at app launch — ideally before initializing ``LoomContainer`` — to
    /// make Loom logs appear under your app's own subsystem in Console.app and Instruments.
    ///
    /// ```swift
    /// LoomLogger.configure(subsystem: "com.myapp.loom")
    /// ```
    public static func configure(subsystem: String) {
        storage.configure(subsystem: subsystem)
    }

    /// Enabled log categories (evaluated once at startup from env var)
    public static let enabledCategories: Set<LoomLogCategory> = parseEnvironment()

    /// Check if a category is enabled
    public static func isEnabled(_ category: LoomLogCategory) -> Bool {
        enabledCategories.contains(category)
    }

    /// Log a message if the category is enabled
    /// Uses @autoclosure to avoid string interpolation when logging is disabled
    public static func log(
        _ category: LoomLogCategory,
        _ message: @autoclosure () -> String,
        fileID: String = #fileID,
        line: UInt = #line,
        function: String = #function
    ) {
        logInfo(
            category,
            message: message,
            fileID: fileID,
            line: line,
            function: function
        )
    }

    /// Log a debug-level message (lower priority, filtered by default in Console.app)
    public static func debug(
        _ category: LoomLogCategory,
        _ message: @autoclosure () -> String,
        fileID: String = #fileID,
        line: UInt = #line,
        function: String = #function
    ) {
        guard enabledCategories.contains(category) else { return }
        emit(
            category,
            level: .debug,
            message: message,
            fileID: fileID,
            line: line,
            function: function
        )
    }

    /// Log a message unconditionally (for errors).
    /// Errors are always logged regardless of category enablement.
    public static func error(
        _ category: LoomLogCategory,
        _ message: @autoclosure () -> String,
        fileID: String = #fileID,
        line: UInt = #line,
        function: String = #function
    ) {
        emit(
            category,
            level: .error,
            message: message,
            fileID: fileID,
            line: line,
            function: function
        )
    }

    /// Log and report a structured non-fatal error.
    public static func error(
        _ category: LoomLogCategory,
        error: Error,
        message: String? = nil,
        fileID: String = #fileID,
        line: UInt = #line,
        function: String = #function
    ) {
        emit(
            category,
            level: .error,
            message: {
                if let message, !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return message
                }
                let metadata = LoomDiagnosticsErrorMetadata(error: error)
                return "type=\(metadata.typeName) domain=\(metadata.domain) code=\(metadata.code)"
            },
            fileID: fileID,
            line: line,
            function: function,
            underlyingError: error,
            errorSource: .logger
        )
    }

    /// Log a fault-level message (critical errors that indicate bugs).
    public static func fault(
        _ category: LoomLogCategory,
        _ message: @autoclosure () -> String,
        fileID: String = #fileID,
        line: UInt = #line,
        function: String = #function
    ) {
        emit(
            category,
            level: .fault,
            message: message,
            fileID: fileID,
            line: line,
            function: function
        )
    }

    /// Log and report a structured fault.
    public static func fault(
        _ category: LoomLogCategory,
        error: Error,
        message: String? = nil,
        fileID: String = #fileID,
        line: UInt = #line,
        function: String = #function
    ) {
        emit(
            category,
            level: .fault,
            message: {
                if let message, !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return message
                }
                let metadata = LoomDiagnosticsErrorMetadata(error: error)
                return "type=\(metadata.typeName) domain=\(metadata.domain) code=\(metadata.code)"
            },
            fileID: fileID,
            line: line,
            function: function,
            underlyingError: error,
            errorSource: .logger
        )
    }

    private static func logInfo(
        _ category: LoomLogCategory,
        message: () -> String,
        fileID: String,
        line: UInt,
        function: String
    ) {
        guard enabledCategories.contains(category) else { return }
        emit(
            category,
            level: .info,
            message: message,
            fileID: fileID,
            line: line,
            function: function
        )
    }

    private static func emit(
        _ category: LoomLogCategory,
        level: LoomLogLevel,
        message: () -> String,
        fileID: String,
        line: UInt,
        function: String,
        underlyingError: Error? = nil,
        errorSource: LoomDiagnosticsErrorSource = .logger
    ) {
        let rawMessage = message()
        let sourceMessage = "\(sourcePrefix(fileID: fileID, line: line, function: function)) \(rawMessage)"
        let logger = logger(for: category)
        switch level {
        case .info:
            logger.info("\(sourceMessage, privacy: .public)")
        case .debug:
            logger.debug("\(sourceMessage, privacy: .public)")
        case .error:
            logger.error("\(sourceMessage, privacy: .public)")
        case .fault:
            logger.fault("\(sourceMessage, privacy: .public)")
        }

        let now = Date()
        LoomDiagnostics.record(log: LoomDiagnosticsLogEvent(
            date: now,
            category: category,
            level: level,
            message: sourceMessage,
            fileID: fileID,
            line: line,
            function: function
        ))

        switch level {
        case .error,
             .fault:
            LoomDiagnostics.record(error: LoomDiagnosticsErrorEvent(
                date: now,
                category: category,
                severity: level == .fault ? .fault : .error,
                source: errorSource,
                message: sourceMessage,
                fileID: fileID,
                line: line,
                function: function,
                metadata: underlyingError.map(LoomDiagnosticsErrorMetadata.init(error:))
            ))
        case .info,
             .debug:
            break
        }
    }

    private static func sourcePrefix(fileID: String, line: UInt, function: String) -> String {
        "[\(fileID):\(line) \(function)]"
    }

    private static func logger(for category: LoomLogCategory) -> Logger {
        storage.logger(for: category)
    }

    /// Parse LOOM_LOG environment variable
    private static func parseEnvironment() -> Set<LoomLogCategory> {
        guard let envValue = ProcessInfo.processInfo.environment["LOOM_LOG"] else {
            return LoomLogCategory.defaultEnabledCategories
        }

        let trimmed = envValue.trimmingCharacters(in: .whitespaces).lowercased()

        switch trimmed {
        case "all":
            return Set(LoomLogCategory.knownCategories)
        case "",
             "none":
            return []
        default:
            let names = trimmed.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            return Set(names.compactMap { name in
                let category = LoomLogCategory(rawValue: name)
                return category.rawValue.isEmpty ? nil : category
            })
        }
    }
}

/// Convenience functions for common log patterns
public extension LoomLogger {
    static func discovery(
        _ message: @autoclosure () -> String,
        fileID: String = #fileID,
        line: UInt = #line,
        function: String = #function
    ) {
        logInfo(
            .discovery,
            message: message,
            fileID: fileID,
            line: line,
            function: function
        )
    }

    static func session(
        _ message: @autoclosure () -> String,
        fileID: String = #fileID,
        line: UInt = #line,
        function: String = #function
    ) {
        logInfo(
            .session,
            message: message,
            fileID: fileID,
            line: line,
            function: function
        )
    }

    static func transport(
        _ message: @autoclosure () -> String,
        fileID: String = #fileID,
        line: UInt = #line,
        function: String = #function
    ) {
        logInfo(
            .transport,
            message: message,
            fileID: fileID,
            line: line,
            function: function
        )
    }

    static func remoteSignaling(
        _ message: @autoclosure () -> String,
        fileID: String = #fileID,
        line: UInt = #line,
        function: String = #function
    ) {
        logInfo(
            .remoteSignaling,
            message: message,
            fileID: fileID,
            line: line,
            function: function
        )
    }

    static func identity(
        _ message: @autoclosure () -> String,
        fileID: String = #fileID,
        line: UInt = #line,
        function: String = #function
    ) {
        logInfo(
            .identity,
            message: message,
            fileID: fileID,
            line: line,
            function: function
        )
    }

    static func security(
        _ message: @autoclosure () -> String,
        fileID: String = #fileID,
        line: UInt = #line,
        function: String = #function
    ) {
        logInfo(
            .security,
            message: message,
            fileID: fileID,
            line: line,
            function: function
        )
    }

    static func trust(
        _ message: @autoclosure () -> String,
        fileID: String = #fileID,
        line: UInt = #line,
        function: String = #function
    ) {
        logInfo(
            .trust,
            message: message,
            fileID: fileID,
            line: line,
            function: function
        )
    }

    static func cloud(
        _ message: @autoclosure () -> String,
        fileID: String = #fileID,
        line: UInt = #line,
        function: String = #function
    ) {
        logInfo(
            .cloud,
            message: message,
            fileID: fileID,
            line: line,
            function: function
        )
    }

    static func bootstrap(
        _ message: @autoclosure () -> String,
        fileID: String = #fileID,
        line: UInt = #line,
        function: String = #function
    ) {
        logInfo(
            .bootstrap,
            message: message,
            fileID: fileID,
            line: line,
            function: function
        )
    }

    static func ssh(
        _ message: @autoclosure () -> String,
        fileID: String = #fileID,
        line: UInt = #line,
        function: String = #function
    ) {
        logInfo(
            .ssh,
            message: message,
            fileID: fileID,
            line: line,
            function: function
        )
    }

    static func wakeOnLAN(
        _ message: @autoclosure () -> String,
        fileID: String = #fileID,
        line: UInt = #line,
        function: String = #function
    ) {
        logInfo(
            .wakeOnLAN,
            message: message,
            fileID: fileID,
            line: line,
            function: function
        )
    }
}

private final class LoggerStorage: @unchecked Sendable {
    private let lock = NSLock()
    private var _subsystem = "com.loom"
    private var _loggers: [LoomLogCategory: Logger] = LoggerStorage.build(subsystem: "com.loom")

    var subsystem: String {
        lock.lock()
        defer { lock.unlock() }
        return _subsystem
    }

    func configure(subsystem: String) {
        lock.lock()
        defer { lock.unlock() }
        _subsystem = subsystem
        _loggers = Self.build(subsystem: subsystem)
    }

    func logger(for category: LoomLogCategory) -> Logger {
        lock.lock()
        let cached = _loggers[category]
        let sub = _subsystem
        lock.unlock()
        return cached ?? Logger(subsystem: sub, category: category.rawValue)
    }

    private static func build(subsystem: String) -> [LoomLogCategory: Logger] {
        var result: [LoomLogCategory: Logger] = [:]
        for category in LoomLogCategory.knownCategories {
            result[category] = Logger(subsystem: subsystem, category: category.rawValue)
        }
        return result
    }
}
