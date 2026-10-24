import BackstageCore
import SwiftUI

/// Links to the app's UserDefaults, Keychain items and files, in the Tools tab.
struct StorageLinks: View {
    var body: some View {
        NavigationLink {
            DefaultsView()
        } label: {
            Label("UserDefaults", systemImage: "list.bullet.rectangle")
        }
        NavigationLink {
            KeychainView()
        } label: {
            Label("Keychain", systemImage: "key")
        }
        NavigationLink {
            if let container = AppReset.container {
                FilesView(directory: container, title: "App Container")
            } else {
                // A Mac app outside the sandbox: its own folders, not the user's home.
                List(AppReset.fileLocations, id: \.self) { folder in
                    NavigationLink {
                        FilesView(directory: folder, title: folder.lastPathComponent)
                    } label: {
                        Label(folder.path(percentEncoded: false), systemImage: "folder")
                    }
                }
                .navigationTitle("Files")
            }
        } label: {
            Label("Files", systemImage: "folder")
        }
    }
}

// MARK: UserDefaults

private struct DefaultsView: View {
    @State private var values: [(key: String, value: Any)] = []
    @State private var search = ""
    @State private var editing: DefaultsEdit?

    private var shown: [(key: String, value: Any)] {
        search.isEmpty ? values : values.filter { $0.key.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        List {
            ForEach(shown, id: \.key) { item in
                Button {
                    editing = DefaultsEdit(key: item.key, value: item.value)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.key)
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.primary)
                        Text(Self.describe(item.value))
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                    }
                }
                .swipeActions {
                    Button("Delete", role: .destructive) {
                        UserDefaults.standard.removeObject(forKey: item.key)
                        load()
                    }
                }
                .contextMenu {
                    Button("Copy Value", systemImage: "doc.on.doc") { copyToClipboard(Self.describe(item.value)) }
                    Button("Delete", systemImage: "trash", role: .destructive) {
                        UserDefaults.standard.removeObject(forKey: item.key)
                        load()
                    }
                }
            }
        }
        .searchable(text: $search, prompt: "Key")
        .navigationTitle("UserDefaults")
        .sheet(item: $editing, onDismiss: load) { edit in
            DefaultsEditor(edit: edit)
        }
        .onAppear(perform: load)
    }

    private func load() {
        let domain = UserDefaults.standard.persistentDomain(forName: Bundle.main.bundleIdentifier ?? "") ?? [:]
        values = domain.sorted { $0.key.lowercased() < $1.key.lowercased() }.map { ($0.key, $0.value) }
    }

    static func describe(_ value: Any) -> String {
        switch value {
        case let data as Data:
            if let object = try? JSONSerialization.jsonObject(with: data), let pretty = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]) {
                return String(decoding: pretty, as: UTF8.self)
            }
            return "\(data.count) bytes"
        case let date as Date:
            return date.formatted(date: .abbreviated, time: .standard)
        default:
            return String(describing: value)
        }
    }
}

private struct DefaultsEdit: Identifiable {
    let key: String
    let value: Any
    var id: String { key }
}

/// Edits text, numbers and switches; other values are shown as they are.
private struct DefaultsEditor: View {
    let edit: DefaultsEdit
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var flag = false

    private var isBool: Bool {
        guard let number = edit.value as? NSNumber else { return false }
        return CFGetTypeID(number) == CFBooleanGetTypeID()
    }

    private var isEditable: Bool { edit.value is String || edit.value is NSNumber }

    var body: some View {
        NavigationStack {
            Form {
                Section(edit.key) {
                    if isBool {
                        Toggle("Value", isOn: $flag)
                    } else if isEditable {
                        TextField("Value", text: $text, axis: .vertical)
                            .font(.body.monospaced())
                    } else {
                        Text(DefaultsView.describe(edit.value))
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Value")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                if isEditable {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") {
                            save()
                            dismiss()
                        }
                    }
                }
            }
            .onAppear {
                flag = (edit.value as? Bool) ?? false
                text = DefaultsView.describe(edit.value)
            }
        }
    }

    private func save() {
        let defaults = UserDefaults.standard
        if isBool {
            defaults.set(flag, forKey: edit.key)
        } else if edit.value is String {
            defaults.set(text, forKey: edit.key)
        } else if let number = edit.value as? NSNumber {
            if let integer = Int(text), CFNumberIsFloatType(number) == false {
                defaults.set(integer, forKey: edit.key)
            } else if let double = Double(text) {
                defaults.set(double, forKey: edit.key)
            }
        }
    }
}

// MARK: Keychain

private struct KeychainView: View {
    @State private var items: [KeychainItem] = []
    @State private var revealed: [String: String] = [:]
    @State private var confirmsReveal: KeychainItem?

    var body: some View {
        List {
            ForEach(items) { item in
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.title)
                        .font(.footnote.weight(.semibold))
                    if let account = item.account {
                        Text(account)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if let value = revealed[item.id] {
                        Text(value)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                    }
                    Text(item.kind.rawValue + (item.modified.map { " · \($0.formatted(date: .abbreviated, time: .shortened))" } ?? ""))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .contextMenu {
                    Button("Show Value", systemImage: "eye") { confirmsReveal = item }
                    Button("Delete", systemImage: "trash", role: .destructive) {
                        KeychainItems.delete(item)
                        load()
                    }
                }
                .swipeActions {
                    Button("Delete", role: .destructive) {
                        KeychainItems.delete(item)
                        load()
                    }
                    Button("Show") { confirmsReveal = item }
                }
                .confirmationDialog("Show this value?", isPresented: Binding { confirmsReveal == item } set: { if !$0 { confirmsReveal = nil } }, titleVisibility: .visible) {
                    Button("Show") {
                        revealed[item.id] = KeychainItems.value(of: item) ?? "(no value)"
                    }
                } message: {
                    Text("It may be a token or a password. Anyone looking at the screen can see it.")
                }
            }
        }
        .overlay {
            if items.isEmpty {
                ContentUnavailableView("No Keychain items", systemImage: "key")
            }
        }
        .navigationTitle("Keychain")
        .onAppear(perform: load)
    }

    private func load() {
        items = KeychainItems.all()
    }
}

// MARK: Files

private struct FilesView: View {
    let directory: URL
    let title: String
    @State private var entries: [FileEntry] = []
    @State private var deleting: FileEntry?

    struct FileEntry: Identifiable {
        let url: URL
        let isDirectory: Bool
        let size: Int
        let modified: Date?
        var id: URL { url }
    }

    var body: some View {
        List {
            ForEach(entries) { entry in
                if entry.isDirectory {
                    NavigationLink {
                        FilesView(directory: entry.url, title: entry.url.lastPathComponent)
                    } label: {
                        Label(entry.url.lastPathComponent, systemImage: "folder")
                    }
                    .swipeActions { deleteButton(entry) }
                } else {
                    NavigationLink {
                        FilePreview(url: entry.url)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Label(entry.url.lastPathComponent, systemImage: "doc")
                            Text(BackstageStyle.bytes(entry.size) + (entry.modified.map { " · \($0.formatted(date: .abbreviated, time: .shortened))" } ?? ""))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .swipeActions { deleteButton(entry) }
                }
            }
        }
        .overlay {
            if entries.isEmpty {
                ContentUnavailableView("Empty", systemImage: "folder")
            }
        }
        .navigationTitle(title)
        .confirmationDialog(
            deleting.map { "Delete \($0.url.lastPathComponent)?" } ?? "",
            isPresented: Binding { deleting != nil } set: { if !$0 { deleting = nil } },
            titleVisibility: .visible,
            presenting: deleting
        ) { entry in
            Button("Delete", role: .destructive) {
                try? FileManager.default.removeItem(at: entry.url)
                load()
            }
        } message: { entry in
            Text(entry.isDirectory ? "The folder and everything in it." : "The file can't be brought back.")
        }
        .onAppear(perform: load)
    }

    private func deleteButton(_ entry: FileEntry) -> some View {
        Button("Delete", role: .destructive) { deleting = entry }
    }

    private func load() {
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys)) ?? []
        entries = urls.map { url in
            let values = try? url.resourceValues(forKeys: Set(keys))
            return FileEntry(url: url, isDirectory: values?.isDirectory ?? false, size: values?.fileSize ?? 0, modified: values?.contentModificationDate)
        }
        .sorted { ($0.isDirectory ? 0 : 1, $0.url.lastPathComponent.lowercased()) < ($1.isDirectory ? 0 : 1, $1.url.lastPathComponent.lowercased()) }
    }
}

private struct FilePreview: View {
    let url: URL

    var body: some View {
        List {
            Section {
                if let data = try? Data(contentsOf: url, options: .mappedIfSafe) {
                    BodyView(content: NetworkTransaction.Body(data, limit: 2_000_000), contentType: Self.contentType(url))
                }
            }
        }
        .navigationTitle(url.lastPathComponent)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                ShareLink(item: url)
            }
        }
    }

    private static func contentType(_ url: URL) -> String? {
        ["png", "jpg", "jpeg", "heic", "gif"].contains(url.pathExtension.lowercased()) ? "image/\(url.pathExtension.lowercased())" : nil
    }
}
