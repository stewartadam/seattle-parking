import AppIntents
import SwiftUI

/// "Hey Siri, find parking with Seattle Parking."
/// "Hey Siri, find overnight parking with Seattle Parking."
///
/// Says only the closest legal spot (the card lists a few more), then asks
/// whether to start driving directions to it. That confirmation is the
/// follow-up turn.
struct FindParkingIntent: AppIntent {
    static let title: LocalizedStringResource = "Find Parking"
    static let description = IntentDescription(
        "Finds the closest Seattle street parking you can legally use right now, then offers driving directions."
    )
    static let openAppWhenRun = false

    @Parameter(title: "Staying for", description: "Only include places where you can stay this long.")
    var stay: StayLength?

    @Parameter(title: "Free only", description: "Only include places that are free right now.", default: false)
    var freeOnly: Bool

    static var parameterSummary: some ParameterSummary {
        Summary("Find parking for \(\.$stay)") {
            \.$freeOnly
        }
    }

    func perform() async throws -> some IntentResult & OpensIntent {
        let now = Date()
        let url = try await findParkingAndConfirm(until: stay?.end(from: now), stayText: stay?.spoken, freeOnly: freeOnly, now: now)
        return .result(opensIntent: OpenURLIntent(url))
    }
}

/// "Hey Siri, find parking until a certain time with Seattle Parking."
/// Siri asks "Until when?" and understands answers like "9 AM tomorrow".
struct FindParkingUntilIntent: AppIntent {
    static let title: LocalizedStringResource = "Find Parking Until a Time"
    static let description = IntentDescription(
        "Finds the closest Seattle street parking where you can stay until the time you choose, then offers driving directions."
    )
    static let openAppWhenRun = false

    @Parameter(title: "Until", requestValueDialog: IntentDialog("Until when?"))
    var until: Date

    @Parameter(title: "Free only", description: "Only include places that are free right now.", default: false)
    var freeOnly: Bool

    static var parameterSummary: some ParameterSummary {
        Summary("Find parking until \(\.$until)") {
            \.$freeOnly
        }
    }

    func perform() async throws -> some IntentResult & OpensIntent {
        let now = Date()
        // "9 AM" said in the evening means tomorrow morning.
        var end = until
        if end <= now, let next = Calendar.current.date(byAdding: .day, value: 1, to: end), next > now { end = next }
        guard end > now else { throw ParkingError.server("That time has already passed.") }
        let url = try await findParkingAndConfirm(until: end, stayText: spokenUntil(end, from: now), freeOnly: freeOnly, now: now)
        return .result(opensIntent: OpenURLIntent(url))
    }
}

extension AppIntent {
    /// Searches around you, says the closest spot, and asks to start
    /// directions. Returns the directions link once you say yes.
    func findParkingAndConfirm(until end: Date?, stayText: String?, freeOnly: Bool, now: Date) async throws -> URL {
        let api = try ParkingAPI.fromSettings()
        let coordinate = try await LocationProvider.current()
        let answer = try await api.nearby(coordinate, until: end, freeOnly: freeOnly)

        guard let closest = answer.results.first, let url = closest.drivingDirectionsURL else {
            throw ParkingError.nothingNearby(answer.speech)
        }
        let speech = ParkingText.briefSpeech(closest: closest, stay: stayText)
        let minutes = end.map { max(1, Int($0.timeIntervalSince(now) / 60)) }
        try await requestConfirmation(
            actionName: .go,
            dialog: IntentDialog("\(speech) Want directions?")
        ) {
            SpotsSnippet(spots: answer.results, minutes: minutes)
        }
        return url
    }
}

struct SpotsSnippet: View {
    let spots: [Spot]
    var minutes: Int? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(spots.enumerated()), id: \.offset) { _, spot in
                HStack(alignment: .top, spacing: 10) {
                    Circle()
                        .fill(Color(spot.kind(filters: CurbFilters(stayingMinutes: minutes)).color))
                        .frame(width: 12, height: 12)
                        .padding(.top, 5)
                    StreetDescription(label: spot.displayStreet, side: spot.side, distanceMeters: spot.distanceMeters,
                                      summary: spot.summary, schedule: spot.schedule)
                }
            }
        }
        .padding()
    }
}
