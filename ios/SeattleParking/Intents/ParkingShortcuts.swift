import AppIntents

/// Phrases Siri recognizes with no setup in the Shortcuts app.
/// Every phrase has to include the app name.
struct ParkingShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: ParkingHereIntent(),
            phrases: [
                "Parking rules here in \(.applicationName)",
                "Can I park here with \(.applicationName)",
                "Check parking with \(.applicationName)",
            ],
            shortTitle: "Parking Here",
            systemImageName: "parkingsign.circle"
        )
        AppShortcut(
            intent: FindParkingIntent(),
            phrases: [
                "Find parking with \(.applicationName)",
                "Where can I park with \(.applicationName)",
                "Find a spot with \(.applicationName)",
            ],
            shortTitle: "Find Parking",
            systemImageName: "car.circle"
        )
        AppShortcut(
            intent: DirectionsToSpotIntent(),
            phrases: [
                "Directions to \(\.$spot) in \(.applicationName)",
            ],
            shortTitle: "Directions to Spot",
            systemImageName: "figure.walk.circle"
        )
    }
}
