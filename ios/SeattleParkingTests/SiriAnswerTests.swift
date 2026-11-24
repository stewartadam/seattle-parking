import XCTest
@testable import SeattleParking

/// Siri's spoken answers (short, for someone driving) and how long a stay
/// a block allows, including stays past midnight.
final class SiriAnswerTests: XCTestCase {
    let morningRush = rules(merged(paidBroadway, ["PEAK_HOUR": "7-9AM"]))
    let unrestricted = rules([
        "UNITDESC": "NW 64TH ST BETWEEN 15TH AVE NW AND 17TH AVE NW", "SIDE": "S",
        "PARKING_CATEGORY": "Unrestricted Parking",
    ])

    func fits(_ b: BlockfaceRules, from: Date, until: Date) -> Bool {
        ParkingEngine.fitsStay(b, from: from, until: until, permitZone: nil, rpzHours: [:])
    }

    func testOvernightLeavesOutBlocksThatBecomeTowAwayZonesInTheMorning() {
        // Monday 10 PM until Tuesday 8 AM: towed at 7 AM.
        XCTAssertFalse(fits(morningRush, from: seattle(5, 22), until: seattle(6, 8)))
        // Friday night into Saturday: rush hour is weekdays only.
        XCTAssertTrue(fits(morningRush, from: seattle(9, 22), until: seattle(10, 8)))
        // The same block without rush hour: free from 10 PM until paid parking at 8 AM.
        XCTAssertTrue(fits(rules(paidBroadway), from: seattle(5, 23), until: seattle(6, 8)))
        XCTAssertTrue(fits(unrestricted, from: seattle(5, 22), until: seattle(8, 8)))
    }

    func testShortStaysMatchTheTimeLimit() {
        // Tuesday noon, paid with a 2-hour limit.
        XCTAssertTrue(fits(rules(paidBroadway), from: seattle(6, 12), until: seattle(6, 14)))
        XCTAssertFalse(fits(rules(paidBroadway), from: seattle(6, 12), until: seattle(6, 15)))
        // Monday 6 AM for 2 hours runs into the 7 AM tow-away.
        XCTAssertFalse(fits(morningRush, from: seattle(5, 6), until: seattle(5, 8)))
    }

    func testOvernightMeansUntilEightTomorrowMorning() {
        XCTAssertEqual(StayLength.overnight.end(from: seattle(6, 22)), seattle(7, 8))
        XCTAssertEqual(StayLength.overnight.end(from: seattle(6, 18, 30)), seattle(7, 8))
        // After midnight, "overnight" means until this morning.
        XCTAssertEqual(StayLength.overnight.end(from: seattle(7, 2)), seattle(7, 8))
        XCTAssertEqual(StayLength.twoHours.end(from: seattle(6, 22)), seattle(7, 0))
    }

    func testSpokenUntil() {
        XCTAssertEqual(spokenUntil(seattle(6, 18), from: seattle(6, 12)), "until 6 PM")
        XCTAssertEqual(spokenUntil(seattle(7, 9), from: seattle(6, 22)), "until 9 AM tomorrow")
        XCTAssertEqual(spokenUntil(seattle(9, 9, 30), from: seattle(6, 22)), "until 9:30 AM Friday")
    }

    func spot(direction: String?, meters: Int) -> Spot {
        Spot(street: "Northwest 64th Street between 15th Avenue Northwest and 17th Avenue Northwest",
             streetLabel: "NW 64th St between 15th Ave NW and 17th Ave NW", side: "south",
             summary: "free, no posted time limit", schedule: nil, freeNow: true, ratePerHour: nil,
             timeLimitMinutes: nil, postedLimitMinutes: nil, restrictionInMinutes: nil,
             distanceMeters: meters, direction: direction, point: Coordinate(lat: 47.675, lon: -122.376),
             mapsUrl: "https://maps.apple.com/?daddr=47.675,-122.376&dirflg=d", path: nil)
    }

    func testBriefSpeechSkipsCrossStreets() {
        XCTAssertEqual(ParkingText.briefSpeech(closest: spot(direction: nil, meters: 10)),
                       "You can park right here, on Northwest 64th Street: free, no posted time limit.")
        XCTAssertEqual(ParkingText.briefSpeech(closest: spot(direction: "south", meters: 60), stay: "overnight"),
                       "The closest spot overnight is about 200 feet south, on Northwest 64th Street: free, no posted time limit.")
        XCTAssertEqual(ParkingText.briefSpeech(closest: spot(direction: nil, meters: 10), stay: "for 2 hours"),
                       "You can park right here for 2 hours, on Northwest 64th Street: free, no posted time limit.")
        XCTAssertEqual(ParkingText.briefSpeech(closest: spot(direction: "north", meters: 60), near: "Lighthouse Coffee Roasters"),
                       "The closest spot is about 200 feet north of Lighthouse Coffee Roasters, on Northwest 64th Street: free, no posted time limit.")
        XCTAssertEqual(ParkingText.briefSpeech(closest: spot(direction: nil, meters: 10), near: "Lighthouse Coffee Roasters"),
                       "You can park right by Lighthouse Coffee Roasters, on Northwest 64th Street: free, no posted time limit.")
    }

    func testBriefAnswersFromRecordedData() async throws {
        let e = ParkingEngine(source: try capitolHill())
        let here = try await e.here(capitolHillPoint, permitZone: nil, date: seattle(6, 10))
        XCTAssertTrue(here.brief.hasPrefix("On 14th Avenue East:"), here.brief)
        XCTAssertFalse(here.brief.contains("between"), here.brief)

        let overnight = try await e.nearby(capitolHillPoint, limit: 5, until: seattle(7, 8), permitZone: nil, date: seattle(6, 22))
        // 10 PM until midnight, then the next day's rules.
        XCTAssertTrue(overnight.results.allSatisfy { ($0.timeLimitMinutes ?? .max) >= 120 },
                      overnight.results.map(\.summary).joined(separator: "; "))
    }
}
