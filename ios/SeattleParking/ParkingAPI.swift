import CoreLocation
import Foundation

/// Settings shared by the app UI (@AppStorage) and the intents.
enum Settings {
    static let serverURLKey = "serverURL"
    static let apiKeyKey = "apiKey"
    static let permitZoneKey = "permitZone"
}

enum ParkingError: Error, CustomLocalizedStringResourceConvertible {
    case notConfigured
    case locationDenied
    case noLocation
    case server(String)
    case nothingNearby(String)
    /// The server doesn't have this endpoint (an older deployment).
    case notFound

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .notConfigured:
            return "Open Seattle Parking and enter your server and API key first."
        case .locationDenied:
            return "Seattle Parking doesn't have permission to use your location. You can allow it in Settings."
        case .noLocation:
            return "I couldn't get your location. Try again in a moment."
        case .server(let message):
            return "\(message)"
        case .nothingNearby(let speech):
            return "\(speech)"
        case .notFound:
            return "The parking server doesn't support this yet."
        }
    }
}

// MARK: - Response models (see src/parking.js on the server)

struct Coordinate: Decodable, Hashable {
    let lat: Double
    let lon: Double
}

struct Blockface: Decodable, Hashable {
    let street: String
    let side: String?
    let summary: String
    let canParkNow: Bool
    let freeNow: Bool?
    let timeLimitMinutes: Int?
    let distanceMeters: Int?
    /// The curb line for this side of the block (newer servers only).
    let path: [Coordinate]?
}

struct RPZZone: Decodable, Hashable {
    let zone: String?
    let name: String?
    let inEffect: String?
}

struct HereResponse: Decodable {
    let speech: String
    let blockfaces: [Blockface]
    let rpzZone: RPZZone?
}

struct Spot: Decodable, Hashable {
    let street: String
    let side: String?
    let summary: String
    let freeNow: Bool
    let ratePerHour: Double?
    let timeLimitMinutes: Int?
    let distanceMeters: Int
    let direction: String?
    let point: Coordinate
    let mapsUrl: String
    /// The curb line for this side of the block (newer servers only).
    let path: [Coordinate]?
}

struct NearbyResponse: Decodable {
    let speech: String
    let results: [Spot]
}

/// One side of one block, for coloring a map (/api/area).
struct AreaBlockface: Decodable, Hashable {
    let street: String
    let side: String?
    let summary: String
    let canParkNow: Bool
    let freeNow: Bool
    /// nil when there's no limit (or an older server that doesn't say).
    let timeLimitMinutes: Int?
    let path: [Coordinate]
}

struct AreaResponse: Decodable {
    let blockfaces: [AreaBlockface]
}

private struct ErrorResponse: Decodable {
    let error: String?
    let speech: String?
}

// MARK: - Client

struct ParkingAPI {
    let baseURL: URL
    let apiKey: String
    let permitZone: String?

    static func fromSettings(_ defaults: UserDefaults = .standard) throws -> ParkingAPI {
        let urlString = defaults.string(forKey: Settings.serverURLKey)?.trimmingCharacters(in: .whitespaces) ?? ""
        guard
            !urlString.isEmpty,
            let url = URL(string: urlString),
            let key = defaults.string(forKey: Settings.apiKeyKey), !key.isEmpty
        else { throw ParkingError.notConfigured }
        let zone = defaults.string(forKey: Settings.permitZoneKey)?.trimmingCharacters(in: .whitespaces)
        return ParkingAPI(baseURL: url, apiKey: key, permitZone: zone?.isEmpty == false ? zone : nil)
    }

    func here(_ c: CLLocationCoordinate2D) async throws -> HereResponse {
        try await get("api/here", coordinate: c, extra: [])
    }

    func nearby(_ c: CLLocationCoordinate2D, minMinutes: Int? = nil, freeOnly: Bool = false, limit: Int = 3, radiusMeters: Int? = nil) async throws -> NearbyResponse {
        var extra = [URLQueryItem(name: "limit", value: String(limit))]
        if let radiusMeters { extra.append(URLQueryItem(name: "radiusMeters", value: String(radiusMeters))) }
        if let minMinutes { extra.append(URLQueryItem(name: "minMinutes", value: String(minMinutes))) }
        if freeOnly { extra.append(URLQueryItem(name: "freeOnly", value: "true")) }
        return try await get("api/nearby", coordinate: c, extra: extra)
    }

    func area(_ c: CLLocationCoordinate2D, radiusMeters: Int) async throws -> AreaResponse {
        try await get("api/area", coordinate: c, extra: [URLQueryItem(name: "radiusMeters", value: String(radiusMeters))])
    }

    private func get<T: Decodable>(_ path: String, coordinate c: CLLocationCoordinate2D, extra: [URLQueryItem]) async throws -> T {
        var components = URLComponents(url: baseURL.appending(path: path), resolvingAgainstBaseURL: false)!
        var items = [
            URLQueryItem(name: "lat", value: String(c.latitude)),
            URLQueryItem(name: "lon", value: String(c.longitude)),
        ] + extra
        if let permitZone { items.append(URLQueryItem(name: "permitZone", value: permitZone)) }
        components.queryItems = items

        var request = URLRequest(url: components.url!, timeoutInterval: 15)
        request.setValue(apiKey, forHTTPHeaderField: "X-API-Key")
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let body = try? JSONDecoder().decode(ErrorResponse.self, from: data)
            if status == 404 { throw ParkingError.notFound }
            if status == 401 { throw ParkingError.server("The parking server rejected the API key. Check it in the Seattle Parking app.") }
            throw ParkingError.server(body?.speech ?? body?.error ?? "The parking server returned an error (\(status)).")
        }
        return try JSONDecoder().decode(T.self, from: data)
    }
}
