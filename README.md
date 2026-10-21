# Backstage

An in-app debug panel for the owner's apps: every network call the app makes, its logs, a server
switch, the app's own actions and switches, its storage, and a performance overlay.

It's for the owner only:

| Where the app runs | Backstage |
|---|---|
| Xcode (a Debug build, the simulator, or any build run from Xcode) | On from launch. Shake, ⌃⌥⌘D, or the hidden trigger opens it. |
| TestFlight | Off and invisible. The hidden trigger asks for a passphrase; a device unlocked with it stays unlocked until **Lock**. Testers' devices record nothing. |
| App Store | Off. Nothing is recorded and nothing opens it. |

TestFlight and App Store builds are the same binary, so Backstage decides when the app runs: it
asks StoreKit's `AppTransaction` (`.xcode`, `.sandbox` for TestFlight, `.production`). Anything
it can't tell counts as the App Store.

## Adding it to an app

1. Add the package by its URL (Xcode > Add Package Dependencies) and the **Backstage** product to
   the app target. For Xcode Cloud, give it access to this repository once (App Store Connect >
   Xcode Cloud > Settings > Repositories).
2. Make a passphrase hash: `swift run backstage-passphrase` in this repository. It asks for the
   passphrase (8 characters or more; mix letters, digits and symbols) without showing it and prints the salt and hash. Only
   those go in the app. The hash is PBKDF2-HMAC-SHA256 with 600,000 rounds, so someone who finds
   it in the app can only test a few guesses a second; a long passphrase keeps it out of reach.
3. Start it first thing at launch, before anything makes a network session:

   ```swift
   import Backstage

   @main
   struct MyApp: App {
       private let backstage: Void = Backstage.shared.start(
           BackstageConfiguration(passphraseSalt: "…", passphraseHash: "…")
       )

       var body: some Scene {
           WindowGroup {
               RootView()
                   .backstage()
           }
       }
   }
   ```

4. Put the hidden trigger on something unremarkable, such as the version row in Settings:

   ```swift
   LabeledContent("Version", value: version)
       .backstageTrigger()   // seven taps, each within two seconds of the last
   ```

5. Record the app's sessions: `Backstage.record(configuration)` on each `URLSessionConfiguration`
   before making the session. `URLSession.shared` is recorded without it. Set
   `recordsAllSessions` in the configuration to also record libraries' sessions (it adds the
   recording protocol to every new `.default` and `.ephemeral` configuration, only while Backstage
   is on).

## What's in the panel

- **Network.** Every HTTP call: method, URL, status, timing, headers and bodies (cut at 1 MB),
  with search and filters, pretty JSON, copy as cURL, and export as HAR or JSON. `Authorization`,
  cookies and API keys stay hidden until tapped and are left out of exports. The last 1,000 calls
  are kept across launches in the app's Caches. WebSockets and other connections the app reports
  (`NetworkRecorder.shared.openConnection(kind:url:headers:note:)`) show with their messages.
- **Logs.** This launch's `Logger` messages, read with `OSLogStore`, filtered by level and
  category.
- **App.** Where it runs, the build, the device, and what the app registers through
  `Backstage.shared.registry`:
  - `addServers(key:servers:)`: a server switch. The app reads the choice with
    `Backstage.server(for:)` when it starts. A strip at the top of the screen shows a server
    that isn't the app's own.
  - `addInfo(_:group:value:)`: lines of information, such as IDs.
  - `addAction(_:group:isDestructive:perform:)`: buttons.
  - `addSwitch(_:key:group:footnote:)`: switches the app reads with `Backstage.isOn(_:)`.
- **Storage.** The app's UserDefaults (edit, delete), Keychain items (show a value after
  confirming, delete) and files (browse, share, delete).
- **Performance.** A floating overlay with frame rate, dropped frames, memory and CPU, and a
  one-minute graph. A flash marks a main-thread hang (over 250 ms). The tab adds charts and the
  last hangs.

## How it's built

- `BackstageCore`: when it's on, the passphrase, the recorder (`NetworkRecorder`,
  `RecordingURLProtocol`), logs, Keychain and performance sampling. No UI.
- `Backstage`: the SwiftUI panel. On iPhone and iPad it lives in its own window above the app's,
  so it opens over sheets and the overlay stays on top; touches pass through everywhere else. On
  the Mac the panel and the overlay are their own windows.
- iOS 18 and macOS 15, Swift 6, no dependencies. Nothing leaves the device unless the owner
  exports it.

`swift test` runs the core's tests: when it's on, the passphrase, recording limits, files across
launches, export, and a request recorded through the protocol.

## License

MIT. See [LICENSE](LICENSE).
