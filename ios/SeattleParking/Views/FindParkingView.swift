import CoreLocation
import MapKit
import SwiftUI

/// The parking search, on its own screen: an address search, filters, a map
/// you can pan, and the results. The first search is around you; picking an
/// address searches around it, and after moving the map, "Search this area"
/// looks inside the visible region instead.
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
    /// The region the current results were searched in; when the map moves away
    /// from it, the "Search this area" button appears.
    @State private var searchedRegion: MKCoordinateRegion?
    @State private var mapMoved = false
    /// What the last search was centered on. Filter changes rerun it.
    @State private var lastOrigin: Origin = .me
    /// Set while the map moves for a search, so that move isn't taken as the
    /// user's. Camera stops elsewhere (an earlier move finishing) are ignored.
    @State private var pendingMove: MKCoordinateRegion?
    /// Bumped per search, so a slower earlier search can't overwrite a newer one.
    @State private var searchID = 0
    /// Index of the result picked on the map or in the list.
    @State private var selection: Int?
    @State private var area = AreaCurbs()
    /// Quantized zoom, so result lines only shift when the zoom changes noticeably.
    @State private var zoomStep: Int?

    @State private var addressSearch = AddressSearch()
    @State private var addressSearchShown = false
    /// The address picked in the search bar; shown as a pin and a chip.
    @State private var destination: SearchedPlace?

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
            results
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
        .onSubmit(of: .search) { Task { await pick(nil) } }
        .autocorrectionDisabled()
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

            if let destination {
                // Tapping it goes back to searching around you.
                Button { clearDestination() } label: {
                    FilterChip(title: destination.name, systemImage: "xmark", isOn: true)
                }
                .accessibilityLabel("Near \(destination.name)")
                .accessibilityHint("Search around you instead")
            }

            Spacer(minLength: 0)
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
        var pins: [ResultPin] = []
        if case .loaded(let answer) = nearby {
            for (index, spot) in answer.results.enumerated() {
                // Pins sit halfway along their block side so neighbors overlap less.
                let color = spot.kind(filters: filters).color
                pins.append(ResultPin(index: index, coordinate: spot.zoneCenter, color: color))
                guard let path = spot.path, path.count >= 2 else { continue }
                highlights.append(HighlightCurb(
                    coordinates: CurbLine.offset(path, side: spot.side, meters: shift),
                    color: color,
                    width: selection == index ? 6 : 4,
                    outlined: selection == index
                ))
            }
        }
        var key = Hasher()
        key.combine(pins.count)
        for pin in pins { key.combine(pin.coordinate.latitude); key.combine(pin.coordinate.longitude) }
        key.combine(selection)
        key.combine(zoomStep)
        key.combine(filters.stayingMinutes)
        key.combine(filters.freeOnly)

        return CurbMapView(
            area: area,
            highlights: highlights,
            highlightsKey: key.finalize(),
            pins: pins,
            destination: destination,
            selection: $selection,
            focus: focus,
            onRegionChange: { region, width in cameraSettled(region, width: width) }
        )
    }

    private func cameraSettled(_ region: MKCoordinateRegion, width: CGFloat) {
        visibleRegion = region
        let mpp = CurbLine.metersPerPoint(region, width: width)
        let step = CurbLine.zoomStep(mpp)
        if step != zoomStep { zoomStep = step }
        area.cameraSettled(region: region, metersPerPoint: mpp)
        if let target = pendingMove {
            // Only the stop where our own move lands counts as the searched
            // area. Before this, the first search's move to your location could
            // finish after the results arrived, and the fit to the results that
            // followed showed "Search this area" right away.
            if region.center.distance(to: target.center) <= max(target.halfDiagonalMeters * 0.1, 25) {
                pendingMove = nil
                searchedRegion = region
                mapMoved = false
            }
        } else if let searchedRegion {
            mapMoved = !region.isClose(to: searchedRegion)
        }
    }

    /// Moves the map for a search; the stop where it lands becomes the searched area.
    private func moveMap(to region: MKCoordinateRegion) {
        let id = (focus?.id ?? 0) + 1
        focus = MapFocus(id: id, region: region)
        pendingMove = region
        Task {
            // If the map never reports landing there (it was already there, or
            // the user grabbed it mid-move), stop waiting.
            try? await Task.sleep(for: .seconds(2))
            if focus?.id == id, pendingMove != nil {
                pendingMove = nil
                searchedRegion = visibleRegion
                mapMoved = false
            }
        }
    }

    @ViewBuilder
    private var searchAreaButton: some View {
        if mapMoved, !nearby.isLoading {
            Button {
                if let visibleRegion { Task { await search(.region(visibleRegion)) } }
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
                    SpotRow(rank: index + 1, spot: spot, kind: spot.kind(filters: filters))
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

    // MARK: - Address search

    /// Looks up a suggestion (or, with nil, the typed text) and searches around it.
    private func pick(_ suggestion: MKLocalSearchCompletion?) async {
        let text = addressSearch.query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard suggestion != nil || !text.isEmpty else { return }
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
            addressSearch.query = ""
            destination = place
            await search(.place(place))
        } catch {
            guard id == searchID else { return }
            nearby = .failed(addressErrorMessage(error))
        }
    }

    private func clearDestination() {
        destination = nil
        Task { await search(.me) }
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

    /// Searches around the user, a searched place, or inside a map region.
    private func search(_ origin: Origin) async {
        nearby = .loading
        searchID += 1
        let id = searchID
        do {
            let api = try ParkingAPI.fromSettings()
            let center: CLLocationCoordinate2D
            var radius: Int?
            switch origin {
            case .region(let region):
                let halfDiagonal = region.halfDiagonalMeters
                guard halfDiagonal <= Self.maxRadiusMeters * 2 else {
                    nearby = .failed("Zoom in to a few blocks to search this area.")
                    mapMoved = true
                    return
                }
                center = region.center
                radius = Int(min(max(halfDiagonal, 50), Self.maxRadiusMeters))
            case .place(let place):
                center = place.coordinate
                // Show the place while the results load.
                moveMap(to: MKCoordinateRegion(center: center, latitudinalMeters: 500, longitudinalMeters: 500))
            case .me:
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
            guard id == searchID else { return }
            SpotStore.shared.save(answer.results)
            selection = nil
            nearby = .loaded(answer)
            lastOrigin = origin
            mapMoved = false
            if case .region(let region) = origin {
                pendingMove = nil
                searchedRegion = region
            } else if !answer.results.isEmpty {
                // Fit the starting point and the results only. (.automatic would also
                // fit the street-color lines, which zoom the map out as they load.)
                let points = [center] + answer.results.flatMap { spot in
                    [spot.zoneCenter] + (spot.path ?? []).map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) }
                }
                moveMap(to: MKCoordinateRegion.fitting(points, minimumMeters: 300))
            } else if pendingMove == nil {
                searchedRegion = visibleRegion
            }
        } catch {
            guard id == searchID else { return }
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
            Text(title).lineLimit(1)
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
