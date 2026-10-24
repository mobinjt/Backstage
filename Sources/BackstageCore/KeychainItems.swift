import Foundation
import Security

/// One of the app's own Keychain items.
public struct KeychainItem: Sendable, Identifiable, Hashable {
    public enum Kind: String, Sendable {
        case genericPassword = "Password"
        case internetPassword = "Internet password"
    }

    public let kind: Kind
    public let service: String?
    public let account: String?
    public let server: String?
    public let label: String?
    public let modified: Date?
    /// The Keychain's reference to exactly this item, so reading or deleting it never reaches
    /// another one.
    let reference: Data

    public var id: String { reference.base64EncodedString() }
    public var title: String { service ?? server ?? label ?? "(no service)" }
}

/// Lists, reads and deletes the app's own Keychain items, synced through iCloud or not.
public enum KeychainItems {
    public static func all() -> [KeychainItem] {
        [(KeychainItem.Kind.genericPassword, kSecClassGenericPassword), (.internetPassword, kSecClassInternetPassword)].flatMap { kind, itemClass in
            var query = baseQuery(itemClass)
            query[kSecReturnAttributes as String] = true
            query[kSecReturnPersistentRef as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitAll
            var result: CFTypeRef?
            guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let items = result as? [[String: Any]] else { return [KeychainItem]() }
            return items.compactMap { attributes in
                guard let reference = attributes[kSecValuePersistentRef as String] as? Data else { return nil }
                return KeychainItem(
                    kind: kind,
                    service: attributes[kSecAttrService as String] as? String,
                    account: attributes[kSecAttrAccount as String] as? String,
                    server: attributes[kSecAttrServer as String] as? String,
                    label: attributes[kSecAttrLabel as String] as? String,
                    modified: attributes[kSecAttrModificationDate as String] as? Date,
                    reference: reference
                )
            }
        }
        .sorted { ($0.title, $0.account ?? "") < ($1.title, $1.account ?? "") }
    }

    /// The item's value, as text when it is text.
    public static func value(of item: KeychainItem) -> String? {
        var query = queryFor(item)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8) ?? data.base64EncodedString()
    }

    @discardableResult
    public static func delete(_ item: KeychainItem) -> Bool {
        SecItemDelete(queryFor(item) as CFDictionary) == errSecSuccess
    }

    /// The app's own items: on the Mac the same kind of Keychain as on iPhone, never the user's
    /// login keychain with other apps' passwords. Items synced through iCloud too.
    private static func baseQuery(_ itemClass: CFString) -> [String: Any] {
        [
            kSecClass as String: itemClass,
            kSecUseDataProtectionKeychain as String: true,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny
        ]
    }

    private static func queryFor(_ item: KeychainItem) -> [String: Any] {
        var query = baseQuery(item.kind == .genericPassword ? kSecClassGenericPassword : kSecClassInternetPassword)
        query[kSecValuePersistentRef as String] = item.reference
        return query
    }
}
