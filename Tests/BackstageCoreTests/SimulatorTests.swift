import Foundation
import Testing
@testable import BackstageCore

struct NetworkSimulatorTests {
    private func request(_ url: String, method: String = "GET") -> URLRequest {
        var request = URLRequest(url: URL(string: url)!)
        request.httpMethod = method
        return request
    }

    private func fake(_ pattern: String, method: String? = nil, isOn: Bool = true) -> NetworkSimulator.Fake {
        NetworkSimulator.Fake(name: pattern, isOn: isOn, method: method, urlPattern: pattern, answer: .response(status: 503, headers: [:], body: Data()))
    }

    @Test func patternsMatchWithWildcardsAndWithoutTheQuery() {
        let users = fake("https://api.example.com/users/*")
        #expect(users.matches(request("https://api.example.com/users/1")))
        #expect(users.matches(request("https://API.example.com/users/1?expand=all")), "Case and the query don't matter")
        #expect(!users.matches(request("https://api.example.com/posts/1")))
        #expect(fake("*/users/*").matches(request("https://staging.example.com/v2/users/7")))
        #expect(!fake("*/users?page=2").matches(request("https://example.com/users?page=1")), "A pattern with a query matches it too")
        #expect(fake("*/users?page=*").matches(request("https://example.com/users?page=1")))
    }

    @Test func onlyTheRightMethodAndRulesThatAreOnMatch() {
        #expect(fake("*/users", method: "POST").matches(request("https://example.com/users", method: "post")))
        #expect(!fake("*/users", method: "POST").matches(request("https://example.com/users")))
        #expect(!fake("*", isOn: false).matches(request("https://example.com/")))
    }

    @Test func aFakeWinsOverTheConditionWhichCanBeLimitedToAHost() {
        let simulator = NetworkSimulator(file: nil)
        simulator.condition = .offline
        simulator.setFakes([fake("*/health")])
        #expect(simulator.plan(for: request("https://example.com/health")).label == "Fake")
        #expect(simulator.plan(for: request("https://example.com/users")).label == "Offline")

        var slow = NetworkSimulator.Condition.slow3G
        slow.host = "api.example.com"
        simulator.condition = slow
        #expect(simulator.plan(for: request("https://api.example.com/users")).label == "Slowed")
        #expect(simulator.plan(for: request("https://cdn.example.com/a.png")).label == nil, "Other hosts are left alone")
        simulator.condition = nil
        #expect(simulator.plan(for: request("https://api.example.com/users")).label == nil)
    }

    @Test func aFlakyNetworkFailsAShareOfRequests() {
        let simulator = NetworkSimulator(file: nil)
        simulator.condition = NetworkSimulator.Condition(name: "Flaky", failureRate: 0.2)
        #expect(simulator.plan(for: request("https://example.com/"), random: { 0.1 }).label == "Flaky")
        #expect(simulator.plan(for: request("https://example.com/"), random: { 0.5 }).label == nil)
    }

    @Test func fakesAreKeptInTheirFile() {
        let file = URL.temporaryDirectory.appending(path: "backstage-fakes-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        NetworkSimulator(file: file).setFakes([fake("*/users/*")])
        let nextLaunch = NetworkSimulator(file: file)
        #expect(nextLaunch.fakes.map(\.urlPattern) == ["*/users/*"])
        #expect(nextLaunch.condition == nil, "The condition isn't kept")
    }

    @Test func aFakeMadeFromARecordedResponseAnswersTheSame() throws {
        var transaction = NetworkTransaction(kind: .http, launchID: UUID(), url: URL(string: "https://example.com/v1/users/1?expand=all"), method: "GET")
        transaction.statusCode = 200
        transaction.responseHeaders = ["Content-Type": "application/json", "Content-Encoding": "br", "Content-Length": "11"]
        transaction.responseBody = NetworkTransaction.Body(Data(#"{"id":1}"#.utf8), limit: 1_000)
        let fake = NetworkSimulator.Fake(answering: transaction)
        #expect(fake.method == "GET")
        #expect(fake.urlPattern == "https://example.com/v1/users/1", "Without the query, so it matches whatever the query")
        guard case .response(let status, let headers, let body) = fake.answer else { Issue.record("Not a response"); return }
        #expect(status == 200)
        #expect(headers == ["Content-Type": "application/json"], "The body is kept decoded, so its encoding and length are dropped")
        #expect(body == Data(#"{"id":1}"#.utf8))
    }
}

/// Fakes and conditions through the recording protocol, in the serialized suite: they change the
/// shared forwarding session, recorder and simulator.
extension SharedStateTests.RecordingURLProtocolTests {
    private func recordedSession() -> URLSession {
        let forwarding = URLSessionConfiguration.ephemeral
        forwarding.protocolClasses = [StubProtocol.self]
        RecordingURLProtocol.forwardingConfiguration = forwarding
        RecordingURLProtocol.resetForwarder()
        NetworkRecorder.shared.setRecording(true, purge: true)
        NetworkSimulator.shared.useFile(nil)
        let configuration = URLSessionConfiguration.ephemeral
        Backstage.record(configuration)
        return URLSession(configuration: configuration)
    }

    private func reset() {
        NetworkSimulator.shared.condition = nil
        NetworkSimulator.shared.setFakes([])
        NetworkRecorder.shared.setRecording(false, purge: true)
    }

    @Test func aFakeAnswersWithoutReachingTheServer() async throws {
        let session = recordedSession()
        defer { reset() }
        NetworkSimulator.shared.setFakes([NetworkSimulator.Fake(
            name: "Down for maintenance",
            urlPattern: "*/v1/status",
            answer: .response(status: 503, headers: ["Content-Type": "application/json"], body: Data(#"{"down":true}"#.utf8))
        )])
        let before = StubProtocol.seen.withLock { $0.count }

        let (data, response) = try await session.data(from: URL(string: "https://example.com/v1/status")!)

        #expect(String(decoding: data, as: UTF8.self) == #"{"down":true}"#)
        #expect((response as? HTTPURLResponse)?.statusCode == 503)
        #expect((response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(StubProtocol.seen.withLock { $0.count } == before, "The server never sees it")
        let recorded = try #require(NetworkRecorder.shared.transactions.first)
        #expect(recorded.simulation == "Fake")
        #expect(recorded.statusCode == 503)
        #expect(recorded.isComplete)
    }

    @Test func aFakeCanFailLikeTheNetwork() async throws {
        let session = recordedSession()
        defer { reset() }
        NetworkSimulator.shared.setFakes([NetworkSimulator.Fake(name: "Timeout", urlPattern: "*", answer: .failure(.timedOut))])
        await #expect { try await session.data(from: URL(string: "https://example.com/v1/ping")!) } throws: { error in
            (error as? URLError)?.code == .timedOut
        }
        #expect(NetworkRecorder.shared.transactions.first?.isFailure == true)
    }

    @Test func offlineFailsEveryRequest() async throws {
        let session = recordedSession()
        defer { reset() }
        NetworkSimulator.shared.condition = .offline
        await #expect { try await session.data(from: URL(string: "https://example.com/v1/ping")!) } throws: { error in
            (error as? URLError)?.code == .notConnectedToInternet
        }
        let recorded = try #require(NetworkRecorder.shared.transactions.first)
        #expect(recorded.simulation == "Offline")
        #expect(recorded.isFailure)
    }

    @Test func aSlowNetworkWaitsAndLimitsTheSpeed() async throws {
        let session = recordedSession()
        defer { reset() }
        NetworkSimulator.shared.condition = NetworkSimulator.Condition(name: "Slow", delay: 0.3, bytesPerSecond: 50_000)
        let clock = ContinuousClock()
        let start = clock.now
        let (data, _) = try await session.data(from: URL(string: "https://example.com/big")!)
        let elapsed = clock.now - start
        #expect(data.count == 20_000, "Everything arrives")
        // 0.3 s before it starts, then 20,000 bytes at 50,000 a second.
        #expect(elapsed >= .milliseconds(650), "Took \(elapsed)")
        #expect(NetworkRecorder.shared.transactions.first?.simulation == "Slowed")
    }
}
