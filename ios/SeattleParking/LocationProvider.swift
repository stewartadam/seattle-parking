import CoreLocation

/// One-shot current location for intents and the app.
enum LocationProvider {
    /// Returns the first reasonably accurate fix (under 65 m), or the best fix
    /// seen once `timeout` has passed.
    static func current(timeout: TimeInterval = 8) async throws -> CLLocationCoordinate2D {
        // Keeps when-in-use authorization valid while an intent runs in the
        // background on Siri's behalf.
        let session = CLServiceSession(authorization: .whenInUse)
        defer { session.invalidate() }

        let deadline = Date().addingTimeInterval(timeout)
        var best: CLLocation?
        for try await update in CLLocationUpdate.liveUpdates() {
            if update.authorizationDenied || update.authorizationDeniedGlobally {
                throw ParkingError.locationDenied
            }
            if let location = update.location, location.horizontalAccuracy >= 0 {
                if best == nil || location.horizontalAccuracy < best!.horizontalAccuracy { best = location }
                if location.horizontalAccuracy <= 65 { return location.coordinate }
            }
            if Date() > deadline { break }
        }
        if let best { return best.coordinate }
        throw ParkingError.noLocation
    }
}
