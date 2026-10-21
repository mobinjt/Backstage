import Foundation
import Synchronization

/// Records HTTP calls: it takes each request while Backstage records, sends it on its own session,
/// and passes everything back to the app's task unchanged while noting it down.
///
/// It doesn't see WebSocket tasks or background sessions; the app reports WebSockets through
/// `NetworkRecorder.openConnection`.
public final class RecordingURLProtocol: URLProtocol, @unchecked Sendable {
    private static let handledKey = "Backstage.RecordingURLProtocol.handled"

    /// The session requests are sent on. Tests replace its configuration.
    nonisolated(unsafe) static var forwardingConfiguration: URLSessionConfiguration = {
        let configuration = URLSessionConfiguration.ephemeral
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

    private struct Loading {
        let task: URLSessionDataTask
        let transactionID: UUID
        var response: URLResponse?
        var body = Data()
    }

    // MARK: URLProtocol

    override public class func canInit(with request: URLRequest) -> Bool {
        guard NetworkRecorder.shared.isRecording,
              let scheme = request.url?.scheme?.lowercased(), scheme == "http" || scheme == "https",
              property(forKey: handledKey, in: request) == nil else { return false }
        return true
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
            forwarded.httpBody = body
            forwarded.httpBodyStream = nil
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
        recorder.add(transaction)

        let task = Self.sharedForwarder.dataTask(with: forwarded, for: self)
        loading.withLock { $0 = Loading(task: task, transactionID: transaction.id) }
        task.resume()
    }

    override public func stopLoading() {
        let task = loading.withLock { $0?.task }
        task?.cancel()
    }

    /// The request's body, also when it was given as a stream (as `URLSession` does for uploads).
    private static func body(of request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while stream.hasBytesAvailable {
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
        loading.withLock { $0?.response = response }
        onClientThread { [self] in client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed) }
    }

    fileprivate func didReceive(_ data: Data) {
        loading.withLock { $0?.body.append(data) }
        onClientThread { [self] in client?.urlProtocol(self, didLoad: data) }
    }

    fileprivate func wasRedirected(to request: URLRequest, by response: HTTPURLResponse) {
        // Recorded as its own transaction; the app's session follows the redirect with a new
        // request, which this protocol records again.
        finish(error: nil, redirectedTo: request.url)
        onClientThread { [self] in client?.urlProtocol(self, wasRedirectedTo: request, redirectResponse: response) }
    }

    fileprivate func didComplete(with error: (any Error)?) {
        finish(error: error, redirectedTo: nil)
        onClientThread { [self] in
            if let error {
                client?.urlProtocol(self, didFailWithError: error)
            } else {
                client?.urlProtocolDidFinishLoading(self)
            }
        }
    }

    private func finish(error: (any Error)?, redirectedTo: URL?) {
        guard let loading = loading.withLock({ $0 }) else { return }
        let limit = recorder.limits.maximumBodySize
        recorder.update(loading.transactionID) { transaction in
            transaction.endDate = .now
            if let response = loading.response as? HTTPURLResponse {
                transaction.statusCode = response.statusCode
                transaction.responseHeaders = response.allHeaderFields.reduce(into: [:]) { headers, field in
                    headers[String(describing: field.key)] = String(describing: field.value)
                }
            }
            if !loading.body.isEmpty {
                transaction.responseBody = NetworkTransaction.Body(loading.body, limit: limit)
            }
            if let error {
                transaction.errorDescription = (error as NSError).localizedDescription
            } else if let redirectedTo {
                transaction.note = "Redirected to \(redirectedTo.absoluteString)"
            }
        }
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
