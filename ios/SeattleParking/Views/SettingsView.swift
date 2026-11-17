import SwiftUI
import UIKit

struct SettingsView: View {
    @AppStorage(Settings.permitZoneKey) private var permitZone = ""

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var cityData: CityData.State = .none

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Zone number", text: $permitZone)
                        .keyboardType(.numberPad)
                } header: {
                    Text("Residential parking permit")
                } footer: {
                    Text("If you have an RPZ permit, enter its zone so blocks in that zone count as places you can park.")
                }

                Section {
                    HStack {
                        Text("Parking data")
                        Spacer()
                        cityDataStatus.foregroundStyle(.secondary)
                    }
                    Button("Update Now") {
                        Task {
                            await CityData.shared.refresh()
                            await watchCityData()
                        }
                    }
                    .disabled(isDownloading)
                } header: {
                    Text("City of Seattle data")
                } footer: {
                    Text("Seattle Parking keeps a copy of the city's street parking rules on your phone, so it works without a connection, and updates it every week. Parking data from the City of Seattle, Seattle Department of Transportation. The city doesn't guarantee it's accurate, so always check the posted signs.")
                }

                Section {
                    Button("Open Location Settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                    }
                } header: {
                    Text("Location")
                } footer: {
                    Text("Seattle Parking uses your location to look up the street you're on. Your location stays on your phone. If Siri says it can't get your location, set Location to Always.")
                }

                Section {
                    Link(destination: Self.sourceURL) {
                        Label("Source code on GitHub", systemImage: "arrow.up.right.square")
                    }
                } header: {
                    Text("About")
                }

                Section {} footer: {
                    Text("Seattle Parking is not affiliated with or endorsed by the City of Seattle. It uses the city's public parking data, which can be incomplete; always check the posted signs.")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task { await watchCityData() }
        }
    }

    private static let sourceURL = URL(string: "https://github.com/stewartadam/seattle-parking")!

    private var isDownloading: Bool {
        if case .downloading = cityData { return true }
        return false
    }

    @ViewBuilder private var cityDataStatus: some View {
        switch cityData {
        case .none:
            Text("Not downloaded yet")
        case .downloading(let fraction):
            HStack(spacing: 8) {
                ProgressView(value: fraction).frame(width: 60)
                Text("Downloading")
            }
        case .ready(let date):
            Text("Updated \(date.formatted(.relative(presentation: .named)))")
        case .failed(_, let lastUpdate):
            if let lastUpdate {
                Text("Update failed, using \(lastUpdate.formatted(date: .abbreviated, time: .omitted))")
            } else {
                Text("Download failed, try again")
            }
        }
    }

    /// Follows the download while it runs.
    private func watchCityData() async {
        cityData = await CityData.shared.currentState()
        while isDownloading, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(300))
            cityData = await CityData.shared.currentState()
        }
    }
}
