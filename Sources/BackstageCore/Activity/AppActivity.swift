import Foundation
import Synchronization

/// A list of things that happened, oldest first, kept to the last `limit`. Safe to use from any
/// thread; the panel watches it. With a file, it's kept across launches.
public final class EventLog<Event: Codable & Sendable>: Sendable {
    private let state = Mutex<[Event]?>(nil)
    private let observers = Mutex<[UUID: AsyncStream<Void>.Continuation]>([:])
    private let limit: Int
    private let file: URL?

    init(limit: Int, file: URL? = nil) {
        self.limit = limit
        self.file = file
    }

    /// Oldest first.
    public var events: [Event] {
        state.withLock { state in loaded(&state) }
    }

    func add(_ event: Event) {
        state.withLock { state in
            var events = loaded(&state)
            events.append(event)
            if events.count > limit { events.removeFirst(events.count - limit) }
            state = events
            // Under the lock, so a write never replaces a newer one.
            save(events)
        }
        changed()
    }

    public func clear() {
        state.withLock { $0 = [] }
        if let file { try? FileManager.default.removeItem(at: file) }
        changed()
    }

    /// Fires whenever something was added or the log was cleared.
    public func changes() -> AsyncStream<Void> {
        let (stream, continuation) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        let id = UUID()
        observers.withLock { $0[id] = continuation }
        continuation.onTermination = { [weak self] _ in
            self?.observers.withLock { _ = $0.removeValue(forKey: id) }
        }
        return stream
    }

    private func loaded(_ state: inout [Event]?) -> [Event] {
        if let state { return state }
        let events = file.flatMap { try? Data(contentsOf: $0) }.flatMap { try? JSONDecoder().decode([Event].self, from: $0) } ?? []
        state = events
        return events
    }

    private func save(_ events: [Event]) {
        guard let file else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(events).write(to: file, options: .atomic)
    }

    private func changed() {
        for observer in observers.withLock({ Array($0.values) }) {
            observer.yield()
        }
    }
}

/// A screen the app showed.
public struct ScreenVisit: Codable, Sendable, Identifiable, Hashable {
    public var id = UUID()
    public var date = Date.now
    public var name: String
    /// The view controller's class, when it was noticed on its own rather than named by the app.
    public var className: String?
}

/// A notification the app received.
public struct NotificationRecord: Codable, Sendable, Identifiable, Hashable {
    public enum Event: String, Codable, Sendable {
        /// Arrived while the app was open.
        case arrived
        /// Tapped, or one of its actions chosen.
        case opened
        /// Found in Notification Center: it arrived while the app wasn't watching.
        case inNotificationCenter
        /// A push the app handed over itself, such as a silent one.
        case reportedByApp

        public var title: String {
            switch self {
            case .arrived: "Arrived"
            case .opened: "Opened"
            case .inNotificationCenter: "In Notification Center"
            case .reportedByApp: "Received"
            }
        }
    }

    public var id = UUID()
    public var date = Date.now
    public var event: Event
    /// The request's identifier, the same each time the same notification is seen.
    public var identifier: String
    public var title: String
    public var subtitle: String
    public var body: String
    public var category: String
    /// A push from a server, rather than one the app scheduled.
    public var isRemote: Bool
    /// The action chosen, for an opened notification.
    public var action: String?
    /// The custom payload, as JSON.
    public var payload: Data

    /// The payload laid out for reading.
    public var prettyPayload: String {
        guard let object = try? JSONSerialization.jsonObject(with: payload),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) else {
            return String(decoding: payload, as: UTF8.self)
        }
        return String(decoding: data, as: UTF8.self)
    }

    /// Any values, such as a notification's user info, as JSON. What JSON can't hold is written
    /// as text.
    static func json(_ value: [AnyHashable: Any]) -> Data {
        func plain(_ value: Any) -> Any {
            switch value {
            case let dictionary as [AnyHashable: Any]:
                return Dictionary(dictionary.map { (String(describing: $0.key), plain($0.value)) }, uniquingKeysWith: { first, _ in first })
            case let array as [Any]: return array.map(plain)
            case is String, is NSNumber, is NSNull: return value
            case let date as Date: return ISO8601DateFormatter().string(from: date)
            case let data as Data: return data.base64EncodedString()
            default: return String(describing: value)
            }
        }
        return (try? JSONSerialization.data(withJSONObject: plain(value), options: [.sortedKeys])) ?? Data("{}".utf8)
    }
}

/// An object expected to be gone that was still in memory: often a retain cycle.
public struct LeakSuspect: Sendable, Identifiable, Hashable, Codable {
    public var id = UUID()
    /// When it should have been freed.
    public var expectedAt: Date
    public var name: String
    /// How long it was given.
    public var waited: TimeInterval
}

/// What the app did, for the timeline: screens, notifications and objects that weren't freed.
public enum AppActivity {
    /// This launch's screens.
    public static let screens = EventLog<ScreenVisit>(limit: 500)
    /// Kept across launches in the app's Caches.
    public static let notifications = EventLog<NotificationRecord>(limit: 200, file: Folders.caches.appending(path: "Notifications.json"))
    /// This launch's suspected leaks.
    public static let leaks = EventLog<LeakSuspect>(limit: 200)

    /// Leak suspects, by ID, held weakly to check again when the panel shows them.
    private static let suspects = Mutex<[UUID: WeakObject]>([:])

    /// Whether a suspected leak is still in memory now; it may have been freed late.
    public static func isStillInMemory(_ suspect: LeakSuspect) -> Bool {
        suspects.withLock { $0[suspect.id]?.object != nil }
    }

    static func addLeak(_ suspect: LeakSuspect, object: WeakObject) {
        suspects.withLock { $0[suspect.id] = object }
        leaks.add(suspect)
    }

    /// Forgets the activity, the notifications kept on disk too.
    static func clear() {
        screens.clear()
        notifications.clear()
        leaks.clear()
    }
}

/// Holds an object without keeping it alive.
final class WeakObject: @unchecked Sendable {
    weak var object: AnyObject?

    init(_ object: AnyObject) {
        self.object = object
    }
}

extension Backstage {
    /// Notes that the app shows a screen, for the timeline. UIKit screens are noticed on their own;
    /// SwiftUI ones can use `.backstageScreen(_:)`. Does nothing while Backstage is off.
    public nonisolated static func screen(_ name: String, className: String? = nil) {
        guard isActive else { return }
        let last = AppActivity.screens.events.last
        // The same screen appearing again at once, as SwiftUI views can, counts once.
        if last?.name == name, let date = last?.date, Date.now.timeIntervalSince(date) < 1 { return }
        AppActivity.screens.add(ScreenVisit(name: name, className: className))
    }

    /// Checks that an object is freed soon, such as a view model when its screen closes. If it's
    /// still in memory after `seconds`, the panel lists it as a possible leak. Does nothing while
    /// Backstage is off.
    public nonisolated static func expectRelease(of object: AnyObject, name: String? = nil, within seconds: TimeInterval = 3) {
        guard isActive else { return }
        let weak = WeakObject(object)
        let name = name ?? String(describing: type(of: object))
        let expected = Date.now.addingTimeInterval(seconds)
        Task.detached {
            try? await Task.sleep(for: .seconds(seconds))
            guard weak.object != nil, isActive else { return }
            AppActivity.addLeak(LeakSuspect(expectedAt: expected, name: name, waited: seconds), object: weak)
        }
    }

    /// Hands over a push the app received that Backstage can't see on its own, such as a silent
    /// one in `application(_:didReceiveRemoteNotification:fetchCompletionHandler:)`. Does nothing
    /// while Backstage is off.
    public nonisolated static func recordRemoteNotification(_ userInfo: [AnyHashable: Any]) {
        guard isActive else { return }
        let aps = userInfo["aps"] as? [AnyHashable: Any]
        let alert = aps?["alert"]
        let alertFields = alert as? [AnyHashable: Any]
        AppActivity.notifications.add(NotificationRecord(
            event: .reportedByApp,
            identifier: UUID().uuidString,
            title: (alertFields?["title"] as? String) ?? "",
            subtitle: (alertFields?["subtitle"] as? String) ?? "",
            body: (alertFields?["body"] as? String) ?? (alert as? String) ?? "",
            category: (aps?["category"] as? String) ?? "",
            isRemote: true,
            payload: NotificationRecord.json(userInfo)
        ))
    }
}
