import BackstageCore
import SwiftUI
import UniformTypeIdentifiers

/// Every recorded call, newest first, updated live.
@MainActor
@Observable
final class NetworkModel {
    static let shared = NetworkModel()

    private(set) var transactions: [NetworkTransaction] = []
    @ObservationIgnored private var watching: Task<Void, Never>?

    func watch() {
        guard watching == nil else { return }
        // Listening before reading, so nothing recorded in between is missed.
        let changes = NetworkRecorder.shared.changes()
        transactions = NetworkRecorder.shared.transactions
        watching = Task { [weak self] in
            for await _ in changes {
                // At most a few refreshes a second, however busy the network is.
                try? await Task.sleep(for: .milliseconds(250))
                self?.transactions = NetworkRecorder.shared.transactions
            }
        }
    }
}

struct NetworkListView: View {
    enum KindFilter: String, CaseIterable, Identifiable {
        case all = "All", http = "HTTP", webSocket = "WebSocket", other = "Other"
        var id: String { rawValue }
    }

    @State private var model = NetworkModel.shared
    @State private var backstage = Backstage.shared
    @State private var search = ""
    @State private var kind = KindFilter.all
    /// Empty shows every status.
    @State private var statuses: Set<StatusClass> = []
    @State private var thisLaunchOnly = false
    @State private var host: String?
    @State private var export: ExportFile?
    @State private var confirmsClear = false

    /// Everything the other filters let through, before the status chips.
    private var matching: [NetworkTransaction] {
        let launchID = NetworkRecorder.shared.launchID
        return model.transactions.filter { transaction in
            switch kind {
            case .all: break
            case .http: guard transaction.kind == .http else { return false }
            case .webSocket: guard transaction.kind == .webSocket else { return false }
            case .other: guard case .connection = transaction.kind else { return false }
            }
            if thisLaunchOnly && transaction.launchID != launchID { return false }
            if let host, transaction.host != host { return false }
            if !search.isEmpty {
                let haystack = [transaction.url?.absoluteString, transaction.note, transaction.method, transaction.statusCode.map(String.init)].compactMap { $0 }.joined(separator: " ")
                if !haystack.localizedCaseInsensitiveContains(search) { return false }
            }
            return true
        }
    }

    private var shown: [NetworkTransaction] {
        guard !statuses.isEmpty else { return matching }
        return matching.filter { transaction in
            StatusClass(transaction).map(statuses.contains) ?? false
        }
    }

    private var hosts: [String] {
        Array(Set(model.transactions.compactMap(\.host))).sorted()
    }

    var body: some View {
        List {
            if backstage.showsUnlockNote {
                Section {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "info.circle.fill")
                            .foregroundStyle(BackstageStyle.accent)
                        Text("Recording started when you unlocked, so calls made earlier in this launch weren't kept. From the next launch on, everything is recorded from the start.")
                            .font(.footnote)
                        Spacer(minLength: 0)
                        Button("Dismiss", systemImage: "xmark") { backstage.showsUnlockNote = false }
                            .labelStyle(.iconOnly)
                            .buttonStyle(.borderless)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Section {
                Picker("Kind", selection: $kind) {
                    ForEach(KindFilter.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                StatusChips(transactions: matching, selection: $statuses)
                    .listRowInsets(EdgeInsets(top: 6, leading: 0, bottom: 6, trailing: 0))
            }
            Section {
                ForEach(shown) { transaction in
                    NavigationLink {
                        TransactionDetailView(id: transaction.id)
                    } label: {
                        TransactionRow(transaction: transaction)
                    }
                }
            } footer: {
                Text("\(shown.count) of \(model.transactions.count)")
            }
        }
        .overlay {
            if model.transactions.isEmpty {
                ContentUnavailableView("Nothing recorded yet", systemImage: "network", description: Text("Calls the app makes appear here as they happen."))
            }
        }
        .searchable(text: $search, prompt: "URL, status or method")
        .navigationTitle("Network")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Toggle("This Launch Only", systemImage: "clock", isOn: $thisLaunchOnly)
                    Picker("Host", selection: $host) {
                        Text("All Hosts").tag(String?.none)
                        ForEach(hosts, id: \.self) { Text($0).tag(String?.some($0)) }
                    }
                    Divider()
                    Button("Export as HAR…", systemImage: "square.and.arrow.up") { exportHAR() }
                    Button("Export as JSON…", systemImage: "curlybraces") { exportJSON() }
                    Divider()
                    Button("Clear", systemImage: "trash", role: .destructive) { confirmsClear = true }
                } label: {
                    Label("Options", systemImage: thisLaunchOnly || host != nil ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                }
            }
        }
        .confirmationDialog("Clear everything recorded?", isPresented: $confirmsClear) {
            Button("Clear", role: .destructive) { NetworkRecorder.shared.clear() }
        }
        .fileExporter(isPresented: Binding { export != nil } set: { if !$0 { export = nil } }, document: export, contentType: export?.contentType ?? .json, defaultFilename: export?.name) { _ in
            export = nil
        }
        .task { model.watch() }
    }

    private var sensitiveHeaders: Set<String> {
        Backstage.shared.configuration?.sensitiveHeaders ?? []
    }

    private func exportHAR() {
        guard let data = try? NetworkExport.har(shown, sensitiveHeaders: sensitiveHeaders) else { return }
        export = ExportFile(data: data, contentType: UTType(filenameExtension: "har") ?? .json, name: "Backstage \(Date.now.formatted(.iso8601)).har")
    }

    private func exportJSON() {
        guard let data = try? NetworkExport.json(shown, sensitiveHeaders: sensitiveHeaders) else { return }
        export = ExportFile(data: data, contentType: .json, name: "Backstage \(Date.now.formatted(.iso8601)).json")
    }
}

/// A family of results, for the status chips.
enum StatusClass: String, CaseIterable, Identifiable {
    case success = "2xx", redirect = "3xx", clientError = "4xx", serverError = "5xx", failed = "Failed"

    var id: String { rawValue }

    /// `nil` for a connection, or a request still waiting.
    init?(_ transaction: NetworkTransaction) {
        if let status = transaction.statusCode {
            switch status {
            case 200..<300: self = .success
            case 300..<400: self = .redirect
            case 400..<500: self = .clientError
            case 500...: self = .serverError
            default: return nil
            }
        } else if transaction.errorDescription != nil {
            self = .failed
        } else {
            return nil
        }
    }

    var color: Color {
        switch self {
        case .success: .green
        case .redirect: .gray
        case .clientError: .orange
        case .serverError, .failed: .red
        }
    }
}

/// Chips for each family of results, with how many there are. Several can be on at once; none
/// shows everything.
private struct StatusChips: View {
    let transactions: [NetworkTransaction]
    @Binding var selection: Set<StatusClass>

    var body: some View {
        let counts = Dictionary(grouping: transactions.compactMap(StatusClass.init), by: { $0 }).mapValues(\.count)
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(StatusClass.allCases) { status in
                    let isOn = selection.contains(status)
                    let count = counts[status, default: 0]
                    Button {
                        if isOn { selection.remove(status) } else { selection.insert(status) }
                    } label: {
                        HStack(spacing: 5) {
                            Circle().fill(status.color).frame(width: 7, height: 7)
                            Text(status.rawValue).font(.subheadline.weight(.semibold))
                            Text("\(count)").font(.caption.monospacedDigit()).foregroundStyle(isOn ? .white.opacity(0.85) : .secondary)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .foregroundStyle(isOn ? .white : .primary)
                        .background(isOn ? status.color : Color.secondary.opacity(0.12), in: .capsule)
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

struct TransactionRow: View {
    let transaction: NetworkTransaction

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(transaction.badge)
                    .font(.caption2.weight(.bold).monospaced())
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(BackstageStyle.accent.opacity(0.18), in: .rect(cornerRadius: 4))
                if transaction.isComplete {
                    Text(transaction.statusCode.map(String.init) ?? (transaction.errorDescription != nil ? "Failed" : "Done"))
                        .font(.caption.weight(.semibold).monospacedDigit())
                        .foregroundStyle(BackstageStyle.color(forStatus: transaction.statusCode, failed: transaction.isFailure))
                } else {
                    ProgressView().controlSize(.mini)
                }
                Spacer(minLength: 4)
                Text(transaction.startDate, format: BackstageStyle.time)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Text(transaction.title)
                .font(.footnote.monospaced())
                .lineLimit(2)
                .truncationMode(.middle)
            HStack(spacing: 8) {
                if let host = transaction.host {
                    Text(host)
                }
                Text(BackstageStyle.duration(transaction.duration))
                if transaction.kind == .http, let size = transaction.responseBody?.size {
                    Text(BackstageStyle.bytes(size))
                } else if !transaction.messages.isEmpty {
                    Text("\(transaction.messages.count) messages")
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
        .padding(.vertical, 2)
    }
}

/// A file to save with the system's exporter.
struct ExportFile: FileDocument {
    static var readableContentTypes: [UTType] { [] }
    static var writableContentTypes: [UTType] { [.json, UTType(filenameExtension: "har") ?? .json, .plainText, .data] }

    let data: Data
    let contentType: UTType
    let name: String

    init(data: Data, contentType: UTType, name: String) {
        self.data = data
        self.contentType = contentType
        self.name = name
    }

    init(configuration: ReadConfiguration) throws {
        throw CocoaError(.featureUnsupported)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
