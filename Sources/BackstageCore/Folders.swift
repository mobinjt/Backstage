import Foundation

/// Where Backstage keeps its files, apart from each other app's.
enum Folders {
    /// A Mac app outside the sandbox shares the user's Library with every other app.
    static var sharesUserLibrary: Bool {
        #if os(macOS)
        ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] == nil
        #else
        false
        #endif
    }

    static var bundleID: String { Bundle.main.bundleIdentifier ?? "app" }

    /// Records: `Caches/Backstage`, or inside the app's own folder when the Library is shared.
    static var caches: URL {
        let base = sharesUserLibrary ? URL.cachesDirectory.appending(path: bundleID, directoryHint: .isDirectory) : URL.cachesDirectory
        return base.appending(path: "Backstage", directoryHint: .isDirectory)
    }

    /// Settings kept across launches, such as fakes.
    static var support: URL {
        URL.applicationSupportDirectory.appending(path: bundleID, directoryHint: .isDirectory).appending(path: "Backstage", directoryHint: .isDirectory)
    }
}
