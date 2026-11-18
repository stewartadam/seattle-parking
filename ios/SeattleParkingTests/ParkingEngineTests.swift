import XCTest
@testable import SeattleParking

// Mirrors the describeHere / findParking / describeArea tests in
// test/parking.test.js, answered from the recorded Capitol Hill blocks.
final class ParkingEngineTests: XCTestCase {
    /// Tuesday, October 6 2026, 10 AM.
    let tuesdayMorning = seattle(6, 10)

    func engine() throws -> ParkingEngine { ParkingEngine(source: try capitolHill()) }

    func testHereSummarisesTheStreetAndZone() async throws {
        let result = try await engine().here(capitolHillPoint, permitZone: nil, date: tuesdayMorning)
        XCTAssertTrue(result.speech.hasPrefix(
            "You're on 14th Avenue East between East Republican Street and East Mercer Street."), result.speech)
        XCTAssertTrue(result.speech.contains("Restricted Parking Zone 4, Capitol Hill"), result.speech)
        XCTAssertFalse(result.blockfaces.isEmpty)
        XCTAssertEqual(result.rpzZone?.zone, "4")
    }

    func testNearbyReturnsLegalSpotsClosestFirst() async throws {
        let result = try await engine().nearby(capitolHillPoint, limit: 5, permitZone: nil, date: tuesdayMorning)
        XCTAssertFalse(result.results.isEmpty)
        let distances = result.results.map(\.distanceMeters)
        XCTAssertEqual(distances, distances.sorted())
        XCTAssertTrue(result.speech.hasPrefix("The closest spot is"), result.speech)
        XCTAssertTrue(result.results[0].mapsUrl.hasPrefix("https://maps.apple.com/?daddr="))

        // Both sides of 14th Ave E qualify; the street should be spoken once.
        let street = "14th Avenue East between East Republican Street and East Mercer Street"
        XCTAssertEqual(result.speech.components(separatedBy: street).count - 1, 1, result.speech)
        XCTAssertNotNil(result.speech.range(of: #"east side, .*; west side, "#, options: .regularExpression), result.speech)
    }

    func testNearbyRespectsFilters() async throws {
        let e = try engine()
        let long = try await e.nearby(capitolHillPoint, minMinutes: 240, permitZone: nil, date: tuesdayMorning)
        XCTAssertTrue(long.results.allSatisfy { $0.timeLimitMinutes == nil || $0.timeLimitMinutes! >= 240 })
        let free = try await e.nearby(capitolHillPoint, limit: 10, freeOnly: true, permitZone: nil, date: tuesdayMorning)
        XCTAssertTrue(free.results.allSatisfy(\.freeNow))
    }

    func testResultsIncludeCurbLinesInSeattle() async throws {
        let e = try engine()
        let here = try await e.here(capitolHillPoint, permitZone: nil, date: tuesdayMorning)
        let nearby = try await e.nearby(capitolHillPoint, limit: 5, permitZone: nil, date: tuesdayMorning)
        let paths = here.blockfaces.map { $0.path ?? [] } + nearby.results.map { $0.path ?? [] }
        for path in paths {
            XCTAssertGreaterThanOrEqual(path.count, 2)
            for p in path {
                XCTAssertTrue(p.lat > 47.4 && p.lat < 47.8 && p.lon > -122.5 && p.lon < -122.2, "\(p)")
            }
        }
    }

    func testAreaReturnsEveryBlockWithItsState() async throws {
        let e = try engine()
        let area = try await e.area(capitolHillPoint, radiusMeters: 5000, permitZone: nil, date: tuesdayMorning)
        let nearby = try await e.nearby(capitolHillPoint, limit: 10, permitZone: nil, date: tuesdayMorning)
        XCTAssertGreaterThanOrEqual(area.blockfaces.count, nearby.results.count)
        XCTAssertTrue(area.blockfaces.contains { !$0.canParkNow }, "includes blocks where you can't park")
        XCTAssertTrue(area.blockfaces.allSatisfy { $0.path.count >= 2 })
    }

    func testSchedulesUseTheZoneHours() async throws {
        let area = try await engine().area(capitolHillPoint, radiusMeters: 300, permitZone: nil, date: tuesdayMorning)
        let source = try capitolHill()
        let blocks = try await source.blockfaces(near: capitolHillPoint, radiusMeters: 300)
        let hours = await source.rpzHours()
        let schedules = blocks.compactMap { ParkingSchedule.text($0.rules, rpzHours: hours) }
        let rpz = schedules.first { $0.contains("zone 4 permit") }
        XCTAssertNotNil(rpz, "an RPZ block shows its zone hours")
        XCTAssertTrue(rpz?.contains("Mon–Sat 7 AM–6 PM") ?? false, rpz ?? "")
        XCTAssertFalse(area.blockfaces.isEmpty)
    }

    func testOutsideTheDataSaysSo() async throws {
        let farAway = Coordinate(lat: 47.70, lon: -122.40)
        let here = try await engine().here(farAway, permitZone: nil, date: tuesdayMorning)
        XCTAssertTrue(here.blockfaces.isEmpty)
        XCTAssertTrue(here.speech.hasPrefix("I couldn't find any city parking data"), here.speech)
        XCTAssertNil(here.rpzZone)
    }
}
