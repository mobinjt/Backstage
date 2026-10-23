import BackstageCore
import SwiftUI

/// The panel: network, logs, the app's settings and actions, storage and performance.
struct PanelView: View {
    @State private var backstage = Backstage.shared
    @AppStorage(Self.tabKey) private var tab = Tab.network

    enum Tab: String {
        case network, logs, app, storage, performance
    }

    private static let tabKey = "Backstage.panelTab"

    /// Opens the panel on the tab it was last on, as when the performance overlay is tapped.
    @MainActor
    static func open() {
        guard Backstage.shared.isEnabled else { return }
        Backstage.shared.open()
        #if os(macOS)
        // The panel may be open already, behind other windows.
        BackstageWindows.shared.showPanel()
        #endif
    }

    var body: some View {
        TabView(selection: $tab) {
            screen(NetworkListView())
                .tabItem { Label("Network", systemImage: "network") }
                .tag(Tab.network)
            screen(LogsView())
                .tabItem { Label("Logs", systemImage: "text.alignleft") }
                .tag(Tab.logs)
            screen(AppTabView())
                .tabItem { Label("App", systemImage: "slider.horizontal.3") }
                .tag(Tab.app)
            screen(StorageView())
                .tabItem { Label("Storage", systemImage: "externaldrive") }
                .tag(Tab.storage)
            screen(PerformanceView())
                .tabItem { Label("Performance", systemImage: "gauge.with.dots.needle.67percent") }
                .tag(Tab.performance)
        }
    }

    private func screen(_ content: some View) -> some View {
        NavigationStack {
            content
                #if os(iOS)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") { backstage.isPanelPresented = false }
                    }
                }
                #endif
        }
    }
}

/// Asks for the passphrase that unlocks Backstage on this TestFlight device.
struct PassphraseView: View {
    @State private var backstage = Backstage.shared
    @State private var passphrase = ""
    @State private var failures = 0
    @State private var isWaiting = false
    @FocusState private var isFocused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SecureField("Passphrase", text: $passphrase)
                        .focused($isFocused)
                        .onSubmit(unlock)
                        .disabled(isWaiting)
                } footer: {
                    if failures > 0 {
                        Text("That's not it.")
                            .foregroundStyle(.red)
                    }
                }
                Section {
                    Button(action: unlock) {
                        HStack {
                            Text("Unlock")
                            if isWaiting && failures == 0 {
                                Spacer()
                                ProgressView().controlSize(.small)
                            }
                        }
                    }
                    .disabled(passphrase.isEmpty || isWaiting)
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Backstage")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        backstage.isAskingForPassphrase = false
                        backstage.isPanelPresented = false
                    }
                }
            }
            .onAppear { isFocused = true }
        }
    }

    private func unlock() {
        guard !passphrase.isEmpty, !isWaiting else { return }
        isWaiting = true
        Task {
            if await backstage.unlock(passphrase: passphrase) {
                isWaiting = false
                backstage.isPanelPresented = true
                return
            }
            // Each wrong guess waits longer.
            failures += 1
            passphrase = ""
            try? await Task.sleep(for: .seconds(min(Double(failures * failures), 30)))
            isWaiting = false
            isFocused = true
        }
    }
}
