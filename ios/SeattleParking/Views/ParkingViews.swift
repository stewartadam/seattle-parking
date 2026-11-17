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

/// A search result with a walking-directions button.
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
            if let url = URL(string: spot.mapsUrl) {
                Button { openURL(url) } label: {
                    Image(systemName: "figure.walk.circle.fill").font(.title)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Walking directions")
            }
        }
        .padding(.vertical, 2)
    }
}

/// Search results as numbered pins: green is free right now, orange is paid.
struct SpotsMap: View {
    let spots: [Spot]

    var body: some View {
        Map(initialPosition: .automatic) {
            UserAnnotation()
            ForEach(Array(spots.enumerated()), id: \.offset) { index, spot in
                Marker(
                    spot.street,
                    monogram: Text("\(index + 1)"),
                    coordinate: CLLocationCoordinate2D(latitude: spot.point.lat, longitude: spot.point.lon)
                )
                .tint(spot.freeNow ? .green : .orange)
            }
        }
        .mapControls { MapUserLocationButton() }
        // A new search recreates the map so it zooms to fit the new pins.
        .id(spots)
    }
}

extension Spot {
    /// "350 ft north, east side"
    var distanceLabel: String {
        let feet = Measurement(value: Double(distanceMeters), unit: UnitLength.meters).converted(to: .feet).value
        let distance = feet < 1000 ? "\(Int((feet / 50).rounded() * 50)) ft" : String(format: "%.1f mi", feet / 5280)
        let sideText = side.map { ", \($0) side" } ?? ""
        return [distance, direction].compactMap { $0 }.joined(separator: " ") + sideText
    }
}
