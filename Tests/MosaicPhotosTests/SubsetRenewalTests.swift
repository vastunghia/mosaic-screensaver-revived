import Foundation
import Testing
@testable import MosaicPhotos

@Suite("Subset renewal")
struct SubsetRenewalTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Rome")!
        return calendar
    }

    private func date(_ text: String) -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = calendar.timeZone
        formatter.formatOptions = [.withFullDate, .withTime, .withColonSeparatorInTime]
        return formatter.date(from: text)!
    }

    @Test("never is never due")
    func never() {
        let renewed = date("2026-10-19T14:50:00")
        #expect(SubsetRenewal.never.due(after: renewed, calendar: calendar) == nil)
        #expect(!SubsetRenewal.never.isDue(renewed: renewed, now: .distantFuture, calendar: calendar))
    }

    @Test("a day, a week and a month go by the calendar, across a change of time and a short month")
    func byTheCalendar() {
        // The clocks go back on 2026-10-25 in Rome: a day is then 25 hours.
        let renewed = date("2026-10-24T14:50:00")
        #expect(SubsetRenewal.daily.due(after: renewed, calendar: calendar) == date("2026-10-25T14:50:00"))
        #expect(SubsetRenewal.weekly.due(after: renewed, calendar: calendar) == date("2026-10-31T14:50:00"))
        #expect(SubsetRenewal.monthly.due(after: date("2027-01-31T09:00:00"), calendar: calendar)
            == date("2027-02-28T09:00:00"))
    }

    @Test("due once the date has come, not before")
    func isDue() {
        let renewed = date("2026-10-19T14:50:00")
        let rule = SubsetRenewal.weekly
        #expect(!rule.isDue(renewed: renewed, now: date("2026-10-26T14:49:00"), calendar: calendar))
        #expect(rule.isDue(renewed: renewed, now: date("2026-10-26T14:50:00"), calendar: calendar))
        #expect(rule.isDue(renewed: renewed, now: date("2026-12-01T00:00:00"), calendar: calendar))
    }

    @Test("weekly by default")
    func standard() {
        #expect(SubsetRenewal.standard == .weekly)
    }
}
