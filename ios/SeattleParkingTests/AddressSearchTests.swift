import CoreLocation
import XCTest
@testable import SeattleParking

final class AddressSearchTests: XCTestCase {
    func testKnowsWhatIsInSeattle() {
        func inSeattle(_ lat: Double, _ lon: Double) -> Bool {
            AddressSearch.isInSeattle(CLLocationCoordinate2D(latitude: lat, longitude: lon))
        }
        XCTAssertTrue(inSeattle(47.6097, -122.3422))   // Pike Place Market
        XCTAssertTrue(inSeattle(47.6806, -122.3290))   // Green Lake
        XCTAssertTrue(inSeattle(47.5287, -122.3937))   // West Seattle (Fauntleroy)
        XCTAssertFalse(inSeattle(47.6101, -122.2015))  // Bellevue
        XCTAssertFalse(inSeattle(47.2529, -122.4443))  // Tacoma
        XCTAssertFalse(inSeattle(47.8209, -122.3151))  // Lynnwood
    }
}
