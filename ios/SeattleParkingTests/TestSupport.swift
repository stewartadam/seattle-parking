import Foundation
import XCTest
@testable import SeattleParking

// Helpers shared by the tests: build city data the way the server's tests do
// (plain SDOT attribute dictionaries), pick a moment in Seattle time, and load
// the recorded Capitol Hill responses in test/fixtures (shared with the
// server's tests, so both are checked against the same data).

/// SDOT attributes, written like the server tests' plain objects.
func rules(_ attributes: [String: Any?]) -> BlockfaceRules {
    var a: GISAttributes = [:]
    for (key, value) in attributes {
        switch value {
        case let n as Int: a[key] = .number(Double(n))
        case let n as Double: a[key] = .number(n)
        case let s as String: a[key] = .string(s)
        default: a[key] = .null
        }
    }
    return BlockfaceRules(a)
}

/// A Seattle date and time. October 2026 is daylight time (UTC-7).
func seattle(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
    var c = DateComponents()
    (c.year, c.month, c.day, c.hour, c.minute) = (2026, 10, day, hour, minute)
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = SeattleTime.timeZone
    return calendar.date(from: c)!
}

/// Tuesday, October 6 2026, `minutes` after midnight.
func weekday(_ minutes: Int) -> SeattleTime { SeattleTime(seattle(6, 0).addingTimeInterval(Double(minutes) * 60)) }
/// Saturday, October 10 2026.
func saturday(_ minutes: Int) -> SeattleTime { SeattleTime(seattle(10, 0).addingTimeInterval(Double(minutes) * 60)) }
/// Sunday, October 11 2026.
func sunday(_ minutes: Int) -> SeattleTime { SeattleTime(seattle(11, 0).addingTimeInterval(Double(minutes) * 60)) }

func status(_ b: BlockfaceRules, _ now: SeattleTime, permitZone: String? = nil,
            rpzHours: [String: String] = [:]) -> BlockfaceStatus {
    BlockfaceStatus(b, at: now, permitZone: permitZone, rpzHours: rpzHours)
}

/// The paid Broadway block the server tests use: $1 then $2.50, 8 AM–10 PM weekdays, 2-hour limit.
let paidBroadway: [String: Any?] = [
    "UNITDESC": "BROADWAY E BETWEEN E OLIVE WAY AND E THOMAS ST",
    "SIDE": "W",
    "PARKING_CATEGORY": "Paid Parking",
    "PARKING_TIME_LIMIT": 120,
    "START_TIME_WKD": "08AM",
    "END_TIME_WKD": "10PM",
    "WKD_RATE1": 1, "WKD_START1": 480, "WKD_END1": 659,
    "WKD_RATE2": 2.5, "WKD_START2": 660, "WKD_END2": 1319,
]

func merged(_ base: [String: Any?], _ changes: [String: Any?]) -> [String: Any?] {
    base.merging(changes) { _, new in new }
}

private final class FixtureBundleMarker {}

/// A recorded City of Seattle response from test/fixtures.
func fixture(_ name: String) throws -> Data {
    let parts = name.split(separator: ".").map(String.init)
    if let url = Bundle(for: FixtureBundleMarker.self).url(forResource: parts[0], withExtension: parts[1]) {
        return try Data(contentsOf: url)
    }
    // Not bundled (e.g. compiled outside Xcode): read it from the repository.
    let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    return try Data(contentsOf: repo.appendingPathComponent("test/fixtures/\(name)"))
}

/// The recorded blocks around 14th Ave E & E Republican St (Capitol Hill),
/// inside RPZ zone 4, as the on-phone copy of the city's data.
func capitolHill() throws -> OfflineCity {
    struct Response: Decodable { let features: [GISFeature] }
    let blocks = try JSONDecoder().decode(Response.self, from: fixture("capitol-hill-blockfaces.json")).features
        .map { f in
            CitySnapshot.Block(
                rules: BlockfaceRules(f.attributes),
                paths: (f.geometry?.paths ?? []).map { $0.flatMap { [$0[0], $0[1]] } }
            )
        }
    let zone = try XCTUnwrap(JSONDecoder().decode(Response.self, from: fixture("capitol-hill-rpz.json")).features.first)
    // The fixture has no zone outline; a box around the recorded area stands in.
    let box: [Double] = [-122.33, 47.61, -122.30, 47.61, -122.30, 47.64, -122.33, 47.64, -122.33, 47.61]
    return OfflineCity(CitySnapshot(
        downloadedAt: seattle(6, 9),
        blocks: blocks,
        zones: [.init(info: RPZZone(zone.attributes), hours: zone.attributes.text("INEFFECT"), rings: [box])]
    ))
}

let capitolHillPoint = Coordinate(lat: 47.6239, lon: -122.3145)
