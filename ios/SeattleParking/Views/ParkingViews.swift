import CoreLocation
import MapKit
import SwiftUI

/// One side of the street and whether you can park there now.
struct BlockfaceRow: View {
    let blockface: Blockface

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: blockface.canParkNow ? "checkmark.circle.fill" : "xmark.octagon.fill")
                .font(.title2)
                .foregroundStyle(blockface.canParkNow ? .green : .red)
                .accessibilityLabel(blockface.canParkNow ? "You can park" : "No parking")
            VStack(alignment: .leading, spacing: 2) {
                Text(blockface.side.map { "\($0.capitalized) side" } ?? "This side").font(.subheadline.bold())
                Text(blockface.summary).font(.subheadline)
                if let schedule = blockface.schedule {
                    Text(schedule).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

/// A search result with a driving-directions button. The bar on the left is
/// the street's color on the map.
struct SpotRow: View {
    let spot: Spot
    var kind: CurbLine.Kind? = nil

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Capsule()
                .fill(Color((kind ?? spot.kind(filters: CurbFilters())).color))
                .frame(width: 5, height: 36)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(spot.displayStreet).font(.subheadline.bold())
                Text(spot.summary).font(.subheadline)
                if let schedule = spot.schedule {
                    Text(schedule).font(.caption).foregroundStyle(.secondary)
                }
                Text(spot.distanceLabel).font(.caption).foregroundStyle(.secondary)
            }
            // Separators start under the street name, not under the number.
            .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] }
            Spacer(minLength: 8)
            DirectionsButton(url: spot.drivingDirectionsURL, street: spot.street)
        }
        .padding(.vertical, 2)
    }
}

/// A round driving-directions button.
struct DirectionsButton: View {
    let url: URL
    let street: String
    @Environment(\.openURL) private var openURL

    var body: some View {
        Button { openURL(url) } label: {
            Image(systemName: "arrow.triangle.turn.up.right.diamond.fill")
                .font(.title3)
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(Circle().fill(Color.accentColor))
        }
        .buttonStyle(.borderless)
        .accessibilityLabel("Driving directions")
        .accessibilityHint(street)
    }
}

/// The rules for one street side picked on the map (or in the results list).
struct CurbDetail: View {
    let curb: AreaBlockface
    let filters: CurbFilters
    var onClose: () -> Void

    var body: some View {
        let kind = curb.kind(filters: filters)
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(curb.streetLabel ?? curb.street).font(.headline)
                        Text(curb.side.map { "\($0.capitalized) side" } ?? "This side")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    if curb.canParkNow {
                        DirectionsButton(url: curb.drivingDirectionsURL, street: curb.street)
                    }
                    Button(action: onClose) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title)
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(.secondary)
                            .frame(width: 44, height: 44)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Close")
                    .accessibilityHint("Back to the nearest spots")
                }
                HStack(spacing: 6) {
                    Capsule().fill(Color(kind.color)).frame(width: 14, height: 5)
                    Text(curb.canParkNow ? kind.label(filtersActive: filters.isActive) : "No parking now")
                        .font(.subheadline.weight(.semibold))
                }
                .accessibilityElement(children: .combine)
                Text(curb.summary)
                if let schedule = curb.schedule {
                    Text(schedule).font(.subheadline).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
        }
    }
}

extension Blockface {
    var curbCoordinates: [CLLocationCoordinate2D]? { path.curbCoordinates }
}

extension Optional where Wrapped == [Coordinate] {
    /// Map coordinates for a curb line, or nil if there isn't a drawable one.
    var curbCoordinates: [CLLocationCoordinate2D]? {
        guard let self, self.count >= 2 else { return nil }
        return self.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) }
    }
}

extension Array where Element == Coordinate {
    /// Halfway along the line, or nil when it's empty.
    var midpoint: CLLocationCoordinate2D? {
        guard let first else { return nil }
        let path = self
        let fallback = CLLocationCoordinate2D(latitude: first.lat, longitude: first.lon)
        guard path.count >= 2 else { return fallback }
        let cosLat = cos(path[0].lat * .pi / 180)
        func length(_ a: Coordinate, _ b: Coordinate) -> Double {
            hypot(b.lat - a.lat, (b.lon - a.lon) * cosLat)
        }
        let total = zip(path, path.dropFirst()).reduce(0) { $0 + length($1.0, $1.1) }
        var remaining = total / 2
        for (a, b) in zip(path, path.dropFirst()) {
            let segment = length(a, b)
            if segment >= remaining, segment > 0 {
                let t = remaining / segment
                return CLLocationCoordinate2D(latitude: a.lat + (b.lat - a.lat) * t, longitude: a.lon + (b.lon - a.lon) * t)
            }
            remaining -= segment
        }
        return fallback
    }
}

/// Apple Maps driving directions to a point.
func appleMapsDrivingURL(to target: CLLocationCoordinate2D) -> URL {
    var components = URLComponents(string: "https://maps.apple.com/")!
    components.queryItems = [
        URLQueryItem(name: "daddr", value: String(format: "%.6f,%.6f", target.latitude, target.longitude)),
        URLQueryItem(name: "dirflg", value: "d"),
    ]
    return components.url!
}

extension AreaBlockface {
    /// Directions to the middle of the block side.
    var drivingDirectionsURL: URL {
        appleMapsDrivingURL(to: path.midpoint ?? CLLocationCoordinate2D(latitude: 47.6062, longitude: -122.3321))
    }
}

extension Spot {
    /// Halfway along this blockface's curb; the closest point (`coordinate`)
    /// when there's no curb line.
    var zoneCenter: CLLocationCoordinate2D {
        guard let path, path.count >= 2, let middle = path.midpoint else { return coordinate }
        return middle
    }

    /// This result as a map street side, so picking it in the list and
    /// tapping its line on the map select the same thing.
    var asCurb: AreaBlockface {
        AreaBlockface(street: street, streetLabel: streetLabel, side: side, summary: summary, schedule: schedule,
                      canParkNow: true, freeNow: freeNow, timeLimitMinutes: timeLimitMinutes,
                      postedLimitMinutes: postedLimitMinutes, restrictionInMinutes: restrictionInMinutes,
                      path: path ?? [point])
    }

    var curbCoordinates: [CLLocationCoordinate2D]? { path.curbCoordinates }

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: point.lat, longitude: point.lon)
    }

    /// Apple Maps driving directions to the middle of the block side. (The
    /// answer's mapsUrl is walking, to the nearest point.)
    var drivingDirectionsURL: URL { appleMapsDrivingURL(to: zoneCenter) }

    /// "350 ft north, east side"
    var distanceLabel: String {
        let feet = Measurement(value: Double(distanceMeters), unit: UnitLength.meters).converted(to: .feet).value
        let distance = feet < 1000 ? "\(Int((feet / 50).rounded() * 50)) ft" : String(format: "%.1f mi", feet / 5280)
        let sideText = side.map { ", \($0) side" } ?? ""
        return [distance, direction].compactMap { $0 }.joined(separator: " ") + sideText
    }
}
