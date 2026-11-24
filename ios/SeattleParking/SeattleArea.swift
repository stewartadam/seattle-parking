import CoreLocation
import MapKit

/// The part of the world the app covers: the City of Seattle, as a box around
/// the city limits with roughly a kilometer to spare on each side.
enum SeattleArea {
    // City limits run from N 145th St (47.734) to the south line near
    // Boeing Field (47.496), and from Alki Point (-122.436) to the middle of
    // Lake Washington (-122.236).
    static let south = 47.4955, north = 47.7341
    static let west = -122.4360, east = -122.2360
    /// About 1.1 km of slack, so streets right at the city line stay reachable.
    static let bufferLat = 0.010, bufferLon = 0.015

    /// Pike Place Market: where the map opens when you aren't in Seattle.
    static let downtown = CLLocationCoordinate2D(latitude: 47.6097, longitude: -122.3422)

    /// City limits plus the buffer.
    static let region = box(lat: bufferLat, lon: bufferLon)

    /// Where the map's center may go: the city limits with no buffer, so even
    /// fully zoomed out at the edge, part of the city (and its zones) is on screen.
    static let mapBounds = box(lat: 0, lon: 0)

    private static func box(lat: Double, lon: Double) -> MKCoordinateRegion {
        let s = south - lat, n = north + lat
        let w = west - lon, e = east + lon
        return MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: (s + n) / 2, longitude: (w + e) / 2),
            span: MKCoordinateSpan(latitudeDelta: n - s, longitudeDelta: e - w))
    }

    /// True when the point is in Seattle (or within the buffer around it).
    static func contains(_ c: CLLocationCoordinate2D) -> Bool {
        region.contains(c)
    }

    /// The opening view of downtown.
    static let downtownRegion = MKCoordinateRegion(center: downtown, latitudinalMeters: 500, longitudinalMeters: 500)
}
