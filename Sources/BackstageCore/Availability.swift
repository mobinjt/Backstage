import CommonCrypto
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

    /// Asks StoreKit where the app came from. Builds installed from Xcode don't need to ask; a
    /// failure counts as the App Store, so Backstage stays off when unsure.
    static func detect() async -> RunEnvironment {
        if isFromXcode { return .xcode }
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

    /// A Debug build, the simulator, or a development-signed build, which only Xcode installs.
    /// A Release build run from Xcode on a device is the last kind: StoreKit doesn't call it
    /// `.xcode`.
    static let isFromXcode = isDebugBuild || isDevelopmentSigned

    static var isDebugBuild: Bool {
        #if DEBUG || targetEnvironment(simulator)
        true
        #else
        false
        #endif
    }

    /// The app's provisioning profile lets a debugger attach (`get-task-allow`), which only
    /// development profiles do. App Store and TestFlight builds carry no profile, and ad hoc and
    /// enterprise profiles don't allow it.
    static var isDevelopmentSigned: Bool {
        #if os(macOS)
        let url = Bundle.main.bundleURL.appending(path: "Contents/embedded.provisionprofile")
        #else
        let url = Bundle.main.bundleURL.appending(path: "embedded.mobileprovision")
        #endif
        guard let data = try? Data(contentsOf: url) else { return false }
        return allowsDebugging(provisioningProfile: data)
    }

    /// Reads `get-task-allow` from a provisioning profile: a signed message with the profile's
    /// property list inside, which is found by its XML markers rather than by checking the
    /// signature. Only the app's own bundle is read, so the signature was checked at install.
    static func allowsDebugging(provisioningProfile data: Data) -> Bool {
        guard
            let start = data.firstRange(of: Data("<?xml".utf8)),
            let end = data.firstRange(of: Data("</plist>".utf8), in: start.lowerBound..<data.endIndex),
            let plist = try? PropertyListSerialization.propertyList(from: data[start.lowerBound..<end.upperBound], format: nil) as? [String: Any],
            let entitlements = plist["Entitlements"] as? [String: Any]
        else { return false }
        return entitlements["get-task-allow"] as? Bool ?? false
    }
}

/// The passphrase that unlocks Backstage in TestFlight builds, and the flag that keeps a device
/// unlocked. The app's configuration holds only a salt and a hash; `swift run backstage-passphrase`
/// makes them.
///
/// The hash is PBKDF2 with HMAC-SHA256 and many rounds, so someone who takes the app apart and
/// finds it can only try a few guesses a second per core, not billions. It's written as
/// `pbkdf2-sha256$<rounds>$<hex>`, so the rounds can grow later without breaking older hashes.
public enum Passphrase {
    /// OWASP's recommendation for PBKDF2-HMAC-SHA256: about half a second to check on a phone.
    public static let defaultRounds = 600_000

    private static let scheme = "pbkdf2-sha256"

    public static func hash(_ passphrase: String, salt: String, rounds: Int = defaultRounds) -> String {
        "\(scheme)$\(rounds)$" + hex(derive(passphrase, salt: salt, rounds: rounds))
    }

    /// A random salt of 16 bytes, as hex.
    public static func makeSalt() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return hex(bytes)
    }

    /// Checks a guess against a stored hash, comparing in constant time so the time taken doesn't
    /// hint at how much of a guess matched. Anything not in the expected form never matches.
    static func matches(_ passphrase: String, salt: String, hash stored: String) -> Bool {
        let parts = stored.lowercased().split(separator: "$")
        guard parts.count == 3, parts[0] == scheme, let rounds = Int(parts[1]), rounds > 0 else { return false }
        let actual = Array(hex(derive(passphrase, salt: salt, rounds: rounds)).utf8)
        let expected = Array(parts[2].utf8)
        guard actual.count == expected.count else { return false }
        return zip(actual, expected).reduce(0) { $0 | ($1.0 ^ $1.1) } == 0
    }

    private static func derive(_ passphrase: String, salt: String, rounds: Int) -> [UInt8] {
        let password = Array(passphrase.utf8)
        let saltBytes = Array(salt.utf8)
        var derived = [UInt8](repeating: 0, count: 32)
        let status = password.withUnsafeBufferPointer { password in
            saltBytes.withUnsafeBufferPointer { salt in
                password.withMemoryRebound(to: CChar.self) { password in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        password.baseAddress, password.count,
                        salt.baseAddress, salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                        UInt32(clamping: rounds),
                        &derived, derived.count
                    )
                }
            }
        }
        return status == kCCSuccess ? derived : []
    }

    private static func hex(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02x", $0) }.joined()
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
