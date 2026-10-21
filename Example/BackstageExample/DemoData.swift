import Foundation
import Security

/// A few UserDefaults values and a Keychain item, for Backstage's Storage tab.
enum DemoData {
    private static let defaults = UserDefaults.standard
    private static let keychainService = "com.mobinjt.BackstageExample"
    private static let keychainAccount = "session"

    static var userID: String? { defaults.string(forKey: "userID") }

    static func seedIfNeeded() {
        if userID == nil {
            reset()
        }
    }

    static func reset() {
        defaults.set("user_8f3a21", forKey: "userID")
        defaults.set(true, forKey: "hasSeenOnboarding")
        defaults.set("system", forKey: "appearance")
        defaults.set(Date.now, forKey: "lastSync")
        saveToken("demo-session-7c1e9b0d")
    }

    static var token: String? {
        var query = keychainQuery
        query[kSecReturnData as String] = true
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    static func signOut() {
        SecItemDelete(keychainQuery as CFDictionary)
        defaults.removeObject(forKey: "userID")
    }

    private static func saveToken(_ token: String) {
        SecItemDelete(keychainQuery as CFDictionary)
        var item = keychainQuery
        item[kSecValueData as String] = Data(token.utf8)
        SecItemAdd(item as CFDictionary, nil)
    }

    private static var keychainQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount
        ]
    }
}
