import Foundation

/// One recorded exchange: an HTTP request and its response, or a connection (a WebSocket, or any
/// other the app reports) with its messages.
public struct NetworkTransaction: Codable, Sendable, Identifiable, Hashable {
    public enum Kind: Codable, Sendable, Hashable {
        case http
        case webSocket
        /// Another kind of connection, named by the app (for example "Nearby").
        case connection(String)

        public var title: String {
            switch self {
            case .http: "HTTP"
            case .webSocket: "WebSocket"
            case .connection(let name): name
            }
        }
    }

    public enum Direction: String, Codable, Sendable {
        case sent
        case received
    }

    /// A message on a connection.
    public struct Message: Codable, Sendable, Hashable, Identifiable {
        public var id: UUID
        public var date: Date
        public var direction: Direction
        public var body: Body
    }

    /// A body, cut at the recorder's limit.
    public struct Body: Codable, Sendable, Hashable {
        public var data: Data
        /// The full size, when `data` was cut or not kept.
        public var size: Int
        public var isTruncated: Bool { data.count < size }

        public init(_ data: Data, limit: Int) {
            self.data = data.count > limit ? data.prefix(limit) : data
            size = data.count
        }
    }

    public var id: UUID
    public var kind: Kind
    /// Each launch of the app has its own ID, so earlier launches can be told apart.
    public var launchID: UUID
    public var startDate: Date
    public var endDate: Date?

    public var url: URL?
    public var method: String?
    public var requestHeaders: [String: String]
    public var requestBody: Body?

    public var statusCode: Int?
    public var responseHeaders: [String: String]
    public var responseBody: Body?
    /// What went wrong, for a failed request or a connection that closed with an error.
    public var errorDescription: String?

    /// A connection's messages, oldest first.
    public var messages: [Message]
    /// What the app said about a connection, such as who is on the other end.
    public var note: String?

    public init(id: UUID = UUID(), kind: Kind, launchID: UUID, startDate: Date = .now, url: URL?, method: String? = nil, requestHeaders: [String: String] = [:]) {
        self.id = id
        self.kind = kind
        self.launchID = launchID
        self.startDate = startDate
        self.url = url
        self.method = method
        self.requestHeaders = requestHeaders
        responseHeaders = [:]
        messages = []
    }

    public var isComplete: Bool { endDate != nil }
    public var duration: TimeInterval? { endDate.map { $0.timeIntervalSince(startDate) } }
    public var isFailure: Bool { errorDescription != nil || (statusCode ?? 0) >= 400 }

    /// Bytes kept for this transaction's bodies and messages.
    var storedBytes: Int {
        (requestBody?.data.count ?? 0) + (responseBody?.data.count ?? 0) + messages.reduce(0) { $0 + $1.body.data.count }
    }

    /// Drops the bodies' data but keeps their sizes, to stay within the recorder's budget.
    mutating func dropBodies() {
        requestBody?.data = Data()
        responseBody?.data = Data()
        for index in messages.indices {
            messages[index].body.data = Data()
        }
    }
}
