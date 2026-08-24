import Foundation

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

/// Serializes durable delivery work while leaving task ownership with the view
/// model. Cancellation therefore fences a torn-down view immediately; a claim
/// interrupted after admission remains ambiguous for canonical reconciliation.
actor OpenClawChatOutboxCoordinator {
    private static let historyPageSize = 200
    private static let historyScanLimit = 1_000
    private static let historyMaxChars = 500_000

    private let store: OpenClawChatOutboxStore
    private let stableGatewayID: String
    private let transport: any OpenClawChatTransport
    private let afterClaimBeforeDispatch: (@Sendable () async -> Void)?

    init(
        store: OpenClawChatOutboxStore,
        stableGatewayID: String,
        transport: any OpenClawChatTransport,
        afterClaimBeforeDispatch: (@Sendable () async -> Void)? = nil)
    {
        self.store = store
        self.stableGatewayID = stableGatewayID
        self.transport = transport
        self.afterClaimBeforeDispatch = afterClaimBeforeDispatch
    }

    func enqueue(
        rawCommandID: String,
        sessionKey: String,
        text: String,
        attachments: [OpenClawChatOutboxAttachment],
        thinkingLevel: String,
        createdAt: Date = Date()) async throws -> OpenClawChatOutboxCommand
    {
        let route = try await self.routeSnapshotForEnqueue()
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

    /// Reconciles the FIFO head before comparing its stored routing contract.
    /// A bounded negative history scan is deliberately inconclusive.
    func processAvailableWork() async throws -> OpenClawChatOutboxProcessingResult {
        var transitions: [OpenClawChatOutboxProcessingResult.Transition] = []
        var commands = try await self.store.loadUnresolved()
        guard !Task.isCancelled else {
            return try await self.result(commands: commands, transitions: transitions)
        }

        let leaseResult = await self.transport.acquireOutboxRouteLease()
        guard case .available(let lease) = leaseResult else {
            guard case .unavailable(let reason) = leaseResult else {
                return try await self.result(commands: commands, transitions: transitions)
            }
            return try await self.result(
                commands: commands,
                transitions: transitions,
                deliveryGate: Self.deliveryGate(for: reason))
        }
        guard lease.stableGatewayID == self.stableGatewayID else {
            return try await self.result(
                commands: commands,
                transitions: transitions,
                deliveryGate: .gatewayMismatch)
        }
        if let routeFailure = Self.minimumRouteFailure(for: lease) {
            return try await self.result(
                commands: commands,
                transitions: transitions,
                deliveryGate: Self.deliveryGate(for: routeFailure))
        }

        let liveRoute = Self.snapshot(from: lease)
        try await self.store.saveVerifiedRouteSnapshot(liveRoute)

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
            let lease = try await self.requireLiveLease()
            let route = Self.snapshot(from: lease)
            try await self.store.saveVerifiedRouteSnapshot(route)
            let requeued = try await self.store.retryAfterRouteReview(
                rawCommandID: rawCommandID,
                newRoute: route)
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

    private func routeSnapshotForEnqueue() async throws -> OpenClawChatOutboxRouteSnapshot {
        switch await self.transport.acquireOutboxRouteLease() {
        case .available(let lease):
            guard lease.stableGatewayID == self.stableGatewayID else {
                throw OpenClawChatOutboxCoordinatorError.gatewayMismatch
            }
            if let routeFailure = Self.minimumRouteFailure(for: lease) {
                throw OpenClawChatOutboxCoordinatorError.routeUnavailable(routeFailure)
            }
            let snapshot = Self.snapshot(from: lease)
            try await self.store.saveVerifiedRouteSnapshot(snapshot)
            return snapshot
        case .unavailable(reason: .routeUnavailable):
            guard let snapshot = try await self.store.loadVerifiedRouteSnapshot() else {
                throw OpenClawChatOutboxCoordinatorError.noVerifiedOfflineRoute
            }
            return snapshot
        case .unavailable(let reason):
            throw OpenClawChatOutboxCoordinatorError.routeUnavailable(reason)
        }
    }

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
