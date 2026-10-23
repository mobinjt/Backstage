#if os(macOS)
import AppKit
import BackstageCore
import SwiftUI

/// On the Mac the panel is its own window, and the performance overlay a small floating panel.
@MainActor
final class BackstageWindows: NSObject, NSWindowDelegate {
    static let shared = BackstageWindows()

    private var panelWindow: NSWindow?
    private var overlayPanel: NSPanel?
    private var networkPanel: NSPanel?
    private var alertsPanel: NSPanel?

    func showPanel() {
        if panelWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 900, height: 640),
                styleMask: [.titled, .closable, .resizable, .miniaturizable],
                backing: .buffered,
                defer: false
            )
            window.title = "Backstage"
            window.isReleasedWhenClosed = false
            window.contentViewController = NSHostingController(rootView: MacPanelRoot().tint(BackstageStyle.accent))
            window.delegate = self
            window.center()
            window.setFrameAutosaveName("Backstage.panel")
            panelWindow = window
        }
        panelWindow?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        guard (notification.object as? NSWindow) === panelWindow else { return }
        Backstage.shared.isPanelPresented = false
        Backstage.shared.isAskingForPassphrase = false
    }

    func setPerformanceOverlay(visible: Bool) {
        if visible {
            if overlayPanel == nil {
                // A click opens Backstage on the tab it was last on; dragging moves the panel.
                overlayPanel = makeOverlayPanel(PerformanceOverlayView().onTapGesture { PanelView.open() }, name: "Backstage.performance", fromTop: 110)
            }
            overlayPanel?.orderFrontRegardless()
            PerformanceMonitor.shared.start()
        } else {
            overlayPanel?.orderOut(nil)
            PerformanceMonitor.shared.stop()
        }
    }

    func setNetworkOverlay(visible: Bool) {
        if visible {
            if networkPanel == nil {
                networkPanel = makeOverlayPanel(MacNetworkOverlay().onTapGesture { PanelView.open() }, name: "Backstage.network", fromTop: 260)
            }
            networkPanel?.orderFrontRegardless()
        } else {
            networkPanel?.orderOut(nil)
        }
    }

    /// The alerts float at the bottom of the main screen and let clicks through.
    func setNetworkAlerts(visible: Bool) {
        if visible {
            if alertsPanel == nil {
                let panel = makeOverlayPanel(NetworkAlertsView().frame(width: 380, height: 150, alignment: .bottom), name: nil, fromTop: 0)
                panel.ignoresMouseEvents = true
                panel.hasShadow = false
                if let screen = NSScreen.main {
                    panel.setFrameOrigin(NSPoint(x: screen.visibleFrame.midX - 190, y: screen.visibleFrame.minY + 24))
                }
                alertsPanel = panel
            }
            alertsPanel?.orderFrontRegardless()
        } else {
            alertsPanel?.orderOut(nil)
        }
    }

    /// A small borderless window above every other, sized to what it shows, at the top right of
    /// the main screen until moved (`name` keeps where it was left).
    private func makeOverlayPanel(_ content: some View, name: String?, fromTop: CGFloat) -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 220, height: 90),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let host = NSHostingController(rootView: content)
        host.sizingOptions = [.preferredContentSize]
        panel.contentViewController = host
        if let name {
            panel.setFrameAutosaveName(name)
        }
        if let screen = NSScreen.main, panel.frame.origin == .zero {
            panel.setFrameOrigin(NSPoint(x: screen.visibleFrame.maxX - 300, y: screen.visibleFrame.maxY - fromTop))
        }
        return panel
    }

}

/// The network overlay in its own window: compact or ticker, as chosen.
private struct MacNetworkOverlay: View {
    @State private var backstage = Backstage.shared

    var body: some View {
        if backstage.networkOverlay == .ticker {
            TickerNetworkOverlay()
        } else {
            CompactNetworkOverlay()
        }
    }
}

private struct MacPanelRoot: View {
    @State private var backstage = Backstage.shared

    var body: some View {
        Group {
            if backstage.isEnabled {
                PanelView()
            } else if backstage.environment == .testFlight {
                PassphraseView()
            } else {
                ContentUnavailableView("Backstage is off", systemImage: "lock")
            }
        }
        .frame(minWidth: 640, minHeight: 440)
    }
}
#endif
