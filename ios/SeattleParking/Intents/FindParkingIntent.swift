import AppIntents
import SwiftUI

/// "Hey Siri, find parking with Seattle Parking."
///
/// Reads out the closest legal spots, then asks whether to start driving
/// directions to the closest one. That confirmation is the follow-up turn.
struct FindParkingIntent: AppIntent {
    static let title: LocalizedStringResource = "Find Parking"
    static let description = IntentDescription(
        "Finds the closest Seattle street parking you can legally use right now, then offers driving directions."
    )
    static let openAppWhenRun = false

    @Parameter(title: "Minutes needed", description: "Only include places where you can stay at least this many minutes.")
    var minutes: Int?

    @Parameter(title: "Free only", description: "Only include places that are free right now.", default: false)
    var freeOnly: Bool

    static var parameterSummary: some ParameterSummary {
        Summary("Find parking for \(\.$minutes) minutes") {
            \.$freeOnly
        }
    }

    func perform() async throws -> some IntentResult & OpensIntent {
        let api = try ParkingAPI.fromSettings()
        let coordinate = try await LocationProvider.current()
        let answer = try await api.nearby(coordinate, minMinutes: minutes, freeOnly: freeOnly)

        guard let closest = answer.results.first else {
            throw ParkingError.nothingNearby(answer.speech)
        }
        SpotStore.shared.save(answer.results)

        try await requestConfirmation(
            actionName: .go,
            dialog: IntentDialog("\(answer.speech) Want driving directions to the closest one?")
        ) {
            SpotsSnippet(spots: answer.results, minutes: minutes)
        }
        return .result(opensIntent: OpenURLIntent(closest.drivingDirectionsURL))
    }
}

struct SpotsSnippet: View {
    let spots: [Spot]
    var minutes: Int? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(spots.enumerated()), id: \.offset) { index, spot in
                HStack(alignment: .top, spacing: 10) {
                    Text("\(index + 1)")
                        .font(.headline)
                        .frame(width: 24, height: 24)
                        .background(Circle().fill(Color(spot.kind(filters: CurbFilters(stayingMinutes: minutes)).color).opacity(0.3)))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(spot.street).font(.subheadline.bold()).lineLimit(2)
                        Text(spot.summary).font(.subheadline)
                        Text(spot.distanceLabel).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding()
    }
}
