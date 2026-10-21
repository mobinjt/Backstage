import BackstageCore
import SwiftUI

/// The build, the device, and what the app added: servers, information, switches and actions.
struct AppTabView: View {
    @State private var backstage = Backstage.shared
    @State private var registry = Backstage.shared.registry
    @State private var runningAction: UUID?
    @State private var confirmsLock = false

    var body: some View {
        Form {
            Section("This build") {
                copyable("Runs from", backstage.environment.map(Self.title) ?? "Checking…")
                copyable("Version", Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?")
                copyable("Build", Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?")
                copyable("Bundle ID", Bundle.main.bundleIdentifier ?? "?")
            }
            Section("Device") {
                copyable("System", DeviceInfo.system)
                copyable("Model", DeviceInfo.model)
                copyable("Language", Locale.preferredLanguages.first ?? "?")
                copyable("Region", Locale.current.region?.identifier ?? "?")
                copyable("Time zone", TimeZone.current.identifier)
            }

            ForEach(groups(of: registry.info.map(\.group)), id: \.self) { group in
                Section(group) {
                    ForEach(registry.info.filter { $0.group == group }) { item in
                        copyable(item.title, item.value() ?? "None")
                    }
                }
            }

            ForEach(registry.serverSettings) { setting in
                ServerPicker(setting: setting)
            }

            ForEach(groups(of: registry.switches.map(\.group)), id: \.self) { group in
                Section(group) {
                    ForEach(registry.switches.filter { $0.group == group }) { item in
                        Toggle(isOn: Binding { registry.isOn(item.key) } set: { registry.set(item.key, on: $0) }) {
                            Text(item.title)
                            if let footnote = item.footnote {
                                Text(footnote)
                            }
                        }
                    }
                }
            }

            ForEach(groups(of: registry.actions.map(\.group)), id: \.self) { group in
                Section(group) {
                    ForEach(registry.actions.filter { $0.group == group }) { action in
                        Button(role: action.isDestructive ? .destructive : nil) {
                            runningAction = action.id
                            Task {
                                await action.perform()
                                runningAction = nil
                            }
                        } label: {
                            HStack {
                                Text(action.title)
                                Spacer()
                                if runningAction == action.id {
                                    ProgressView().controlSize(.small)
                                }
                            }
                        }
                        .disabled(runningAction != nil)
                    }
                }
            }

            if backstage.environment == .testFlight {
                Section {
                    Button("Lock Backstage", systemImage: "lock", role: .destructive) { confirmsLock = true }
                } footer: {
                    Text("Locking stops recording on this device and forgets what was recorded. The passphrase unlocks it again.")
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("App")
        .confirmationDialog("Lock Backstage on this device?", isPresented: $confirmsLock) {
            Button("Lock", role: .destructive) {
                backstage.lock()
                backstage.isPanelPresented = false
            }
        }
    }

    private static func title(_ environment: RunEnvironment) -> String {
        switch environment {
        case .xcode: "Xcode"
        case .testFlight: "TestFlight"
        case .appStore: "App Store"
        }
    }

    /// Groups in the order the app added them.
    private func groups(of names: [String]) -> [String] {
        var seen = Set<String>()
        return names.filter { seen.insert($0).inserted }
    }

    private func copyable(_ title: String, _ value: String) -> some View {
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

private struct ServerPicker: View {
    let setting: Registry.ServerSetting
    @State private var registry = Backstage.shared.registry
    @State private var customURL = ""

    private static let custom = "Backstage.custom"

    private var selection: Binding<String> {
        Binding {
            guard let chosen = registry.selectedServer(for: setting.key) else { return setting.servers.first?.name ?? "" }
            return setting.servers.first { $0.url == chosen }?.name ?? Self.custom
        } set: { name in
            if name == Self.custom {
                registry.selectServer(URL(string: customURL), for: setting.key)
            } else if name == setting.servers.first?.name {
                registry.selectServer(nil, for: setting.key)
            } else {
                registry.selectServer(setting.servers.first { $0.name == name }?.url, for: setting.key)
            }
        }
    }

    var body: some View {
        Section {
            Picker(setting.title, selection: selection) {
                ForEach(setting.servers) { server in
                    VStack(alignment: .leading) {
                        Text(server.name)
                        Text(server.url.absoluteString).font(.caption).foregroundStyle(.secondary)
                    }
                    .tag(server.name)
                }
                if setting.allowsCustomURL {
                    Text("Other address").tag(Self.custom)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
            if setting.allowsCustomURL && selection.wrappedValue == Self.custom {
                TextField("http://192.168.1.10:8080", text: $customURL)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                    #endif
                    .onSubmit {
                        registry.selectServer(URL(string: customURL), for: setting.key)
                    }
            }
        } header: {
            Text(setting.title)
        } footer: {
            Text("Applies from the next launch. A strip at the top of the screen shows the server while it isn't the app's own.")
        }
        .onAppear {
            if let chosen = registry.selectedServer(for: setting.key), !setting.servers.contains(where: { $0.url == chosen }) {
                customURL = chosen.absoluteString
            }
        }
    }
}

@MainActor
enum DeviceInfo {
    /// "iOS 27.0.1".
    static var system: String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        let number = "\(version.majorVersion).\(version.minorVersion)" + (version.patchVersion > 0 ? ".\(version.patchVersion)" : "")
        #if os(iOS)
        return "\(UIDevice.current.systemName) \(number)"
        #else
        return "macOS \(number)"
        #endif
    }

    /// The hardware identifier, such as "iPhone17,1".
    static var model: String {
        var info = utsname()
        uname(&info)
        let machine = withUnsafeBytes(of: &info.machine) { buffer in
            String(decoding: buffer.prefix { $0 != 0 }, as: UTF8.self)
        }
        #if targetEnvironment(simulator)
        return "Simulator (\(ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] ?? machine))"
        #else
        return machine
        #endif
    }
}
