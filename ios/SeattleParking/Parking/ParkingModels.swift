import Foundation

// The answers the app shows and Siri reads. They match the JSON the
// self-hosted server returns (src/parking.js), so the server's /api/here and
// /api/nearby and this app say the same thing.

struct Coordinate: Codable, Hashable, Sendable {
    let lat: Double
    let lon: Double
}

struct Blockface: Codable, Hashable, Sendable {
    let street: String
    /// Short display form, e.g. "E. Lynn St between Yale Ave E and Eastlake Ave E".
    let streetLabel: String?
    let side: String?
    let summary: String
    /// When the rules apply all week, e.g. "2-hour limit, paid Mon–Sat 8 AM–8 PM; free Sun".
    let schedule: String?
    let canParkNow: Bool
    let freeNow: Bool?
    let timeLimitMinutes: Int?
    /// A posted limit in effect now / minutes until a restriction starts (while free now).
    let postedLimitMinutes: Int?
    let restrictionInMinutes: Int?
    let distanceMeters: Int?
    /// The curb line for this side of the block.
    let path: [Coordinate]?
}

struct RPZZone: Codable, Hashable, Sendable {
    let zone: String?
    let name: String?
    let inEffect: String?
}

struct HereResponse: Codable, Sendable {
    let speech: String
    let blockfaces: [Blockface]
    let rpzZone: RPZZone?
}

struct Spot: Codable, Hashable, Sendable {
    let street: String
    /// Short display form, e.g. "E. Lynn St between Yale Ave E and Eastlake Ave E".
    let streetLabel: String?
    let side: String?
    let summary: String
    /// When the rules apply all week, e.g. "2-hour limit, paid Mon–Sat 8 AM–8 PM; free Sun".
    let schedule: String?
    let freeNow: Bool
    let ratePerHour: Double?
    let timeLimitMinutes: Int?
    /// A posted limit in effect now / minutes until a restriction starts (while free now).
    let postedLimitMinutes: Int?
    let restrictionInMinutes: Int?
    let distanceMeters: Int
    let direction: String?
    let point: Coordinate
    let mapsUrl: String
    /// The curb line for this side of the block.
    let path: [Coordinate]?
}

struct NearbyResponse: Codable, Sendable {
    let speech: String
    let results: [Spot]
}

/// One side of one block, for coloring a map.
struct AreaBlockface: Codable, Hashable, Sendable {
    let street: String
    /// Short display form, e.g. "E. Lynn St between Yale Ave E and Eastlake Ave E".
    let streetLabel: String?
    let side: String?
    let summary: String
    /// When the rules apply all week, e.g. "2-hour limit, paid Mon–Sat 8 AM–8 PM; free Sun".
    var schedule: String? = nil
    let canParkNow: Bool
    let freeNow: Bool
    /// nil when there's no limit.
    let timeLimitMinutes: Int?
    /// A posted limit in effect now / minutes until a restriction starts (while free now).
    let postedLimitMinutes: Int?
    let restrictionInMinutes: Int?
    let path: [Coordinate]
}

struct AreaResponse: Codable, Sendable {
    let blockfaces: [AreaBlockface]
}

extension Blockface { var displayStreet: String { streetLabel ?? street } }
extension Spot { var displayStreet: String { streetLabel ?? street } }
