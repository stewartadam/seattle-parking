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
    @Environment(\.openURL) private var openURL

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(rank)")
                .font(.headline)
                .frame(width: 28, height: 28)
                .background(Circle().fill((spot.freeNow ? Color.green : Color.orange).opacity(0.25)))
            VStack(alignment: .leading, spacing: 2) {
                Text(spot.street).font(.subheadline.bold())
                Text(spot.summary).font(.subheadline)
                Text(spot.distanceLabel).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button { openURL(spot.drivingDirectionsURL) } label: {
                Label("Go", systemImage: "car.fill")
                    .font(.subheadline.bold())
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
            .accessibilityLabel("Driving directions to \(spot.street)")
        }
        .padding(.vertical, 2)
    }
}

/// Drawing style shared by curb-line overlays.
enum CurbLine {
    static func style(width: CGFloat) -> StrokeStyle {
        StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round)
    }
}

/// The blocks you're on, drawn as their curb lines: green where you can park
/// now, red where you can't.
struct HereMap: View {
    let blockfaces: [Blockface]

    var body: some View {
        Map(initialPosition: .automatic, interactionModes: []) {
            UserAnnotation()
            ForEach(Array(blockfaces.enumerated()), id: \.offset) { _, blockface in
                if let curb = blockface.curbCoordinates {
                    MapPolyline(coordinates: curb)
                        .stroke(blockface.canParkNow ? Color.green : Color.red, style: CurbLine.style(width: 6))
                }
            }
        }
        // New data recreates the map so it fits the new lines.
        .id(blockfaces)
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
    var curbCoordinates: [CLLocationCoordinate2D]? { path.curbCoordinates }

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: point.lat, longitude: point.lon)
    }

    /// Apple Maps driving directions to the spot. (The server's mapsUrl is walking.)
    var drivingDirectionsURL: URL {
        var components = URLComponents(string: "https://maps.apple.com/")!
        components.queryItems = [
            URLQueryItem(name: "daddr", value: "\(point.lat),\(point.lon)"),
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
