import BackstageCore
import ObjectiveC
import SwiftUI
import UserNotifications
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

// MARK: Deep links

/// Opens a link as if it came from outside the app, with a history of the ones tried.
struct DeepLinksView: View {
    @AppStorage("Backstage.deepLinks.history") private var historyText = ""
    @State private var link = ""
    @State private var universalOnly = false
    @State private var message: String?

    private var history: [String] {
        historyText.split(separator: "\n").map(String.init)
    }

    private var url: URL? {
        let trimmed = link.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), url.scheme != nil else { return nil }
        return url
    }

    var body: some View {
        Form {
            Section {
                TextField("myapp://orders/42", text: $link, axis: .vertical)
                    .font(.callout.monospaced())
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                    #endif
                    .onSubmit(open)
                Toggle("Universal Links Only", isOn: $universalOnly)
                Button("Open", systemImage: "arrow.up.forward.app", action: open)
                    .disabled(url == nil)
                if let message {
                    Text(message).font(.footnote).foregroundStyle(.orange)
                }
            } footer: {
                if Self.schemes.isEmpty {
                    Text("Backstage closes and the link opens as if tapped elsewhere. The app has no link schemes of its own; web links open in the app only if it handles them as universal links.")
                } else {
                    Text("Backstage closes and the link opens as if tapped elsewhere. The app's schemes: \(Self.schemes.map { "\($0)://" }.joined(separator: ", ")).")
                }
            }

            if !history.isEmpty {
                Section("Recent") {
                    ForEach(history, id: \.self) { item in
                        Button {
                            link = item
                        } label: {
                            Text(item).font(.callout.monospaced()).foregroundStyle(.primary).lineLimit(2)
                        }
                    }
                    .onDelete { offsets in
                        var items = history
                        items.remove(atOffsets: offsets)
                        historyText = items.joined(separator: "\n")
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Deep Links")
    }

    private func open() {
        guard let url else { return }
        message = nil
        historyText = ([url.absoluteString] + history.filter { $0 != url.absoluteString }).prefix(20).joined(separator: "\n")
        let universalOnly = universalOnly
        #if os(iOS)
        Backstage.shared.isPanelPresented = false
        Task {
            // Once the panel is out of the way.
            try? await Task.sleep(for: .milliseconds(500))
            let opened = await UIApplication.shared.open(url, options: universalOnly ? [.universalLinksOnly: true] : [:])
            if !opened {
                message = universalOnly ? "No app handles this as a universal link." : "Nothing could open this link."
                Backstage.shared.isPanelPresented = true
            }
        }
        #elseif os(macOS)
        if !NSWorkspace.shared.open(url) {
            message = "Nothing could open this link."
        }
        #endif
    }

    /// The URL schemes the app registers in its Info.plist.
    static var schemes: [String] {
        let types = Bundle.main.object(forInfoDictionaryKey: "CFBundleURLTypes") as? [[String: Any]] ?? []
        return types.flatMap { ($0["CFBundleURLSchemes"] as? [String]) ?? [] }
    }
}

// MARK: Notifications

/// The notifications the app received, and a test one to send.
struct NotificationsView: View {
    @State private var records: [NotificationRecord] = []

    var body: some View {
        List {
            Section {
                NavigationLink {
                    TestNotificationView()
                } label: {
                    Label("Send a Test Notification", systemImage: "paperplane")
                }
            } footer: {
                Text("Arrives through the app's own notification handling, with any payload. On the simulator, `xcrun simctl push booted \(Bundle.main.bundleIdentifier ?? "<bundle ID>") payload.apns` sends a real push.")
            }
            Section {
                if records.isEmpty {
                    Text("None yet").foregroundStyle(.secondary)
                }
                ForEach(records) { record in
                    NavigationLink {
                        NotificationDetailView(record: record)
                    } label: {
                        NotificationRow(record: record)
                    }
                }
            } header: {
                Text("Received")
            } footer: {
                Text("Those that arrive while the app is open, those tapped, and those left in Notification Center. A silent push can be handed over with Backstage.recordRemoteNotification(_:).")
            }
        }
        .navigationTitle("Notifications")
        .task {
            await Backstage.readNotificationCenter()
            for await _ in AppActivity.notifications.changesIncludingNow() {
                records = AppActivity.notifications.events.reversed()
            }
        }
    }
}

struct NotificationRow: View {
    let record: NotificationRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(record.event.title + (record.isRemote ? " · Push" : ""))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(BackstageStyle.accent)
                Spacer()
                Text(record.date, format: BackstageStyle.time).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
            }
            Text(record.title.isEmpty ? "(no title)" : record.title).font(.subheadline.weight(.semibold))
            if !record.body.isEmpty {
                Text(record.body).font(.footnote).foregroundStyle(.secondary).lineLimit(2)
            }
        }
    }
}

struct NotificationDetailView: View {
    let record: NotificationRecord

    var body: some View {
        List {
            Section {
                LabeledContent("What", value: record.event.title)
                LabeledContent("When", value: record.date.formatted(date: .abbreviated, time: .standard))
                LabeledContent("From", value: record.isRemote ? "A push" : "The app")
                if let action = record.action {
                    LabeledContent("Action", value: action)
                }
                if !record.category.isEmpty {
                    LabeledContent("Category", value: record.category)
                }
                LabeledContent("Identifier") { Text(record.identifier).textSelection(.enabled) }
            }
            Section("Content") {
                LabeledContent("Title", value: record.title)
                if !record.subtitle.isEmpty {
                    LabeledContent("Subtitle", value: record.subtitle)
                }
                Text(record.body).textSelection(.enabled)
            }
            Section("Payload") {
                Text(record.prettyPayload)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
            }
        }
        .navigationTitle(record.title.isEmpty ? "Notification" : record.title)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Copy Payload", systemImage: "doc.on.doc") { copyToClipboard(record.prettyPayload) }
            }
        }
    }
}

/// Schedules a notification with any title, body and payload, to test how the app handles it.
private struct TestNotificationView: View {
    @State private var title = "Test notification"
    @State private var bodyText = "Sent from Backstage"
    @State private var payload = "{\n  \"screen\": \"home\"\n}"
    @State private var delay: TimeInterval = 5
    @State private var status: UNAuthorizationStatus?
    @State private var message: String?

    private var payloadObject: [String: Any]? {
        let trimmed = payload.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return [:] }
        return (try? JSONSerialization.jsonObject(with: Data(trimmed.utf8))) as? [String: Any]
    }

    var body: some View {
        Form {
            Section("Content") {
                TextField("Title", text: $title)
                TextField("Body", text: $bodyText, axis: .vertical)
            }
            Section {
                TextField("{}", text: $payload, axis: .vertical)
                    .font(.caption.monospaced())
                    .lineLimit(3...12)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
                if payloadObject == nil {
                    Text("That isn't a JSON object.").font(.footnote).foregroundStyle(.orange)
                }
            } header: {
                Text("Payload")
            } footer: {
                Text("The notification's userInfo, as the app's handling sees it.")
            }
            Section {
                Picker("Arrives In", selection: $delay) {
                    ForEach([1, 5, 10, 30] as [TimeInterval], id: \.self) { Text("\(Int($0)) s").tag($0) }
                }
                switch status {
                case .notDetermined?:
                    Button("Allow Notifications", systemImage: "bell") { Task { await allow() } }
                case .denied?:
                    Button("Open Settings to Allow Notifications", systemImage: "gear", action: openSettings)
                default:
                    Button("Send", systemImage: "paperplane") { Task { await send() } }
                        .disabled(payloadObject == nil)
                }
                if let message {
                    Text(message).font(.footnote).foregroundStyle(.secondary)
                }
            } footer: {
                Text("Stay in the app to see how it handles one arriving, or leave it to see the banner and tap it. Allow Notifications asks with the app's own permission prompt.")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Test Notification")
        .task { await refreshStatus() }
    }

    private func refreshStatus() async {
        status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    private func allow() async {
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
        await refreshStatus()
    }

    private func send() async {
        guard let userInfo = payloadObject else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = bodyText
        content.sound = .default
        content.userInfo = userInfo
        let request = UNNotificationRequest(identifier: "backstage-test-\(UUID().uuidString)", content: content, trigger: UNTimeIntervalNotificationTrigger(timeInterval: delay, repeats: false))
        do {
            try await UNUserNotificationCenter.current().add(request)
            message = "Arrives in \(Int(delay)) s."
        } catch {
            message = error.localizedDescription
        }
    }
}

// MARK: Permissions

/// What the app was allowed to use, without asking.
struct PermissionsView: View {
    @State private var rows: [(String, String, PermissionState)] = []

    enum PermissionState {
        case notAsked, allowed, limited(String), denied, restricted

        var text: String {
            switch self {
            case .notAsked: "Not asked"
            case .allowed: "Allowed"
            case .limited(let detail): detail
            case .denied: "Denied"
            case .restricted: "Restricted"
            }
        }

        var color: Color {
            switch self {
            case .notAsked: .secondary
            case .allowed: .green
            case .limited: .orange
            case .denied, .restricted: .red
            }
        }

        /// The status the frameworks share: 0 not asked, 1 restricted, 2 denied, 3 allowed, and
        /// a limited kind past that.
        init(status: Int, limited: String? = nil) {
            switch status {
            case 0: self = .notAsked
            case 1: self = .restricted
            case 2: self = .denied
            case 3: self = .allowed
            default: self = limited.map(PermissionState.limited) ?? .allowed
            }
        }
    }

    var body: some View {
        Form {
            Section {
                ForEach(rows, id: \.0) { name, icon, state in
                    LabeledContent {
                        Text(state.text).foregroundStyle(state.color)
                    } label: {
                        Label(name, systemImage: icon)
                    }
                }
            } footer: {
                Text("Read without asking: notifications, and those the app's Info.plist has a usage description for. Local network access has no way to be read.")
            }
            Section {
                Button("Open the App's Settings", systemImage: "gear", action: openSettings)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Permissions")
        .task { rows = await Self.read() }
    }

    /// A permission the app can ask for, read through the Objective-C runtime so Backstage doesn't
    /// link its framework: App Store Connect asks every app that uses these frameworks for a
    /// usage description, even one that never asks.
    private struct Permission {
        let name: String
        let icon: String
        /// Any of these in the Info.plist means the app asks.
        let usageKeys: [String]
        let framework: String
        let className: String
        let selector: String
        let argument: Argument
        var limited: String?

        enum Argument {
            case none
            case number(Int)
            case text(String)
        }
    }

    private static let permissions = [
        Permission(name: "Camera", icon: "camera", usageKeys: ["NSCameraUsageDescription"], framework: "AVFoundation", className: "AVCaptureDevice", selector: "authorizationStatusForMediaType:", argument: .text("vide")),
        Permission(name: "Microphone", icon: "mic", usageKeys: ["NSMicrophoneUsageDescription"], framework: "AVFoundation", className: "AVCaptureDevice", selector: "authorizationStatusForMediaType:", argument: .text("soun")),
        Permission(name: "Photos", icon: "photo", usageKeys: ["NSPhotoLibraryUsageDescription", "NSPhotoLibraryAddUsageDescription"], framework: "Photos", className: "PHPhotoLibrary", selector: "authorizationStatusForAccessLevel:", argument: .number(2), limited: "Selected Photos"),
        Permission(name: "Contacts", icon: "person.crop.circle", usageKeys: ["NSContactsUsageDescription"], framework: "Contacts", className: "CNContactStore", selector: "authorizationStatusForEntityType:", argument: .number(0), limited: "Selected Contacts"),
        Permission(name: "Calendars", icon: "calendar", usageKeys: ["NSCalendarsFullAccessUsageDescription", "NSCalendarsWriteOnlyAccessUsageDescription", "NSCalendarsUsageDescription"], framework: "EventKit", className: "EKEventStore", selector: "authorizationStatusForEntityType:", argument: .number(0), limited: "Add Only"),
        Permission(name: "Reminders", icon: "list.bullet", usageKeys: ["NSRemindersFullAccessUsageDescription", "NSRemindersUsageDescription"], framework: "EventKit", className: "EKEventStore", selector: "authorizationStatusForEntityType:", argument: .number(1)),
        Permission(name: "Bluetooth", icon: "dot.radiowaves.left.and.right", usageKeys: ["NSBluetoothAlwaysUsageDescription"], framework: "CoreBluetooth", className: "CBManager", selector: "authorization", argument: .none),
        Permission(name: "Motion & Fitness", icon: "figure.walk", usageKeys: ["NSMotionUsageDescription"], framework: "CoreMotion", className: "CMMotionActivityManager", selector: "authorizationStatus", argument: .none),
        Permission(name: "Tracking", icon: "hand.raised", usageKeys: ["NSUserTrackingUsageDescription"], framework: "AppTrackingTransparency", className: "ATTrackingManager", selector: "trackingAuthorizationStatus", argument: .none)
    ]

    static func read() async -> [(String, String, PermissionState)] {
        var rows: [(String, String, PermissionState)] = []
        let notifications = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        rows.append(("Notifications", "bell", {
            switch notifications {
            case .notDetermined: .notAsked
            case .denied: .denied
            case .provisional: .limited("Provisional")
            case .ephemeral: .limited("Ephemeral")
            default: .allowed
            }
        }()))
        if asks(for: ["NSLocationWhenInUseUsageDescription", "NSLocationAlwaysAndWhenInUseUsageDescription", "NSLocationUsageDescription"]) {
            // Read from a manager made at run time, like the others: Backstage doesn't link
            // CoreLocation. 4 is while using; 3 always.
            if NSClassFromString("CLLocationManager") == nil {
                Bundle(path: "/System/Library/Frameworks/CoreLocation.framework")?.load()
            }
            if let manager = (NSClassFromString("CLLocationManager") as? NSObject.Type)?.init(),
               let status = manager.value(forKey: "authorizationStatus") as? Int {
                rows.append(("Location", "location", PermissionState(status: status, limited: "While Using")))
            }
        }
        for permission in permissions where asks(for: permission.usageKeys) {
            if let status = status(of: permission) {
                rows.append((permission.name, permission.icon, PermissionState(status: status, limited: permission.limited)))
            }
        }
        return rows
    }

    private static func asks(for usageKeys: [String]) -> Bool {
        usageKeys.contains { Bundle.main.object(forInfoDictionaryKey: $0) != nil }
    }

    /// Calls the framework's class method for its status, loading the framework if the app
    /// hasn't yet.
    private static func status(of permission: Permission) -> Int? {
        if NSClassFromString(permission.className) == nil {
            Bundle(path: "/System/Library/Frameworks/\(permission.framework).framework")?.load()
        }
        let selector = NSSelectorFromString(permission.selector)
        guard let cls = NSClassFromString(permission.className),
              let method = class_getClassMethod(cls, selector) else { return nil }
        let implementation = method_getImplementation(method)
        switch permission.argument {
        case .none:
            typealias Status = @convention(c) (AnyClass, Selector) -> Int
            return unsafeBitCast(implementation, to: Status.self)(cls, selector)
        case .number(let number):
            typealias Status = @convention(c) (AnyClass, Selector, Int) -> Int
            return unsafeBitCast(implementation, to: Status.self)(cls, selector, number)
        case .text(let text):
            typealias Status = @convention(c) (AnyClass, Selector, NSString) -> Int
            return unsafeBitCast(implementation, to: Status.self)(cls, selector, text as NSString)
        }
    }
}

/// The app's page in Settings.
@MainActor
private func openSettings() {
    #if os(iOS)
    if let url = URL(string: UIApplication.openSettingsURLString) {
        UIApplication.shared.open(url)
    }
    #elseif os(macOS)
    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy") {
        NSWorkspace.shared.open(url)
    }
    #endif
}

extension EventLog {
    /// Fires at once and then whenever something changes, for a view that shows the list.
    func changesIncludingNow() -> AsyncStream<Void> {
        let changes = changes()
        return AsyncStream { continuation in
            continuation.yield()
            let task = Task {
                for await _ in changes { continuation.yield() }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
