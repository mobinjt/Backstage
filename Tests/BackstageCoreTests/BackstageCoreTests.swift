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

    @Test func onlyDevelopmentProfilesCountAsXcode() {
        func profile(getTaskAllow: Bool?) -> Data {
            var entitlements: [String: Any] = ["application-identifier": "TEAM.com.example.app"]
            entitlements["get-task-allow"] = getTaskAllow
            let plist = try! PropertyListSerialization.data(fromPropertyList: ["Entitlements": entitlements], format: .xml, options: 0)
            // The property list sits between binary signature bytes, as in a real profile.
            return Data([0x30, 0x80, 0x06, 0x09]) + plist + Data([0xA0, 0x82, 0x0B, 0x00])
        }
        #expect(RunEnvironment.allowsDebugging(provisioningProfile: profile(getTaskAllow: true)))
        #expect(!RunEnvironment.allowsDebugging(provisioningProfile: profile(getTaskAllow: false)), "Ad hoc and enterprise")
        #expect(!RunEnvironment.allowsDebugging(provisioningProfile: profile(getTaskAllow: nil)))
        #expect(!RunEnvironment.allowsDebugging(provisioningProfile: Data("not a profile".utf8)))
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

    @Test func nothingIsLoadedOnceRecordingStopped() {
        let (recorder, directory) = makeRecorder()
        recorder.add(transaction(recorder))
        recorder.flush()
        // Such as an App Store build that stopped before the files were read.
        let nextLaunch = NetworkRecorder(directory: directory)
        nextLaunch.loadPrevious()
        #expect(nextLaunch.transactions.isEmpty)
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
        #expect((entry["response"] as? [String: Any])?["statusText"] as? String == "Created")
        #expect((entry["time"] as? Double) == 250)
        let headers = try #require((entry["request"] as? [String: Any])?["headers"] as? [[String: String]])
        #expect(headers.contains { $0["name"] == "Authorization" && $0["value"] == "<hidden>" })
    }

    @Test func sensitiveHeadersAreHiddenHoweverTheyreWritten() throws {
        var configuration = BackstageConfiguration(passphraseSalt: "", passphraseHash: "")
        configuration.sensitiveHeaders.insert("X-Auth-Token")
        #expect(configuration.sensitiveHeaders.contains("x-auth-token"))
        var call = transaction
        call.requestHeaders["x-auth-TOKEN"] = "t0ken"
        let curl = try #require(NetworkExport.curl(call, sensitiveHeaders: ["X-Auth-Token"]))
        #expect(!curl.contains("t0ken"))
        #expect(call.hidingHeaders(["X-AUTH-TOKEN"]).requestHeaders["x-auth-TOKEN"] == "<hidden>")
        let har = String(decoding: try NetworkExport.har([call], sensitiveHeaders: ["X-Auth-Token"]), as: UTF8.self)
        #expect(!har.contains("t0ken"))
    }
}

struct StatusAndLogTests {
    @Test func statusCodesUseTheStandardWording() {
        #expect(NetworkTransaction.reasonPhrase(forStatusCode: 200) == "OK")
        #expect(NetworkTransaction.reasonPhrase(forStatusCode: 307) == "Temporary Redirect")
        #expect(NetworkTransaction.reasonPhrase(forStatusCode: 429) == "Too Many Requests")
        #expect(NetworkTransaction.reasonPhrase(forStatusCode: 299) == nil)
    }

    @Test func onlyTheAppsOwnCodeCountsAsTheApp() {
        let app: Set<String> = ["MyApp", "MyApp.debug.dylib", "Purchases"]
        #expect(LogReader.isFromApp(sender: "MyApp.debug.dylib", subsystem: "com.example.myapp", appImages: app))
        #expect(LogReader.isFromApp(sender: "Purchases", subsystem: "com.revenuecat", appImages: app), "An embedded framework")
        #expect(LogReader.isFromApp(sender: "Foundation", subsystem: "", appImages: app), "NSLog")
        #expect(!LogReader.isFromApp(sender: "UIKitCore", subsystem: "com.apple.UIKit", appImages: app))
        #expect(!LogReader.isFromApp(sender: "Security", subsystem: "", appImages: app))
        #expect(!LogReader.isFromApp(sender: "Foundation", subsystem: "com.apple.foundation", appImages: app))
    }
}

/// Asks for a password, then answers with the user it was given; 401 without one.
final class PasswordStubProtocol: URLProtocol, URLAuthenticationChallengeSender, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let space = URLProtectionSpace(host: "example.com", port: 443, protocol: "https", realm: "Staff", authenticationMethod: NSURLAuthenticationMethodHTTPBasic)
        client?.urlProtocol(self, didReceive: URLAuthenticationChallenge(protectionSpace: space, proposedCredential: nil, previousFailureCount: 0, failureResponse: nil, error: nil, sender: self))
    }

    override func stopLoading() {}

    private func answer(_ status: Int, _ body: String) {
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    func use(_ credential: URLCredential, for challenge: URLAuthenticationChallenge) { answer(200, credential.user ?? "") }
    func continueWithoutCredential(for challenge: URLAuthenticationChallenge) { answer(401, "") }
    func cancel(_ challenge: URLAuthenticationChallenge) { answer(401, "") }
    func performDefaultHandling(for challenge: URLAuthenticationChallenge) { answer(401, "") }
}

/// Gives a password when asked, as an app's session delegate does.
final class PasswordGiver: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        (.useCredential, URLCredential(user: "sara", password: "secret", persistence: .none))
    }
}

/// Answers every request with a fixed response and remembers the request it saw. `/old` is
/// redirected to `/v1/ping`; `/big` answers with 20,000 bytes.
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
        client?.urlProtocol(self, didLoad: request.url?.path() == "/big" ? Data(count: 20_000) : Data(#"{"pong":true}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

struct LaunchTests {
    @Test func settingsApplyAtLaunchOnlyWhereBackstageMayBeOn() {
        #expect(Backstage.isEnabledAtLaunch(isFromXcode: true, isUnlocked: false, hasAppStoreReceipt: false))
        #expect(Backstage.isEnabledAtLaunch(isFromXcode: false, isUnlocked: true, hasAppStoreReceipt: false), "An unlocked TestFlight device")
        #expect(!Backstage.isEnabledAtLaunch(isFromXcode: false, isUnlocked: true, hasAppStoreReceipt: true), "Unlocked once, now the App Store version")
        #expect(!Backstage.isEnabledAtLaunch(isFromXcode: false, isUnlocked: false, hasAppStoreReceipt: false))
    }
}

extension SharedStateTests {
    @MainActor
    @Suite struct AppStoreTests {
        @Test func theAppStoreVersionForgetsATestFlightUnlock() {
            let name = "backstage-tests-\(UUID().uuidString)"
            let store = UnlockStore(service: "BackstageTests", account: name)
            store.setUnlocked(true)
            defer { store.setUnlocked(false) }
            let backstage = Backstage(unlockStore: store, defaults: UserDefaults(suiteName: name)!)
            #expect(backstage.isUnlocked)

            backstage.settle(.appStore)
            #expect(!backstage.isEnabled)
            #expect(!store.isUnlocked, "The next launch doesn't act on the TestFlight settings")
        }
    }
}

/// Suites that change what the whole process shares (the recorder, the simulator, whether
/// Backstage is on, the location and time zone), run one at a time so none sees another's.
@Suite(.serialized)
struct SharedStateTests {}

extension SharedStateTests {
    @Suite struct RecordingURLProtocolTests {
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

        @Test func theAppsSessionAnswersTheServersChallenge() async throws {
        let forwarding = URLSessionConfiguration.ephemeral
        forwarding.protocolClasses = [PasswordStubProtocol.self]
        RecordingURLProtocol.forwardingConfiguration = forwarding
        RecordingURLProtocol.resetForwarder()
        NetworkRecorder.shared.setRecording(true, purge: true)
        defer { NetworkRecorder.shared.setRecording(false, purge: true) }

        let configuration = URLSessionConfiguration.ephemeral
        Backstage.record(configuration)
        let request = URLRequest(url: URL(string: "https://example.com/staff")!)
        let (data, response) = try await URLSession(configuration: configuration).data(for: request, delegate: PasswordGiver())
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        #expect(String(decoding: data, as: UTF8.self) == "sara", "The password came from the app's own delegate")
        #expect(NetworkRecorder.shared.transactions.first?.statusCode == 200)
    }

    @Test func aLargeBodyIsKeptOnlyUpToTheLimit() async throws {
        let forwarding = URLSessionConfiguration.ephemeral
        forwarding.protocolClasses = [StubProtocol.self]
        RecordingURLProtocol.forwardingConfiguration = forwarding
        RecordingURLProtocol.resetForwarder()
        var limits = NetworkRecorder.Limits()
        limits.maximumBodySize = 1_000
        NetworkRecorder.shared.configure(limits)
        NetworkRecorder.shared.setRecording(true, purge: true)
        defer {
            NetworkRecorder.shared.setRecording(false, purge: true)
            NetworkRecorder.shared.configure(.init())
        }

        let configuration = URLSessionConfiguration.ephemeral
        Backstage.record(configuration)
        let (data, _) = try await URLSession(configuration: configuration).data(from: URL(string: "https://example.com/big")!)
        #expect(data.count == 20_000, "The app gets all of it")
        let body = try #require(NetworkRecorder.shared.transactions.first?.responseBody)
        #expect(body.data.count == 1_000)
        #expect(body.size == 20_000)
    }

    @Test func aStreamedBodyIsSentWhole() async throws {
        let forwarding = URLSessionConfiguration.ephemeral
        forwarding.protocolClasses = [StubProtocol.self]
        RecordingURLProtocol.forwardingConfiguration = forwarding
        RecordingURLProtocol.resetForwarder()
        NetworkRecorder.shared.setRecording(true, purge: true)
        defer { NetworkRecorder.shared.setRecording(false, purge: true) }

        // A stream the app is still writing to when the request starts.
        var input: InputStream?
        var output: OutputStream?
        Stream.getBoundStreams(withBufferSize: 1_024, inputStream: &input, outputStream: &output)
        nonisolated(unsafe) let writer = try #require(output)
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) {
            writer.open()
            let bytes = Array(#"{"upload":true}"#.utf8)
            _ = writer.write(bytes, maxLength: bytes.count)
            writer.close()
        }
        var request = URLRequest(url: URL(string: "https://example.com/upload")!)
        request.httpMethod = "POST"
        request.httpBodyStream = input

        let configuration = URLSessionConfiguration.ephemeral
        Backstage.record(configuration)
        _ = try await URLSession(configuration: configuration).data(for: request)
        #expect(NetworkRecorder.shared.transactions.first?.requestBody?.data == Data(#"{"upload":true}"#.utf8))
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
}

@MainActor
struct OverlaySettingsTests {
    private func backstage() -> (Backstage, UserDefaults) {
        let name = "backstage-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return (Backstage(unlockStore: UnlockStore(service: "BackstageTests", account: name), defaults: defaults), defaults)
    }

    @Test func networkLinesInThePerformanceOverlayGoWithIt() {
        let (backstage, _) = backstage()
        #expect(backstage.networkOverlay == .off)
        backstage.networkOverlay = .inPerformanceOverlay
        #expect(backstage.showsPerformanceOverlay, "Choosing it shows the performance overlay")
        backstage.showsPerformanceOverlay = false
        #expect(backstage.networkOverlay == .off, "Hiding the performance overlay takes the network lines with it")
        backstage.networkOverlay = .ticker
        backstage.showsPerformanceOverlay = true
        backstage.showsPerformanceOverlay = false
        #expect(backstage.networkOverlay == .ticker, "Its own window doesn't depend on the performance overlay")
    }

    @Test func overlaySettingsAreKeptAcrossLaunches() {
        let (backstage, defaults) = backstage()
        backstage.networkOverlay = .compact
        backstage.alertsOnNetworkProblems = true
        let nextLaunch = Backstage(unlockStore: UnlockStore(service: "BackstageTests", account: "next"), defaults: defaults)
        #expect(nextLaunch.networkOverlay == .compact)
        #expect(nextLaunch.alertsOnNetworkProblems)
    }
}
