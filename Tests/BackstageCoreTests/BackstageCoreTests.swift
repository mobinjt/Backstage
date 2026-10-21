import Foundation
import Synchronization
import Testing
@testable import BackstageCore

struct PassphraseTests {
    @Test func theRightPassphraseMatchesOnlyWithItsSalt() {
        let salt = Passphrase.makeSalt()
        // Few rounds keep the test fast; the rounds are read from the hash.
        let hash = Passphrase.hash("correct horse battery", salt: salt, rounds: 1_000)
        #expect(hash.hasPrefix("pbkdf2-sha256$1000$"))
        #expect(hash.count == "pbkdf2-sha256$1000$".count + 64)
        #expect(Passphrase.matches("correct horse battery", salt: salt, hash: hash))
        #expect(Passphrase.matches("correct horse battery", salt: salt, hash: hash.uppercased()))
        #expect(!Passphrase.matches("correct horse batter", salt: salt, hash: hash))
        #expect(!Passphrase.matches("correct horse battery", salt: Passphrase.makeSalt(), hash: hash))
    }

    @Test func pbkdf2MatchesAKnownVector() {
        // RFC 7914 section 11: PBKDF2-HMAC-SHA256, password "passwd", salt "salt", 1 round
        // (the first 32 bytes of its 64-byte result).
        #expect(Passphrase.hash("passwd", salt: "salt", rounds: 1) == "pbkdf2-sha256$1$55ac046e56e3089fec1691c22544b605f94185216dde0465e68b9d57c20dacbc")
    }

    @Test func blankOrOtherHashesNeverMatch() {
        let digest = String(repeating: "0", count: 64)
        #expect(!Passphrase.matches("", salt: "", hash: ""))
        #expect(!Passphrase.matches("anything", salt: "salt", hash: digest), "A bare SHA-256 hash isn't accepted")
        #expect(!Passphrase.matches("anything", salt: "salt", hash: "pbkdf2-sha256$0$\(digest)"))
    }

    @Test func onlyXcodeAndUnlockedTestFlightBuildsAreOn() {
        #expect(Backstage.isEnabled(environment: .xcode, isUnlocked: false))
        #expect(!Backstage.isEnabled(environment: .testFlight, isUnlocked: false))
        #expect(Backstage.isEnabled(environment: .testFlight, isUnlocked: true))
        #expect(!Backstage.isEnabled(environment: .appStore, isUnlocked: true), "An unlocked flag never turns on an App Store build")
    }
}

struct NetworkRecorderTests {
    private func makeRecorder(_ limits: NetworkRecorder.Limits = .init()) -> (NetworkRecorder, URL) {
        let directory = URL.temporaryDirectory.appending(path: "backstage-tests-\(UUID().uuidString)")
        let recorder = NetworkRecorder(directory: directory)
        recorder.configure(limits)
        recorder.setRecording(true)
        return (recorder, directory)
    }

    private func transaction(_ recorder: NetworkRecorder, body: Int = 0) -> NetworkTransaction {
        var transaction = NetworkTransaction(kind: .http, launchID: recorder.launchID, url: URL(string: "https://example.com/a"), method: "GET")
        if body > 0 {
            transaction.responseBody = NetworkTransaction.Body(Data(count: body), limit: recorder.limits.maximumBodySize)
        }
        return transaction
    }

    @Test func nothingIsRecordedWhileOff() {
        let (recorder, _) = makeRecorder()
        recorder.setRecording(false)
        recorder.add(transaction(recorder))
        #expect(recorder.transactions.isEmpty)
        #expect(recorder.openConnection(kind: .webSocket, url: nil) == nil)
    }

    @Test func theOldestTransactionsAreRemovedPastTheLimit() {
        var limits = NetworkRecorder.Limits()
        limits.maximumTransactions = 3
        let (recorder, _) = makeRecorder(limits)
        let added = (0..<5).map { _ in transaction(recorder) }
        added.forEach(recorder.add)
        #expect(recorder.transactions.map(\.id) == added.suffix(3).reversed().map(\.id), "Newest first, the two oldest gone")
    }

    @Test func bodiesAreCutAndTheOldestLoseThemPastTheBudget() {
        var limits = NetworkRecorder.Limits()
        limits.maximumBodySize = 100
        limits.bodyBudget = 250
        let (recorder, _) = makeRecorder(limits)
        let first = transaction(recorder, body: 500)
        #expect(first.responseBody?.data.count == 100)
        #expect(first.responseBody?.size == 500)
        recorder.add(first)
        recorder.add(transaction(recorder, body: 100))
        recorder.add(transaction(recorder, body: 100))
        let kept = recorder.transactions
        #expect(kept.last?.responseBody?.data.isEmpty == true, "The oldest keeps only its size")
        #expect(kept.last?.responseBody?.size == 500)
        #expect(kept.first?.responseBody?.data.count == 100)
    }

    @Test func connectionsRecordTheirMessages() {
        let (recorder, _) = makeRecorder()
        let connection = recorder.openConnection(kind: .connection("Nearby"), url: nil, note: "Sara's room")
        connection?.opened()
        connection?.sent(text: #"{"hello":1}"#)
        connection?.received(text: #"{"welcome":1}"#)
        connection?.closed()
        let recorded = recorder.transactions.first
        #expect(recorded?.kind == .connection("Nearby"))
        #expect(recorded?.messages.map(\.direction) == [.sent, .received])
        #expect(recorded?.note == "Sara's room")
        #expect(recorded?.isComplete == true)
    }

    @Test func earlierLaunchesAreLoadedAndUnfinishedOnesMarked() {
        let (recorder, directory) = makeRecorder()
        var finished = transaction(recorder)
        finished.endDate = .now
        recorder.add(finished)
        recorder.add(transaction(recorder))
        recorder.flush()

        let nextLaunch = NetworkRecorder(directory: directory)
        nextLaunch.setRecording(true)
        nextLaunch.loadPrevious()
        let loaded = nextLaunch.transactions
        #expect(loaded.count == 2)
        #expect(loaded.allSatisfy { $0.isComplete })
        #expect(loaded.contains { $0.errorDescription == "The app stopped before this finished." })
    }
}

struct ExportTests {
    private var transaction: NetworkTransaction {
        var transaction = NetworkTransaction(kind: .http, launchID: UUID(), url: URL(string: "https://example.com/v1/me?x=1"), method: "POST", requestHeaders: ["Authorization": "Bearer secret", "Content-Type": "application/json"])
        transaction.requestBody = NetworkTransaction.Body(Data(#"{"name":"O'Neil"}"#.utf8), limit: 1_000)
        transaction.statusCode = 201
        transaction.responseHeaders = ["Content-Type": "application/json"]
        transaction.responseBody = NetworkTransaction.Body(Data(#"{"ok":true}"#.utf8), limit: 1_000)
        transaction.endDate = transaction.startDate.addingTimeInterval(0.25)
        return transaction
    }

    @Test func curlRepeatsTheRequestWithoutSecrets() throws {
        let curl = try #require(NetworkExport.curl(transaction, sensitiveHeaders: ["authorization"]))
        #expect(curl.contains("-X POST"))
        #expect(curl.contains("'Authorization: <hidden>'"))
        #expect(curl.contains(#"'{"name":"O'\''Neil"}'"#))
        #expect(curl.hasSuffix("'https://example.com/v1/me?x=1'"))
        #expect(NetworkExport.curl(transaction, sensitiveHeaders: ["authorization"], includingSensitive: true)?.contains("Bearer secret") == true)
    }

    @Test func harHasTheEntry() throws {
        let data = try NetworkExport.har([transaction], sensitiveHeaders: ["authorization"])
        let har = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let log = try #require(har["log"] as? [String: Any])
        let entry = try #require((log["entries"] as? [[String: Any]])?.first)
        #expect((entry["response"] as? [String: Any])?["status"] as? Int == 201)
        #expect((entry["time"] as? Double) == 250)
        let headers = try #require((entry["request"] as? [String: Any])?["headers"] as? [[String: String]])
        #expect(headers.contains { $0["name"] == "Authorization" && $0["value"] == "<hidden>" })
    }
}

/// Answers every request with a fixed response and remembers the request it saw. `/old` is
/// redirected to `/v1/ping`.
final class StubProtocol: URLProtocol, @unchecked Sendable {
    static let seen = Mutex<[URLRequest]>([])

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.seen.withLock { $0.append(request) }
        if request.url?.path() == "/old" {
            // Like the system, the new request is the old one with another URL, properties and all.
            var next = request
            next.url = URL(string: "https://example.com/v1/ping")!
            let response = HTTPURLResponse(url: request.url!, statusCode: 302, httpVersion: "HTTP/1.1", headerFields: ["Location": next.url!.absoluteString])!
            client?.urlProtocol(self, wasRedirectedTo: next, redirectResponse: response)
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"pong":true}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@Suite(.serialized)
struct RecordingURLProtocolTests {
    @Test func requestsPassThroughAndAreRecorded() async throws {
        let forwarding = URLSessionConfiguration.ephemeral
        forwarding.protocolClasses = [StubProtocol.self]
        RecordingURLProtocol.forwardingConfiguration = forwarding
        RecordingURLProtocol.resetForwarder()
        NetworkRecorder.shared.setRecording(true, purge: true)
        defer { NetworkRecorder.shared.setRecording(false, purge: true) }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpAdditionalHeaders = ["X-App-Build": "ios 42"]
        Backstage.record(configuration)
        let session = URLSession(configuration: configuration)
        var request = URLRequest(url: URL(string: "https://example.com/v1/ping")!)
        request.httpMethod = "POST"
        request.httpBody = Data(#"{"ping":true}"#.utf8)
        let (data, response) = try await session.data(for: request)

        #expect(String(decoding: data, as: UTF8.self) == #"{"pong":true}"#)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        let sent = try #require(StubProtocol.seen.withLock { $0.last })
        #expect(sent.value(forHTTPHeaderField: "X-App-Build") == "ios 42", "The session's own headers reach the server")

        let recorded = try #require(NetworkRecorder.shared.transactions.first)
        #expect(recorded.method == "POST")
        #expect(recorded.statusCode == 200)
        #expect(recorded.requestBody?.data == Data(#"{"ping":true}"#.utf8))
        #expect(recorded.responseBody?.data == data)
        #expect(recorded.requestHeaders["X-App-Build"] == "ios 42")
        #expect(recorded.isComplete)
    }

    @Test func redirectsAreRecordedWithTheirStatus() async throws {
        let forwarding = URLSessionConfiguration.ephemeral
        forwarding.protocolClasses = [StubProtocol.self]
        RecordingURLProtocol.forwardingConfiguration = forwarding
        RecordingURLProtocol.resetForwarder()
        NetworkRecorder.shared.setRecording(true, purge: true)
        defer { NetworkRecorder.shared.setRecording(false, purge: true) }

        let configuration = URLSessionConfiguration.ephemeral
        Backstage.record(configuration)
        let (data, response) = try await URLSession(configuration: configuration).data(from: URL(string: "https://example.com/old")!)

        #expect(String(decoding: data, as: UTF8.self) == #"{"pong":true}"#)
        #expect(response.url?.path() == "/v1/ping")
        let recorded = NetworkRecorder.shared.transactions
        #expect(recorded.map { $0.url?.path() } == ["/v1/ping", "/old"], "The redirect and the request it led to, newest first")
        #expect(recorded.last?.statusCode == 302)
        #expect(recorded.last?.note == "Redirected to https://example.com/v1/ping")
        #expect(recorded.first?.statusCode == 200)
    }

    @Test func webSocketsAreLeftAlone() {
        NetworkRecorder.shared.setRecording(true, purge: true)
        defer { NetworkRecorder.shared.setRecording(false, purge: true) }
        let configuration = URLSessionConfiguration.ephemeral
        Backstage.record(configuration)
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        #expect(RecordingURLProtocol.canInit(with: session.dataTask(with: URL(string: "https://example.com/socket")!)))
        #expect(!RecordingURLProtocol.canInit(with: session.webSocketTask(with: URL(string: "wss://example.com/socket")!)))
    }

    @Test func nothingIsTouchedWhileOff() async throws {
        NetworkRecorder.shared.setRecording(false, purge: true)
        let configuration = URLSessionConfiguration.ephemeral
        Backstage.record(configuration)
        configuration.protocolClasses = (configuration.protocolClasses ?? []) + [StubProtocol.self]
        let (data, _) = try await URLSession(configuration: configuration).data(from: URL(string: "https://example.com/v1/ping")!)
        #expect(!data.isEmpty)
        #expect(NetworkRecorder.shared.transactions.isEmpty)
    }
}
