import Foundation
import Testing
@testable import OpenClaw

private struct AIESAgendaTestFetcher: AIESAgendaFetching {
    let result: Result<Data, AIESAgendaTestError>
    func fetchAgendaCache() async throws -> Data { try self.result.get() }
}

private enum AIESAgendaTestError: Error, Sendable {
    case unavailable
}

@Suite(.serialized) struct AIESAgendaStoreTests {
    private func utc(_ value: String) -> Date {
        try! AIESAgendaContract.canonicalUTCDate(value, field: "test")
    }

    private func cache(fetchedAt: String = "2026-10-12T06:55:00Z", empty: Bool = false) -> Data {
        let items: [[String: Any]] = empty ? [] : [[
            "schema": "argus.aies.event.v1",
            "event_key": "evt_00000000000000000000000000000001",
            "title": "AIES session",
            "start_instant": "2026-10-12T07:00:00Z",
            "end_instant": "2026-10-12T08:00:00Z",
            "event_timezone": "Europe/Stockholm",
            "timezone_source": "event",
            "all_day": false,
            "source": "google_calendar",
            "source_event_id": "gcal-1",
            "fetched_at": fetchedAt,
            "source_status": "available",
            "stale": false,
            "warnings": [],
        ]]
        let object: [String: Any] = [
            "schema": "argus.aies.agenda-cache.v1",
            "cache_kind": "last_known_agenda",
            "authoritative": false,
            "authority_source": "google_calendar",
            "source_status": "available",
            "source_status_at_fetch": "available",
            "availability_state": empty ? "available_empty" : "available_events",
            "fetched_at": fetchedAt,
            "cached_at": "2026-10-12T07:00:00Z",
            "age_seconds": 300,
            "max_age_seconds": 3600,
            "stale": false,
            "max_items": 256,
            "original_item_count": items.count,
            "truncated": false,
            "items": items,
        ]
        return try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    private func defaults() -> (store: UserDefaults, suiteName: String) {
        let name = "AIESAgendaStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return (defaults, name)
    }

    @Test @MainActor func acceptedCacheSurvivesRelaunch() throws {
        let fixture = self.defaults()
        let defaults = fixture.store
        defer { defaults.removePersistentDomain(forName: fixture.suiteName) }
        let now = { self.utc("2026-10-12T07:10:00Z") }
        let first = AIESAgendaStore(defaults: defaults, now: now)
        try first.accept(self.cache())
        #expect(first.presentation.state == .availableEvents)

        let reopenedDefaults = UserDefaults(suiteName: fixture.suiteName)!
        let relaunched = AIESAgendaStore(defaults: reopenedDefaults, now: now)
        #expect(relaunched.presentation.state == .availableEvents)
        #expect(relaunched.presentation.items.count == 1)
    }

    @Test @MainActor func fetchFailureKeepsTimestampedLastKnownAgendaButMarksItStale() async throws {
        let now = { self.utc("2026-10-12T07:10:00Z") }
        let fixture = self.defaults()
        defer { fixture.store.removePersistentDomain(forName: fixture.suiteName) }
        let store = AIESAgendaStore(defaults: fixture.store, now: now)
        try store.accept(self.cache())
        await store.refresh(using: AIESAgendaTestFetcher(result: .failure(AIESAgendaTestError.unavailable)))
        #expect(store.presentation.state == .staleCache)
        #expect(store.presentation.items.count == 1)
        #expect(store.presentation.fetchedAt == self.utc("2026-10-12T06:55:00Z"))
        #expect(store.presentation.statusMessage.contains("last known"))

        let reopenedDefaults = UserDefaults(suiteName: fixture.suiteName)!
        let relaunched = AIESAgendaStore(defaults: reopenedDefaults, now: now)
        #expect(relaunched.presentation.state == .staleCache)
        #expect(relaunched.presentation.sourceStatus == .unavailable)
        #expect(relaunched.presentation.lastRefreshFailed)
        #expect(relaunched.presentation.staleReason == .sourceUnavailable)

        try relaunched.accept(self.cache())
        #expect(relaunched.presentation.state == .staleCache)
        #expect(relaunched.presentation.lastRefreshFailed)

        let afterReplayDefaults = UserDefaults(suiteName: fixture.suiteName)!
        let afterReplay = AIESAgendaStore(defaults: afterReplayDefaults, now: now)
        #expect(afterReplay.presentation.state == .staleCache)
        #expect(afterReplay.presentation.lastRefreshFailed)

        try afterReplay.accept(self.cache(fetchedAt: "2026-10-12T06:56:00Z"))
        #expect(afterReplay.presentation.state == .availableEvents)
        #expect(!afterReplay.presentation.lastRefreshFailed)
    }

    @Test @MainActor func healthyEmptyIsTheOnlyStateThatSaysNoEvents() throws {
        let fixture = self.defaults()
        defer { fixture.store.removePersistentDomain(forName: fixture.suiteName) }
        let store = AIESAgendaStore(
            defaults: fixture.store,
            now: { self.utc("2026-10-12T07:10:00Z") })
        try store.accept(self.cache(empty: true))
        #expect(store.presentation.state == .availableEmpty)
        #expect(store.presentation.statusMessage.contains("empty cached agenda"))
        store.markSourceUnavailable()
        #expect(store.presentation.state == .staleCache)
        #expect(!store.presentation.statusMessage.contains("empty cached agenda"))
    }

    @Test @MainActor func unavailableWithoutCacheNeverLooksEmpty() {
        let fixture = self.defaults()
        defer { fixture.store.removePersistentDomain(forName: fixture.suiteName) }
        let store = AIESAgendaStore(defaults: fixture.store)
        store.markSourceUnavailable()
        #expect(store.presentation.state == .unavailable)
        #expect(store.presentation.statusMessage.contains("unavailable"))
        #expect(!store.presentation.statusMessage.contains("No events"))

        let reopenedDefaults = UserDefaults(suiteName: fixture.suiteName)!
        let relaunched = AIESAgendaStore(defaults: reopenedDefaults)
        #expect(relaunched.presentation.state == .unavailable)
        #expect(relaunched.presentation.sourceStatus == .unavailable)
        #expect(relaunched.presentation.lastRefreshFailed)
    }

    @Test @MainActor func malformedOrOlderResponseNeverOverwritesValidCache() throws {
        let fixture = self.defaults()
        let defaults = fixture.store
        defer { defaults.removePersistentDomain(forName: fixture.suiteName) }
        let store = AIESAgendaStore(
            defaults: defaults,
            now: { self.utc("2026-10-12T07:10:00Z") })
        try store.accept(self.cache())
        let preserved = defaults.data(forKey: AIESAgendaStore.defaultStorageKey)
        #expect(throws: AIESAgendaContractError.self) { try store.accept(Data("{}".utf8)) }
        #expect(defaults.data(forKey: AIESAgendaStore.defaultStorageKey) == preserved)
        try store.accept(self.cache(fetchedAt: "2026-10-12T06:50:00Z"))
        #expect(defaults.data(forKey: AIESAgendaStore.defaultStorageKey) == preserved)

        let rawConflict = try JSONSerialization.jsonObject(with: self.cache())
        var conflicting = try #require(rawConflict as? [String: Any])
        var items = try #require(conflicting["items"] as? [[String: Any]])
        items[0]["title"] = "Conflicting equal-timestamp title"
        conflicting["items"] = items
        let conflictingData = try JSONSerialization.data(withJSONObject: conflicting, options: [.sortedKeys])
        #expect(throws: AIESAgendaContractError.conflictingSnapshot) {
            try store.accept(conflictingData)
        }
    }

    @Test @MainActor func corruptPersistedDataDoesNotCrashOrClaimEmpty() {
        let fixture = self.defaults()
        let defaults = fixture.store
        defer { defaults.removePersistentDomain(forName: fixture.suiteName) }
        defaults.set(Data("not-json".utf8), forKey: AIESAgendaStore.defaultStorageKey)
        let store = AIESAgendaStore(defaults: defaults)
        #expect(store.presentation.state == .unavailable)
        #expect(store.presentation.statusMessage == "Agenda has not been loaded.")
    }

    @Test @MainActor func initialStateDoesNotClaimCalendarFailureBeforeAProbe() {
        let fixture = self.defaults()
        defer { fixture.store.removePersistentDomain(forName: fixture.suiteName) }
        let store = AIESAgendaStore(defaults: fixture.store)
        #expect(store.presentation.state == .unavailable)
        #expect(store.presentation.sourceStatus == nil)
        #expect(!store.presentation.lastRefreshFailed)
        #expect(store.presentation.statusMessage == "Agenda has not been loaded.")
    }

    @Test @MainActor func explicitClockAdvanceReclassifiesFreshCacheWithoutNetwork() throws {
        let fixture = self.defaults()
        defer { fixture.store.removePersistentDomain(forName: fixture.suiteName) }
        var current = self.utc("2026-10-12T07:10:00Z")
        let store = AIESAgendaStore(defaults: fixture.store, now: { current })
        try store.accept(self.cache())
        #expect(store.presentation.state == .availableEvents)
        current = self.utc("2026-10-12T08:10:00Z")
        store.reclassifyFreshness()
        #expect(store.presentation.state == .staleCache)
        #expect(store.presentation.staleReason == .ageExpired)
        #expect(!store.presentation.statusMessage.contains("unavailable"))
    }

    @Test func lastUpdatedCopyIncludesDateTimeAndDisplayZone() {
        let instant = self.utc("2026-10-12T06:55:00Z")
        let displayTimezone = TimeZone(identifier: "Europe/Stockholm")!
        let rendered = AIESAgendaTimeRendering.lastUpdated(
            instant,
            displayTimezone: displayTimezone)
        let zoneFormatter = DateFormatter()
        zoneFormatter.calendar = Calendar(identifier: .gregorian)
        zoneFormatter.locale = Locale(identifier: "en_US_POSIX")
        zoneFormatter.timeZone = displayTimezone
        zoneFormatter.dateFormat = "z"
        let expectedZoneToken = zoneFormatter.string(from: instant)
        #expect(rendered.contains("2026-10-12"))
        #expect(rendered.contains("08:55"))
        #expect(displayTimezone.secondsFromGMT(for: instant) == 7_200)
        #expect(rendered.hasSuffix(" \(expectedZoneToken)"))
    }
}
