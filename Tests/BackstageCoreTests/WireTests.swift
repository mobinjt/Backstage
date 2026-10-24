import Foundation
import Network
import Synchronization
import Testing
@testable import BackstageCore

/// A one-request HTTP server on localhost that keeps the raw bytes it received.
final class RawHTTPServer: @unchecked Sendable {
    private let listener: NWListener
    let received = Mutex(Data())
    private(set) var port: UInt16 = 0

    init() throws {
        listener = try NWListener(using: .tcp, on: .any)
    }

    func start() async throws {
        let ready = AsyncStream<UInt16>.makeStream()
        listener.stateUpdateHandler = { [listener] state in
            if case .ready = state, let port = listener.port?.rawValue { ready.continuation.yield(port) }
        }
        listener.newConnectionHandler = { [weak self] connection in
            connection.start(queue: .global())
            self?.read(connection)
        }
        listener.start(queue: .global())
        for await port in ready.stream {
            self.port = port
            return
        }
    }

    private func read(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data { received.withLock { $0.append(data) } }
            if hasWholeRequest() {
                let reply = "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nContent-Type: application/json\r\nConnection: close\r\n\r\n{}"
                connection.send(content: Data(reply.utf8), completion: .contentProcessed { _ in connection.cancel() })
            } else if !isComplete, error == nil {
                read(connection)
            }
        }
    }

    /// Headers done and as many body bytes as Content-Length says.
    private func hasWholeRequest() -> Bool {
        let text = String(decoding: received.withLock { $0 }, as: UTF8.self)
        guard let end = text.range(of: "\r\n\r\n") else { return false }
        let length = text[..<end.lowerBound].split(separator: "\r\n")
            .first { $0.lowercased().hasPrefix("content-length:") }
            .flatMap { Int($0.split(separator: ":")[1].trimmingCharacters(in: .whitespaces)) } ?? 0
        return text.utf8.count - text[..<end.upperBound].utf8.count >= length
    }

    func stop() {
        listener.cancel()
    }
}

/// What actually goes over the wire, in the same serialized suite as the other recording tests:
/// they all change the shared forwarding session and recorder.
extension SharedStateTests.RecordingURLProtocolTests {
    @Test func aRecordedRequestsBodyReachesTheServer() async throws {
        let server = try RawHTTPServer()
        try await server.start()
        defer { server.stop() }
        RecordingURLProtocol.forwardingConfiguration = {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = (configuration.protocolClasses ?? []).filter { $0 != RecordingURLProtocol.self }
            return configuration
        }()
        RecordingURLProtocol.resetForwarder()
        NetworkRecorder.shared.setRecording(true, purge: true)
        defer { NetworkRecorder.shared.setRecording(false, purge: true) }

        let configuration = URLSessionConfiguration.ephemeral
        Backstage.record(configuration)
        let session = URLSession(configuration: configuration)
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(server.port)/v1/me/profile")!)
        request.httpMethod = "PUT"
        request.httpBody = Data(#"{"displayName":"Sara","avatarID":"cat"}"#.utf8)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        _ = try await session.data(for: request)

        let raw = String(decoding: server.received.withLock { $0 }, as: UTF8.self)
        #expect(raw.contains(#"{"displayName":"Sara","avatarID":"cat"}"#), "The body arrives: \(raw)")
    }

    @Test func anUploadsBodyReachesTheServer() async throws {
        let server = try RawHTTPServer()
        try await server.start()
        defer { server.stop() }
        RecordingURLProtocol.forwardingConfiguration = {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = (configuration.protocolClasses ?? []).filter { $0 != RecordingURLProtocol.self }
            return configuration
        }()
        RecordingURLProtocol.resetForwarder()
        NetworkRecorder.shared.setRecording(true, purge: true)
        defer { NetworkRecorder.shared.setRecording(false, purge: true) }

        let configuration = URLSessionConfiguration.ephemeral
        Backstage.record(configuration)
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(server.port)/v1/upload")!)
        request.httpMethod = "POST"
        _ = try await URLSession(configuration: configuration).upload(for: request, from: Data("hello upload".utf8))

        let raw = String(decoding: server.received.withLock { $0 }, as: UTF8.self)
        #expect(raw.contains("hello upload"), "The body arrives: \(raw)")
    }
}
