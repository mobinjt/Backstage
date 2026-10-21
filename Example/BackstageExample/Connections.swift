import Backstage
import Foundation
import OSLog

/// A WebSocket to a public echo server, reported to Backstage with `openConnection`, since the
/// recording protocol doesn't see WebSockets.
@Observable
final class EchoSocket {
    static let url = URL(string: "wss://echo.websocket.org")!

    private(set) var isOpen = false
    private(set) var lastReply: String?

    private var task: URLSessionWebSocketTask?
    private var session: URLSession?
    private var recording: ConnectionRecording?
    private var sentCount = 0
    private let logger = Logger(subsystem: "com.mobinjt.BackstageExample", category: "WebSocket")

    func connect() {
        guard task == nil else { return }
        // `nil` while Backstage is off, so these calls cost nothing in App Store builds.
        let recording = NetworkRecorder.shared.openConnection(kind: .webSocket, url: Self.url, note: "Echo server")
        let session = URLSession(configuration: .default, delegate: SocketEvents(recording: recording), delegateQueue: nil)
        let task = session.webSocketTask(with: Self.url)
        self.recording = recording
        self.session = session
        self.task = task
        isOpen = true
        task.resume()
        logger.info("Connecting to \(Self.url.absoluteString, privacy: .public)")
        Task { await receive(on: task) }
    }

    func sendGreeting() async {
        guard let task else { return }
        sentCount += 1
        let text = #"{"type":"hello","count":\#(sentCount)}"#
        do {
            try await task.send(.string(text))
            recording?.sent(text: text)
        } catch {
            logger.error("Couldn't send: \(error.localizedDescription, privacy: .public)")
        }
    }

    func disconnect() {
        task?.cancel(with: .normalClosure, reason: nil)
        session?.finishTasksAndInvalidate()
        task = nil
        session = nil
        isOpen = false
        logger.info("Disconnected")
    }

    private func receive(on task: URLSessionWebSocketTask) async {
        while let message = try? await task.receive() {
            switch message {
            case .string(let text):
                recording?.received(text: text)
                lastReply = text
            case .data(let data):
                recording?.received(data)
            @unknown default:
                break
            }
        }
        if self.task === task {
            disconnect()
        }
    }
}

/// Tells Backstage when the socket opened and closed.
private nonisolated final class SocketEvents: NSObject, URLSessionWebSocketDelegate, Sendable {
    let recording: ConnectionRecording?

    init(recording: ConnectionRecording?) {
        self.recording = recording
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        let response = webSocketTask.response as? HTTPURLResponse
        let headers = (response?.allHeaderFields ?? [:]).reduce(into: [String: String]()) { $0[String(describing: $1.key)] = String(describing: $1.value) }
        recording?.opened(statusCode: response?.statusCode, headers: headers)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        recording?.closed(error: error)
    }
}

/// Any other connection the app has, such as a Nearby or Bluetooth link, is reported the same
/// way. This one is made up: a peer that says hello and leaves.
enum NearbyPeer {
    static func simulate() async {
        let peer = NetworkRecorder.shared.openConnection(kind: .connection("Nearby"), url: nil, note: "Sam's iPhone")
        peer?.opened()
        let messages: [(sent: Bool, text: String)] = [
            (true, #"{"type":"join","player":"You"}"#),
            (false, #"{"type":"welcome","room":"4821","players":2}"#),
            (true, #"{"type":"ready"}"#),
            (false, #"{"type":"start","round":1}"#)
        ]
        for message in messages {
            try? await Task.sleep(for: .milliseconds(300))
            if message.sent {
                peer?.sent(text: message.text)
            } else {
                peer?.received(text: message.text)
            }
        }
        peer?.closed()
    }
}
