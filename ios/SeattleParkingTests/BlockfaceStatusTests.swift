import XCTest
@testable import SeattleParking

// Mirrors the evaluateBlockface tests in test/parking.test.js.
final class BlockfaceStatusTests: XCTestCase {
    let paid = rules(paidBroadway)

    func testPaidParkingReportsRateAndLimit() {
        let r = status(paid, weekday(12 * 60))
        XCTAssertTrue(r.canParkNow)
        XCTAssertFalse(r.freeNow)
        XCTAssertEqual(r.ratePerHour, 2.5)
        XCTAssertEqual(r.timeLimitMinutes, 120)
        XCTAssertEqual(r.summary, "paid, $2.50 an hour until 10 PM, 2-hour limit")
        XCTAssertEqual(r.side, "west")
    }

    func testPaidParkingIsFreeOutsideEnforcementHours() {
        XCTAssertEqual(status(paid, weekday(23 * 60)).summary, "free now, paid parking ended at 10 PM")
        let early = status(paid, weekday(7 * 60))
        XCTAssertEqual(early.summary, "free until 8 AM, then paid")
        XCTAssertTrue(early.freeNow)
        XCTAssertEqual(early.timeLimitMinutes, 60)
        XCTAssertEqual(status(paid, sunday(720)).summary, "paid parking area, but free today")
    }

    func testPeakHourTowAwayOverridesOnWeekdaysOnly() {
        let a = rules(merged(paidBroadway, ["PEAK_HOUR": "4-6PM"]))
        let rush = status(a, weekday(17 * 60))
        XCTAssertFalse(rush.canParkNow)
        XCTAssertTrue(rush.summary.contains("tow-away zone until 6 PM"), rush.summary)

        let before = status(a, weekday(15 * 60))
        XCTAssertTrue(before.canParkNow)
        XCTAssertEqual(before.timeLimitMinutes, 60)
        XCTAssertTrue(before.summary.contains("becomes a tow-away zone at 4 PM"), before.summary)

        XCTAssertTrue(status(a, saturday(17 * 60)).canParkNow)
    }

    func testRPZHonoursAMatchingPermit() {
        let a = rules([
            "UNITDESC": "14TH AVE E BETWEEN E REPUBLICAN ST AND E MERCER ST", "SIDE": "E",
            "PARKING_CATEGORY": "Restricted Parking Zone", "RPZ_ZONE": "4", "PARKING_TIME_LIMIT": 120,
        ])
        XCTAssertEqual(status(a, weekday(600)).summary, "free, 2-hour limit without a zone 4 permit")
        let withPermit = status(a, weekday(600), permitZone: "4")
        XCTAssertNil(withPermit.timeLimitMinutes)
        XCTAssertEqual(withPermit.summary, "free with your zone 4 permit, no time limit")
        // Another zone's permit doesn't help.
        XCTAssertEqual(status(a, weekday(600), permitZone: "7").timeLimitMinutes, 120)
    }

    func testNoParkingBlocksAreNeverParkable() {
        XCTAssertFalse(status(rules(["PARKING_CATEGORY": "No Parking Allowed"]), weekday(600)).canParkNow)
    }

    func testSeparatesPostedLimitsUpcomingRestrictionsAndLaterParking() {
        let inHours = status(paid, weekday(9 * 60))
        XCTAssertEqual(inHours.postedLimitMinutes, 120)
        XCTAssertNil(inHours.restrictionInMinutes)
        let early = status(paid, weekday(7 * 60))
        XCTAssertNil(early.postedLimitMinutes)
        XCTAssertEqual(early.restrictionInMinutes, 60)

        // Unrestricted block with a 4–6 PM tow-away.
        let peak: [String: Any?] = [
            "UNITDESC": "E MERCER ST BETWEEN 10TH AVE E AND 11TH AVE E", "SIDE": "N",
            "PARKING_CATEGORY": "Unrestricted Parking", "PEAK_HOUR": "4-6PM",
        ]
        let before = status(rules(peak), weekday(15 * 60))
        XCTAssertTrue(before.canParkNow)
        XCTAssertEqual(before.restrictionInMinutes, 60)
        let during = status(rules(peak), weekday(17 * 60))
        XCTAssertFalse(during.canParkNow)
        XCTAssertEqual(during.parkableInMinutes, 60)

        let none = status(rules(merged(peak, ["PARKING_CATEGORY": "No Parking Allowed", "PEAK_HOUR": nil])), weekday(12 * 60))
        XCTAssertNil(none.parkableInMinutes)
    }

    func testStreetLabelIsAbbreviated() {
        XCTAssertEqual(status(paid, weekday(600)).streetLabel, "Broadway E between E. Olive Way and E. Thomas St")
    }
}
