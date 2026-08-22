import Foundation
import Observation

protocol AIESAgendaFetching: Sendable {
    func fetchAgendaCache() async throws -> Data
}

private struct AIESAgendaPersistedState: Codable, Sendable {
    static let schema = "argus.aies.agenda-local-state.v1"

    let schema: String
    let cacheData: Data?
    let sourceUnavailable: Bool
}

enum AIESAgendaPresentationState: Equatable, Sendable {
    case availableEvents
    case availableEmpty
    case staleCache
    case unavailable
}

enum AIESAgendaStaleReason: Equatable, Sendable {
    case sourceUnavailable
    case sourceDegraded
    case ageExpired
    case serverMarkedStale
}

struct AIESAgendaPresentation: Equatable, Sendable {
    let state: AIESAgendaPresentationState
    let items: [AIESAgendaEvent]
    let fetchedAt: Date?
    let sourceStatus: AIESAgendaSourceStatus?
    let lastRefreshFailed: Bool
    let staleReason: AIESAgendaStaleReason?

    var statusMessage: String {
        switch self.state {
        case .availableEvents:
            "Agenda is current."
        case .availableEmpty:
            "Calendar returned an empty cached agenda."
        case .staleCache:
            switch self.staleReason {
            case .sourceUnavailable:
                "Calendar currently unavailable. Showing last known agenda."
            case .sourceDegraded:
                "Calendar status is degraded. Showing last known agenda."
            case .ageExpired:
                "Agenda may be out of date. Showing last known agenda."
            case .serverMarkedStale, .none:
                "Showing a server-marked stale agenda."
            }
        case .unavailable:
            if self.sourceStatus == .unavailable || self.lastRefreshFailed {
                "Calendar unavailable. No validated cached agenda."
            } else {
                "Agenda has not been loaded."
            }
        }
    }
}

@MainActor
@Observable
final class AIESAgendaStore {
    static let defaultStorageKey = "aies.agenda.cache.v1"
    static let maximumPersistedBytes = AIESAgendaContract.maximumEncodedBytes + (64 * 1024)

    private(set) var presentation = AIESAgendaPresentation(
        state: .unavailable,
        items: [],
        fetchedAt: nil,
        sourceStatus: nil,
        lastRefreshFailed: false,
        staleReason: nil)
    private(set) var isRefreshing = false

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let storageKey: String
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private var validatedCache: AIESValidatedAgendaCache?

    init(
        defaults: UserDefaults = .standard,
        storageKey: String = AIESAgendaStore.defaultStorageKey,
        now: @escaping () -> Date = Date.init)
    {
        self.defaults = defaults
        self.storageKey = storageKey
        self.now = now
        self.loadPersistedCache()
    }

    func refresh(using fetcher: any AIESAgendaFetching) async {
        guard !self.isRefreshing else { return }
        self.isRefreshing = true
        defer { self.isRefreshing = false }
        do {
            let data = try await fetcher.fetchAgendaCache()
            try self.accept(data)
        } catch {
            self.markSourceUnavailable()
        }
    }

    /// Accept only a fully validated, bounded server-built cache envelope.
    ///
    /// UserDefaults is a deliberate user-directed exception to the repository's
    /// SQLite cache preference: this is one transient, versioned value and the
    /// AIES requirements explicitly prohibit introducing a new database.
    func accept(_ data: Data) throws {
        let candidate = try AIESAgendaContract.decodeAndValidate(data, now: self.now())
        if let current = self.validatedCache {
            if candidate.fetchedAt < current.fetchedAt {
                return
            }
            if candidate.fetchedAt == current.fetchedAt {
                guard candidate.encodedData == current.encodedData else {
                    throw AIESAgendaContractError.conflictingSnapshot
                }
                // Exact replay cannot repair a known outage. Require newer
                // source evidence before clearing the unavailable overlay.
                return
            }
        }
        try self.persist(cacheData: candidate.encodedData, sourceUnavailable: false)
        self.validatedCache = candidate
        self.applyPresentation(candidate, refreshFailed: false)
    }

    func markSourceUnavailable() {
        guard let cache = self.validatedCache else {
            try? self.persist(cacheData: nil, sourceUnavailable: true)
            self.presentation = AIESAgendaPresentation(
                state: .unavailable,
                items: [],
                fetchedAt: nil,
                sourceStatus: .unavailable,
                lastRefreshFailed: true,
                staleReason: .sourceUnavailable)
            return
        }
        try? self.persist(cacheData: cache.encodedData, sourceUnavailable: true)
        self.presentation = AIESAgendaPresentation(
            state: .staleCache,
            items: cache.envelope.items,
            fetchedAt: cache.fetchedAt,
            sourceStatus: .unavailable,
            lastRefreshFailed: true,
            staleReason: .sourceUnavailable)
    }

    /// Re-evaluate max-age against the injected clock. A foreground/lifecycle
    /// owner can call this without a network request, and a long-running view
    /// cannot remain "current" merely because it decoded while fresh.
    func reclassifyFreshness() {
        guard let cache = self.validatedCache else { return }
        let ageExpired = self.now().timeIntervalSince(cache.fetchedAt) > Double(cache.envelope.maxAgeSeconds)
        if ageExpired {
            let sourceUnavailable = self.presentation.lastRefreshFailed
            self.presentation = AIESAgendaPresentation(
                state: .staleCache,
                items: cache.envelope.items,
                fetchedAt: cache.fetchedAt,
                sourceStatus: sourceUnavailable ? .unavailable : cache.envelope.sourceStatus,
                lastRefreshFailed: sourceUnavailable,
                staleReason: sourceUnavailable ? .sourceUnavailable : .ageExpired)
        }
    }

    private func loadPersistedCache() {
        guard let data = self.defaults.data(forKey: self.storageKey) else { return }
        do {
            guard data.count <= Self.maximumPersistedBytes else {
                throw AIESAgendaContractError.oversized
            }
            let persisted = try PropertyListDecoder().decode(AIESAgendaPersistedState.self, from: data)
            guard persisted.schema == AIESAgendaPersistedState.schema else {
                throw AIESAgendaContractError.unsupportedSchema
            }
            if let cacheData = persisted.cacheData {
                let cache = try AIESAgendaContract.decodeAndValidate(cacheData, now: self.now())
                self.validatedCache = cache
                self.applyPresentation(cache, refreshFailed: persisted.sourceUnavailable)
            } else if persisted.sourceUnavailable {
                self.presentation = AIESAgendaPresentation(
                    state: .unavailable,
                    items: [],
                    fetchedAt: nil,
                    sourceStatus: .unavailable,
                    lastRefreshFailed: true,
                    staleReason: .sourceUnavailable)
            }
        } catch {
            // Corrupt or obsolete transient cache is ignored. Never crash or
            // reinterpret it as a healthy empty agenda.
            self.presentation = AIESAgendaPresentation(
                state: .unavailable,
                items: [],
                fetchedAt: nil,
                sourceStatus: nil,
                lastRefreshFailed: false,
                staleReason: nil)
        }
    }

    private func applyPresentation(_ cache: AIESValidatedAgendaCache, refreshFailed: Bool) {
        let state: AIESAgendaPresentationState
        let staleReason: AIESAgendaStaleReason?
        if refreshFailed || cache.locallyStale || cache.envelope.availabilityState == .staleCache {
            state = .staleCache
            if refreshFailed || cache.envelope.sourceStatus == .unavailable {
                staleReason = .sourceUnavailable
            } else if cache.envelope.sourceStatus == .degraded {
                staleReason = .sourceDegraded
            } else if cache.ageExpired {
                staleReason = .ageExpired
            } else {
                staleReason = .serverMarkedStale
            }
        } else if cache.envelope.availabilityState == .availableEvents {
            state = .availableEvents
            staleReason = nil
        } else if cache.envelope.availabilityState == .availableEmpty {
            state = .availableEmpty
            staleReason = nil
        } else {
            state = .unavailable
            staleReason = nil
        }
        self.presentation = AIESAgendaPresentation(
            state: state,
            items: cache.envelope.items,
            fetchedAt: cache.fetchedAt,
            sourceStatus: refreshFailed ? .unavailable : cache.envelope.sourceStatus,
            lastRefreshFailed: refreshFailed,
            staleReason: staleReason)
    }

    private func persist(cacheData: Data?, sourceUnavailable: Bool) throws {
        let state = AIESAgendaPersistedState(
            schema: AIESAgendaPersistedState.schema,
            cacheData: cacheData,
            sourceUnavailable: sourceUnavailable)
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let data = try encoder.encode(state)
        guard data.count <= Self.maximumPersistedBytes else {
            throw AIESAgendaContractError.oversized
        }
        self.defaults.set(data, forKey: self.storageKey)
    }
}
