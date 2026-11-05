import AppIntents
import SwiftUI

/// "Hey Siri, parking rules here in Seattle Parking."
struct ParkingHereIntent: AppIntent {
    static let title: LocalizedStringResource = "Parking Rules Here"
    static let description = IntentDescription(
        "Tells you the street parking rules where you are right now: cost, time limit, permit zone and rush-hour restrictions."
    )
    static let openAppWhenRun = false

    func perform() async throws -> some IntentResult & ProvidesDialog & ShowsSnippetView {
        let api = try ParkingAPI.fromSettings()
        let coordinate = try await LocationProvider.current()
        let answer = try await api.here(coordinate)
        return .result(dialog: IntentDialog("\(answer.speech)"), view: HereSnippet(answer: answer))
    }
}

struct HereSnippet: View {
    let answer: HereResponse

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let street = answer.blockfaces.first?.street {
                Text(street).font(.headline)
            }
            ForEach(answer.blockfaces, id: \.self) { b in
                HStack(alignment: .top) {
                    Image(systemName: b.canParkNow ? "checkmark.circle.fill" : "xmark.octagon.fill")
                        .foregroundStyle(b.canParkNow ? .green : .red)
                    VStack(alignment: .leading) {
                        Text(b.side.map { "\($0.capitalized) side" } ?? "This side").font(.subheadline.bold())
                        Text(b.summary).font(.subheadline)
                    }
                }
            }
            if let zone = answer.rpzZone?.zone {
                Text("RPZ \(zone)\(answer.rpzZone?.inEffect.map { " · \($0)" } ?? "")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
    }
}
