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

    /// The map's bounds are a rectangle, and its corners and edges are partly
    /// open water (Shilshole, Lake Washington, Elliott Bay). When a map near
    /// that edge shows no streets at all, this is the same-size region moved
    /// just far enough that the nearest street sits halfway between the middle
    /// and the edge. Nil when streets are in view, away from the edge (so
    /// Green Lake or a big park isn't pushed away), or before the city data
    /// is on the phone.
    static func pulledBackToStreets(_ region: MKCoordinateRegion) async -> MKCoordinateRegion? {
        let c = region.center
        // Within about 1.5 km of the city's box.
        let nearEdge = c.latitude < south + 0.0135 || c.latitude > north - 0.0135
            || c.longitude < west + 0.02 || c.longitude > east - 0.02
        guard nearEdge, let city = try? await CityData.shared.readySource() else { return nil }
        let halfHeight = region.span.latitudeDelta * 111_320 / 2
        let halfWidth = region.span.longitudeDelta * 111_320 * cos(c.latitude * .pi / 180) / 2
        let inView = min(halfHeight, halfWidth) * 0.8
        let origin = Coordinate(c)
        if let near = try? await city.blockfaces(near: origin, radiusMeters: inView), !near.isEmpty { return nil }
        guard let nearest = try? await city.blockfaces(near: origin, radiusMeters: 6_000).first,
              nearest.distance > 0 else { return nil }
        let f = max(0, (nearest.distance - inView * 0.5) / nearest.distance)
        let center = CLLocationCoordinate2D(latitude: c.latitude + (nearest.point.lat - c.latitude) * f,
                                            longitude: c.longitude + (nearest.point.lon - c.longitude) * f)
        return MKCoordinateRegion(center: center, span: region.span)
    }

    /// The opening view of downtown.
    static let downtownRegion = MKCoordinateRegion(center: downtown, latitudinalMeters: 500, longitudinalMeters: 500)
}
