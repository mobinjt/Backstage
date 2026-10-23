import BackstageCore
import SwiftUI

/// The simulator's condition and fake responses, for the panel and the strip.
@MainActor
@Observable
final class SimulationModel {
    static let shared = SimulationModel()

    var condition: NetworkSimulator.Condition? {
        didSet { NetworkSimulator.shared.condition = condition }
    }

    private(set) var fakes: [NetworkSimulator.Fake]

    private init() {
        condition = NetworkSimulator.shared.condition
        fakes = NetworkSimulator.shared.fakes
    }

    var activeFakes: Int { fakes.filter(\.isOn).count }

    /// "Slow 3G · 2 fakes", or `nil` when the network is left as it is.
    var summary: String? {
        let parts = [condition?.name, activeFakes == 0 ? nil : activeFakes == 1 ? "1 fake" : "\(activeFakes) fakes"].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    func save(_ fake: NetworkSimulator.Fake) {
        if let index = fakes.firstIndex(where: { $0.id == fake.id }) {
            fakes[index] = fake
        } else {
            fakes.append(fake)
        }
        NetworkSimulator.shared.setFakes(fakes)
    }

    func delete(_ id: UUID) {
        fakes.removeAll { $0.id == id }
        NetworkSimulator.shared.setFakes(fakes)
    }

    func move(from source: IndexSet, to destination: Int) {
        fakes.move(fromOffsets: source, toOffset: destination)
        NetworkSimulator.shared.setFakes(fakes)
    }
}

/// The network's condition and the fake responses, from the Network tab.
struct SimulationView: View {
    @State private var model = SimulationModel.shared
    @State private var networkModel = NetworkModel.shared
    @Environment(\.dismiss) private var dismiss

    private static let custom = "Custom"
    private static let off = "Off"

    private var conditionName: Binding<String> {
        Binding {
            guard let condition = model.condition else { return Self.off }
            return NetworkSimulator.Condition.presets.contains { $0.name == condition.name } ? condition.name : Self.custom
        } set: { name in
            let host = model.condition?.host
            switch name {
            case Self.off: model.condition = nil
            case Self.custom: model.condition = NetworkSimulator.Condition(name: Self.custom, delay: 1, host: host)
            default:
                var preset = NetworkSimulator.Condition.presets.first { $0.name == name }
                preset?.host = host
                model.condition = preset
            }
        }
    }

    private var hosts: [String] {
        Array(Set(networkModel.transactions.compactMap(\.host))).sorted()
    }

    var body: some View {
        Form {
            Section {
                Picker("Condition", selection: conditionName) {
                    Text("As It Is").tag(Self.off)
                    ForEach(NetworkSimulator.Condition.presets, id: \.name) { preset in
                        Text(preset.name).tag(preset.name)
                    }
                    Text("Custom").tag(Self.custom)
                }
                if model.condition != nil {
                    conditionDetails
                }
            } header: {
                Text("Network")
            } footer: {
                Text("Slows down or fails the calls Backstage records, until the app is reopened.")
            }

            Section {
                ForEach(model.fakes) { fake in
                    NavigationLink {
                        FakeEditor(fake: fake, isNew: false)
                    } label: {
                        FakeRow(fake: fake)
                    }
                }
                .onDelete { offsets in offsets.map { model.fakes[$0].id }.forEach(model.delete) }
                .onMove(perform: model.move)
                NavigationLink {
                    FakeEditor(fake: NetworkSimulator.Fake(name: "", method: "GET", urlPattern: "", answer: .response(status: 200, headers: ["Content-Type": "application/json"], body: Data("{}".utf8))), isNew: true)
                } label: {
                    Label("Add Fake Response", systemImage: "plus")
                }
            } header: {
                Text("Fake Responses")
            } footer: {
                Text("A fake answers matching calls itself, without reaching the server; the first match wins. Fake This Response on a recorded call starts one from its real answer. They're kept across launches.")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Simulate")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }
            }
        }
    }

    @ViewBuilder
    private var conditionDetails: some View {
        let condition = Binding { model.condition ?? NetworkSimulator.Condition(name: Self.custom) } set: { model.condition = $0 }
        if conditionName.wrappedValue == Self.custom {
            Picker("Delay", selection: condition.delay) {
                ForEach([0, 0.25, 0.5, 1, 2, 5, 10] as [TimeInterval], id: \.self) { Text($0 == 0 ? "None" : BackstageStyle.duration($0)).tag($0) }
            }
            Picker("Speed", selection: condition.bytesPerSecond) {
                Text("No Limit").tag(Int?.none)
                ForEach([1_000_000, 250_000, 50_000, 10_000], id: \.self) { Text("\(BackstageStyle.bytes($0))/s").tag(Int?.some($0)) }
            }
            Picker("Failures", selection: condition.failureRate) {
                ForEach([0, 0.1, 0.25, 0.5, 1] as [Double], id: \.self) { Text($0 == 0 ? "None" : "\(Int($0 * 100))%").tag($0) }
            }
        } else if let current = model.condition {
            LabeledContent("Does", value: Self.describe(current))
        }
        Picker("Calls To", selection: condition.host) {
            Text("Every Host").tag(String?.none)
            ForEach(hosts, id: \.self) { Text($0).tag(String?.some($0)) }
        }
    }

    static func describe(_ condition: NetworkSimulator.Condition) -> String {
        if condition.isOffline { return "Every call fails, as with no connection" }
        var parts: [String] = []
        if condition.delay > 0 { parts.append("waits \(BackstageStyle.duration(condition.delay))") }
        if let speed = condition.bytesPerSecond { parts.append("\(BackstageStyle.bytes(speed))/s") }
        if condition.failureRate > 0 { parts.append("\(Int(condition.failureRate * 100))% fail") }
        return parts.isEmpty ? "Nothing" : parts.joined(separator: ", ").capitalizedFirst
    }
}

private struct FakeRow: View {
    let fake: NetworkSimulator.Fake
    @State private var model = SimulationModel.shared

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(fake.name.isEmpty ? fake.urlPattern : fake.name)
                    .font(.subheadline.weight(.semibold))
                Text("\(fake.method ?? "Any") \(fake.urlPattern)")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                Text(Self.describe(fake.answer))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("On", isOn: Binding { fake.isOn } set: { isOn in
                var changed = fake
                changed.isOn = isOn
                model.save(changed)
            })
            .labelsHidden()
        }
    }

    static func describe(_ answer: NetworkSimulator.Fake.Answer) -> String {
        switch answer {
        case .response(let status, _, let body):
            let phrase = NetworkTransaction.reasonPhrase(forStatusCode: status).map { "\(status) \($0)" } ?? "\(status)"
            return "\(phrase), \(BackstageStyle.bytes(body.count))"
        case .failure(let failure):
            return failure.title
        }
    }
}

/// Makes or changes a fake response.
struct FakeEditor: View {
    let isNew: Bool
    @State private var fake: NetworkSimulator.Fake
    @State private var statusText: String
    @State private var headersText: String
    @State private var bodyText: String
    /// A body that isn't text, such as an image, kept as it was.
    @State private var binaryBody: Data?
    @State private var model = SimulationModel.shared
    @Environment(\.dismiss) private var dismiss

    private static let methods = ["GET", "POST", "PUT", "PATCH", "DELETE"]

    init(fake: NetworkSimulator.Fake, isNew: Bool) {
        self.isNew = isNew
        _fake = State(initialValue: fake)
        var status = 200
        var headers: [String: String] = [:]
        var body = Data()
        if case .response(let s, let h, let b) = fake.answer {
            status = s
            headers = h
            body = b
        }
        _statusText = State(initialValue: String(status))
        _headersText = State(initialValue: headers.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }.joined(separator: "\n"))
        if let text = String(data: body, encoding: .utf8) {
            _bodyText = State(initialValue: BodyView.prettyJSON(body) ?? text)
            _binaryBody = State(initialValue: nil)
        } else {
            _bodyText = State(initialValue: "")
            _binaryBody = State(initialValue: body)
        }
    }

    private var isFailure: Binding<Bool> {
        Binding {
            if case .failure = fake.answer { return true }
            return false
        } set: { failure in
            fake.answer = failure ? .failure(.timedOut) : .response(status: 200, headers: [:], body: Data())
        }
    }

    private var status: Int? {
        Int(statusText.trimmingCharacters(in: .whitespaces)).flatMap { (100...599).contains($0) ? $0 : nil }
    }

    private var canSave: Bool {
        !fake.urlPattern.trimmingCharacters(in: .whitespaces).isEmpty && (isFailure.wrappedValue || status != nil)
    }

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $fake.name, prompt: Text("Optional"))
                Picker("Method", selection: $fake.method) {
                    Text("Any").tag(String?.none)
                    ForEach(Self.methods, id: \.self) { Text($0).tag(String?.some($0)) }
                }
                TextField("URL", text: $fake.urlPattern, prompt: Text("https://api.example.com/users/*"), axis: .vertical)
                    .font(.callout.monospaced())
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                    #endif
            } header: {
                Text("Matches")
            } footer: {
                Text("* stands for anything. Without a ? the query is ignored.")
            }

            Section("Answers With") {
                Picker("Answer", selection: isFailure) {
                    Text("Response").tag(false)
                    Text("Failure").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                if case .failure(let failure) = fake.answer {
                    Picker("Failure", selection: Binding { failure } set: { fake.answer = .failure($0) }) {
                        ForEach(NetworkSimulator.Fake.Failure.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                } else {
                    LabeledContent("Status") {
                        TextField("200", text: $statusText)
                            .multilineTextAlignment(.trailing)
                            #if os(iOS)
                            .keyboardType(.numberPad)
                            #endif
                    }
                    if let status {
                        Text(NetworkTransaction.reasonPhrase(forStatusCode: status) ?? "")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Headers").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        TextField("Content-Type: application/json", text: $headersText, axis: .vertical)
                            .font(.caption.monospaced())
                            .autocorrectionDisabled()
                            #if os(iOS)
                            .textInputAutocapitalization(.never)
                            #endif
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Body").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        if let binaryBody {
                            Text("\(BackstageStyle.bytes(binaryBody.count)) that isn't text, sent as recorded.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        } else {
                            TextField("{}", text: $bodyText, axis: .vertical)
                                .font(.caption.monospaced())
                                .lineLimit(4...20)
                                .autocorrectionDisabled()
                                #if os(iOS)
                                .textInputAutocapitalization(.never)
                                #endif
                        }
                    }
                }
                Picker("Delay", selection: $fake.delay) {
                    ForEach([0, 0.5, 1, 2, 5, 10] as [TimeInterval], id: \.self) { Text($0 == 0 ? "None" : BackstageStyle.duration($0)).tag($0) }
                }
            }

            if !isNew {
                Section {
                    Button("Delete Fake", systemImage: "trash", role: .destructive) {
                        model.delete(fake.id)
                        dismiss()
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(isNew ? "New Fake" : "Fake")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    save()
                    dismiss()
                }
                .disabled(!canSave)
            }
        }
    }

    private func save() {
        var saved = fake
        saved.urlPattern = fake.urlPattern.trimmingCharacters(in: .whitespacesAndNewlines)
        if case .response = fake.answer {
            let headers = headersText.split(whereSeparator: \.isNewline).reduce(into: [String: String]()) { headers, line in
                let parts = line.split(separator: ":", maxSplits: 1)
                guard parts.count == 2 else { return }
                headers[parts[0].trimmingCharacters(in: .whitespaces)] = parts[1].trimmingCharacters(in: .whitespaces)
            }
            saved.answer = .response(status: status ?? 200, headers: headers, body: binaryBody ?? Data(bodyText.utf8))
        }
        model.save(saved)
    }
}

/// Fake This Response, from a recorded call: the editor, filled with the real answer.
struct NewFakeSheet: View {
    let transaction: NetworkTransaction

    var body: some View {
        NavigationStack {
            FakeEditor(fake: NetworkSimulator.Fake(answering: transaction), isNew: true)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        CancelButton()
                    }
                }
        }
    }

    private struct CancelButton: View {
        @Environment(\.dismiss) private var dismiss
        var body: some View { Button("Cancel") { dismiss() } }
    }
}

private extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
