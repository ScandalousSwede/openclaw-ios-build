import Foundation
import Testing
@testable import OpenClaw

@Suite(.serialized) struct AIESAgendaContractTests {
    private func utc(_ value: String) -> Date {
        try! AIESAgendaContract.canonicalUTCDate(value, field: "test")
    }

    private func canonical(_ value: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: value)
    }

    private func event(
        index: Int = 0,
        stale: Bool = false,
        allDay: Bool = false,
        timezone: String = "Europe/Stockholm",
        start: String? = nil,
        end: String? = nil) -> [String: Any]
    {
        [
            "schema": "argus.aies.event.v1",
            "event_key": String(format: "evt_%032x", index + 1),
            "title": "AIES session \(index)",
            "start_instant": start ?? (allDay ? "2026-10-24T22:00:00Z" : "2026-10-12T07:00:00Z"),
            "end_instant": end ?? (allDay ? "2026-10-25T23:00:00Z" : "2026-10-12T08:00:00Z"),
            "event_timezone": timezone,
            "timezone_source": "event",
            "all_day": allDay,
            "source": "google_calendar",
            "source_event_id": "gcal-\(index)",
            "fetched_at": "2026-10-12T06:55:00Z",
            "source_status": "available",
            "stale": stale,
            "warnings": [],
        ]
    }

    private func cache(
        items: [[String: Any]]? = nil,
        state: String? = nil,
        stale: Bool = false,
        sourceStatus: String = "available",
        fetchedAt: String = "2026-10-12T06:55:00Z",
        maxAge: Int = 3600) -> [String: Any]
    {
        let values = items ?? [self.event(stale: stale)]
        return [
            "schema": "argus.aies.agenda-cache.v1",
            "cache_kind": "last_known_agenda",
            "authoritative": false,
            "authority_source": "google_calendar",
            "source_status": sourceStatus,
            "source_status_at_fetch": "available",
            "availability_state": state ?? (stale ? "stale_cache" : (values.isEmpty ? "available_empty" : "available_events")),
            "fetched_at": fetchedAt,
            "cached_at": "2026-10-12T07:00:00Z",
            "age_seconds": 300,
            "max_age_seconds": maxAge,
            "stale": stale,
            "max_items": 256,
            "original_item_count": values.count,
            "truncated": false,
            "items": values,
        ]
    }

    private func data(_ object: [String: Any]) -> Data {
        try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    @Test func distinguishesHealthyEventsAndHealthyEmpty() throws {
        let reference = self.utc("2026-10-12T07:10:00Z")
        let events = try AIESAgendaContract.decodeAndValidate(self.data(self.cache()), now: reference)
        #expect(events.envelope.availabilityState == .availableEvents)
        let empty = try AIESAgendaContract.decodeAndValidate(
            self.data(self.cache(items: [], state: "available_empty")), now: reference)
        #expect(empty.envelope.availabilityState == .availableEmpty)
        #expect(empty.envelope.items.isEmpty)
    }

    @Test func emptyItemsWithUnavailableSourceNeverBecomeHealthyEmpty() {
        let bad = self.cache(items: [], state: "available_empty", sourceStatus: "unavailable")
        #expect(throws: AIESAgendaContractError.invalidAvailability) {
            try AIESAgendaContract.decodeAndValidate(self.data(bad), now: self.utc("2026-10-12T07:10:00Z"))
        }
    }

    @Test func staleCacheRequiresStaleItemsAndExplicitState() throws {
        let stale = self.cache(items: [self.event(stale: true)], stale: true, sourceStatus: "unavailable")
        let decoded = try AIESAgendaContract.decodeAndValidate(
            self.data(stale), now: self.utc("2026-10-12T07:10:00Z"))
        #expect(decoded.locallyStale)
        var inconsistent = stale
        inconsistent["availability_state"] = "available_events"
        #expect(throws: AIESAgendaContractError.invalidAvailability) {
            try AIESAgendaContract.decodeAndValidate(
                self.data(inconsistent), now: self.utc("2026-10-12T07:10:00Z"))
        }
    }

    @Test func rejectsUnknownFieldsInvalidTimezoneAndNoncanonicalInstant() {
        var extra = self.cache()
        extra["start_local"] = "2026-10-12T09:00:00+02:00"
        #expect(throws: AIESAgendaContractError.self) {
            try AIESAgendaContract.decodeAndValidate(self.data(extra), now: self.utc("2026-10-12T07:10:00Z"))
        }
        var abbreviation = self.cache()
        var item = self.event()
        item["event_timezone"] = "CET"
        abbreviation["items"] = [item]
        #expect(throws: AIESAgendaContractError.invalidTimezone("CET")) {
            try AIESAgendaContract.decodeAndValidate(
                self.data(abbreviation), now: self.utc("2026-10-12T07:10:00Z"))
        }
        var offset = self.cache()
        item = self.event()
        item["start_instant"] = "2026-10-12T09:00:00+02:00"
        offset["items"] = [item]
        #expect(throws: AIESAgendaContractError.self) {
            try AIESAgendaContract.decodeAndValidate(self.data(offset), now: self.utc("2026-10-12T07:10:00Z"))
        }
    }

    @Test func itemAndEncodedBoundsFailClosed() {
        let oversized = Data(repeating: 0x20, count: AIESAgendaContract.maximumEncodedBytes + 1)
        #expect(throws: AIESAgendaContractError.oversized) {
            try AIESAgendaContract.decodeAndValidate(oversized)
        }
        let values = (0...256).map { self.event(index: $0) }
        #expect(throws: AIESAgendaContractError.invalidBounds) {
            try AIESAgendaContract.decodeAndValidate(
                self.data(self.cache(items: values)), now: self.utc("2026-10-12T07:10:00Z"))
        }
    }

    @Test func exactItemAndByteBoundsAreAccepted() throws {
        let reference = self.utc("2026-10-12T07:10:00Z")
        let values = (0..<256).map { self.event(index: $0) }
        let maximumItems = self.data(self.cache(items: values))
        let decoded = try AIESAgendaContract.decodeAndValidate(maximumItems, now: reference)
        #expect(decoded.envelope.items.count == 256)

        let base = self.data(self.cache())
        let padded = base + Data(repeating: 0x20, count: AIESAgendaContract.maximumEncodedBytes - base.count)
        _ = try AIESAgendaContract.decodeAndValidate(padded, now: reference)
        #expect(throws: AIESAgendaContractError.oversized) {
            try AIESAgendaContract.decodeAndValidate(padded + Data([0x20]), now: reference)
        }
    }

    @Test func duplicateIdentityAndFutureClockSkewFailClosed() {
        let duplicate = self.event()
        #expect(throws: AIESAgendaContractError.duplicateEventKey("evt_00000000000000000000000000000001")) {
            try AIESAgendaContract.decodeAndValidate(
                self.data(self.cache(items: [duplicate, duplicate])),
                now: self.utc("2026-10-12T07:10:00Z"))
        }
        #expect(throws: AIESAgendaContractError.self) {
            try AIESAgendaContract.decodeAndValidate(
                self.data(self.cache()), now: self.utc("2026-10-12T06:00:00Z"))
        }
    }

    @Test func localAgeCanMakeAnOtherwiseHealthyCacheStale() throws {
        let decoded = try AIESAgendaContract.decodeAndValidate(
            self.data(self.cache(maxAge: 60)), now: self.utc("2026-10-12T07:10:00Z"))
        #expect(decoded.locallyStale)
    }

    @Test func rendersStockholmPrimaryAndDeviceSecondaryWithoutPersistingWallTime() throws {
        let decoded = try AIESAgendaContract.decodeAndValidate(
            self.data(self.cache()), now: self.utc("2026-10-12T07:10:00Z"))
        let display = try AIESAgendaTimeRendering.display(
            for: decoded.envelope.items[0],
            deviceTimezone: TimeZone(identifier: "America/Edmonton")!)
        #expect(display.eventTime.contains("09:00"))
        #expect(display.deviceTime?.contains("01:00") == true)
        #expect(display.eventTimezone == "Europe/Stockholm")
    }

    @Test func allDayExclusiveEndUsesCalendarDaysAcrossAutumnDST() throws {
        let decoded = try AIESAgendaContract.decodeAndValidate(
            self.data(self.cache(items: [self.event(allDay: true)])),
            now: self.utc("2026-10-12T07:10:00Z"))
        let display = try AIESAgendaTimeRendering.display(for: decoded.envelope.items[0])
        #expect(display.eventTime.contains("Oct 25"))
        #expect(!display.eventTime.contains("Oct 26"))
    }

    @Test func allDayExclusiveEndUsesCalendarDaysAcrossSpringDST() throws {
        let value = self.event(
            allDay: true,
            start: "2026-03-28T23:00:00Z",
            end: "2026-03-29T22:00:00Z")
        let decoded = try AIESAgendaContract.decodeAndValidate(
            self.data(self.cache(items: [value])),
            now: self.utc("2026-10-12T07:10:00Z"))
        let display = try AIESAgendaTimeRendering.display(for: decoded.envelope.items[0])
        #expect(display.eventTime.contains("Mar 29"))
        #expect(!display.eventTime.contains("Mar 30"))
    }

    @Test func allDayEventsRequireLocalMidnightBoundaries() {
        let value = self.event(
            allDay: true,
            start: "2026-03-29T00:30:00Z",
            end: "2026-03-29T22:00:00Z")
        #expect(throws: AIESAgendaContractError.self) {
            try AIESAgendaContract.decodeAndValidate(
                self.data(self.cache(items: [value])), now: self.utc("2026-10-12T07:10:00Z"))
        }
    }

    @Test func rendersEdmontonAndStockholmWinterSummerRules() throws {
        let cases = [
            ("America/Edmonton", "2026-01-15T18:00:00Z", "11:00"),
            ("America/Edmonton", "2026-07-15T18:00:00Z", "12:00"),
            ("Europe/Stockholm", "2026-01-15T18:00:00Z", "19:00"),
            ("Europe/Stockholm", "2026-07-15T18:00:00Z", "20:00"),
        ]
        for (index, item) in cases.enumerated() {
            let value = self.event(
                index: index,
                timezone: item.0,
                start: item.1,
                end: self.canonical(self.utc(item.1).addingTimeInterval(3600)))
            let decoded = try AIESAgendaContract.decodeAndValidate(
                self.data(self.cache(items: [value])),
                now: self.utc("2026-10-12T07:10:00Z"))
            let display = try AIESAgendaTimeRendering.display(for: decoded.envelope.items[0])
            #expect(display.eventTime.contains(item.2))
        }
    }

    @Test func distinctAutumnFoldInstantsRemainDistinctInBothZones() throws {
        let cases = [
            ("Europe/Stockholm", "2026-10-25T00:30:00Z", "2026-10-25T01:30:00Z", "02:30", "CEST", "CET"),
            ("America/Edmonton", "2025-11-02T07:30:00Z", "2025-11-02T08:30:00Z", "01:30", "MDT", "MST"),
        ]
        for (index, item) in cases.enumerated() {
            let first = self.event(
                index: index * 2,
                timezone: item.0,
                start: item.1,
                end: self.canonical(self.utc(item.1).addingTimeInterval(900)))
            let second = self.event(
                index: index * 2 + 1,
                timezone: item.0,
                start: item.2,
                end: self.canonical(self.utc(item.2).addingTimeInterval(900)))
            let decoded = try AIESAgendaContract.decodeAndValidate(
                self.data(self.cache(items: [first, second])),
                now: self.utc("2026-10-12T07:10:00Z"))
            #expect(decoded.envelope.items[0].startInstant != decoded.envelope.items[1].startInstant)
            let firstDisplay = try AIESAgendaTimeRendering.display(for: decoded.envelope.items[0])
            let secondDisplay = try AIESAgendaTimeRendering.display(for: decoded.envelope.items[1])
            #expect(firstDisplay.eventTime.contains(item.3))
            #expect(secondDisplay.eventTime.contains(item.3))
            #expect(firstDisplay.eventTime.contains(item.4))
            #expect(secondDisplay.eventTime.contains(item.5))
        }
    }

    @Test func foldCrossingAndMidnightCrossingRangesShowBothZonesAndDates() throws {
        let stockholmFold = self.event(
            timezone: "Europe/Stockholm",
            start: "2026-10-25T00:45:00Z",
            end: "2026-10-25T01:15:00Z")
        let foldCache = try AIESAgendaContract.decodeAndValidate(
            self.data(self.cache(items: [stockholmFold])),
            now: self.utc("2026-10-12T07:10:00Z"))
        let foldDisplay = try AIESAgendaTimeRendering.display(for: foldCache.envelope.items[0])
        #expect(foldDisplay.eventTime.contains("02:45 CEST"))
        #expect(foldDisplay.eventTime.contains("02:15 CET"))

        let midnight = self.event(
            timezone: "Europe/Stockholm",
            start: "2026-10-12T21:30:00Z",
            end: "2026-10-12T22:30:00Z")
        let midnightCache = try AIESAgendaContract.decodeAndValidate(
            self.data(self.cache(items: [midnight])),
            now: self.utc("2026-10-12T07:10:00Z"))
        let midnightDisplay = try AIESAgendaTimeRendering.display(for: midnightCache.envelope.items[0])
        #expect(midnightDisplay.eventTime.contains("Oct 12, 23:30"))
        #expect(midnightDisplay.eventTime.contains("Oct 13, 00:30"))
    }

    @Test func optionalStringsAndWarningsFollowTrancheBSchema() {
        var value = self.event()
        value["source_event_id"] = ""
        #expect(throws: AIESAgendaContractError.self) {
            try AIESAgendaContract.decodeAndValidate(
                self.data(self.cache(items: [value])), now: self.utc("2026-10-12T07:10:00Z"))
        }
        value = self.event()
        value["warnings"] = ["duplicate", "duplicate"]
        #expect(throws: AIESAgendaContractError.self) {
            try AIESAgendaContract.decodeAndValidate(
                self.data(self.cache(items: [value])), now: self.utc("2026-10-12T07:10:00Z"))
        }
        value = self.event()
        value["location"] = ""
        #expect(throws: AIESAgendaContractError.self) {
            try AIESAgendaContract.decodeAndValidate(
                self.data(self.cache(items: [value])), now: self.utc("2026-10-12T07:10:00Z"))
        }
        value = self.event()
        value["warnings"] = [""]
        #expect(throws: AIESAgendaContractError.self) {
            try AIESAgendaContract.decodeAndValidate(
                self.data(self.cache(items: [value])), now: self.utc("2026-10-12T07:10:00Z"))
        }
    }

    @Test func freshEnvelopeRejectsDegradedEventStatus() {
        var value = self.event()
        value["source_status"] = "degraded"
        #expect(throws: AIESAgendaContractError.invalidAvailability) {
            try AIESAgendaContract.decodeAndValidate(
                self.data(self.cache(items: [value])), now: self.utc("2026-10-12T07:10:00Z"))
        }
    }

    @Test func springTransitionsAndReverseCrossZoneRenderingUseEventRules() throws {
        let transitions = [
            ("America/Edmonton", "2026-03-08T08:30:00Z", "01:30"),
            ("America/Edmonton", "2026-03-08T09:30:00Z", "03:30"),
            ("Europe/Stockholm", "2026-03-29T00:30:00Z", "01:30"),
            ("Europe/Stockholm", "2026-03-29T01:30:00Z", "03:30"),
        ]
        for (index, item) in transitions.enumerated() {
            let value = self.event(
                index: index,
                timezone: item.0,
                start: item.1,
                end: self.canonical(self.utc(item.1).addingTimeInterval(900)))
            let decoded = try AIESAgendaContract.decodeAndValidate(
                self.data(self.cache(items: [value])),
                now: self.utc("2026-10-12T07:10:00Z"))
            let display = try AIESAgendaTimeRendering.display(for: decoded.envelope.items[0])
            #expect(display.eventTime.contains(item.2))
        }

        let edmontonAuthored = self.event(
            timezone: "America/Edmonton",
            start: "2026-10-12T15:00:00Z",
            end: "2026-10-12T16:00:00Z")
        let decoded = try AIESAgendaContract.decodeAndValidate(
            self.data(self.cache(items: [edmontonAuthored])),
            now: self.utc("2026-10-12T07:10:00Z"))
        let display = try AIESAgendaTimeRendering.display(
            for: decoded.envelope.items[0],
            deviceTimezone: TimeZone(identifier: "Europe/Stockholm")!)
        #expect(display.eventTime.contains("09:00"))
        #expect(display.deviceTime?.contains("17:00") == true)
    }
}
