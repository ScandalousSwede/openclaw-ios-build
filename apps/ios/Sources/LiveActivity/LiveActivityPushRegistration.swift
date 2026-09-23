import Foundation
import Security

/// Credential metadata only: tokens stay in memory. Reserve before publication,
/// using an update rather than delete/add so interruption cannot reset a revision.
@MainActor
enum LiveActivityPushSequence {
    static let maximum: UInt64 = 9_007_199_254_740_991

    static func next() throws -> UInt64 {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "ai.openclaw.pushrelay",
            kSecAttrAccount as String: "activity-update-sequence",
        ]
        var read = query
        read[kSecReturnData as String] = true
        read[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(read as CFDictionary, &item)
        let previous: UInt64
        if status == errSecItemNotFound {
            previous = 0
        } else {
            guard status == errSecSuccess, let data = item as? Data,
                  let raw = String(data: data, encoding: .utf8), let value = UInt64(raw)
            else { throw ArgusOperationsError.unavailable }
            previous = value
        }
        guard previous < self.maximum else { throw ArgusOperationsError.unavailable }
        let next = previous + 1
        let data = Data(String(next).utf8)
        let saved: OSStatus
        if status == errSecItemNotFound {
            var insert = query
            insert[kSecValueData as String] = data
            insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            saved = SecItemAdd(insert as CFDictionary, nil)
        } else {
            saved = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        }
        guard saved == errSecSuccess else { throw ArgusOperationsError.unavailable }
        return next
    }
}

struct LiveActivityPushIdentity: Equatable {
    let activityID: String
    let reference: ArgusTaskActivityReference
    let generation: UInt64
    let expiresAtMs: Int64

    var expiresAt: Date { Date(timeIntervalSince1970: Double(self.expiresAtMs) / 1000) }
}

enum LiveActivityPushEvent: Equatable {
    case register(LiveActivityPushIdentity, token: Data, revision: UInt64)
    case retire(LiveActivityPushIdentity)

    var identity: LiveActivityPushIdentity {
        switch self {
        case let .register(identity, _, _), let .retire(identity): identity
        }
    }

    var name: String {
        switch self {
        case .register: "push.apns.activity.register"
        case .retire: "push.apns.activity.retire"
        }
    }

    func payloadJSON() throws -> String {
        struct Payload: Encodable {
            let kind = "liveActivityUpdate"
            let activityId: String
            let taskId: String
            let generation: UInt64
            var token: String?
            var requestId: String?
            var registrationRevision: UInt64?
            var expiresAtMs: Int64?
        }
        let identity = self.identity
        var payload = Payload(
            activityId: identity.activityID, taskId: identity.reference.taskID, generation: identity.generation)
        if case let .register(_, token, revision) = self {
            payload.token = token.map { String(format: "%02x", $0) }.joined()
            payload.requestId = identity.reference.requestID
            payload.registrationRevision = revision
            payload.expiresAtMs = identity.expiresAtMs
        }
        return String(decoding: try JSONEncoder().encode(payload), as: UTF8.self)
    }
}

/// Serializes token publication and retirement independently of OS rendering.
/// A transport write is unacknowledged; it never becomes a user-facing saved state.
@MainActor
final class LiveActivityPushRegistration {
    typealias Publisher = @MainActor (LiveActivityPushEvent, @escaping @MainActor () -> Bool) async -> Bool

    private let reserveRevision: @MainActor () throws -> UInt64
    private var publisher: Publisher?
    private var active: (handle: any LiveActivityHandle, identity: LiveActivityPushIdentity)?
    private var registration: LiveActivityPushEvent?
    private var pending: [LiveActivityPushEvent] = []
    private var tokenObserver: Task<Void, Never>?
    private var endObserver: Task<Void, Never>?
    private var worker: Task<Void, Never>?
    private var workRevision: UInt64 = 0

    init(reserveRevision: @escaping @MainActor () throws -> UInt64 = LiveActivityPushSequence.next) {
        self.reserveRevision = reserveRevision
    }

    deinit {
        self.tokenObserver?.cancel()
        self.endObserver?.cancel()
        self.worker?.cancel()
    }

    func configure(publisher: @escaping Publisher) {
        self.publisher = publisher
        self.republish()
    }

    func activate(_ handle: any LiveActivityHandle) {
        if self.active?.handle.id == handle.id { return }
        if let old = self.active?.handle { self.retire(old) }
        guard let reference = handle.taskReference, let task = handle.state.task,
              let generation = handle.pushGeneration, generation > 0,
              generation <= LiveActivityPushSequence.maximum,
              handle.isActive, !task.trackingEnded, !task.phase.isTerminal, task.expiresAt > .now
        else { return }
        let identity = LiveActivityPushIdentity(
            activityID: handle.id, reference: reference, generation: generation, expiresAtMs: task.expiresAtMs)
        self.active = (handle, identity)
        self.tokenObserver = Task { @MainActor [weak self] in
            if let token = handle.pushToken { self?.receive(token, identity: identity) }
            await handle.observePushTokens { [weak self] token in self?.receive(token, identity: identity) }
        }
        self.endObserver = Task { @MainActor [weak self] in
            await handle.observePushEnd { [weak self] in self?.retire(handle) }
        }
    }

    func retire(_ handle: any LiveActivityHandle) {
        if self.active?.handle.id == handle.id {
            self.tokenObserver?.cancel()
            self.endObserver?.cancel()
            self.tokenObserver = nil
            self.endObserver = nil
            self.active = nil
            self.registration = nil
        }
        self.pending.removeAll { $0.identity.activityID == handle.id }
        guard let reference = handle.taskReference, let task = handle.state.task,
              let generation = handle.pushGeneration else { return }
        self.enqueue(.retire(.init(
            activityID: handle.id, reference: reference, generation: generation, expiresAtMs: task.expiresAtMs)))
    }

    func republish() {
        self.workRevision &+= 1
        if let active, let token = active.handle.pushToken { self.receive(token, identity: active.identity) }
        if let registration, self.isCurrent(registration) { self.enqueue(registration) }
        else { self.startWorker() }
    }

    private func receive(_ token: Data, identity: LiveActivityPushIdentity) {
        guard !Task.isCancelled, self.active?.identity == identity,
              self.active?.handle.isActive == true, identity.expiresAt > .now,
              self.active?.handle.state.task?.phase.isTerminal == false,
              !token.isEmpty, token.count <= 256 else { return }
        if case let .register(_, previous, _)? = self.registration, previous == token { return }
        guard let revision = try? self.reserveRevision(), revision > 0,
              revision <= LiveActivityPushSequence.maximum else {
            // A newly issued token invalidates the old address even when secure
            // revision storage is unavailable. A connection wake rereads the OS token.
            self.registration = nil
            self.pending.removeAll { $0.identity.activityID == identity.activityID }
            return
        }
        let event = LiveActivityPushEvent.register(identity, token: token, revision: revision)
        self.registration = event
        self.enqueue(event)
    }

    private func enqueue(_ event: LiveActivityPushEvent) {
        self.pending.removeAll { $0.identity.activityID == event.identity.activityID || $0.identity.expiresAt <= .now }
        self.pending.append(event)
        // Offline retirements contain no token. The original server lease remains
        // the bound even if many manual replacements exceed the retained queue.
        if self.pending.count > 64 { self.pending.removeFirst(self.pending.count - 64) }
        self.workRevision &+= 1
        self.startWorker()
    }

    private func isCurrent(_ event: LiveActivityPushEvent) -> Bool {
        guard event.identity.expiresAt > .now else { return false }
        switch event {
        case .register:
            return self.registration == event && self.active?.identity == event.identity &&
                self.active?.handle.isActive == true && self.active?.handle.state.task?.phase.isTerminal == false
        case .retire:
            return self.pending.contains(event)
        }
    }

    private func startWorker() {
        guard self.worker == nil, self.publisher != nil, !self.pending.isEmpty else { return }
        self.worker = Task { @MainActor [weak self] in await self?.drain() }
    }

    private func drain() async {
        guard let publisher else { self.worker = nil; return }
        let revision = self.workRevision
        var attempted: [LiveActivityPushEvent] = []
        // Re-select after every await: a newly issued current token overtakes the
        // retirement backlog, including events queued during an in-flight attempt.
        while !Task.isCancelled {
            let obsolete = self.pending.filter { !self.isCurrent($0) }
            self.pending.removeAll { obsolete.contains($0) }
            let remaining = self.pending.filter { !attempted.contains($0) }
            let registration = remaining.first { event in
                if case .register = event { return true }
                return false
            }
            guard let event = registration ?? remaining.first else { break }
            attempted.append(event)
            let written = await publisher(event, { [weak self] in self?.isCurrent(event) == true })
            // A write has no server acknowledgement. The current registration
            // remains in `registration`; retain token-free retirements here for
            // reconnect replay until their original lease expires (bounded above).
            if written, case .register = event { self.pending.removeAll { $0 == event } }
            // Reconnect may enqueue the same event, already in `attempted`.
            // A new pass must give that retry priority over remaining retirements.
            if revision != self.workRevision { break }
        }
        self.worker = nil
        if revision != self.workRevision { self.startWorker() }
    }

    func waitUntilIdleForTesting() async {
        while self.worker != nil { await Task.yield() }
    }
}
