import BackstageCore
import Foundation

// Asks for a passphrase without showing it and prints the salt and PBKDF2 hash for
// `BackstageConfiguration`. The passphrase itself is never printed or stored.
guard let entered = getpass("Passphrase for TestFlight builds: "), !String(cString: entered).isEmpty else {
    print("No passphrase given.")
    exit(1)
}
let passphrase = String(cString: entered)
if passphrase.count < 12 {
    print("Use at least 12 characters: the hash ships in the app, so a short passphrase can be guessed.")
    exit(1)
}
let salt = Passphrase.makeSalt()
let hash = Passphrase.hash(passphrase, salt: salt)
print("""

BackstageConfiguration(
    passphraseSalt: "\(salt)",
    passphraseHash: "\(hash)"
)
""")
