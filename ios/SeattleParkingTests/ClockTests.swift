import XCTest
@testable import SeattleParking

// Mirrors test/schedule.test.js.
final class ClockTests: XCTestCase {
    func testParsesSDOTClockText() {
        XCTAssertEqual(Clock.parse("08AM"), 480)
        XCTAssertEqual(Clock.parse("10PM"), 1320)
        XCTAssertEqual(Clock.parse("12AM"), 0)
        XCTAssertEqual(Clock.parse("12PM"), 720)
        XCTAssertEqual(Clock.parse("8:30AM"), 510)
        XCTAssertNil(Clock.parse(nil))
        XCTAssertNil(Clock.parse("nonsense"))
    }

    func testSplitsPeakHourWindows() {
        func windows(_ s: String?) -> [[Int]] { Clock.peakWindows(s).map { [$0.start, $0.end] } }
        XCTAssertEqual(windows("7-9AM"), [[420, 540]])
        XCTAssertEqual(windows("7-9AM 4-6PM"), [[420, 540], [960, 1080]])
        XCTAssertEqual(windows("11-1PM"), [[660, 780]])
        XCTAssertEqual(windows(nil), [])
    }

    func testFormatsTimesAndLimits() {
        XCTAssertEqual(Clock.format(480), "8 AM")
        XCTAssertEqual(Clock.format(1290), "9:30 PM")
        XCTAssertEqual(Clock.format(720), "noon")
        XCTAssertEqual(Clock.format(1440), "midnight")
        XCTAssertEqual(Clock.limit(120), "2-hour")
        XCTAssertEqual(Clock.limit(30), "30-minute")
        XCTAssertEqual(Clock.limit(90), "1.5-hour")
    }

    func testSeattleTimeUsesPacificTime() {
        // 2026-10-06T08:00Z is Tuesday 1:00 AM PDT.
        let tue = SeattleTime(Date(timeIntervalSince1970: 1_791_273_600))
        XCTAssertEqual(tue.weekday, "Tue")
        XCTAssertEqual(tue.dayType, .weekday)
        XCTAssertTrue(tue.isWeekday)
        XCTAssertEqual(tue.minutes, 60)
        // 2026-10-11T19:30Z is Sunday 12:30 PM PDT.
        let sun = SeattleTime(Date(timeIntervalSince1970: 1_791_747_000))
        XCTAssertEqual(sun.dayType, .sunday)
        XCTAssertEqual(sun.minutes, 750)
    }
}
