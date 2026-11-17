import CoreLocation
import MapKit
import Observation
import SwiftUI

// MARK: - Every blockface in view

/// Loads every blockface around the visible map area from /api/area, so the
/// map can color all the streets, not just the search results.
@MainActor @Observable
final class AreaCurbs {
    private(set) var blockfaces: [AreaBlockface] = []

    /// The server answers for at most this radius; beyond it we keep what we have.
    static let maxRadiusMeters = 800.0

    private var loaded: (center: CLLocation, radius: Double)?
    private var pending: Task<Void, Never>?
    /// Set when the server doesn't have /api/area (older deployments).
    private var unsupported = false

    /// Call when the camera settles; fetches after a short pause unless the
    /// area is already covered.
    func update(for region: MKCoordinateRegion) {
        pending?.cancel()
        guard !unsupported else { return }
        let radius = max(region.halfDiagonalMeters, 100)
        guard radius <= Self.maxRadiusMeters else { return }
        let center = CLLocation(latitude: region.center.latitude, longitude: region.center.longitude)
        if let loaded, center.distance(from: loaded.center) + radius <= loaded.radius { return }

        pending = Task {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            // Fetch a little more than is visible so small pans don't refetch.
            let fetchRadius = min(radius * 1.5, Self.maxRadiusMeters)
            do {
                let api = try ParkingAPI.fromSettings()
                let answer = try await api.area(region.center, radiusMeters: Int(fetchRadius))
                guard !Task.isCancelled else { return }
                blockfaces = answer.blockfaces
                loaded = (center, fetchRadius)
            } catch ParkingError.notFound {
                unsupported = true
            } catch {
                // Network hiccup: try again on the next camera change.
            }
        }
    }
}

// MARK: - Drawing

enum CurbLine {
    static func style(width: CGFloat) -> StrokeStyle {
        StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round)
    }

    /// Green: free now. Orange: paid now. Red: no parking now.
    static func color(canParkNow: Bool, freeNow: Bool) -> Color {
        !canParkNow ? .red : (freeNow ? .green : .orange)
    }

    /// How far each side's line is pushed toward its curb, in screen points.
    static let sideOffsetPoints: CGFloat = 3

    /// Map meters per screen point for a region shown `width` points wide.
    static func metersPerPoint(_ region: MKCoordinateRegion?, width: CGFloat) -> Double {
        guard let region, width > 0 else { return 0 }
        let meters = region.span.longitudeDelta * 111_320 * cos(region.center.latitude * .pi / 180)
        return meters / Double(width)
    }

    /// The curb line moved sideways toward its side of the street ("north",
    /// "southwest", ...) so the two sides of a block don't overlap on screen.
    static func offset(_ path: [Coordinate], side: String?, meters: Double) -> [CLLocationCoordinate2D] {
        let coords = path.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) }
        guard meters > 0, let side, let toward = compassVector[side], let first = coords.first, let last = coords.last
        else { return coords }

        // Work in local meters around the first point.
        let metersPerDegLat = 111_320.0
        let metersPerDegLon = 111_320.0 * cos(first.latitude * .pi / 180)
        let dx = (last.longitude - first.longitude) * metersPerDegLon
        let dy = (last.latitude - first.latitude) * metersPerDegLat
        let length = hypot(dx, dy)
        guard length > 0 else { return coords }

        // Unit normal to the block, flipped to point toward the named side.
        var nx = -dy / length, ny = dx / length
        if nx * toward.x + ny * toward.y < 0 { nx = -nx; ny = -ny }
        let dLon = nx * meters / metersPerDegLon
        let dLat = ny * meters / metersPerDegLat
        return coords.map { CLLocationCoordinate2D(latitude: $0.latitude + dLat, longitude: $0.longitude + dLon) }
    }

    private static let compassVector: [String: (x: Double, y: Double)] = {
        let d = 1 / 2.0.squareRoot()
        return [
            "north": (0, 1), "south": (0, -1), "east": (1, 0), "west": (-1, 0),
            "northeast": (d, d), "northwest": (-d, d), "southeast": (d, -d), "southwest": (-d, -d),
        ]
    }()
}

/// Every blockface in `area`, thin and colored by whether you can park.
struct AreaCurbsContent: MapContent {
    let blockfaces: [AreaBlockface]
    let metersPerPoint: Double

    var body: some MapContent {
        ForEach(Array(blockfaces.enumerated()), id: \.offset) { _, b in
            MapPolyline(coordinates: CurbLine.offset(b.path, side: b.side, meters: CurbLine.sideOffsetPoints * metersPerPoint))
                .stroke(CurbLine.color(canParkNow: b.canParkNow, freeNow: b.freeNow).opacity(0.85),
                        style: CurbLine.style(width: 3))
        }
    }
}

// MARK: - Home screen map

/// The streets around you, every side colored by whether you can park now,
/// with the block you're on drawn heavier.
struct HereMap: View {
    let blockfaces: [Blockface]
    @State private var area = AreaCurbs()
    @State private var region: MKCoordinateRegion?
    @State private var width: CGFloat = 0

    var body: some View {
        let mpp = CurbLine.metersPerPoint(region, width: width)
        Map(initialPosition: .automatic, interactionModes: []) {
            UserAnnotation()
            AreaCurbsContent(blockfaces: area.blockfaces, metersPerPoint: mpp)
            ForEach(Array(blockfaces.enumerated()), id: \.offset) { _, b in
                if let path = b.path, path.count >= 2 {
                    MapPolyline(coordinates: CurbLine.offset(path, side: b.side, meters: CurbLine.sideOffsetPoints * mpp))
                        .stroke(b.canParkNow ? Color.green : Color.red, style: CurbLine.style(width: 5))
                }
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .onMapCameraChange(frequency: .onEnd) { context in
            region = context.region
            area.update(for: context.region)
        }
        // New data recreates the map so it fits the new lines.
        .id(blockfaces)
    }
}
