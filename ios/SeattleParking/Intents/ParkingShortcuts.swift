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
                // "Find parking for two hours", "Find overnight parking",
                // "Find parking until morning": the stay comes from StayLength's list.
                "Find parking for \(\.$stay) with \(.applicationName)",
                "Find \(\.$stay) parking with \(.applicationName)",
                "Find parking \(\.$stay) with \(.applicationName)",
                "Where can I park for \(\.$stay) with \(.applicationName)",
                "Where can I park \(\.$stay) with \(.applicationName)",
            ],
            shortTitle: "Find Parking",
            systemImageName: "car.circle"
        )
        AppShortcut(
            intent: FindParkingUntilIntent(),
            phrases: [
                "Find parking until a certain time with \(.applicationName)",
                "Find parking until a set time with \(.applicationName)",
                "Find parking until later with \(.applicationName)",
            ],
            shortTitle: "Find Parking Until…",
            systemImageName: "clock"
        )
    }
}
