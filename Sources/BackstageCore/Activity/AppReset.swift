import Foundation

/// Puts the app back to a fresh install, for testing first launch and onboarding: its
/// UserDefaults, Keychain items, files, cookies and URL cache. The app should quit afterwards.
public enum AppReset {
    /// What was removed, for the panel to report.
    public struct Result: Sendable {
        public var defaults = 0
        public var keychainItems = 0
        public var files = 0
    }

    /// Resets the app. With `keepingBackstage`, Backstage's own settings and records stay: the
    /// server and switches, fakes, recorded calls and reports. The device stays unlocked either
    /// way.
    @discardableResult
    public static func reset(keepingBackstage: Bool) -> Result {
        var result = Result()
        result.defaults = resetDefaults(.standard, domain: Bundle.main.bundleIdentifier ?? "", keepingBackstage: keepingBackstage)
        for item in KeychainItems.all() where item.service != UnlockStore.standard.service {
            if KeychainItems.delete(item) { result.keychainItems += 1 }
        }
        result.files = removeFiles(in: fileLocations, keeping: keepingBackstage ? backstageLocations : [])
        HTTPCookieStorage.shared.removeCookies(since: .distantPast)
        URLCache.shared.removeAllCachedResponses()
        return result
    }

    /// Removes the domain's values, all but Backstage's when kept. Returns how many went.
    static func resetDefaults(_ defaults: UserDefaults, domain: String, keepingBackstage: Bool) -> Int {
        let values = defaults.persistentDomain(forName: domain) ?? [:]
        let removed = values.keys.filter { !keepingBackstage || !$0.hasPrefix("Backstage.") }
        // One by one: replacing the whole domain doesn't always reach the disk.
        for key in removed {
            defaults.removeObject(forKey: key)
        }
        // Written in the background otherwise, and the app quits next.
        defaults.synchronize()
        return removed.count
    }

    /// Removes what's in each folder except the kept paths. Returns how many items went.
    static func removeFiles(in folders: [URL], keeping kept: [URL]) -> Int {
        let fileManager = FileManager.default
        let keptPaths = kept.map(Self.plainPath)
        var removed = 0
        func clear(_ folder: URL) {
            for item in (try? fileManager.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [] {
                let path = Self.plainPath(item)
                if keptPaths.contains(path) { continue }
                if keptPaths.contains(where: { $0.hasPrefix(path + "/") }) {
                    // Something inside is kept; clear around it.
                    clear(item)
                } else if (try? fileManager.removeItem(at: item)) != nil {
                    removed += 1
                }
            }
        }
        folders.forEach(clear)
        return removed
    }

    /// A path to compare: links followed, no trailing slash. A folder listed by the file manager
    /// ends in a slash; one made with `appending(path:)` may not.
    static func plainPath(_ url: URL) -> String {
        var path = url.resolvingSymlinksInPath().standardizedFileURL.path(percentEncoded: false)
        while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
        return path
    }

    /// The app's own folders. A Mac app outside the sandbox shares the user's home, so only its
    /// own Application Support and Caches folders are touched there.
    public static var fileLocations: [URL] {
        if Folders.sharesUserLibrary {
            return [
                URL.applicationSupportDirectory.appending(path: Folders.bundleID, directoryHint: .isDirectory),
                URL.cachesDirectory.appending(path: Folders.bundleID, directoryHint: .isDirectory)
            ]
        }
        return [URL.documentsDirectory, URL.applicationSupportDirectory, URL.cachesDirectory, URL.temporaryDirectory]
    }

    /// The app's container, to look through; `nil` for a Mac app outside the sandbox, whose
    /// folder is the user's home. Its own folders are in `fileLocations` then.
    public static var container: URL? {
        Folders.sharesUserLibrary ? nil : URL(filePath: NSHomeDirectory(), directoryHint: .isDirectory)
    }

    /// Where Backstage keeps its records and fakes.
    static var backstageLocations: [URL] {
        [Folders.caches, Folders.support]
    }
}
