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
            }
        }
        .padding(.vertical, 2)
    }
}

/// A search result with a driving-directions button.
struct SpotRow: View {
    let rank: Int
    let spot: Spot
    var kind: CurbLine.Kind? = nil
    @Environment(\.openURL) private var openURL

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Text("\(rank)")
                .font(.headline)
                .frame(width: 28, height: 28)
                .background(Circle().fill(Color((kind ?? spot.kind(stayingMinutes: nil)).color).opacity(0.3)))
            VStack(alignment: .leading, spacing: 2) {
                Text(spot.street).font(.subheadline.bold())
                Text(spot.summary).font(.subheadline)
                Text(spot.distanceLabel).font(.caption).foregroundStyle(.secondary)
            }
            // Separators start under the street name, not under the number.
            .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] }
            Spacer(minLength: 8)
            Button { openURL(spot.drivingDirectionsURL) } label: {
                Image(systemName: "arrow.triangle.turn.up.right.diamond.fill")
                    .font(.title3)
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(Circle().fill(Color.accentColor))
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Driving directions")
            .accessibilityHint(spot.street)
        }
        .padding(.vertical, 2)
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

extension Spot {
    /// Halfway along this blockface's curb, for placing its pin; the closest
    /// point (`coordinate`) when the server didn't send a curb line.
    var zoneCenter: CLLocationCoordinate2D {
        guard let path, path.count >= 2 else { return coordinate }
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
        return coordinate
    }

    var curbCoordinates: [CLLocationCoordinate2D]? { path.curbCoordinates }

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: point.lat, longitude: point.lon)
    }

    /// Apple Maps driving directions to the middle of the block side, where
    /// its pin is. (The server's mapsUrl is walking, to the nearest point.)
    var drivingDirectionsURL: URL {
        let target = zoneCenter
        var components = URLComponents(string: "https://maps.apple.com/")!
        components.queryItems = [
            URLQueryItem(name: "daddr", value: String(format: "%.6f,%.6f", target.latitude, target.longitude)),
            URLQueryItem(name: "dirflg", value: "d"),
        ]
        return components.url!
    }

    /// "350 ft north, east side"
    var distanceLabel: String {
        let feet = Measurement(value: Double(distanceMeters), unit: UnitLength.meters).converted(to: .feet).value
        let distance = feet < 1000 ? "\(Int((feet / 50).rounded() * 50)) ft" : String(format: "%.1f mi", feet / 5280)
        let sideText = side.map { ", \($0) side" } ?? ""
        return [distance, direction].compactMap { $0 }.joined(separator: " ") + sideText
    }
}
