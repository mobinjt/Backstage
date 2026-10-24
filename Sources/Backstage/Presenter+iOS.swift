#if os(iOS)
import BackstageCore
import ObjectiveC
import SwiftUI
import UIKit

/// On iPhone and iPad Backstage lives in its own window above the app's, so it opens over the
/// app's sheets and full-screen views, and the performance overlay stays on top of everything.
/// The window lets touches through except on what Backstage shows.
@MainActor
final class BackstageWindowController {
    static let shared = BackstageWindowController()

    private var window: PassthroughWindow?
    private weak var previousKeyWindow: UIWindow?
    weak var scene: UIWindowScene?

    /// Where each overlay is, in the window's coordinates; touches there go to it.
    var overlayFrames: [String: CGRect] = [:] {
        didSet { window?.interactiveFrames = Array(overlayFrames.values) }
    }

    func setVisible(_ visible: Bool) {
        if visible {
            guard let scene else { return }
            if window == nil || window?.windowScene !== scene {
                // The app moved to another scene: the old window goes.
                window?.isHidden = true
                let window = PassthroughWindow(windowScene: scene)
                window.windowLevel = .alert + 1
                window.backgroundColor = .clear
                let host = UIHostingController(rootView: OverlayRoot())
                host.view.backgroundColor = .clear
                window.rootViewController = host
                self.window = window
            }
            window?.isHidden = false
            if Backstage.shared.isEnabled {
                ShakeDetector.install()
            }
        } else {
            window?.isHidden = true
        }
    }

    /// While the panel or the passphrase prompt is open, the window takes the keyboard; then it
    /// gives it back.
    func setPresenting(_ presenting: Bool) {
        guard let window else { return }
        window.capturesAllTouches = presenting
        if presenting {
            previousKeyWindow = scene?.windows.first { $0.isKeyWindow && $0 !== window }
            window.makeKey()
        } else if window.isKeyWindow {
            previousKeyWindow?.makeKey()
        }
    }
}

final class PassthroughWindow: UIWindow {
    var interactiveFrames: [CGRect] = []
    var capturesAllTouches = false

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard capturesAllTouches || rootViewController?.presentedViewController != nil || interactiveFrames.contains(where: { $0.contains(point) }) else {
            return nil
        }
        return super.hitTest(point, with: event)
    }
}

/// Finds the window scene the app's view is in.
struct BackstageWindowInstaller: View {
    @State private var backstage = Backstage.shared

    var body: some View {
        SceneProbe()
            .frame(width: 0, height: 0)
            .onChange(of: needsWindow, initial: true) { _, needed in
                BackstageWindowController.shared.setVisible(needed)
            }
    }

    private var needsWindow: Bool {
        backstage.isEnabled || backstage.isAskingForPassphrase
    }
}

private struct SceneProbe: UIViewRepresentable {
    final class ProbeView: UIView {
        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard let scene = window?.windowScene else { return }
            let controller = BackstageWindowController.shared
            controller.scene = scene
            if Backstage.shared.isEnabled || Backstage.shared.isAskingForPassphrase {
                controller.setVisible(true)
            }
        }
    }

    func makeUIView(context: Context) -> ProbeView {
        let view = ProbeView()
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ uiView: ProbeView, context: Context) {}
}

/// What the Backstage window shows.
private struct OverlayRoot: View {
    @State private var backstage = Backstage.shared

    var body: some View {
        ZStack(alignment: .top) {
            Color.clear
            if backstage.isEnabled {
                ServerStrip()
                if backstage.showsPerformanceOverlay {
                    DraggableOverlay(place: "overlay", x: 0.8, y: 0.12) { frame in
                        BackstageWindowController.shared.overlayFrames["performance"] = frame
                    } hide: {
                        backstage.showsPerformanceOverlay = false
                    } content: {
                        PerformanceOverlayView()
                    }
                    .onAppear { PerformanceMonitor.shared.start() }
                    .onDisappear { PerformanceMonitor.shared.stop() }
                }
                if backstage.networkOverlay == .compact || backstage.networkOverlay == .ticker {
                    DraggableOverlay(place: "networkOverlay", x: 0.75, y: 0.3) { frame in
                        BackstageWindowController.shared.overlayFrames["network"] = frame
                    } hide: {
                        backstage.networkOverlay = .off
                    } content: {
                        if backstage.networkOverlay == .ticker {
                            TickerNetworkOverlay()
                        } else {
                            CompactNetworkOverlay()
                        }
                    }
                }
                // Above everything, never in the way of a touch.
                TouchIndicatorsView()
                if backstage.alertsOnNetworkProblems {
                    // Above the home indicator; touches pass through to the app.
                    VStack {
                        Spacer()
                        NetworkAlertsView()
                            .padding(.horizontal, 16)
                            .padding(.bottom, 48)
                    }
                    .allowsHitTesting(false)
                }
            }
        }
        .ignoresSafeArea(edges: .bottom)
        .sheet(isPresented: Bindable(backstage).isPanelPresented) {
            PanelView()
                .tint(BackstageStyle.accent)
        }
        .sheet(isPresented: Bindable(backstage).isAskingForPassphrase) {
            PassphraseView()
                .tint(BackstageStyle.accent)
        }
        .onChange(of: backstage.isPanelPresented || backstage.isAskingForPassphrase) { _, presenting in
            BackstageWindowController.shared.setPresenting(presenting)
        }
        .onChange(of: backstage.showsPerformanceOverlay && backstage.isEnabled) { _, shows in
            if !shows { BackstageWindowController.shared.overlayFrames["performance"] = nil }
        }
        .onChange(of: backstage.isEnabled && [.compact, .ticker].contains(backstage.networkOverlay)) { _, shows in
            if !shows { BackstageWindowController.shared.overlayFrames["network"] = nil }
        }
    }
}

/// Opens Backstage when the device is shaken. Installed only once Backstage is on, so App Store
/// builds never change `UIWindow`.
@MainActor
enum ShakeDetector {
    private static var isInstalled = false

    static func install() {
        guard !isInstalled else { return }
        isInstalled = true
        let selector = #selector(UIResponder.motionEnded(_:with:))
        guard let method = class_getInstanceMethod(UIWindow.self, selector) else { return }
        typealias MotionEnded = @convention(c) (UIWindow, Selector, UIEvent.EventSubtype, UIEvent?) -> Void
        let original = unsafeBitCast(method_getImplementation(method), to: MotionEnded.self)
        let replacement: @convention(block) (UIWindow, UIEvent.EventSubtype, UIEvent?) -> Void = { window, motion, event in
            if motion == .motionShake {
                MainActor.assumeIsolated { Backstage.shared.open() }
            }
            original(window, selector, motion, event)
        }
        let implementation = imp_implementationWithBlock(replacement)
        // UIWindow may only inherit the method; then it gets its own, leaving other responders alone.
        if !class_addMethod(UIWindow.self, selector, implementation, method_getTypeEncoding(method)) {
            method_setImplementation(method, implementation)
        }
    }
}
#endif
