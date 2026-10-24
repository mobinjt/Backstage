import BackstageCore
import SwiftUI
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// The Tools tab: reporting a bug, changing how the app looks and behaves for testing, deep
/// links, notifications, permissions, storage and starting over.
struct ToolsView: View {
    @State private var tools = DeviceTools.shared
    @State private var location = LocationModel.shared
    @State private var bugReport = BugReportModel.shared
    @State private var confirmsReset = false

    var body: some View {
        Form {
            Section {
                Button("Report a Bug", systemImage: "ladybug") { bugReport.start() }
            } footer: {
                Text("A screenshot to mark up, with the recent calls, logs, timeline, build and settings, to share in one go.")
            }

            #if os(iOS)
            Section {
                Picker("Appearance", selection: $tools.appearance) {
                    ForEach(DeviceTools.Appearance.allCases) { Text($0.title).tag($0) }
                }
                Picker("Text Size", selection: $tools.textSize) {
                    Text("Device's").tag(String?.none)
                    ForEach(DeviceTools.textSizes, id: \.0.rawValue) { size, name in
                        Text(name).tag(String?.some(size.rawValue))
                    }
                }
                .pickerStyle(.navigationLink)
                Toggle("Bold Text", isOn: $tools.boldText)
            } header: {
                Text("Look")
            } footer: {
                Text("On the app's screens, not Backstage's. Other accessibility settings, such as Reduce Motion, can only be changed in Settings.")
            }
            #elseif os(macOS)
            Section("Look") {
                Picker("Appearance", selection: $tools.appearance) {
                    ForEach(DeviceTools.Appearance.allCases) { Text($0.title).tag($0) }
                }
            }
            #endif

            Section {
                Picker("Language", selection: $tools.language) {
                    Text("Device's").tag(String?.none)
                    ForEach(Self.languages, id: \.code) { language in
                        Text(language.name).tag(String?.some(language.code))
                    }
                }
                Picker("Region", selection: $tools.region) {
                    Text("Device's").tag(String?.none)
                    ForEach(Self.regions, id: \.code) { region in
                        Text(region.name).tag(String?.some(region.code))
                    }
                }
                #if os(iOS)
                .pickerStyle(.navigationLink)
                #endif
                Toggle("Right to Left", isOn: $tools.rightToLeft)
                if tools.needsRelaunch {
                    Button("Quit App to Apply", systemImage: "arrow.clockwise", role: .destructive, action: Self.quit)
                }
                NavigationLink {
                    LocationPickerView()
                } label: {
                    LabeledContent {
                        Text(location.location?.name ?? "Device's")
                    } label: {
                        Label("Location", systemImage: "location")
                    }
                }
            } header: {
                Text("Language, Region and Location")
            } footer: {
                Text("Language, region and right to left apply from the next launch; the location at once. The languages are the ones the app is translated into. Right to Left lays the app out as for Arabic or Hebrew, in any language.")
            }

            #if os(iOS)
            Section {
                Picker("Animations", selection: $tools.animationSpeed) {
                    Text("Normal").tag(1.0)
                    Text("Half Speed").tag(0.5)
                    Text("Quarter Speed").tag(0.25)
                    Text("Tenth Speed").tag(0.1)
                }
                Toggle("Show Touches", isOn: $tools.showsTouches)
            } header: {
                Text("Testing")
            } footer: {
                Text("Slow animations show glitches the eye misses. Show Touches puts a circle under each finger, for screen recordings.")
            }
            #endif

            Section {
                NavigationLink {
                    DeepLinksView()
                } label: {
                    Label("Deep Links", systemImage: "link")
                }
                NavigationLink {
                    NotificationsView()
                } label: {
                    Label("Notifications", systemImage: "bell.badge")
                }
                NavigationLink {
                    PermissionsView()
                } label: {
                    Label("Permissions", systemImage: "hand.raised")
                }
            }

            Section("Storage") {
                StorageLinks()
            }

            Section {
                if tools.isChangingAnything || location.location != nil {
                    Button("Undo Testing Changes", systemImage: "arrow.uturn.backward") {
                        tools.resetAll()
                        location.location = nil
                    }
                }
                Button("Reset App…", systemImage: "trash", role: .destructive) { confirmsReset = true }
                    .confirmationDialog("Reset the app?", isPresented: $confirmsReset, titleVisibility: .visible) {
                        Button("Reset, Keep Backstage's Settings", role: .destructive) { reset(keepingBackstage: true) }
                        Button("Reset Everything", role: .destructive) { reset(keepingBackstage: false) }
                    } message: {
                        Text("Deletes the app's UserDefaults, Keychain items, files, cookies and cache, then closes it. Open it again to start as if just installed. Backstage's settings are its server, switches, fakes and records.")
                    }
            } footer: {
                Text("Reset the app to test first launch and onboarding without reinstalling. The device stays unlocked.")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Tools")
    }

    private func reset(keepingBackstage: Bool) {
        if !keepingBackstage {
            tools.resetAll()
        }
        NetworkRecorder.shared.flush()
        AppReset.reset(keepingBackstage: keepingBackstage)
        Task {
            // A moment for the system to finish writing settings before the app goes.
            try? await Task.sleep(for: .milliseconds(500))
            Self.quit()
        }
    }

    /// Closes the app; the user opens it again.
    static func quit() {
        UserDefaults.standard.synchronize()
        #if os(iOS)
        exit(0)
        #elseif os(macOS)
        NSApp.terminate(nil)
        #endif
    }

    /// The languages the app is translated into, by name.
    static var languages: [(code: String, name: String)] {
        Bundle.main.localizations
            .filter { $0 != "Base" }
            .map { ($0, Locale.current.localizedString(forIdentifier: $0) ?? $0) }
            .sorted { $0.name < $1.name }
    }

    /// Countries and territories, by name.
    static var regions: [(code: String, name: String)] {
        Locale.Region.isoRegions
            .map(\.identifier)
            .filter { $0.count == 2 }
            .compactMap { code in Locale.current.localizedString(forRegionCode: code).map { (code, $0) } }
            .sorted { $0.name < $1.name }
    }
}
