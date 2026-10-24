import Foundation
import Synchronization

/// Records HTTP calls: it takes each request while Backstage records, sends it on its own session,
/// and passes everything back to the app's task unchanged while noting it down. It also plays the
/// `NetworkSimulator`'s part: a fake response, a failure, or a slower answer.
///
/// It doesn't see WebSocket tasks or background sessions; the app reports WebSockets through
/// `NetworkRecorder.openConnection`.
public final class RecordingURLProtocol: URLProtocol, @unchecked Sendable {
    private static let handledKey = "Backstage.RecordingURLProtocol.handled"

    /// The session requests are sent on. Like `URLSession.shared`, it uses the shared cookies,
    /// cache and credentials, so signing in with a cookie works as without Backstage. Tests
    /// replace its configuration.
    nonisolated(unsafe) static var forwardingConfiguration: URLSessionConfiguration = {
        let configuration = URLSessionConfiguration.default
        configuration.protocolClasses = (configuration.protocolClasses ?? []).filter { $0 != RecordingURLProtocol.self }
        return configuration
    }()

    private static let forwarder = Mutex<Forwarder?>(nil)

    private static var sharedForwarder: Forwarder {
        forwarder.withLock { forwarder in
            if let forwarder { return forwarder }
            let created = Forwarder(configuration: forwardingConfiguration)
            forwarder = created
            return created
        }
    }

    /// For tests: forget the forwarding session so the next request makes one from
    /// `forwardingConfiguration`.
    static func resetForwarder() {
        forwarder.withLock { $0 = nil }
    }

    var recorder: NetworkRecorder { .shared }
    private let loading = Mutex<Loading?>(nil)
    /// The thread that started loading; the app's task expects every callback there.
    private var clientRunLoop: CFRunLoop?
    private var clientModes: [CFString] = []
    /// Events reach the app in order through here, held back for a simulated delay or speed.
    private let deliveries = DispatchQueue(label: "Backstage.RecordingURLProtocol.deliveries")
    private let pacing = Mutex(Pacing())
    /// The forwarding session's answer to a server challenge, waiting for the app's.
    private let pendingChallenge = Mutex<(@Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void)?>(nil)

    private struct Loading {
        /// `nil` for a fake or a simulated failure, which never reach the server.
        let task: URLSessionDataTask?
        let transactionID: UUID
        var response: URLResponse?
        /// Kept up to the recorder's limit; the rest only reaches the app.
        var body = Data()
        var bodySize = 0
        var isFinished = false
    }

    private struct Pacing {
        var bytesPerSecond: Int?
        /// When the next event may reach the app.
        var next = DispatchTime.now()
        var isStopped = false
        /// Events not delivered yet, in order; each runs once it and those before it are due.
        var waiting: [(deadline: DispatchTime, work: @Sendable () -> Void)] = []
    }

    // MARK: URLProtocol

    override public class func canInit(with request: URLRequest) -> Bool {
        guard NetworkRecorder.shared.isRecording,
              let scheme = request.url?.scheme?.lowercased(), scheme == "http" || scheme == "https",
              request.value(forHTTPHeaderField: "Upgrade")?.lowercased() != "websocket",
              property(forKey: handledKey, in: request) == nil else { return false }
        return true
    }

    /// WebSocket tasks are left alone: their handshake arrives as an `https` request, and sending
    /// it on as a plain request would break the socket.
    override public class func canInit(with task: URLSessionTask) -> Bool {
        guard !(task is URLSessionWebSocketTask), let request = task.currentRequest else { return false }
        return canInit(with: request)
    }

    override public class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override public func startLoading() {
        clientRunLoop = CFRunLoopGetCurrent()
        clientModes = [CFRunLoopMode.defaultMode.rawValue]
        if let mode = RunLoop.current.currentMode, mode != .default {
            clientModes.append(mode.rawValue as CFString)
        }
        var forwarded = request
        let body = Self.body(of: request)
        if let body {
            // A request keeps one body: setting the stream, even to nil, clears `httpBody`, so the
            // stream goes first.
            forwarded.httpBodyStream = nil
            forwarded.httpBody = body
        }
        let mutable = (forwarded as NSURLRequest).mutableCopy() as! NSMutableURLRequest
        URLProtocol.setProperty(true, forKey: Self.handledKey, in: mutable)
        forwarded = mutable as URLRequest

        let limit = recorder.limits.maximumBodySize
        var transaction = NetworkTransaction(
            kind: .http,
            launchID: recorder.launchID,
            url: request.url,
            method: request.httpMethod ?? "GET",
            requestHeaders: request.allHTTPHeaderFields ?? [:]
        )
        transaction.requestBody = body.map { NetworkTransaction.Body($0, limit: limit) }
        let plan = NetworkSimulator.shared.plan(for: request)
        transaction.simulation = plan.label
        recorder.add(transaction)

        switch plan {
        case .forward(let delay, let bytesPerSecond):
            pacing.withLock { pacing in
                pacing.bytesPerSecond = bytesPerSecond
                pacing.next = .now() + delay
            }
            let task = Self.sharedForwarder.dataTask(with: forwarded, for: self)
            loading.withLock { $0 = Loading(task: task, transactionID: transaction.id) }
            task.resume()
        case .fake(let fake):
            loading.withLock { $0 = Loading(task: nil, transactionID: transaction.id) }
            pacing.withLock { $0.next = .now() + fake.delay }
            answer(with: fake)
        case .fail(let code, let delay, _):
            loading.withLock { $0 = Loading(task: nil, transactionID: transaction.id) }
            pacing.withLock { $0.next = .now() + delay }
            didComplete(with: failure(code))
        }
    }

    override public func stopLoading() {
        let task = loading.withLock { $0?.task }
        pacing.withLock { $0.isStopped = true }
        answerChallenge(.cancelAuthenticationChallenge, nil)
        task?.cancel()
        // Events still held back won't reach the app now; the request ends here.
        finish(error: URLError(.cancelled), redirectedTo: nil)
    }

    // MARK: Simulating

    private func answer(with fake: NetworkSimulator.Fake) {
        guard let url = request.url else { return }
        switch fake.answer {
        case .response(let status, let headers, let body):
            if let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers) {
                didReceive(response)
            }
            if !body.isEmpty {
                didReceive(body)
            }
            didComplete(with: nil)
        case .failure(let failure):
            didComplete(with: self.failure(failure.code))
        }
    }

    private func failure(_ code: URLError.Code) -> URLError {
        var info: [String: Any] = [:]
        if let url = request.url {
            info[NSURLErrorFailingURLErrorKey] = url
            info[NSURLErrorFailingURLStringErrorKey] = url.absoluteString
        }
        return URLError(code, userInfo: info)
    }

    /// Runs `work` after the events before it, and later still when the speed is limited and
    /// `bytes` have to arrive first.
    private func deliver(bytes: Int = 0, _ work: @escaping @Sendable () -> Void) {
        let deadline = pacing.withLock { pacing -> DispatchTime in
            let start = max(pacing.next, .now())
            if let speed = pacing.bytesPerSecond, speed > 0, bytes > 0 {
                pacing.next = start + Double(bytes) / Double(speed)
            } else {
                pacing.next = start
            }
            pacing.waiting.append((pacing.next, work))
            return pacing.next
        }
        // Timers due at the same moment may fire in any order, so each one runs whatever is due
        // from the front of the line, keeping the events in order.
        deliveries.asyncAfter(deadline: deadline) { [self] in
            let due = pacing.withLock { pacing -> [@Sendable () -> Void] in
                guard !pacing.isStopped else { return [] }
                let now = DispatchTime.now()
                let count = pacing.waiting.prefix { $0.deadline <= now }.count
                defer { pacing.waiting.removeFirst(count) }
                return pacing.waiting.prefix(count).map(\.work)
            }
            due.forEach { $0() }
        }
    }

    /// A body in pieces of a tenth of a second each at a limited speed, so it arrives steadily.
    private func pieces(of data: Data) -> [Data] {
        guard let speed = pacing.withLock({ $0.bytesPerSecond }), speed > 0 else { return [data] }
        let size = max(speed / 10, 1_024)
        return stride(from: 0, to: data.count, by: size).map { data.subdata(in: $0..<min($0 + size, data.count)) }
    }

    /// The request's body, also when it was given as a stream (as `URLSession` does for uploads).
    private static func body(of request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16_384)
        // Until the end (0) or an error (-1). A stream the app is still writing to, as for a
        // streamed upload, waits for the rest rather than looking empty.
        while true {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }

    // MARK: Forwarded events

    private func onClientThread(_ work: @escaping @Sendable () -> Void) {
        guard let clientRunLoop else { return work() }
        CFRunLoopPerformBlock(clientRunLoop, clientModes as CFArray, work)
        CFRunLoopWakeUp(clientRunLoop)
    }

    fileprivate func didReceive(_ response: URLResponse) {
        deliver { [self] in
            loading.withLock { $0?.response = response }
            onClientThread { [self] in client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed) }
        }
    }

    fileprivate func didReceive(_ data: Data) {
        let limit = recorder.limits.maximumBodySize
        for piece in pieces(of: data) {
            deliver(bytes: piece.count) { [self] in
                loading.withLock { loading in
                    guard var current = loading else { return }
                    current.bodySize += piece.count
                    let room = limit - current.body.count
                    if room > 0 { current.body.append(piece.prefix(room)) }
                    loading = current
                }
                onClientThread { [self] in client?.urlProtocol(self, didLoad: piece) }
            }
        }
    }

    /// A server challenge, such as its certificate to check or a password to give, goes to the
    /// app's own session, whose delegate answers as if it talked to the server itself.
    fileprivate func didReceive(_ challenge: URLAuthenticationChallenge, completion: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        pendingChallenge.withLock { $0 = completion }
        let forwarded = URLAuthenticationChallenge(authenticationChallenge: challenge, sender: self)
        onClientThread { [self] in client?.urlProtocol(self, didReceive: forwarded) }
    }

    private func answerChallenge(_ disposition: URLSession.AuthChallengeDisposition, _ credential: URLCredential?) {
        let completion = pendingChallenge.withLock { pending in
            defer { pending = nil }
            return pending
        }
        completion?(disposition, credential)
    }

    fileprivate func wasRedirected(to request: URLRequest, by response: HTTPURLResponse) {
        deliver { [self] in
            // Recorded as its own transaction; the app's session follows the redirect with a new
            // request, which this protocol records again.
            loading.withLock { $0?.response = response }
            finish(error: nil, redirectedTo: request.url)
            // The new request carries the mark that this one was sent on already; without it,
            // it's recorded like any other.
            let mutable = (request as NSURLRequest).mutableCopy() as! NSMutableURLRequest
            URLProtocol.removeProperty(forKey: Self.handledKey, in: mutable)
            let next = mutable as URLRequest
            onClientThread { [self] in client?.urlProtocol(self, wasRedirectedTo: next, redirectResponse: response) }
        }
    }

    fileprivate func didComplete(with error: (any Error)?) {
        deliver { [self] in
            finish(error: error, redirectedTo: nil)
            onClientThread { [self] in
                if let error {
                    client?.urlProtocol(self, didFailWithError: error)
                } else {
                    client?.urlProtocolDidFinishLoading(self)
                }
            }
        }
    }

    /// Notes how the request ended, once.
    private func finish(error: (any Error)?, redirectedTo: URL?) {
        let loading = loading.withLock { loading -> Loading? in
            guard let current = loading, !current.isFinished else { return nil }
            loading?.isFinished = true
            return current
        }
        guard let loading else { return }
        recorder.update(loading.transactionID) { transaction in
            transaction.endDate = .now
            if let response = loading.response as? HTTPURLResponse {
                transaction.statusCode = response.statusCode
                transaction.responseHeaders = response.allHeaderFields.reduce(into: [:]) { headers, field in
                    headers[String(describing: field.key)] = String(describing: field.value)
                }
            }
            if loading.bodySize > 0 {
                transaction.responseBody = NetworkTransaction.Body(kept: loading.body, size: loading.bodySize)
            }
            if let error {
                transaction.errorDescription = (error as NSError).localizedDescription
            } else if let redirectedTo {
                transaction.note = "Redirected to \(redirectedTo.absoluteString)"
            }
        }
    }
}

/// The app's answer to a forwarded server challenge.
extension RecordingURLProtocol: URLAuthenticationChallengeSender {
    public func use(_ credential: URLCredential, for challenge: URLAuthenticationChallenge) {
        answerChallenge(.useCredential, credential)
    }

    public func continueWithoutCredential(for challenge: URLAuthenticationChallenge) {
        answerChallenge(.useCredential, nil)
    }

    public func cancel(_ challenge: URLAuthenticationChallenge) {
        answerChallenge(.cancelAuthenticationChallenge, nil)
    }

    public func performDefaultHandling(for challenge: URLAuthenticationChallenge) {
        answerChallenge(.performDefaultHandling, nil)
    }

    public func rejectProtectionSpaceAndContinue(with challenge: URLAuthenticationChallenge) {
        answerChallenge(.rejectProtectionSpace, nil)
    }
}

/// The session recorded requests go out on. Its delegate hands each task's events to the protocol
/// that sent it.
private final class Forwarder: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private var session: URLSession!
    /// URLProtocol is a class from before Swift concurrency; each is used by one task at a time.
    private struct Owner: @unchecked Sendable {
        let value: RecordingURLProtocol
    }

    private let owners = Mutex<[Int: Owner]>([:])

    init(configuration: URLSessionConfiguration) {
        super.init()
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }

    func dataTask(with request: URLRequest, for owner: RecordingURLProtocol) -> URLSessionDataTask {
        let task = session.dataTask(with: request)
        let entry = Owner(value: owner)
        owners.withLock { $0[task.taskIdentifier] = entry }
        return task
    }

    private func owner(of task: URLSessionTask) -> RecordingURLProtocol? {
        owners.withLock { $0[task.taskIdentifier]?.value }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        owner(of: dataTask)?.didReceive(response)
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard let owner = owner(of: task) else { return completionHandler(.performDefaultHandling, nil) }
        owner.didReceive(challenge, completion: completionHandler)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        owner(of: dataTask)?.didReceive(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        if let owner = owner(of: task) {
            owners.withLock { _ = $0.removeValue(forKey: task.taskIdentifier) }
            owner.wasRedirected(to: request, by: response)
        }
        completionHandler(nil)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        let owner = owners.withLock { $0.removeValue(forKey: task.taskIdentifier) }
        owner?.value.didComplete(with: error)
    }
}
