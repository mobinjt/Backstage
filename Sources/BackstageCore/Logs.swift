import Foundation
import OSLog

/// A message the app logged with `Logger` or `os_log`.
public struct LogEntry: Sendable, Identifiable, Hashable {
    public enum Level: Int, Sendable, Comparable, CaseIterable {
        case debug, info, notice, error, fault

        public static func < (lhs: Level, rhs: Level) -> Bool { lhs.rawValue < rhs.rawValue }

        public var title: String {
            switch self {
            case .debug: "Debug"
            case .info: "Info"
            case .notice: "Notice"
            case .error: "Error"
            case .fault: "Fault"
            }
        }
    }

    public let id: Int
    public let date: Date
    public let level: Level
    public let subsystem: String
    public let category: String
    public let message: String
}

/// Reads this launch's log messages from the system's log store, so apps need no changes to
/// show their `Logger` output.
public enum LogReader {
    /// This launch's messages, oldest first, at most `limit` (the newest ones).
    public static func entries(limit: Int = 5_000) async throws -> [LogEntry] {
        try await Task.detached(priority: .userInitiated) {
            let store = try OSLogStore(scope: .currentProcessIdentifier)
            var entries: [LogEntry] = []
            var index = 0
            for case let entry as OSLogEntryLog in try store.getEntries() {
                entries.append(LogEntry(
                    id: index,
                    date: entry.date,
                    level: Self.level(entry.level),
                    subsystem: entry.subsystem,
                    category: entry.category,
                    message: entry.composedMessage
                ))
                index += 1
            }
            return entries.count > limit ? Array(entries.suffix(limit)) : entries
        }.value
    }

    private static func level(_ level: OSLogEntryLog.Level) -> LogEntry.Level {
        switch level {
        case .debug: .debug
        case .info: .info
        case .notice: .notice
        case .error: .error
        case .fault: .fault
        default: .info
        }
    }
}
