import CoreLocation
import SwiftUI
import UIKit

struct SettingsView: View {
    @AppStorage(Settings.serverURLKey) private var serverURL = ""
    @AppStorage(Settings.apiKeyKey) private var apiKey = ""
    @AppStorage(Settings.permitZoneKey) private var permitZone = ""

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var test: Loadable<Void> = .idle

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("https://parking.example.com", text: $serverURL)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        .autocorrectionDisabled()
                        .textContentType(.URL)
                    SecureField("API key", text: $apiKey)
                } header: {
                    Text("Server")
                } footer: {
                    Text("The address of your parking server and the API key it was set up with.")
                }

                Section {
                    Button { Task { await testConnection() } } label: {
                        HStack {
                            Text("Test connection")
                            Spacer()
                            switch test {
                            case .idle: EmptyView()
                            case .loading: ProgressView()
                            case .loaded: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                            case .failed: Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
                            }
                        }
                    }
                    .disabled(test.isLoading || serverURL.isEmpty || apiKey.isEmpty)
                } footer: {
                    switch test {
                    case .loaded: Text("Connected. The server answered and accepted your key.")
                    case .failed(let message): Text(message)
                    default: EmptyView()
                    }
                }

                Section {
                    TextField("Zone number", text: $permitZone)
                        .keyboardType(.numberPad)
                } header: {
                    Text("Residential parking permit")
                } footer: {
                    Text("If you have an RPZ permit, enter its zone so blocks in that zone count as places you can park.")
                }

                Section {
                    Button("Open Location Settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                    }
                } header: {
                    Text("Location")
                } footer: {
                    Text("Seattle Parking uses your location to look up the street you're on. If Siri says it can't get your location, set Location to Always.")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .onChange(of: serverURL) { test = .idle }
            .onChange(of: apiKey) { test = .idle }
        }
    }

    /// Asks the server about a fixed downtown spot (Pike Place Market), so the
    /// check works without your location.
    private func testConnection() async {
        test = .loading
        do {
            let api = try ParkingAPI.fromSettings()
            _ = try await api.here(CLLocationCoordinate2D(latitude: 47.6097, longitude: -122.3422))
            test = .loaded(())
        } catch {
            test = .failed(errorMessage(error))
        }
    }
}
