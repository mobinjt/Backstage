import BackstageCore
import SwiftUI

/// The chosen fake location, for the panel and the strip.
@MainActor
@Observable
final class LocationModel {
    static let shared = LocationModel()

    var location: FakeLocation? {
        didSet { LocationSimulator.shared.location = location }
    }

    private init() {
        location = LocationSimulator.shared.location
    }
}

/// Picks the place the app is told it's at: a city, or any place by its coordinates. No map, so
/// Backstage doesn't link MapKit or CoreLocation into the app.
struct LocationPickerView: View {
    @State private var model = LocationModel.shared
    @State private var name = ""
    @State private var coordinates = ""
    /// `nil` guesses the zone from the longitude.
    @State private var timeZone: String?

    private var typed: (latitude: Double, longitude: Double)? {
        Self.coordinates(in: coordinates)
    }

    var body: some View {
        Form {
            Section {
                LabeledContent("Now", value: model.location?.name ?? "The device's")
                if let location = model.location {
                    LabeledContent("Time Zone", value: location.timeZone.identifier)
                    Button("Use the Device's Location", systemImage: "location") { model.location = nil }
                }
            } footer: {
                Text("While set, the app is told it's here: its CLLocationManager, its maps' blue dot and current-location button, and web pages asking for the position. Its clock moves to the place's time zone. Code that uses CLLocationUpdate still gets the real position, and other apps keep the real place and time.")
            }

            Section("Cities") {
                ForEach(FakeLocation.presets, id: \.name) { preset in
                    Button {
                        model.location = preset
                    } label: {
                        HStack {
                            Text(preset.name).foregroundStyle(.primary)
                            Spacer()
                            if model.location == preset {
                                Image(systemName: "checkmark").foregroundStyle(BackstageStyle.accent)
                            }
                        }
                    }
                }
            }

            Section {
                TextField("Name, such as Office", text: $name)
                TextField("Coordinates, such as 35.6762, 139.6503", text: $coordinates)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .keyboardType(.numbersAndPunctuation)
                    #endif
                Picker("Time Zone", selection: $timeZone) {
                    Text(typed.map { "From the Longitude (\(Self.guessedZone(longitude: $0.longitude).identifier))" } ?? "From the Longitude")
                        .tag(String?.none)
                    ForEach(TimeZone.knownTimeZoneIdentifiers.sorted(), id: \.self) { identifier in
                        Text(identifier).tag(String?.some(identifier))
                    }
                }
                #if os(iOS)
                .pickerStyle(.navigationLink)
                #endif
                Button("Use This Place", systemImage: "mappin.and.ellipse", action: useTyped)
                    .disabled(typed == nil)
            } header: {
                Text("Somewhere Else")
            } footer: {
                Text("Paste coordinates from Apple Maps (Copy Coordinates) or Google Maps, or type them.")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Location")
        .onAppear(perform: showChosen)
    }

    private func useTyped() {
        guard let typed else { return }
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        model.location = FakeLocation(
            name: trimmed.isEmpty ? String(format: "%.4f, %.4f", typed.latitude, typed.longitude) : trimmed,
            latitude: typed.latitude,
            longitude: typed.longitude,
            timeZoneIdentifier: timeZone
        )
    }

    /// A place chosen here before shows in the fields, to change it.
    private func showChosen() {
        guard let location = model.location, !FakeLocation.presets.contains(location) else { return }
        name = location.name
        coordinates = String(format: "%.4f, %.4f", location.latitude, location.longitude)
        timeZone = location.timeZoneIdentifier
    }

    /// The zone a place with no known one gets.
    static func guessedZone(longitude: Double) -> TimeZone {
        FakeLocation(name: "", latitude: 0, longitude: longitude).timeZone
    }

    /// Reads "35.6762, 139.6503", or Apple Maps' "35.6762° N, 139.6503° E".
    static func coordinates(in text: String) -> (latitude: Double, longitude: Double)? {
        let matches = text.matches(of: /(-?\d+(?:\.\d+)?)\s*°?\s*([NSEWnsew])?/)
        guard matches.count == 2,
              var latitude = Double(matches[0].output.1),
              var longitude = Double(matches[1].output.1) else { return nil }
        if matches[0].output.2?.uppercased() == "S" { latitude = -latitude }
        if matches[1].output.2?.uppercased() == "W" { longitude = -longitude }
        guard (-90...90).contains(latitude), (-180...180).contains(longitude) else { return nil }
        return (latitude, longitude)
    }
}
