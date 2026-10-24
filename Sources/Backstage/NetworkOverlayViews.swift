import BackstageCore
import SwiftUI

/// What the network overlays show: this launch's HTTP calls.
@MainActor
struct NetworkActivity {
    /// A call counts as slow from this long.
    static let slow: TimeInterval = 2
    /// Failures are counted over this last stretch of time.
    static let recent: TimeInterval = 60

    /// Newest first.
    let calls: [NetworkTransaction]

    init(_ model: NetworkModel) {
        let launchID = NetworkRecorder.shared.launchID
        calls = model.transactions.filter { $0.kind == .http && $0.launchID == launchID }
    }

    var running: Int { calls.filter { !$0.isComplete }.count }

    /// In the last minute.
    var failed: Int {
        let since = Date.now.addingTimeInterval(-Self.recent)
        return calls.filter { $0.isComplete && $0.isFailure && ($0.endDate ?? .now) >= since }.count
    }

    /// The call that ended most recently.
    var lastFinished: NetworkTransaction? {
        calls.filter(\.isComplete).max { ($0.endDate ?? .distantPast) < ($1.endDate ?? .distantPast) }
    }

    var lastFailure: NetworkTransaction? {
        calls.filter { $0.isComplete && $0.isFailure }.max { ($0.endDate ?? .distantPast) < ($1.endDate ?? .distantPast) }
    }
}

@MainActor
private enum OverlayText {
    static func status(_ call: NetworkTransaction) -> String {
        guard call.isComplete else { return "…" }
        return call.statusCode.map(String.init) ?? "✕"
    }

    static func color(_ call: NetworkTransaction) -> Color {
        guard call.isComplete else { return .white.opacity(0.6) }
        return BackstageStyle.color(forStatus: call.statusCode, failed: call.isFailure)
    }

    static func line(_ call: NetworkTransaction) -> String {
        "\(call.method ?? "GET") \(call.title)"
    }

    static func time(_ call: NetworkTransaction) -> String {
        call.duration.map { BackstageStyle.duration($0) } ?? ""
    }

    static func counts(_ activity: NetworkActivity) -> some View {
        HStack(spacing: 6) {
            if activity.running > 0 {
                ProgressView().controlSize(.mini).tint(.white)
            } else {
                Image(systemName: "arrow.up.arrow.down").font(.caption2).foregroundStyle(.white.opacity(0.6))
            }
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text("\(activity.running)").font(.caption.weight(.bold).monospacedDigit())
                Text("running").font(.caption2).foregroundStyle(.white.opacity(0.6))
            }
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text("\(activity.failed)").font(.caption.weight(.bold).monospacedDigit())
                    .foregroundStyle(activity.failed > 0 ? .red : .white)
                Text("failed").font(.caption2).foregroundStyle(.white.opacity(0.6))
            }
        }
    }
}

/// The overlays' dark box.
private struct OverlayBox<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding(8)
            .background(.black.opacity(0.75), in: .rect(cornerRadius: 10))
            .environment(\.colorScheme, .dark)
    }
}

/// Compact: calls running and failed, the last call, and a bar for each recent call.
struct CompactNetworkOverlay: View {
    @State private var model = NetworkModel.shared

    var body: some View {
        let activity = NetworkActivity(model)
        OverlayBox {
            VStack(alignment: .leading, spacing: 4) {
                OverlayText.counts(activity)
                if let call = activity.lastFinished {
                    HStack(spacing: 4) {
                        Text(OverlayText.status(call)).font(.caption2.weight(.bold).monospacedDigit()).foregroundStyle(OverlayText.color(call))
                        Text(OverlayText.line(call)).font(.caption2.monospaced()).lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 2)
                        Text(OverlayText.time(call)).font(.caption2.monospacedDigit()).foregroundStyle(.white.opacity(0.6))
                    }
                } else {
                    Text("No calls yet").font(.caption2).foregroundStyle(.white.opacity(0.6))
                }
                // A bar per call, oldest on the left, taller the slower.
                HStack(alignment: .bottom, spacing: 2) {
                    ForEach(activity.calls.filter(\.isComplete).prefix(20).reversed()) { call in
                        RoundedRectangle(cornerRadius: 1)
                            .fill(OverlayText.color(call))
                            .frame(width: 5, height: 4 + 14 * min((call.duration ?? 0) / Self.tallest, 1))
                    }
                }
                .frame(height: 18, alignment: .bottomLeading)
            }
            .frame(width: 160, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Network: \(activity.running) running, \(activity.failed) failed")
        .task { model.watch() }
    }

    /// The duration of a full-height bar.
    private static let tallest: TimeInterval = 2
}

/// Ticker: the last calls, one line each, newest on top.
struct TickerNetworkOverlay: View {
    @State private var model = NetworkModel.shared

    var body: some View {
        let activity = NetworkActivity(model)
        OverlayBox {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 4) {
                    Image(systemName: "network").font(.caption2)
                    Text("Network").font(.caption2.weight(.semibold))
                    Spacer()
                    if activity.running > 0 {
                        ProgressView().controlSize(.mini).tint(.white)
                        Text("\(activity.running) running").font(.caption2).foregroundStyle(.white.opacity(0.6))
                    }
                }
                if activity.calls.isEmpty {
                    Text("No calls yet").font(.caption2).foregroundStyle(.white.opacity(0.6))
                }
                ForEach(activity.calls.prefix(5)) { call in
                    HStack(spacing: 5) {
                        Text(OverlayText.status(call))
                            .font(.caption2.weight(.bold).monospacedDigit())
                            .foregroundStyle(OverlayText.color(call))
                            .frame(width: 24, alignment: .leading)
                        Text(call.method ?? "GET").font(.caption2.weight(.semibold).monospaced()).frame(width: 36, alignment: .leading)
                        Text(call.title).font(.caption2.monospaced()).lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 4)
                        Text(OverlayText.time(call))
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle((call.duration ?? 0) >= NetworkActivity.slow ? .orange : .white.opacity(0.6))
                    }
                }
            }
            .frame(width: 250, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Network: \(activity.running) running")
        .task { model.watch() }
    }
}

/// The network's lines inside the performance overlay.
struct NetworkLinesInPerformanceOverlay: View {
    @State private var model = NetworkModel.shared

    var body: some View {
        let activity = NetworkActivity(model)
        VStack(alignment: .leading, spacing: 3) {
            Rectangle().fill(.white.opacity(0.2)).frame(height: 1)
            OverlayText.counts(activity)
            if let call = activity.lastFailure ?? activity.lastFinished {
                HStack(spacing: 4) {
                    Text(OverlayText.status(call)).font(.caption2.weight(.bold).monospacedDigit()).foregroundStyle(OverlayText.color(call))
                    Text(OverlayText.line(call)).font(.caption2.monospaced()).lineLimit(1).truncationMode(.middle)
                }
            }
        }
        .frame(width: 140, alignment: .leading)
        .task { model.watch() }
    }
}

/// Alerts at the bottom of the screen for calls that fail or are slow, each for a few seconds.
struct NetworkAlertsView: View {
    @State private var model = NetworkModel.shared
    @State private var shown: [NetworkTransaction] = []
    @State private var seen: Set<UUID> = []
    /// Calls that ended before the alerts were turned on aren't announced.
    @State private var since = Date.now

    private static let showsFor: Duration = .seconds(4)
    private static let most = 2

    var body: some View {
        VStack(spacing: 8) {
            ForEach(shown) { call in
                alert(call)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(duration: 0.35), value: shown.map(\.id))
        .onChange(of: model.revision) { _, _ in announce() }
        .task {
            model.watch()
            since = .now
        }
    }

    private func announce() {
        let launchID = NetworkRecorder.shared.launchID
        let problems = model.transactions.filter { call in
            call.kind == .http && call.launchID == launchID && call.isComplete && !seen.contains(call.id)
                && (call.endDate ?? .distantPast) >= since
                && (call.isFailure || (call.duration ?? 0) >= NetworkActivity.slow)
        }
        for call in problems.reversed() {
            seen.insert(call.id)
            shown.append(call)
            if shown.count > Self.most { shown.removeFirst(shown.count - Self.most) }
            Task {
                try? await Task.sleep(for: Self.showsFor)
                shown.removeAll { $0.id == call.id }
            }
        }
    }

    private func alert(_ call: NetworkTransaction) -> some View {
        let failed = call.isFailure
        let title: String = {
            if let status = call.statusCode, failed {
                return NetworkTransaction.reasonPhrase(forStatusCode: status).map { "\(status) \($0)" } ?? "\(status)"
            }
            if failed { return call.errorDescription ?? "Failed" }
            return "Slow: \(OverlayText.time(call))"
        }()
        return HStack(spacing: 10) {
            Image(systemName: failed ? "xmark.octagon.fill" : "tortoise.fill")
                .font(.title3)
                .foregroundStyle(failed ? .red : .orange)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.footnote.weight(.semibold)).lineLimit(1)
                Text("\(OverlayText.line(call)) · \(call.host ?? "")")
                    .font(.caption.monospaced())
                    .foregroundStyle(.white.opacity(0.7))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: 360)
        .background(.black.opacity(0.8), in: .capsule)
        .environment(\.colorScheme, .dark)
        .accessibilityElement(children: .combine)
    }
}
