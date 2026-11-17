import SwiftUI

@main
struct SeattleParkingApp: App {
    init() {
        // Earlier versions needed a parking server and API key; forget them.
        for key in Settings.retiredKeys { UserDefaults.standard.removeObject(forKey: key) }
    }

    var body: some Scene {
        WindowGroup { HomeView() }
    }
}
