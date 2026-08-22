import Foundation

enum AIESAgendaSourceStatus: String, Codable, Sendable {
    case available
    case degraded
    case unavailable
}

enum AIESAgendaAvailabilityState: String, Codable, Sendable {
    case availableEvents = "available_events"
    case availableEmpty = "available_empty"
    case unavailable
    case degraded
    case staleCache = "stale_cache"
}

struct AIESAgendaEvent: Codable, Equatable, Sendable, Identifiable {
    let schema: String
    let eventKey: String
    let title: String
    let startInstant: String
    let endInstant: String
    let eventTimezone: String
    let timezoneSource: String
    let allDay: Bool
    let source: String
    let sourceEventID: String?
    let location: String?
    let fetchedAt: String
    let sourceStatus: AIESAgendaSourceStatus
    let stale: Bool
    let warnings: [String]

    var id: String { self.eventKey }

    enum CodingKeys: String, CodingKey {
        case schema
        case eventKey = "event_key"
        case title
        case startInstant = "start_instant"
        case endInstant = "end_instant"
        case eventTimezone = "event_timezone"
        case timezoneSource = "timezone_source"
        case allDay = "all_day"
        case source
        case sourceEventID = "source_event_id"
        case location
        case fetchedAt = "fetched_at"
        case sourceStatus = "source_status"
        case stale
        case warnings
    }
}

struct AIESAgendaCacheEnvelope: Codable, Equatable, Sendable {
    let schema: String
    let cacheKind: String
    let authoritative: Bool
    let authoritySource: String
    let sourceStatus: AIESAgendaSourceStatus
    let sourceStatusAtFetch: AIESAgendaSourceStatus
    let availabilityState: AIESAgendaAvailabilityState
    let fetchedAt: String
    let cachedAt: String
    let ageSeconds: Int
    let maxAgeSeconds: Int
    let stale: Bool
    let maxItems: Int
    let originalItemCount: Int
    let truncated: Bool
    let items: [AIESAgendaEvent]

    enum CodingKeys: String, CodingKey {
        case schema
        case cacheKind = "cache_kind"
        case authoritative
        case authoritySource = "authority_source"
        case sourceStatus = "source_status"
        case sourceStatusAtFetch = "source_status_at_fetch"
        case availabilityState = "availability_state"
        case fetchedAt = "fetched_at"
        case cachedAt = "cached_at"
        case ageSeconds = "age_seconds"
        case maxAgeSeconds = "max_age_seconds"
        case stale
        case maxItems = "max_items"
        case originalItemCount = "original_item_count"
        case truncated
        case items
    }
}

struct AIESValidatedAgendaCache: Sendable {
    let envelope: AIESAgendaCacheEnvelope
    let encodedData: Data
    let fetchedAt: Date
    let cachedAt: Date
    let ageExpired: Bool
    let locallyStale: Bool
}

enum AIESAgendaContractError: Error, Equatable {
    case oversized
    case malformed(String)
    case unsupportedSchema
    case authoritativeCache
    case invalidInstant(String)
    case invalidTimezone(String)
    case invalidAvailability
    case invalidBounds
    case duplicateEventKey(String)
    case conflictingSnapshot
}

enum AIESAgendaContract {
    static let schema = "argus.aies.agenda-cache.v1"
    static let eventSchema = "argus.aies.event.v1"
    static let maximumEncodedBytes = 256 * 1024
    static let maximumItems = 256
    static let allowedClockSkewSeconds: TimeInterval = 300

    private static let cacheKeys: Set<String> = [
        "schema", "cache_kind", "authoritative", "authority_source", "source_status",
        "source_status_at_fetch", "availability_state", "fetched_at", "cached_at",
        "age_seconds", "max_age_seconds", "stale", "max_items", "original_item_count",
        "truncated", "items",
    ]
    private static let eventRequiredKeys: Set<String> = [
        "schema", "event_key", "title", "start_instant", "end_instant", "event_timezone",
        "timezone_source", "all_day", "source", "source_event_id", "fetched_at",
        "source_status", "stale", "warnings",
    ]
    private static let eventAllowedKeys = eventRequiredKeys.union(["location"])

    static func decodeAndValidate(_ data: Data, now: Date = Date()) throws -> AIESValidatedAgendaCache {
        guard data.count <= Self.maximumEncodedBytes else { throw AIESAgendaContractError.oversized }
        try Self.validateObjectShape(data)

        let envelope: AIESAgendaCacheEnvelope
        do {
            envelope = try JSONDecoder().decode(AIESAgendaCacheEnvelope.self, from: data)
        } catch {
            throw AIESAgendaContractError.malformed("cache JSON does not match the typed contract")
        }

        guard envelope.schema == Self.schema, envelope.cacheKind == "last_known_agenda" else {
            throw AIESAgendaContractError.unsupportedSchema
        }
        guard !envelope.authoritative else { throw AIESAgendaContractError.authoritativeCache }
        guard !envelope.authoritySource.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AIESAgendaContractError.malformed("authority_source is empty")
        }
        guard envelope.ageSeconds >= 0, envelope.maxAgeSeconds >= 0,
              (1...Self.maximumItems).contains(envelope.maxItems),
              envelope.items.count <= envelope.maxItems,
              envelope.originalItemCount >= envelope.items.count
        else {
            throw AIESAgendaContractError.invalidBounds
        }
        guard envelope.truncated == (envelope.originalItemCount > envelope.items.count) else {
            throw AIESAgendaContractError.invalidBounds
        }

        let fetchedAt = try Self.canonicalUTCDate(envelope.fetchedAt, field: "fetched_at")
        let cachedAt = try Self.canonicalUTCDate(envelope.cachedAt, field: "cached_at")
        guard fetchedAt <= cachedAt.addingTimeInterval(Self.allowedClockSkewSeconds),
              cachedAt <= now.addingTimeInterval(Self.allowedClockSkewSeconds)
        else {
            throw AIESAgendaContractError.invalidInstant("cache timestamps are in the future or reversed")
        }

        var keys = Set<String>()
        for event in envelope.items {
            guard event.schema == Self.eventSchema else { throw AIESAgendaContractError.unsupportedSchema }
            guard event.eventKey.range(of: #"^evt_[0-9a-f]{32}$"#, options: .regularExpression) != nil else {
                throw AIESAgendaContractError.malformed("event_key is invalid")
            }
            guard keys.insert(event.eventKey).inserted else {
                throw AIESAgendaContractError.duplicateEventKey(event.eventKey)
            }
            guard !event.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !event.source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else {
                throw AIESAgendaContractError.malformed("event title/source is empty")
            }
            if let sourceEventID = event.sourceEventID,
               sourceEventID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            {
                throw AIESAgendaContractError.malformed("source_event_id is empty")
            }
            if let location = event.location,
               location.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            {
                throw AIESAgendaContractError.malformed("location is empty")
            }
            let normalizedWarnings = event.warnings.map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            guard normalizedWarnings.allSatisfy({ !$0.isEmpty }),
                  Set(normalizedWarnings).count == normalizedWarnings.count
            else {
                throw AIESAgendaContractError.malformed("warnings must be non-empty and unique")
            }
            guard event.timezoneSource == "event" || event.timezoneSource == "default" else {
                throw AIESAgendaContractError.invalidTimezone(event.eventTimezone)
            }
            guard Self.isCanonicalIANAIdentity(event.eventTimezone) else {
                throw AIESAgendaContractError.invalidTimezone(event.eventTimezone)
            }
            let start = try Self.canonicalUTCDate(event.startInstant, field: "start_instant")
            let end = try Self.canonicalUTCDate(event.endInstant, field: "end_instant")
            _ = try Self.canonicalUTCDate(event.fetchedAt, field: "event.fetched_at")
            guard end > start else { throw AIESAgendaContractError.invalidInstant("event end is not after start") }
            if event.allDay {
                guard let timezone = TimeZone(identifier: event.eventTimezone) else {
                    throw AIESAgendaContractError.invalidTimezone(event.eventTimezone)
                }
                var calendar = Calendar(identifier: .gregorian)
                calendar.timeZone = timezone
                let fields: Set<Calendar.Component> = [.hour, .minute, .second, .nanosecond]
                let startFields = calendar.dateComponents(fields, from: start)
                let endFields = calendar.dateComponents(fields, from: end)
                guard startFields.hour == 0, startFields.minute == 0, startFields.second == 0,
                      startFields.nanosecond == 0, endFields.hour == 0, endFields.minute == 0,
                      endFields.second == 0, endFields.nanosecond == 0
                else {
                    throw AIESAgendaContractError.invalidInstant(
                        "all-day event boundaries must be local midnight")
                }
            }
        }

        try Self.validateAvailability(envelope)
        let ageExpired = now.timeIntervalSince(fetchedAt) > Double(envelope.maxAgeSeconds)
        let locallyStale = envelope.stale || ageExpired
        return AIESValidatedAgendaCache(
            envelope: envelope,
            encodedData: data,
            fetchedAt: fetchedAt,
            cachedAt: cachedAt,
            ageExpired: ageExpired,
            locallyStale: locallyStale)
    }

    static func canonicalUTCDate(_ value: String, field: String) throws -> Date {
        guard value.range(
            of: #"^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(?:\.[0-9]{1,6})?Z$"#,
            options: .regularExpression) != nil
        else {
            throw AIESAgendaContractError.invalidInstant(field)
        }
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let withoutFraction = ISO8601DateFormatter()
        withoutFraction.formatOptions = [.withInternetDateTime]
        guard let parsed = withFraction.date(from: value) ?? withoutFraction.date(from: value) else {
            throw AIESAgendaContractError.invalidInstant(field)
        }
        return parsed
    }

    static func isCanonicalIANAIdentity(_ value: String) -> Bool {
        if value == "UTC" { return true }
        guard value.range(
            of: #"^[A-Za-z0-9._+-]+(?:/[A-Za-z0-9._+-]+)+$"#,
            options: .regularExpression) != nil
        else { return false }
        return TimeZone(identifier: value) != nil
    }

    private static func validateObjectShape(_ data: Data) throws {
        let raw: Any
        do {
            raw = try JSONSerialization.jsonObject(with: data, options: [])
        } catch {
            throw AIESAgendaContractError.malformed("cache is not JSON")
        }
        guard let object = raw as? [String: Any], Set(object.keys) == Self.cacheKeys,
              let items = object["items"] as? [Any]
        else {
            throw AIESAgendaContractError.malformed("cache fields do not match the schema")
        }
        for item in items {
            guard let event = item as? [String: Any],
                  Self.eventRequiredKeys.isSubset(of: Set(event.keys)),
                  Set(event.keys).isSubset(of: Self.eventAllowedKeys)
            else {
                throw AIESAgendaContractError.malformed("event fields do not match the schema")
            }
        }
    }

    private static func validateAvailability(_ envelope: AIESAgendaCacheEnvelope) throws {
        if envelope.stale {
            guard envelope.availabilityState == .staleCache,
                  envelope.items.allSatisfy(\.stale)
            else { throw AIESAgendaContractError.invalidAvailability }
            return
        }
        guard envelope.sourceStatus == .available,
              envelope.sourceStatusAtFetch == .available,
              envelope.items.allSatisfy({ !$0.stale && $0.sourceStatus == .available })
        else { throw AIESAgendaContractError.invalidAvailability }
        switch envelope.availabilityState {
        case .availableEvents where !envelope.items.isEmpty:
            return
        case .availableEmpty where envelope.items.isEmpty:
            return
        default:
            throw AIESAgendaContractError.invalidAvailability
        }
    }
}
