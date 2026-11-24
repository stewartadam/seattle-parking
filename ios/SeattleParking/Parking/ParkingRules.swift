import Foundation

// The parking rules for one side of one block, ported from the server's
// src/parking.js, src/schedule.js and src/geo.js. Keep the two in step: the
// server still answers Siri Shortcuts, ChatGPT and MCP, and both should say
// the same thing for the same block.

// MARK: - One block side's data

/// The SDOT Parking_Categories fields the rules use, for one blockface.
struct BlockfaceRules: Codable, Hashable, Sendable {
    /// One paid-rate window: rate in dollars, start/end in minutes since midnight (end inclusive).
    struct Rate: Codable, Hashable, Sendable {
        let rate: Double
        let start: Int
        let end: Int

        private enum CodingKeys: String, CodingKey { case rate = "r", start = "s", end = "e" }
    }

    /// Paid/enforced hours for one day type, as SDOT clock text ("08AM").
    struct Hours: Codable, Hashable, Sendable {
        let start: String?
        let end: String?

        private enum CodingKeys: String, CodingKey { case start = "s", end = "e" }
    }

    var unitDesc: String?
    var side: String?
    var category: String?
    /// PARKING_TIME_LIMIT in minutes; nil when 0 or missing.
    var timeLimit: Int?
    var rpzZone: String?
    var peakHour: String?
    var paidArea: String?
    /// Indexed by DayType: weekday, Saturday, Sunday.
    var hours: [Hours]
    var rates: [[Rate]]

    // Short keys keep the saved copy of the whole city small.
    private enum CodingKeys: String, CodingKey {
        case unitDesc = "u", side = "d", category = "c", timeLimit = "l", rpzZone = "z", peakHour = "p", paidArea = "a"
        case hours = "h", rates = "r"
    }

    static let fields: [String] = {
        var f = ["UNITDESC", "SIDE", "PARKING_CATEGORY", "PARKING_TIME_LIMIT", "RPZ_ZONE", "PEAK_HOUR", "PAIDAREA"]
        for d in DayType.allCases { f += ["START_TIME_\(d.rawValue)", "END_TIME_\(d.rawValue)"] }
        for d in DayType.allCases {
            for i in 1...3 { f += ["\(d.rawValue)_RATE\(i)", "\(d.rawValue)_START\(i)", "\(d.rawValue)_END\(i)"] }
        }
        return f
    }()

    init(_ a: GISAttributes) {
        unitDesc = a.text("UNITDESC")
        side = a.text("SIDE")
        category = a.text("PARKING_CATEGORY")
        timeLimit = a.positiveInt("PARKING_TIME_LIMIT")
        rpzZone = a.text("RPZ_ZONE")
        peakHour = a.text("PEAK_HOUR")
        paidArea = a.text("PAIDAREA")
        hours = DayType.allCases.map { d in
            Hours(start: a.text("START_TIME_\(d.rawValue)"), end: a.text("END_TIME_\(d.rawValue)"))
        }
        rates = DayType.allCases.map { d in
            (1...3).compactMap { i in
                guard let rate = a.number("\(d.rawValue)_RATE\(i)"),
                      let start = a.number("\(d.rawValue)_START\(i)"),
                      let end = a.number("\(d.rawValue)_END\(i)"),
                      // SDOT fills unused slots with zeros; they never change an answer.
                      rate != 0 || start != 0 || end != 0 else { return nil }
                return Rate(rate: rate, start: Int(start), end: Int(end))
            }
        }
    }
}

// MARK: - Seattle time

enum DayType: String, CaseIterable, Sendable {
    case weekday = "WKD", saturday = "SAT", sunday = "SUN"
    var index: Int { DayType.allCases.firstIndex(of: self)! }
}

struct SeattleTime: Sendable {
    /// "Mon", "Tue", ...
    let weekday: String
    let dayType: DayType
    var isWeekday: Bool { dayType == .weekday }
    /// Minutes since midnight.
    let minutes: Int

    static let timeZone = TimeZone(identifier: "America/Los_Angeles")!

    init(_ date: Date = Date()) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = Self.timeZone
        let c = calendar.dateComponents([.weekday, .hour, .minute], from: date)
        let names = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
        weekday = names[(c.weekday ?? 2) - 1]
        dayType = weekday == "Sat" ? .saturday : weekday == "Sun" ? .sunday : .weekday
        minutes = (c.hour ?? 0) * 60 + (c.minute ?? 0)
    }
}

// MARK: - Clock text

private func regex(_ pattern: String) -> NSRegularExpression {
    try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
}

private extension NSTextCheckingResult {
    func group(_ i: Int, in s: String) -> String? {
        guard let r = Range(range(at: i), in: s) else { return nil }
        return String(s[r])
    }
}

enum Clock {
    private static let clockPattern = regex(#"^\s*(\d{1,2})(?::(\d{2}))?\s*(AM|PM)\s*$"#)
    private static let peakPattern = regex(#"(\d{1,2})(?::(\d{2}))?\s*(AM|PM)?\s*-\s*(\d{1,2})(?::(\d{2}))?\s*(AM|PM)"#)

    /// "08AM", "10PM", "8:30AM" -> minutes since midnight.
    static func parse(_ text: String?) -> Int? {
        guard let text,
              let m = clockPattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let h = m.group(1, in: text).flatMap(Int.init),
              let mer = m.group(3, in: text)?.uppercased() else { return nil }
        var hour = h % 12
        if mer == "PM" { hour += 12 }
        return hour * 60 + (m.group(2, in: text).flatMap(Int.init) ?? 0)
    }

    /// "7-9AM", "4-6PM" or "7-9AM 4-6PM" -> [start, end) windows.
    static func peakWindows(_ text: String?) -> [(start: Int, end: Int)] {
        guard let text else { return [] }
        return peakPattern.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { m in
            let endMer = m.group(6, in: text)!.uppercased()
            guard let end = parse("\(m.group(4, in: text)!):\(m.group(5, in: text) ?? "00")\(endMer)"),
                  var start = parse("\(m.group(1, in: text)!):\(m.group(2, in: text) ?? "00")\((m.group(3, in: text) ?? endMer).uppercased())")
            else { return nil }
            // "11-1PM" style ranges cross noon; the start is really AM.
            if m.group(3, in: text) == nil, start > end { start -= 12 * 60 }
            return (start, end)
        }
    }

    /// 480 -> "8 AM", 1290 -> "9:30 PM".
    static func format(_ minutes: Int) -> String {
        let m = ((minutes % 1440) + 1440) % 1440
        let h24 = m / 60
        let min = m % 60
        if h24 == 0 && min == 0 { return "midnight" }
        if h24 == 12 && min == 0 { return "noon" }
        let h12 = h24 % 12 == 0 ? 12 : h24 % 12
        let mer = h24 < 12 ? "AM" : "PM"
        return min != 0 ? "\(h12):\(String(format: "%02d", min)) \(mer)" : "\(h12) \(mer)"
    }

    /// A time limit before a noun: "2-hour", "30-minute", "1.5-hour".
    static func limit(_ minutes: Int) -> String {
        if minutes < 60 { return "\(minutes)-minute" }
        if minutes % 60 == 0 { return "\(minutes / 60)-hour" }
        return "\(String(format: "%.1f", Double(minutes) / 60))-hour"
    }

    static func range(_ start: Int, _ end: Int) -> String { "\(format(start))–\(format(end))" }
}

// MARK: - Geometry

/// Planar helpers in a local equirectangular projection around the query
/// point, accurate to well under a meter at the few-kilometer scale used here.
enum Geo {
    static let metersPerDegLat = 110_540.0
    static let metersPerDegLonAtEquator = 111_320.0

    static func toLocal(_ origin: Coordinate, _ lat: Double, _ lon: Double) -> (x: Double, y: Double) {
        let kx = metersPerDegLonAtEquator * cos(origin.lat * .pi / 180)
        return ((lon - origin.lon) * kx, (lat - origin.lat) * metersPerDegLat)
    }

    static func fromLocal(_ origin: Coordinate, _ x: Double, _ y: Double) -> Coordinate {
        let kx = metersPerDegLonAtEquator * cos(origin.lat * .pi / 180)
        return Coordinate(lat: origin.lat + y / metersPerDegLat, lon: origin.lon + x / kx)
    }

    /// Distance in meters from origin to the closest point on a polyline
    /// (each path a flat [lon, lat, lon, lat, ...] array), and that point.
    static func distance(from origin: Coordinate, to paths: [[Double]]) -> (distance: Double, point: Coordinate?) {
        var best = (distance: Double.infinity, point: Coordinate?.none)
        for path in paths {
            let n = path.count / 2
            for i in 0..<n {
                let a = toLocal(origin, path[2 * i + 1], path[2 * i])
                let b = i + 1 < n ? toLocal(origin, path[2 * i + 3], path[2 * i + 2]) : a
                let dx = b.x - a.x
                let dy = b.y - a.y
                let len2 = dx * dx + dy * dy
                // Origin is (0, 0) in local coordinates.
                let t = len2 == 0 ? 0 : max(0, min(1, -(a.x * dx + a.y * dy) / len2))
                let px = a.x + t * dx
                let py = a.y + t * dy
                let d = (px * px + py * py).squareRoot()
                if d < best.distance { best = (d, fromLocal(origin, px, py)) }
            }
        }
        return best
    }

    private static let compass = ["north", "northeast", "east", "southeast", "south", "southwest", "west", "northwest"]

    /// "northeast" etc., from origin to a point.
    static func compassDirection(from origin: Coordinate, to point: Coordinate) -> String {
        let p = toLocal(origin, point.lat, point.lon)
        let bearing = (atan2(p.x, p.y) * 180 / .pi + 360).truncatingRemainder(dividingBy: 360)
        return compass[Int((bearing / 45).rounded()) % 8]
    }

    /// Even-odd point-in-polygon test over all rings (so holes work).
    static func contains(rings: [[Double]], lat: Double, lon: Double) -> Bool {
        var inside = false
        for ring in rings {
            let n = ring.count / 2
            guard n >= 3 else { continue }
            var j = n - 1
            for i in 0..<n {
                let xi = ring[2 * i], yi = ring[2 * i + 1]
                let xj = ring[2 * j], yj = ring[2 * j + 1]
                if (yi > lat) != (yj > lat), lon < (xj - xi) * (lat - yi) / (yj - yi) + xi { inside.toggle() }
                j = i
            }
        }
        return inside
    }
}

// MARK: - Display text

enum ParkingText {
    private static let sideNames = [
        "N": "north", "S": "south", "E": "east", "W": "west",
        "NE": "northeast", "NW": "northwest", "SE": "southeast", "SW": "southwest",
    ]

    private static let streetWords = [
        "N": "North", "S": "South", "E": "East", "W": "West",
        "NE": "Northeast", "NW": "Northwest", "SE": "Southeast", "SW": "Southwest",
        "ST": "Street", "AVE": "Avenue", "PL": "Place", "BLVD": "Boulevard", "DR": "Drive", "RD": "Road",
        "CT": "Court", "AL": "Alley", "LN": "Lane", "PKWY": "Parkway", "TER": "Terrace", "HWY": "Highway", "CIR": "Circle",
        "BETWEEN": "between", "AND": "and",
    ]

    private static let directions: Set = ["N", "S", "E", "W", "NE", "NW", "SE", "SW"]
    private static let labelSuffixes = [
        "AVE": "Ave", "AV": "Ave", "AVENUE": "Ave", "ST": "St", "STREET": "St", "PL": "Pl", "PLACE": "Pl", "DR": "Dr", "DRIVE": "Dr",
        "BLVD": "Blvd", "BOULEVARD": "Blvd", "WAY": "Way", "CT": "Ct", "COURT": "Ct", "LN": "Ln", "LANE": "Ln", "RD": "Rd", "ROAD": "Rd",
        "PKWY": "Pkwy", "PARKWAY": "Pkwy", "TER": "Ter", "TERRACE": "Ter", "CIR": "Cir", "CIRCLE": "Cir", "HWY": "Hwy", "HIGHWAY": "Hwy",
    ]

    static func side(_ code: String?) -> String? { code.flatMap { sideNames[$0] } }

    private static func words(_ s: String) -> [String] {
        s.split(whereSeparator: { $0.isWhitespace }).map(String.init)
    }

    private static func startsWithDigit(_ w: String) -> Bool { w.first?.isASCII == true && w.first?.isNumber == true }

    /// "BROADWAY E BETWEEN E OLIVE WAY AND E THOMAS ST" -> "Broadway East between East Olive Way and East Thomas Street"
    static func street(_ unitDesc: String?) -> String {
        guard let unitDesc, !unitDesc.isEmpty else { return "an unnamed block" }
        return words(unitDesc).map { w in
            if let word = streetWords[w] { return word }
            if startsWithDigit(w) { return w.lowercased() }
            return String(w.prefix(1)) + w.dropFirst().lowercased()
        }.joined(separator: " ")
    }

    /// "E LYNN ST BETWEEN YALE AVE E AND EASTLAKE AVE E" -> "E. Lynn St between Yale Ave E and Eastlake Ave E"
    static func streetLabel(_ unitDesc: String?) -> String {
        guard let unitDesc, !unitDesc.isEmpty else { return "Unnamed block" }
        var startOfName = true
        let ordinal = regex(#"^\d+(ST|ND|RD|TH)$"#)
        return words(unitDesc).map { w in
            let word = w.uppercased()
            let atStart = startOfName
            startOfName = false
            if word == "BETWEEN" || word == "AND" {
                startOfName = true
                return word.lowercased()
            }
            if directions.contains(word) { return atStart && word.count == 1 ? "\(word)." : word }
            if ordinal.firstMatch(in: word, range: NSRange(word.startIndex..., in: word)) != nil { return word.lowercased() }
            if startsWithDigit(word) { return word }
            if let suffix = labelSuffixes[word] { return suffix }
            return String(word.prefix(1)) + word.dropFirst().lowercased()
        }.joined(separator: " ")
    }

    /// "about 300 feet", "about 0.4 miles", "right here".
    static func distance(_ meters: Double) -> String {
        let feet = meters * 3.28084
        if feet < 75 { return "right here" }
        if feet < 1000 { return "about \(Int((feet / 50).rounded()) * 50) feet" }
        return "about \(String(format: "%.1f", feet / 5280)) miles"
    }

    static func rate(_ rate: Double) -> String { "$\(String(format: "%.2f", rate)) an hour" }

    static func money(_ rate: Double) -> String {
        rate == rate.rounded() ? "$\(Int(rate))" : "$\(String(format: "%.2f", rate))"
    }

    /// Splits a display label into the street and the block it covers:
    /// "NW 64th St between 15th Ave NW and 17th Ave NW" ->
    /// ("NW 64th St", "Between 15th Ave NW and 17th Ave NW").
    static func splitStreetLabel(_ label: String) -> (name: String, between: String?) {
        guard let range = label.range(of: " between ") else { return (label, nil) }
        let name = String(label[..<range.lowerBound])
        let rest = String(label[range.upperBound...])
        guard !name.isEmpty, !rest.isEmpty else { return (label, nil) }
        return (name, "Between " + rest)
    }

    /// "50ft", "0.4mi": a compact distance for list rows.
    static func shortDistance(_ meters: Double) -> String {
        let feet = meters * 3.28084
        if feet < 1000 { return "\(max(50, Int((feet / 50).rounded()) * 50))ft" }
        return "\(String(format: "%.1f", feet / 5280))mi"
    }

    /// The first line of a street description: "NW 64th St - South side, 50ft".
    static func streetHeading(name: String, side: String?, distanceMeters: Int? = nil) -> String {
        var line = name + " - " + (side.map { "\(capitalized($0)) side" } ?? "This side")
        if let distanceMeters { line += ", " + shortDistance(Double(distanceMeters)) }
        return line
    }

    /// A street name to say out loud, without the cross streets:
    /// "Northwest 64th Street between 15th Avenue Northwest and ..." -> "Northwest 64th Street".
    static func spokenStreet(_ street: String) -> String {
        street.components(separatedBy: " between ").first ?? street
    }

    /// What Siri says after a search, kept short for someone driving: only
    /// the closest spot, its street without cross streets or side (the card
    /// shows those), and its rules. `stay` is how the search was worded,
    /// e.g. "for 2 hours" or "overnight"; `place` is a place searched by name,
    /// for answers like "about 200 feet north of Lighthouse Coffee Roasters".
    /// "The closest spot is about 200 feet south, on Northwest 63rd Street: free, no posted time limit."
    static func briefSpeech(closest spot: Spot, stay: String? = nil, near place: String? = nil) -> String {
        let street = spokenStreet(spot.street)
        let forStay = stay.map { " \($0)" } ?? ""
        guard let direction = spot.direction else {
            let at = place.map { "right by \($0)" } ?? "right here"
            return "You can park \(at)\(forStay), on \(street): \(spot.summary)."
        }
        let of = place.map { " of \($0)" } ?? ""
        return "The closest spot\(forStay) is \(distance(Double(spot.distanceMeters))) \(direction)\(of), on \(street): \(spot.summary)."
    }

    static func capitalized(_ s: String) -> String { s.isEmpty ? s : s.prefix(1).uppercased() + s.dropFirst() }
}

// MARK: - Weekly schedule ("when do these rules apply?")

enum ParkingSchedule {
    private static let dayLabels: [DayType: String] = [.weekday: "Mon–Fri", .saturday: "Sat", .sunday: "Sun"]

    /// Day types with identical text, labeled "daily", "Mon–Sat", "Sat–Sun" or a list.
    private static func dayGroups(_ textByDay: [String?]) -> [(text: String?, label: String)] {
        var groups: [(text: String?, days: [DayType])] = []
        for d in DayType.allCases {
            let text = textByDay[d.index]
            if let i = groups.firstIndex(where: { $0.text == text }) { groups[i].days.append(d) } else { groups.append((text, [d])) }
        }
        return groups.map { g in
            let label: String
            switch g.days {
            case [.weekday, .saturday, .sunday]: label = "daily"
            case [.weekday, .saturday]: label = "Mon–Sat"
            case [.saturday, .sunday]: label = "Sat–Sun"
            default: label = g.days.map { dayLabels[$0]! }.joined(separator: ", ")
            }
            return (g.text, label)
        }
    }

    /// "Mon–Sat 8 AM–8 PM ($1–$2.50/hr); free Sun", or nil if the data has no paid hours.
    private static func paid(_ b: BlockfaceRules) -> String? {
        let textByDay: [String?] = DayType.allCases.map { d in
            guard let start = Clock.parse(b.hours[d.index].start), let end = Clock.parse(b.hours[d.index].end) else { return nil }
            let rates = b.rates[d.index].map(\.rate).filter { $0 > 0 }
            var rateText = ""
            if let lo = rates.min(), let hi = rates.max() {
                rateText = lo == hi ? " (\(ParkingText.money(lo))/hr)" : " (\(ParkingText.money(lo))–\(ParkingText.money(hi))/hr)"
            }
            return "\(Clock.range(start, end == 0 ? 1440 : end))\(rateText)"
        }
        let groups = dayGroups(textByDay)
        if groups.allSatisfy({ $0.text == nil }) { return nil }
        let paid = groups.compactMap { g in g.text.map { "\(g.label) \($0)" } }
        let free = groups.filter { $0.text == nil }.map(\.label)
        return ([paid.joined(separator: ", ")] + (free.isEmpty ? [] : ["free \(free.joined(separator: ", "))"]))
            .joined(separator: "; ")
    }

    /// "Monday-Saturday 7 AM to 6 PM" -> "Mon–Sat 7 AM–6 PM".
    static func shortenRPZHours(_ text: String) -> String {
        var s = regex(#"\s+"#).stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: " ")
        let days = regex(#"\b(Mon|Tues|Wednes|Thurs|Fri|Satur|Sun)day\b"#)
        for m in days.matches(in: s, range: NSRange(s.startIndex..., in: s)).reversed() {
            let r = Range(m.range, in: s)!
            s.replaceSubrange(r, with: String(m.group(1, in: s)!.prefix(3)))
        }
        s = regex(#"\s*-\s*"#).stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: "–")
        s = regex(#"\s+to\s+"#).stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: "–")
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// When a blockface's rules apply (all week), e.g.
    /// "2-hour limit, paid Mon–Sat 8 AM–8 PM ($2.50/hr); free Sun · no parking 7 AM–9 AM weekdays".
    static func text(_ b: BlockfaceRules, rpzHours: [String: String]) -> String? {
        var parts: [String] = []
        let limitText = b.timeLimit.map { "\(Clock.limit($0)) limit" }
        switch b.category {
        case "Paid Parking":
            let p = paid(b)
            parts.append([limitText, p.map { "paid \($0)" } ?? "paid hours not in city data"].compactMap { $0 }.joined(separator: ", "))
        case "Time Limited Parking":
            parts.append("\(limitText ?? "time limited"), hours not in city data, check the sign")
        case "Restricted Parking Zone":
            let hours = b.rpzZone.flatMap { rpzHours[$0] }
            let visitor = b.rpzZone.map { "\(Clock.limit(b.timeLimit ?? 120)) limit without a zone \($0) permit" }
                ?? "\(Clock.limit(b.timeLimit ?? 120)) limit without a permit"
            parts.append(hours.map { "\(visitor), \(shortenRPZHours($0))" } ?? "\(visitor), hours not in city data")
        default:
            break
        }
        let peaks = Clock.peakWindows(b.peakHour)
        if !peaks.isEmpty {
            parts.append("no parking \(peaks.map { Clock.range($0.start, $0.end) }.joined(separator: ", ")) weekdays")
        }
        guard !parts.isEmpty else { return nil }
        return ParkingText.capitalized(parts.joined(separator: " · "))
    }
}

// MARK: - Rules right now

/// A blockface's rules evaluated at one moment (src/parking.js evaluateBlockface).
struct BlockfaceStatus: Sendable {
    var street: String
    var streetLabel: String
    var side: String?
    var category: String
    var canParkNow = false
    var freeNow = true
    var ratePerHour: Double?
    /// How long you can stay from now.
    var timeLimitMinutes: Int?
    /// A posted time limit in effect right now.
    var postedLimitMinutes: Int?
    /// Free and unrestricted now, but a restriction starts later today.
    var restrictionInMinutes: Int?
    /// Can't park now, but can later today.
    var parkableInMinutes: Int?
    var summary = ""
    var schedule: String?

    init(_ b: BlockfaceRules, at now: SeattleTime, permitZone: String?, rpzHours: [String: String]) {
        street = ParkingText.street(b.unitDesc)
        streetLabel = ParkingText.streetLabel(b.unitDesc)
        side = ParkingText.side(b.side)
        category = b.category ?? "Unknown"
        schedule = ParkingSchedule.text(b, rpzHours: rpzHours)
        let limit = b.timeLimit

        switch category {
        case "No Parking Allowed":
            summary = "no parking"

        case "Carpool Parking":
            summary = "carpool permit parking only"

        case "Paid Parking":
            canParkNow = true
            if let hours = Self.enforcementHours(b, now) {
                if now.minutes >= hours.start && now.minutes < hours.end {
                    let rate = Self.currentRate(b, now)
                    let paid = rate.map { $0 != 0 } ?? false
                    freeNow = !paid
                    ratePerHour = paid ? rate : nil
                    timeLimitMinutes = limit
                    postedLimitMinutes = limit
                    summary = [
                        paid ? "paid, \(ParkingText.rate(rate!)) until \(Clock.format(hours.end))" : "paid parking until \(Clock.format(hours.end))",
                        limit.map { "\(Clock.limit($0)) limit" },
                    ].compactMap { $0 }.joined(separator: ", ")
                } else if now.minutes < hours.start {
                    timeLimitMinutes = hours.start - now.minutes
                    restrictionInMinutes = hours.start - now.minutes
                    summary = "free until \(Clock.format(hours.start)), then paid"
                } else {
                    summary = "free now, paid parking ended at \(Clock.format(hours.end))"
                }
            } else {
                summary = "paid parking area, but free today"
            }

        case "Time Limited Parking":
            canParkNow = true
            timeLimitMinutes = limit
            postedLimitMinutes = limit
            summary = limit.map { "free, \(Clock.limit($0)) limit" } ?? "free, time limited"

        case "Restricted Parking Zone":
            canParkNow = true
            let zone = b.rpzZone.map { "zone \($0)" } ?? "a restricted parking zone"
            if let permitZone, let rpz = b.rpzZone, permitZone == rpz {
                summary = "free with your \(zone) permit, no time limit"
                break
            }
            let hours = Self.enforcementHours(b, now)
            if let hours, !(now.minutes >= hours.start && now.minutes < hours.end) {
                summary = "free, \(zone) permit rules not in effect right now"
                if now.minutes < hours.start {
                    timeLimitMinutes = hours.start - now.minutes + (limit ?? 0)
                    restrictionInMinutes = hours.start - now.minutes
                }
            } else {
                timeLimitMinutes = limit ?? 120
                postedLimitMinutes = timeLimitMinutes
                summary = "free, \(Clock.limit(timeLimitMinutes!)) limit without a \(zone) permit"
                if let hours { summary += " until \(Clock.format(hours.end))" }
            }

        case "Unrestricted Parking":
            canParkNow = true
            summary = "free, no posted time limit"

        default:
            summary = category.lowercased()
        }

        // Weekday peak-hour (rush hour) tow-away restrictions override everything.
        let peaks = now.isWeekday ? Clock.peakWindows(b.peakHour) : []
        let active = peaks.first { now.minutes >= $0.start && now.minutes < $0.end }
        let upcoming = peaks.filter { $0.start > now.minutes }.min { $0.start < $1.start }
        if let active {
            // Parking is allowed again when the tow-away window ends, if the
            // block allows parking at all.
            if canParkNow { parkableInMinutes = active.end - now.minutes }
            canParkNow = false
            postedLimitMinutes = nil
            restrictionInMinutes = nil
            summary = "no parking right now, rush-hour tow-away zone until \(Clock.format(active.end))"
        } else if let upcoming, canParkNow {
            let minutesLeft = upcoming.start - now.minutes
            timeLimitMinutes = timeLimitMinutes.map { min($0, minutesLeft) } ?? minutesLeft
            restrictionInMinutes = restrictionInMinutes.map { min($0, minutesLeft) } ?? minutesLeft
            if minutesLeft <= 180 { summary += ", but it becomes a tow-away zone at \(Clock.format(upcoming.start))" }
        }
    }

    private static func enforcementHours(_ b: BlockfaceRules, _ now: SeattleTime) -> (start: Int, end: Int)? {
        let h = b.hours[now.dayType.index]
        guard let start = Clock.parse(h.start), let end = Clock.parse(h.end) else { return nil }
        return (start, end == 0 ? 1440 : end)
    }

    private static func currentRate(_ b: BlockfaceRules, _ now: SeattleTime) -> Double? {
        b.rates[now.dayType.index].first { now.minutes >= $0.start && now.minutes <= $0.end }?.rate
    }
}
