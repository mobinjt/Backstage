import Foundation
import ObjectiveC
import Synchronization

/// A place the app is told it's at instead of where the device is.
public struct FakeLocation: Codable, Sendable, Hashable {
    public var name: String
    public var latitude: Double
    public var longitude: Double
    /// The place's time zone, such as "Asia/Tokyo", which the app uses while it's there.
    public var timeZoneIdentifier: String?

    public init(name: String, latitude: Double, longitude: Double, timeZoneIdentifier: String? = nil) {
        self.name = name
        self.latitude = latitude
        self.longitude = longitude
        self.timeZoneIdentifier = timeZoneIdentifier
    }

    /// The place's time zone, or one guessed from the longitude when it isn't known.
    public var timeZone: TimeZone {
        if let timeZoneIdentifier, let zone = TimeZone(identifier: timeZoneIdentifier) {
            return zone
        }
        // A city chosen before time zones were kept.
        if let city = Self.presets.first(where: { $0.latitude == latitude && $0.longitude == longitude }), city.timeZoneIdentifier != nil {
            return city.timeZone
        }
        return TimeZone(secondsFromGMT: Int((longitude / 15).rounded()) * 3600) ?? .gmt
    }

    public static let presets = [
        FakeLocation(name: "London", latitude: 51.5074, longitude: -0.1278, timeZoneIdentifier: "Europe/London"),
        FakeLocation(name: "New York", latitude: 40.7128, longitude: -74.0060, timeZoneIdentifier: "America/New_York"),
        FakeLocation(name: "San Francisco", latitude: 37.7749, longitude: -122.4194, timeZoneIdentifier: "America/Los_Angeles"),
        FakeLocation(name: "Berlin", latitude: 52.5200, longitude: 13.4050, timeZoneIdentifier: "Europe/Berlin"),
        FakeLocation(name: "Dubai", latitude: 25.2048, longitude: 55.2708, timeZoneIdentifier: "Asia/Dubai"),
        FakeLocation(name: "Tokyo", latitude: 35.6762, longitude: 139.6503, timeZoneIdentifier: "Asia/Tokyo"),
        FakeLocation(name: "Sydney", latitude: -33.8688, longitude: 151.2093, timeZoneIdentifier: "Australia/Sydney"),
        FakeLocation(name: "São Paulo", latitude: -23.5505, longitude: -46.6333, timeZoneIdentifier: "America/Sao_Paulo")
    ]
}

/// Tells the app it's somewhere else: `CLLocationManager.location`, and the locations every
/// location delegate gets, become the chosen place, and the app's time zone becomes the place's.
/// Only while Backstage is on; the location is kept across launches until it's cleared.
///
/// It covers `CLLocationManager`, the way most apps ask, and the system's own users of it in the
/// app: MapKit's blue dot and current-location button, and web pages asking for the position.
/// `CLLocationUpdate` reads the device's position another way and isn't changed. Other apps and
/// the system keep the real place and time.
///
/// Backstage doesn't link CoreLocation: it reaches Apple's location classes at run time, so an app
/// that never uses location isn't asked by App Store Connect why it does.
public final class LocationSimulator: Sendable {
    public static let shared = LocationSimulator(defaults: .standard)

    private static let key = "Backstage.location"
    private let state: Mutex<FakeLocation?>
    private nonisolated(unsafe) let defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults
        let saved = defaults.data(forKey: Self.key).flatMap { try? JSONDecoder().decode(FakeLocation.self, from: $0) }
        state = Mutex(saved)
    }

    /// The place the app is told it's at; `nil` for the device's own position.
    public var location: FakeLocation? {
        get { state.withLock { $0 } }
        set {
            state.withLock { $0 = newValue }
            if let newValue, let data = try? JSONEncoder().encode(newValue) {
                defaults.set(data, forKey: Self.key)
            } else {
                defaults.removeObject(forKey: Self.key)
            }
            if newValue != nil, Backstage.isActive {
                LocationCapture.install()
            }
            TimeZoneOverride.apply(active?.timeZone)
            LocationCapture.deliverToRunningManagers()
        }
    }

    /// What the app sees now: the fake location while Backstage is on.
    var active: FakeLocation? {
        Backstage.isActive ? location : nil
    }
}

/// Moves the app into another time zone through the `TZ` variable: `TimeZone.current`, date
/// formatting and calendars follow. A zone the app set as `NSTimeZone.default` is left as it is.
enum TimeZoneOverride {
    private struct Saved {
        /// The `TZ` variable before; `nil` when it wasn't set.
        var variable: String?
        var deviceZone: TimeZone
    }

    private static let saved = Mutex<Saved?>(nil)

    /// The device's own time zone, also while the app is in another.
    static var deviceTimeZone: TimeZone {
        saved.withLock { $0?.deviceZone } ?? .current
    }

    /// Uses the zone, or the device's again for `nil`.
    static func apply(_ zone: TimeZone?) {
        let changed: Bool = saved.withLock { saved in
            if let zone {
                if saved == nil {
                    saved = Saved(variable: getenv("TZ").map { String(cString: $0) }, deviceZone: .current)
                }
                setenv("TZ", zone.identifier, 1)
                return true
            }
            guard let original = saved else { return false }
            if let variable = original.variable {
                setenv("TZ", variable, 1)
            } else {
                unsetenv("TZ")
            }
            saved = nil
            return true
        }
        guard changed else { return }
        NSTimeZone.resetSystemTimeZone()
        // What the system posts when the device's zone changes, for views showing times.
        NotificationCenter.default.post(name: .NSSystemTimeZoneDidChange, object: nil)
    }
}

/// Apple's location classes, reached at run time rather than linked. They're loaded whenever the
/// app uses location itself (or MapKit, which does), the only time there's anything to fake.
enum LocationClasses {
    static var manager: AnyClass? { NSClassFromString("CLLocationManager") }

    private static let initializer = NSSelectorFromString("initWithCoordinate:altitude:horizontalAccuracy:verticalAccuracy:timestamp:")

    /// A `CLLocation` at the place, as precise as GPS outdoors, taken now.
    static func location(at place: FakeLocation) -> AnyObject? {
        let alloc = NSSelectorFromString("alloc")
        guard let cls = NSClassFromString("CLLocation"),
              let allocMethod = class_getClassMethod(cls, alloc),
              let initMethod = class_getInstanceMethod(cls, initializer) else { return nil }
        typealias Alloc = @convention(c) (AnyClass, Selector) -> Unmanaged<AnyObject>
        // The coordinate is a struct of two doubles, which goes in the same registers as two
        // doubles on both arm64 and x86_64.
        typealias Initialize = @convention(c) (Unmanaged<AnyObject>, Selector, Double, Double, Double, Double, Double, NSDate) -> Unmanaged<AnyObject>?
        let object = unsafeBitCast(method_getImplementation(allocMethod), to: Alloc.self)(cls, alloc)
        let initialize = unsafeBitCast(method_getImplementation(initMethod), to: Initialize.self)
        return initialize(object, initializer, place.latitude, place.longitude, 10, 5, 5, Date.now as NSDate)?.takeRetainedValue()
    }

    /// The location the app may be told: while using it or always.
    static func isAllowed(_ manager: NSObject) -> Bool {
        // CLAuthorizationStatus: 3 is always (or `authorized` on the Mac), 4 while using.
        let status = manager.value(forKey: "authorizationStatus") as? Int ?? 0
        return status == 3 || status == 4
    }
}

/// Puts the fake location into `CLLocationManager`. Installed only once Backstage is on and a
/// location is chosen, so App Store builds never change anything.
enum LocationCapture {
    private static let isInstalled = Mutex(false)
    private static let hookedReceivers = Mutex<Set<ObjectIdentifier>>([])
    /// Managers that are updating, to hand a new location to at once.
    private static let updating = Mutex<[ObjectIdentifier: WeakObject]>([:])

    private static let didUpdate = NSSelectorFromString("locationManager:didUpdateLocations:")
    /// Done once every loaded class was looked through; tests wait on it.
    static let scan = DispatchGroup()

    /// The older single-location callback some code still implements.
    private static let didUpdateTo = NSSelectorFromString("locationManager:didUpdateToLocation:fromLocation:")

    static func install() {
        // Nothing to fake in an app that doesn't use location.
        guard let manager = LocationClasses.manager else { return }
        let first = isInstalled.withLock { done in
            defer { done = true }
            return !done
        }
        guard first else { return }
        // Every class that takes location updates, the app's and the system's (such as MapKit's
        // for the blue dot), however its manager was made. Looking through every class takes a
        // moment, so not on the main thread; code loaded later is looked through when it loads.
        DispatchQueue.global(qos: .userInitiated).async(group: scan, execute: hookEveryReceiver)
        NotificationCenter.default.addObserver(forName: Bundle.didLoadNotification, object: nil, queue: nil) { notification in
            let names = notification.userInfo?[NSLoadedClasses] as? [String] ?? []
            names.compactMap(NSClassFromString).forEach(hookIfReceiver)
        }

        // The location property.
        let locationSelector = NSSelectorFromString("location")
        if let method = class_getInstanceMethod(manager, locationSelector) {
            typealias Getter = @convention(c) (AnyObject, Selector) -> AnyObject?
            let original = unsafeBitCast(method_getImplementation(method), to: Getter.self)
            let replacement: @convention(block) (AnyObject) -> AnyObject? = { object in
                LocationSimulator.shared.active.flatMap(LocationClasses.location(at:)) ?? original(object, locationSelector)
            }
            method_setImplementation(method, imp_implementationWithBlock(replacement))
        }

        // A delegate set now or later gets the fake locations.
        let setDelegate = NSSelectorFromString("setDelegate:")
        if let method = class_getInstanceMethod(manager, setDelegate) {
            typealias Setter = @convention(c) (AnyObject, Selector, AnyObject?) -> Void
            let original = unsafeBitCast(method_getImplementation(method), to: Setter.self)
            let replacement: @convention(block) (AnyObject, AnyObject?) -> Void = { object, delegate in
                if let delegate { hook(type(of: delegate)) }
                original(object, setDelegate, delegate)
            }
            method_setImplementation(method, imp_implementationWithBlock(replacement))
        }

        // Asking for the location answers with the fake one at once, as the device would.
        for (name, keepsUpdating) in [("startUpdatingLocation", true), ("requestLocation", false)] {
            let selector = NSSelectorFromString(name)
            guard let method = class_getInstanceMethod(manager, selector) else { continue }
            typealias Start = @convention(c) (AnyObject, Selector) -> Void
            let original = unsafeBitCast(method_getImplementation(method), to: Start.self)
            let replacement: @convention(block) (AnyObject) -> Void = { object in
                guard let manager = object as? NSObject else { return original(object, selector) }
                // A delegate handed over another way than setDelegate:, such as when it was made.
                if let delegate = manager.value(forKey: "delegate") as AnyObject? { hook(type(of: delegate)) }
                original(object, selector)
                if keepsUpdating {
                    updating.withLock { $0[ObjectIdentifier(manager)] = WeakObject(manager) }
                }
                deliver(to: manager)
            }
            method_setImplementation(method, imp_implementationWithBlock(replacement))
        }
        let stop = NSSelectorFromString("stopUpdatingLocation")
        if let method = class_getInstanceMethod(manager, stop) {
            typealias Stop = @convention(c) (AnyObject, Selector) -> Void
            let original = unsafeBitCast(method_getImplementation(method), to: Stop.self)
            let replacement: @convention(block) (AnyObject) -> Void = { object in
                updating.withLock { _ = $0.removeValue(forKey: ObjectIdentifier(object)) }
                original(object, stop)
            }
            method_setImplementation(method, imp_implementationWithBlock(replacement))
        }
    }

    /// Wraps every loaded class that implements a location update method itself.
    @Sendable private static func hookEveryReceiver() {
        var count: UInt32 = 0
        guard let list = objc_copyClassList(&count) else { return }
        defer { free(UnsafeMutableRawPointer(list)) }
        // Read as plain pointers: a Swift cast would message each class, and some of the
        // system's classes trap when touched before they're used.
        let classes = UnsafeRawPointer(list).assumingMemoryBound(to: UnsafeRawPointer.self)
        for index in 0..<Int(count) {
            hookIfReceiver(unsafeBitCast(classes[index], to: AnyClass.self))
        }
    }

    /// Wraps the class when it implements a location update method itself.
    @Sendable private static func hookIfReceiver(_ cls: AnyClass) {
        var methodCount: UInt32 = 0
        guard let methods = class_copyMethodList(cls, &methodCount) else { return }
        defer { free(methods) }
        for index in 0..<Int(methodCount) {
            let name = method_getName(methods[index])
            if name == didUpdate || name == didUpdateTo {
                hook(cls)
                return
            }
        }
    }

    /// Replaces the locations a class's location callbacks get, once. Only methods it has are
    /// wrapped; one it inherits is added to it, leaving the superclass alone.
    private static func hook(_ receiverClass: AnyClass) {
        let first = hookedReceivers.withLock { $0.insert(ObjectIdentifier(receiverClass)).inserted }
        guard first else { return }

        if let method = class_getInstanceMethod(receiverClass, didUpdate) {
            typealias DidUpdate = @convention(c) (AnyObject, Selector, AnyObject, NSArray) -> Void
            let original = unsafeBitCast(method_getImplementation(method), to: DidUpdate.self)
            let replacement: @convention(block) (AnyObject, AnyObject, NSArray) -> Void = { receiver, manager, locations in
                if let fake = LocationSimulator.shared.active.flatMap(LocationClasses.location(at:)) {
                    original(receiver, didUpdate, manager, [fake] as NSArray)
                } else {
                    original(receiver, didUpdate, manager, locations)
                }
            }
            replace(method, in: receiverClass, selector: didUpdate, with: imp_implementationWithBlock(replacement))
        }

        if let method = class_getInstanceMethod(receiverClass, didUpdateTo) {
            typealias DidUpdateTo = @convention(c) (AnyObject, Selector, AnyObject, AnyObject, AnyObject?) -> Void
            let original = unsafeBitCast(method_getImplementation(method), to: DidUpdateTo.self)
            let replacement: @convention(block) (AnyObject, AnyObject, AnyObject, AnyObject?) -> Void = { receiver, manager, new, old in
                original(receiver, didUpdateTo, manager, LocationSimulator.shared.active.flatMap(LocationClasses.location(at:)) ?? new, old)
            }
            replace(method, in: receiverClass, selector: didUpdateTo, with: imp_implementationWithBlock(replacement))
        }
    }

    private static func replace(_ method: Method, in cls: AnyClass, selector: Selector, with implementation: IMP) {
        if !class_addMethod(cls, selector, implementation, method_getTypeEncoding(method)) {
            method_setImplementation(method, implementation)
        }
    }

    /// Tells a manager's delegate the fake location, when the app may use location at all.
    private static func deliver(to manager: NSObject) {
        guard LocationSimulator.shared.active != nil, LocationClasses.isAllowed(manager) else { return }
        let box = WeakObject(manager)
        DispatchQueue.main.async {
            guard let manager = box.object as? NSObject,
                  let delegate = manager.value(forKey: "delegate") as? NSObject,
                  delegate.responds(to: didUpdate),
                  let fake = LocationSimulator.shared.active.flatMap(LocationClasses.location(at:)) else { return }
            hook(type(of: delegate))
            delegate.perform(didUpdate, with: manager, with: [fake] as NSArray)
        }
    }

    /// A newly chosen location reaches managers already updating.
    static func deliverToRunningManagers() {
        let managers = updating.withLock { $0.values.compactMap { $0.object as? NSObject } }
        managers.forEach(deliver(to:))
    }
}
