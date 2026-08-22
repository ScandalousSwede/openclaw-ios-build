import Foundation

struct AIESAgendaTimeDisplay: Equatable, Sendable {
    let eventTime: String
    let deviceTime: String?
    let eventTimezone: String
}

enum AIESAgendaTimeRendering {
    static func display(
        for event: AIESAgendaEvent,
        deviceTimezone: TimeZone = .autoupdatingCurrent,
        locale: Locale = Locale(identifier: "en_US_POSIX")) throws -> AIESAgendaTimeDisplay
    {
        guard let eventTimezone = TimeZone(identifier: event.eventTimezone) else {
            throw AIESAgendaContractError.invalidTimezone(event.eventTimezone)
        }
        let start = try AIESAgendaContract.canonicalUTCDate(event.startInstant, field: "start_instant")
        let end = try AIESAgendaContract.canonicalUTCDate(event.endInstant, field: "end_instant")
        let eventTime: String
        let deviceTime: String?
        if event.allDay {
            eventTime = Self.allDayRange(start: start, exclusiveEnd: end, timezone: eventTimezone, locale: locale)
            deviceTime = nil
        } else {
            eventTime = Self.timedRange(start: start, end: end, timezone: eventTimezone, locale: locale)
            deviceTime = deviceTimezone.identifier == eventTimezone.identifier
                ? nil
                : Self.timedRange(start: start, end: end, timezone: deviceTimezone, locale: locale)
        }
        return AIESAgendaTimeDisplay(
            eventTime: eventTime,
            deviceTime: deviceTime,
            eventTimezone: event.eventTimezone)
    }

    static func lastUpdated(
        _ date: Date,
        displayTimezone: TimeZone,
        locale: Locale = Locale(identifier: "en_US_POSIX")) -> String
    {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = locale
        formatter.timeZone = displayTimezone
        formatter.dateFormat = "yyyy-MM-dd HH:mm z"
        return "Last updated: \(formatter.string(from: date))"
    }

    private static func timedRange(start: Date, end: Date, timezone: TimeZone, locale: Locale) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timezone
        let startFormatter = DateFormatter()
        startFormatter.calendar = calendar
        startFormatter.locale = locale
        startFormatter.timeZone = timezone
        startFormatter.dateFormat = "MMM d, HH:mm z"
        let endFormatter = DateFormatter()
        endFormatter.calendar = calendar
        endFormatter.locale = locale
        endFormatter.timeZone = timezone
        endFormatter.dateFormat = calendar.isDate(start, inSameDayAs: end)
            ? "HH:mm z"
            : "MMM d, HH:mm z"
        return "\(startFormatter.string(from: start))–\(endFormatter.string(from: end))"
    }

    private static func allDayRange(
        start: Date,
        exclusiveEnd: Date,
        timezone: TimeZone,
        locale: Locale) -> String
    {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timezone
        let inclusiveEnd = calendar.date(byAdding: .day, value: -1, to: exclusiveEnd) ?? start
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = locale
        formatter.timeZone = timezone
        formatter.dateFormat = "MMM d"
        let startText = formatter.string(from: start)
        let endText = formatter.string(from: inclusiveEnd)
        let dates = startText == endText ? startText : "\(startText)–\(endText)"
        return "\(dates) · all day · \(timezone.identifier)"
    }
}
