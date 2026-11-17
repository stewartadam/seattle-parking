import CoreLocation
import MapKit
import Observation
import SwiftUI
import UIKit

// MARK: - Street colors for the visible map

/// Every street side's curb, grouped by color and ready to hand to MapKit as
/// one MKMultiPolyline per color.
/// The Find Parking filters, as they affect street colors.
struct CurbFilters: Equatable, Sendable {
    var stayingMinutes: Int?
    var freeOnly = false
    var isActive: Bool { stayingMinutes != nil || freeOnly }
}

struct AreaLayers {
    var version = 0
    var groups: [(color: UIColor, lines: [[CLLocationCoordinate2D]])] = []
    var width: CGFloat = 3
    var lineCount: Int { groups.reduce(0) { $0 + $1.lines.count } }
}

/// Loads every blockface in the visible map area from /api/area, so the map
/// can color all the streets, not just the search results.
///
/// The map is split into a fixed grid of 250 m tiles. Each tile in view is
/// fetched once (a circle query just covering it), nearest first, at most four
/// at a time, and cached. A tile that hits the server's cap is split into four
/// 125 m tiles. Lines are shifted and grouped off the main thread, and only
/// rebuilt when tiles arrive or the zoom changes noticeably.
@MainActor @Observable
final class AreaCurbs {
    /// What the map draws.
    private(set) var layers = AreaLayers() {
        didSet { onLayers?(layers) }
    }
    /// Set by the map view: new layers go straight to MapKit, without waiting
    /// for SwiftUI to re-render the screen.
    @ObservationIgnored var onLayers: ((AreaLayers) -> Void)?
    /// True when the view spans more tiles than we load at once.
    private(set) var zoomedOutTooFar = false

    nonisolated private static let tileLat = 250.0 / 111_320
    nonisolated private static let tileLon = 250.0 / (111_320 * cos(47.62 * .pi / 180))
    private static let maxTiles = 36
    private static let maxConcurrent = 4
    /// /api/area returns at most 600 blockfaces; near that means "truncated".
    private static let serverCap = 580

    struct Tile: Hashable {
        let level: Int  // 0 = 250 m, -1 = 125 m (a quarter, for dense areas)
        let i: Int      // latitude index
        let j: Int      // longitude index

        var size: (lat: Double, lon: Double) {
            let f = pow(2, Double(level))
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
            [(0, 0), (0, 1), (1, 0), (1, 1)].map { Tile(level: level - 1, i: i * 2 + $0.0, j: j * 2 + $0.1) }
        }
    }

    private var cache: [Tile: [AreaBlockface]] = [:]
    private var split: Set<Tile> = []
    private var inFlight: [Tile: (token: UUID, task: Task<Void, Never>)] = [:]
    private var queue: [Tile] = []
    private var unsupported = false

    private var visible: MKCoordinateRegion?
    private var zoomStep: Int?
    private var rebuildTask: Task<Void, Never>?
    private var drawnKey: (ids: Int, step: Int, filters: CurbFilters)?
    private var filters = CurbFilters()

    /// The search filters; recolors without refetching.
    func setFilters(_ new: CurbFilters) {
        guard new != filters else { return }
        filters = new
        scheduleRebuild(delay: 0)
    }

    /// Call when the camera settles (not continuously).
    func cameraSettled(region: MKCoordinateRegion, metersPerPoint: Double) {
        visible = region
        let step = CurbLine.zoomStep(metersPerPoint)
        let stepChanged = step != zoomStep
        zoomStep = step

        let needed = tiles(covering: region)
        let tooFar = needed == nil
        if tooFar != zoomedOutTooFar { zoomedOutTooFar = tooFar }

        // Stop loading tiles that are no longer in view.
        let wanted = Set(needed ?? [])
        for (tile, entry) in inFlight where !wanted.contains(tile) {
            entry.task.cancel()
            inFlight[tile] = nil
        }
        queue = (needed ?? []).filter { cache[$0] == nil && inFlight[$0] == nil }
            .sorted { distance($0.center, region.center) < distance($1.center, region.center) }
        pump()
        scheduleRebuild(delay: stepChanged ? 0 : 150)
    }

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
            for j in j0...j1 { expand(Tile(level: 0, i: i, j: j), into: &result) }
        }
        return result
    }

    private func expand(_ tile: Tile, into result: inout [Tile]) {
        if split.contains(tile) {
            for child in tile.children { expand(child, into: &result) }
        } else {
            result.append(tile)
        }
    }

    private func pump() {
        guard !unsupported else { queue = []; return }
        while inFlight.count < Self.maxConcurrent, !queue.isEmpty {
            let tile = queue.removeFirst()
            let token = UUID()
            inFlight[tile] = (token, Task { await self.load(tile, token: token) })
        }
    }

    private func load(_ tile: Tile, token: UUID) async {
        defer {
            // Only clear our own entry: a cancelled load can finish after the
            // same tile was queued again.
            if inFlight[tile]?.token == token { inFlight[tile] = nil }
            pump()
        }
        do {
            // The request and JSON decoding run off the main thread.
            let api = try ParkingAPI.fromSettings()
            let answer = try await api.area(tile.center, radiusMeters: tile.radiusMeters)
            guard !Task.isCancelled else { return }
            if tile.level > -1, answer.blockfaces.count >= Self.serverCap {
                split.insert(tile)
                queue.insert(contentsOf: tile.children.filter { cache[$0] == nil }, at: 0)
            }
            cache[tile] = answer.blockfaces
            scheduleRebuild(delay: 150)
        } catch ParkingError.notFound {
            unsupported = true
        } catch {
            // Cancelled (left the view) or a network hiccup: retry shortly if
            // it's still in view, instead of waiting for the map to move.
            guard !Task.isCancelled else { return }
            Task {
                try? await Task.sleep(for: .seconds(2))
                guard let visible, cache[tile] == nil, inFlight[tile] == nil,
                      tiles(covering: visible)?.contains(tile) == true else { return }
                queue.append(tile)
                pump()
            }
        }
    }

    /// Coalesces rebuilds while several tiles arrive together, then shifts and
    /// groups the lines on a background thread.
    private func scheduleRebuild(delay: Int) {
        rebuildTask?.cancel()
        guard let visible, let zoomStep else { return }
        let tiles = Array(cache.values)
        let bounds = visible.expanded(by: 1.5)
        let filters = filters
        rebuildTask = Task {
            if delay > 0 { try? await Task.sleep(for: .milliseconds(delay)) }
            guard !Task.isCancelled else { return }
            let (layers, idsHash) = await Task.detached(priority: .userInitiated) {
                Self.buildLayers(tiles: tiles, bounds: bounds, step: zoomStep, filters: filters)
            }.value
            guard !Task.isCancelled else { return }
            // Same lines at the same zoom step: leave MapKit alone.
            if let drawnKey, drawnKey.ids == idsHash, drawnKey.step == zoomStep, drawnKey.filters == filters { return }
            drawnKey = (idsHash, zoomStep, filters)
            var next = layers
            next.version = self.layers.version + 1
            self.layers = next
        }
    }

    nonisolated private static func buildLayers(tiles: [[AreaBlockface]], bounds: MKCoordinateRegion, step: Int, filters: CurbFilters) -> (AreaLayers, Int) {
        let shift = CurbLine.shiftMeters(step: step)
        var seen = Set<String>()
        var lines: [CurbLine.Kind: [[CLLocationCoordinate2D]]] = [:]
        for blockfaces in tiles {
            for b in blockfaces where bounds.intersects(b.path) {
                guard seen.insert(b.id).inserted else { continue }
                let line = CurbLine.offset(b.path, side: b.side, meters: shift)
                let kind = CurbLine.kind(canParkNow: b.canParkNow, freeNow: b.freeNow, timeLimitMinutes: b.timeLimitMinutes,
                                         postedLimitMinutes: b.postedLimitMinutes, restrictionInMinutes: b.restrictionInMinutes,
                                         filters: filters)
                lines[kind, default: []].append(line)
            }
        }
        var layers = AreaLayers()
        // One MKMultiPolyline per color; later groups draw on top.
        layers.groups = CurbLine.Kind.allCases.map { ($0.color, lines[$0] ?? []) }
        layers.width = CurbLine.areaWidth(step: step)
        return (layers, seen.hashValue)
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

    /// A region around the points with some padding, at least `minimumMeters`
    /// across. Falls back to central Seattle if there are no points.
    static func fitting(_ points: [CLLocationCoordinate2D], minimumMeters: Double) -> MKCoordinateRegion {
        guard let first = points.first else {
            return MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: 47.6062, longitude: -122.3321),
                                      latitudinalMeters: 800, longitudinalMeters: 800)
        }
        var minLat = first.latitude, maxLat = first.latitude, minLon = first.longitude, maxLon = first.longitude
        for p in points {
            minLat = min(minLat, p.latitude); maxLat = max(maxLat, p.latitude)
            minLon = min(minLon, p.longitude); maxLon = max(maxLon, p.longitude)
        }
        let center = CLLocationCoordinate2D(latitude: (minLat + maxLat) / 2, longitude: (minLon + maxLon) / 2)
        let minLatDelta = minimumMeters / 111_320
        let minLonDelta = minimumMeters / (111_320 * cos(center.latitude * .pi / 180))
        return MKCoordinateRegion(center: center, span: MKCoordinateSpan(
            latitudeDelta: max((maxLat - minLat) * 1.3, minLatDelta),
            longitudeDelta: max((maxLon - minLon) * 1.3, minLonDelta)))
    }
}

// MARK: - Drawing

enum CurbLine {
    /// What a block side means for you right now.
    enum Kind: Int, CaseIterable {
        // Drawing order: later kinds draw on top.
        case noParking, restricted, okForFilters, free

        var color: UIColor {
            switch self {
            case .noParking: .systemRed
            case .restricted: .systemYellow
            case .okForFilters: UIColor(red: 0.71, green: 0.90, blue: 0.11, alpha: 1) // chartreuse
            case .free: .systemGreen
            }
        }

        func label(filtersActive: Bool) -> String {
            switch self {
            case .noParking: filtersActive ? "Won't work" : "No parking"
            case .restricted: "Restrictions"
            case .okForFilters: "OK for your stay"
            case .free: "Free"
            }
        }

        /// The colors shown with and without filters.
        static func legend(filtersActive: Bool) -> [Kind] {
            filtersActive ? [.free, .okForFilters, .noParking] : [.free, .restricted, .noParking]
        }
    }

    /// Without a chosen stay, a restriction starting within this long counts.
    static let restrictionHorizonMinutes = 12 * 60

    /// Without filters: green = free now with no limit and nothing coming up,
    /// yellow = any restriction (paid now, a time limit, or one starting
    /// within 12 h), red = no parking now.
    ///
    /// With filters (a stay length and/or Free only): green = free with no
    /// restriction during the stay, green-yellow = restricted but fine for
    /// the filters, red = no parking now or doesn't fit the filters.
    static func kind(canParkNow: Bool, freeNow: Bool, timeLimitMinutes: Int?, postedLimitMinutes: Int?,
                     restrictionInMinutes: Int?, filters: CurbFilters) -> Kind {
        if !canParkNow { return .noParking }
        var posted = postedLimitMinutes
        // Older servers only send the combined limit: treat it as posted.
        if posted == nil, restrictionInMinutes == nil { posted = timeLimitMinutes }

        let horizon = filters.stayingMinutes ?? restrictionHorizonMinutes
        let restrictionSoon = restrictionInMinutes.map { $0 < horizon } ?? false
        if freeNow, posted == nil, !restrictionSoon { return .free }
        guard filters.isActive else { return .restricted }

        var fits = !filters.freeOnly || freeNow
        if let staying = filters.stayingMinutes {
            if let posted, posted < staying { fits = false }
            if let starts = restrictionInMinutes, starts < staying { fits = false }
        }
        return fits ? .okForFilters : .noParking
    }

    /// Camera distance limits (meters above the map): the widest view is about
    /// 1 km across, so the street colors never mean loading half the city.
    static let minCameraDistance = 150.0
    static let maxCameraDistance = 1_900.0

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

    /// How far to push a line toward its side at this zoom. Past roughly a
    /// 600 m wide view the sides are drawn where they are.
    static func shiftMeters(step: Int) -> Double {
        let mpp = metersPerPoint(forStep: step)
        return mpp > 1.6 ? 0 : sideOffsetPoints * mpp
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

// MARK: - Map view

/// A highlighted curb drawn above the street colors (a search result, or the
/// block you're on).
struct HighlightCurb {
    let coordinates: [CLLocationCoordinate2D]
    let color: UIColor
    let width: CGFloat
    var outlined = false
}

/// A numbered search-result pin.
struct ResultPin {
    let index: Int
    let coordinate: CLLocationCoordinate2D
    let color: UIColor
}

/// Where the map should move to. Changing `id` moves it, even to the same region.
struct MapFocus: Equatable {
    var id: Int
    var region: MKCoordinateRegion
    static func == (a: MapFocus, b: MapFocus) -> Bool { a.id == b.id }
}

/// MKMapView wrapper. SwiftUI's Map creates one overlay per line, which is too
/// slow for hundreds of streets; here the street colors are three
/// MKMultiPolylines (one per color) and only change when their data does.
struct CurbMapView: UIViewRepresentable {
    /// Street colors; new layers are pushed straight to the map.
    var area: AreaCurbs
    var highlights: [HighlightCurb] = []
    /// Changes whenever `highlights` should be redrawn.
    var highlightsKey: Int = 0
    var pins: [ResultPin] = []
    var selection: Binding<Int?> = .constant(nil)
    var focus: MapFocus?
    var interactive = true
    var onRegionChange: (MKCoordinateRegion, CGFloat) -> Void = { _, _ in }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        map.showsUserLocation = true
        map.pointOfInterestFilter = .excludingAll
        map.register(MKMarkerAnnotationView.self, forAnnotationViewWithReuseIdentifier: "pin")
        if let focus {
            map.setRegion(focus.region, animated: false)
            context.coordinator.focusID = focus.id
        }
        if interactive {
            map.cameraZoomRange = MKMapView.CameraZoomRange(
                minCenterCoordinateDistance: CurbLine.minCameraDistance,
                maxCenterCoordinateDistance: CurbLine.maxCameraDistance)
            map.isRotateEnabled = false
            map.isPitchEnabled = false
            let button = MKUserTrackingButton(mapView: map)
            button.backgroundColor = .secondarySystemBackground
            button.layer.cornerRadius = 8
            button.translatesAutoresizingMaskIntoConstraints = false
            map.addSubview(button)
            NSLayoutConstraint.activate([
                button.topAnchor.constraint(equalTo: map.safeAreaLayoutGuide.topAnchor, constant: 12),
                button.trailingAnchor.constraint(equalTo: map.trailingAnchor, constant: -12),
            ])
        } else {
            map.isScrollEnabled = false
            map.isZoomEnabled = false
            map.isRotateEnabled = false
            map.isPitchEnabled = false
        }
        return map
    }

    func updateUIView(_ map: MKMapView, context: Context) {
        let c = context.coordinator
        c.parent = self

        area.onLayers = { [weak map, weak c] layers in
            guard let map, let c else { return }
            c.apply(layers, to: map)
        }
        c.apply(area.layers, to: map)

        if highlightsKey != c.highlightsKey {
            c.highlightsKey = highlightsKey
            map.removeOverlays(c.highlightOverlays)
            c.highlightOverlays = highlights.flatMap { h -> [MKOverlay] in
                var lines: [MKOverlay] = []
                if h.outlined {
                    let outline = MKPolyline(coordinates: h.coordinates, count: h.coordinates.count)
                    c.styles[ObjectIdentifier(outline)] = (.white, h.width + 3)
                    lines.append(outline)
                }
                let line = MKPolyline(coordinates: h.coordinates, count: h.coordinates.count)
                c.styles[ObjectIdentifier(line)] = (h.color, h.width)
                lines.append(line)
                return lines
            }
            map.addOverlays(c.highlightOverlays, level: .aboveRoads)
            c.pruneStyles(keeping: c.areaOverlays + c.highlightOverlays)
        }

        let pinsKey = pins.map { "\($0.index):\($0.coordinate.latitude),\($0.coordinate.longitude):\($0.color.hashValue)" }.joined(separator: ";")
        if pinsKey != c.pinsKey {
            c.pinsKey = pinsKey
            map.removeAnnotations(map.annotations.filter { $0 is ResultAnnotation })
            map.addAnnotations(pins.map(ResultAnnotation.init))
        }

        let selected = map.selectedAnnotations.compactMap { $0 as? ResultAnnotation }.first?.pin.index
        if selected != selection.wrappedValue {
            if let index = selection.wrappedValue,
               let annotation = map.annotations.compactMap({ $0 as? ResultAnnotation }).first(where: { $0.pin.index == index }) {
                map.selectAnnotation(annotation, animated: true)
            } else {
                for a in map.selectedAnnotations { map.deselectAnnotation(a, animated: true) }
            }
        }

        if let focus, focus.id != c.focusID {
            c.focusID = focus.id
            map.setRegion(map.regionThatFits(focus.region), animated: true)
        }
    }

    final class ResultAnnotation: NSObject, MKAnnotation {
        let pin: ResultPin
        var coordinate: CLLocationCoordinate2D { pin.coordinate }
        init(_ pin: ResultPin) { self.pin = pin }
    }

    final class Coordinator: NSObject, MKMapViewDelegate {
        var parent: CurbMapView
        var areaVersion = -1
        var areaOverlays: [MKOverlay] = []
        var highlightsKey = Int.min
        var highlightOverlays: [MKOverlay] = []
        var pinsKey = ""
        var focusID: Int?
        var styles: [ObjectIdentifier: (color: UIColor, width: CGFloat)] = [:]

        init(_ parent: CurbMapView) { self.parent = parent }

        /// Swaps in new street-color overlays (once per version).
        func apply(_ layers: AreaLayers, to map: MKMapView) {
            guard layers.version != areaVersion else { return }
            areaVersion = layers.version
            map.removeOverlays(areaOverlays)
            areaOverlays = layers.groups.compactMap { group in
                guard !group.lines.isEmpty else { return nil }
                let multi = MKMultiPolyline(group.lines.map { MKPolyline(coordinates: $0, count: $0.count) })
                styles[ObjectIdentifier(multi)] = (group.color.withAlphaComponent(0.85), layers.width)
                return multi
            }
            // Below the highlights.
            for (i, overlay) in areaOverlays.enumerated() { map.insertOverlay(overlay, at: i, level: .aboveRoads) }
            pruneStyles(keeping: areaOverlays + highlightOverlays)
        }

        func pruneStyles(keeping overlays: [MKOverlay]) {
            let live = Set(overlays.map { ObjectIdentifier($0 as AnyObject) })
            styles = styles.filter { live.contains($0.key) }
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            let style = styles[ObjectIdentifier(overlay as AnyObject)] ?? (.systemGray, 2)
            let renderer: MKOverlayPathRenderer
            if let multi = overlay as? MKMultiPolyline {
                renderer = MKMultiPolylineRenderer(multiPolyline: multi)
            } else if let line = overlay as? MKPolyline {
                renderer = MKPolylineRenderer(polyline: line)
            } else {
                return MKOverlayRenderer(overlay: overlay)
            }
            renderer.strokeColor = style.color
            renderer.lineWidth = style.width
            renderer.lineCap = .round
            renderer.lineJoin = .round
            return renderer
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            guard let result = annotation as? ResultAnnotation else { return nil }
            let view = mapView.dequeueReusableAnnotationView(withIdentifier: "pin", for: annotation) as! MKMarkerAnnotationView
            view.glyphText = "\(result.pin.index + 1)"
            view.markerTintColor = result.pin.color
            view.titleVisibility = .hidden
            view.subtitleVisibility = .hidden
            view.displayPriority = .required
            return view
        }

        func mapView(_ mapView: MKMapView, didSelect annotation: MKAnnotation) {
            guard let result = annotation as? ResultAnnotation else { return }
            DispatchQueue.main.async { self.parent.selection.wrappedValue = result.pin.index }
        }

        func mapView(_ mapView: MKMapView, didDeselect annotation: MKAnnotation) {
            guard let result = annotation as? ResultAnnotation else { return }
            DispatchQueue.main.async {
                if self.parent.selection.wrappedValue == result.pin.index { self.parent.selection.wrappedValue = nil }
            }
        }

        func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
            let region = mapView.region, width = mapView.bounds.width
            DispatchQueue.main.async { self.parent.onRegionChange(region, width) }
        }
    }
}

/// A one-line color key for the street colors.
struct CurbLegend: View {
    var filtersActive = false

    var body: some View {
        HStack(spacing: 12) {
            ForEach(CurbLine.Kind.legend(filtersActive: filtersActive), id: \.self) { kind in
                HStack(spacing: 4) {
                    Capsule().fill(Color(kind.color)).frame(width: 14, height: 4)
                    Text(kind.label(filtersActive: filtersActive))
                }
            }
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .combine)
    }
}

extension Spot {
    func kind(filters: CurbFilters) -> CurbLine.Kind {
        CurbLine.kind(canParkNow: true, freeNow: freeNow, timeLimitMinutes: timeLimitMinutes, postedLimitMinutes: postedLimitMinutes,
                      restrictionInMinutes: restrictionInMinutes, filters: filters)
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

    var body: some View {
        let shift = zoomStep.map(CurbLine.shiftMeters(step:)) ?? 0
        let highlights = blockfaces.compactMap { b -> HighlightCurb? in
            guard let path = b.path, path.count >= 2 else { return nil }
            return HighlightCurb(coordinates: CurbLine.offset(path, side: b.side, meters: shift),
                                 color: CurbLine.kind(canParkNow: b.canParkNow, freeNow: b.freeNow ?? true,
                                                      timeLimitMinutes: b.timeLimitMinutes, postedLimitMinutes: b.postedLimitMinutes,
                                                      restrictionInMinutes: b.restrictionInMinutes, filters: CurbFilters()).color,
                                 width: 5)
        }
        CurbMapView(
            area: area,
            highlights: highlights,
            highlightsKey: zoomStep ?? 0,
            focus: MapFocus(id: 0, region: hereRegion),
            interactive: false,
            onRegionChange: { region, width in
                let mpp = CurbLine.metersPerPoint(region, width: width)
                let step = CurbLine.zoomStep(mpp)
                if step != zoomStep { zoomStep = step }
                area.cameraSettled(region: region, metersPerPoint: mpp)
            }
        )
        // New data recreates the map so it frames the new block.
        .id(blockfaces)
    }

    /// Frames the block you're on (at least 250 m across).
    private var hereRegion: MKCoordinateRegion {
        let points = blockfaces.flatMap { ($0.path ?? []).map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) } }
        return MKCoordinateRegion.fitting(points, minimumMeters: 250)
    }
}
