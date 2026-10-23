import CryptoKit
import Foundation
import Synchronization

/// A report iOS collected about the app and handed over through MetricKit, kept as iOS wrote it.
public struct IOSReport: Codable, Sendable, Identifiable, Hashable {
    public enum Kind: String, Codable, Sendable {
        /// Crashes, hangs, CPU or disk-write overuse and slow launches, with call stacks.
        case diagnostics
        /// About a day of launch times, hangs, memory, CPU, disk and time on screen.
        case metrics
    }

    /// The same report always gets the same ID, so one delivered twice is kept once.
    public let id: String
    public let kind: Kind
    public let received: Date
    /// MetricKit's JSON.
    public let json: Data

    public init(kind: Kind, json: Data, received: Date = .now) {
        self.kind = kind
        self.json = json
        self.received = received
        id = Insecure.SHA1.hash(data: json).map { String(format: "%02x", $0) }.joined()
    }

    /// The report's JSON, laid out for reading.
    public var prettyJSON: String {
        guard let object = try? JSONSerialization.jsonObject(with: json),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) else {
            return String(decoding: json, as: UTF8.self)
        }
        return String(decoding: data, as: UTF8.self)
    }
}

/// Keeps the reports iOS delivers, one file each in the app's Caches, for 30 days. Safe to use
/// from any thread.
public final class IOSReportStore: Sendable {
    public static let shared = IOSReportStore(directory: URL.cachesDirectory.appending(path: "Backstage/iOSReports", directoryHint: .isDirectory))

    /// Reports older than this are removed.
    public static let keptFor: TimeInterval = 30 * 24 * 60 * 60

    private let directory: URL
    private let observers = Mutex<[UUID: AsyncStream<Void>.Continuation]>([:])

    init(directory: URL) {
        self.directory = directory
    }

    /// Keeps a report. MetricKit's own go through here; an app can add reports it got another way,
    /// or samples. One already kept is left as it is.
    public func add(_ kind: IOSReport.Kind, json: Data, received: Date = .now) {
        let report = IOSReport(kind: kind, json: json, received: received)
        let file = directory.appending(path: "\(report.id).json")
        guard !FileManager.default.fileExists(atPath: file.path()) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? JSONEncoder().encode(report).write(to: file, options: .atomic)
        changed()
    }

    /// Newest first; older ones are removed on the way.
    public var reports: [IOSReport] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        let decoder = JSONDecoder()
        let oldest = Date.now.addingTimeInterval(-Self.keptFor)
        var reports: [IOSReport] = []
        for file in files where file.pathExtension == "json" {
            guard let report = (try? Data(contentsOf: file)).flatMap({ try? decoder.decode(IOSReport.self, from: $0) }) else { continue }
            if report.received < oldest {
                try? FileManager.default.removeItem(at: file)
            } else {
                reports.append(report)
            }
        }
        return reports.sorted { $0.received > $1.received }
    }

    public func clear() {
        try? FileManager.default.removeItem(at: directory)
        changed()
    }

    /// Fires whenever a report was added or the reports were cleared.
    public func changes() -> AsyncStream<Void> {
        let (stream, continuation) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        let id = UUID()
        observers.withLock { $0[id] = continuation }
        continuation.onTermination = { [weak self] _ in
            self?.observers.withLock { _ = $0.removeValue(forKey: id) }
        }
        return stream
    }

    private func changed() {
        for observer in observers.withLock({ Array($0.values) }) {
            observer.yield()
        }
    }
}
