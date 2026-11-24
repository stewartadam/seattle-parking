import Foundation

// The three questions the app answers, ported from src/parking.js:
//   here()   "What are the parking rules where I am?"
//   nearby() "Where's the nearest place I can park?"
//   area()   every block side around a point, for coloring the map
// The data comes from a ParkingDataSource: the copy of the city's data
// downloaded to the phone.

/// One blockface near a point.
struct NearbyBlockface: Sendable {
    let rules: BlockfaceRules
    /// Each path a flat [lon, lat, lon, lat, ...] array.
    let paths: [[Double]]
    let distance: Double
    let point: Coordinate

    /// The curb line, for drawing on a map.
    var curbLine: [Coordinate] {
        paths.flatMap { path in
            stride(from: 0, to: path.count - 1, by: 2).map {
                Coordinate(lat: round6(path[$0 + 1]), lon: round6(path[$0]))
            }
        }
    }
}

func round6(_ x: Double) -> Double { (x * 1e6).rounded() / 1e6 }

protocol ParkingDataSource: Sendable {
    /// Blockfaces within `radiusMeters` of a point, closest first.
    func blockfaces(near origin: Coordinate, radiusMeters: Double) async throws -> [NearbyBlockface]
    /// The RPZ zone containing a point, if any.
    func zone(at origin: Coordinate) async throws -> RPZZone?
    /// Hours each RPZ zone is in effect, by zone ("Monday-Saturday 7 AM to 6 PM").
    func rpzHours() async -> [String: String]
}

struct ParkingEngine: Sendable {
    static let hereRadius = 60.0
    static let defaultSearchRadius = 500.0
    static let maxSearchRadius = 1500.0
    static let maxAreaRadius = 800.0
    static let maxAreaBlockfaces = 600

    let source: ParkingDataSource

    // MARK: here

    func here(_ origin: Coordinate, permitZone: String?, date: Date = Date()) async throws -> HereResponse {
        let now = SeattleTime(date)
        async let nearbyTask = source.blockfaces(near: origin, radiusMeters: Self.hereRadius)
        async let zoneTask = source.zone(at: origin)
        let rpzHours = await source.rpzHours()
        let blockfaces = try await nearbyTask
        let rpz = try await zoneTask

        // GPS is only good to ~10–20 m, so report the closest block plus
        // anything nearly as close (the other side of the street, or a corner).
        let nearest = blockfaces.first?.distance ?? .infinity
        let here = blockfaces.filter { $0.distance <= nearest + 20 }.prefix(4).map { b in
            (status: BlockfaceStatus(b.rules, at: now, permitZone: permitZone, rpzHours: rpzHours), b: b)
        }

        var speech: [String] = []
        var brief = ""
        if here.isEmpty {
            speech.append("I couldn't find any city parking data for the street you're on. You may be off-street or outside Seattle.")
            brief = speech[0]
        } else {
            var streets: [String] = []
            var byStreet: [String: [BlockfaceStatus]] = [:]
            for h in here {
                if byStreet[h.status.street] == nil { streets.append(h.status.street) }
                byStreet[h.status.street, default: []].append(h.status)
            }
            speech.append(streets.count == 1 ? "You're on \(streets[0])." : "You're near \(streets.joined(separator: ", and ")).")
            brief = Self.briefHere(street: streets[0], sides: byStreet[streets[0]]!)
            for street in streets {
                let sides = byStreet[street]!
                let prefix = streets.count > 1 ? "On \(street), " : ""
                if sides.count > 1, Set(sides.map(\.summary)).count == 1 {
                    speech.append("\(prefix)\(prefix.isEmpty ? "Both" : "both") sides: \(sides[0].summary).")
                } else {
                    for s in sides {
                        let label = s.side.map { "\($0) side" } ?? "this side"
                        speech.append("\(prefix)\(prefix.isEmpty ? ParkingText.capitalized(label) : label): \(s.summary).")
                    }
                }
            }
        }
        if let rpz, let zone = rpz.zone {
            let name = rpz.name.map { ", \($0)" } ?? ""
            let inEffect = rpz.inEffect.map { ", in effect \($0)" } ?? ""
            speech.append("You're inside Restricted Parking Zone \(zone)\(name)\(inEffect).")
        }

        return HereResponse(
            speech: speech.joined(separator: " "),
            brief: brief,
            blockfaces: here.map { h in
                let s = h.status
                return Blockface(
                    street: s.street, streetLabel: s.streetLabel, side: s.side, summary: s.summary, schedule: s.schedule,
                    canParkNow: s.canParkNow, freeNow: s.freeNow, timeLimitMinutes: s.timeLimitMinutes,
                    postedLimitMinutes: s.postedLimitMinutes, restrictionInMinutes: s.restrictionInMinutes,
                    distanceMeters: Int(h.b.distance.rounded()), path: h.b.curbLine
                )
            },
            rpzZone: rpz
        )
    }

    /// What Siri says for "can I park here", kept short for someone
    /// driving: the closest street only, without its cross streets.
    /// "On 14th Avenue East: east side, free, no posted time limit; west side, no parking."
    static func briefHere(street: String, sides: [BlockfaceStatus]) -> String {
        let name = ParkingText.spokenStreet(street)
        if sides.count == 1 || Set(sides.map(\.summary)).count == 1 {
            return "On \(name): \(sides[0].summary)."
        }
        let each = sides.map { "\($0.side.map { "\($0) side" } ?? "one side"), \($0.summary)" }
        return "On \(name): \(each.joined(separator: "; "))."
    }

    // MARK: area

    func area(_ origin: Coordinate, radiusMeters: Double = 300, permitZone: String?, date: Date = Date()) async throws -> AreaResponse {
        let now = SeattleTime(date)
        let radius = min(max(radiusMeters, 50), Self.maxAreaRadius)
        async let nearbyTask = source.blockfaces(near: origin, radiusMeters: radius)
        let rpzHours = await source.rpzHours()
        let nearby = try await nearbyTask
        let blockfaces: [AreaBlockface] = nearby.prefix(Self.maxAreaBlockfaces).compactMap { b in
            let path = b.curbLine
            guard path.count >= 2 else { return nil }
            let s = BlockfaceStatus(b.rules, at: now, permitZone: permitZone, rpzHours: rpzHours)
            return AreaBlockface(
                street: s.street, streetLabel: s.streetLabel, side: s.side, summary: s.summary, schedule: s.schedule,
                canParkNow: s.canParkNow, freeNow: s.freeNow, timeLimitMinutes: s.timeLimitMinutes,
                postedLimitMinutes: s.postedLimitMinutes, restrictionInMinutes: s.restrictionInMinutes, path: path
            )
        }
        return AreaResponse(blockfaces: blockfaces)
    }

    // MARK: nearby

    /// `minMinutes` or `until` (whichever is given) is how long you're
    /// staying; a stay past midnight is checked against the next day's rules too.
    func nearby(_ origin: Coordinate, radiusMeters: Double = defaultSearchRadius, limit: Int = 3, minMinutes: Int? = nil,
                until: Date? = nil, freeOnly: Bool = false, permitZone: String?, date: Date = Date()) async throws -> NearbyResponse {
        let now = SeattleTime(date)
        let stayEnd = until ?? minMinutes.flatMap { $0 > 0 ? date.addingTimeInterval(Double($0) * 60) : nil }
        let radius = min(max(radiusMeters, 50), Self.maxSearchRadius)
        async let nearbyTask = source.blockfaces(near: origin, radiusMeters: radius)
        let rpzHours = await source.rpzHours()
        let blockfaces = try await nearbyTask

        var seen = Set<String>()
        var results: [Spot] = []
        for b in blockfaces {
            let r = BlockfaceStatus(b.rules, at: now, permitZone: permitZone, rpzHours: rpzHours)
            if !r.canParkNow { continue }
            if freeOnly && !r.freeNow { continue }
            if let stayEnd, !Self.fitsStay(b.rules, from: date, until: stayEnd, permitZone: permitZone, rpzHours: rpzHours) {
                continue
            }
            // Both sides of a block usually share rules; keep the closer one.
            guard seen.insert("\(r.street)|\(r.summary)").inserted else { continue }
            let lat = String(format: "%.6f", b.point.lat)
            let lon = String(format: "%.6f", b.point.lon)
            results.append(Spot(
                street: r.street, streetLabel: r.streetLabel, side: r.side, summary: r.summary, schedule: r.schedule,
                freeNow: r.freeNow, ratePerHour: r.ratePerHour, timeLimitMinutes: r.timeLimitMinutes,
                postedLimitMinutes: r.postedLimitMinutes, restrictionInMinutes: r.restrictionInMinutes,
                distanceMeters: Int(b.distance.rounded()),
                direction: ParkingText.distance(b.distance) == "right here" ? nil : Geo.compassDirection(from: origin, to: b.point),
                point: Coordinate(lat: round6(b.point.lat), lon: round6(b.point.lon)),
                mapsUrl: "https://maps.apple.com/?daddr=\(lat),\(lon)&dirflg=w",
                path: b.curbLine
            ))
            if results.count >= limit { break }
        }

        var speech: [String] = []
        if results.isEmpty {
            let within = ParkingText.distance(radius).replacingOccurrences(of: "about ", with: "")
            speech.append("I couldn't find any street parking you can use right now within \(within)"
                + "\(blockfaces.isEmpty ? "" : " that matches"). Try a wider search or a parking garage.")
        } else {
            // Results are sorted by distance, so both sides of one block are
            // usually adjacent; speak them as one sentence.
            var groups: [[Spot]] = []
            for r in results {
                if let last = groups.last, last[0].street == r.street { groups[groups.count - 1].append(r) } else { groups.append([r]) }
            }
            for (i, group) in groups.enumerated() {
                let first = group[0]
                let place = first.direction.map { "\(ParkingText.distance(Double(first.distanceMeters))) \($0)" } ?? "right here"
                let lead = i == 0 ? "The closest spot is" : i == 1 ? "Next is" : "Or"
                if group.count == 1 {
                    let side = first.side.map { ", \($0) side" } ?? ""
                    speech.append("\(lead) \(place), on \(first.street)\(side): \(first.summary).")
                } else {
                    let sides = group.map { "\($0.side.map { "\($0) side" } ?? "one side"), \($0.summary)" }.joined(separator: "; ")
                    speech.append("\(lead) \(place), on \(first.street): \(sides).")
                }
            }
        }
        return NearbyResponse(speech: speech.joined(separator: " "), results: results)
    }

    /// The longest stay a search checks, so a far-off "until" stays cheap.
    static let maxStayDays = 3

    /// Whether you can stay on a block from `start` until `end`. The rules
    /// are worked out one day at a time, so each day the stay covers is
    /// checked from its first minute (from midnight after the first day).
    static func fitsStay(_ rules: BlockfaceRules, from start: Date, until end: Date, permitZone: String?,
                         rpzHours: [String: String]) -> Bool {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = SeattleTime.timeZone
        let end = min(end, start.addingTimeInterval(Double(maxStayDays) * 86_400))
        var from = start
        while from < end {
            guard let nextDay = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: from)) else { break }
            let needed = Int((min(end, nextDay).timeIntervalSince(from) / 60).rounded(.down))
            let status = BlockfaceStatus(rules, at: SeattleTime(from), permitZone: permitZone, rpzHours: rpzHours)
            if !status.canParkNow { return false }
            if let limit = status.timeLimitMinutes, limit < needed { return false }
            from = nextDay
        }
        return true
    }
}
