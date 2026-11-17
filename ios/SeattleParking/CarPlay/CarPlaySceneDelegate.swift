import CarPlay
import CoreLocation
import MapKit
import UIKit

/// The CarPlay screen: Apple's point-of-interest map with the closest parking
/// pinned in the same colors as the phone's street map (green = free,
/// yellow = restrictions, red = no parking; with a stay length chosen,
/// green-yellow = OK for your stay). Tapping a pin shows its rules and a
/// Directions button that hands off to Maps.
///
/// Runs only once Apple grants the CarPlay Parking entitlement
/// (com.apple.developer.carplay-parking); see ios/README.md.
@MainActor
final class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate, CPPointOfInterestTemplateDelegate {
    /// CarPlay shows at most 12 points of interest.
    private static let maxSpots = 12
    /// The server searches at most 1.5 km from the center point.
    private static let maxRadiusMeters = 1500.0

    private var scene: CPTemplateApplicationScene?
    private var interfaceController: CPInterfaceController?
    private var template: CPPointOfInterestTemplate?
    private var searchTask: Task<Void, Never>?
    /// The map region the driver last scrolled to, for "Search Here".
    private var visibleRegion: MKCoordinateRegion?
    private var stayingMinutes: Int?

    private var filters: CurbFilters { CurbFilters(stayingMinutes: stayingMinutes) }

    // MARK: - Scene

    func templateApplicationScene(_ templateApplicationScene: CPTemplateApplicationScene,
                                  didConnect interfaceController: CPInterfaceController) {
        scene = templateApplicationScene
        self.interfaceController = interfaceController

        let template = CPPointOfInterestTemplate(title: "Parking", pointsOfInterest: [], selectedIndex: NSNotFound)
        template.pointOfInterestDelegate = self
        self.template = template
        updateButtons()
        interfaceController.setRootTemplate(template, animated: false, completion: nil)
        search(in: nil)
    }

    func templateApplicationScene(_ templateApplicationScene: CPTemplateApplicationScene,
                                  didDisconnectInterfaceController interfaceController: CPInterfaceController) {
        searchTask?.cancel()
        searchTask = nil
        template = nil
        self.interfaceController = nil
        scene = nil
    }

    // MARK: - Map

    func pointOfInterestTemplate(_ pointOfInterestTemplate: CPPointOfInterestTemplate,
                                 didChangeMapRegion region: MKCoordinateRegion) {
        visibleRegion = region
    }

    func pointOfInterestTemplate(_ pointOfInterestTemplate: CPPointOfInterestTemplate,
                                 didSelectPointOfInterest pointOfInterest: CPPointOfInterest) {}

    // MARK: - Buttons

    private func updateButtons() {
        let stay = CPBarButton(title: stayingMinutes.map { "\($0 / 60)+ hr" } ?? "Any time") { [weak self] _ in
            self?.chooseStay()
        }
        let here = CPBarButton(title: "Search Here") { [weak self] _ in
            guard let self else { return }
            self.search(in: self.visibleRegion)
        }
        let nearMe = CPBarButton(image: UIImage(systemName: "location.fill")!) { [weak self] _ in
            self?.search(in: nil)
        }
        template?.leadingNavigationBarButtons = [stay]
        template?.trailingNavigationBarButtons = [nearMe, here]
    }

    private func chooseStay() {
        let choices: [(String, Int?)] = [("Any time", nil), ("1 hour", 60), ("2 hours", 120), ("4 hours", 240)]
        let actions = choices.map { title, minutes in
            CPAlertAction(title: title, style: minutes == stayingMinutes ? .cancel : .default) { [weak self] _ in
                guard let self else { return }
                self.interfaceController?.dismissTemplate(animated: true, completion: nil)
                guard minutes != self.stayingMinutes else { return }
                self.stayingMinutes = minutes
                self.updateButtons()
                self.search(in: self.lastQueryRegion)
            }
        }
        let sheet = CPActionSheetTemplate(title: "Staying for", message: nil, actions: actions)
        interfaceController?.presentTemplate(sheet, animated: true, completion: nil)
    }

    // MARK: - Search

    /// The area the last search used; nil means around the car.
    private var lastQueryRegion: MKCoordinateRegion?

    private func search(in region: MKCoordinateRegion?) {
        searchTask?.cancel()
        searchTask = Task { [weak self] in
            await self?.runSearch(in: region)
        }
    }

    private func runSearch(in region: MKCoordinateRegion?) async {
        template?.setPointsOfInterest([], selectedIndex: NSNotFound)
        template?.title = "Finding parking…"
        do {
            let api = try ParkingAPI.fromSettings()
            let center: CLLocationCoordinate2D
            var radius: Int?
            if let region {
                let halfDiagonal = region.halfDiagonalMeters
                guard halfDiagonal <= Self.maxRadiusMeters * 2 else {
                    template?.title = "Parking"
                    showMessage("Zoom in to a few blocks to search this area.")
                    return
                }
                center = region.center
                radius = Int(min(max(halfDiagonal, 50), Self.maxRadiusMeters))
            } else {
                center = try await LocationProvider.current()
            }
            let answer = try await api.nearby(
                center,
                minMinutes: stayingMinutes,
                limit: Self.maxSpots,
                radiusMeters: radius
            )
            guard !Task.isCancelled else { return }
            lastQueryRegion = region
            SpotStore.shared.save(answer.results)
            template?.title = "Parking"
            if answer.results.isEmpty {
                showMessage(answer.speech)
                return
            }
            let points = answer.results.prefix(Self.maxSpots).enumerated().map { index, spot in
                pointOfInterest(for: spot, rank: index + 1)
            }
            template?.setPointsOfInterest(points, selectedIndex: NSNotFound)
        } catch {
            guard !Task.isCancelled else { return }
            template?.title = "Parking"
            showMessage(errorMessage(error))
        }
    }

    private func pointOfInterest(for spot: Spot, rank: Int) -> CPPointOfInterest {
        let kind = spot.kind(filters: filters)
        let item = MKMapItem(placemark: MKPlacemark(coordinate: spot.zoneCenter))
        item.name = spot.displayStreet
        let point = CPPointOfInterest(
            location: item,
            title: spot.displayStreet,
            subtitle: spot.summary,
            summary: spot.distanceLabel,
            detailTitle: spot.displayStreet,
            detailSubtitle: spot.summary,
            detailSummary: [spot.schedule, spot.distanceLabel].compactMap { $0 }.joined(separator: "\n"),
            pinImage: Self.pinImage(rank: rank, color: kind.color, selected: false),
            selectedPinImage: Self.pinImage(rank: rank, color: kind.color, selected: true)
        )
        let url = spot.drivingDirectionsURL
        point.primaryButton = CPTextButton(title: "Directions", textStyle: .confirm) { [weak self] _ in
            self?.scene?.open(url, options: nil, completionHandler: nil)
        }
        return point
    }

    private func showMessage(_ message: String) {
        guard let interfaceController else { return }
        let alert = CPAlertTemplate(titleVariants: [message], actions: [
            CPAlertAction(title: "OK", style: .cancel) { [weak interfaceController] _ in
                interfaceController?.dismissTemplate(animated: true, completion: nil)
            },
        ])
        // Only one modal at a time: replace any sheet or earlier message.
        if interfaceController.presentedTemplate != nil {
            interfaceController.dismissTemplate(animated: false, completion: nil)
        }
        interfaceController.presentTemplate(alert, animated: true, completion: nil)
    }

    // MARK: - Pins

    /// A colored disc with the result's rank, like the phone's map pins.
    private static func pinImage(rank: Int, color: UIColor, selected: Bool) -> UIImage {
        let size: CGFloat = selected ? 34 : 26
        let format = UIGraphicsImageRendererFormat()
        format.scale = 3
        return UIGraphicsImageRenderer(size: CGSize(width: size, height: size), format: format).image { _ in
            let rect = CGRect(x: 0, y: 0, width: size, height: size).insetBy(dx: 1.5, dy: 1.5)
            let disc = UIBezierPath(ovalIn: rect)
            color.setFill()
            disc.fill()
            UIColor.white.setStroke()
            disc.lineWidth = selected ? 3 : 2
            disc.stroke()

            let text = "\(rank)" as NSString
            let attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: size * 0.5, weight: .bold),
                .foregroundColor: UIColor.black,
            ]
            let textSize = text.size(withAttributes: attributes)
            text.draw(at: CGPoint(x: (size - textSize.width) / 2, y: (size - textSize.height) / 2), withAttributes: attributes)
        }
    }
}
