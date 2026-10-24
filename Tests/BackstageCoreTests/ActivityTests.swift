import CoreLocation
import Foundation
import Testing
@testable import BackstageCore

struct EventLogTests {
    @Test func theLastOnesAreKeptAndSavedToTheFile() {
        let file = URL.temporaryDirectory.appending(path: "backstage-events-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let log = EventLog<ScreenVisit>(limit: 2, file: file)
        ["Home", "Detail", "Settings"].forEach { log.add(ScreenVisit(name: $0)) }
        #expect(log.events.map(\.name) == ["Detail", "Settings"], "Oldest first, the first gone past the limit")
        #expect(EventLog<ScreenVisit>(limit: 2, file: file).events.map(\.name) == ["Detail", "Settings"], "Read back on the next launch")
        log.clear()
        #expect(!FileManager.default.fileExists(atPath: file.path()))
    }
}

struct AppResetTests {
    @Test func defaultsGoExceptBackstagesWhenKept() {
        let domain = "backstage-reset-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }
        defaults.setPersistentDomain(["onboarded": true, "userID": "u1", "Backstage.server.api": "https://staging"], forName: domain)
        #expect(AppReset.resetDefaults(defaults, domain: domain, keepingBackstage: true) == 2)
        #expect(defaults.persistentDomain(forName: domain)?.keys.sorted() == ["Backstage.server.api"])
        #expect(AppReset.resetDefaults(defaults, domain: domain, keepingBackstage: false) == 1)
        #expect(defaults.persistentDomain(forName: domain)?.isEmpty == true)
    }

    @Test func filesGoAroundWhatsKept() throws {
        let root = URL.temporaryDirectory.appending(path: "backstage-reset-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let fileManager = FileManager.default
        for path in ["Documents/notes.txt", "Caches/Backstage/call.json", "Caches/images/a.png", "Support/com.example/Backstage/Fakes.json", "Support/com.example/db.sqlite"] {
            let file = root.appending(path: path)
            try fileManager.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("x".utf8).write(to: file)
        }
        // One kept folder written with a trailing slash, one without, as both happen.
        let removed = AppReset.removeFiles(
            in: [root.appending(path: "Documents"), root.appending(path: "Caches"), root.appending(path: "Support")],
            keeping: [root.appending(path: "Caches/Backstage", directoryHint: .isDirectory), root.appending(path: "Support/com.example/Backstage", directoryHint: .notDirectory)]
        )
        #expect(removed == 3)
        let left = fileManager.enumerator(at: root, includingPropertiesForKeys: nil)?.compactMap { ($0 as? URL)?.standardizedFileURL.path().replacingOccurrences(of: root.standardizedFileURL.path(), with: "") }.filter { $0.hasSuffix(".json") || $0.hasSuffix(".txt") || $0.hasSuffix(".png") || $0.hasSuffix(".sqlite") }.sorted()
        #expect(left == ["Caches/Backstage/call.json", "Support/com.example/Backstage/Fakes.json"])
    }

    @Test func backstagesFilesAreInsideTheAppsOwnFolders() {
        // So a reset finds them, and on a Mac outside the sandbox no other app shares them.
        let folders = AppReset.fileLocations.map(AppReset.plainPath)
        for location in AppReset.backstageLocations.map(AppReset.plainPath) {
            #expect(folders.contains { location.hasPrefix($0 + "/") }, "\(location)")
        }
        if Folders.sharesUserLibrary {
            #expect(Folders.caches.path(percentEncoded: false).contains("/\(Folders.bundleID)/"))
        }
    }
}

extension SharedStateTests {
    @Suite struct ActivityTests {
        private func on() { Backstage.active.withLock { $0 = true } }
        private func off() {
            Backstage.active.withLock { $0 = false }
            AppActivity.leaks.clear()
            AppActivity.screens.clear()
        }

        final class Model {}

        @Test func anObjectStillInMemoryIsSuspectedAndAFreedOneIsNot() async throws {
            on()
            defer { off() }
            let kept = Model()
            Backstage.expectRelease(of: kept, name: "Kept", within: 0.1)
            do {
                let freed = Model()
                Backstage.expectRelease(of: freed, name: "Freed", within: 0.1)
            }
            try await Task.sleep(for: .milliseconds(400))
            #expect(AppActivity.leaks.events.map(\.name) == ["Kept"])
            let suspect = try #require(AppActivity.leaks.events.first)
            #expect(AppActivity.isStillInMemory(suspect))
            withExtendedLifetime(kept) {}
        }

        @Test func screensAreNotedOnceAndNotWhileOff() {
            on()
            defer { off() }
            Backstage.screen("Home")
            Backstage.screen("Home")
            Backstage.screen("Detail")
            #expect(AppActivity.screens.events.map(\.name) == ["Home", "Detail"], "The same screen at once counts once")
            Backstage.active.withLock { $0 = false }
            Backstage.screen("Settings")
            #expect(AppActivity.screens.events.count == 2)
        }

        @Test func aPushHandedOverIsReadWithItsPayload() throws {
            on()
            defer {
                off()
                AppActivity.notifications.clear()
            }
            AppActivity.notifications.clear()
            Backstage.recordRemoteNotification([
                "aps": ["alert": ["title": "Your turn", "body": "Sara played a card"], "content-available": 1],
                "gameID": 42,
                "sent": Date(timeIntervalSince1970: 0)
            ])
            let record = try #require(AppActivity.notifications.events.last)
            #expect(record.title == "Your turn")
            #expect(record.body == "Sara played a card")
            #expect(record.isRemote)
            #expect(record.prettyPayload.contains(#""gameID" : 42"#))
            #expect(record.prettyPayload.contains("1970-01-01"), "A date is written as text")
        }
    }
}

/// Records the locations it's told about.
final class LocationListener: NSObject, CLLocationManagerDelegate, @unchecked Sendable {
    var received: [CLLocation] = []

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        received = locations
    }
}

/// Takes location updates from a manager it made itself, the way MapKit does.
final class OwnManagerListener: NSObject, CLLocationManagerDelegate, @unchecked Sendable {
    var received: [CLLocation] = []

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        received = locations
    }
}

extension SharedStateTests.ActivityTests {
    @Test func theAppSeesTheFakeLocationOnlyWhileBackstageIsOn() throws {
        let tokyo = try #require(FakeLocation.presets.first { $0.name == "Tokyo" })
        Backstage.active.withLock { $0 = true }
        LocationSimulator.shared.location = tokyo
        defer {
            LocationSimulator.shared.location = nil
            Backstage.active.withLock { $0 = false }
        }
        let manager = CLLocationManager()
        let listener = LocationListener()
        manager.delegate = listener
        #expect(manager.location?.coordinate.latitude == tokyo.latitude)

        // What the system hands the delegate is replaced. Called the way the system does, through
        // Objective-C; a direct Swift call would skip the hook.
        let real = CLLocation(latitude: 52.37, longitude: 4.89)
        manager.delegate?.locationManager?(manager, didUpdateLocations: [real])
        #expect(listener.received.first?.coordinate.longitude == tokyo.longitude)

        // A receiver that was never handed to setDelegate: still gets the fake place.
        LocationCapture.scan.wait()
        let other = OwnManagerListener()
        other.perform(NSSelectorFromString("locationManager:didUpdateLocations:"), with: manager, with: [real])
        #expect(other.received.first?.coordinate.longitude == tokyo.longitude)

        Backstage.active.withLock { $0 = false }
        manager.delegate?.locationManager?(manager, didUpdateLocations: [real])
        #expect(listener.received.first?.coordinate.longitude == 4.89, "Off: the real location goes through")
    }

    @Test func theAppMovesToThePlacesTimeZone() throws {
        let deviceZone = TimeZone.current.identifier
        let tokyo = try #require(FakeLocation.presets.first { $0.name == "Tokyo" })
        Backstage.active.withLock { $0 = true }
        LocationSimulator.shared.location = tokyo
        #expect(TimeZone.current.identifier == "Asia/Tokyo")
        #expect(Calendar.current.timeZone.identifier == "Asia/Tokyo")
        // iOS's reports are still read in the device's own time.
        #expect(TimeZoneOverride.deviceTimeZone.identifier == deviceZone)
        var components = DateComponents(year: 2026, month: 10, day: 22, hour: 23, minute: 59)
        components.timeZone = TimeZone(identifier: deviceZone)
        #expect(IOSReport.date("2026-10-22 23:59:00") == Calendar(identifier: .gregorian).date(from: components))

        LocationSimulator.shared.location = nil
        Backstage.active.withLock { $0 = false }
        #expect(TimeZone.current.identifier == deviceZone)
        #expect(NSTimeZone.default.identifier == deviceZone)
    }

    @Test func aPlaceWithoutAKnownZoneGetsOneFromItsLongitude() throws {
        let atSea = FakeLocation(name: "At sea", latitude: 0, longitude: 135)
        #expect(atSea.timeZone.secondsFromGMT() == 9 * 3600)
        // Saved before time zones were kept.
        let old = try JSONDecoder().decode(FakeLocation.self, from: Data(#"{"name":"Office","latitude":1,"longitude":2}"#.utf8))
        #expect(old.timeZoneIdentifier == nil)
    }

    @Test func theChoiceIsKeptAcrossLaunches() {
        let name = "backstage-location-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let simulator = LocationSimulator(defaults: defaults)
        simulator.location = FakeLocation(name: "Office", latitude: 35.7, longitude: 51.4)
        #expect(LocationSimulator(defaults: defaults).location?.name == "Office")
        simulator.location = nil
        #expect(LocationSimulator(defaults: defaults).location == nil)
    }
}
