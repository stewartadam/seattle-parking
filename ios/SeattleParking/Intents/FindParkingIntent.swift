import AppIntents
import CoreLocation
import SwiftUI

/// "Hey Siri, find parking with Seattle Parking."
/// "Hey Siri, find overnight parking with Seattle Parking."
///
/// Says only the closest legal spot. If it's somewhere else, Siri shows a
/// card with a few more and asks whether to start driving directions (that
/// confirmation is the follow-up turn); if you can park right where you
/// are, Siri just says so.
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

    func perform() async throws -> some IntentResult & ProvidesDialog & OpensIntent {
        let now = Date()
        return try await answerParking(near: nil, until: stay?.end(from: now), stayText: stay?.spoken, freeOnly: freeOnly, now: now)
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

    func perform() async throws -> some IntentResult & ProvidesDialog & OpensIntent {
        let now = Date()
        // "9 AM" said in the evening means tomorrow morning.
        var end = until
        if end <= now, let next = Calendar.current.date(byAdding: .day, value: 1, to: end), next > now { end = next }
        guard end > now else { throw ParkingError.server("That time has already passed.") }
        return try await answerParking(near: nil, until: end, stayText: spokenUntil(end, from: now), freeOnly: freeOnly, now: now)
    }
}

/// "Hey Siri, find parking near a place with Seattle Parking."
/// Siri asks "Near where?"; the answer ("Lighthouse Coffee Roasters") is
/// looked up with Apple Maps, limited to Seattle, like the app's search box.
struct FindParkingNearIntent: AppIntent {
    static let title: LocalizedStringResource = "Find Parking Near a Place"
    static let description = IntentDescription(
        "Finds the closest Seattle street parking near a place or address you name, then offers driving directions."
    )
    static let openAppWhenRun = false

    @Parameter(title: "Place", requestValueDialog: IntentDialog("Near where?"))
    var place: String

    @Parameter(title: "Staying for", description: "Only include places where you can stay this long.")
    var stay: StayLength?

    @Parameter(title: "Free only", description: "Only include places that are free right now.", default: false)
    var freeOnly: Bool

    static var parameterSummary: some ParameterSummary {
        Summary("Find parking near \(\.$place) for \(\.$stay)") {
            \.$freeOnly
        }
    }

    func perform() async throws -> some IntentResult & ProvidesDialog & OpensIntent {
        let now = Date()
        let found: SearchedPlace
        do {
            found = try await AddressSearch().place(matching: place)
        } catch let error as AddressSearchError {
            throw ParkingError.server(error.errorDescription ?? "Couldn't find that place in Seattle.")
        }
        return try await answerParking(near: found, until: stay?.end(from: now), stayText: stay?.spoken, freeOnly: freeOnly, now: now)
    }
}

extension AppIntent {
    /// Searches around you (or around `place`) and says the closest spot.
    /// When it's somewhere else, asks to start directions and opens them on
    /// a yes. Both answers share one result type (iOS 18.2+), so one intent
    /// can end either way.
    func answerParking(near place: SearchedPlace?, until end: Date?, stayText: String?, freeOnly: Bool,
                       now: Date) async throws -> IntentResultContainer<Never, Never, Never, IntentDialog> {
        let api = try ParkingAPI.fromSettings()
        let origin: CLLocationCoordinate2D
        if let place {
            origin = place.coordinate
        } else {
            origin = try await LocationProvider.current()
        }
        let answer = try await api.nearby(origin, until: end, freeOnly: freeOnly)

        guard let closest = answer.results.first else {
            throw ParkingError.nothingNearby(answer.speech)
        }
        let speech = ParkingText.briefSpeech(closest: closest, stay: stayText, near: place?.name)
        // Already there: nothing to drive to.
        if place == nil, closest.direction == nil {
            return .result(dialog: IntentDialog("\(speech)"))
        }
        let minutes = end.map { max(1, Int($0.timeIntervalSince(now) / 60)) }
        try await requestConfirmation(
            actionName: .go,
            dialog: IntentDialog("\(speech) Want directions?")
        ) {
            SpotsSnippet(spots: answer.results, minutes: minutes)
        }
        return .result(opensIntent: OpenURLIntent(closest.drivingDirectionsURL), dialog: IntentDialog("Starting directions."))
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
