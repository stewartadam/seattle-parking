import AppIntents
import SwiftUI

/// "Hey Siri, find parking with Seattle Parking."
///
/// Reads out the closest legal spots, then asks whether to start walking
/// directions to the closest one. That confirmation is the follow-up turn.
struct FindParkingIntent: AppIntent {
    static let title: LocalizedStringResource = "Find Parking"
    static let description = IntentDescription(
        "Finds the closest Seattle street parking you can legally use right now, then offers walking directions."
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

        guard let closest = answer.results.first, let mapsURL = URL(string: closest.mapsUrl) else {
            throw ParkingError.nothingNearby(answer.speech)
        }
        SpotStore.shared.save(answer.results)

        try await requestConfirmation(
            result: .result(
                dialog: IntentDialog("\(answer.speech) Want walking directions to the closest one?"),
                view: SpotsSnippet(spots: answer.results)
            ),
            confirmationActionName: .go
        )
        return .result(opensIntent: OpenURLIntent(mapsURL))
    }
}

struct SpotsSnippet: View {
    let spots: [Spot]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(spots.enumerated()), id: \.offset) { index, spot in
                HStack(alignment: .top, spacing: 10) {
                    Text("\(index + 1)")
                        .font(.headline)
                        .frame(width: 24, height: 24)
                        .background(Circle().fill(spot.freeNow ? Color.green.opacity(0.25) : Color.orange.opacity(0.25)))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(spot.street).font(.subheadline.bold()).lineLimit(2)
                        Text(spot.summary).font(.subheadline)
                        Text(distanceLabel(spot)).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding()
    }

    private func distanceLabel(_ spot: Spot) -> String {
        let feet = Measurement(value: Double(spot.distanceMeters), unit: UnitLength.meters).converted(to: .feet).value
        let distance = feet < 1000 ? "\(Int((feet / 50).rounded() * 50)) ft" : String(format: "%.1f mi", feet / 5280)
        let side = spot.side.map { ", \($0) side" } ?? ""
        return [distance, spot.direction].compactMap { $0 }.joined(separator: " ") + side
    }
}
