import BackstageCore
import Darwin
import SwiftUI

/// One thing that happened, for the timeline.
struct TimelineEvent: Identifiable {
    enum Kind: String, CaseIterable, Identifiable {
        case screen, network, log, notification, hang, leak, report
        var id: String { rawValue }

        var title: String {
            switch self {
            case .screen: "Screens"
            case .network: "Network"
            case .log: "Logs"
            case .notification: "Notifications"
            case .hang: "Hangs"
            case .leak: "Leaks"
            case .report: "iOS Reports"
            }
        }

        var icon: String {
            switch self {
            case .screen: "rectangle.portrait"
            case .network: "network"
            case .log: "text.alignleft"
            case .notification: "bell"
            case .hang: "hourglass"
            case .leak: "drop"
            case .report: "exclamationmark.triangle"
            }
        }
    }

    enum Source {
        case screen(ScreenVisit)
        case network(NetworkTransaction)
        case log(LogEntry)
        case notification(NotificationRecord)
        case hang(PerformanceMonitor.Hang)
        case leak(LeakSuspect)
        case report(IOSDiagnostic, IOSReport)
    }

    let id: String
    let date: Date
    let kind: Kind
    let title: String
    let detail: String
    let color: Color
    let source: Source

    /// One line of text, for a bug report.
    var line: String {
        "\(date.formatted(.iso8601.time(includingFractionalSeconds: true))) [\(kind.title)] \(title)\(detail.isEmpty ? "" : " — \(detail)")"
    }
}

/// Gathers the timeline from Backstage's records. Logs are read when the timeline is shown.
@MainActor
@Observable
final class TimelineModel {
    static let shared = TimelineModel()

    private(set) var logs: [LogEntry] = []
    private(set) var isLoadingLogs = false
    private(set) var logError: String?
    private(set) var screens: [ScreenVisit] = []
    private(set) var notifications: [NotificationRecord] = []
    private(set) var leaks: [LeakSuspect] = []
    @ObservationIgnored private var isWatching = false
    /// Goes up whenever the screens, notifications, leaks or logs change.
    @ObservationIgnored private var revision = 0
    /// The last events made, until something they come from changes.
    @ObservationIgnored private var cache: (key: CacheKey, events: [TimelineEvent])?

    private struct CacheKey: Equatable {
        let earlier: Bool
        let appLogsOnly: Bool
        let revision: Int
        let network: Int
        let reports: Int
        let hangs: [UUID]
    }

    /// When this launch began.
    static let launchDate: Date = {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&name, 4, &info, &size, nil, 0) == 0 else { return .now }
        let start = info.kp_proc.p_un.__p_starttime
        return Date(timeIntervalSince1970: Double(start.tv_sec) + Double(start.tv_usec) / 1_000_000)
    }()

    func watch() {
        guard !isWatching else { return }
        isWatching = true
        NetworkModel.shared.watch()
        IOSReportModel.shared.watch()
        follow(AppActivity.screens) { [weak self] in self?.screens = $0 }
        follow(AppActivity.notifications) { [weak self] in self?.notifications = $0 }
        follow(AppActivity.leaks) { [weak self] in self?.leaks = $0 }
    }

    /// The events, made again only when something they come from has changed since; while the
    /// timeline isn't watching, always made again.
    func cachedEvents(earlier: Bool, appLogsOnly: Bool) -> [TimelineEvent] {
        // Read so a view showing these follows them.
        _ = (screens.count, notifications.count, leaks.count)
        guard isWatching else { return events(earlier: earlier, appLogsOnly: appLogsOnly) }
        let key = CacheKey(
            earlier: earlier,
            appLogsOnly: appLogsOnly,
            revision: revision,
            network: NetworkModel.shared.revision,
            reports: IOSReportModel.shared.diagnostics.count,
            hangs: PerformanceMonitor.shared.hangs.map(\.id)
        )
        if let cache, cache.key == key { return cache.events }
        let events = events(earlier: earlier, appLogsOnly: appLogsOnly)
        cache = (key, events)
        return events
    }

    private func follow<Event>(_ log: EventLog<Event>, update: @escaping @MainActor ([Event]) -> Void) {
        Task {
            for await _ in log.changesIncludingNow() {
                update(log.events)
                revision += 1
            }
        }
    }

    func loadLogs() async {
        isLoadingLogs = true
        defer { isLoadingLogs = false }
        do {
            logs = try await LogReader.entries()
            revision += 1
            logError = nil
        } catch {
            logError = error.localizedDescription
        }
    }

    /// Everything, newest first. Without `earlier`, only this launch. Read from the records
    /// themselves, so a bug report has them even if the timeline was never opened.
    func events(earlier: Bool, appLogsOnly: Bool) -> [TimelineEvent] {
        // Read so a view showing these follows them.
        _ = (screens.count, notifications.count, leaks.count)
        let since = earlier ? Date.distantPast : Self.launchDate.addingTimeInterval(-1)
        let launch = NetworkRecorder.shared.launchID
        var events: [TimelineEvent] = []
        for screen in AppActivity.screens.events {
            events.append(TimelineEvent(id: screen.id.uuidString, date: screen.date, kind: .screen, title: screen.name, detail: screen.className.map { $0 == screen.name ? "" : $0 } ?? "", color: .indigo, source: .screen(screen)))
        }
        for call in NetworkRecorder.shared.transactions where call.launchID == launch || earlier {
            let status = call.isComplete ? (call.statusCode.map(String.init) ?? "Failed") : "…"
            events.append(TimelineEvent(
                id: call.id.uuidString,
                date: call.startDate,
                kind: .network,
                title: "\(call.badge) \(call.title)",
                detail: [status, call.host, call.duration.map { BackstageStyle.duration($0) }].compactMap { $0 }.joined(separator: " · "),
                color: call.isComplete ? BackstageStyle.color(forStatus: call.statusCode, failed: call.isFailure) : .secondary,
                source: .network(call)
            ))
        }
        for entry in logs where !appLogsOnly || entry.isFromApp {
            events.append(TimelineEvent(id: "log-\(entry.id)", date: entry.date, kind: .log, title: entry.message, detail: [entry.level.title, entry.category].filter { !$0.isEmpty }.joined(separator: " · "), color: LogRow.color(entry.level), source: .log(entry)))
        }
        for record in AppActivity.notifications.events {
            events.append(TimelineEvent(id: record.id.uuidString, date: record.date, kind: .notification, title: record.title.isEmpty ? "(no title)" : record.title, detail: record.event.title + (record.isRemote ? " · Push" : ""), color: .pink, source: .notification(record)))
        }
        for hang in PerformanceMonitor.shared.hangs {
            events.append(TimelineEvent(id: hang.id.uuidString, date: hang.date, kind: .hang, title: "Main thread hung for \(BackstageStyle.duration(hang.duration))", detail: "", color: .orange, source: .hang(hang)))
        }
        for leak in AppActivity.leaks.events {
            events.append(TimelineEvent(id: leak.id.uuidString, date: leak.expectedAt, kind: .leak, title: "\(leak.name) still in memory", detail: "\(Int(leak.waited)) s after it closed", color: .purple, source: .leak(leak)))
        }
        for (diagnostic, report) in IOSReportModel.shared.diagnostics {
            events.append(TimelineEvent(id: diagnostic.id, date: diagnostic.date, kind: .report, title: diagnostic.kind.title, detail: diagnostic.summary, color: diagnostic.kind == .crash ? .red : .orange, source: .report(diagnostic, report)))
        }
        return events.filter { $0.date >= since }.sorted { $0.date > $1.date }
    }

    /// The last stretch of this launch as text, oldest first, for a bug report. Logs go in their
    /// own file.
    func text(since: Date) -> String {
        events(earlier: false, appLogsOnly: true)
            .filter { $0.kind != .log && $0.date >= since }
            .reversed()
            .map(\.line)
            .joined(separator: "\n")
    }
}

/// The Timeline tab: what the app did, in order, with logs among it or alone.
struct TimelineView: View {
    @State private var model = TimelineModel.shared
    @State private var networkModel = NetworkModel.shared
    @State private var reports = IOSReportModel.shared
    @State private var monitor = PerformanceMonitor.shared
    @State private var search = ""
    /// Empty shows every kind.
    @State private var kinds: Set<TimelineEvent.Kind> = []
    @AppStorage("Backstage.logs.minimumLevel") private var minimumLevel = LogEntry.Level.debug.rawValue
    /// The system's own messages (UIKit, networking, Security…) far outnumber the app's.
    @AppStorage("Backstage.logs.appOnly") private var appOnly = true
    @AppStorage("Backstage.timeline.earlier") private var earlier = false
    @State private var category: String?

    private var all: [TimelineEvent] {
        // Read so the list follows them.
        _ = (networkModel.transactions.count, reports.diagnostics.count, monitor.hangs.count)
        return model.cachedEvents(earlier: earlier, appLogsOnly: appOnly).filter { event in
            guard case .log(let entry) = event.source else { return true }
            return entry.level.rawValue >= minimumLevel && (category == nil || entry.category == category)
        }
    }

    private func shown(_ all: [TimelineEvent]) -> [TimelineEvent] {
        all.filter { event in
            (kinds.isEmpty || kinds.contains(event.kind))
                && (search.isEmpty || event.title.localizedCaseInsensitiveContains(search) || event.detail.localizedCaseInsensitiveContains(search))
        }
    }

    private var categories: [String] {
        Array(Set(model.logs.filter { !appOnly || $0.isFromApp }.map(\.category))).filter { !$0.isEmpty }.sorted()
    }

    var body: some View {
        let all = all
        let shown = shown(all)
        List {
            Section {
                KindChips(events: all, selection: $kinds)
                    .listRowInsets(EdgeInsets(top: 6, leading: 0, bottom: 6, trailing: 0))
            }
            Section {
                ForEach(shown.prefix(1_000)) { event in
                    NavigationLink {
                        destination(event)
                    } label: {
                        TimelineRow(event: event)
                    }
                }
            } footer: {
                Text(earlier ? "\(shown.count) events" : "\(shown.count) events this launch. Crashes from earlier launches show with Earlier Launches on.")
            }
        }
        .overlay {
            if model.isLoadingLogs && all.isEmpty {
                ProgressView()
            } else if shown.isEmpty && !search.isEmpty {
                ContentUnavailableView.search(text: search)
            } else if shown.isEmpty {
                ContentUnavailableView("Nothing yet", systemImage: "clock", description: Text("Screens, calls, logs, notifications, hangs and leaks show here as they happen."))
            }
        }
        .searchable(text: $search, prompt: "Search")
        .navigationTitle("Timeline")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Toggle("Earlier Launches", systemImage: "clock.arrow.circlepath", isOn: $earlier)
                    Divider()
                    Section("Logs") {
                        Toggle("App's Messages Only", systemImage: "app", isOn: $appOnly)
                        Picker("Level", selection: $minimumLevel) {
                            ForEach(LogEntry.Level.allCases, id: \.self) { level in
                                Text(level == .debug ? "Every Level" : "\(level.title) and Above").tag(level.rawValue)
                            }
                        }
                        .pickerStyle(.menu)
                        Picker("Category", selection: $category) {
                            Text("Every Category").tag(String?.none)
                            ForEach(categories, id: \.self) { Text($0).tag(String?.some($0)) }
                        }
                        .pickerStyle(.menu)
                    }
                    Divider()
                    Button("Reload Logs", systemImage: "arrow.clockwise") { Task { await model.loadLogs() } }
                } label: {
                    Label("Options", systemImage: earlier || category != nil || minimumLevel != LogEntry.Level.debug.rawValue ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                }
            }
        }
        .onChange(of: appOnly) { category = nil }
        .refreshable { await model.loadLogs() }
        .task {
            model.watch()
            await Backstage.readNotificationCenter()
            await model.loadLogs()
        }
    }

    @ViewBuilder
    private func destination(_ event: TimelineEvent) -> some View {
        switch event.source {
        case .network(let call):
            TransactionDetailView(id: call.id)
        case .log(let entry):
            LogDetailView(entry: entry)
        case .notification(let record):
            NotificationDetailView(record: record)
        case .report(let diagnostic, let report):
            DiagnosticView(diagnostic: diagnostic, report: report)
        case .screen(let screen):
            InfoView(title: screen.name, lines: [
                ("Shown", screen.date.formatted(date: .abbreviated, time: .standard)),
                ("View controller", screen.className ?? "Named by the app")
            ], note: nil)
        case .hang(let hang):
            InfoView(title: "Hang", lines: [
                ("When", hang.date.formatted(date: .abbreviated, time: .standard)),
                ("Main thread stuck for", BackstageStyle.duration(hang.duration))
            ], note: "Hangs are noticed while the performance overlay or the Performance tab is open.")
        case .leak(let leak):
            InfoView(title: leak.name, lines: [
                ("Should have gone", leak.expectedAt.formatted(date: .abbreviated, time: .standard)),
                ("Waited", "\(Int(leak.waited)) s"),
                ("Now", AppActivity.isStillInMemory(leak) ? "Still in memory" : "Freed since")
            ], note: "Something still holds on to it after its screen closed: often a closure that captures self strongly, a delegate that isn't weak, or a timer or observer that wasn't removed. Xcode's Debug Memory Graph shows what holds it.")
        }
    }
}

/// Chips for each kind of event, with how many there are. Several can be on at once; none shows
/// everything.
private struct KindChips: View {
    let events: [TimelineEvent]
    @Binding var selection: Set<TimelineEvent.Kind>

    var body: some View {
        let counts = Dictionary(grouping: events, by: \.kind).mapValues(\.count)
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(TimelineEvent.Kind.allCases) { kind in
                    let isOn = selection.contains(kind)
                    let count = counts[kind, default: 0]
                    Button {
                        if isOn { selection.remove(kind) } else { selection.insert(kind) }
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: kind.icon).font(.caption)
                            Text(kind.title).font(.subheadline.weight(.semibold))
                            Text("\(count)").font(.caption.monospacedDigit()).foregroundStyle(isOn ? .white.opacity(0.85) : .secondary)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .foregroundStyle(isOn ? .white : .primary)
                        .background(isOn ? BackstageStyle.accent : Color.secondary.opacity(0.12), in: .capsule)
                    }
                    .buttonStyle(.plain)
                    .disabled(count == 0 && !isOn)
                    .opacity(count == 0 && !isOn ? 0.4 : 1)
                    .accessibilityAddTraits(isOn ? .isSelected : [])
                }
                if !selection.isEmpty {
                    Button("Clear") { selection = [] }
                        .font(.subheadline)
                        .buttonStyle(.plain)
                        .foregroundStyle(BackstageStyle.accent)
                }
            }
            .padding(.horizontal, 16)
        }
    }
}

private struct TimelineRow: View {
    let event: TimelineEvent

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: event.kind.icon)
                .font(.footnote)
                .foregroundStyle(event.color)
                .frame(width: 20)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(event.kind.title.uppercased())
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(event.color)
                    Spacer()
                    Text(event.date, format: BackstageStyle.time)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Text(event.title)
                    .font(event.kind == .log || event.kind == .network ? .footnote.monospaced() : .subheadline)
                    .lineLimit(3)
                if !event.detail.isEmpty {
                    Text(event.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
    }
}

enum LogRow {
    static func color(_ level: LogEntry.Level) -> Color {
        switch level {
        case .debug: .gray
        case .info: .blue
        case .notice: .green
        case .error: .orange
        case .fault: .red
        }
    }
}

private struct LogDetailView: View {
    let entry: LogEntry

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("\(entry.level.title) · \(entry.subsystem) · \(entry.category)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(entry.date.formatted(date: .abbreviated, time: .standard))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(entry.message)
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
        }
        .navigationTitle(entry.category.isEmpty ? "Message" : entry.category)
    }
}

/// A few facts about an event, with a note.
private struct InfoView: View {
    let title: String
    let lines: [(String, String)]
    let note: String?

    var body: some View {
        Form {
            Section {
                ForEach(lines, id: \.0) { name, value in
                    LabeledContent(name, value: value)
                }
            } footer: {
                if let note { Text(note) }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(title)
    }
}
