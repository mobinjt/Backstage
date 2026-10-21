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
    /// The library or executable that logged it, such as "UIKitCore".
    public let sender: String
    /// Logged by the app's own code rather than the system's.
    public let isFromApp: Bool
}

/// Reads this launch's log messages from the system's log store, so apps need no changes to
/// show their `Logger` output.
public enum LogReader {
    /// This launch's messages, oldest first, at most `limit` (the newest ones).
    public static func entries(limit: Int = 5_000) async throws -> [LogEntry] {
        try await Task.detached(priority: .userInitiated) {
            let store = try OSLogStore(scope: .currentProcessIdentifier)
            let appImages = Self.appImageNames
            var entries: [LogEntry] = []
            var index = 0
            for case let entry as OSLogEntryLog in try store.getEntries() {
                entries.append(LogEntry(
                    id: index,
                    date: entry.date,
                    level: Self.level(entry.level),
                    subsystem: entry.subsystem,
                    category: entry.category,
                    message: entry.composedMessage,
                    sender: entry.sender,
                    isFromApp: Self.isFromApp(sender: entry.sender, subsystem: entry.subsystem, appImages: appImages)
                ))
                index += 1
            }
            return entries.count > limit ? Array(entries.suffix(limit)) : entries
        }.value
    }

    /// Whether a message came from the app's own code: its executable (packages are linked into
    /// it), its embedded frameworks, or `NSLog`, which logs as Foundation without a subsystem.
    static func isFromApp(sender: String, subsystem: String, appImages: Set<String>) -> Bool {
        appImages.contains(sender) || (sender == "Foundation" && subsystem.isEmpty)
    }

    /// The names the app's own code logs under: the executable, the `.debug.dylib` Xcode puts a
    /// Debug build's code in, and the frameworks and libraries in the app.
    static var appImageNames: Set<String> {
        var names: Set<String> = []
        if let executable = Bundle.main.executableURL?.lastPathComponent {
            names.insert(executable)
            names.insert(executable + ".debug.dylib")
        }
        if let frameworks = Bundle.main.privateFrameworksURL,
           let contents = try? FileManager.default.contentsOfDirectory(at: frameworks, includingPropertiesForKeys: nil) {
            for item in contents {
                // "Purchases.framework" logs as "Purchases"; a bare library keeps its extension.
                names.insert(item.pathExtension == "framework" ? item.deletingPathExtension().lastPathComponent : item.lastPathComponent)
            }
        }
        return names
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
