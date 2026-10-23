import BackstageCore
import SwiftUI

/// The reports iOS delivered, kept up to date.
@MainActor
@Observable
final class IOSReportModel {
    static let shared = IOSReportModel()

    private(set) var diagnostics: [(IOSDiagnostic, IOSReport)] = []
    private(set) var daily: [(IOSDailySummary, IOSReport)] = []
    @ObservationIgnored private var watching: Task<Void, Never>?

    func watch() {
        guard watching == nil else { return }
        let changes = IOSReportStore.shared.changes()
        Task { await load() }
        watching = Task { [weak self] in
            for await _ in changes {
                await self?.load()
            }
        }
    }

    func load() async {
        let reports = await Task.detached(priority: .userInitiated) { IOSReportStore.shared.reports }.value
        diagnostics = reports.flatMap { report in report.diagnostics.map { ($0, report) } }.sorted { $0.0.date > $1.0.date }
        daily = reports.compactMap { report in report.dailySummary.map { ($0, report) } }
    }
}

/// The section of the Performance tab with the reports iOS delivered.
struct IOSReportsSection: View {
    @State private var model = IOSReportModel.shared

    var body: some View {
        Section {
            if model.diagnostics.isEmpty && model.daily.isEmpty {
                Text("None yet").foregroundStyle(.secondary)
            }
            ForEach(model.diagnostics.prefix(20), id: \.0.id) { diagnostic, report in
                NavigationLink {
                    DiagnosticView(diagnostic: diagnostic, report: report)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(diagnostic.kind.title).font(.subheadline.weight(.semibold))
                                .foregroundStyle(diagnostic.kind == .crash ? .red : .orange)
                            Spacer()
                            Text(diagnostic.date.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Text(diagnostic.summary).font(.footnote).lineLimit(2)
                        if let top = diagnostic.callStack.first {
                            Text(top.text).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                }
            }
            ForEach(model.daily.prefix(7), id: \.1.id) { summary, report in
                NavigationLink {
                    DailyReportView(summary: summary, report: report)
                } label: {
                    LabeledContent("Day of \((summary.begin ?? report.received).formatted(date: .abbreviated, time: .omitted))") {
                        Text(summary.values.first.map { "\($0.name): \($0.value)" } ?? "")
                    }
                }
            }
        } header: {
            Text("Reports from iOS")
        } footer: {
            Text("Collected by iOS through MetricKit: crashes and hangs arrive on the next launch, a summary about once a day. None in the simulator; on a device connected to Xcode, Debug > Simulate MetricKit Payloads sends samples. Kept for 30 days.")
        }
        .task { model.watch() }
    }
}

private struct DiagnosticView: View {
    let diagnostic: IOSDiagnostic
    let report: IOSReport

    var body: some View {
        List {
            Section {
                LabeledContent("Kind", value: diagnostic.kind.title)
                LabeledContent("When", value: diagnostic.date.formatted(date: .abbreviated, time: .shortened))
                Text(diagnostic.summary).textSelection(.enabled)
            }
            Section {
                if diagnostic.callStack.isEmpty {
                    Text("None in this report").foregroundStyle(.secondary)
                }
                ForEach(Array(diagnostic.callStack.enumerated()), id: \.offset) { _, frame in
                    Text(frame.text)
                        .font(.caption.monospaced())
                        .padding(.leading, CGFloat(min(frame.depth, 12)) * 8)
                        .textSelection(.enabled)
                }
            } header: {
                Text("Call stack")
            } footer: {
                Text("Addresses, not names: Xcode or atos turns them into function names with the build's dSYM. Share the report to do it on the Mac.")
            }
            Section("Details") {
                ForEach(diagnostic.details, id: \.key) { key, value in
                    LabeledContent(key) { Text(value).textSelection(.enabled) }
                }
            }
        }
        .navigationTitle(diagnostic.kind.title)
        .toolbar { ReportActions(report: report) }
    }
}

private struct DailyReportView: View {
    let summary: IOSDailySummary
    let report: IOSReport

    var body: some View {
        List {
            Section {
                if let begin = summary.begin, let end = summary.end {
                    LabeledContent("From", value: begin.formatted(date: .abbreviated, time: .shortened))
                    LabeledContent("To", value: end.formatted(date: .abbreviated, time: .shortened))
                }
                if let version = summary.appVersion {
                    LabeledContent("App version", value: version)
                }
            }
            Section {
                ForEach(summary.values, id: \.name) { name, value in
                    LabeledContent(name, value: value)
                }
            } header: {
                Text("Key numbers")
            } footer: {
                Text("Typical launch and hang are the most common range. The full report has every number iOS keeps.")
            }
            Section("Full report") {
                Text(report.prettyJSON)
                    .font(.caption2.monospaced())
                    .textSelection(.enabled)
            }
        }
        .navigationTitle("Daily Report")
        .toolbar { ReportActions(report: report) }
    }
}

/// Copy and share the report as iOS wrote it.
private struct ReportActions: ToolbarContent {
    let report: IOSReport

    var body: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Menu {
                Button("Copy Report", systemImage: "doc.on.doc") { copyToClipboard(report.prettyJSON) }
                ShareLink("Share Report", item: report.prettyJSON)
            } label: {
                Label("Actions", systemImage: "ellipsis.circle")
            }
        }
    }
}
