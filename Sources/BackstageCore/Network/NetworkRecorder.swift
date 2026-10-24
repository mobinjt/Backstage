import Foundation
import Synchronization

/// Keeps the recorded traffic: in memory for the panel, and as one file per transaction in the
/// app's Caches, so what happened before a crash or relaunch is still there. Safe to use from any
/// thread. It records only while Backstage is on.
public final class NetworkRecorder: Sendable {
    public static let shared = NetworkRecorder(directory: Folders.caches.appending(path: "Network", directoryHint: .isDirectory))

    public struct Limits: Sendable {
        /// Transactions kept; older ones are removed.
        public var maximumTransactions = 1_000
        /// Each body (or message) is cut at this size.
        public var maximumBodySize = 1_000_000
        /// Bodies kept in all; past it the oldest transactions keep only their sizes.
        public var bodyBudget = 32_000_000

        public init() {}
    }

    private struct State {
        var isRecording = false
        var limits = Limits()
        var transactions: [UUID: NetworkTransaction] = [:]
        /// Oldest first.
        var order: [UUID] = []
        var observers: [UUID: AsyncStream<Void>.Continuation] = [:]
        var pendingWrites: Set<UUID> = []
        var isWriteScheduled = false
        /// Bytes of bodies and messages kept in all.
        var storedBytes = 0
    }

    /// This launch of the app.
    public let launchID = UUID()
    private let state = Mutex(State())
    private let directory: URL
    private let writer = DispatchQueue(label: "Backstage.NetworkRecorder.writer", qos: .utility)

    init(directory: URL) {
        self.directory = directory
    }

    // MARK: Recording

    public var isRecording: Bool {
        state.withLock { $0.isRecording }
    }

    var limits: Limits {
        state.withLock { $0.limits }
    }

    func configure(_ limits: Limits) {
        state.withLock { $0.limits = limits }
    }

    /// Starts or stops recording. Stopping with `purge` also forgets everything recorded, on disk
    /// too: used when the app turns out to come from the App Store.
    func setRecording(_ recording: Bool, purge: Bool = false) {
        state.withLock { $0.isRecording = recording }
        if purge {
            clear()
        }
    }

    /// Adds a transaction; ignored when not recording.
    public func add(_ transaction: NetworkTransaction) {
        let added = state.withLock { state -> Bool in
            guard state.isRecording else { return false }
            state.transactions[transaction.id] = transaction
            state.order.append(transaction.id)
            state.storedBytes += transaction.storedBytes
            Self.trim(&state)
            state.pendingWrites.insert(transaction.id)
            return true
        }
        if added { changed() }
    }

    /// Changes a transaction recorded earlier.
    public func update(_ id: UUID, _ change: (inout NetworkTransaction) -> Void) {
        let updated = state.withLock { state -> Bool in
            guard state.isRecording, var transaction = state.transactions[id] else { return false }
            let before = transaction.storedBytes
            change(&transaction)
            state.transactions[id] = transaction
            state.storedBytes += transaction.storedBytes - before
            Self.keepWithinBudget(&state)
            state.pendingWrites.insert(id)
            return true
        }
        if updated { changed() }
    }

    /// Newest first.
    public var transactions: [NetworkTransaction] {
        state.withLock { state in state.order.reversed().compactMap { state.transactions[$0] } }
    }

    public func transaction(_ id: UUID) -> NetworkTransaction? {
        state.withLock { $0.transactions[id] }
    }

    public func clear() {
        state.withLock { state in
            state.transactions = [:]
            state.order = []
            state.pendingWrites = []
            state.storedBytes = 0
        }
        let directory = directory
        writer.async {
            try? FileManager.default.removeItem(at: directory)
        }
        changed()
    }

    /// Fires whenever something was recorded or changed; the panel refreshes on it.
    public func changes() -> AsyncStream<Void> {
        let (stream, continuation) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        let id = UUID()
        state.withLock { $0.observers[id] = continuation }
        continuation.onTermination = { [weak self] _ in
            self?.state.withLock { _ = $0.observers.removeValue(forKey: id) }
        }
        return stream
    }

    // MARK: Connections

    /// Starts recording a connection the app reports, such as a WebSocket or a Nearby
    /// connection. Returns `nil` when Backstage is off, so the app's calls cost nothing.
    public func openConnection(kind: NetworkTransaction.Kind, url: URL?, headers: [String: String] = [:], note: String? = nil) -> ConnectionRecording? {
        guard isRecording else { return nil }
        var transaction = NetworkTransaction(kind: kind, launchID: launchID, url: url, method: nil, requestHeaders: headers)
        transaction.note = note
        add(transaction)
        return ConnectionRecording(id: transaction.id, recorder: self)
    }

    // MARK: Limits

    private static func trim(_ state: inout State) {
        while state.order.count > state.limits.maximumTransactions {
            let oldest = state.order.removeFirst()
            state.storedBytes -= state.transactions.removeValue(forKey: oldest)?.storedBytes ?? 0
            state.pendingWrites.remove(oldest)
        }
        keepWithinBudget(&state)
    }

    private static func keepWithinBudget(_ state: inout State) {
        var index = 0
        while state.storedBytes > state.limits.bodyBudget, index < state.order.count {
            let id = state.order[index]
            if var transaction = state.transactions[id], transaction.storedBytes > 0 {
                state.storedBytes -= transaction.storedBytes
                transaction.dropBodies()
                state.transactions[id] = transaction
                state.pendingWrites.insert(id)
            }
            index += 1
        }
    }

    private func changed() {
        let observers = state.withLock { Array($0.observers.values) }
        for observer in observers {
            observer.yield()
        }
        scheduleWrite()
    }

    // MARK: Files

    /// Writes changed transactions about once a second.
    private func scheduleWrite() {
        let shouldSchedule = state.withLock { state -> Bool in
            guard !state.isWriteScheduled, !state.pendingWrites.isEmpty else { return false }
            state.isWriteScheduled = true
            return true
        }
        guard shouldSchedule else { return }
        writer.asyncAfter(deadline: .now() + 1) { [self] in
            writePending()
        }
    }

    /// Writes what's waiting now, for example when the app moves to the background.
    public func flush() {
        writer.sync { writePending() }
    }

    private func writePending() {
        let (transactions, keep) = state.withLock { state -> ([NetworkTransaction], Set<UUID>) in
            let pending = state.pendingWrites.compactMap { state.transactions[$0] }
            state.pendingWrites = []
            state.isWriteScheduled = false
            return (pending, Set(state.order))
        }
        let fileManager = FileManager.default
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        for transaction in transactions {
            guard let data = try? encoder.encode(transaction) else { continue }
            try? data.write(to: fileURL(for: transaction), options: .atomic)
        }
        // Files of transactions that were trimmed away.
        if let files = try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            for file in files where file.pathExtension == "json" {
                if let id = UUID(uuidString: String(file.deletingPathExtension().lastPathComponent.suffix(36))), !keep.contains(id) {
                    try? fileManager.removeItem(at: file)
                }
            }
        }
    }

    private func fileURL(for transaction: NetworkTransaction) -> URL {
        let milliseconds = Int(transaction.startDate.timeIntervalSince1970 * 1_000)
        return directory.appending(path: "\(milliseconds)-\(transaction.id.uuidString).json")
    }

    /// Loads what earlier launches recorded. Transactions left unfinished by a launch that ended
    /// are marked as such.
    func loadPrevious() {
        let fileManager = FileManager.default
        guard let files = try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return }
        let decoder = JSONDecoder()
        let launchID = launchID
        var loaded = files
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .compactMap { file -> NetworkTransaction? in
                guard let data = try? Data(contentsOf: file) else { return nil }
                return try? decoder.decode(NetworkTransaction.self, from: data)
            }
        for index in loaded.indices where loaded[index].endDate == nil && loaded[index].launchID != launchID {
            loaded[index].endDate = loaded[index].messages.last?.date ?? loaded[index].startDate
            loaded[index].errorDescription = loaded[index].errorDescription ?? "The app stopped before this finished."
        }
        state.withLock { state in
            // Stopped meanwhile, such as an App Store build forgetting what it recorded.
            guard state.isRecording else { return }
            var merged = state.transactions
            for transaction in loaded where merged[transaction.id] == nil {
                merged[transaction.id] = transaction
            }
            state.transactions = merged
            state.order = merged.values.sorted { $0.startDate < $1.startDate }.map(\.id)
            state.storedBytes = merged.values.reduce(0) { $0 + $1.storedBytes }
            Self.trim(&state)
        }
        changed()
    }
}

/// A connection being recorded. Each call adds to its transaction.
public struct ConnectionRecording: Sendable {
    public let id: UUID
    let recorder: NetworkRecorder

    /// The connection is open; for a WebSocket, the server's handshake response.
    public func opened(statusCode: Int? = nil, headers: [String: String] = [:]) {
        recorder.update(id) { transaction in
            transaction.statusCode = statusCode
            transaction.responseHeaders = headers
        }
    }

    public func sent(_ data: Data) {
        append(data, direction: .sent)
    }

    public func received(_ data: Data) {
        append(data, direction: .received)
    }

    public func sent(text: String) {
        append(Data(text.utf8), direction: .sent)
    }

    public func received(text: String) {
        append(Data(text.utf8), direction: .received)
    }

    /// Replaces what the app says about the connection, such as who is on the other end.
    public func note(_ note: String) {
        recorder.update(id) { $0.note = note }
    }

    /// The connection ended; with an error when it failed.
    public func closed(error: (any Error)? = nil) {
        recorder.update(id) { transaction in
            transaction.endDate = .now
            if let error {
                transaction.errorDescription = String(describing: error)
            }
        }
    }

    private func append(_ data: Data, direction: NetworkTransaction.Direction) {
        let limit = recorder.limits.maximumBodySize
        recorder.update(id) { transaction in
            transaction.messages.append(NetworkTransaction.Message(id: UUID(), date: .now, direction: direction, body: NetworkTransaction.Body(data, limit: limit)))
        }
    }
}
