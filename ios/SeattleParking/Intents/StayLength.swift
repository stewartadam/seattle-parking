import AppIntents
import Foundation

/// How long you're staying, as Siri hears it inside a phrase ("find parking
/// for two hours", "find overnight parking"). App Shortcut phrases can only
/// hold values from a fixed list like this one; for any other time, Siri
/// asks "Until when?" (see FindParkingUntilIntent).
enum StayLength: String, AppEnum {
    case oneHour, twoHours, fourHours, overnight

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Staying For"
    static let caseDisplayRepresentations: [StayLength: DisplayRepresentation] = [
        .oneHour: DisplayRepresentation(title: "1 hour", synonyms: ["one hour", "an hour", "1 hour", "one-hour", "1-hour"]),
        .twoHours: DisplayRepresentation(title: "2 hours", synonyms: [
            "two hours", "2 hours", "two-hour", "2-hour", "two hour", "2 hour", "a couple of hours", "a couple hours",
        ]),
        .fourHours: DisplayRepresentation(title: "4 hours", synonyms: ["four hours", "4 hours", "four-hour", "4-hour", "four hour", "4 hour"]),
        .overnight: DisplayRepresentation(title: "overnight", synonyms: [
            "overnight", "all night", "until morning", "till morning", "until tomorrow morning", "until the morning",
        ]),
    ]

    /// Overnight means until this time the next morning (or this morning, after midnight).
    static let morningMinutes = 8 * 60
    /// Before this time, "overnight" means until this morning.
    static let earlyMorningCutoff = 5 * 60

    /// When the stay ends, if it starts at `date`.
    func end(from date: Date) -> Date {
        switch self {
        case .oneHour: return date.addingTimeInterval(3600)
        case .twoHours: return date.addingTimeInterval(2 * 3600)
        case .fourHours: return date.addingTimeInterval(4 * 3600)
        case .overnight:
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = SeattleTime.timeZone
            let today = calendar.startOfDay(for: date)
            let day = SeattleTime(date).minutes < Self.earlyMorningCutoff
                ? today : calendar.date(byAdding: .day, value: 1, to: today)!
            return calendar.date(byAdding: .minute, value: Self.morningMinutes, to: day)!
        }
    }

    /// Fills in "The closest spot ___ is…".
    var spoken: String {
        switch self {
        case .oneHour: return "for an hour"
        case .twoHours: return "for 2 hours"
        case .fourHours: return "for 4 hours"
        case .overnight: return "overnight"
        }
    }
}

/// "until 9 AM", "until 9 AM tomorrow", "until 6 PM Friday".
func spokenUntil(_ end: Date, from now: Date = Date()) -> String {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = SeattleTime.timeZone
    let time = Clock.format(SeattleTime(end).minutes)
    let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: end)).day ?? 0
    switch days {
    case ..<1: return "until \(time)"
    case 1: return "until \(time) tomorrow"
    default:
        let formatter = DateFormatter()
        formatter.timeZone = SeattleTime.timeZone
        formatter.locale = Locale(identifier: "en_US")
        formatter.dateFormat = "EEEE"
        return "until \(time) \(formatter.string(from: end))"
    }
}
