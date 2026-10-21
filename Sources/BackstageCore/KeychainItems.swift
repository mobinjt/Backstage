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

    public var id: String { [kind.rawValue, service ?? server ?? "", account ?? ""].joined(separator: "|") }
    public var title: String { service ?? server ?? label ?? "(no service)" }
}

/// Lists, reads and deletes the app's own Keychain items.
public enum KeychainItems {
    public static func all() -> [KeychainItem] {
        [(KeychainItem.Kind.genericPassword, kSecClassGenericPassword), (.internetPassword, kSecClassInternetPassword)].flatMap { kind, itemClass in
            let query: [String: Any] = [
                kSecClass as String: itemClass,
                kSecReturnAttributes as String: true,
                kSecMatchLimit as String: kSecMatchLimitAll
            ]
            var result: CFTypeRef?
            guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let items = result as? [[String: Any]] else { return [KeychainItem]() }
            return items.map { attributes in
                KeychainItem(
                    kind: kind,
                    service: attributes[kSecAttrService as String] as? String,
                    account: attributes[kSecAttrAccount as String] as? String,
                    server: attributes[kSecAttrServer as String] as? String,
                    label: attributes[kSecAttrLabel as String] as? String,
                    modified: attributes[kSecAttrModificationDate as String] as? Date
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

    private static func queryFor(_ item: KeychainItem) -> [String: Any] {
        var query: [String: Any] = [kSecClass as String: item.kind == .genericPassword ? kSecClassGenericPassword : kSecClassInternetPassword]
        if let service = item.service { query[kSecAttrService as String] = service }
        if let server = item.server { query[kSecAttrServer as String] = server }
        if let account = item.account { query[kSecAttrAccount as String] = account }
        return query
    }
}
