import Foundation
import ObjectiveC
import Synchronization
import UserNotifications

/// Notes the notifications the app gets, by listening in on its notification center delegate:
/// those that arrive while it's open and those that are tapped. The app's own handling runs as
/// before. Only ever installed while Backstage is on; App Store builds never change anything.
enum NotificationCapture {
    private static let isInstalled = Mutex(false)
    private static let hookedClasses = Mutex<Set<ObjectIdentifier>>([])

    private static let willPresent = NSSelectorFromString("userNotificationCenter:willPresentNotification:withCompletionHandler:")
    private static let didReceive = NSSelectorFromString("userNotificationCenter:didReceiveNotificationResponse:withCompletionHandler:")

    static func install() {
        let first = isInstalled.withLock { done in
            defer { done = true }
            return !done
        }
        guard first else { return }
        let center = UNUserNotificationCenter.current()
        // A delegate set later is listened in on too.
        let setDelegate = NSSelectorFromString("setDelegate:")
        if let method = class_getInstanceMethod(UNUserNotificationCenter.self, setDelegate) {
            typealias SetDelegate = @convention(c) (AnyObject, Selector, AnyObject?) -> Void
            let original = unsafeBitCast(method_getImplementation(method), to: SetDelegate.self)
            let replacement: @convention(block) (AnyObject, AnyObject?) -> Void = { center, delegate in
                if let delegate { hook(type(of: delegate)) }
                original(center, setDelegate, delegate)
            }
            method_setImplementation(method, imp_implementationWithBlock(replacement))
        }
        if let delegate = center.delegate {
            hook(type(of: delegate))
        }
    }

    /// Wraps the delegate's methods that it implements; ones it doesn't stay missing, so the
    /// system's behaviour doesn't change.
    private static func hook(_ delegateClass: AnyClass) {
        let first = hookedClasses.withLock { $0.insert(ObjectIdentifier(delegateClass)).inserted }
        guard first else { return }

        if let method = class_getInstanceMethod(delegateClass, willPresent), !recordsAlready(delegateClass, willPresent) {
            typealias WillPresent = @convention(c) (AnyObject, Selector, UNUserNotificationCenter, UNNotification, @escaping @convention(block) (UNNotificationPresentationOptions) -> Void) -> Void
            let original = unsafeBitCast(method_getImplementation(method), to: WillPresent.self)
            let replacement: @convention(block) (AnyObject, UNUserNotificationCenter, UNNotification, @escaping @convention(block) (UNNotificationPresentationOptions) -> Void) -> Void = { delegate, center, notification, completion in
                record(notification, event: .arrived, action: nil)
                original(delegate, willPresent, center, notification, completion)
            }
            replace(method, in: delegateClass, selector: willPresent, with: imp_implementationWithBlock(replacement))
        }

        if let method = class_getInstanceMethod(delegateClass, didReceive), !recordsAlready(delegateClass, didReceive) {
            typealias DidReceive = @convention(c) (AnyObject, Selector, UNUserNotificationCenter, UNNotificationResponse, @escaping @convention(block) () -> Void) -> Void
            let original = unsafeBitCast(method_getImplementation(method), to: DidReceive.self)
            let replacement: @convention(block) (AnyObject, UNUserNotificationCenter, UNNotificationResponse, @escaping @convention(block) () -> Void) -> Void = { delegate, center, response, completion in
                let action = response.actionIdentifier == UNNotificationDefaultActionIdentifier ? nil : response.actionIdentifier
                record(response.notification, event: .opened, action: action)
                original(delegate, didReceive, center, response, completion)
            }
            replace(method, in: delegateClass, selector: didReceive, with: imp_implementationWithBlock(replacement))
        }
    }

    /// The class only inherits the method from a class wrapped earlier, which notes it already.
    private static func recordsAlready(_ cls: AnyClass, _ selector: Selector) -> Bool {
        let method = class_getInstanceMethod(cls, selector)
        var ancestor: AnyClass? = class_getSuperclass(cls)
        while let current = ancestor, class_getInstanceMethod(current, selector) == method {
            if hookedClasses.withLock({ $0.contains(ObjectIdentifier(current)) }) { return true }
            ancestor = class_getSuperclass(current)
        }
        return false
    }

    /// The class gets its own method when it only inherits one, so its superclass and other
    /// subclasses are left alone.
    private static func replace(_ method: Method, in cls: AnyClass, selector: Selector, with implementation: IMP) {
        if !class_addMethod(cls, selector, implementation, method_getTypeEncoding(method)) {
            method_setImplementation(method, implementation)
        }
    }

    static func record(_ notification: UNNotification, event: NotificationRecord.Event, action: String?) {
        guard Backstage.isActive else { return }
        AppActivity.notifications.add(NotificationRecord(notification, event: event, action: action))
    }

    /// Notes what's in Notification Center that wasn't seen yet: notifications that arrived while
    /// the app was closed or in the background and weren't tapped.
    static func readNotificationCenter() async {
        guard Backstage.isActive else { return }
        let delivered = await UNUserNotificationCenter.current().deliveredNotifications()
        let seen = Set(AppActivity.notifications.events.map(\.identifier))
        for notification in delivered.sorted(by: { $0.date < $1.date }) where !seen.contains(notification.request.identifier) {
            var record = NotificationRecord(notification, event: .inNotificationCenter, action: nil)
            record.date = notification.date
            AppActivity.notifications.add(record)
        }
    }
}

extension NotificationRecord {
    init(_ notification: UNNotification, event: Event, action: String?) {
        let content = notification.request.content
        self.init(
            event: event,
            identifier: notification.request.identifier,
            title: content.title,
            subtitle: content.subtitle,
            body: content.body,
            category: content.categoryIdentifier,
            isRemote: notification.request.trigger is UNPushNotificationTrigger,
            action: action,
            payload: Self.json(content.userInfo)
        )
    }
}

extension Backstage {
    /// Notes what's in Notification Center that wasn't seen yet. The panel does this when it shows
    /// notifications.
    public static func readNotificationCenter() async {
        await NotificationCapture.readNotificationCenter()
    }
}
