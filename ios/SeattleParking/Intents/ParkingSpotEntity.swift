import AppIntents
import Foundation

/// The most recent "find parking" results, so Shortcuts and Siri can refer
/// back to them (for example, "directions to number 2").
final class SpotStore: @unchecked Sendable {
    static let shared = SpotStore()
    private let lock = NSLock()
    private var spots: [ParkingSpotEntity] = []

    func save(_ results: [Spot]) {
        let entities = results.enumerated().map { ParkingSpotEntity(rank: $0.offset + 1, spot: $0.element) }
        lock.withLock { spots = entities }
    }

    func all() -> [ParkingSpotEntity] {
        lock.withLock { spots }
    }
}

struct ParkingSpotEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Parking Spot"
    static let defaultQuery = ParkingSpotQuery()

    /// 1 = closest result from the last search.
    let id: Int
    let street: String
    let summary: String
    let mapsURL: URL?

    init(rank: Int, spot: Spot) {
        id = rank
        street = spot.street
        summary = spot.summary
        mapsURL = URL(string: spot.mapsUrl)
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(id). \(street)", subtitle: "\(summary)")
    }
}

struct ParkingSpotQuery: EntityQuery {
    func entities(for identifiers: [Int]) async throws -> [ParkingSpotEntity] {
        SpotStore.shared.all().filter { identifiers.contains($0.id) }
    }

    func suggestedEntities() async throws -> [ParkingSpotEntity] {
        SpotStore.shared.all()
    }
}

/// "Directions to parking spot 2 in Seattle Parking."
struct DirectionsToSpotIntent: AppIntent {
    static let title: LocalizedStringResource = "Directions to Parking Spot"
    static let description = IntentDescription("Opens walking directions to one of the spots from your last parking search.")

    @Parameter(title: "Spot")
    var spot: ParkingSpotEntity

    func perform() async throws -> some IntentResult & OpensIntent {
        guard let url = spot.mapsURL else { throw ParkingError.server("That spot has no map location.") }
        return .result(opensIntent: OpenURLIntent(url))
    }
}
