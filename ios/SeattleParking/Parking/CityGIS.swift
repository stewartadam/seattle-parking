import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// Client for the City of Seattle's public ArcGIS Online feature services (the
// same data behind SDOT's parking map). No API key is needed. Mirrors
// src/arcgis.js on the server.

enum CityGIS {
    static let base = "https://services.arcgis.com/ZOyb2t4B0UYuYNYH/arcgis/rest/services"
    /// SDOT blockface parking categories: one line per side of each block.
    static let parkingCategories = URL(string: "\(base)/Parking_Categories/FeatureServer/0/query")!
    /// Restricted Parking Zone (RPZ) boundaries, with zone name and hours in effect.
    static let rpzZones = URL(string: "\(base)/Restricted_Parking_Zone_Areas/FeatureServer/4/query")!
}

/// Why a city map lookup failed, in words fit to show or speak.
enum CityGISError: LocalizedError {
    case offline
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .offline:
            return "I couldn't reach the City of Seattle's parking map. Check your connection and try again."
        case .failed(let detail):
            return "The City of Seattle's parking map didn't answer (\(detail)). Try again in a moment."
        }
    }
}

/// An attribute value from a feature: ArcGIS sends numbers, strings and nulls.
enum GISValue: Decodable, Hashable, Sendable {
    case number(Double)
    case string(String)
    case bool(Bool)
    case null

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else { self = .string(try c.decode(String.self)) }
    }
}

typealias GISAttributes = [String: GISValue]

extension Dictionary where Key == String, Value == GISValue {
    /// The value as text (whole numbers without ".0"), or nil if null or empty.
    func text(_ key: String) -> String? {
        switch self[key] {
        case .string(let s): return s.isEmpty ? nil : s
        case .number(let n): return n == n.rounded() && abs(n) < 1e15 ? String(Int(n)) : String(n)
        case .bool(let b): return String(b)
        default: return nil
        }
    }

    func number(_ key: String) -> Double? {
        if case .number(let n) = self[key] { return n }
        return nil
    }

    /// A whole-number value, treating 0 and null as "none" (like JS `x || null`).
    func positiveInt(_ key: String) -> Int? {
        guard let n = number(key), n != 0 else { return nil }
        return Int(n)
    }
}

struct GISFeature: Decodable, Sendable {
    struct Geometry: Decodable, Sendable {
        /// Polylines: [[ [lon, lat], ... ], ...]
        let paths: [[[Double]]]?
        /// Polygons, same shape.
        let rings: [[[Double]]]?
    }

    let attributes: GISAttributes
    let geometry: Geometry?
}

private struct GISResponse: Decodable {
    struct Failure: Decodable { let message: String? }
    let features: [GISFeature]?
    let error: Failure?
}

struct CityGISClient: Sendable {
    var session: URLSession = .shared

    /// Features within `radiusMeters` of a point (or containing it when 0).
    func queryNear(_ layer: URL, lat: Double, lon: Double, radiusMeters: Double,
                   outFields: [String], returnGeometry: Bool = true) async throws -> [GISFeature] {
        var params = [
            ("geometry", "\(lon),\(lat)"),
            ("geometryType", "esriGeometryPoint"),
            ("inSR", "4326"),
            ("outSR", "4326"),
            ("spatialRel", "esriSpatialRelIntersects"),
            ("outFields", outFields.joined(separator: ",")),
            ("returnGeometry", String(returnGeometry)),
            ("f", "json"),
        ]
        if radiusMeters > 0 {
            params.append(("distance", String(radiusMeters)))
            params.append(("units", "esriSRUnit_Meter"))
        }
        return try await query(layer, params)
    }

    /// Attribute-only query for every feature matching a SQL `where` clause.
    func queryWhere(_ layer: URL, where clause: String = "1=1", outFields: [String]) async throws -> [GISFeature] {
        try await query(layer, [
            ("where", clause),
            ("outFields", outFields.joined(separator: ",")),
            ("returnGeometry", "false"),
            ("f", "json"),
        ])
    }

    /// How many features the layer has.
    func count(_ layer: URL) async throws -> Int {
        var request = request(layer, [("where", "1=1"), ("returnCountOnly", "true"), ("f", "json")])
        request.timeoutInterval = 30
        let data = try await send(request)
        struct Count: Decodable { let count: Int? }
        guard let n = (try? JSONDecoder().decode(Count.self, from: data))?.count else {
            throw CityGISError.failed("no count")
        }
        return n
    }

    /// One page of every feature, with geometry, in a stable order.
    func queryPage(_ layer: URL, offset: Int, count: Int, outFields: [String]) async throws -> [GISFeature] {
        var request = request(layer, [
            ("where", "1=1"),
            ("outFields", outFields.joined(separator: ",")),
            ("outSR", "4326"),
            ("returnGeometry", "true"),
            ("geometryPrecision", "6"),
            ("orderByFields", "OBJECTID"),
            ("resultOffset", String(offset)),
            ("resultRecordCount", String(count)),
            ("f", "json"),
        ])
        request.timeoutInterval = 60
        return try decode(try await send(request))
    }

    private func query(_ layer: URL, _ params: [(String, String)]) async throws -> [GISFeature] {
        try decode(try await send(request(layer, params)))
    }

    private func request(_ layer: URL, _ params: [(String, String)]) -> URLRequest {
        var request = URLRequest(url: layer, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = params.map { "\(Self.encode($0.0))=\(Self.encode($0.1))" }
            .joined(separator: "&").data(using: .utf8)
        return request
    }

    private func send(_ request: URLRequest) async throws -> Data {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError where error.code != .cancelled {
            throw CityGISError.offline
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw CityGISError.failed("HTTP \(status)") }
        return data
    }

    private func decode(_ data: Data) throws -> [GISFeature] {
        let body: GISResponse
        do {
            body = try JSONDecoder().decode(GISResponse.self, from: data)
        } catch {
            throw CityGISError.failed("unreadable answer")
        }
        if let error = body.error { throw CityGISError.failed(error.message ?? "error") }
        return body.features ?? []
    }

    private static let formAllowed: CharacterSet = {
        var set = CharacterSet.alphanumerics
        set.insert(charactersIn: "-._~")
        return set
    }()

    private static func encode(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: formAllowed) ?? s
    }
}
