import BackstageCore
import SwiftUI

extension View {
    /// Puts Backstage on the app's main view: the panel, the passphrase prompt, the performance
    /// overlay and the server strip, shake and ⌃⌥⌘D to open. Nothing shows while Backstage is off.
    /// Call `Backstage.shared.start(_:)` first.
    public func backstage() -> some View {
        modifier(BackstageHostModifier())
    }

    /// The hidden trigger: tapping this view `count` times in a row (each within two seconds of
    /// the last) opens Backstage, or asks for the passphrase in a locked TestFlight build. App
    /// Store builds ignore it.
    public func backstageTrigger(count: Int = 7) -> some View {
        modifier(BackstageTriggerModifier(count: count))
    }

    /// Names this screen in Backstage's timeline each time it appears. UIKit screens are noticed
    /// on their own; SwiftUI ones need this. Does nothing while Backstage is off.
    public func backstageScreen(_ name: String) -> some View {
        onAppear { Backstage.screen(name) }
    }
}

private struct BackstageHostModifier: ViewModifier {
    @State private var backstage = Backstage.shared

    func body(content: Content) -> some View {
        content
            .background {
                if backstage.isEnabled {
                    // ⌃⌥⌘D, on the Mac and on iPads with a keyboard.
                    Button("Backstage") { backstage.open() }
                        .keyboardShortcut("d", modifiers: [.control, .option, .command])
                        .hidden()
                        .accessibilityHidden(true)
                }
            }
            .onChange(of: backstage.isEnabled, initial: true) { _, enabled in
                // Testing changes go on and off with Backstage.
                DeviceTools.shared.apply()
                #if os(iOS)
                if enabled { ViewControllerWatcher.install() }
                #endif
            }
            #if os(iOS)
            .background { BackstageWindowInstaller() }
            #elseif os(macOS)
            .overlay(alignment: .top) {
                if backstage.isEnabled {
                    ServerStrip()
                }
            }
            .onChange(of: backstage.isPanelPresented || backstage.isAskingForPassphrase, initial: true) { _, isOpen in
                if isOpen { BackstageWindows.shared.showPanel() }
            }
            .onChange(of: backstage.isEnabled && backstage.showsPerformanceOverlay, initial: true) { _, shows in
                BackstageWindows.shared.setPerformanceOverlay(visible: shows)
            }
            .onChange(of: backstage.isEnabled && [.compact, .ticker].contains(backstage.networkOverlay), initial: true) { _, shows in
                BackstageWindows.shared.setNetworkOverlay(visible: shows)
            }
            .onChange(of: backstage.isEnabled && backstage.alertsOnNetworkProblems, initial: true) { _, shows in
                BackstageWindows.shared.setNetworkAlerts(visible: shows)
            }
            #endif
    }
}

private struct BackstageTriggerModifier: ViewModifier {
    let count: Int
    @State private var taps: [Date] = []

    func body(content: Content) -> some View {
        content
            .contentShape(.rect)
            .simultaneousGesture(TapGesture().onEnded {
                let now = Date.now
                // A pause of two seconds starts the count again.
                taps = (taps.last.map { now.timeIntervalSince($0) < 2 } ?? false ? taps : []) + [now]
                if taps.count >= count {
                    taps = []
                    Backstage.shared.trigger()
                }
            })
    }
}

/// Shows which server the app uses when it isn't the app's own, so a build pointed at staging is
/// never mistaken for the real thing, and a simulated network or fakes while they're on.
struct ServerStrip: View {
    @State private var registry = Backstage.shared.registry
    @State private var simulation = SimulationModel.shared
    @State private var location = LocationModel.shared

    var body: some View {
        let chosen = registry.serverSettings.compactMap { setting -> String? in
            guard let url = registry.serverInUse(for: setting.key) else { return nil }
            return setting.servers.first { $0.url == url }?.name ?? url.host() ?? url.absoluteString
        }
        HStack(spacing: 4) {
            if !chosen.isEmpty {
                label(chosen.joined(separator: " · "), color: BackstageStyle.accent)
                    .accessibilityLabel("Server: \(chosen.joined(separator: ", "))")
            }
            // A slow network or a fake left on is easy to forget.
            if let summary = simulation.summary {
                label(summary, color: .orange)
                    .accessibilityLabel("Simulating: \(summary)")
            }
            if let place = location.location {
                label("📍 \(place.name)", color: .orange)
                    .accessibilityLabel("Location set to \(place.name)")
            }
        }
        .allowsHitTesting(false)
    }

    private func label(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(color, in: .capsule)
    }
}
