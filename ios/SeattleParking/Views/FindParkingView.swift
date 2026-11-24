import CoreLocation
import MapKit
import SwiftUI

/// The parking search, on its own screen: filters, a map you can pan, and the
/// results. The first search is around you; after moving the map, "Search this
/// area" looks inside the visible region instead. Tapping any street on the map
/// (or a result) shows that street side's rules in place of the list.
struct FindParkingView: View {
    @State private var minMinutes = 0
    @State private var freeOnly = false
    @State private var nearby: Loadable<NearbyResponse> = .idle
    /// Where the map should move to; set when a search starts and when results arrive.
    @State private var focus: MapFocus?
    @State private var visibleRegion: MKCoordinateRegion?
    /// The region the current results were searched in; when the map moves away
    /// from it, the "Search this area" button appears.
    @State private var searchedRegion: MKCoordinateRegion?
    @State private var mapMoved = false
    /// The area the last search used; nil means "around me". Filter changes rerun it.
    @State private var lastQueryRegion: MKCoordinateRegion?
    /// Set while the map zooms to fit fresh results, so that move isn't the user's.
    @State private var fittingResults = false
    /// The street side picked on the map or in the list; its rules replace the list.
    @State private var selected: AreaBlockface?
    @State private var area = AreaCurbs()
    /// Quantized zoom, so result lines only shift when the zoom changes noticeably.
    @State private var zoomStep: Int?

    /// Searches reach at most 1.5 km from the center point.
    private static let maxRadiusMeters = 1500.0

    var body: some View {
        VStack(spacing: 0) {
            filterBar
            ZStack(alignment: .top) {
                map
                searchAreaButton
            }
            .overlay(alignment: .bottomLeading) {
                if area.zoomedOutTooFar { ZoomInHint().allowsHitTesting(false) }
            }
            .frame(maxHeight: .infinity)
            Group {
                if let selected {
                    CurbDetail(curb: selected, filters: filters) { self.selected = nil }
                } else {
                    results
                }
            }
            .frame(maxHeight: .infinity)
        }
        .navigationTitle("Find Parking")
        .navigationBarTitleDisplayMode(.inline)
        .task { if case .idle = nearby { await search(in: nil) } }
        .onAppear { area.setFilters(filters) }
        .onChange(of: filters) {
            // Recolor right away; the search below refreshes the results.
            area.setFilters(filters)
            Task { await search(in: lastQueryRegion) }
        }
    }

    private var filters: CurbFilters {
        CurbFilters(stayingMinutes: minMinutes > 0 ? minMinutes : nil, freeOnly: freeOnly)
    }

    // MARK: - Pieces

    private var filterBar: some View {
        HStack(spacing: 12) {
            Menu {
                Picker("Staying for", selection: $minMinutes) {
                    Text("Any time").tag(0)
                    Text("1 hour").tag(60)
                    Text("2 hours").tag(120)
                    Text("4 hours").tag(240)
                }
            } label: {
                FilterChip(
                    title: minMinutes == 0 ? "Any time" : "\(minMinutes / 60)+ hours",
                    systemImage: minMinutes == 0 ? "clock" : "checkmark",
                    isOn: minMinutes > 0,
                    isMenu: true
                )
            }
            .accessibilityLabel("Staying for")
            .accessibilityValue(minMinutes == 0 ? "Any time" : "\(minMinutes / 60) hours or more")

            Button { freeOnly.toggle() } label: {
                FilterChip(title: "Free only", systemImage: freeOnly ? "checkmark" : "dollarsign", isOn: freeOnly)
            }
            .accessibilityAddTraits(freeOnly ? .isSelected : [])

            Spacer()
        }
        .padding(.horizontal)
        .padding(.top, 8)
        .padding(.bottom, 4)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            CurbLegend(filtersActive: filters.isActive)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal)
                .padding(.bottom, 6)
        }
    }

    private var map: some View {
        let shift = zoomStep.map(CurbLine.shiftMeters(step:)) ?? 0
        let filters = filters
        var highlights: [HighlightCurb] = []
        var key = Hasher()
        if case .loaded(let answer) = nearby {
            // The results' streets, a little heavier than the rest.
            for spot in answer.results {
                guard let path = spot.path, path.count >= 2, spot.asCurb.id != selected?.id else { continue }
                highlights.append(HighlightCurb(
                    coordinates: CurbLine.offset(path, side: spot.side, meters: shift),
                    color: spot.kind(filters: filters).color,
                    width: 4
                ))
                key.combine(spot.asCurb.id)
            }
        }
        // The picked street on top, outlined.
        if let selected, selected.path.count >= 2 {
            highlights.append(HighlightCurb(
                coordinates: CurbLine.offset(selected.path, side: selected.side, meters: shift),
                color: selected.kind(filters: filters).color,
                width: 6,
                outlined: true
            ))
        }
        key.combine(selected?.id)
        key.combine(zoomStep)
        key.combine(filters.stayingMinutes)
        key.combine(filters.freeOnly)

        return CurbMapView(
            area: area,
            highlights: highlights,
            highlightsKey: key.finalize(),
            focus: focus,
            onTapCurb: { curb in withAnimation(.snappy) { selected = curb } },
            selectedCurbID: selected?.id,
            onRegionChange: { region, width in cameraSettled(region, width: width) }
        )
    }

    private func cameraSettled(_ region: MKCoordinateRegion, width: CGFloat) {
        visibleRegion = region
        let mpp = CurbLine.metersPerPoint(region, width: width)
        let step = CurbLine.zoomStep(mpp)
        if step != zoomStep { zoomStep = step }
        area.cameraSettled(region: region, metersPerPoint: mpp)
        if fittingResults {
            fittingResults = false
            searchedRegion = region
            mapMoved = false
        } else if let searchedRegion {
            mapMoved = !region.isClose(to: searchedRegion)
        }
    }

    private func moveMap(to region: MKCoordinateRegion) {
        focus = MapFocus(id: (focus?.id ?? 0) + 1, region: region)
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
            List {
                Section {
                    ForEach(Array(answer.results.enumerated()), id: \.offset) { _, spot in
                        SpotRow(spot: spot, kind: spot.kind(filters: filters))
                            .contentShape(Rectangle())
                            .onTapGesture { select(spot) }
                            .accessibilityAddTraits(.isButton)
                            .accessibilityHint("Shows this street's rules")
                    }
                } header: {
                    Label("Tap any street on the map to see its rules", systemImage: "hand.tap")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textCase(nil)
                }
            }
            .listStyle(.plain)
        }
    }

    /// Picks a result: shows its rules, and brings it into view if it's off the map.
    private func select(_ spot: Spot) {
        withAnimation(.snappy) { selected = spot.asCurb }
        if let visibleRegion, !visibleRegion.contains(spot.zoneCenter) {
            moveMap(to: MKCoordinateRegion(center: spot.zoneCenter, span: visibleRegion.span))
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
                if focus == nil { moveMap(to: MKCoordinateRegion(center: center, latitudinalMeters: 500, longitudinalMeters: 500)) }
            }
            let answer = try await api.nearby(
                center,
                minMinutes: minMinutes > 0 ? minMinutes : nil,
                freeOnly: freeOnly,
                limit: 10,
                radiusMeters: radius
            )
            SpotStore.shared.save(answer.results)
            nearby = .loaded(answer)
            lastQueryRegion = region
            searchedRegion = region ?? visibleRegion
            mapMoved = false
            if region == nil, !answer.results.isEmpty {
                // Fit the user and the results only. (.automatic would also fit the
                // street-color lines, which zoom the map out as they load.)
                let points = [center] + answer.results.flatMap { spot in
                    [spot.zoneCenter] + (spot.path ?? []).map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) }
                }
                fittingResults = true
                moveMap(to: MKCoordinateRegion.fitting(points, minimumMeters: 300))
                try? await Task.sleep(for: .seconds(1.5))
                fittingResults = false
            }
        } catch {
            nearby = .failed(errorMessage(error))
        }
    }
}

/// A filter pill: filled accent with white text when on, gray when off.
private struct FilterChip: View {
    let title: String
    let systemImage: String
    let isOn: Bool
    var isMenu = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage).imageScale(.small)
            Text(title)
            if isMenu { Image(systemName: "chevron.down").imageScale(.small) }
        }
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(isOn ? Color.white : Color.primary)
        .padding(.horizontal, 14)
        .frame(minHeight: 36)
        .background(Capsule().fill(isOn ? Color.accentColor : Color(.secondarySystemFill)))
        .overlay(Capsule().strokeBorder(isOn ? Color.clear : Color(.separator), lineWidth: 1))
        .contentShape(Capsule())
        .animation(.snappy, value: isOn)
    }
}

extension MKCoordinateRegion {
    func contains(_ c: CLLocationCoordinate2D) -> Bool {
        abs(c.latitude - center.latitude) <= span.latitudeDelta / 2
            && abs(c.longitude - center.longitude) <= span.longitudeDelta / 2
    }

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
