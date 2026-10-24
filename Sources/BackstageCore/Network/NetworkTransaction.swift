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

        /// The start of a body that was only kept up to the limit as it arrived.
        init(kept data: Data, size: Int) {
            self.data = data
            self.size = size
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
    /// How Backstage changed this request: "Fake", "Slowed", or the condition that failed it.
    public var simulation: String?

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

    /// The standard wording for a status code ("OK", "Not Found"), or `nil` for one without.
    /// `HTTPURLResponse.localizedString(forStatusCode:)` says "no error" for 200 and "client
    /// error" for 422 and 429.
    public static func reasonPhrase(forStatusCode code: Int) -> String? {
        switch code {
        case 100: "Continue"
        case 101: "Switching Protocols"
        case 200: "OK"
        case 201: "Created"
        case 202: "Accepted"
        case 203: "Non-Authoritative Information"
        case 204: "No Content"
        case 205: "Reset Content"
        case 206: "Partial Content"
        case 300: "Multiple Choices"
        case 301: "Moved Permanently"
        case 302: "Found"
        case 303: "See Other"
        case 304: "Not Modified"
        case 307: "Temporary Redirect"
        case 308: "Permanent Redirect"
        case 400: "Bad Request"
        case 401: "Unauthorized"
        case 402: "Payment Required"
        case 403: "Forbidden"
        case 404: "Not Found"
        case 405: "Method Not Allowed"
        case 406: "Not Acceptable"
        case 407: "Proxy Authentication Required"
        case 408: "Request Timeout"
        case 409: "Conflict"
        case 410: "Gone"
        case 411: "Length Required"
        case 412: "Precondition Failed"
        case 413: "Content Too Large"
        case 414: "URI Too Long"
        case 415: "Unsupported Media Type"
        case 416: "Range Not Satisfiable"
        case 417: "Expectation Failed"
        case 421: "Misdirected Request"
        case 422: "Unprocessable Content"
        case 423: "Locked"
        case 425: "Too Early"
        case 426: "Upgrade Required"
        case 428: "Precondition Required"
        case 429: "Too Many Requests"
        case 431: "Request Header Fields Too Large"
        case 451: "Unavailable For Legal Reasons"
        case 500: "Internal Server Error"
        case 501: "Not Implemented"
        case 502: "Bad Gateway"
        case 503: "Service Unavailable"
        case 504: "Gateway Timeout"
        case 505: "HTTP Version Not Supported"
        default: nil
        }
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
