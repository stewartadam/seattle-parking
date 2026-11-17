import CoreLocation
import SwiftUI

/// The main screen: the rules where you're standing, a parking search with a
/// map, and the phrases Siri understands. Settings live in a sheet.
struct HomeView: View {
    @AppStorage(Settings.serverURLKey) private var serverURL = ""
    @AppStorage(Settings.apiKeyKey) private var apiKey = ""

    @State private var showSettings = false
    @State private var here: Loadable<HereResponse> = .idle
    @State private var locationManager = CLLocationManager()

    private var isConfigured: Bool {
        !serverURL.trimmingCharacters(in: .whitespaces).isEmpty && !apiKey.isEmpty
    }

    var body: some View {
        NavigationStack {
            List {
                if isConfigured {
                    hereSection
                    findSection
                    siriSection
                } else {
                    setupSection
                }
            }
            .navigationTitle("Seattle Parking")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showSettings = true } label: { Image(systemName: "gearshape") }
                        .accessibilityLabel("Settings")
                }
            }
            .refreshable { await loadHere() }
            .sheet(isPresented: $showSettings, onDismiss: { Task { await loadHere() } }) {
                SettingsView()
            }
            .task {
                guard isConfigured else {
                    showSettings = true
                    return
                }
                if locationManager.authorizationStatus == .notDetermined {
                    locationManager.requestWhenInUseAuthorization()
                }
                await loadHere()
            }
        }
    }

    // MARK: - Sections

    private var setupSection: some View {
        Section {
            VStack(spacing: 12) {
                Image(systemName: "parkingsign.circle.fill")
                    .font(.system(size: 56))
                    .foregroundStyle(.tint)
                Text("Set up Seattle Parking").font(.headline)
                Text("Enter your parking server and API key to get started.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("Open Settings") { showSettings = true }
                    .buttonStyle(.borderedProminent)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 24)
        }
    }

    private var hereSection: some View {
        Section {
            switch here {
            case .idle, .loading:
                HStack(spacing: 12) {
                    ProgressView()
                    Text("Checking the street you're on…").foregroundStyle(.secondary)
                }
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
            case .loaded(let answer):
                if answer.blockfaces.isEmpty {
                    Text(answer.speech)
                }
                if answer.blockfaces.contains(where: { $0.curbCoordinates != nil }) {
                    HereMap(blockfaces: answer.blockfaces)
                        .frame(height: 150)
                        .listRowInsets(EdgeInsets())
                }
                ForEach(answer.blockfaces, id: \.self) { BlockfaceRow(blockface: $0) }
                if let zone = answer.rpzZone?.zone {
                    Label(
                        "RPZ zone \(zone)" + (answer.rpzZone?.inEffect.map { " · \($0)" } ?? ""),
                        systemImage: "person.text.rectangle"
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }
            }
        } header: {
            HStack {
                Text(hereTitle)
                Spacer()
                Button { Task { await loadHere() } } label: { Image(systemName: "arrow.clockwise") }
                    .disabled(here.isLoading)
                    .accessibilityLabel("Refresh")
            }
            .textCase(nil)
            .font(.headline)
        }
    }

    private var hereTitle: String {
        if case .loaded(let answer) = here, let street = answer.blockfaces.first?.street { return street }
        return "Right here"
    }

    private var findSection: some View {
        Section {
            NavigationLink {
                FindParkingView()
            } label: {
                Label("Find parking nearby", systemImage: "magnifyingglass")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .listRowBackground(Color.accentColor)
        } footer: {
            Text("Search around you, then pan the map to look somewhere else.")
        }
    }

    private var siriSection: some View {
        Section {
            SiriPhrase(text: "Can I park here with Seattle Parking")
            SiriPhrase(text: "Find parking with Seattle Parking")
            SiriPhrase(text: "Directions to spot 2 in Seattle Parking")
        } header: {
            Text("Ask Siri").textCase(nil).font(.headline)
        } footer: {
            Text("After finding parking, Siri offers driving directions to the closest spot.")
        }
    }

    // MARK: - Loading

    private func loadHere() async {
        guard isConfigured else { return }
        here = .loading
        do {
            let api = try ParkingAPI.fromSettings()
            let coordinate = try await LocationProvider.current()
            here = .loaded(try await api.here(coordinate))
        } catch {
            here = .failed(errorMessage(error))
        }
    }
}

private struct SiriPhrase: View {
    let text: String

    var body: some View {
        Label {
            Text("\u{201C}\(text)\u{201D}")
        } icon: {
            Image(systemName: "mic.fill").foregroundStyle(.tint)
        }
        .font(.subheadline)
    }
}

/// A value being fetched for the UI.
enum Loadable<Value> {
    case idle
    case loading
    case loaded(Value)
    case failed(String)

    var isLoading: Bool {
        if case .loading = self { return true }
        return false
    }
}

func errorMessage(_ error: Error) -> String {
    if let error = error as? ParkingError { return String(localized: error.localizedStringResource) }
    return error.localizedDescription
}
