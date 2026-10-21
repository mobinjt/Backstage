import CryptoKit
import Foundation
import Security
import StoreKit

/// Where the app runs, which decides whether Backstage is on.
public enum RunEnvironment: String, Sendable, Codable {
    /// A Debug build, the simulator, or any build run from Xcode: always on.
    case xcode
    /// A TestFlight build: on only on devices unlocked with the passphrase.
    case testFlight
    /// The App Store, or anything that couldn't be told apart from it: always off.
    case appStore

    /// Asks StoreKit where the app came from. Debug builds and the simulator don't need to ask;
    /// a failure counts as the App Store, so Backstage stays off when unsure.
    static func detect() async -> RunEnvironment {
        if isDebugBuild { return .xcode }
        do {
            let transaction = try await AppTransaction.shared
            switch transaction.unsafePayloadValue.environment {
            case .xcode: return .xcode
            case .sandbox: return .testFlight
            default: return .appStore
            }
        } catch {
            return .appStore
        }
    }

    static var isDebugBuild: Bool {
        #if DEBUG || targetEnvironment(simulator)
        true
        #else
        false
        #endif
    }
}

/// The passphrase that unlocks Backstage in TestFlight builds, and the flag that keeps a device
/// unlocked. The app's configuration holds only a salted hash; `swift run backstage-passphrase`
/// makes one.
public enum Passphrase {
    /// The hex SHA-256 of the salt followed by the passphrase.
    public static func hash(_ passphrase: String, salt: String) -> String {
        let digest = SHA256.hash(data: Data((salt + passphrase).utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// A random salt of 16 bytes, as hex.
    public static func makeSalt() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// Compares in constant time, so the time taken doesn't hint at how much of a guess matched.
    static func matches(_ passphrase: String, salt: String, hash expected: String) -> Bool {
        let actual = Array(hash(passphrase, salt: salt).utf8)
        let expected = Array(expected.lowercased().utf8)
        guard actual.count == expected.count else { return false }
        return zip(actual, expected).reduce(0) { $0 | ($1.0 ^ $1.1) } == 0
    }
}

/// The unlocked flag, kept in the Keychain so it survives reinstalling the app on the owner's
/// device and never reaches another device.
struct UnlockStore: Sendable {
    let service: String
    let account: String

    static let standard = UnlockStore(service: "Backstage", account: (Bundle.main.bundleIdentifier ?? "app") + ".unlocked")

    var isUnlocked: Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    func setUnlocked(_ unlocked: Bool) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
        guard unlocked else { return }
        var item = query
        item[kSecValueData as String] = Data("1".utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(item as CFDictionary, nil)
    }
}
