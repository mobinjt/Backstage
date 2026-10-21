import BackstageCore
import SwiftUI

/// This launch's log messages.
struct LogsView: View {
    @State private var entries: [LogEntry] = []
    @State private var isLoading = false
    @State private var error: String?
    @State private var search = ""
    @AppStorage("Backstage.logs.minimumLevel") private var minimumLevel = LogEntry.Level.debug.rawValue
    /// The system's own messages (UIKit, networking, Security…) far outnumber the app's.
    @AppStorage("Backstage.logs.appOnly") private var appOnly = true
    @State private var category: String?

    /// The app's messages, or everyone's.
    private var sources: [LogEntry] {
        appOnly ? entries.filter(\.isFromApp) : entries
    }

    private var shown: [LogEntry] {
        sources.reversed().filter { entry in
            entry.level.rawValue >= minimumLevel
                && (category == nil || entry.category == category)
                && (search.isEmpty || entry.message.localizedCaseInsensitiveContains(search) || entry.category.localizedCaseInsensitiveContains(search))
        }
    }

    private var categories: [String] {
        Array(Set(sources.map(\.category))).filter { !$0.isEmpty }.sorted()
    }

    var body: some View {
        List(shown) { entry in
            NavigationLink {
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
            } label: {
                LogRow(entry: entry)
            }
        }
        .overlay {
            if let error {
                ContentUnavailableView("Couldn't read the log", systemImage: "exclamationmark.triangle", description: Text(error))
            } else if isLoading && entries.isEmpty {
                ProgressView()
            } else if shown.isEmpty && !search.isEmpty {
                ContentUnavailableView.search(text: search)
            } else if sources.isEmpty {
                ContentUnavailableView("No messages", systemImage: "text.alignleft", description: Text(appOnly
                    ? "Messages the app logs with Logger appear here. Turn off App's Messages Only to see the system's too."
                    : "Messages the app logs with Logger appear here."))
            } else if shown.isEmpty {
                ContentUnavailableView("No messages", systemImage: "line.3.horizontal.decrease.circle", description: Text("None at this level or in this category."))
            }
        }
        .searchable(text: $search, prompt: "Message or category")
        .navigationTitle("Logs")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Toggle("App's Messages Only", systemImage: "app", isOn: $appOnly)
                    Divider()
                    Picker("Level", selection: $minimumLevel) {
                        ForEach(LogEntry.Level.allCases, id: \.self) { level in
                            Text(level == .debug ? "Every Level" : "\(level.title) and Above").tag(level.rawValue)
                        }
                    }
                    Picker("Category", selection: $category) {
                        Text("Every Category").tag(String?.none)
                        ForEach(categories, id: \.self) { Text($0).tag(String?.some($0)) }
                    }
                    Divider()
                    Button("Reload", systemImage: "arrow.clockwise") { Task { await load() } }
                } label: {
                    Label("Options", systemImage: category != nil || minimumLevel != LogEntry.Level.debug.rawValue ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                }
            }
        }
        .refreshable { await load() }
        .onChange(of: appOnly) { category = nil }
        .task { await load() }
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            entries = try await LogReader.entries()
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}

private struct LogRow: View {
    let entry: LogEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Circle()
                    .fill(color)
                    .frame(width: 7, height: 7)
                Text(entry.category.isEmpty ? entry.subsystem : entry.category)
                    .font(.caption.weight(.semibold))
                Spacer()
                Text(entry.date, format: BackstageStyle.time)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Text(entry.message)
                .font(.footnote.monospaced())
                .lineLimit(4)
        }
    }

    private var color: Color {
        switch entry.level {
        case .debug: .gray
        case .info: .blue
        case .notice: .green
        case .error: .orange
        case .fault: .red
        }
    }
}
