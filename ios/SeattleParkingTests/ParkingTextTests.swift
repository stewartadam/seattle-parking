import XCTest
@testable import SeattleParking

// Mirrors the formatting and blockfaceSchedule tests in test/parking.test.js.
final class ParkingTextTests: XCTestCase {
    func testStreetExpandsAbbreviationsForSpeech() {
        XCTAssertEqual(ParkingText.street("BROADWAY E BETWEEN E OLIVE WAY AND E THOMAS ST"),
                       "Broadway East between East Olive Way and East Thomas Street")
        XCTAssertEqual(ParkingText.street("11TH AVE NE BETWEEN NE 45TH ST AND NE 47TH ST"),
                       "11th Avenue Northeast between Northeast 45th Street and Northeast 47th Street")
    }

    func testStreetLabelAbbreviatesForDisplay() {
        XCTAssertEqual(ParkingText.streetLabel("E LYNN ST BETWEEN YALE AVE E AND EASTLAKE AVE E"),
                       "E. Lynn St between Yale Ave E and Eastlake Ave E")
        XCTAssertEqual(ParkingText.streetLabel("NW 64TH ST BETWEEN 15TH AVE NW AND 17TH AVE NW"),
                       "NW 64th St between 15th Ave NW and 17th Ave NW")
        XCTAssertEqual(ParkingText.streetLabel("BROADWAY E BETWEEN E OLIVE WAY AND E THOMAS ST"),
                       "Broadway E between E. Olive Way and E. Thomas St")
    }

    func testDistanceUsesFeetThenMiles() {
        XCTAssertEqual(ParkingText.distance(10), "right here")
        XCTAssertEqual(ParkingText.distance(90), "about 300 feet")
        XCTAssertEqual(ParkingText.distance(800), "about 0.5 miles")
    }

    func testScheduleSaysWhenTheRulesApply() {
        XCTAssertEqual(
            ParkingSchedule.text(rules(merged(paidBroadway, [
                "SAT_RATE1": 2, "SAT_START1": 480, "SAT_END1": 1319, "START_TIME_SAT": "08AM", "END_TIME_SAT": "10PM",
            ])), rpzHours: [:]),
            "2-hour limit, paid Mon–Fri 8 AM–10 PM ($1–$2.50/hr), Sat 8 AM–10 PM ($2/hr); free Sun"
        )
        XCTAssertEqual(
            ParkingSchedule.text(rules([
                "PARKING_CATEGORY": "Paid Parking", "PARKING_TIME_LIMIT": 240,
                "START_TIME_WKD": "08AM", "END_TIME_WKD": "08PM", "WKD_RATE1": 3, "WKD_START1": 480, "WKD_END1": 1199,
                "START_TIME_SAT": "08AM", "END_TIME_SAT": "08PM", "SAT_RATE1": 3, "SAT_START1": 480, "SAT_END1": 1199,
            ]), rpzHours: [:]),
            "4-hour limit, paid Mon–Sat 8 AM–8 PM ($3/hr); free Sun"
        )
        XCTAssertEqual(
            ParkingSchedule.text(rules(["PARKING_CATEGORY": "Time Limited Parking", "PARKING_TIME_LIMIT": 120, "PEAK_HOUR": "7-9AM"]), rpzHours: [:]),
            "2-hour limit, hours not in city data, check the sign · no parking 7 AM–9 AM weekdays"
        )
        XCTAssertEqual(
            ParkingSchedule.text(rules(["PARKING_CATEGORY": "Restricted Parking Zone", "RPZ_ZONE": "4"]),
                                 rpzHours: ["4": "Monday-Saturday 7 AM to 6 PM"]),
            "2-hour limit without a zone 4 permit, Mon–Sat 7 AM–6 PM"
        )
        XCTAssertNil(ParkingSchedule.text(rules(["PARKING_CATEGORY": "Unrestricted Parking"]), rpzHours: [:]))
    }

    func testSavedCopyRoundTrips() throws {
        // The on-phone copy is saved as JSON with short keys; reading it back
        // must give the same rules.
        let original = rules(paidBroadway)
        let decoded = try JSONDecoder().decode(BlockfaceRules.self, from: JSONEncoder().encode(original))
        XCTAssertEqual(decoded, original)
    }
}
