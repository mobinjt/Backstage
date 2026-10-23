import Foundation
import Synchronization

/// A slow or failing network, and fake responses, for the requests Backstage records. Only while
/// Backstage is on: the recording protocol is the only thing that asks it.
///
/// The condition lasts until the app is relaunched; fake responses are kept in a file.
public final class NetworkSimulator: Sendable {
    public static let shared = NetworkSimulator(file: URL.applicationSupportDirectory
        .appending(path: (Bundle.main.bundleIdentifier ?? "app") + "/Backstage/Fakes.json"))

    /// How the network behaves.
    public struct Condition: Codable, Sendable, Hashable {
        public var name: String
        /// Before a response starts.
        public var delay: TimeInterval
        /// The speed responses arrive at; `nil` for no limit.
        public var bytesPerSecond: Int?
        /// From 0 to 1: the share of requests that fail as if the connection dropped.
        public var failureRate: Double
        /// Every request fails as if there were no connection.
        public var isOffline: Bool
        /// Only requests to this host; `nil` for every host.
        public var host: String?

        public init(name: String, delay: TimeInterval = 0, bytesPerSecond: Int? = nil, failureRate: Double = 0, isOffline: Bool = false, host: String? = nil) {
            self.name = name
            self.delay = delay
            self.bytesPerSecond = bytesPerSecond
            self.failureRate = failureRate
            self.isOffline = isOffline
            self.host = host
        }

        public static let slow3G = Condition(name: "Slow 3G", delay: 2, bytesPerSecond: 50_000)
        public static let flaky = Condition(name: "Flaky", delay: 0.8, failureRate: 0.2)
        public static let offline = Condition(name: "Offline", isOffline: true)
        public static let presets = [slow3G, flaky, offline]

        func applies(to url: URL?) -> Bool {
            guard let host else { return true }
            return url?.host()?.lowercased() == host.lowercased()
        }
    }

    /// A rule that answers matching requests itself, without reaching the server.
    public struct Fake: Codable, Sendable, Hashable, Identifiable {
        /// How the fake answers.
        public enum Answer: Codable, Sendable, Hashable {
            case response(status: Int, headers: [String: String], body: Data)
            case failure(Failure)
        }

        /// A request that fails the way a real network can.
        public enum Failure: String, Codable, Sendable, Hashable, CaseIterable {
            case timedOut, offline, cannotConnect, connectionLost

            public var title: String {
                switch self {
                case .timedOut: "Timed out"
                case .offline: "No connection"
                case .cannotConnect: "Can't reach the server"
                case .connectionLost: "Connection lost"
                }
            }

            var code: URLError.Code {
                switch self {
                case .timedOut: .timedOut
                case .offline: .notConnectedToInternet
                case .cannotConnect: .cannotConnectToHost
                case .connectionLost: .networkConnectionLost
                }
            }
        }

        public var id: UUID
        public var name: String
        public var isOn: Bool
        /// "GET", "POST"…; `nil` for any method.
        public var method: String?
        /// The URL it answers, where `*` stands for anything. Without a `?`, the query is ignored.
        public var urlPattern: String
        public var answer: Answer
        /// Before the answer.
        public var delay: TimeInterval

        public init(id: UUID = UUID(), name: String, isOn: Bool = true, method: String? = nil, urlPattern: String, answer: Answer, delay: TimeInterval = 0) {
            self.id = id
            self.name = name
            self.isOn = isOn
            self.method = method
            self.urlPattern = urlPattern
            self.answer = answer
            self.delay = delay
        }

        /// A fake that answers like a recorded response, ready to be changed.
        public init(answering transaction: NetworkTransaction) {
            let url = transaction.url
            var pattern = url?.absoluteString ?? "*"
            if let query = url?.query(), !query.isEmpty, let index = pattern.firstIndex(of: "?") {
                pattern = String(pattern[..<index])
            }
            // The body is kept decoded, so its encoding and length no longer apply.
            let headers = transaction.responseHeaders.filter { !["content-encoding", "content-length", "transfer-encoding"].contains($0.key.lowercased()) }
            self.init(
                name: "\(transaction.method ?? "GET") \(url?.path() ?? "")",
                method: transaction.method,
                urlPattern: pattern,
                answer: .response(status: transaction.statusCode ?? 200, headers: headers, body: transaction.responseBody?.data ?? Data())
            )
        }

        public func matches(_ request: URLRequest) -> Bool {
            guard isOn, let url = request.url else { return false }
            if let method, method.uppercased() != (request.httpMethod ?? "GET").uppercased() { return false }
            return Self.pattern(urlPattern, matches: url)
        }

        /// `*` stands for anything; the rest must match as written, without case. Without a `?`
        /// in the pattern, the URL's query is left out.
        static func pattern(_ pattern: String, matches url: URL) -> Bool {
            var text = url.absoluteString
            if !pattern.contains("?"), let index = text.firstIndex(of: "?") {
                text = String(text[..<index])
            }
            let parts = pattern.split(separator: "*", omittingEmptySubsequences: false).map { NSRegularExpression.escapedPattern(for: String($0)) }
            guard let expression = try? NSRegularExpression(pattern: "^" + parts.joined(separator: ".*") + "$", options: [.caseInsensitive]) else { return false }
            return expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
        }
    }

    /// What happens to one request.
    enum Plan {
        case forward(delay: TimeInterval, bytesPerSecond: Int?)
        case fake(Fake)
        case fail(URLError.Code, delay: TimeInterval, reason: String)

        /// Shown on the recorded request.
        var label: String? {
            switch self {
            case .forward(let delay, let speed): delay > 0 || speed != nil ? "Slowed" : nil
            case .fake: "Fake"
            case .fail(_, _, let reason): reason
            }
        }
    }

    private struct State {
        var condition: Condition?
        var fakes: [Fake]?
        var file: URL?
    }

    private let state: Mutex<State>

    init(file: URL?) {
        state = Mutex(State(file: file))
    }

    // MARK: Condition

    /// How the network behaves now; `nil` for as it is. Not kept across launches.
    public var condition: Condition? {
        get { state.withLock { $0.condition } }
        set { state.withLock { $0.condition = newValue } }
    }

    // MARK: Fakes

    /// The fake responses, first match wins.
    public var fakes: [Fake] {
        state.withLock { state in loadedFakes(&state) }
    }

    public func setFakes(_ fakes: [Fake]) {
        let file = state.withLock { state in
            state.fakes = fakes
            return state.file
        }
        guard let file else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(fakes).write(to: file, options: .atomic)
    }

    private func loadedFakes(_ state: inout State) -> [Fake] {
        if let fakes = state.fakes { return fakes }
        let loaded = state.file.flatMap { try? Data(contentsOf: $0) }.flatMap { try? JSONDecoder().decode([Fake].self, from: $0) } ?? []
        state.fakes = loaded
        return loaded
    }

    /// For tests: keep fakes in another file, or in memory only.
    func useFile(_ file: URL?) {
        state.withLock { state in
            state.file = file
            state.fakes = nil
        }
    }

    // MARK: Deciding

    /// What to do with a request: a matching fake first, then the condition.
    func plan(for request: URLRequest, random: () -> Double = { Double.random(in: 0..<1) }) -> Plan {
        let (fakes, condition) = state.withLock { state in (loadedFakes(&state), state.condition) }
        if let fake = fakes.first(where: { $0.matches(request) }) {
            return .fake(fake)
        }
        guard let condition, condition.applies(to: request.url) else {
            return .forward(delay: 0, bytesPerSecond: nil)
        }
        if condition.isOffline {
            return .fail(.notConnectedToInternet, delay: condition.delay, reason: condition.name)
        }
        if condition.failureRate > 0 && random() < condition.failureRate {
            return .fail(.networkConnectionLost, delay: condition.delay, reason: condition.name)
        }
        return .forward(delay: condition.delay, bytesPerSecond: condition.bytesPerSecond)
    }
}
