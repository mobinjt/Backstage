import Backstage
import CoreLocation
import MapKit
import SwiftUI
import UserNotifications

/// Shows notifications while the app is open and notes the ones tapped, as an app's own handling
/// would. Backstage records them without any code here.
final class NotificationHandler: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationHandler()

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let screen = response.notification.request.content.userInfo["screen"] as? String
        await MainActor.run { DemoState.shared.lastNotification = screen.map { "Opened for \"\($0)\"" } ?? "Opened" }
    }
}

/// What the example shows about links and notifications it received.
@Observable
final class DemoState {
    static let shared = DemoState()
    var lastLink: String?
    var lastNotification: String?
}

/// A screen with a model, named for Backstage's timeline. The model is checked to be freed when
/// the screen closes.
struct OrderDetailScreen: View {
    @State private var model = OrderModel()

    var body: some View {
        Form {
            Section {
                LabeledContent("Order", value: "#\(model.number)")
                LabeledContent("Status", value: "On its way")
            } footer: {
                Text("This screen shows in Backstage's Timeline as \"Order Detail\". When it closes, its model is checked to be freed.")
            }
        }
        .navigationTitle("Order Detail")
        .backstageScreen("Order Detail")
        .onDisappear { Backstage.expectRelease(of: model, name: "OrderModel") }
    }
}

@Observable
final class OrderModel {
    let number = Int.random(in: 1_000...9_999)
}

/// Which receipt screen to show.
enum ReceiptKind: String, Identifiable {
    case leaking, wellBehaved
    var id: String { rawValue }
}

#if os(iOS)
import UIKit

/// A UIKit screen. With `leaks`, a closure it keeps holds on to it, so it stays in memory after
/// it closes and Backstage lists it under Possible Leaks.
final class ReceiptViewController: UIViewController {
    private let leaks: Bool
    private var onRefresh: (() -> Void)?

    init(leaks: Bool) {
        self.leaks = leaks
        super.init(nibName: nil, bundle: nil)
        title = leaks ? "Leaking Receipt" : "Receipt"
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        let label = UILabel()
        label.numberOfLines = 0
        label.textAlignment = .center
        label.text = leaks
            ? "This screen leaks: a closure it keeps captures it strongly.\n\nSwipe down to close it; about 3 s later Backstage lists ReceiptViewController under Performance > Possible Leaks and in the Timeline."
            : "This screen is freed when it closes, so Backstage lists nothing."
        label.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            label.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
            label.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor)
        ])
        if leaks {
            // The mistake: self is captured strongly by a closure self keeps.
            onRefresh = { self.view.setNeedsLayout() }
        } else {
            onRefresh = { [weak self] in self?.view.setNeedsLayout() }
        }
    }
}

struct ReceiptScreen: UIViewControllerRepresentable {
    let leaks: Bool

    func makeUIViewController(context: Context) -> UINavigationController {
        UINavigationController(rootViewController: ReceiptViewController(leaks: leaks))
    }

    func updateUIViewController(_ controller: UINavigationController, context: Context) {}
}
#endif

/// Asks for the device's location the usual way, with a delegate. With a location set in
/// Backstage's Tools, the answer is that place.
@Observable
final class WhereAmI: NSObject, CLLocationManagerDelegate {
    static let shared = WhereAmI()

    private(set) var answer: String?
    private let manager = CLLocationManager()

    override init() {
        super.init()
        manager.delegate = self
    }

    func ask() {
        answer = "Asking…"
        switch manager.authorizationStatus {
        case .notDetermined: manager.requestWhenInUseAuthorization()
        case .denied, .restricted: answer = "Location isn't allowed"
        default: manager.requestLocation()
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            if answer != nil, status != .notDetermined { ask() }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let coordinate = locations.last?.coordinate else { return }
        let text = String(format: "%.4f, %.4f", coordinate.latitude, coordinate.longitude)
        Task { @MainActor in answer = text }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: any Error) {
        let text = error.localizedDescription
        Task { @MainActor in answer = text }
    }
}

/// A map with the system's own current-location button and blue dot, and the location the app's
/// code gets, side by side.
struct MapScreen: View {
    @State private var camera: MapCameraPosition = .userLocation(fallback: .automatic)
    @State private var whereAmI = WhereAmI.shared
    /// What the newer async API reports.
    @State private var liveUpdate: String?

    var body: some View {
        Map(position: $camera) {
            UserAnnotation()
        }
        .mapControls {
            MapUserLocationButton()
        }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 4) {
                Text("CLLocationManager: \(whereAmI.answer ?? "…")")
                Text("CLLocationUpdate: \(liveUpdate ?? "…")")
                Text("Time here: \(Date.now.formatted(date: .omitted, time: .shortened)), \(TimeZone.current.identifier)")
            }
            .font(.footnote)
            .padding(8)
            .background(.regularMaterial, in: .rect(cornerRadius: 12))
            .padding(.bottom, 8)
        }
        .navigationTitle("Map")
        .onAppear { whereAmI.ask() }
        .task {
            do {
                for try await update in CLLocationUpdate.liveUpdates() {
                    if let coordinate = update.location?.coordinate {
                        liveUpdate = String(format: "%.4f, %.4f", coordinate.latitude, coordinate.longitude)
                    }
                }
            } catch {
                liveUpdate = error.localizedDescription
            }
        }
    }
}
