import CoreLocation
import Foundation

/// Settings shared by the app UI (@AppStorage) and the intents.
enum Settings {
    static let permitZoneKey = "permitZone"
    /// Left over from versions that needed a parking server; cleared at launch.
    static let retiredKeys = ["serverURL", "apiKey"]
}

enum ParkingError: Error, CustomLocalizedStringResourceConvertible {
    case locationDenied
    case noLocation
    case server(String)
    case nothingNearby(String)

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .locationDenied:
            return "Seattle Parking doesn't have permission to use your location. You can allow it in Settings."
        case .noLocation:
            return "I couldn't get your location. Try again in a moment."
        case .server(let message):
            return "\(message)"
        case .nothingNearby(let speech):
            return "\(speech)"
        }
    }
}

/// Answers parking questions on the phone, from the downloaded copy of the
/// city's data (or the city's live map service until that copy arrives).
struct ParkingAPI {
    let permitZone: String?

    static func fromSettings(_ defaults: UserDefaults = .standard) throws -> ParkingAPI {
        let zone = defaults.string(forKey: Settings.permitZoneKey)?.trimmingCharacters(in: .whitespaces)
        return ParkingAPI(permitZone: zone?.isEmpty == false ? zone : nil)
    }

    func here(_ c: CLLocationCoordinate2D) async throws -> HereResponse {
        try await run { try await $0.here(Coordinate(c), permitZone: permitZone) }
    }

    func nearby(_ c: CLLocationCoordinate2D, minMinutes: Int? = nil, freeOnly: Bool = false, limit: Int = 3, radiusMeters: Int? = nil) async throws -> NearbyResponse {
        try await run {
            try await $0.nearby(Coordinate(c), radiusMeters: radiusMeters.map { Double($0) } ?? ParkingEngine.defaultSearchRadius,
                                limit: limit, minMinutes: minMinutes, freeOnly: freeOnly, permitZone: permitZone)
        }
    }

    func area(_ c: CLLocationCoordinate2D, radiusMeters: Int) async throws -> AreaResponse {
        try await run { try await $0.area(Coordinate(c), radiusMeters: Double(radiusMeters), permitZone: permitZone) }
    }

    private func run<T>(_ ask: (ParkingEngine) async throws -> T) async throws -> T {
        let engine = ParkingEngine(source: await CityData.shared.source())
        do {
            return try await ask(engine)
        } catch let error as CityGISError {
            // Siri reads ParkingError messages; other errors become a generic failure.
            throw ParkingError.server(error.localizedDescription)
        }
    }
}

extension Coordinate {
    init(_ c: CLLocationCoordinate2D) { self.init(lat: c.latitude, lon: c.longitude) }
}
