import CoreLocation
import MapKit
import Observation
import SwiftUI

// MARK: - Every blockface in view

/// A curb line ready to draw: already shifted toward its side for the current
/// zoom step, with a stable identity so SwiftUI updates instead of recreating it.
struct DrawnCurb: Identifiable {
    let id: String
    let coordinates: [CLLocationCoordinate2D]
    let color: Color
}

/// Loads every blockface in the visible map area from /api/area, so the map
/// can color all the streets, not just the search results.
///
/// The map is split into a fixed grid of ~250 m tiles. Each tile is fetched
/// once (a circle query just covering it), cached, and only tiles in
/// the view are loaded, nearest first, at most four at a time. A tile that hits the server's
/// cap is split into four smaller tiles.
@MainActor @Observable
final class AreaCurbs {
    /// What the map should draw right now.
    private(set) var drawn: [DrawnCurb] = []
    /// Stroke width for the current zoom.
    private(set) var lineWidth: CGFloat = 3
    /// True when the view spans more tiles than we load at once.
    private(set) var zoomedOutTooFar = false

    // Grid: 250 m at Seattle's latitude.
    nonisolated private static let tileLat = 250.0 / 111_320
    nonisolated private static let tileLon = 250.0 / (111_320 * cos(47.62 * .pi / 180))
    private static let maxTiles = 64
    private static let maxConcurrent = 4
    /// /api/area returns at most 600 blockfaces; near that means "truncated".
    private static let serverCap = 590
    private static let maxDrawn = 4000

    struct Tile: Hashable {
        let level: Int  // 0 = 250 m, 1 = 125 m (a quarter of a level-0 tile)
        let i: Int      // latitude index
        let j: Int      // longitude index

        var size: (lat: Double, lon: Double) {
            let f = level == 0 ? 1.0 : 0.5
            return (AreaCurbs.tileLat * f, AreaCurbs.tileLon * f)
        }
        var center: CLLocationCoordinate2D {
            CLLocationCoordinate2D(latitude: (Double(i) + 0.5) * size.lat, longitude: (Double(j) + 0.5) * size.lon)
        }
        /// Circle radius that covers the whole tile, with a little margin.
        var radiusMeters: Int {
            let h = size.lat * 111_320 / 2, w = size.lon * 111_320 * cos(47.62 * .pi / 180) / 2
            return Int((hypot(h, w) * 1.1).rounded(.up))
        }
        var children: [Tile] {
            [(0, 0), (0, 1), (1, 0), (1, 1)].map { Tile(level: 1, i: i * 2 + $0.0, j: j * 2 + $0.1) }
        }
    }

    private var cache: [Tile: [AreaBlockface]] = [:]
    private var split: Set<Tile> = []
    private var inFlight: [Tile: Task<Void, Never>] = [:]
    private var queue: [Tile] = []
    private var unsupported = false

    private var visible: MKCoordinateRegion?
    private var zoomStep: Int?
    private var drawnIDs: Set<String> = []
    private var rebuildTask: Task<Void, Never>?

    /// Call when the camera settles (not continuously).
    func cameraSettled(region: MKCoordinateRegion, metersPerPoint: Double) {
        visible = region
        let step = CurbLine.zoomStep(metersPerPoint)
        let stepChanged = step != zoomStep
        zoomStep = step
        let width = CurbLine.areaWidth(step: step)
        if width != lineWidth { lineWidth = width }

        let needed = tiles(covering: region)
        let tooFar = needed == nil
        if tooFar != zoomedOutTooFar { zoomedOutTooFar = tooFar }

        // Stop loading tiles that are no longer near the view.
        let wanted = Set(needed ?? [])
        for (tile, task) in inFlight where !wanted.contains(tile) {
            task.cancel()
            inFlight[tile] = nil
        }
        // Nearest tiles first.
        queue = (needed ?? []).filter { cache[$0] == nil && inFlight[$0] == nil }
            .sorted { distance($0.center, region.center) < distance($1.center, region.center) }
        pump()
        rebuild(force: stepChanged)
    }

    /// Tiles intersecting the region (split tiles
    /// replaced by their quarters), or nil if that's too many to load.
    private func tiles(covering region: MKCoordinateRegion) -> [Tile]? {
        let lat0 = region.center.latitude - region.span.latitudeDelta / 2
        let lat1 = region.center.latitude + region.span.latitudeDelta / 2
        let lon0 = region.center.longitude - region.span.longitudeDelta / 2
        let lon1 = region.center.longitude + region.span.longitudeDelta / 2
        let i0 = Int(floor(lat0 / Self.tileLat)), i1 = Int(floor(lat1 / Self.tileLat))
        let j0 = Int(floor(lon0 / Self.tileLon)), j1 = Int(floor(lon1 / Self.tileLon))
        guard (i1 - i0 + 1) * (j1 - j0 + 1) <= Self.maxTiles else { return nil }
        var result: [Tile] = []
        for i in i0...i1 {
            for j in j0...j1 {
                let tile = Tile(level: 0, i: i, j: j)
                if split.contains(tile) { result += tile.children } else { result.append(tile) }
            }
        }
        return result
    }

    private func pump() {
        guard !unsupported else { queue = []; return }
        while inFlight.count < Self.maxConcurrent, !queue.isEmpty {
            let tile = queue.removeFirst()
            inFlight[tile] = Task { await self.load(tile) }
        }
    }

    private func load(_ tile: Tile) async {
        defer {
            inFlight[tile] = nil
            pump()
        }
        do {
            let api = try ParkingAPI.fromSettings()
            let answer = try await api.area(tile.center, radiusMeters: tile.radiusMeters)
            guard !Task.isCancelled else { return }
            if tile.level == 0, answer.blockfaces.count >= Self.serverCap {
                // Too dense for one query: load it as four smaller tiles.
                split.insert(tile)
                queue.insert(contentsOf: tile.children.filter { cache[$0] == nil }, at: 0)
            }
            // Cache only after a successful fetch.
            cache[tile] = answer.blockfaces
            scheduleRebuild()
        } catch ParkingError.notFound {
            unsupported = true
        } catch {
            // Cancelled or a network hiccup: it'll be retried on the next camera change.
        }
    }

    /// Coalesces redraws while several tiles arrive together.
    private func scheduleRebuild() {
        rebuildTask?.cancel()
        rebuildTask = Task {
            try? await Task.sleep(for: .milliseconds(80))
            guard !Task.isCancelled else { return }
            rebuild(force: false)
        }
    }

    /// Recomputes the drawn lines: everything cached near the view, deduplicated
    /// across tiles, shifted toward its side for the current zoom step.
    private func rebuild(force: Bool) {
        guard let visible, let zoomStep else { return }
        let shift = CurbLine.shiftMeters(step: zoomStep)
        let bounds = visible.expanded(by: 1.5)
        var seen: Set<String> = []
        var next: [DrawnCurb] = []
        outer: for blockfaces in cache.values {
            for b in blockfaces where bounds.intersects(b.path) {
                guard seen.insert(b.id).inserted else { continue }
                next.append(DrawnCurb(
                    id: b.id,
                    coordinates: CurbLine.offset(b.path, side: b.side, meters: shift),
                    color: CurbLine.color(canParkNow: b.canParkNow, freeNow: b.freeNow)
                ))
                if next.count >= Self.maxDrawn { break outer }
            }
        }
        // Same lines at the same zoom step: leave the overlays alone.
        if !force && seen == drawnIDs { return }
        drawnIDs = seen
        drawn = next
    }

    private func distance(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
        CLLocation(latitude: a.latitude, longitude: a.longitude).distance(from: CLLocation(latitude: b.latitude, longitude: b.longitude))
    }
}

extension AreaBlockface {
    /// Stable identity: street, side and where its curb starts.
    var id: String {
        let start = path.first.map { "\($0.lat),\($0.lon)" } ?? ""
        return "\(street)|\(side ?? "")|\(start)"
    }
}

extension MKCoordinateRegion {
    func expanded(by factor: Double) -> MKCoordinateRegion {
        MKCoordinateRegion(center: center, span: MKCoordinateSpan(
            latitudeDelta: span.latitudeDelta * factor, longitudeDelta: span.longitudeDelta * factor))
    }

    /// True if any point of the path falls inside the region.
    func intersects(_ path: [Coordinate]) -> Bool {
        let halfLat = span.latitudeDelta / 2, halfLon = span.longitudeDelta / 2
        return path.contains { abs($0.lat - center.latitude) <= halfLat && abs($0.lon - center.longitude) <= halfLon }
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

    /// Zoom quantized to half-octaves, so small zoom changes don't move lines.
    static func zoomStep(_ metersPerPoint: Double) -> Int {
        guard metersPerPoint > 0 else { return 0 }
        return Int((log2(metersPerPoint) * 2).rounded())
    }

    static func metersPerPoint(forStep step: Int) -> Double {
        pow(2, Double(step) / 2)
    }

    /// How far to push a line toward its side at this zoom. Zoomed far out the
    /// two sides are only a couple of points apart anyway, so don't separate them.
    static func shiftMeters(step: Int) -> Double {
        let mpp = metersPerPoint(forStep: step)
        return mpp > 4 ? 0 : sideOffsetPoints * mpp
    }

    /// Thin "every street" lines: about 3.5 pt up close, 2 pt across a
    /// kilometer, 1.5 pt beyond, so streets don't merge into a solid mesh.
    static func areaWidth(step: Int) -> CGFloat {
        let mpp = max(metersPerPoint(forStep: step), 1)
        return max(1.5, min(3.5, 3.5 / pow(mpp, 0.6)))
    }

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

/// Every street side in view, thin and colored by whether you can park.
struct AreaCurbsContent: MapContent {
    let curbs: [DrawnCurb]
    var width: CGFloat = 3

    var body: some MapContent {
        ForEach(curbs) { curb in
            MapPolyline(coordinates: curb.coordinates)
                .stroke(curb.color.opacity(0.85), style: CurbLine.style(width: width))
        }
    }
}

/// Shown over a map when it's too zoomed out to color the streets.
struct ZoomInHint: View {
    var body: some View {
        Label("Zoom in to see street colors", systemImage: "plus.magnifyingglass")
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.regularMaterial, in: Capsule())
            .padding(8)
    }
}

// MARK: - Home screen map

/// The streets around you, every side colored by whether you can park now,
/// with the block you're on drawn heavier.
struct HereMap: View {
    let blockfaces: [Blockface]
    @State private var area = AreaCurbs()
    @State private var zoomStep: Int?
    @State private var width: CGFloat = 0

    var body: some View {
        let shift = zoomStep.map(CurbLine.shiftMeters(step:)) ?? 0
        Map(initialPosition: .automatic, interactionModes: []) {
            UserAnnotation()
            AreaCurbsContent(curbs: area.drawn, width: area.lineWidth)
            ForEach(Array(blockfaces.enumerated()), id: \.offset) { _, b in
                if let path = b.path, path.count >= 2 {
                    MapPolyline(coordinates: CurbLine.offset(path, side: b.side, meters: shift))
                        .stroke(b.canParkNow ? Color.green : Color.red, style: CurbLine.style(width: 5))
                }
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .onMapCameraChange(frequency: .onEnd) { context in
            let mpp = CurbLine.metersPerPoint(context.region, width: width)
            let step = CurbLine.zoomStep(mpp)
            if step != zoomStep { zoomStep = step }
            area.cameraSettled(region: context.region, metersPerPoint: mpp)
        }
        // New data recreates the map so it fits the new lines.
        .id(blockfaces)
    }
}
