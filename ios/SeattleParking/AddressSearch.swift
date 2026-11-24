import CoreLocation
import Foundation
import MapKit
import Observation

/// A place picked in the address search.
struct SearchedPlace {
    let name: String
    let coordinate: CLLocationCoordinate2D
}

enum AddressSearchError: LocalizedError {
    case notFound
    case outsideSeattle

    var errorDescription: String? {
        switch self {
        case .notFound: "Couldn't find that address in Seattle. Try a street address or a place name."
        case .outsideSeattle: "That's outside Seattle. Seattle Parking only knows the rules on Seattle streets."
        }
    }
}

/// Address and place search with Apple Maps (MapKit), limited to Seattle.
///
/// What the person types is sent to Apple to find matches, along with a fixed
/// area covering Seattle. The app doesn't add the person's location; parking
/// answers for the place found still come from the copy of the city's data on
/// the phone.
@MainActor @Observable
final class AddressSearch: NSObject, MKLocalSearchCompleterDelegate {
    /// Suggestions for what's typed so far.
    private(set) var suggestions: [MKLocalSearchCompletion] = []

    var query = "" {
        didSet {
            guard query != oldValue else { return }
            let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty {
                completer.cancel()
                suggestions = []
            } else {
                completer.queryFragment = text
            }
        }
    }

    @ObservationIgnored private let completer = MKLocalSearchCompleter()

    /// Roughly the city limits, padded a little.
    nonisolated static let seattleBounds = (minLat: 47.48, maxLat: 47.75, minLon: -122.46, maxLon: -122.22)

    nonisolated static var seattleRegion: MKCoordinateRegion {
        let b = seattleBounds
        return MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: (b.minLat + b.maxLat) / 2, longitude: (b.minLon + b.maxLon) / 2),
            span: MKCoordinateSpan(latitudeDelta: b.maxLat - b.minLat, longitudeDelta: b.maxLon - b.minLon))
    }

    nonisolated static func isInSeattle(_ c: CLLocationCoordinate2D) -> Bool {
        let b = seattleBounds
        return (b.minLat...b.maxLat).contains(c.latitude) && (b.minLon...b.maxLon).contains(c.longitude)
    }

    override init() {
        super.init()
        completer.delegate = self
        completer.region = Self.seattleRegion
        completer.regionPriority = .required
        completer.resultTypes = [.address, .pointOfInterest]
    }

    /// The place behind a suggestion. The request is left as MapKit builds it
    /// from the suggestion: changing its area or result types can turn it back
    /// into a plain text search, which finds a different place with a similar
    /// name. Of the matches, the one with the suggestion's name wins.
    func place(for completion: MKLocalSearchCompletion) async throws -> SearchedPlace {
        let items = try await mapItems(for: MKLocalSearch.Request(completion: completion))
        let title = completion.title.lowercased()
        let named = items.filter { ($0.name ?? "").lowercased() == title }
        return try best(of: named.isEmpty ? items : named, fallbackName: completion.title)
    }

    /// The best match for typed text (when Search is pressed without picking a suggestion).
    func place(matching text: String) async throws -> SearchedPlace {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = text
        return try await run(request, fallbackName: text)
    }

    private func run(_ request: MKLocalSearch.Request, fallbackName: String) async throws -> SearchedPlace {
        request.region = Self.seattleRegion
        request.regionPriority = .required
        request.resultTypes = [.address, .pointOfInterest]
        return try best(of: try await mapItems(for: request), fallbackName: fallbackName)
    }

    private func mapItems(for request: MKLocalSearch.Request) async throws -> [MKMapItem] {
        do {
            return try await MKLocalSearch(request: request).start().mapItems
        } catch let error as MKError where error.code == .placemarkNotFound {
            throw AddressSearchError.notFound
        }
    }

    /// The first match inside Seattle.
    private func best(of items: [MKMapItem], fallbackName: String) throws -> SearchedPlace {
        guard !items.isEmpty else { throw AddressSearchError.notFound }
        guard let item = items.first(where: { Self.isInSeattle($0.placemark.coordinate) }) else {
            throw AddressSearchError.outsideSeattle
        }
        return SearchedPlace(name: item.name ?? fallbackName, coordinate: item.placemark.coordinate)
    }

    // MARK: - MKLocalSearchCompleterDelegate (called on the main thread)

    nonisolated func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        MainActor.assumeIsolated {
            suggestions = Array(completer.results.prefix(8))
        }
    }

    nonisolated func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
        MainActor.assumeIsolated {
            suggestions = []
        }
    }
}
