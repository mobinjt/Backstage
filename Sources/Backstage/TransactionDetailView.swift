import BackstageCore
import SwiftUI

/// One call or connection in full.
struct TransactionDetailView: View {
    let id: UUID

    enum Part: String, CaseIterable, Identifiable {
        case overview = "Overview", request = "Request", response = "Response", messages = "Messages"
        var id: String { rawValue }
    }

    @State private var model = NetworkModel.shared
    @State private var part = Part.overview
    @State private var revealsSensitive = false
    @State private var fakes: NetworkTransaction?

    private var transaction: NetworkTransaction? {
        model.transactions.first { $0.id == id } ?? NetworkRecorder.shared.transaction(id)
    }

    private var sensitiveHeaders: Set<String> {
        Backstage.shared.configuration?.sensitiveHeaders ?? []
    }

    var body: some View {
        if let transaction {
            content(transaction)
        } else {
            ContentUnavailableView("Not recorded anymore", systemImage: "questionmark")
        }
    }

    private func parts(of transaction: NetworkTransaction) -> [Part] {
        transaction.kind == .http ? [.overview, .request, .response] : [.overview, .messages]
    }

    private func content(_ transaction: NetworkTransaction) -> some View {
        List {
            Section {
                Picker("Part", selection: $part) {
                    ForEach(parts(of: transaction)) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            switch part {
            case .overview: overview(transaction)
            case .request: exchange(headers: transaction.requestHeaders, body: transaction.requestBody)
            case .response: exchange(headers: transaction.responseHeaders, body: transaction.responseBody)
            case .messages: messages(transaction)
            }
        }
        .navigationTitle(transaction.badge)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    if let url = transaction.url {
                        Button("Copy URL", systemImage: "link") { copyToClipboard(url.absoluteString) }
                    }
                    if let curl = NetworkExport.curl(transaction, sensitiveHeaders: sensitiveHeaders, includingSensitive: revealsSensitive) {
                        Button("Copy as cURL", systemImage: "terminal") { copyToClipboard(curl) }
                    }
                    if let body = transaction.responseBody, let text = String(data: body.data, encoding: .utf8) {
                        Button("Copy Response Body", systemImage: "doc.on.doc") { copyToClipboard(text) }
                    }
                    if transaction.kind == .http && transaction.isComplete {
                        // A fake made from part of a body would answer with broken data.
                        if transaction.responseBody?.isTruncated == true {
                            Button("Can't Fake: Body Not Kept in Full", systemImage: "theatermasks") {}
                                .disabled(true)
                        } else {
                            Button("Fake This Response", systemImage: "theatermasks") { fakes = transaction }
                        }
                    }
                    Toggle("Show Hidden Headers", systemImage: "eye", isOn: $revealsSensitive)
                } label: {
                    Label("Actions", systemImage: "ellipsis.circle")
                }
            }
        }
        .onChange(of: id) { part = .overview }
        .sheet(item: $fakes) { transaction in
            NewFakeSheet(transaction: transaction)
        }
    }

    @ViewBuilder
    private func overview(_ transaction: NetworkTransaction) -> some View {
        Section {
            if let url = transaction.url {
                row("URL", url.absoluteString)
            }
            row("Kind", transaction.kind.title)
            if let method = transaction.method {
                row("Method", method)
            }
            row("Status", transaction.statusText)
            if let simulation = transaction.simulation {
                row("Simulated", simulation == "Fake" ? "A fake response; the server never saw it" : simulation == "Slowed" ? "Slowed by Simulate" : "Failed by Simulate (\(simulation))")
            }
            if let note = transaction.note {
                row("Note", note)
            }
            if let error = transaction.errorDescription {
                row("Error", error)
            }
        }
        Section("Timing") {
            row("Started", transaction.startDate.formatted(date: .abbreviated, time: .standard))
            row("Duration", BackstageStyle.duration(transaction.duration))
            if transaction.launchID != NetworkRecorder.shared.launchID {
                row("Launch", "An earlier launch")
            }
        }
        if transaction.kind == .http {
            Section("Size") {
                row("Request", BackstageStyle.bytes(transaction.requestBody?.size ?? 0))
                row("Response", BackstageStyle.bytes(transaction.responseBody?.size ?? 0))
            }
        } else {
            Section("Messages") {
                row("Sent", "\(transaction.messages.filter { $0.direction == .sent }.count)")
                row("Received", "\(transaction.messages.filter { $0.direction == .received }.count)")
            }
        }
    }

    @ViewBuilder
    private func exchange(headers: [String: String], body: NetworkTransaction.Body?) -> some View {
        Section("Headers") {
            if headers.isEmpty {
                Text("None").foregroundStyle(.secondary)
            }
            ForEach(headers.sorted { $0.key.lowercased() < $1.key.lowercased() }, id: \.key) { field, value in
                let hidden = !revealsSensitive && sensitiveHeaders.contains(field.lowercased())
                VStack(alignment: .leading, spacing: 2) {
                    Text(field)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(hidden ? "Hidden. Tap to show." : value)
                        .font(.footnote.monospaced())
                        .foregroundStyle(hidden ? .secondary : .primary)
                        .textSelection(.enabled)
                }
                .contentShape(.rect)
                .onTapGesture {
                    if hidden { revealsSensitive = true }
                }
            }
        }
        Section("Body") {
            if let body, body.size > 0 {
                BodyView(content: body, contentType: headers.first { $0.key.lowercased() == "content-type" }?.value)
            } else {
                Text("None").foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func messages(_ transaction: NetworkTransaction) -> some View {
        Section {
            if transaction.messages.isEmpty {
                Text("No messages yet").foregroundStyle(.secondary)
            }
            ForEach(transaction.messages.reversed()) { message in
                NavigationLink {
                    List {
                        Section {
                            BodyView(content: message.body, contentType: nil)
                        } header: {
                            Text("\(message.direction == .sent ? "Sent" : "Received") at \(message.date.formatted(BackstageStyle.time))")
                        }
                    }
                    .navigationTitle(message.direction == .sent ? "Sent" : "Received")
                } label: {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: message.direction == .sent ? "arrow.up.circle.fill" : "arrow.down.circle.fill")
                            .foregroundStyle(message.direction == .sent ? BackstageStyle.accent : .green)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(String(decoding: message.body.data.prefix(300), as: UTF8.self))
                                .font(.caption.monospaced())
                                .lineLimit(3)
                            Text("\(message.date.formatted(BackstageStyle.time)) · \(BackstageStyle.bytes(message.body.size))")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        } header: {
            Text("Newest first")
        }
    }

    private func row(_ title: String, _ value: String) -> some View {
        LabeledContent(title) {
            Text(value)
                .textSelection(.enabled)
                .multilineTextAlignment(.trailing)
        }
        .contextMenu {
            Button("Copy", systemImage: "doc.on.doc") { copyToClipboard(value) }
        }
    }
}
