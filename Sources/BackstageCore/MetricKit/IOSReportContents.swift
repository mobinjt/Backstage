import Foundation

/// One problem from a diagnostics report: a crash, a hang, CPU or disk-write overuse, or a slow
/// launch.
public struct IOSDiagnostic: Sendable, Identifiable, Hashable {
    public enum Kind: String, Sendable, CaseIterable {
        case crash, hang, cpu, diskWrites, launch

        public var title: String {
            switch self {
            case .crash: "Crash"
            case .hang: "Hang"
            case .cpu: "Too much CPU"
            case .diskWrites: "Too many disk writes"
            case .launch: "Slow launch"
            }
        }

        /// MetricKit's key for this kind's list.
        var key: String {
            switch self {
            case .crash: "crashDiagnostics"
            case .hang: "hangDiagnostics"
            case .cpu: "cpuExceptionDiagnostics"
            case .diskWrites: "diskWriteExceptionDiagnostics"
            case .launch: "appLaunchDiagnostics"
            }
        }
    }

    /// A frame of a call stack: where in which binary.
    public struct Frame: Sendable, Hashable {
        public let binary: String
        public let offset: Int
        public let address: Int
        /// How far down the tree, for indenting.
        public let depth: Int
        public let samples: Int

        /// "MyApp + 0x1a2b", the form symbolication tools take.
        public var text: String { "\(binary) + 0x\(String(offset, radix: 16))" }
    }

    public let id: String
    public let kind: Kind
    /// When the report's period ended, or when it arrived.
    public let date: Date
    /// "SIGSEGV", "Hung for 3.5 s"…
    public let summary: String
    /// Everything MetricKit says about it, as written.
    public let details: [(key: String, value: String)]
    /// The thread it's about first.
    public let callStack: [Frame]

    public static func == (lhs: IOSDiagnostic, rhs: IOSDiagnostic) -> Bool { lhs.id == rhs.id }
    public func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// The key numbers of a daily metrics report.
public struct IOSDailySummary: Sendable, Hashable {
    public let begin: Date?
    public let end: Date?
    public let appVersion: String?
    /// Each a value as MetricKit wrote it, such as "1,200 ms" or "180,000 kB", by name.
    public let values: [(name: String, value: String)]

    public static func == (lhs: IOSDailySummary, rhs: IOSDailySummary) -> Bool {
        lhs.begin == rhs.begin && lhs.end == rhs.end && lhs.values.map(\.value) == rhs.values.map(\.value)
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(begin)
        hasher.combine(end)
    }
}

extension IOSReport {
    private var object: [String: Any] {
        (try? JSONSerialization.jsonObject(with: json)) as? [String: Any] ?? [:]
    }

    /// The problems in a diagnostics report; none in a metrics report.
    public var diagnostics: [IOSDiagnostic] {
        guard kind == .diagnostics else { return [] }
        let object = object
        let date = Self.date(object["timeStampEnd"]) ?? received
        return IOSDiagnostic.Kind.allCases.flatMap { kind in
            ((object[kind.key] as? [[String: Any]]) ?? []).enumerated().map { index, item in
                let meta = (item["diagnosticMetaData"] as? [String: Any]) ?? [:]
                return IOSDiagnostic(
                    id: "\(id)-\(kind.rawValue)-\(index)",
                    kind: kind,
                    date: date,
                    summary: Self.summary(kind, meta),
                    details: meta.map { ($0.key, Self.text($0.value)) }.sorted { $0.key < $1.key },
                    callStack: Self.frames(item["callStackTree"] as? [String: Any])
                )
            }
        }
    }

    /// The key numbers of a metrics report; `nil` for a diagnostics report.
    public var dailySummary: IOSDailySummary? {
        guard kind == .metrics else { return nil }
        let object = object
        func value(_ path: String...) -> Any? {
            path.reduce(object as Any?) { ($0 as? [String: Any])?[$1] }
        }
        var values: [(String, String)] = []
        if let launch = Self.typical(value("applicationLaunchMetrics", "histogrammedTimeToFirstDrawKey")) {
            values.append(("Typical launch", launch))
        }
        if let hangs = Self.typical(value("applicationResponsivenessMetrics", "histogrammedAppHangTime")) {
            values.append(("Typical hang", hangs))
        }
        let named: [(String, [String])] = [
            ("Peak memory", ["memoryMetrics", "peakMemoryUsage"]),
            ("CPU time", ["cpuMetrics", "cumulativeCPUTime"]),
            ("Disk writes", ["diskIOMetrics", "cumulativeLogicalWrites"]),
            ("On screen", ["applicationTimeMetrics", "cumulativeForegroundTime"]),
            ("In the background", ["applicationTimeMetrics", "cumulativeBackgroundTime"]),
            ("Cellular data", ["networkTransferMetrics", "cumulativeCellularDownload"]),
            ("Wi-Fi data", ["networkTransferMetrics", "cumulativeWifiDownload"])
        ]
        for (name, path) in named {
            if let found = path.reduce(object as Any?, { ($0 as? [String: Any])?[$1] }) {
                values.append((name, Self.text(found)))
            }
        }
        return IOSDailySummary(
            begin: Self.date(object["timeStampBegin"]),
            end: Self.date(object["timeStampEnd"]),
            appVersion: (object["appVersion"] as? String) ?? (value("metaData", "appBuildVersion") as? String),
            values: values
        )
    }

    // MARK: Reading MetricKit's JSON

    private static func summary(_ kind: IOSDiagnostic.Kind, _ meta: [String: Any]) -> String {
        switch kind {
        case .crash:
            if let reason = (meta["objectiveCexceptionReason"] as? [String: Any])?["composedMessage"] as? String { return reason }
            if let reason = meta["terminationReason"] as? String, !reason.isEmpty { return reason }
            if let signal = meta["signal"].map(text) { return signalName(signal) }
            return meta["exceptionType"].map { "Exception \(text($0))" } ?? "Crash"
        case .hang: return meta["hangDuration"].map { "Hung for \(text($0))" } ?? "Hang"
        case .cpu: return meta["totalCPUTime"].map { "\(text($0)) of CPU" } ?? "Too much CPU"
        case .diskWrites: return meta["writesCaused"].map { "\(text($0)) written" } ?? "Too many disk writes"
        case .launch: return meta["launchDuration"].map { "Took \(text($0))" } ?? "Slow launch"
        }
    }

    /// "SIGSEGV" for 11, and the other common ones.
    private static func signalName(_ number: String) -> String {
        let names = ["4": "SIGILL", "5": "SIGTRAP", "6": "SIGABRT", "8": "SIGFPE", "9": "SIGKILL", "10": "SIGBUS", "11": "SIGSEGV", "13": "SIGPIPE"]
        return names[number].map { "\($0) (signal \(number))" } ?? "Signal \(number)"
    }

    /// The frames of the thread the problem is about, or else the first, depth first.
    private static func frames(_ tree: [String: Any]?) -> [IOSDiagnostic.Frame] {
        let stacks = (tree?["callStacks"] as? [[String: Any]]) ?? []
        let stack = stacks.first { ($0["threadAttributed"] as? Bool) == true } ?? stacks.first
        var frames: [IOSDiagnostic.Frame] = []
        func walk(_ items: [[String: Any]], depth: Int) {
            for item in items where frames.count < 500 {
                frames.append(IOSDiagnostic.Frame(
                    binary: (item["binaryName"] as? String) ?? "?",
                    offset: (item["offsetIntoBinaryTextSegment"] as? Int) ?? 0,
                    address: (item["address"] as? Int) ?? 0,
                    depth: depth,
                    samples: (item["sampleCount"] as? Int) ?? 1
                ))
                walk((item["subFrames"] as? [[String: Any]]) ?? [], depth: depth + 1)
            }
        }
        walk((stack?["callStackRootFrames"] as? [[String: Any]]) ?? [], depth: 0)
        return frames
    }

    /// The bucket most samples fall in, such as "1,000–1,010 ms".
    private static func typical(_ histogram: Any?) -> String? {
        guard let buckets = ((histogram as? [String: Any])?["histogramValue"] as? [String: Any])?.values.compactMap({ $0 as? [String: Any] }),
              let top = buckets.max(by: { (($0["bucketCount"] as? Int) ?? 0) < (($1["bucketCount"] as? Int) ?? 0) }),
              let start = top["bucketStart"].map(text) else { return nil }
        guard let end = top["bucketEnd"].map(text), end != start else { return start }
        // "1000 ms" and "1010 ms" read as "1000–1010 ms".
        let startNumber = start.split(separator: " ").first.map(String.init) ?? start
        return "\(startNumber)–\(end)"
    }

    static func text(_ value: Any) -> String {
        switch value {
        case let string as String: string
        case let number as NSNumber: number.stringValue
        case let dictionary as [String: Any]:
            dictionary.sorted { $0.key < $1.key }.map { "\($0.key): \(text($0.value))" }.joined(separator: ", ")
        case let array as [Any]: array.map(text).joined(separator: ", ")
        default: String(describing: value)
        }
    }

    /// MetricKit writes dates like "2026-10-22 23:59:00" in local time.
    static func date(_ value: Any?) -> Date? {
        guard let text = value as? String else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        for format in ["yyyy-MM-dd HH:mm:ss Z", "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd'T'HH:mm:ssZ"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: text) { return date }
        }
        return nil
    }
}
