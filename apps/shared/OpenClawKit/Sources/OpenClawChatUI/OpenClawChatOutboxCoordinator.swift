import Foundation

/// Cross-module owner for one gateway's durable chat FIFO. Chat, Talk, and
/// lifecycle recovery share this actor so only one coordinator can admit work
/// for a stable gateway at a time.
public actor OpenClawChatOutboxDeliveryOwner {
    private let coordinator: OpenClawChatOutboxCoordinator
    private let store: OpenClawChatOutboxStore
    private var generation: UInt64 = 1
    private var isRetired = false
    private var updateSequence: UInt64 = 0
    private var updateSubscribers: [UUID: AsyncStream<OpenClawChatOutboxDeliveryUpdate>.Continuation] = [:]
    private var workerTask: Task<Void, Never>?
    private var workerGeneration: UInt64 = 0
    private var wakeRequested = false
    private let confirmationDelaysNanoseconds: [UInt64]
    private var destructiveSessionActionActive = false
    // An opaque token is intentionally used instead of an owner-local counter.
    // Recreating an owner for the same gateway must not make an admission token
    // captured by a retired owner valid again (A -> B -> new A ABA).
    private var destructiveSessionAdmissionToken = UUID()
    private var destructiveAdmissionSubscribers: [UUID: AsyncStream<UUID>.Continuation] = [:]
    private var destructiveSessionActionWaiters: [CheckedContinuation<Void, Never>] = []
    private var enqueueAdmissionsInFlight = 0
    private var enqueueAdmissionWaiters: [CheckedContinuation<Void, Never>] = []

    public init(
        store: OpenClawChatOutboxStore,
        stableGatewayID: String,
        transport: any OpenClawChatTransport,
        confirmationDelaysNanoseconds: [UInt64] = [
            1_000_000_000,
            2_000_000_000,
            5_000_000_000,
            15_000_000_000,
            30_000_000_000,
        ])
    {
        self.store = store
        self.confirmationDelaysNanoseconds = confirmationDelaysNanoseconds
        self.coordinator = OpenClawChatOutboxCoordinator(
            store: store,
            stableGatewayID: stableGatewayID,
            transport: transport)
    }

    public func updates(bufferingNewest: Int = 32) -> AsyncStream<OpenClawChatOutboxDeliveryUpdate> {
        let (stream, continuation) = AsyncStream.makeStream(
            of: OpenClawChatOutboxDeliveryUpdate.self,
            bufferingPolicy: .bufferingNewest(max(1, bufferingNewest)))
        guard !self.isRetired else {
            continuation.finish()
            return stream
        }
        let subscriberID = UUID()
        let owner = self
        self.updateSubscribers[subscriberID] = continuation
        continuation.onTermination = { @Sendable _ in
            Task { await owner.removeUpdateSubscriber(subscriberID) }
        }
        // Streams intentionally do not retain an unbounded replay buffer. A
        // newly attached Chat/Talk observer therefore owns a fresh snapshot
        // wake so it cannot miss a fast lifecycle wake that completed before
        // registration.
        self.wakeRequested = true
        self.ensureWorker()
        return stream
    }

    public func enqueue(
        rawCommandID: String,
        sessionKey: String,
        text: String,
        attachments: [OpenClawChatOutboxAttachment],
        thinkingLevel: String,
        createdAt: Date = Date(),
        expectedDestructiveSessionAdmissionToken: UUID? = nil,
        expectedCaptureRouteSnapshot: OpenClawChatOutboxRouteSnapshot? = nil)
        async throws -> OpenClawChatOutboxCommand
    {
        _ = try self.requireCurrentGeneration()
        guard !self.destructiveSessionActionActive else {
            throw OpenClawChatOutboxDeliveryOwnerError.destructiveSessionActionInProgress
        }
        if let expectedDestructiveSessionAdmissionToken,
           expectedDestructiveSessionAdmissionToken != self.destructiveSessionAdmissionToken
        {
            throw OpenClawChatOutboxDeliveryOwnerError.destructiveSessionAdmissionChanged
        }
        self.enqueueAdmissionsInFlight += 1
        defer { self.finishEnqueueAdmission() }
        let command = try await self.coordinator.enqueue(
            rawCommandID: rawCommandID,
            sessionKey: sessionKey,
            text: text,
            attachments: attachments,
            thinkingLevel: thinkingLevel,
            createdAt: createdAt,
            expectedCaptureRouteSnapshot: expectedCaptureRouteSnapshot)
        // A successful return from storage is the persist-before-clear proof.
        // Retirement after commit may fence delivery, but must never turn that
        // committed row back into a failed enqueue that a caller could duplicate.
        self.wakeRequested = true
        self.ensureWorker()
        return command
    }

    public func destructiveSessionAdmissionToken() throws -> UUID {
        _ = try self.requireCurrentGeneration()
        guard !self.destructiveSessionActionActive else {
            throw OpenClawChatOutboxDeliveryOwnerError.destructiveSessionActionInProgress
        }
        return self.destructiveSessionAdmissionToken
    }

    public func destructiveSessionAdmissionUpdates() -> AsyncStream<UUID> {
        let (stream, continuation) = AsyncStream.makeStream(
            of: UUID.self,
            bufferingPolicy: .bufferingNewest(1))
        guard !self.isRetired else {
            continuation.finish()
            return stream
        }
        let subscriberID = UUID()
        let owner = self
        self.destructiveAdmissionSubscribers[subscriberID] = continuation
        continuation.yield(self.destructiveSessionAdmissionToken)
        continuation.onTermination = { @Sendable _ in
            Task { await owner.removeDestructiveAdmissionSubscriber(subscriberID) }
        }
        return stream
    }

    /// Capture admission requires a live, capability-complete route once. This
    /// persists the bounded route snapshot so a connected Talk capture can
    /// still enqueue if connectivity disappears before capture ends.
    public func admitCapture() async throws -> OpenClawChatOutboxCaptureAdmission {
        let admittedGeneration = try self.requireCurrentGeneration()
        let admittedToken = self.destructiveSessionAdmissionToken
        guard !self.destructiveSessionActionActive else {
            throw OpenClawChatOutboxDeliveryOwnerError.destructiveSessionActionInProgress
        }
        self.enqueueAdmissionsInFlight += 1
        defer { self.finishEnqueueAdmission() }
        let routeSnapshot = try await self.coordinator.verifyLiveRouteSnapshot()
        try self.requireCurrent(admittedGeneration)
        guard !self.destructiveSessionActionActive,
              self.destructiveSessionAdmissionToken == admittedToken
        else {
            throw OpenClawChatOutboxDeliveryOwnerError.destructiveSessionAdmissionChanged
        }
        return OpenClawChatOutboxCaptureAdmission(
            destructiveSessionAdmissionToken: admittedToken,
            routeSnapshot: routeSnapshot)
    }

    public func performDestructiveSessionAction<Result: Sendable>(
        admissionCheck: @escaping @Sendable () async throws -> Void = {},
        _ action: @escaping @Sendable () async throws -> Result) async throws -> Result
    {
        _ = try self.requireCurrentGeneration()
        guard !self.destructiveSessionActionActive else {
            throw OpenClawChatOutboxDeliveryOwnerError.destructiveSessionActionInProgress
        }
        self.destructiveSessionActionActive = true
        defer { self.finishDestructiveSessionAction() }
        await self.waitForEnqueueAdmissions()
        try Task.checkCancellation()
        _ = try self.requireCurrentGeneration()
        guard try await self.store.loadUnresolved().isEmpty else {
            throw OpenClawChatOutboxDeliveryOwnerError.unresolvedCommandsPreventDestructiveSessionAction
        }
        try Task.checkCancellation()
        _ = try self.requireCurrentGeneration()
        try await admissionCheck()
        try Task.checkCancellation()
        _ = try self.requireCurrentGeneration()
        self.destructiveSessionAdmissionToken = UUID()
        self.publishDestructiveAdmissionToken()
        return try await action()
    }

    public func wake() throws {
        _ = try self.requireCurrentGeneration()
        self.wakeRequested = true
        self.ensureWorker()
    }

    public func retrySameIdentity(rawCommandID: String) async throws {
        let admittedGeneration = try self.requireCurrentGeneration()
        try await self.coordinator.retrySameIdentity(rawCommandID: rawCommandID)
        try self.requireCurrent(admittedGeneration)
        self.wakeRequested = true
        self.ensureWorker()
    }

    public func cancelProvablyUnaccepted(rawCommandID: String) async throws {
        let admittedGeneration = try self.requireCurrentGeneration()
        try await self.coordinator.cancelProvablyUnaccepted(rawCommandID: rawCommandID)
        try self.requireCurrent(admittedGeneration)
        self.wakeRequested = true
        self.ensureWorker()
    }

    public func currentOutcome(rawCommandID: String) async throws -> OpenClawChatOutboxOutcome? {
        let admittedGeneration = try self.requireCurrentGeneration()
        if let command = try await self.store.loadUnresolved().first(where: {
            $0.rawCommandID == rawCommandID
        }) {
            try self.requireCurrent(admittedGeneration)
            return command.outcome
        }
        let receipt = try await self.store.loadRecentReceipts().first(where: {
            $0.rawCommandID == rawCommandID
        })
        try self.requireCurrent(admittedGeneration)
        return receipt?.outcome
    }

    public func unresolvedCommands() async throws -> [OpenClawChatOutboxCommand] {
        let admittedGeneration = try self.requireCurrentGeneration()
        let commands = try await self.store.loadUnresolved()
        try self.requireCurrent(admittedGeneration)
        return commands
    }

    /// Fences callbacks before a gateway-owner swap or credential purge. The
    /// underlying store's generation remains the final persistence boundary.
    public func retire() async {
        guard !self.isRetired else { return }
        self.isRetired = true
        self.generation &+= 1
        self.wakeRequested = false
        let workerTask = self.workerTask
        workerTask?.cancel()
        self.workerTask = nil
        let subscribers = self.updateSubscribers.values
        self.updateSubscribers.removeAll()
        for continuation in subscribers {
            continuation.finish()
        }
        let admissionSubscribers = self.destructiveAdmissionSubscribers.values
        self.destructiveAdmissionSubscribers.removeAll()
        for continuation in admissionSubscribers {
            continuation.finish()
        }
        await self.waitForEnqueueAdmissions()
        await self.waitForDestructiveSessionAction()
        // This is a persistence barrier: after it returns an admitted worker
        // has recorded its final not-dispatched/ambiguous classification.
        await workerTask?.value
    }

    private func makeUpdate(
        from result: OpenClawChatOutboxProcessingResult) -> OpenClawChatOutboxDeliveryUpdate
    {
        self.updateSequence &+= 1
        return OpenClawChatOutboxDeliveryUpdate(
            sequence: self.updateSequence,
            status: result.status,
            unresolvedCommands: result.unresolvedCommands,
            transitions: result.transitions.map { transition in
                switch transition {
                case .dispatched(let rawCommandID):
                    .dispatched(rawCommandID: rawCommandID)
                case .canonicalHistoryConfirmed(let rawCommandID):
                    .canonicalHistoryConfirmed(rawCommandID: rawCommandID)
                case .blocked(let rawCommandID):
                    .blocked(rawCommandID: rawCommandID)
                }
            },
            terminalReceipts: result.terminalReceipts)
    }

    private func ensureWorker() {
        guard !self.isRetired, self.workerTask == nil else { return }
        self.workerGeneration &+= 1
        let generation = self.workerGeneration
        let coordinator = self.coordinator
        self.workerTask = Task { [weak self, coordinator] in
            guard let self else { return }
            await self.runWorker(coordinator: coordinator, generation: generation)
        }
    }

    private func runWorker(
        coordinator: OpenClawChatOutboxCoordinator,
        generation: UInt64) async
    {
        var confirmationAttempt = 0
        while self.isCurrentWorker(generation) {
            if !self.wakeRequested {
                guard confirmationAttempt < self.confirmationDelaysNanoseconds.count else { break }
                let delay = self.confirmationDelaysNanoseconds[confirmationAttempt]
                do {
                    try await Task.sleep(nanoseconds: delay)
                } catch {
                    return
                }
                guard self.isCurrentWorker(generation) else { return }
                confirmationAttempt += 1
            }
            self.wakeRequested = false
            do {
                let result = try await coordinator.processAvailableWork()
                guard self.isCurrentWorker(generation) else { return }
                self.publish(self.makeUpdate(from: result))
                if result.unresolvedCommands.first.map({
                    $0.outcome == .accepted || $0.outcome == .ambiguous
                }) == true {
                    continue
                }
                confirmationAttempt = 0
                guard self.wakeRequested else { break }
            } catch {
                guard self.isCurrentWorker(generation) else { return }
                break
            }
        }
        guard self.isCurrentWorker(generation) else { return }
        self.workerTask = nil
        if self.wakeRequested {
            self.ensureWorker()
        }
    }

    private func isCurrentWorker(_ generation: UInt64) -> Bool {
        !self.isRetired && !Task.isCancelled && generation == self.workerGeneration
    }

    private func publish(_ update: OpenClawChatOutboxDeliveryUpdate) {
        for continuation in self.updateSubscribers.values {
            continuation.yield(update)
        }
    }

    private func removeUpdateSubscriber(_ id: UUID) {
        self.updateSubscribers[id] = nil
    }

    private func publishDestructiveAdmissionToken() {
        for continuation in self.destructiveAdmissionSubscribers.values {
            continuation.yield(self.destructiveSessionAdmissionToken)
        }
    }

    private func removeDestructiveAdmissionSubscriber(_ id: UUID) {
        self.destructiveAdmissionSubscribers[id] = nil
    }

    private func finishEnqueueAdmission() {
        self.enqueueAdmissionsInFlight = max(0, self.enqueueAdmissionsInFlight - 1)
        guard self.enqueueAdmissionsInFlight == 0 else { return }
        let waiters = self.enqueueAdmissionWaiters
        self.enqueueAdmissionWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    private func waitForEnqueueAdmissions() async {
        guard self.enqueueAdmissionsInFlight > 0 else { return }
        await withCheckedContinuation { self.enqueueAdmissionWaiters.append($0) }
    }

    private func finishDestructiveSessionAction() {
        self.destructiveSessionActionActive = false
        let waiters = self.destructiveSessionActionWaiters
        self.destructiveSessionActionWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    private func waitForDestructiveSessionAction() async {
        guard self.destructiveSessionActionActive else { return }
        await withCheckedContinuation { self.destructiveSessionActionWaiters.append($0) }
    }

    private func requireCurrentGeneration() throws -> UInt64 {
        guard !self.isRetired else { throw OpenClawChatOutboxError.retired }
        return self.generation
    }

    private func requireCurrent(_ admittedGeneration: UInt64) throws {
        guard !self.isRetired, self.generation == admittedGeneration else {
            throw OpenClawChatOutboxError.retired
        }
    }
}

public enum OpenClawChatOutboxDeliveryOwnerError: Error, Equatable, LocalizedError, Sendable {
    case destructiveSessionActionInProgress
    case destructiveSessionAdmissionChanged
    case unresolvedCommandsPreventDestructiveSessionAction

    public var errorDescription: String? {
        switch self {
        case .destructiveSessionActionInProgress:
            "A destructive session action is already in progress"
        case .destructiveSessionAdmissionChanged:
            "The session changed after this message capture began"
        case .unresolvedCommandsPreventDestructiveSessionAction:
            "Queued messages must be confirmed before changing this session"
        }
    }
}

public struct OpenClawChatOutboxCaptureAdmission: Hashable, Sendable {
    public let destructiveSessionAdmissionToken: UUID
    public let routeSnapshot: OpenClawChatOutboxRouteSnapshot

    public init(
        destructiveSessionAdmissionToken: UUID,
        routeSnapshot: OpenClawChatOutboxRouteSnapshot)
    {
        self.destructiveSessionAdmissionToken = destructiveSessionAdmissionToken
        self.routeSnapshot = routeSnapshot
    }
}

public struct OpenClawChatOutboxDeliveryUpdate: Sendable {
    public enum Transition: Sendable, Equatable {
        case dispatched(rawCommandID: String)
        case canonicalHistoryConfirmed(rawCommandID: String)
        case blocked(rawCommandID: String)

        public var rawCommandID: String {
            switch self {
            case .dispatched(let rawCommandID),
                 .canonicalHistoryConfirmed(let rawCommandID),
                 .blocked(let rawCommandID):
                rawCommandID
            }
        }
    }

    public let sequence: UInt64
    public let status: OpenClawChatOutboxStatus
    public let unresolvedCommands: [OpenClawChatOutboxCommand]
    public let transitions: [Transition]
    public let terminalReceipts: [OpenClawChatOutboxReceipt]
}

/// A small, non-authoritative summary suitable for chat UI status. It never
/// contains message text, attachment data, or gateway credentials.
public struct OpenClawChatOutboxStatus: Equatable, Sendable {
    public enum DeliveryGate: String, Equatable, Sendable {
        case offline
        case unsupportedClient
        case gatewayIdentityUnavailable
        case gatewayMismatch
        case capabilityUnavailable
        case operatorScopesUnavailable
        case routingContractUnavailable
    }

    public static let empty = OpenClawChatOutboxStatus()

    public let queuedCount: Int
    public let confirmingCount: Int
    public let blockedCount: Int
    public let recentExpiredCount: Int
    public let hasVerifiedRouteSnapshot: Bool
    public let headOutcome: OpenClawChatOutboxOutcome?
    public let retryableRawCommandID: String?
    public let cancellableRawCommandID: String?
    public let deliveryGate: DeliveryGate?

    public init(
        queuedCount: Int = 0,
        confirmingCount: Int = 0,
        blockedCount: Int = 0,
        recentExpiredCount: Int = 0,
        hasVerifiedRouteSnapshot: Bool = false,
        headOutcome: OpenClawChatOutboxOutcome? = nil,
        retryableRawCommandID: String? = nil,
        cancellableRawCommandID: String? = nil,
        deliveryGate: DeliveryGate? = nil)
    {
        self.queuedCount = queuedCount
        self.confirmingCount = confirmingCount
        self.blockedCount = blockedCount
        self.recentExpiredCount = recentExpiredCount
        self.hasVerifiedRouteSnapshot = hasVerifiedRouteSnapshot
        self.headOutcome = headOutcome
        self.retryableRawCommandID = retryableRawCommandID
        self.cancellableRawCommandID = cancellableRawCommandID
        self.deliveryGate = deliveryGate
    }

    public var unresolvedCount: Int {
        self.queuedCount + self.confirmingCount + self.blockedCount
    }
}

enum OpenClawChatOutboxCoordinatorError: Error, LocalizedError, Equatable, Sendable {
    case gatewayMismatch
    case noVerifiedOfflineRoute
    case routeUnavailable(OpenClawChatTransportRouteLeaseUnavailableReason)
    case noMatchingCommand
    case retryRequiresCanonicalConfirmation

    var errorDescription: String? {
        switch self {
        case .gatewayMismatch:
            "The connected gateway does not match this chat outbox."
        case .noVerifiedOfflineRoute:
            "Connect once to verify this gateway before queueing offline."
        case .routeUnavailable(let reason):
            switch reason {
            case .capabilityUnavailable:
                "This gateway does not advertise durable chat routing."
            case .operatorScopesUnavailable:
                "The authenticated connection is missing required chat scopes."
            case .routingContractUnavailable:
                "The gateway did not provide a chat routing contract."
            default:
                "The verified chat route is unavailable."
            }
        case .noMatchingCommand:
            "The queued chat command is no longer available."
        case .retryRequiresCanonicalConfirmation:
            "This message was accepted and must be confirmed through canonical history."
        }
    }
}

struct OpenClawChatOutboxProcessingResult: Sendable {
    enum Transition: Sendable, Equatable {
        case dispatched(rawCommandID: String)
        case canonicalHistoryConfirmed(rawCommandID: String)
        case blocked(rawCommandID: String)
    }

    let status: OpenClawChatOutboxStatus
    let unresolvedCommands: [OpenClawChatOutboxCommand]
    let transitions: [Transition]
    let terminalReceipts: [OpenClawChatOutboxReceipt]
}

/// Coordinates one durable gateway FIFO. Its caller owns worker lifetime; the
/// iOS product binds that lifetime to NodeAppModel rather than a Chat/Talk view.
/// Cancellation before dispatch is non-effectful, while cancellation after
/// wire admission remains ambiguous for canonical reconciliation.
actor OpenClawChatOutboxCoordinator {
    private static let historyPageSize = 200
    private static let historyScanLimit = 1_000
    private static let historyMaxChars = 500_000

    private let store: OpenClawChatOutboxStore
    private let stableGatewayID: String
    private let transport: any OpenClawChatTransport
    private let afterClaimBeforeDispatch: (@Sendable () async -> Void)?
    private let afterEnqueueRouteSaveBeforePersist: (@Sendable (String) async -> Void)?
    // Actor isolation alone does not make a multi-await route/store operation
    // atomic. Keep route evidence refresh and the storage operation that relies
    // on it in one FIFO critical section so another Chat/Talk caller cannot
    // replace verifiedAt between save and compare-and-swap persistence.
    private var routeStoreOperationActive = false
    private var routeStoreOperationWaiters: [CheckedContinuation<Void, Never>] = []

    init(
        store: OpenClawChatOutboxStore,
        stableGatewayID: String,
        transport: any OpenClawChatTransport,
        afterClaimBeforeDispatch: (@Sendable () async -> Void)? = nil,
        afterEnqueueRouteSaveBeforePersist: (@Sendable (String) async -> Void)? = nil)
    {
        self.store = store
        self.stableGatewayID = stableGatewayID
        self.transport = transport
        self.afterClaimBeforeDispatch = afterClaimBeforeDispatch
        self.afterEnqueueRouteSaveBeforePersist = afterEnqueueRouteSaveBeforePersist
    }

    func enqueue(
        rawCommandID: String,
        sessionKey: String,
        text: String,
        attachments: [OpenClawChatOutboxAttachment],
        thinkingLevel: String,
        createdAt: Date = Date(),
        expectedCaptureRouteSnapshot: OpenClawChatOutboxRouteSnapshot? = nil)
        async throws -> OpenClawChatOutboxCommand
    {
        await self.acquireRouteStoreOperation()
        defer { self.releaseRouteStoreOperation() }
        try Task.checkCancellation()
        let route = try await self.routeSnapshotForEnqueue(
            expectedCaptureRouteSnapshot: expectedCaptureRouteSnapshot)
        await self.afterEnqueueRouteSaveBeforePersist?(rawCommandID)
        let persisted = OpenClawChatOutboxDraft(
            rawCommandID: rawCommandID,
            sessionKey: sessionKey,
            text: text,
            attachments: attachments,
            thinkingLevel: thinkingLevel,
            route: route,
            createdAt: createdAt)
        return try await self.store.persistBeforeDraftClear(persisted)
    }

    func verifyLiveRouteSnapshot() async throws -> OpenClawChatOutboxRouteSnapshot {
        await self.acquireRouteStoreOperation()
        defer { self.releaseRouteStoreOperation() }
        try Task.checkCancellation()
        let lease = try await self.requireLiveLease()
        let snapshot = Self.snapshot(from: lease)
        try await self.store.saveVerifiedRouteSnapshot(snapshot)
        return snapshot
    }

    /// Reconciles the FIFO head before comparing its stored routing contract.
    /// A bounded negative history scan is deliberately inconclusive.
    func processAvailableWork() async throws -> OpenClawChatOutboxProcessingResult {
        var transitions: [OpenClawChatOutboxProcessingResult.Transition] = []
        var commands = try await self.store.loadUnresolved()
        guard !Task.isCancelled else {
            return try await self.result(commands: commands, transitions: transitions)
        }

        let routeEvidence = try await self.routeEvidenceForProcessing()
        guard case .available(let lease, let liveRoute) = routeEvidence else {
            guard case .unavailable(let deliveryGate) = routeEvidence else {
                return try await self.result(commands: commands, transitions: transitions)
            }
            return try await self.result(
                commands: commands,
                transitions: transitions,
                deliveryGate: deliveryGate)
        }

        while let head = commands.first, !Task.isCancelled {
            if head.outcome == .accepted || head.outcome == .ambiguous {
                let canonicalHistoryContainsHead = try await self.canonicalHistoryContains(
                    head,
                    using: lease)
                if canonicalHistoryContainsHead {
                    guard !Task.isCancelled else { break }
                    _ = try await self.store.confirmCanonicalHistory(
                        rawCommandID: head.rawCommandID,
                        canonicalUserIdempotencyKey: head.canonicalUserIdempotencyKey)
                    transitions.append(.canonicalHistoryConfirmed(rawCommandID: head.rawCommandID))
                    commands = try await self.store.loadUnresolved()
                    continue
                }

                // Absence is never proof of non-dispatch and never auto-requeues.
                break
            }

            guard head.outcome == .notDispatched else { break }
            guard let claim = try await self.store.claimNext() else { break }
            await self.afterClaimBeforeDispatch?()
            if Task.isCancelled {
                _ = try? await self.store.recordDispatchOutcome(.notDispatched, for: claim)
                break
            }

            guard Self.routeAllowsDispatch(stored: claim.command.route, live: liveRoute) else {
                _ = try await self.store.recordDispatchOutcome(
                    .blockedRouteChanged,
                    for: claim,
                    failureCode: OpenClawChatSessionRoutingContract.changedErrorReason)
                transitions.append(.blocked(rawCommandID: claim.command.rawCommandID))
                commands = try await self.store.loadUnresolved()
                break
            }

            let attachments = claim.command.attachments.map {
                OpenClawChatAttachmentPayload(
                    type: $0.type,
                    mimeType: $0.mimeType,
                    fileName: $0.fileName,
                    content: $0.data.base64EncodedString())
            }
            let dispatch = await lease.dispatchMessage(
                sessionKey: claim.command.sessionKey,
                message: claim.command.text,
                thinking: claim.command.thinkingLevel,
                idempotencyKey: claim.command.rawCommandID,
                attachments: attachments)
            if Task.isCancelled {
                // Admission already happened. Release only this exact CAS claim
                // into unresolved state; never turn cancellation into a replay.
                _ = try? await self.store.recordDispatchOutcome(
                    .ambiguous,
                    for: claim,
                    failureCode: "worker-cancelled-after-admission")
                break
            }

            switch dispatch {
            case .notDispatched:
                _ = try await self.store.recordDispatchOutcome(.notDispatched, for: claim)
            case .dispatchRejected(let code, let reason):
                if reason == OpenClawChatSessionRoutingContract.changedErrorReason {
                    _ = try await self.store.recordDispatchOutcome(
                        .blockedRouteChanged,
                        for: claim,
                        failureCode: Self.boundedFailureCode(reason))
                    transitions.append(.blocked(rawCommandID: claim.command.rawCommandID))
                } else {
                    _ = try await self.store.recordDispatchOutcome(
                        .dispatchRejected,
                        for: claim,
                        failureCode: Self.boundedFailureCode(code))
                    transitions.append(.blocked(rawCommandID: claim.command.rawCommandID))
                }
            case .accepted(let runID, _):
                if runID == claim.command.rawCommandID {
                    _ = try await self.store.recordDispatchOutcome(
                        .accepted,
                        for: claim,
                        ackRunID: runID)
                } else {
                    _ = try await self.store.recordDispatchOutcome(
                        .ambiguous,
                        for: claim,
                        failureCode: "ack-identity-mismatch")
                }
                transitions.append(.dispatched(rawCommandID: claim.command.rawCommandID))
            case .ambiguous(let code):
                _ = try await self.store.recordDispatchOutcome(
                    .ambiguous,
                    for: claim,
                    failureCode: Self.boundedFailureCode(code))
                transitions.append(.dispatched(rawCommandID: claim.command.rawCommandID))
            case .blockedRouteChanged:
                _ = try await self.store.recordDispatchOutcome(
                    .blockedRouteChanged,
                    for: claim,
                    failureCode: OpenClawChatSessionRoutingContract.changedErrorReason)
                transitions.append(.blocked(rawCommandID: claim.command.rawCommandID))
            }

            commands = try await self.store.loadUnresolved()
            guard dispatch.shouldContinueOutboxDrain else { break }
        }

        return try await self.result(commands: commands, transitions: transitions)
    }

    /// Explicit operator retry always preserves the raw command identity. An
    /// ambiguous command gets one final positive-history check before requeue.
    func retrySameIdentity(rawCommandID: String) async throws {
        let commands = try await self.store.loadUnresolved()
        guard let command = commands.first(where: { $0.rawCommandID == rawCommandID }) else {
            throw OpenClawChatOutboxCoordinatorError.noMatchingCommand
        }

        switch command.outcome {
        case .notDispatched:
            return
        case .dispatchRejected:
            let requeued = try await self.store.retryDispatchRejected(rawCommandID: rawCommandID)
            guard requeued else {
                throw OpenClawChatOutboxCoordinatorError.noMatchingCommand
            }
        case .blockedRouteChanged:
            await self.acquireRouteStoreOperation()
            let requeued: Bool
            do {
                try Task.checkCancellation()
                let lease = try await self.requireLiveLease()
                let route = Self.snapshot(from: lease)
                try await self.store.saveVerifiedRouteSnapshot(route)
                requeued = try await self.store.retryAfterRouteReview(
                    rawCommandID: rawCommandID,
                    newRoute: route)
                self.releaseRouteStoreOperation()
            } catch {
                self.releaseRouteStoreOperation()
                throw error
            }
            guard requeued else {
                throw OpenClawChatOutboxCoordinatorError.noMatchingCommand
            }
        case .ambiguous:
            let lease = try await self.requireLiveLease()
            let confirmed = try await self.canonicalHistoryContains(command, using: lease)
            if confirmed {
                _ = try await self.store.confirmCanonicalHistory(
                    rawCommandID: rawCommandID,
                    canonicalUserIdempotencyKey: command.canonicalUserIdempotencyKey)
                return
            }
            let requeued = try await self.store.retryAmbiguousAfterReview(rawCommandID: rawCommandID)
            guard requeued else {
                throw OpenClawChatOutboxCoordinatorError.noMatchingCommand
            }
        case .accepted:
            let lease = try await self.requireLiveLease()
            let confirmed = try await self.canonicalHistoryContains(command, using: lease)
            if confirmed {
                _ = try await self.store.confirmCanonicalHistory(
                    rawCommandID: rawCommandID,
                    canonicalUserIdempotencyKey: command.canonicalUserIdempotencyKey)
                return
            }
            throw OpenClawChatOutboxCoordinatorError.retryRequiresCanonicalConfirmation
        case .canonicalHistoryConfirmed, .expired, .cancelled:
            throw OpenClawChatOutboxCoordinatorError.noMatchingCommand
        }
    }

    /// Deletes only work that is provably not accepted: never accepted or
    /// ambiguous work. This is the safe user escape hatch for a blocked FIFO.
    func cancelProvablyUnaccepted(rawCommandID: String) async throws {
        let commands = try await self.store.loadUnresolved()
        guard let command = commands.first(where: { $0.rawCommandID == rawCommandID }) else {
            throw OpenClawChatOutboxCoordinatorError.noMatchingCommand
        }
        guard command.outcome == .notDispatched || command.outcome == .dispatchRejected ||
            command.outcome == .blockedRouteChanged
        else {
            throw OpenClawChatOutboxCoordinatorError.retryRequiresCanonicalConfirmation
        }
        let cancelled = try await self.store.cancel(rawCommandID: rawCommandID)
        guard cancelled else {
            throw OpenClawChatOutboxCoordinatorError.noMatchingCommand
        }
    }

    private func routeSnapshotForEnqueue(
        expectedCaptureRouteSnapshot: OpenClawChatOutboxRouteSnapshot? = nil)
        async throws -> OpenClawChatOutboxRouteSnapshot
    {
        let requireExpectedIdentity: (OpenClawChatOutboxRouteSnapshot) throws -> Void = { actual in
            guard let expectedCaptureRouteSnapshot else { return }
            guard Self.sameRouteIdentity(actual, expectedCaptureRouteSnapshot) else {
                throw OpenClawChatOutboxError.routeSnapshotChanged
            }
        }
        switch await self.transport.acquireOutboxRouteLease() {
        case .available(let lease):
            guard lease.stableGatewayID == self.stableGatewayID else {
                throw OpenClawChatOutboxCoordinatorError.gatewayMismatch
            }
            if let routeFailure = Self.minimumRouteFailure(for: lease) {
                throw OpenClawChatOutboxCoordinatorError.routeUnavailable(routeFailure)
            }
            let snapshot = Self.snapshot(from: lease)
            try requireExpectedIdentity(snapshot)
            try await self.store.saveVerifiedRouteSnapshot(snapshot)
            return snapshot
        case .unavailable(reason: .routeUnavailable):
            guard let snapshot = try await self.store.loadVerifiedRouteSnapshot() else {
                throw OpenClawChatOutboxCoordinatorError.noVerifiedOfflineRoute
            }
            try requireExpectedIdentity(snapshot)
            return snapshot
        case .unavailable(let reason):
            throw OpenClawChatOutboxCoordinatorError.routeUnavailable(reason)
        }
    }

    private static func sameRouteIdentity(
        _ lhs: OpenClawChatOutboxRouteSnapshot,
        _ rhs: OpenClawChatOutboxRouteSnapshot) -> Bool
    {
        lhs.routingContract == rhs.routingContract &&
            Set(lhs.capabilities) == Set(rhs.capabilities) &&
            Set(lhs.operatorScopes) == Set(rhs.operatorScopes)
    }

    private enum ProcessingRouteEvidence {
        case available(OpenClawChatTransportRouteLease, OpenClawChatOutboxRouteSnapshot)
        case unavailable(OpenClawChatOutboxStatus.DeliveryGate)
    }

    private func routeEvidenceForProcessing() async throws -> ProcessingRouteEvidence {
        await self.acquireRouteStoreOperation()
        defer { self.releaseRouteStoreOperation() }
        try Task.checkCancellation()
        switch await self.transport.acquireOutboxRouteLease() {
        case .unavailable(let reason):
            return .unavailable(Self.deliveryGate(for: reason))
        case .available(let lease):
            guard lease.stableGatewayID == self.stableGatewayID else {
                return .unavailable(.gatewayMismatch)
            }
            if let routeFailure = Self.minimumRouteFailure(for: lease) {
                return .unavailable(Self.deliveryGate(for: routeFailure))
            }
            let liveRoute = Self.snapshot(from: lease)
            try await self.store.saveVerifiedRouteSnapshot(liveRoute)
            return .available(lease, liveRoute)
        }
    }

    private func acquireRouteStoreOperation() async {
        guard self.routeStoreOperationActive else {
            self.routeStoreOperationActive = true
            return
        }
        await withCheckedContinuation { self.routeStoreOperationWaiters.append($0) }
    }

    private func releaseRouteStoreOperation() {
        guard !self.routeStoreOperationWaiters.isEmpty else {
            self.routeStoreOperationActive = false
            return
        }
        let next = self.routeStoreOperationWaiters.removeFirst()
        next.resume()
    }

    #if DEBUG
    func _test_routeStoreOperationWaiterCount() -> Int {
        self.routeStoreOperationWaiters.count
    }
    #endif

    private func requireLiveLease() async throws -> OpenClawChatTransportRouteLease {
        switch await self.transport.acquireOutboxRouteLease() {
        case .available(let lease):
            guard lease.stableGatewayID == self.stableGatewayID else {
                throw OpenClawChatOutboxCoordinatorError.gatewayMismatch
            }
            if let routeFailure = Self.minimumRouteFailure(for: lease) {
                throw OpenClawChatOutboxCoordinatorError.routeUnavailable(routeFailure)
            }
            return lease
        case .unavailable(let reason):
            throw OpenClawChatOutboxCoordinatorError.routeUnavailable(reason)
        }
    }

    private func canonicalHistoryContains(
        _ command: OpenClawChatOutboxCommand,
        using lease: OpenClawChatTransportRouteLease) async throws -> Bool
    {
        var offset = 0
        while offset < Self.historyScanLimit, !Task.isCancelled {
            let limit = min(Self.historyPageSize, Self.historyScanLimit - offset)
            let page = try await lease.requestHistoryPage(
                sessionKey: command.sessionKey,
                limit: limit,
                offset: offset,
                maxChars: Self.historyMaxChars)
            if Self.hasCanonicalUserIdentity(
                command.canonicalUserIdempotencyKey,
                in: page.payload)
            {
                return true
            }
            guard page.hasMore,
                  let nextOffset = page.nextOffset,
                  nextOffset > offset,
                  nextOffset < Self.historyScanLimit
            else {
                return false
            }
            offset = nextOffset
        }
        return false
    }

    private static func hasCanonicalUserIdentity(
        _ identity: String,
        in payload: OpenClawChatHistoryPayload) -> Bool
    {
        (payload.messages ?? []).contains { item in
            guard let message = try? ChatPayloadDecoding.decode(item, as: OpenClawChatMessage.self) else {
                return false
            }
            return message.role.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "user" &&
                message.idempotencyKey == identity
        }
    }

    private static func snapshot(
        from lease: OpenClawChatTransportRouteLease) -> OpenClawChatOutboxRouteSnapshot
    {
        OpenClawChatOutboxRouteSnapshot(
            routingContract: lease.sessionRoutingContract,
            capabilities: lease.capabilities,
            operatorScopes: lease.operatorScopes,
            verifiedAt: Date())
    }

    private static func routeAllowsDispatch(
        stored: OpenClawChatOutboxRouteSnapshot,
        live: OpenClawChatOutboxRouteSnapshot) -> Bool
    {
        let storedContract = stored.routingContract
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let liveContract = live.routingContract
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard storedContract == liveContract else { return false }

        // Full Hello evidence is retained for diagnostics, but unrelated
        // capability/scope drift is not dispatch identity. Only S3's actual
        // chat capability and minimum chat scope union gate delivery.
        let liveCapabilities = Set(live.capabilities)
        let liveScopes = Set(live.operatorScopes)
        return liveCapabilities.contains(OpenClawChatOutboxDatabase.routingCapability) &&
            Set(OpenClawChatOutboxDatabase.requiredOperatorScopes).isSubset(of: liveScopes)
    }

    private static func minimumRouteFailure(
        for lease: OpenClawChatTransportRouteLease)
        -> OpenClawChatTransportRouteLeaseUnavailableReason?
    {
        guard !lease.sessionRoutingContract.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .routingContractUnavailable
        }
        guard Set(lease.capabilities).contains(OpenClawChatOutboxDatabase.routingCapability) else {
            return .capabilityUnavailable
        }
        guard Set(OpenClawChatOutboxDatabase.requiredOperatorScopes)
            .isSubset(of: Set(lease.operatorScopes))
        else {
            return .operatorScopesUnavailable
        }
        return nil
    }

    private func result(
        commands: [OpenClawChatOutboxCommand],
        transitions: [OpenClawChatOutboxProcessingResult.Transition],
        deliveryGate: OpenClawChatOutboxStatus.DeliveryGate? = nil) async throws
        -> OpenClawChatOutboxProcessingResult
    {
        OpenClawChatOutboxProcessingResult(
            status: try await self.makeStatus(commands: commands, deliveryGate: deliveryGate),
            unresolvedCommands: commands,
            transitions: transitions,
            terminalReceipts: try await self.store.loadRecentReceipts())
    }

    private func makeStatus(
        commands: [OpenClawChatOutboxCommand],
        deliveryGate: OpenClawChatOutboxStatus.DeliveryGate? = nil) async throws
        -> OpenClawChatOutboxStatus
    {
        let receipts = try await self.store.loadRecentReceipts()
        let snapshot = try await self.store.loadVerifiedRouteSnapshot()
        let head = commands.first
        let isRetryable = head.map {
            $0.outcome == .dispatchRejected || $0.outcome == .blockedRouteChanged ||
                $0.outcome == .ambiguous
        } ?? false
        let isCancellable = head.map {
            $0.outcome == .notDispatched || $0.outcome == .dispatchRejected ||
                $0.outcome == .blockedRouteChanged
        } ?? false
        return OpenClawChatOutboxStatus(
            queuedCount: commands.filter { $0.outcome == .notDispatched }.count,
            confirmingCount: commands.filter {
                $0.outcome == .accepted || $0.outcome == .ambiguous
            }.count,
            blockedCount: commands.filter {
                $0.outcome == .dispatchRejected || $0.outcome == .blockedRouteChanged
            }.count,
            recentExpiredCount: receipts.filter { $0.outcome == .expired }.count,
            hasVerifiedRouteSnapshot: snapshot != nil,
            headOutcome: head?.outcome,
            retryableRawCommandID: isRetryable ? head?.rawCommandID : nil,
            cancellableRawCommandID: isCancellable ? head?.rawCommandID : nil,
            deliveryGate: deliveryGate)
    }

    private static func deliveryGate(
        for reason: OpenClawChatTransportRouteLeaseUnavailableReason)
        -> OpenClawChatOutboxStatus.DeliveryGate
    {
        switch reason {
        case .unsupportedTransport: .unsupportedClient
        case .gatewayIdentityUnavailable: .gatewayIdentityUnavailable
        case .gatewayMismatch: .gatewayMismatch
        case .routeUnavailable: .offline
        case .capabilityUnavailable: .capabilityUnavailable
        case .operatorScopesUnavailable: .operatorScopesUnavailable
        case .routingContractUnavailable: .routingContractUnavailable
        }
    }

    private static func boundedFailureCode(_ value: String?) -> String? {
        guard let value else { return nil }
        return String(value.prefix(256))
    }
}

private extension OpenClawChatDispatchOutcome {
    var shouldContinueOutboxDrain: Bool {
        switch self {
        case .accepted, .ambiguous:
            true
        case .notDispatched, .dispatchRejected, .blockedRouteChanged:
            false
        }
    }
}
