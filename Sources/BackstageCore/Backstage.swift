import Foundation
import Observation
import Synchronization

/// How an app sets up Backstage.
public struct BackstageConfiguration: Sendable {
    /// From `swift run backstage-passphrase`: the salt and the hex SHA-256 of the salt followed by
    /// the passphrase that unlocks TestFlight builds. The passphrase itself is never in the app.
    public var passphraseSalt: String
    public var passphraseHash: String
    /// Also record sessions the app doesn't hand to `Backstage.record(_:)`, such as libraries'
    /// sessions, by adding the recording protocol to every new `.default` and `.ephemeral`
    /// configuration. Only while Backstage is on.
    public var recordsAllSessions = false
    /// Headers shown hidden until tapped, and left out of exports unless chosen. Compared without
    /// case.
    public var sensitiveHeaders: Set<String> = ["authorization", "cookie", "set-cookie", "proxy-authorization", "x-api-key"]
    public var limits = NetworkRecorder.Limits()

    public init(passphraseSalt: String, passphraseHash: String) {
        self.passphraseSalt = passphraseSalt
        self.passphraseHash = passphraseHash
    }
}

/// The app's debug panel: whether it's on, what it records, and what the app adds to it.
///
/// Call `start(_:)` once at launch. Backstage is on in builds run from Xcode, on TestFlight
/// devices unlocked with the passphrase, and never in App Store builds.
@MainActor
@Observable
public final class Backstage {
    public static let shared = Backstage()

    /// Where the app runs; `nil` until StoreKit answered.
    public private(set) var environment: RunEnvironment?
    /// This device was unlocked with the passphrase.
    public private(set) var isUnlocked: Bool
    public private(set) var configuration: BackstageConfiguration?

    /// The panel is open.
    public var isPanelPresented = false
    /// The passphrase prompt is open (TestFlight, before unlocking).
    public var isAskingForPassphrase = false
    /// This device was unlocked during this launch, so recording began then rather than at
    /// launch. The panel says so until the note is dismissed.
    public var showsUnlockNote = false

    /// What the app added: servers, information, actions and switches.
    public let registry = Registry()

    @ObservationIgnored private let unlockStore: UnlockStore
    @ObservationIgnored private let defaults: UserDefaults

    init(unlockStore: UnlockStore = .standard, defaults: UserDefaults = .standard) {
        self.unlockStore = unlockStore
        self.defaults = defaults
        isUnlocked = unlockStore.isUnlocked
        showsPerformanceOverlay = defaults.bool(forKey: Self.performanceOverlayKey)
    }

    /// On now: always from Xcode, and on TestFlight devices after unlocking.
    public var isEnabled: Bool {
        Self.isEnabled(environment: environment ?? (Self.isEnabledAtLaunch ? .xcode : .appStore), isUnlocked: isUnlocked)
    }

    nonisolated static func isEnabled(environment: RunEnvironment, isUnlocked: Bool) -> Bool {
        switch environment {
        case .xcode: true
        case .testFlight: isUnlocked
        case .appStore: false
        }
    }

    /// Whether to act on Backstage's settings at launch, before StoreKit has answered: builds
    /// installed from Xcode, and devices unlocked earlier. Apps read the chosen server through
    /// this.
    public nonisolated static var isEnabledAtLaunch: Bool {
        RunEnvironment.isFromXcode || UnlockStore.standard.isUnlocked
    }

    /// Whether Backstage's settings apply right now, from any thread.
    public nonisolated static var isActive: Bool {
        active.withLock { $0 }
    }

    private nonisolated static let active = Mutex(false)

    // MARK: Starting

    /// Starts Backstage. Recording begins at once in Debug builds and on unlocked devices; once
    /// StoreKit tells where the app runs, an App Store build stops it and forgets what it recorded.
    public func start(_ configuration: BackstageConfiguration) {
        guard self.configuration == nil else { return }
        self.configuration = configuration
        NetworkRecorder.shared.configure(configuration.limits)
        if Self.isEnabledAtLaunch {
            turnOn()
        }
        Task {
            let environment = await RunEnvironment.detect()
            self.environment = environment
            if Self.isEnabled(environment: environment, isUnlocked: isUnlocked) {
                turnOn()
            } else {
                turnOff(purge: true)
            }
        }
    }

    private func turnOn() {
        Self.active.withLock { $0 = true }
        let recorder = NetworkRecorder.shared
        guard !recorder.isRecording else { return }
        recorder.setRecording(true)
        SessionCapture.captureSharedSession()
        if configuration?.recordsAllSessions == true {
            SessionCapture.captureEverything()
        }
        Task.detached(priority: .utility) {
            recorder.loadPrevious()
        }
    }

    private func turnOff(purge: Bool) {
        Self.active.withLock { $0 = false }
        NetworkRecorder.shared.setRecording(false, purge: purge)
        isPanelPresented = false
    }

    /// Adds the recording protocol to a session configuration the app makes. Harmless when
    /// Backstage is off: the protocol then lets every request through untouched.
    public nonisolated static func record(_ configuration: URLSessionConfiguration) {
        SessionCapture.install(in: configuration)
    }

    // MARK: Opening

    /// Opens the panel when Backstage is on (shake, ⌃⌥⌘D).
    public func open() {
        guard isEnabled else { return }
        isPanelPresented = true
    }

    /// The hidden trigger: opens the panel when on, and asks for the passphrase in a locked
    /// TestFlight build. Does nothing in App Store builds.
    public func trigger() {
        if isEnabled {
            isPanelPresented = true
        } else if environment == .testFlight {
            isAskingForPassphrase = true
        }
    }

    /// Unlocks this device when the passphrase matches. Recording starts at once. Checking takes
    /// about half a second, off the main thread.
    @discardableResult
    public func unlock(passphrase: String) async -> Bool {
        guard environment == .testFlight || environment == .xcode, let configuration else { return false }
        let salt = configuration.passphraseSalt
        let hash = configuration.passphraseHash
        let matches = await Task.detached(priority: .userInitiated) {
            Passphrase.matches(passphrase, salt: salt, hash: hash)
        }.value
        guard matches else { return false }
        unlockStore.setUnlocked(true)
        isUnlocked = true
        isAskingForPassphrase = false
        if !NetworkRecorder.shared.isRecording {
            showsUnlockNote = true
        }
        turnOn()
        return true
    }

    /// Locks this device again: Backstage stops and forgets what it recorded. Builds run from
    /// Xcode stay on.
    public func lock() {
        unlockStore.setUnlocked(false)
        isUnlocked = false
        if !isEnabled {
            turnOff(purge: true)
        }
    }

    // MARK: Performance overlay

    private static let performanceOverlayKey = "Backstage.performanceOverlay"

    /// The performance overlay is shown (while Backstage is on). Kept across launches.
    public var showsPerformanceOverlay: Bool {
        didSet { defaults.set(showsPerformanceOverlay, forKey: Self.performanceOverlayKey) }
    }
}
