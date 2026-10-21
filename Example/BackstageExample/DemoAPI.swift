import Backstage
import Foundation
import OSLog

/// A few calls to public test servers, so the Network tab has something of every kind to show.
@Observable
final class DemoAPI {
    static let shared = DemoAPI()

    static let serverKey = "api"
    static let mockDataKey = "mockData"
    static let verboseLoggingKey = "verboseLogging"
    static let production = URL(string: "https://jsonplaceholder.typicode.com")!

    enum Request: String, CaseIterable, Identifiable {
        case user, posts, createPost, image, slow, redirect, notFound, serverError, unreachable

        var id: String { rawValue }

        var title: String {
            switch self {
            case .user: "Load a User"
            case .posts: "Load Posts"
            case .createPost: "Create a Post"
            case .image: "Load an Image"
            case .slow: "Slow Request"
            case .redirect: "Redirect"
            case .notFound: "Not Found"
            case .serverError: "Server Error"
            case .unreachable: "Unreachable Server"
            }
        }

        var systemImage: String {
            switch self {
            case .user: "person"
            case .posts: "list.bullet"
            case .createPost: "square.and.pencil"
            case .image: "photo"
            case .slow: "tortoise"
            case .redirect: "arrow.turn.up.right"
            case .notFound: "questionmark.folder"
            case .serverError: "exclamationmark.triangle"
            case .unreachable: "wifi.slash"
            }
        }
    }

    /// The server chosen in Backstage's App tab, read once at launch.
    let baseURL = Backstage.server(for: serverKey) ?? production
    /// The last result of each request, shown next to it.
    private(set) var results: [Request: String] = [:]
    private(set) var running: Set<Request> = []

    private let session: URLSession
    private let logger = Logger(subsystem: "com.mobinjt.BackstageExample", category: "Network")
    private let testServer = URL(string: "https://httpbingo.org")!

    private init() {
        let configuration = URLSessionConfiguration.default
        configuration.httpAdditionalHeaders = [
            "Authorization": "Bearer demo-session-7c1e9b0d",
            "X-App-Version": "1.0 (1)"
        ]
        // The app's own sessions are recorded with this line.
        Backstage.record(configuration)
        session = URLSession(configuration: configuration)
    }

    func send(_ request: Request) async {
        running.insert(request)
        defer { running.remove(request) }

        if request == .user && Backstage.isOn(Self.mockDataKey) {
            logger.notice("Load a User answered with mock data")
            results[request] = "Mock"
            return
        }

        let urlRequest = makeRequest(request)
        logger.info("\(urlRequest.httpMethod ?? "GET", privacy: .public) \(urlRequest.url?.absoluteString ?? "", privacy: .public)")
        if Backstage.isOn(Self.verboseLoggingKey) {
            logger.debug("Headers: \(urlRequest.allHTTPHeaderFields ?? [:], privacy: .public)")
        }
        let start = Date.now
        do {
            let (data, response) = try await session.data(for: urlRequest)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let milliseconds = Int(Date.now.timeIntervalSince(start) * 1_000)
            if status >= 400 {
                logger.error("\(request.title, privacy: .public) failed with \(status, privacy: .public)")
            } else {
                logger.notice("\(request.title, privacy: .public): \(status, privacy: .public), \(data.count, privacy: .public) bytes in \(milliseconds, privacy: .public) ms")
            }
            results[request] = "\(status)"
        } catch {
            logger.error("\(request.title, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            results[request] = "Failed"
        }
    }

    func sendAll() async {
        await withTaskGroup { group in
            for request in Request.allCases {
                group.addTask { await self.send(request) }
            }
        }
    }

    private func makeRequest(_ request: Request) -> URLRequest {
        switch request {
        case .user:
            return URLRequest(url: baseURL.appending(path: "users/1"))
        case .posts:
            return URLRequest(url: baseURL.appending(path: "posts").appending(queryItems: [URLQueryItem(name: "userId", value: "1")]))
        case .createPost:
            var urlRequest = URLRequest(url: baseURL.appending(path: "posts"))
            urlRequest.httpMethod = "POST"
            urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
            urlRequest.httpBody = Data(#"{"userId":1,"title":"Hello from Backstage","body":"Every call shows up in the panel."}"#.utf8)
            return urlRequest
        case .image:
            return URLRequest(url: testServer.appending(path: "image/png"))
        case .slow:
            return URLRequest(url: testServer.appending(path: "delay/2"))
        case .redirect:
            return URLRequest(url: testServer.appending(path: "redirect/1"))
        case .notFound:
            return URLRequest(url: testServer.appending(path: "status/404"))
        case .serverError:
            return URLRequest(url: testServer.appending(path: "status/500"))
        case .unreachable:
            return URLRequest(url: URL(string: "https://api.example.invalid/v1/status")!)
        }
    }
}
