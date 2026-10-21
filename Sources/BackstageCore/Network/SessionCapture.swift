import Foundation
import ObjectiveC
import Synchronization

/// Puts `RecordingURLProtocol` into sessions.
enum SessionCapture {
    /// Adds the recording protocol to a configuration, before any others.
    static func install(in configuration: URLSessionConfiguration) {
        var classes = configuration.protocolClasses ?? []
        guard !classes.contains(where: { $0 == RecordingURLProtocol.self }) else { return }
        classes.insert(RecordingURLProtocol.self, at: 0)
        configuration.protocolClasses = classes
    }

    private static let didCaptureShared = Mutex(false)
    private static let didCaptureEverything = Mutex(false)

    /// `URLSession.shared` and the old `NSURLConnection` use registered protocols.
    static func captureSharedSession() {
        let first = didCaptureShared.withLock { done in
            defer { done = true }
            return !done
        }
        if first {
            URLProtocol.registerClass(RecordingURLProtocol.self)
        }
    }

    /// Makes `URLSessionConfiguration.default` and `.ephemeral` include the recording protocol,
    /// so sessions made by libraries (such as RevenueCat) are recorded too. Only ever done while
    /// Backstage is on; App Store builds never change these methods.
    static func captureEverything() {
        let first = didCaptureEverything.withLock { done in
            defer { done = true }
            return !done
        }
        guard first else { return }
        for name in ["defaultSessionConfiguration", "ephemeralSessionConfiguration"] {
            let selector = NSSelectorFromString(name)
            guard let method = class_getClassMethod(URLSessionConfiguration.self, selector) else { continue }
            typealias Getter = @convention(c) (AnyClass, Selector) -> URLSessionConfiguration
            let original = unsafeBitCast(method_getImplementation(method), to: Getter.self)
            let replacement: @convention(block) (AnyClass) -> URLSessionConfiguration = { type in
                let configuration = original(type, selector)
                install(in: configuration)
                return configuration
            }
            method_setImplementation(method, imp_implementationWithBlock(replacement))
        }
    }
}
