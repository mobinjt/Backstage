import BackstageCore
import SwiftUI
#if os(iOS)
import ObjectiveC
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// Changes to how the app looks and behaves, for testing: appearance, text size, layout
/// direction, bold text, animation speed and touches, and language and region from the next
/// launch. They only apply while Backstage is on, and are kept across launches. Backstage's own
/// window is left as it is, so the panel stays usable.
@MainActor
@Observable
final class DeviceTools {
    static let shared = DeviceTools()

    enum Appearance: String, CaseIterable, Identifiable {
        case system, light, dark
        var id: String { rawValue }
        var title: String { rawValue == "system" ? "Device's" : rawValue.capitalized }
    }

    var appearance: Appearance { didSet { save(); apply() } }
    /// A `UIContentSizeCategory`, or `nil` for the device's.
    var textSize: String? { didSet { save(); apply() } }
    /// From the next launch, like the language: switched while running, SwiftUI's lists stay
    /// mirrored.
    var rightToLeft: Bool { didSet { save(); writeLocale() } }
    var boldText: Bool { didSet { save(); apply() } }
    /// 1 is normal; 0.25 runs animations four times slower.
    var animationSpeed: Double { didSet { save(); apply() } }
    var showsTouches: Bool { didSet { save(); apply() } }
    /// An app language code, or `nil` for the device's. From the next launch.
    var language: String? { didSet { save(); writeLocale() } }
    /// A region code, or `nil` for the device's. From the next launch.
    var region: String? { didSet { save(); writeLocale() } }

    /// What this launch started with, to tell whether a relaunch is needed.
    @ObservationIgnored private let launchLanguage: String?
    @ObservationIgnored private let launchRegion: String?
    @ObservationIgnored private let launchRightToLeft: Bool
    @ObservationIgnored private let defaults = UserDefaults.standard
    @ObservationIgnored private var isWatchingWindows = false
    /// What was changed on the app's windows, to put back when turned off. Anything else is the
    /// app's own and left alone.
    @ObservationIgnored private var changedStyle = false
    @ObservationIgnored private var changedTextSize = false
    @ObservationIgnored private var changedBold = false
    @ObservationIgnored private var changedSpeed = false

    private enum Key {
        static let appearance = "Backstage.tools.appearance"
        static let textSize = "Backstage.tools.textSize"
        static let rightToLeft = "Backstage.tools.rightToLeft"
        static let boldText = "Backstage.tools.boldText"
        static let animationSpeed = "Backstage.tools.animationSpeed"
        static let showsTouches = "Backstage.tools.showsTouches"
        static let language = "Backstage.tools.language"
        static let region = "Backstage.tools.region"
    }

    private init() {
        appearance = defaults.string(forKey: Key.appearance).flatMap(Appearance.init(rawValue:)) ?? .system
        textSize = defaults.string(forKey: Key.textSize)
        let rightToLeft = defaults.bool(forKey: Key.rightToLeft)
        self.rightToLeft = rightToLeft
        launchRightToLeft = rightToLeft
        boldText = defaults.bool(forKey: Key.boldText)
        animationSpeed = defaults.object(forKey: Key.animationSpeed) as? Double ?? 1
        showsTouches = defaults.bool(forKey: Key.showsTouches)
        let language = defaults.string(forKey: Key.language)
        let region = defaults.string(forKey: Key.region)
        self.language = language
        self.region = region
        launchLanguage = language
        launchRegion = region
    }

    /// Something changed only takes effect when the app is opened again.
    var needsRelaunch: Bool { language != launchLanguage || region != launchRegion || rightToLeft != launchRightToLeft }

    /// Anything changed from the device's own settings.
    var isChangingAnything: Bool {
        appearance != .system || textSize != nil || rightToLeft || boldText || animationSpeed != 1 || showsTouches || language != nil || region != nil
    }

    func resetAll() {
        appearance = .system
        textSize = nil
        rightToLeft = false
        boldText = false
        animationSpeed = 1
        showsTouches = false
        language = nil
        region = nil
    }

    private func save() {
        defaults.set(appearance.rawValue, forKey: Key.appearance)
        defaults.set(textSize, forKey: Key.textSize)
        defaults.set(rightToLeft, forKey: Key.rightToLeft)
        defaults.set(boldText, forKey: Key.boldText)
        defaults.set(animationSpeed, forKey: Key.animationSpeed)
        defaults.set(showsTouches, forKey: Key.showsTouches)
        defaults.set(language, forKey: Key.language)
        defaults.set(region, forKey: Key.region)
    }

    // MARK: Language and region

    /// The app reads its language, region and layout direction from these when it starts. The
    /// direction keys are the ones Xcode's Right-to-Left Pseudolanguage passes.
    private func writeLocale() {
        let active = Backstage.shared.isEnabled
        override("AppleTextDirection", with: active && rightToLeft ? true : nil)
        override("NSForceRightToLeftWritingDirection", with: active && rightToLeft ? true : nil)
        override("AppleLanguages", with: active ? language.map { [$0] } : nil)
        var locale: String?
        if active, let region {
            let base = language ?? Locale.preferredLanguages.first.map { Locale(identifier: $0).language.languageCode?.identifier ?? "en" } ?? "en"
            locale = "\(base)_\(region)"
        }
        override("AppleLocale", with: locale)
    }

    /// Sets one of the system's keys in the app's defaults while a change is on, keeping the
    /// app's own value (such as its own language setting) to put back after. A key Backstage
    /// never set is left alone.
    private func override(_ key: String, with value: Any?) {
        let saved = "Backstage.tools.saved.\(key)"
        if let value {
            if defaults.object(forKey: saved) == nil {
                // Read from the app's own settings, not the device's, and wrapped, so a missing
                // value is kept too.
                let own = defaults.persistentDomain(forName: Bundle.main.bundleIdentifier ?? "")?[key]
                defaults.set(own.map { ["value": $0] } ?? [:], forKey: saved)
            }
            defaults.set(value, forKey: key)
        } else if let original = defaults.dictionary(forKey: saved) {
            defaults.set(original["value"], forKey: key)
            defaults.removeObject(forKey: saved)
        }
    }

    // MARK: Applying

    /// Puts the changes on the app's windows while Backstage is on, and takes them off when it
    /// isn't.
    func apply() {
        let active = Backstage.shared.isEnabled
        writeLocale()
        #if os(iOS)
        if active { watchWindows() }
        for scene in UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }) {
            for window in scene.windows where !(window is PassthroughWindow) {
                apply(to: window, active: active)
            }
        }
        // Put back on every window now; later ones were never changed.
        changedStyle = active && appearance != .system
        changedTextSize = active && textSize != nil
        changedBold = active && boldText
        changedSpeed = active && animationSpeed != 1
        if active && showsTouches {
            TouchWatcher.install()
        }
        TouchIndicators.shared.isOn = active && showsTouches
        #elseif os(macOS)
        if active && appearance != .system {
            NSApp.appearance = NSAppearance(named: appearance == .dark ? .darkAqua : .aqua)
            changedStyle = true
        } else if changedStyle {
            NSApp.appearance = nil
            changedStyle = false
        }
        #endif
    }

    #if os(iOS)
    private func apply(to window: UIWindow, active: Bool) {
        if active && appearance != .system {
            window.overrideUserInterfaceStyle = appearance == .dark ? .dark : .light
            changedStyle = true
        } else if changedStyle {
            window.overrideUserInterfaceStyle = .unspecified
        }
        if active, let textSize {
            window.traitOverrides.preferredContentSizeCategory = UIContentSizeCategory(rawValue: textSize)
            changedTextSize = true
        } else if changedTextSize {
            window.traitOverrides.remove(UITraitPreferredContentSizeCategory.self)
        }
        if active && boldText {
            window.traitOverrides.legibilityWeight = .bold
            changedBold = true
        } else if changedBold {
            window.traitOverrides.remove(UITraitLegibilityWeight.self)
        }
        if active && animationSpeed != 1 {
            window.layer.speed = Float(animationSpeed)
            changedSpeed = true
        } else if changedSpeed {
            window.layer.speed = 1
        }
    }

    /// Windows the app opens later get the changes too.
    private func watchWindows() {
        guard !isWatchingWindows else { return }
        isWatchingWindows = true
        NotificationCenter.default.addObserver(forName: UIWindow.didBecomeVisibleNotification, object: nil, queue: .main) { notification in
            // Posted on the main thread, where windows live.
            nonisolated(unsafe) let object = notification.object
            MainActor.assumeIsolated {
                guard let window = object as? UIWindow, !(window is PassthroughWindow) else { return }
                DeviceTools.shared.apply(to: window, active: Backstage.shared.isEnabled)
            }
        }
    }

    /// Text sizes, smallest first, with their names.
    static let textSizes: [(UIContentSizeCategory, String)] = [
        (.extraSmall, "Extra Small"), (.small, "Small"), (.medium, "Medium"), (.large, "Large (Default)"),
        (.extraLarge, "Extra Large"), (.extraExtraLarge, "XX Large"), (.extraExtraExtraLarge, "XXX Large"),
        (.accessibilityMedium, "Accessibility M"), (.accessibilityLarge, "Accessibility L"),
        (.accessibilityExtraLarge, "Accessibility XL"), (.accessibilityExtraExtraLarge, "Accessibility XXL"),
        (.accessibilityExtraExtraExtraLarge, "Accessibility XXXL")
    ]
    #endif
}

#if os(iOS)
// MARK: Touches

/// Where fingers are on the screen, for the circles in Backstage's window.
@MainActor
@Observable
final class TouchIndicators {
    static let shared = TouchIndicators()

    struct Touch: Identifiable {
        let id: ObjectIdentifier
        var point: CGPoint
        var isEnded = false
    }

    var isOn = false
    private(set) var touches: [Touch] = []

    func update(with event: UIEvent) {
        guard isOn, event.type == .touches, let all = event.allTouches else { return }
        for touch in all {
            let id = ObjectIdentifier(touch)
            let point = touch.location(in: nil)
            let ended = touch.phase == .ended || touch.phase == .cancelled
            if let index = touches.firstIndex(where: { $0.id == id }) {
                touches[index].point = point
                touches[index].isEnded = ended
            } else {
                touches.append(Touch(id: id, point: point, isEnded: ended))
            }
            if ended {
                Task {
                    try? await Task.sleep(for: .milliseconds(250))
                    touches.removeAll { $0.id == id && $0.isEnded }
                }
            }
        }
    }
}

/// Sees every touch the app's windows get, without changing what they do with it. Installed only
/// once Show Touches is turned on.
@MainActor
enum TouchWatcher {
    private static var isInstalled = false

    static func install() {
        guard !isInstalled else { return }
        isInstalled = true
        let selector = #selector(UIWindow.sendEvent(_:))
        guard let method = class_getInstanceMethod(UIWindow.self, selector) else { return }
        typealias SendEvent = @convention(c) (UIWindow, Selector, UIEvent) -> Void
        let original = unsafeBitCast(method_getImplementation(method), to: SendEvent.self)
        let replacement: @convention(block) (UIWindow, UIEvent) -> Void = { window, event in
            MainActor.assumeIsolated { TouchIndicators.shared.update(with: event) }
            original(window, selector, event)
        }
        method_setImplementation(method, imp_implementationWithBlock(replacement))
    }
}

/// A circle under each finger.
struct TouchIndicatorsView: View {
    @State private var indicators = TouchIndicators.shared

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear
            ForEach(indicators.touches) { touch in
                Circle()
                    .fill(.white.opacity(0.35))
                    .overlay { Circle().strokeBorder(.black.opacity(0.35), lineWidth: 1.5) }
                    .frame(width: 44, height: 44)
                    .scaleEffect(touch.isEnded ? 1.4 : 1)
                    .opacity(touch.isEnded ? 0 : 1)
                    .position(touch.point)
                    .animation(.easeOut(duration: 0.25), value: touch.isEnded)
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}

// MARK: Screens and leftovers

/// Notices the app's UIKit screens for the timeline, and checks that each one closed is freed
/// soon after. Only the app's own view controllers count, and SwiftUI navigation screens that
/// have a title. Installed only while Backstage is on.
@MainActor
enum ViewControllerWatcher {
    private static var isInstalled = false

    static func install() {
        guard !isInstalled else { return }
        isInstalled = true
        hook(#selector(UIViewController.viewDidAppear(_:))) { appeared($0) }
        hook(#selector(UIViewController.viewDidDisappear(_:))) { disappeared($0) }
    }

    private static func hook(_ selector: Selector, then note: @escaping @MainActor (UIViewController) -> Void) {
        guard let method = class_getInstanceMethod(UIViewController.self, selector) else { return }
        typealias Callback = @convention(c) (UIViewController, Selector, Bool) -> Void
        let original = unsafeBitCast(method_getImplementation(method), to: Callback.self)
        let replacement: @convention(block) (UIViewController, Bool) -> Void = { controller, animated in
            original(controller, selector, animated)
            MainActor.assumeIsolated { note(controller) }
        }
        method_setImplementation(method, imp_implementationWithBlock(replacement))
    }

    private static func appeared(_ controller: UIViewController) {
        guard Backstage.isActive, let window = controller.viewIfLoaded?.window, !(window is PassthroughWindow) else { return }
        if controller is UINavigationController || controller is UITabBarController || controller is UISplitViewController || controller is UIPageViewController { return }
        let className = String(describing: type(of: controller))
        let title = [controller.navigationItem.title, controller.title].compactMap { $0 }.first { !$0.isEmpty }
        if isFromApp(controller) {
            Backstage.screen(title ?? className, className: className)
        } else if let title, className.contains("HostingController") {
            Backstage.screen(title, className: nil)
        }
    }

    private static func disappeared(_ controller: UIViewController) {
        guard Backstage.isActive, isFromApp(controller) else { return }
        let isClosing = sequence(first: controller, next: \.parent).contains { $0.isBeingDismissed || $0.isMovingFromParent }
        guard isClosing else { return }
        Backstage.expectRelease(of: controller, name: String(describing: type(of: controller)), within: 3)
    }

    /// Written by the app or a framework inside it, not by the system.
    private static func isFromApp(_ controller: UIViewController) -> Bool {
        let bundle = Bundle(for: type(of: controller))
        return bundle == .main || bundle.bundleURL.path().hasPrefix(Bundle.main.bundleURL.path())
    }
}
#endif
