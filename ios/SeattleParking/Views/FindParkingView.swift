import CoreLocation
import MapKit
import SwiftUI

/// The parking search, on its own screen: an address search, filters, a map
/// you can pan, and the results. The first search is around you; picking an
/// address searches around it, and once you move the map, the list follows
/// the middle of the map. Tapping any street on the map
/// (or a result) shows that street side's rules in place of the list.
struct FindParkingView: View {
    /// Where a search is centered.
    enum Origin {
        case me
        case place(SearchedPlace)
        case region(MKCoordinateRegion)
    }

    @State private var minMinutes = 0
    @State private var freeOnly = false
    @State private var nearby: Loadable<NearbyResponse> = .idle
    /// Where the map should move to; set when a search starts and when results arrive.
    @State private var focus: MapFocus?
    @State private var visibleRegion: MKCoordinateRegion?
    /// Off until the first search has answered, so the map's initial moves
    /// don't replace it.
    @State private var followMap = false
    /// What the last search was centered on. Filter changes rerun it.
    @State private var lastOrigin: Origin = .me
    /// Set while the map moves on its own (for a search or a picked result), so
    /// that move doesn't refresh the list. Camera stops elsewhere (an earlier
    /// move finishing) still count as the user's.
    @State private var pendingMove: MKCoordinateRegion?
    /// Bumped per search, so a slower earlier search can't overwrite a newer one.
    @State private var searchID = 0
    /// The street side picked on the map or in the list; its rules replace the list.
    @State private var selected: AreaBlockface?
    @State private var area = AreaCurbs()
    /// Quantized zoom, so result lines only shift when the zoom changes noticeably.
    @State private var zoomStep: Int?
    /// Why the search started downtown instead of where you are, if it did.
    @State private var startNote: String?

    @State private var addressSearch = AddressSearch()
    @State private var addressSearchShown = false
    /// When a suggestion was last tapped, so a Search submit right after it is ignored.
    @State private var suggestionPickedAt: Date?
    /// The address picked in the search bar; shown as a pin. Clearing the
    /// search field removes it.
    @State private var destination: SearchedPlace?

    /// Searches reach at most 1.5 km from the center point.
    private static let maxRadiusMeters = 1500.0

    var body: some View {
        VStack(spacing: 0) {
            filterBar
            if let startNote { StartNote(text: startNote) }
            map
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
        .searchable(
            text: $addressSearch.query,
            isPresented: $addressSearchShown,
            placement: .navigationBarDrawer(displayMode: .always),
            prompt: "Search an address or place"
        )
        .searchSuggestions {
            ForEach(Array(addressSearch.suggestions.enumerated()), id: \.offset) { _, suggestion in
                Button {
                    suggestionPickedAt = Date()
                    Task { await pick(suggestion) }
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(suggestion.title).foregroundStyle(Color.primary)
                        if !suggestion.subtitle.isEmpty {
                            Text(suggestion.subtitle).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .onSubmit(of: .search) {
            // A tap on a suggestion can also submit the field; the suggestion wins.
            if let picked = suggestionPickedAt, Date().timeIntervalSince(picked) < 1 { return }
            Task { await pick(nil) }
        }
        .autocorrectionDisabled()
        .onChange(of: addressSearch.query) {
            if addressSearch.query.isEmpty { destination = nil }
        }
        .task { if case .idle = nearby { await search(.me) } }
        .onAppear { area.setFilters(filters) }
        .onChange(of: filters) {
            // Recolor right away; the search below refreshes the results.
            area.setFilters(filters)
            Task { await search(lastOrigin) }
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
            destination: destination,
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
        if let target = pendingMove,
           region.center.distance(to: target.center) <= max(target.halfDiagonalMeters * 0.1, 25) {
            // Our own move landed; the list already matches it.
            pendingMove = nil
            return
        }
        guard followMap else { return }
        // The user moved the map: re-rank the list from its center. Wait a
        // moment so a quick series of drags only searches once.
        searchID += 1
        let id = searchID
        Task {
            try? await Task.sleep(for: .milliseconds(250))
            guard id == searchID else { return }
            if let back = await SeattleArea.pulledBackToStreets(region) {
                // No streets in view: slide back to the nearest ones. The list
                // follows once the map lands there.
                guard id == searchID else { return }
                focus = MapFocus(id: (focus?.id ?? 0) + 1, region: back)
                return
            }
            await search(.region(region))
        }
    }

    /// Moves the map without refreshing the list when it lands.
    private func moveMap(to region: MKCoordinateRegion) {
        let id = (focus?.id ?? 0) + 1
        focus = MapFocus(id: id, region: region)
        pendingMove = region
        Task {
            // If the map never reports landing there (it was already there, or
            // the user grabbed it mid-move), stop waiting.
            try? await Task.sleep(for: .seconds(2))
            if focus?.id == id { pendingMove = nil }
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

    // MARK: - Address search

    /// Looks up a suggestion (or, with nil, the typed text) and searches around it.
    private func pick(_ suggestion: MKLocalSearchCompletion?) async {
        let text = addressSearch.query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard suggestion != nil || !text.isEmpty else { return }
        // Closing the search bar resizes the map, and that camera stop must not
        // start a map-center search that would drop this lookup's result.
        followMap = false
        addressSearchShown = false
        nearby = .loading
        searchID += 1
        let id = searchID
        do {
            let place: SearchedPlace
            if let suggestion {
                place = try await addressSearch.place(for: suggestion)
            } else {
                place = try await addressSearch.place(matching: text)
            }
            guard id == searchID else { return }
            destination = place
            addressSearch.show(place)
            await search(.place(place))
        } catch {
            guard id == searchID else { return }
            followMap = true
            nearby = .failed(addressErrorMessage(error))
        }
    }

    private func addressErrorMessage(_ error: Error) -> String {
        if error is AddressSearchError { return error.localizedDescription }
        if let error = error as? MKError, error.code == .serverFailure || error.code == .loadingThrottled {
            return "Apple Maps couldn't search right now. Try again in a moment."
        }
        if (error as NSError).domain == NSURLErrorDomain {
            return "Searching for an address needs an internet connection."
        }
        return "Couldn't search for that address. Try again in a moment."
    }

    // MARK: - Search

    /// Searches around the user, a searched place, or from the middle of the map.
    private func search(_ origin: Origin) async {
        // Following the map keeps the old list up until the new one is ready.
        if case .region = origin {} else { nearby = .loading }
        searchID += 1
        let id = searchID
        do {
            let api = try ParkingAPI.fromSettings()
            let center: CLLocationCoordinate2D
            var radius: Int?
            switch origin {
            case .region(let region):
                // Zoomed far out, this still finds the closest spots to the middle.
                center = region.center
                radius = Int(min(max(region.halfDiagonalMeters, 50), Self.maxRadiusMeters))
            case .place(let place):
                center = place.coordinate
                startNote = nil
                // Show the place while the results load.
                moveMap(to: MKCoordinateRegion(center: center, latitudinalMeters: 500, longitudinalMeters: 500))
            case .me:
                let start = await startingPoint()
                center = start.center
                startNote = start.note
                if focus == nil { moveMap(to: MKCoordinateRegion(center: center, latitudinalMeters: 500, longitudinalMeters: 500)) }
            }
            let answer = try await api.nearby(
                center,
                minMinutes: minMinutes > 0 ? minMinutes : nil,
                freeOnly: freeOnly,
                limit: 10,
                radiusMeters: radius
            )
            guard id == searchID else { return }
            nearby = .loaded(answer)
            lastOrigin = origin
            followMap = true
            if case .region = origin {
                // The map is already where the user put it.
            } else if !answer.results.isEmpty {
                // Fit the starting point and the results only. (.automatic would also
                // fit the street-color lines, which zoom the map out as they load.)
                var points = [center] + answer.results.flatMap { spot in
                    [spot.zoneCenter] + (spot.path ?? []).map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) }
                }
                if case .place = origin {
                    // Keep the searched place in the middle: mirror every point around it.
                    points += points.map {
                        CLLocationCoordinate2D(latitude: 2 * center.latitude - $0.latitude,
                                               longitude: 2 * center.longitude - $0.longitude)
                    }
                }
                moveMap(to: MKCoordinateRegion.fitting(points, minimumMeters: 300))
            }
        } catch {
            guard id == searchID else { return }
            followMap = true
            nearby = .failed(errorMessage(error))
        }
    }
}

extension FindParkingView {
    /// Where a search "around me" starts: your location when you're in Seattle,
    /// otherwise downtown, with a note saying why. The app only has Seattle's
    /// data, so a search anywhere else would come back empty.
    func startingPoint() async -> (center: CLLocationCoordinate2D, note: String?) {
        do {
            let here = try await LocationProvider.current()
            if SeattleArea.contains(here) { return (here, nil) }
            return (SeattleArea.downtown, "You're outside Seattle, so this starts downtown. Seattle Parking only covers the City of Seattle.")
        } catch {
            return (SeattleArea.downtown, "Couldn't get your location, so this starts downtown. Seattle Parking only covers the City of Seattle.")
        }
    }
}

/// A one-line banner above the map explaining why it isn't showing your location.
private struct StartNote: View {
    let text: String

    var body: some View {
        Label(text, systemImage: "location.slash")
            .font(.footnote)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal)
            .padding(.vertical, 8)
            .background(Color(.secondarySystemBackground))
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

extension CLLocationCoordinate2D {
    /// Distance in meters.
    func distance(to other: CLLocationCoordinate2D) -> Double {
        CLLocation(latitude: latitude, longitude: longitude)
            .distance(from: CLLocation(latitude: other.latitude, longitude: other.longitude))
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
}
