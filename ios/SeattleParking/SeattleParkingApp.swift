import CoreLocation
import SwiftUI

@main
struct SeattleParkingApp: App {
    var body: some Scene {
        WindowGroup { ContentView() }
    }
}

/// Settings and a manual test. Siri does the real work through the intents.
struct ContentView: View {
    @AppStorage(Settings.serverURLKey) private var serverURL = ""
    @AppStorage(Settings.apiKeyKey) private var apiKey = ""
    @AppStorage(Settings.permitZoneKey) private var permitZone = ""

    @State private var locationManager = CLLocationManager()
    @State private var output = ""
    @State private var busy = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Server") {
                    TextField("Server URL", text: $serverURL)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        .autocorrectionDisabled()
                    SecureField("API key", text: $apiKey)
                    TextField("RPZ permit zone (optional)", text: $permitZone)
                        .keyboardType(.numberPad)
                }
                Section {
                    Button("Allow location access") { locationManager.requestWhenInUseAuthorization() }
                } footer: {
                    Text("Siri needs this to look up parking where you are.")
                }
                Section("Try it") {
                    Button("Parking rules here") { run { api, c in try await api.here(c).speech } }
                    Button("Find parking") { run { api, c in try await api.nearby(c).speech } }
                    if busy { ProgressView() }
                    if !output.isEmpty { Text(output).font(.callout) }
                }
                Section("Ask Siri") {
                    Text("\u{201C}Parking rules here in Seattle Parking\u{201D}")
                    Text("\u{201C}Find parking with Seattle Parking\u{201D}")
                }
            }
            .navigationTitle("Seattle Parking")
        }
    }

    private func run(_ call: @escaping (ParkingAPI, CLLocationCoordinate2D) async throws -> String) {
        busy = true
        output = ""
        Task {
            do {
                let api = try ParkingAPI.fromSettings()
                output = try await call(api, try await LocationProvider.current())
            } catch let error as ParkingError {
                output = String(localized: error.localizedStringResource)
            } catch {
                output = error.localizedDescription
            }
            busy = false
        }
    }
}
