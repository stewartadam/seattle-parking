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
    let distanceMeters: Int?
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
}

struct NearbyResponse: Decodable {
    let speech: String
    let results: [Spot]
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

    func nearby(_ c: CLLocationCoordinate2D, minMinutes: Int? = nil, freeOnly: Bool = false, limit: Int = 3) async throws -> NearbyResponse {
        var extra = [URLQueryItem(name: "limit", value: String(limit))]
        if let minMinutes { extra.append(URLQueryItem(name: "minMinutes", value: String(minMinutes))) }
        if freeOnly { extra.append(URLQueryItem(name: "freeOnly", value: "true")) }
        return try await get("api/nearby", coordinate: c, extra: extra)
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
            if status == 401 { throw ParkingError.server("The parking server rejected the API key. Check it in the Seattle Parking app.") }
            throw ParkingError.server(body?.speech ?? body?.error ?? "The parking server returned an error (\(status)).")
        }
        return try JSONDecoder().decode(T.self, from: data)
    }
}
