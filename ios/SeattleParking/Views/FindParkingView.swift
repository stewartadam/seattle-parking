import CoreLocation
import MapKit
import SwiftUI

/// The parking search, on its own screen: filters, a map you can pan, and the
/// results. The first search is around you; after moving the map, "Search this
/// area" looks inside the visible region instead.
struct FindParkingView: View {
    @State private var minMinutes = 0
    @State private var freeOnly = false
    @State private var nearby: Loadable<NearbyResponse> = .idle
    @State private var position: MapCameraPosition = .userLocation(fallback: .automatic)
    @State private var visibleRegion: MKCoordinateRegion?
    /// The region the current results were searched in; when the map moves away
    /// from it, the "Search this area" button appears.
    @State private var searchedRegion: MKCoordinateRegion?
    @State private var mapMoved = false
    /// The area the last search used; nil means "around me". Filter changes rerun it.
    @State private var lastQueryRegion: MKCoordinateRegion?
    /// Set while the map zooms to fit fresh results, so that move isn't the user's.
    @State private var fittingResults = false
    /// Index of the result picked on the map or in the list.
    @State private var selection: Int?

    /// The server searches at most 1.5 km from the center point.
    private static let maxRadiusMeters = 1500.0

    var body: some View {
        VStack(spacing: 0) {
            filters
            ZStack(alignment: .top) {
                map
                searchAreaButton
            }
            .frame(maxHeight: .infinity)
            results
                .frame(maxHeight: .infinity)
        }
        .navigationTitle("Find Parking")
        .navigationBarTitleDisplayMode(.inline)
        .task { if case .idle = nearby { await search(in: nil) } }
        .onChange(of: minMinutes) { Task { await search(in: lastQueryRegion) } }
        .onChange(of: freeOnly) { Task { await search(in: lastQueryRegion) } }
    }

    // MARK: - Pieces

    private var filters: some View {
        HStack(spacing: 12) {
            Menu {
                Picker("Staying for", selection: $minMinutes) {
                    Text("Any time").tag(0)
                    Text("1 hour").tag(60)
                    Text("2 hours").tag(120)
                    Text("4 hours").tag(240)
                }
            } label: {
                Label(minMinutes == 0 ? "Any time" : "\(minMinutes / 60)+ hr", systemImage: "clock")
            }
            .buttonStyle(.bordered)

            Toggle(isOn: $freeOnly) { Label("Free only", systemImage: "dollarsign.circle") }
                .toggleStyle(.button)
                .buttonStyle(.bordered)

            Spacer()
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    private var map: some View {
        Map(position: $position, selection: $selection) {
            UserAnnotation()
            if case .loaded(let answer) = nearby {
                // Curb lines first so the pins sit on top. The selected one gets a
                // white outline and a heavier line.
                ForEach(Array(answer.results.enumerated()), id: \.offset) { index, spot in
                    if let curb = spot.curbCoordinates {
                        if selection == index {
                            MapPolyline(coordinates: curb).stroke(.white, style: CurbLine.style(width: 12))
                        }
                        MapPolyline(coordinates: curb)
                            .stroke(spot.freeNow ? Color.green : Color.orange,
                                    style: CurbLine.style(width: selection == index ? 8 : 5))
                    }
                }
                ForEach(Array(answer.results.enumerated()), id: \.offset) { index, spot in
                    Marker(spot.street, monogram: Text("\(index + 1)"), coordinate: spot.coordinate)
                        .tint(spot.freeNow ? .green : .orange)
                        .tag(index)
                }
            }
        }
        .mapControls { MapUserLocationButton() }
        .onMapCameraChange(frequency: .onEnd) { context in
            visibleRegion = context.region
            if fittingResults {
                fittingResults = false
                searchedRegion = context.region
                mapMoved = false
            } else if let searchedRegion {
                mapMoved = !context.region.isClose(to: searchedRegion)
            }
        }
    }

    @ViewBuilder
    private var searchAreaButton: some View {
        if mapMoved, !nearby.isLoading {
            Button {
                Task { await search(in: visibleRegion) }
            } label: {
                Label("Search this area", systemImage: "magnifyingglass")
                    .font(.subheadline.bold())
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
            .shadow(radius: 4)
            .padding(.top, 12)
        }
    }

    @ViewBuilder
    private var results: some View {
        switch nearby {
        case .idle, .loading:
            ProgressView("Finding parking…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
            ContentUnavailableView("Couldn't search", systemImage: "exclamationmark.triangle", description: Text(message))
        case .loaded(let answer) where answer.results.isEmpty:
            ContentUnavailableView("No parking found", systemImage: "car", description: Text(answer.speech))
        case .loaded(let answer):
            ScrollViewReader { proxy in
                List(Array(answer.results.enumerated()), id: \.offset) { index, spot in
                    SpotRow(rank: index + 1, spot: spot)
                        .contentShape(Rectangle())
                        .onTapGesture { selection = index }
                        .listRowBackground(selection == index ? Color.accentColor.opacity(0.15) : nil)
                }
                .listStyle(.plain)
                .onChange(of: selection) {
                    guard let selection else { return }
                    withAnimation { proxy.scrollTo(selection, anchor: .center) }
                }
            }
        }
    }

    // MARK: - Search

    /// Searches around the user (region nil) or inside a map region.
    private func search(in region: MKCoordinateRegion?) async {
        nearby = .loading
        do {
            let api = try ParkingAPI.fromSettings()
            let center: CLLocationCoordinate2D
            var radius: Int?
            if let region {
                let halfDiagonal = region.halfDiagonalMeters
                guard halfDiagonal <= Self.maxRadiusMeters * 2 else {
                    nearby = .failed("Zoom in to a few blocks to search this area.")
                    mapMoved = true
                    return
                }
                center = region.center
                radius = Int(min(max(halfDiagonal, 50), Self.maxRadiusMeters))
            } else {
                center = try await LocationProvider.current()
            }
            let answer = try await api.nearby(
                center,
                minMinutes: minMinutes > 0 ? minMinutes : nil,
                freeOnly: freeOnly,
                limit: 10,
                radiusMeters: radius
            )
            SpotStore.shared.save(answer.results)
            selection = nil
            nearby = .loaded(answer)
            lastQueryRegion = region
            searchedRegion = region ?? visibleRegion
            mapMoved = false
            if region == nil, !answer.results.isEmpty {
                // Fit the user and the pins; the camera callback records the fitted region.
                fittingResults = true
                withAnimation { position = .automatic }
                try? await Task.sleep(for: .seconds(1.5))
                fittingResults = false
            }
        } catch {
            nearby = .failed(errorMessage(error))
        }
    }
}

extension MKCoordinateRegion {
    /// Distance from the center to a corner, in meters.
    var halfDiagonalMeters: Double {
        let corner = CLLocation(
            latitude: center.latitude + span.latitudeDelta / 2,
            longitude: center.longitude + span.longitudeDelta / 2
        )
        return CLLocation(latitude: center.latitude, longitude: center.longitude).distance(from: corner)
    }

    /// True when the regions overlap closely enough that searching again is pointless.
    func isClose(to other: MKCoordinateRegion) -> Bool {
        let shift = CLLocation(latitude: center.latitude, longitude: center.longitude)
            .distance(from: CLLocation(latitude: other.center.latitude, longitude: other.center.longitude))
        let zoom = span.latitudeDelta / max(other.span.latitudeDelta, .ulpOfOne)
        return shift < other.halfDiagonalMeters * 0.25 && zoom > 0.7 && zoom < 1.4
    }
}
