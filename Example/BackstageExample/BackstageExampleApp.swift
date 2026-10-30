import Backstage
import SwiftUI
import UserNotifications

@main
struct BackstageExampleApp: App {
    // Backstage starts before anything makes a network session.
    private let backstage: Void = setUpBackstage()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .backstage()
        }
    }
}

private func setUpBackstage() {
    // The passphrase for this example is "backstage-example". Make your own with
    // `swift run backstage-passphrase` in the Backstage repository.
    var configuration = BackstageConfiguration(
        passphraseSalt: "99b31876b8b1a6d3405b74b4dad6ca21",
        passphraseHash: "pbkdf2-sha256$600000$96d991e58d3bce9e30d2f9ce185acd56a40a61e0b8fa840e991cd7a407e45f7a"
    )
    // Also records sessions made by libraries, not only the ones handed to `Backstage.record`.
    configuration.recordsAllSessions = true
    Backstage.shared.start(configuration)

    let registry = Backstage.shared.registry
    registry.addServers(key: DemoAPI.serverKey, servers: [
        .init("Production", url: DemoAPI.production),
        .init("Staging", url: URL(string: "https://dummyjson.com")!)
    ])
    registry.addInfo("User ID", group: "Account") { DemoData.userID }
    registry.addInfo("Signed in", group: "Account") { DemoData.token == nil ? "No" : "Yes" }
    registry.addSwitch("Use mock data", key: DemoAPI.mockDataKey, footnote: "Load a User answers from the app without calling the server.")
    registry.addSwitch("Verbose logging", key: DemoAPI.verboseLoggingKey, footnote: "Logs each request's headers.")
    registry.addAction("Send every request", group: "Demo") { await DemoAPI.shared.sendAll() }
    registry.addAction("Simulate a nearby peer", group: "Demo") { await NearbyPeer.simulate() }
    registry.addAction("Add sample iOS reports", group: "Demo") { SampleIOSReports.add() }
    registry.addAction("Reset demo data", group: "Demo") { DemoData.reset() }
    registry.addAction("Sign out", group: "Account", isDestructive: true) { DemoData.signOut() }
    registry.addPage("Check a User ID", group: "Account", systemImage: "person.text.rectangle") {
        UserIDCheckView()
    }

    DemoData.seedIfNeeded()

    // The app's own notification handling. Backstage notes the notifications on its own.
    UNUserNotificationCenter.current().delegate = NotificationHandler.shared
}

/// A screen of the app's own in the App tab: types a user ID and says whether it's the signed-in one.
private struct UserIDCheckView: View {
    @State private var text = ""

    var body: some View {
        Form {
            TextField("User ID", text: $text)
                .autocorrectionDisabled()
            if !text.isEmpty {
                if text == DemoData.userID {
                    Label("The signed-in user", systemImage: "checkmark.circle.fill")
                } else {
                    Label("Not the signed-in user", systemImage: "xmark.circle.fill")
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Check a User ID")
    }
}
