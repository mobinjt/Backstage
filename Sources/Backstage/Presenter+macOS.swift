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
                // A click opens Backstage on the tab it was last on; dragging moves the panel.
                panel.contentViewController = NSHostingController(rootView: PerformanceOverlayView().onTapGesture { PanelView.open() })
                panel.setFrameAutosaveName("Backstage.performance")
                if let screen = NSScreen.main, panel.frame.origin == .zero {
                    panel.setFrameOrigin(NSPoint(x: screen.visibleFrame.maxX - 240, y: screen.visibleFrame.maxY - 110))
                }
                overlayPanel = panel
            }
            overlayPanel?.orderFrontRegardless()
            PerformanceMonitor.shared.start()
        } else {
            overlayPanel?.orderOut(nil)
            PerformanceMonitor.shared.stop()
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
