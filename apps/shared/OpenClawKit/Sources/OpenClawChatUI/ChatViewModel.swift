import Foundation
import Observation
import OpenClawKit
import OSLog

private let chatUILogger = Logger(subsystem: "ai.openclaw", category: "OpenClawChatUI")

@MainActor
@Observable
// swiftlint:disable:next type_body_length
public final class OpenClawChatViewModel {
    public static let defaultModelSelectionID = "__default__"
    static let maxAttachmentBytes = 5_000_000

    public private(set) var messages: [OpenClawChatMessage] = [] {
        didSet { self.messageProjectionGeneration &+= 1 }
    }
    public var input: String = "" {
        didSet {
            if self.input != oldValue { self.draftRevision &+= 1 }
        }
    }
    public private(set) var thinkingLevel: String
    public private(set) var thinkingLevelOptions: [OpenClawChatThinkingLevelOption]
    public private(set) var modelSelectionID: String = "__default__"
    public private(set) var modelChoices: [OpenClawChatModelChoice] = []
    public private(set) var isLoading = false
    public private(set) var isSending = false
    public private(set) var isAborting = false
    public var errorText: String?
    public var attachments: [OpenClawPendingAttachment] = [] {
        didSet { self.draftRevision &+= 1 }
    }
    public private(set) var healthOK: Bool = false
    public private(set) var pendingRunCount: Int = 0
    public private(set) var outboxStatus: OpenClawChatOutboxStatus = .empty

    public private(set) var sessionKey: String
    public private(set) var sessionId: String?
    public private(set) var streamingAssistantText: String?
    public private(set) var pendingToolCalls: [OpenClawChatPendingToolCall] = []
    public private(set) var sessions: [OpenClawChatSessionEntry] = []
    private let transport: any OpenClawChatTransport
    private let outboxCoordinator: OpenClawChatOutboxDeliveryOwner?
    private let ownsOutboxCoordinator: Bool
    private var sessionDefaults: OpenClawChatSessionsDefaults?
    private let prefersExplicitThinkingLevel: Bool
    private let onSessionChanged: (@MainActor (String) -> Void)?
    private let onThinkingLevelChanged: (@MainActor @Sendable (String) -> Void)?
    private let diagnosticsLog: (@MainActor @Sendable (String) -> Void)?

    @ObservationIgnored
    private nonisolated(unsafe) var eventTask: Task<Void, Never>?
    private var eventSubscriptionGeneration: UInt64 = 0
    @ObservationIgnored
    private nonisolated(unsafe) var bootstrapTask: Task<Void, Never>?
    @ObservationIgnored
    private nonisolated(unsafe) var outboxWorkerTask: Task<Void, Never>?
    @ObservationIgnored
    private nonisolated(unsafe) var outboxUpdateTask: Task<Void, Never>?
    private var pendingRuns = Set<String>() {
        didSet { self.pendingRunCount = self.pendingRuns.count }
    }
    private var isShutDown = false
    private var outboxWorkerGeneration: UInt64 = 0
    private var outboxWakeRequested = false
    private var lastAppliedOutboxUpdateSequence: UInt64 = 0
    private var draftRevision: UInt64 = 0

    private var pendingLocalUserEchoMessageIDsByRunID: [String: UUID] = [:]
    // Canonical rows observed directly on the live session stream remain
    // provisional until a history response acknowledges their transcript ID.
    // This is deliberately scoped to a trailing live suffix so bounded history
    // cannot resurrect arbitrary rows from an older transcript window.
    private var liveCanonicalMessageIDsByIdentity: [String: UUID] = [:]
    private var sessionGeneration: UInt64 = 0
    private var bootstrapGeneration: UInt64 = 0
    // A newer same-session history request only invalidates older responses after it applies.
    // Failed later refreshes must not drop the last successful pending-run history payload.
    private var lastIssuedHistoryRequestID: UInt64 = 0
    private var latestAppliedHistoryRequestID: UInt64 = 0
    private var historyErrorReceipt: HistoryErrorReceipt?
    @ObservationIgnored
    private var lastCompletedMessageProjection: MessageProjectionSignature?
    @ObservationIgnored
    private var nextMessageProjectionID: UInt64 = 0
    @ObservationIgnored
    private var messageProjectionGeneration: UInt64 = 0
    @ObservationIgnored
    private var nextEventApplicationID: UInt64 = 0

    @ObservationIgnored
    private nonisolated(unsafe) var pendingRunTimeoutTasks: [String: Task<Void, Never>] = [:]
    private let pendingRunTimeoutMs: UInt64 = 120_000
    private static let postSendRefreshDelaysMs: [UInt64] = [
        1500,
        4000,
        9000,
        20000,
        45000,
        90000,
    ]
    // Session switches can overlap in-flight picker patches, so stale completions
    // must compare against the latest request and latest desired value for that session.
    private var nextModelSelectionRequestID: UInt64 = 0
    private var latestModelSelectionRequestIDsBySession: [String: UInt64] = [:]
    private var latestModelSelectionIDsBySession: [String: String] = [:]
    private var lastSuccessfulModelSelectionIDsBySession: [String: String] = [:]
    private var inFlightModelPatchCountsBySession: [String: Int] = [:]
    private var modelPatchWaitersBySession: [String: [CheckedContinuation<Void, Never>]] = [:]
    private var nextThinkingSelectionRequestID: UInt64 = 0
    private var latestThinkingSelectionRequestIDsBySession: [String: UInt64] = [:]
    private var latestThinkingLevelsBySession: [String: String] = [:]
    private var isCompacting = false
    private var lastCompactAt: Date?
    private let compactCooldown: TimeInterval = 60

    private enum SessionSwitchIntent {
        case userInitiated
        case externalSync
    }

    private struct SessionSnapshot: Sendable {
        var key: String
        var generation: UInt64
    }

    private struct BootstrapContext {
        var id: UInt64
        var historyRequest: HistoryRequest

        var session: SessionSnapshot {
            self.historyRequest.session
        }
    }

    private struct HistoryRequest {
        var id: UInt64
        var session: SessionSnapshot
        var latestUserTurn: LatestUserTurn?
    }

    private struct HistoryErrorReceipt {
        var requestID: UInt64
        var session: SessionSnapshot
        var message: String
    }

    private struct LatestUserTurn {
        var refreshKey: String?
        var occurrence: Int
        var timestamp: Double?
    }

    struct MessageProjectionContext {
        fileprivate var id: UInt64
        fileprivate var sessionGeneration: UInt64
        fileprivate var inputMessageCount: Int
        fileprivate var sessionKey: String
    }

    private struct MessageProjectionSignature: Equatable {
        var sessionGeneration: UInt64
        var projectionGeneration: UInt64
        var inputMessageCount: Int
    }

    private enum HistoryRefreshOutcome: Equatable {
        case applied
        case discarded
        case invalidRequest
        case transientFailure

        var didApply: Bool {
            self == .applied
        }

        var permitsBoundedRetry: Bool {
            switch self {
            case .applied, .discarded, .transientFailure:
                true
            case .invalidRequest:
                false
            }
        }
    }

    private var pendingToolCallsById: [String: OpenClawChatPendingToolCall] = [:] {
        didSet {
            self.pendingToolCalls = self.pendingToolCallsById.values
                .sorted { ($0.startedAt ?? 0) < ($1.startedAt ?? 0) }
        }
    }

    private var lastHealthPollAt: Date?

    public init(
        sessionKey: String,
        transport: any OpenClawChatTransport,
        initialThinkingLevel: String? = nil,
        outboxDeliveryOwner: OpenClawChatOutboxDeliveryOwner? = nil,
        outboxStore: OpenClawChatOutboxStore? = nil,
        outboxStableGatewayID: String? = nil,
        onSessionChanged: (@MainActor (String) -> Void)? = nil,
        onThinkingLevelChanged: (@MainActor @Sendable (String) -> Void)? = nil,
        diagnosticsLog: (@MainActor @Sendable (String) -> Void)? = nil)
    {
        self.sessionKey = sessionKey
        self.transport = transport
        let normalizedGatewayID = outboxStableGatewayID?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let outboxDeliveryOwner {
            self.outboxCoordinator = outboxDeliveryOwner
            self.ownsOutboxCoordinator = false
        } else if let outboxStore,
           let stableGatewayID = normalizedGatewayID,
           !stableGatewayID.isEmpty
        {
            self.outboxCoordinator = OpenClawChatOutboxDeliveryOwner(
                store: outboxStore,
                stableGatewayID: stableGatewayID,
                transport: transport)
            self.ownsOutboxCoordinator = true
        } else {
            self.outboxCoordinator = nil
            self.ownsOutboxCoordinator = false
        }
        let normalizedThinkingLevel = Self.normalizedThinkingLevel(initialThinkingLevel)
        let initialResolvedThinkingLevel = normalizedThinkingLevel ?? "off"
        self.thinkingLevel = initialResolvedThinkingLevel
        self.thinkingLevelOptions = Self.withCurrentThinkingOption(
            Self.baseThinkingLevelOptions,
            current: initialResolvedThinkingLevel)
        self.prefersExplicitThinkingLevel = normalizedThinkingLevel != nil
        self.onSessionChanged = onSessionChanged
        self.onThinkingLevelChanged = onThinkingLevelChanged
        self.diagnosticsLog = diagnosticsLog

        self.startEventSubscription()
        if let outboxCoordinator = self.outboxCoordinator {
            self.outboxUpdateTask = Task { [weak self, outboxCoordinator] in
                let updates = await outboxCoordinator.updates()
                for await update in updates {
                    if Task.isCancelled { return }
                    await MainActor.run { [weak self] in
                        self?.applyOutboxResult(update)
                    }
                }
            }
        }
    }

    deinit {
        self.eventTask?.cancel()
        self.bootstrapTask?.cancel()
        self.outboxWorkerTask?.cancel()
        self.outboxUpdateTask?.cancel()
        if self.ownsOutboxCoordinator, let outboxCoordinator = self.outboxCoordinator {
            Task { await outboxCoordinator.retire() }
        }
        for (_, task) in self.pendingRunTimeoutTasks {
            task.cancel()
        }
    }

    public func shutdown() {
        guard !self.isShutDown else { return }
        self.isShutDown = true
        self.eventSubscriptionGeneration &+= 1
        self.outboxWorkerGeneration &+= 1
        self.outboxWakeRequested = false
        self.outboxWorkerTask?.cancel()
        self.outboxWorkerTask = nil
        self.outboxUpdateTask?.cancel()
        self.outboxUpdateTask = nil
        if self.ownsOutboxCoordinator, let outboxCoordinator = self.outboxCoordinator {
            Task { await outboxCoordinator.retire() }
        }
        self.eventTask?.cancel()
        self.eventTask = nil
        self.bootstrapTask?.cancel()
        self.bootstrapTask = nil
        for (_, task) in self.pendingRunTimeoutTasks {
            task.cancel()
        }
        self.pendingRunTimeoutTasks.removeAll()
    }

    public func load() {
        self.startBootstrap()
        self.kickOutboxWorker(reason: "load")
    }

    public func refresh() {
        self.startBootstrap()
        self.kickOutboxWorker(reason: "refresh")
    }

    public func resumeFromForeground() {
        Task { await self.refreshPendingRunAfterForeground() }
        self.kickOutboxWorker(reason: "foreground")
    }

    public func send() {
        self.logDiagnostic(
            "chat.ui send invoked sessionKey=\(self.sessionKey) "
                + "inputLen=\(self.input.count) attachments=\(self.attachments.count) "
                + "pending=\(self.pendingRunCount) sending=\(self.isSending) "
                + "health=\(self.healthOK)")
        Task { await self.performSend() }
    }

    public func abort() {
        Task { await self.performAbort() }
    }

    public func retryHeadOutboxCommand() {
        guard let rawCommandID = self.outboxStatus.retryableRawCommandID,
              let coordinator = self.outboxCoordinator
        else { return }
        Task { [weak self, coordinator] in
            do {
                try await coordinator.retrySameIdentity(rawCommandID: rawCommandID)
                guard !Task.isCancelled else { return }
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.clearPendingRun(rawCommandID)
                    self.kickOutboxWorker(reason: "manual-retry")
                    let context = self.beginHistoryRequest()
                    Task { [weak self] in
                        _ = await self?.refreshHistoryAfterRun(historyRequest: context)
                    }
                }
            } catch {
                await MainActor.run { [weak self] in
                    self?.errorText = error.localizedDescription
                }
            }
        }
    }

    public func cancelHeadOutboxCommand() {
        guard let rawCommandID = self.outboxStatus.cancellableRawCommandID,
              let coordinator = self.outboxCoordinator
        else { return }
        Task { [weak self, coordinator] in
            do {
                try await coordinator.cancelProvablyUnaccepted(rawCommandID: rawCommandID)
                guard !Task.isCancelled else { return }
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.removeOptimisticOutboxMessage(rawCommandID: rawCommandID)
                    self.kickOutboxWorker(reason: "safe-cancel")
                }
            } catch {
                await MainActor.run { [weak self] in
                    self?.errorText = error.localizedDescription
                }
            }
        }
    }

    public func refreshSessions(limit: Int? = nil) {
        let context = self.currentSessionSnapshot()
        Task { await self.fetchSessions(limit: limit, sessionSnapshot: context) }
    }

    public func switchSession(to sessionKey: String) {
        self.applySessionSwitch(to: sessionKey, intent: .userInitiated)
    }

    public func syncSession(to sessionKey: String) {
        self.applySessionSwitch(to: sessionKey, intent: .externalSync)
    }

    public func selectThinkingLevel(_ level: String) {
        Task { await self.performSelectThinkingLevel(level) }
    }

    public func selectModel(_ selectionID: String) {
        Task { await self.performSelectModel(selectionID) }
    }

    public var sessionChoices: [OpenClawChatSessionEntry] {
        let now = Date().timeIntervalSince1970 * 1000
        let cutoff = now - (24 * 60 * 60 * 1000)
        let sorted = self.sessions.sorted { ($0.updatedAt ?? 0) > ($1.updatedAt ?? 0) }
        let mainSessionKey = self.resolvedMainSessionKey

        var result: [OpenClawChatSessionEntry] = []
        var included = Set<String>()

        // Always show the resolved main session first, even if it hasn't been updated recently.
        if let main = sorted.first(where: { $0.key == mainSessionKey }) {
            result.append(main)
            included.insert(main.key)
        } else {
            result.append(self.placeholderSession(key: mainSessionKey))
            included.insert(mainSessionKey)
        }

        for entry in sorted {
            guard !included.contains(entry.key) else { continue }
            guard entry.key == self.sessionKey || !Self.isHiddenInternalSession(entry.key) else { continue }
            guard (entry.updatedAt ?? 0) >= cutoff else { continue }
            result.append(entry)
            included.insert(entry.key)
        }

        if !included.contains(self.sessionKey) {
            if let current = sorted.first(where: { $0.key == self.sessionKey }) {
                result.append(current)
            } else {
                result.append(self.placeholderSession(key: self.sessionKey))
            }
        }

        return result
    }

    var resolvedMainSessionKey: String {
        let trimmed = self.sessionDefaults?.mainSessionKey?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmed?.isEmpty == false ? trimmed : nil) ?? "main"
    }

    private static func isHiddenInternalSession(_ key: String) -> Bool {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return trimmed == "onboarding" || trimmed.hasSuffix(":onboarding")
    }

    public var showsModelPicker: Bool {
        !self.modelChoices.isEmpty
    }

    public var defaultModelLabel: String {
        guard let defaultModelID = normalizedModelSelectionID(sessionDefaults?.model) else {
            return "Default"
        }
        return "Default: \(self.modelLabel(for: defaultModelID))"
    }

    private static let baseThinkingLevelOptions: [OpenClawChatThinkingLevelOption] = [
        OpenClawChatThinkingLevelOption(id: "off", label: "off"),
        OpenClawChatThinkingLevelOption(id: "minimal", label: "minimal"),
        OpenClawChatThinkingLevelOption(id: "low", label: "low"),
        OpenClawChatThinkingLevelOption(id: "medium", label: "medium"),
        OpenClawChatThinkingLevelOption(id: "high", label: "high"),
    ]

    public func addAttachments(urls: [URL]) {
        Task { await self.loadAttachments(urls: urls) }
    }

    public func addImageAttachment(data: Data, fileName: String, mimeType: String) {
        Task { await self.addImageAttachment(url: nil, data: data, fileName: fileName, mimeType: mimeType) }
    }

    public func removeAttachment(_ id: OpenClawPendingAttachment.ID) {
        self.attachments.removeAll { $0.id == id }
    }

    public var canSend: Bool {
        let deliveryAvailable = if self.supportsDurableOutbox {
            if let gate = self.outboxStatus.deliveryGate, gate != .offline {
                false
            } else {
                self.healthOK || self.canQueueOffline
            }
        } else {
            self.pendingRunCount == 0
        }
        return !self.isSending && deliveryAvailable && self.hasDraftToSend
    }

    public var supportsDurableOutbox: Bool {
        self.outboxCoordinator != nil
    }

    public var canQueueOffline: Bool {
        self.supportsDurableOutbox && self.outboxStatus.hasVerifiedRouteSnapshot &&
            (self.outboxStatus.deliveryGate == nil || self.outboxStatus.deliveryGate == .offline)
    }

    public var hasDraftToSend: Bool {
        let trimmed = self.input.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty || !self.attachments.isEmpty
    }

    public var canSendDraft: Bool {
        !self.isSending && self.hasDraftToSend
    }

    // MARK: - Internals

    private func logDiagnostic(_ message: String) {
        self.diagnosticsLog?(message)
    }

    private func recordChatDiagnostic(
        state: String,
        session: SessionSnapshot? = nil,
        diagnosticAttemptID: String? = nil,
        stream: String? = nil,
        resultClass: String? = nil,
        eventCount: Int? = nil,
        messageCount: Int? = nil)
    {
        let session = session ?? self.currentSessionSnapshot()
        OpenClawDiagnosticRecorder.record(OpenClawDiagnosticEvent(
            kind: .chat,
            state: state,
            sessionIdentifier: session.key,
            diagnosticAttemptID: diagnosticAttemptID,
            stream: stream,
            resultClass: resultClass,
            eventCount: eventCount,
            messageCount: messageCount,
            sessionGeneration: session.generation))
    }

    func chatViewAppeared() {
        self.recordChatDiagnostic(
            state: "chat_view_appeared",
            resultClass: "success",
            messageCount: self.messages.count)
    }

    func chatViewDisappeared() {
        self.recordChatDiagnostic(
            state: "chat_view_disappeared",
            resultClass: "success",
            messageCount: self.messages.count)
    }

    func beginMessageListProjection(inputMessageCount: Int) -> MessageProjectionContext? {
        let session = self.currentSessionSnapshot()
        let signature = MessageProjectionSignature(
            sessionGeneration: session.generation,
            projectionGeneration: self.messageProjectionGeneration,
            inputMessageCount: inputMessageCount)
        guard signature != self.lastCompletedMessageProjection else { return nil }
        self.nextMessageProjectionID &+= 1
        let context = MessageProjectionContext(
            id: self.nextMessageProjectionID,
            sessionGeneration: session.generation,
            inputMessageCount: inputMessageCount,
            sessionKey: session.key)
        self.recordChatDiagnostic(
            state: "message_list_projection_started",
            session: session,
            diagnosticAttemptID: "message-projection-\(context.id)",
            resultClass: "requested",
            messageCount: inputMessageCount)
        return context
    }

    func completeMessageListProjection(
        _ context: MessageProjectionContext?,
        outputMessageCount: Int)
    {
        guard let context else { return }
        let session = SessionSnapshot(
            key: context.sessionKey,
            generation: context.sessionGeneration)
        self.recordChatDiagnostic(
            state: "message_list_projection_completed",
            session: session,
            diagnosticAttemptID: "message-projection-\(context.id)",
            resultClass: "success",
            messageCount: outputMessageCount)
        guard self.isCurrentSession(session) else { return }
        self.lastCompletedMessageProjection = MessageProjectionSignature(
            sessionGeneration: context.sessionGeneration,
            projectionGeneration: self.messageProjectionGeneration,
            inputMessageCount: context.inputMessageCount)
    }

    private static func diagnosticStream(for event: OpenClawChatTransportEvent) -> String {
        switch event {
        case .health: "health"
        case .tick: "tick"
        case .chat: "chat"
        case .sessionMessage: "session_message"
        case .agent: "agent"
        case .seqGap: "seq_gap"
        }
    }

    private static func isInvalidRequest(_ error: Error) -> Bool {
        guard let responseError = error as? GatewayResponseError else { return false }
        return responseError.code.caseInsensitiveCompare("INVALID_REQUEST") == .orderedSame
    }

    private func currentSessionSnapshot() -> SessionSnapshot {
        SessionSnapshot(key: self.sessionKey, generation: self.sessionGeneration)
    }

    private func isCurrentSession(_ snapshot: SessionSnapshot) -> Bool {
        !self.isShutDown &&
            self.sessionKey == snapshot.key &&
            self.sessionGeneration == snapshot.generation
    }

    private func isCurrentBootstrap(_ context: BootstrapContext) -> Bool {
        self.bootstrapGeneration == context.id && self.isCurrentSession(context.session)
    }

    private func canApplyHistory(_ request: HistoryRequest) -> Bool {
        request.id >= self.latestAppliedHistoryRequestID && self.isCurrentSession(request.session)
    }

    private func advanceSessionGeneration() {
        self.sessionGeneration &+= 1
        self.startEventSubscription()
    }

    private func startEventSubscription() {
        guard !self.isShutDown else { return }
        self.eventSubscriptionGeneration &+= 1
        let subscriptionGeneration = self.eventSubscriptionGeneration
        self.eventTask?.cancel()
        let eventTransport = self.transport
        self.eventTask = Task { [weak self, eventTransport] in
            let stream = eventTransport.events()
            for await evt in stream {
                if Task.isCancelled { return }
                await MainActor.run { [weak self] in
                    self?.applyTransportEvent(
                        evt,
                        admittedSubscriptionGeneration: subscriptionGeneration)
                }
            }
        }
    }

    private func applyTransportEvent(
        _ event: OpenClawChatTransportEvent,
        admittedSubscriptionGeneration: UInt64)
    {
        guard !self.isShutDown,
              self.eventSubscriptionGeneration == admittedSubscriptionGeneration
        else { return }
        let stream = Self.diagnosticStream(for: event)
        self.nextEventApplicationID &+= 1
        let attemptID = "event-\(admittedSubscriptionGeneration)-\(self.nextEventApplicationID)-\(stream)"
        self.recordChatDiagnostic(
            state: "event_batch_application_started",
            diagnosticAttemptID: attemptID,
            stream: stream,
            resultClass: "requested",
            eventCount: 1,
            messageCount: self.messages.count)
        self.handleTransportEvent(event)
        self.recordChatDiagnostic(
            state: "event_batch_application_completed",
            diagnosticAttemptID: attemptID,
            stream: stream,
            resultClass: "success",
            eventCount: 1,
            messageCount: self.messages.count)
    }

    #if DEBUG
    func _test_eventSubscriptionGeneration() -> UInt64 {
        self.eventSubscriptionGeneration
    }

    func _test_applyTransportEvent(
        _ event: OpenClawChatTransportEvent,
        admittedSubscriptionGeneration: UInt64)
    {
        self.applyTransportEvent(
            event,
            admittedSubscriptionGeneration: admittedSubscriptionGeneration)
    }

    func _test_applyOutboxResult(_ result: OpenClawChatOutboxDeliveryUpdate) {
        self.applyOutboxResult(result)
    }

    func _test_performReset(preserving commandInput: String) async {
        await self.performReset(preserving: commandInput, clearInputOnAdmission: true)
    }

    func _test_performCompact(preserving commandInput: String) async {
        await self.performCompact(preserving: commandInput)
    }

    func _test_performStartNewSession(preserving commandInput: String) async {
        await self.performStartNewSession(preserving: commandInput)
    }
    #endif

    private func applySuccessfulDestructiveSessionMutation() {
        self.advanceSessionGeneration()
        self.messages = []
        self.pendingLocalUserEchoMessageIDsByRunID.removeAll()
        self.liveCanonicalMessageIDsByIdentity.removeAll()
        self.sessionId = nil
        self.pendingToolCallsById = [:]
        self.streamingAssistantText = nil
        self.clearPendingRuns(reason: nil)
    }

    private func beginHistoryRequest(
        for sessionSnapshot: SessionSnapshot? = nil,
        captureLatestUserTurn: Bool = true) -> HistoryRequest
    {
        self.lastIssuedHistoryRequestID &+= 1
        return HistoryRequest(
            id: self.lastIssuedHistoryRequestID,
            session: sessionSnapshot ?? self.currentSessionSnapshot(),
            latestUserTurn: captureLatestUserTurn ? Self.latestUserTurn(in: self.messages) : nil)
    }

    private func markHistoryRequestApplied(_ request: HistoryRequest) {
        self.latestAppliedHistoryRequestID = max(self.latestAppliedHistoryRequestID, request.id)
    }

    private func applyHistoryError(_ error: Error, for request: HistoryRequest) {
        guard request.id == self.lastIssuedHistoryRequestID,
              self.isCurrentSession(request.session)
        else { return }
        let message = error.localizedDescription
        self.errorText = message
        self.historyErrorReceipt = HistoryErrorReceipt(
            requestID: request.id,
            session: request.session,
            message: message)
    }

    private func clearHistoryErrorIfOwned(by request: HistoryRequest) {
        guard let receipt = self.historyErrorReceipt,
              receipt.session.key == request.session.key,
              receipt.session.generation == request.session.generation,
              request.id >= receipt.requestID,
              self.errorText == receipt.message
        else { return }
        self.errorText = nil
        self.historyErrorReceipt = nil
    }

    @discardableResult
    private func applyHistoryPayload(
        _ payload: OpenClawChatHistoryPayload,
        for request: HistoryRequest,
        preservingOptimisticLocalMessages: Bool,
        syncThinkingOptions: Bool = false) -> Bool
    {
        let attemptID = "history-\(request.session.generation)-\(request.id)"
        guard self.canApplyHistory(request) else {
            self.recordChatDiagnostic(
                state: "history_application_rejected",
                session: request.session,
                diagnosticAttemptID: attemptID,
                resultClass: "interrupted",
                messageCount: self.messages.count)
            return false
        }
        self.recordChatDiagnostic(
            state: "history_application_started",
            session: request.session,
            diagnosticAttemptID: attemptID,
            resultClass: "requested",
            messageCount: payload.messages?.count ?? 0)
        let previous = self.messages
        let incoming = Self.decodeMessages(payload.messages ?? [])
        self.messages = if preservingOptimisticLocalMessages {
            Self.reconcileRunRefreshMessages(
                previous: previous,
                incoming: incoming,
                pendingLocalUserEchoIDs: Set(self.pendingLocalUserEchoMessageIDsByRunID.values),
                liveCanonicalMessageIDs: Set(self.liveCanonicalMessageIDsByIdentity.values))
        } else {
            Self.reconcileMessageIDs(previous: previous, incoming: incoming)
        }
        self.reconcileLiveCanonicalMessageTracking(with: incoming)
        self.prunePendingLocalUserEchoMessageIDs()
        self.sessionId = payload.sessionId
        // Incomplete refreshes can arrive before durable assistant history.
        // The latest visible user turn must survive answered before it can reject older replies.
        let canInvalidateOlderHistory = if let latestUserTurn = request.latestUserTurn {
            Self.hasAnsweredUser(latestUserTurn, in: self.messages)
        } else {
            !Self.hasUnansweredLatestUser(in: self.messages)
        }
        if canInvalidateOlderHistory {
            self.markHistoryRequestApplied(request)
        }
        let appliedThinkingLevel = !self.prefersExplicitThinkingLevel
            ? Self.normalizedThinkingLevel(payload.thinkingLevel)
            : nil
        if let level = appliedThinkingLevel {
            self.thinkingLevel = level
        }
        if syncThinkingOptions || appliedThinkingLevel != nil {
            self.syncThinkingLevelOptions()
        }
        self.recordChatDiagnostic(
            state: "history_application_completed",
            session: request.session,
            diagnosticAttemptID: attemptID,
            resultClass: "success",
            messageCount: self.messages.count)
        return true
    }

    private func startBootstrap(sessionKey requestedSessionKey: String? = nil) {
        let sessionKey = requestedSessionKey ?? self.sessionKey
        guard sessionKey == self.sessionKey else { return }
        self.bootstrapGeneration &+= 1
        let historyRequest = self.beginHistoryRequest(captureLatestUserTurn: requestedSessionKey == nil)
        let context = BootstrapContext(
            id: bootstrapGeneration,
            historyRequest: historyRequest)
        self.bootstrapTask?.cancel()
        self.isLoading = true
        self.errorText = nil
        self.historyErrorReceipt = nil
        self.healthOK = false
        self.clearPendingRuns(reason: nil)
        self.pendingToolCallsById = [:]
        self.streamingAssistantText = nil
        self.sessionId = nil
        self.bootstrapTask = Task { [weak self] in
            guard let self else { return }
            await self.bootstrap(context: context)
        }
    }

    private func bootstrap(context: BootstrapContext) async {
        guard self.isCurrentBootstrap(context) else { return }
        defer {
            if self.isCurrentBootstrap(context) {
                self.isLoading = false
                self.kickOutboxWorker(reason: "bootstrap-complete")
            }
        }
        do {
            await self.syncActiveSessionSubscription(startingWith: context.session.key)
            guard self.isCurrentBootstrap(context) else { return }

            let historyAttemptID = "history-\(context.session.generation)-\(context.historyRequest.id)"
            self.recordChatDiagnostic(
                state: "history_request_started",
                session: context.session,
                diagnosticAttemptID: historyAttemptID,
                resultClass: "requested",
                messageCount: self.messages.count)
            let payload = try await transport.requestHistory(sessionKey: context.session.key)
            guard self.isCurrentBootstrap(context) else { return }
            self.recordChatDiagnostic(
                state: "history_request_succeeded",
                session: context.session,
                diagnosticAttemptID: historyAttemptID,
                resultClass: "success",
                messageCount: payload.messages?.count ?? 0)
            let applied = self.applyHistoryPayload(
                payload,
                for: context.historyRequest,
                preservingOptimisticLocalMessages: false,
                syncThinkingOptions: true)
            if applied {
                self.clearHistoryErrorIfOwned(by: context.historyRequest)
            }
            await self.pollHealthIfNeeded(force: true, sessionSnapshot: context.session)
            guard self.isCurrentBootstrap(context) else { return }
            await self.fetchSessions(limit: 50, sessionSnapshot: context.session)
            guard self.isCurrentBootstrap(context) else { return }
            await self.fetchModels(sessionSnapshot: context.session)
            guard self.isCurrentBootstrap(context) else { return }
        } catch {
            guard self.isCurrentBootstrap(context) else { return }
            self.recordChatDiagnostic(
                state: "history_request_rejected",
                session: context.session,
                diagnosticAttemptID: "history-\(context.session.generation)-\(context.historyRequest.id)",
                resultClass: Self.isInvalidRequest(error) ? "gateway_rejected" : "failed",
                messageCount: self.messages.count)
            self.applyHistoryError(error, for: context.historyRequest)
            chatUILogger.error("bootstrap failed \(error.localizedDescription, privacy: .public)")
        }
    }

    private func syncActiveSessionSubscription(startingWith sessionKey: String) async {
        var nextSessionKey = sessionKey
        while true {
            do {
                // Subscribe requests are gateway side effects. If a stale request finishes
                // after a newer switch, immediately reassert the latest visible session.
                try await self.transport.setActiveSessionKey(nextSessionKey)
            } catch {
                let currentSessionKey = self.sessionKey
                guard currentSessionKey != nextSessionKey else {
                    // Best-effort only; history/send/health still work without push events.
                    return
                }
                nextSessionKey = currentSessionKey
                continue
            }
            let currentSessionKey = self.sessionKey
            guard currentSessionKey != nextSessionKey else { return }
            nextSessionKey = currentSessionKey
        }
    }

    private func refreshPendingRunAfterForeground() async {
        guard self.pendingRunCount > 0 else { return }
        let context = self.beginHistoryRequest()
        self.logDiagnostic(
            "chat.ui foreground refresh sessionKey=\(context.session.key) "
                + "pending=\(self.pendingRunCount)")
        await self.refreshHistoryAfterRun(historyRequest: context)
        await self.pollHealthIfNeeded(force: true, sessionSnapshot: context.session)
        guard self.isCurrentSession(context.session) else { return }
        if self.hasAssistantMessageAfterLatestUser() {
            self.clearPendingRuns(reason: nil)
            self.pendingToolCallsById = [:]
            self.streamingAssistantText = nil
        }
    }

    private static func decodeMessages(_ raw: [AnyCodable]) -> [OpenClawChatMessage] {
        let decoded = raw.compactMap { item in
            (try? ChatPayloadDecoding.decode(item, as: OpenClawChatMessage.self))
                .map { Self.stripInboundMetadata(from: $0) }
        }
        return Self.dedupeMessages(decoded)
    }

    private static func stripInboundMetadata(from message: OpenClawChatMessage) -> OpenClawChatMessage {
        guard message.role.lowercased() == "user" else {
            return message
        }

        let sanitizedContent = message.content.map { content -> OpenClawChatMessageContent in
            guard let text = content.text else { return content }
            let cleaned = ChatMarkdownPreprocessor.preprocess(markdown: text).cleaned
            return OpenClawChatMessageContent(
                type: content.type,
                text: cleaned,
                thinking: content.thinking,
                thinkingSignature: content.thinkingSignature,
                mimeType: content.mimeType,
                fileName: content.fileName,
                content: content.content,
                id: content.id,
                name: content.name,
                arguments: content.arguments)
        }

        return OpenClawChatMessage(
            id: message.id,
            role: message.role,
            content: sanitizedContent,
            timestamp: message.timestamp,
            transcriptMessageID: message.transcriptMessageID,
            idempotencyKey: message.idempotencyKey,
            toolCallId: message.toolCallId,
            toolName: message.toolName,
            usage: message.usage,
            stopReason: message.stopReason,
            errorMessage: message.errorMessage)
    }

    private static func messageContentFingerprint(for message: OpenClawChatMessage) -> String {
        message.content.map { item in
            let type = (item.type ?? "text").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let text = (item.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let id = (item.id ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let name = (item.name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let fileName = (item.fileName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return [type, text, id, name, fileName].joined(separator: "\\u{001F}")
        }.joined(separator: "\\u{001E}")
    }

    private static func messageIdentityKey(for message: OpenClawChatMessage) -> String? {
        let role = message.role.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !role.isEmpty else { return nil }

        if let idempotencyKey = Self.idempotencyIdentityKey(for: message) {
            return idempotencyKey
        }
        if let canonicalKey = Self.canonicalTranscriptIdentityKey(for: message) {
            return canonicalKey
        }

        let timestamp: String = {
            guard let value = message.timestamp, value.isFinite else { return "" }
            return String(format: "%.3f", value)
        }()

        let contentFingerprint = Self.messageContentFingerprint(for: message)
        let toolCallId = (message.toolCallId ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let toolName = (message.toolName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if timestamp.isEmpty, contentFingerprint.isEmpty, toolCallId.isEmpty, toolName.isEmpty {
            return nil
        }
        return [role, timestamp, toolCallId, toolName, contentFingerprint].joined(separator: "|")
    }

    private static func normalizedTranscriptMessageID(_ id: String?) -> String? {
        let trimmed = id?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func idempotencyIdentityKey(for message: OpenClawChatMessage) -> String? {
        let role = message.role.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let key = message.idempotencyKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard role == "user", !key.isEmpty else { return nil }
        return [role, "idempotency", key].joined(separator: "|")
    }

    private static func canonicalTranscriptIdentityKey(for message: OpenClawChatMessage) -> String? {
        let role = message.role.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !role.isEmpty,
              let transcriptMessageID = Self.normalizedTranscriptMessageID(message.transcriptMessageID)
        else {
            return nil
        }
        return [role, "transcript", transcriptMessageID].joined(separator: "|")
    }

    private static func userRefreshIdentityKey(for message: OpenClawChatMessage) -> String? {
        let role = message.role.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard role == "user" else { return nil }

        let contentFingerprint = Self.messageContentFingerprint(for: message)
        let toolCallId = (message.toolCallId ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let toolName = (message.toolName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if contentFingerprint.isEmpty, toolCallId.isEmpty, toolName.isEmpty {
            return nil
        }
        return [role, toolCallId, toolName, contentFingerprint].joined(separator: "|")
    }

    private func prunePendingLocalUserEchoMessageIDs() {
        guard !self.pendingLocalUserEchoMessageIDsByRunID.isEmpty else { return }
        let visibleMessageIDs = Set(messages.map(\.id))
        self.pendingLocalUserEchoMessageIDsByRunID = self.pendingLocalUserEchoMessageIDsByRunID.filter {
            self.pendingRuns.contains($0.key) && visibleMessageIDs.contains($0.value)
        }
    }

    private func trackLiveCanonicalMessage(_ message: OpenClawChatMessage) {
        guard let identityKey = Self.canonicalTranscriptIdentityKey(for: message),
              let visible = self.messages.last(where: {
                  Self.canonicalTranscriptIdentityKey(for: $0) == identityKey
              })
        else {
            return
        }
        self.liveCanonicalMessageIDsByIdentity[identityKey] = visible.id
    }

    private func reconcileLiveCanonicalMessageTracking(with incoming: [OpenClawChatMessage]) {
        guard !self.liveCanonicalMessageIDsByIdentity.isEmpty else { return }
        let acknowledgedIdentityKeys = Set(incoming.compactMap(Self.canonicalTranscriptIdentityKey(for:)))
        let visibleByID = self.messages.reduce(into: [UUID: OpenClawChatMessage]()) {
            $0[$1.id] = $1
        }
        self.liveCanonicalMessageIDsByIdentity = self.liveCanonicalMessageIDsByIdentity.filter {
            identityKey, messageID in
            guard !acknowledgedIdentityKeys.contains(identityKey),
                  let visible = visibleByID[messageID]
            else {
                return false
            }
            return Self.canonicalTranscriptIdentityKey(for: visible) == identityKey
        }
    }

    private func adoptPendingLocalUserEcho(incoming: OpenClawChatMessage) -> Bool {
        guard let incomingKey = Self.userRefreshIdentityKey(for: incoming) else { return false }
        let candidateMessageIDs: Set<UUID>
        if let canonicalKey = incoming.idempotencyKey,
           canonicalKey.hasSuffix(":user")
        {
            let rawCommandID = String(canonicalKey.dropLast(":user".count))
            guard let exactMessageID = self.pendingLocalUserEchoMessageIDsByRunID[rawCommandID] else {
                return false
            }
            candidateMessageIDs = [exactMessageID]
        } else {
            // Legacy echoes have no durable key. They may match only work that
            // is actually in flight, never an offline queued row with similar text.
            candidateMessageIDs = Set(self.pendingLocalUserEchoMessageIDsByRunID.compactMap {
                self.pendingRuns.contains($0.key) ? $0.value : nil
            })
        }
        guard let matchIndex = messages.lastIndex(where: { existing in
            candidateMessageIDs.contains(existing.id) &&
                Self.userRefreshIdentityKey(for: existing) == incomingKey
        }) else {
            return false
        }

        let existing = self.messages[matchIndex]
        self.pendingLocalUserEchoMessageIDsByRunID = self.pendingLocalUserEchoMessageIDsByRunID.filter {
            $0.value != existing.id
        }
        var updated = self.messages
        updated[matchIndex] = OpenClawChatMessage(
            id: existing.id,
            role: incoming.role,
            content: incoming.content,
            timestamp: incoming.timestamp ?? existing.timestamp,
            transcriptMessageID: incoming.transcriptMessageID ?? existing.transcriptMessageID,
            idempotencyKey: incoming.idempotencyKey ?? existing.idempotencyKey,
            toolCallId: incoming.toolCallId,
            toolName: incoming.toolName,
            usage: incoming.usage,
            stopReason: incoming.stopReason,
            errorMessage: incoming.errorMessage)
        self.messages = Self.dedupeMessages(updated)
        self.prunePendingLocalUserEchoMessageIDs()
        return true
    }

    private static func reconcileMessageIDs(
        previous: [OpenClawChatMessage],
        incoming: [OpenClawChatMessage]) -> [OpenClawChatMessage]
    {
        guard !previous.isEmpty, !incoming.isEmpty else { return incoming }

        var idsByKey: [String: [UUID]] = [:]
        for message in previous {
            guard let key = Self.messageIdentityKey(for: message) else { continue }
            idsByKey[key, default: []].append(message.id)
        }

        return incoming.map { message in
            guard let key = Self.messageIdentityKey(for: message),
                  var ids = idsByKey[key],
                  let reusedId = ids.first
            else {
                return message
            }
            ids.removeFirst()
            if ids.isEmpty {
                idsByKey.removeValue(forKey: key)
            } else {
                idsByKey[key] = ids
            }
            guard reusedId != message.id else { return message }
            return OpenClawChatMessage(
                id: reusedId,
                role: message.role,
                content: message.content,
                timestamp: message.timestamp,
                transcriptMessageID: message.transcriptMessageID,
                idempotencyKey: message.idempotencyKey,
                toolCallId: message.toolCallId,
                toolName: message.toolName,
                usage: message.usage,
                stopReason: message.stopReason,
                errorMessage: message.errorMessage)
        }
    }

    private static func reconcileRunRefreshMessages(
        previous: [OpenClawChatMessage],
        incoming: [OpenClawChatMessage],
        pendingLocalUserEchoIDs: Set<UUID>,
        liveCanonicalMessageIDs: Set<UUID>) -> [OpenClawChatMessage]
    {
        guard !previous.isEmpty else { return incoming }
        guard !incoming.isEmpty else { return previous }

        func countKeys(_ keys: [String]) -> [String: Int] {
            keys.reduce(into: [:]) { counts, key in
                counts[key, default: 0] += 1
            }
        }

        var reconciled = Self.reconcileMessageIDs(previous: previous, incoming: incoming)
        let incomingIdentityKeys = Set(reconciled.compactMap(Self.messageIdentityKey(for:)))
        var remainingIncomingUserRefreshCounts = countKeys(
            reconciled.compactMap(Self.userRefreshIdentityKey(for:)))

        // Exact history rows own their incoming user count before local echo matching.
        // Otherwise repeated same-text sends can consume the canonical row twice.
        for message in previous {
            guard let identityKey = Self.messageIdentityKey(for: message),
                  incomingIdentityKeys.contains(identityKey),
                  let userKey = Self.userRefreshIdentityKey(for: message),
                  let remaining = remainingIncomingUserRefreshCounts[userKey],
                  remaining > 0
            else {
                continue
            }
            remainingIncomingUserRefreshCounts[userKey] = remaining - 1
        }

        let lastCanonicalPreviousIndex = previous.lastIndex { message in
            guard let identityKey = Self.messageIdentityKey(for: message) else { return false }
            return incomingIdentityKeys.contains(identityKey)
        }
        let trailingLocalCandidates = lastCanonicalPreviousIndex.map { index in
            previous[previous.index(after: index)...]
        } ?? []

        let pendingLocalUsers = previous.filter { message in
            message.role.lowercased() == "user" && pendingLocalUserEchoIDs.contains(message.id)
        }
        let trailingLocalUsers = trailingLocalCandidates.filter { message in
            guard message.role.lowercased() == "user" else { return false }
            guard let identityKey = Self.messageIdentityKey(for: message) else { return true }
            guard !incomingIdentityKeys.contains(identityKey) else { return false }
            guard let userKey = Self.userRefreshIdentityKey(for: message) else { return true }
            let remaining = remainingIncomingUserRefreshCounts[userKey] ?? 0
            if remaining > 0 {
                remainingIncomingUserRefreshCounts[userKey] = remaining - 1
                return false
            }
            return true
        }
        let optimisticUserMessages = pendingLocalUsers + trailingLocalUsers

        // Only retain canonical messages that were observed on the live stream
        // and remain in the trailing provisional suffix. Once a history payload
        // acknowledges the transcript ID, tracking is cleared by the caller.
        // Encountering any unrelated older row ends the suffix, preventing a
        // bounded history response from reviving arbitrary prior messages.
        var trailingLiveCanonicalMessages: [OpenClawChatMessage] = []
        for message in previous.reversed() {
            if liveCanonicalMessageIDs.contains(message.id) {
                if let identityKey = Self.canonicalTranscriptIdentityKey(for: message),
                   !incomingIdentityKeys.contains(identityKey)
                {
                    trailingLiveCanonicalMessages.append(message)
                }
                continue
            }
            // A local echo is part of the same unconfirmed trailing turn and is
            // retained separately by the optimistic-user path above.
            if pendingLocalUserEchoIDs.contains(message.id) {
                continue
            }
            break
        }
        trailingLiveCanonicalMessages.reverse()
        let retainedMessages = optimisticUserMessages + trailingLiveCanonicalMessages

        guard !retainedMessages.isEmpty else {
            return reconciled
        }

        var insertedMessageIDs = Set<UUID>()
        for message in retainedMessages where insertedMessageIDs.insert(message.id).inserted {
            guard let messageTimestamp = message.timestamp else {
                reconciled.append(message)
                continue
            }

            let insertIndex = reconciled.firstIndex { existing in
                guard let existingTimestamp = existing.timestamp else { return false }
                return existingTimestamp > messageTimestamp
            } ?? reconciled.endIndex
            reconciled.insert(message, at: insertIndex)
        }

        return Self.dedupeMessages(reconciled)
    }

    private static func dedupeMessages(_ messages: [OpenClawChatMessage]) -> [OpenClawChatMessage] {
        var result: [OpenClawChatMessage] = []
        result.reserveCapacity(messages.count)
        var seen = Set<String>()

        for message in messages {
            guard let key = Self.dedupeKey(for: message) else {
                result.append(message)
                continue
            }
            if seen.contains(key) { continue }
            seen.insert(key)
            result.append(message)
        }

        return result
    }

    private static func dedupeKey(for message: OpenClawChatMessage) -> String? {
        if let idempotencyKey = self.idempotencyIdentityKey(for: message) {
            return idempotencyKey
        }
        if let canonicalKey = self.canonicalTranscriptIdentityKey(for: message) {
            return canonicalKey
        }
        guard let timestamp = message.timestamp else { return nil }
        let text = message.content.compactMap(\.text).joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        return "\(message.role)|\(timestamp)|\(text)"
    }

    private static let resetTriggers: Set<String> = ["/reset", "/clear"]
    private static let compactTriggers: Set<String> = ["/compact"]

    private func performSend() async {
        guard !self.isSending else {
            self.logDiagnostic("chat.ui send ignored reason=sending sessionKey=\(self.sessionKey)")
            return
        }
        guard self.supportsDurableOutbox || self.pendingRuns.isEmpty else {
            self.logDiagnostic(
                "chat.ui send ignored reason=pending sessionKey=\(self.sessionKey) "
                    + "pending=\(self.pendingRunCount)")
            return
        }
        let trimmed = self.input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !self.attachments.isEmpty else {
            self.logDiagnostic("chat.ui send ignored reason=empty sessionKey=\(self.sessionKey)")
            return
        }

        let command = trimmed.lowercased()
        if command == "/new" {
            await self.performStartNewSession(preserving: self.input)
            return
        }
        if Self.resetTriggers.contains(command) {
            await self.performReset(preserving: self.input, clearInputOnAdmission: true)
            return
        }
        if Self.compactTriggers.contains(command) {
            await self.performCompact(preserving: self.input)
            return
        }

        if let coordinator = self.outboxCoordinator {
            await self.performDurableSend(trimmed: trimmed, coordinator: coordinator)
            return
        }

        let sessionSnapshot = self.currentSessionSnapshot()
        let sessionKey = sessionSnapshot.key

        if !self.healthOK {
            await self.pollHealthIfNeeded(force: true, sessionSnapshot: sessionSnapshot)
            guard self.isCurrentSession(sessionSnapshot) else { return }
        }

        self.isSending = true
        self.errorText = nil
        defer { self.isSending = false }
        let runId = UUID().uuidString
        let messageText = trimmed.isEmpty && !self.attachments.isEmpty ? "See attached." : trimmed
        let thinkingLevel = self.thinkingLevel
        self.pendingRuns.insert(runId)
        self.armPendingRunTimeout(runId: runId)
        self.logDiagnostic(
            "chat.ui send queued sessionKey=\(sessionKey) "
                + "localRunId=\(runId) pending=\(self.pendingRunCount)")
        self.pendingToolCallsById = [:]
        self.streamingAssistantText = nil

        // Optimistically append user message to UI.
        var userContent: [OpenClawChatMessageContent] = [
            OpenClawChatMessageContent(
                type: "text",
                text: messageText,
                thinking: nil,
                thinkingSignature: nil,
                mimeType: nil,
                fileName: nil,
                content: nil,
                id: nil,
                name: nil,
                arguments: nil),
        ]
        let encodedAttachments = self.attachments.map { att -> OpenClawChatAttachmentPayload in
            OpenClawChatAttachmentPayload(
                type: att.type,
                mimeType: att.mimeType,
                fileName: att.fileName,
                content: att.data.base64EncodedString())
        }
        for att in encodedAttachments {
            userContent.append(
                OpenClawChatMessageContent(
                    type: att.type,
                    text: nil,
                    thinking: nil,
                    thinkingSignature: nil,
                    mimeType: att.mimeType,
                    fileName: att.fileName,
                    content: AnyCodable(att.content),
                    id: nil,
                    name: nil,
                    arguments: nil))
        }
        let userMessageTimestamp = Date().timeIntervalSince1970 * 1000
        let userMessageID = UUID()
        self.messages.append(
            OpenClawChatMessage(
                id: userMessageID,
                role: "user",
                content: userContent,
                timestamp: userMessageTimestamp))
        self.pendingLocalUserEchoMessageIDsByRunID[runId] = userMessageID

        // Clear input immediately for responsive UX (before network await)
        self.input = ""
        self.attachments = []

        do {
            await self.waitForPendingModelPatches(in: sessionKey)
            guard self.isCurrentSession(sessionSnapshot) else { return }
            self.logDiagnostic(
                "chat.ui transport send start sessionKey=\(sessionKey) "
                    + "localRunId=\(runId)")
            let response = try await transport.sendMessage(
                sessionKey: sessionKey,
                message: messageText,
                thinking: thinkingLevel,
                idempotencyKey: runId,
                attachments: encodedAttachments)
            guard self.isCurrentSession(sessionSnapshot) else { return }
            self.logDiagnostic(
                "chat.ui transport send accepted sessionKey=\(sessionKey) "
                    + "localRunId=\(runId) remoteRunId=\(response.runId)")
            if response.runId != runId {
                let pendingUserMessageID = self.pendingLocalUserEchoMessageIDsByRunID.removeValue(forKey: runId)
                self.clearPendingRun(runId)
                self.pendingRuns.insert(response.runId)
                self.pendingLocalUserEchoMessageIDsByRunID[response.runId] = pendingUserMessageID
                self.armPendingRunTimeout(runId: response.runId)
            }
            let historyContext = self.beginHistoryRequest(for: sessionSnapshot)
            let historyRefresh = await self.refreshHistoryAfterRun(historyRequest: historyContext)
            guard self.isCurrentSession(sessionSnapshot) else { return }
            if !self.clearPendingRunIfAssistantMessagePresent(
                runId: response.runId,
                after: userMessageTimestamp)
            {
                if historyRefresh.permitsBoundedRetry {
                    self.armPostSendRefreshFallback(
                        runId: response.runId,
                        sessionSnapshot: sessionSnapshot,
                        userMessageTimestamp: userMessageTimestamp)
                    self.armRunCompletionRefresh(
                        runId: response.runId,
                        sessionSnapshot: sessionSnapshot,
                        userMessageTimestamp: userMessageTimestamp)
                }
            }
        } catch {
            guard self.isCurrentSession(sessionSnapshot) else { return }
            self.pendingLocalUserEchoMessageIDsByRunID[runId] = nil
            self.clearPendingRun(runId)
            self.errorText = error.localizedDescription
            self.logDiagnostic(
                "chat.ui send failed sessionKey=\(sessionKey) "
                    + "localRunId=\(runId) error=\(error.localizedDescription)")
            chatUILogger.error("chat transport send failed \(error.localizedDescription, privacy: .public)")
        }
    }

    private func performDurableSend(
        trimmed: String,
        coordinator: OpenClawChatOutboxDeliveryOwner) async
    {
        let sessionSnapshot = self.currentSessionSnapshot()
        let capturedInput = self.input
        let capturedAttachments = self.attachments
        let capturedAttachmentIDs = capturedAttachments.map(\.id)
        let capturedDraftRevision = self.draftRevision
        let rawCommandID = UUID().uuidString.lowercased()
        let messageText = trimmed.isEmpty && !capturedAttachments.isEmpty ? "See attached." : trimmed
        let thinkingLevel = self.thinkingLevel
        let createdAt = Date()
        let durableAttachments = capturedAttachments.map {
            OpenClawChatOutboxAttachment(
                type: $0.type,
                mimeType: $0.mimeType,
                fileName: $0.fileName,
                data: $0.data)
        }

        self.isSending = true
        self.errorText = nil
        defer { self.isSending = false }

        guard self.isCurrentSession(sessionSnapshot), !self.isShutDown else { return }

        do {
            let persisted = try await coordinator.enqueue(
                rawCommandID: rawCommandID,
                sessionKey: sessionSnapshot.key,
                text: messageText,
                attachments: durableAttachments,
                thinkingLevel: thinkingLevel,
                createdAt: createdAt)
            guard !self.isShutDown else { return }
            guard self.isCurrentSession(sessionSnapshot) else {
                self.kickOutboxWorker(reason: "enqueue-after-session-switch")
                return
            }

            // Clearing is a compare-and-swap over both revision and attachment
            // identity. User edits made while SQLite or route evidence awaited
            // always survive.
            if self.draftRevision == capturedDraftRevision,
               self.input == capturedInput,
               self.attachments.map(\.id) == capturedAttachmentIDs
            {
                self.input = ""
                self.attachments = []
            }

            self.restoreOptimisticOutboxCommands([persisted])
            self.logDiagnostic(
                "chat.outbox persisted sessionKey=\(sessionSnapshot.key) commandId=\(rawCommandID)")
            self.kickOutboxWorker(reason: "enqueue")
        } catch {
            // Persist-before-clear is the safety boundary. On any failure the
            // exact draft and attachments remain user-owned in the composer.
            self.errorText = error.localizedDescription
            self.logDiagnostic(
                "chat.outbox persist failed sessionKey=\(sessionSnapshot.key) "
                    + "commandId=\(rawCommandID) error=\(error.localizedDescription)")
        }
    }

    private func kickOutboxWorker(reason: String) {
        guard let coordinator = self.outboxCoordinator, !self.isShutDown else { return }
        self.outboxWakeRequested = true
        guard self.outboxWorkerTask == nil else { return }

        let generation = self.outboxWorkerGeneration
        self.logDiagnostic("chat.outbox worker wake reason=\(reason)")
        self.outboxWorkerTask = Task { [weak self, coordinator] in
            guard let self else { return }
            await self.runOutboxWorker(coordinator: coordinator, generation: generation)
        }
    }

    private func runOutboxWorker(
        coordinator: OpenClawChatOutboxDeliveryOwner,
        generation: UInt64) async
    {
        while self.isCurrentOutboxWorker(generation), self.outboxWakeRequested {
            self.outboxWakeRequested = false
            do {
                try await coordinator.wake()
            } catch {
                guard self.isCurrentOutboxWorker(generation), !Task.isCancelled else { return }
                self.errorText = error.localizedDescription
                self.logDiagnostic("chat.outbox worker failed error=\(error.localizedDescription)")
            }
        }

        guard self.isCurrentOutboxWorker(generation) else { return }
        self.outboxWorkerTask = nil
        if self.outboxWakeRequested {
            self.kickOutboxWorker(reason: "coalesced")
        }
    }

    private func isCurrentOutboxWorker(_ generation: UInt64) -> Bool {
        !self.isShutDown && !Task.isCancelled && generation == self.outboxWorkerGeneration
    }

    private func applyOutboxResult(_ result: OpenClawChatOutboxDeliveryUpdate) {
        guard !self.isShutDown,
              result.sequence > self.lastAppliedOutboxUpdateSequence
        else { return }
        self.lastAppliedOutboxUpdateSequence = result.sequence
        self.outboxStatus = result.status
        for receipt in result.terminalReceipts
            where receipt.outcome == .expired || receipt.outcome == .cancelled
        {
            self.removeOptimisticOutboxMessage(rawCommandID: receipt.rawCommandID)
        }
        self.restoreOptimisticOutboxCommands(result.unresolvedCommands)

        var shouldRefreshHistory = false
        for transition in result.transitions {
            switch transition {
            case .dispatched(let rawCommandID):
                guard let command = result.unresolvedCommands.first(where: {
                    $0.rawCommandID == rawCommandID && $0.sessionKey == self.sessionKey
                }) else { continue }
                self.pendingRuns.insert(rawCommandID)
                self.armOutboxConfirmationTimeout(rawCommandID: rawCommandID)
                self.logDiagnostic(
                    "chat.outbox dispatch admitted sessionKey=\(command.sessionKey) commandId=\(rawCommandID)")
            case .canonicalHistoryConfirmed(let rawCommandID):
                self.clearPendingRun(rawCommandID)
                shouldRefreshHistory = true
                self.logDiagnostic("chat.outbox canonical confirmed commandId=\(rawCommandID)")
            case .blocked(let rawCommandID):
                self.clearPendingRun(rawCommandID)
                self.logDiagnostic("chat.outbox blocked commandId=\(rawCommandID)")
            }
        }

        if shouldRefreshHistory {
            let context = self.beginHistoryRequest()
            Task { [weak self] in
                _ = await self?.refreshHistoryAfterRun(historyRequest: context)
            }
        }
    }

    private func restoreOptimisticOutboxCommands(_ commands: [OpenClawChatOutboxCommand]) {
        for command in commands where command.sessionKey == self.sessionKey {
            if let existing = self.messages.first(where: {
                $0.role.lowercased() == "user" &&
                    $0.idempotencyKey == command.canonicalUserIdempotencyKey
            }) {
                self.pendingLocalUserEchoMessageIDsByRunID[command.rawCommandID] = existing.id
                continue
            }

            var content: [OpenClawChatMessageContent] = [
                OpenClawChatMessageContent(
                    type: "text",
                    text: command.text,
                    thinking: nil,
                    thinkingSignature: nil,
                    mimeType: nil,
                    fileName: nil,
                    content: nil),
            ]
            content.append(contentsOf: command.attachments.map {
                OpenClawChatMessageContent(
                    type: $0.type,
                    text: nil,
                    thinking: nil,
                    thinkingSignature: nil,
                    mimeType: $0.mimeType,
                    fileName: $0.fileName,
                    content: AnyCodable($0.data.base64EncodedString()))
            })

            let messageID = UUID(uuidString: command.rawCommandID) ?? UUID()
            self.messages.append(OpenClawChatMessage(
                id: messageID,
                role: "user",
                content: content,
                timestamp: command.createdAt.timeIntervalSince1970 * 1000,
                idempotencyKey: command.canonicalUserIdempotencyKey))
            self.pendingLocalUserEchoMessageIDsByRunID[command.rawCommandID] = messageID
        }
        self.messages = Self.dedupeMessages(self.messages)
    }

    private func armOutboxConfirmationTimeout(rawCommandID: String) {
        self.pendingRunTimeoutTasks[rawCommandID]?.cancel()
        self.pendingRunTimeoutTasks[rawCommandID] = Task { [weak self] in
            let timeoutMs = await MainActor.run { self?.pendingRunTimeoutMs ?? 0 }
            try? await Task.sleep(nanoseconds: timeoutMs * 1_000_000)
            await MainActor.run { [weak self] in
                guard let self, self.pendingRuns.contains(rawCommandID) else { return }
                self.clearPendingRun(rawCommandID)
                self.errorText =
                    "Delivery remains unconfirmed. Checking canonical history; "
                        + "this message will not be resent automatically."
                self.kickOutboxWorker(reason: "confirmation-timeout")
            }
        }
    }

    private func removeOptimisticOutboxMessage(rawCommandID: String) {
        let canonicalIdentity = "\(rawCommandID):user"
        self.messages.removeAll {
            $0.role.lowercased() == "user" && $0.idempotencyKey == canonicalIdentity
        }
        self.clearPendingRun(rawCommandID)
        self.pendingLocalUserEchoMessageIDsByRunID[rawCommandID] = nil
    }

    private func performAbort() async {
        guard !self.pendingRuns.isEmpty else { return }
        guard !self.isAborting else { return }
        self.isAborting = true
        defer { self.isAborting = false }

        let runIds = Array(pendingRuns)
        for runId in runIds {
            do {
                try await self.transport.abortRun(sessionKey: self.sessionKey, runId: runId)
            } catch {
                // Best-effort.
            }
        }
    }

    private func fetchSessions(limit: Int?, sessionSnapshot: SessionSnapshot? = nil) async {
        do {
            let res = try await transport.listSessions(limit: limit)
            if let sessionSnapshot, !self.isCurrentSession(sessionSnapshot) { return }
            self.sessions = res.sessions
            self.sessionDefaults = res.defaults
            self.syncSelectedModel()
            self.syncThinkingLevelOptions()
        } catch {
            // Best-effort.
        }
    }

    private func fetchModels(sessionSnapshot: SessionSnapshot? = nil) async {
        do {
            let modelChoices = try await transport.listModels()
            if let sessionSnapshot, !self.isCurrentSession(sessionSnapshot) { return }
            self.modelChoices = modelChoices
            self.syncSelectedModel()
        } catch {
            // Best-effort.
        }
    }

    private func applySessionSwitch(to sessionKey: String, intent: SessionSwitchIntent) {
        let next = sessionKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !next.isEmpty else { return }
        guard next != self.sessionKey else { return }
        self.advanceSessionGeneration()
        self.sessionKey = next
        self.recordChatDiagnostic(
            state: "selected_session_generation_changed",
            resultClass: "success",
            messageCount: 0)
        if intent == .userInitiated {
            self.onSessionChanged?(next)
        }
        self.modelSelectionID = Self.defaultModelSelectionID
        self.messages = []
        self.pendingLocalUserEchoMessageIDsByRunID.removeAll()
        self.liveCanonicalMessageIDsByIdentity.removeAll()
        self.sessionId = nil
        self.pendingToolCallsById = [:]
        self.streamingAssistantText = nil
        self.clearPendingRuns(reason: nil)
        self.startBootstrap(sessionKey: next)
        self.kickOutboxWorker(reason: "session-switch")
    }

    private func performStartNewSession(preserving commandInput: String) async {
        let admittedSession = self.currentSessionSnapshot()
        guard await self.destructiveSessionActionIsAllowed(for: admittedSession),
              self.isCurrentSession(admittedSession)
        else { return }
        self.input = ""
        let requested = self.generatedNewSessionKey()
        let parentSessionKey = admittedSession.key
        let next: String
        do {
            let transport = self.transport
            let created: OpenClawChatCreateSessionResponse
            if let outboxCoordinator = self.outboxCoordinator {
                created = try await outboxCoordinator.performDestructiveSessionAction(
                    admissionCheck: { [weak self] in
                        guard await MainActor.run(body: {
                            self?.isCurrentSession(admittedSession) == true
                        }) else { throw CancellationError() }
                    }) {
                        try await transport.createSession(
                            key: requested,
                            label: nil,
                            parentSessionKey: parentSessionKey)
                    }
            } else {
                guard self.isCurrentSession(admittedSession) else { throw CancellationError() }
                created = try await transport.createSession(
                    key: requested,
                    label: nil,
                    parentSessionKey: parentSessionKey)
            }
            guard self.isCurrentSession(admittedSession) else { return }
            let createdKey = created.key.trimmingCharacters(in: .whitespacesAndNewlines)
            next = createdKey.isEmpty ? requested : createdKey
        } catch {
            guard self.isCurrentSession(admittedSession) else { return }
            if Self.isUnsupportedCreateSessionError(error) {
                chatUILogger.info("sessions.create unsupported; falling back to sessions.reset")
                await self.performReset(preserving: commandInput, clearInputOnAdmission: false)
                return
            }
            chatUILogger.error("sessions.create failed \(error.localizedDescription, privacy: .public)")
            self.errorText = error.localizedDescription
            if self.input.isEmpty {
                self.input = commandInput
            }
            return
        }
        self.advanceSessionGeneration()
        self.sessionKey = next
        self.recordChatDiagnostic(
            state: "selected_session_generation_changed",
            resultClass: "success",
            messageCount: 0)
        self.onSessionChanged?(next)
        self.modelSelectionID = Self.defaultModelSelectionID
        self.messages = []
        self.pendingLocalUserEchoMessageIDsByRunID.removeAll()
        self.liveCanonicalMessageIDsByIdentity.removeAll()
        self.sessionId = nil
        self.pendingToolCallsById = [:]
        self.streamingAssistantText = nil
        self.clearPendingRuns(reason: nil)
        self.errorText = nil
        self.startBootstrap()
        self.kickOutboxWorker(reason: "session-create")
    }

    private static func isUnsupportedCreateSessionError(_ error: Error) -> Bool {
        let nsError = error as NSError
        return nsError.domain == "OpenClawChatTransport"
            && nsError.localizedDescription == "sessions.create not supported by this transport"
    }

    private func performReset(
        preserving commandInput: String,
        clearInputOnAdmission: Bool) async
    {
        let admittedSession = self.currentSessionSnapshot()
        self.isLoading = true
        self.errorText = nil

        do {
            let transport = self.transport
            if let outboxCoordinator = self.outboxCoordinator {
                try await outboxCoordinator.performDestructiveSessionAction(admissionCheck: { [weak self] in
                    guard await MainActor.run(body: {
                        self?.isCurrentSession(admittedSession) == true
                    }) else { throw CancellationError() }
                }) {
                    try await transport.resetSession(sessionKey: admittedSession.key)
                }
            } else {
                guard self.isCurrentSession(admittedSession) else { throw CancellationError() }
                try await transport.resetSession(sessionKey: admittedSession.key)
            }
        } catch {
            guard self.isCurrentSession(admittedSession) else { return }
            self.isLoading = false
            if error is OpenClawChatOutboxDeliveryOwnerError {
                self.errorText =
                    "Wait for queued messages to be confirmed before changing this session."
            } else {
                self.errorText = error.localizedDescription
            }
            if self.input.isEmpty {
                self.input = commandInput
            }
            chatUILogger.error("session reset failed \(error.localizedDescription, privacy: .public)")
            return
        }

        guard self.isCurrentSession(admittedSession) else { return }
        if clearInputOnAdmission, self.input == commandInput {
            self.input = ""
        }
        self.applySuccessfulDestructiveSessionMutation()
        self.startBootstrap()
    }

    private func destructiveSessionActionIsAllowed(
        for admittedSession: SessionSnapshot? = nil) async -> Bool
    {
        let admittedSession = admittedSession ?? self.currentSessionSnapshot()
        guard self.isCurrentSession(admittedSession) else { return false }
        guard let outboxCoordinator else { return true }
        do {
            guard try await outboxCoordinator.unresolvedCommands().isEmpty else {
                guard self.isCurrentSession(admittedSession) else { return false }
                self.errorText =
                    "Wait for queued messages to be confirmed before changing this session."
                return false
            }
            return self.isCurrentSession(admittedSession)
        } catch {
            guard self.isCurrentSession(admittedSession) else { return false }
            self.errorText =
                "Unable to verify queued messages. Reconnect before changing this session."
            return false
        }
    }

    private func performCompact(preserving commandInput: String) async {
        guard !self.isCompacting else { return }
        guard !self.isSending, self.pendingRuns.isEmpty, !self.isAborting else {
            self.errorText = "Wait for the current response before compacting the session."
            return
        }
        if let lastCompactAt,
           Date().timeIntervalSince(lastCompactAt) < compactCooldown
        {
            self.errorText = "Please wait before compacting this session again."
            return
        }

        let admittedSession = self.currentSessionSnapshot()
        self.isCompacting = true
        self.isLoading = true
        self.errorText = nil
        defer {
            self.isCompacting = false
        }

        do {
            let transport = self.transport
            if let outboxCoordinator = self.outboxCoordinator {
                try await outboxCoordinator.performDestructiveSessionAction(admissionCheck: { [weak self] in
                    guard await MainActor.run(body: {
                        self?.isCurrentSession(admittedSession) == true
                    }) else { throw CancellationError() }
                }) {
                    try await transport.compactSession(sessionKey: admittedSession.key)
                }
            } else {
                guard self.isCurrentSession(admittedSession) else { throw CancellationError() }
                try await transport.compactSession(sessionKey: admittedSession.key)
            }
        } catch {
            guard self.isCurrentSession(admittedSession) else { return }
            self.isLoading = false
            if error is OpenClawChatOutboxDeliveryOwnerError {
                self.errorText =
                    "Wait for queued messages to be confirmed before changing this session."
            } else {
                self.errorText = "Unable to compact the session. Please try again."
            }
            if self.input.isEmpty {
                self.input = commandInput
            }
            let nsError = error as NSError
            chatUILogger.error(
                "compact failed domain=\(nsError.domain, privacy: .public) code=\(nsError.code, privacy: .public)")
            chatUILogger.error("compact details=\(String(describing: error), privacy: .private)")
            return
        }

        guard self.isCurrentSession(admittedSession) else { return }
        if self.input == commandInput {
            self.input = ""
        }
        lastCompactAt = Date()
        self.applySuccessfulDestructiveSessionMutation()
        self.startBootstrap()
    }

    private func performSelectThinkingLevel(_ level: String) async {
        let next = Self.normalizedThinkingLevel(level) ?? "off"
        guard next != self.thinkingLevel else { return }

        let sessionKey = self.sessionKey
        self.thinkingLevel = next
        self.syncThinkingLevelOptions()
        self.updateCurrentSessionThinkingLevel(next, sessionKey: sessionKey)
        self.onThinkingLevelChanged?(next)
        self.nextThinkingSelectionRequestID &+= 1
        let requestID = self.nextThinkingSelectionRequestID
        self.latestThinkingSelectionRequestIDsBySession[sessionKey] = requestID
        self.latestThinkingLevelsBySession[sessionKey] = next

        do {
            try await self.transport.setSessionThinking(sessionKey: sessionKey, thinkingLevel: next)
            guard requestID == self.latestThinkingSelectionRequestIDsBySession[sessionKey] else {
                let latest = self.latestThinkingLevelsBySession[sessionKey] ?? next
                guard latest != next else { return }
                try? await self.transport.setSessionThinking(sessionKey: sessionKey, thinkingLevel: latest)
                return
            }
        } catch {
            guard sessionKey == self.sessionKey,
                  requestID == self.latestThinkingSelectionRequestIDsBySession[sessionKey]
            else { return }
            // Best-effort. Persisting the user's local preference matters more than a patch error here.
        }
    }

    private func performSelectModel(_ selectionID: String) async {
        let next = self.normalizedSelectionID(selectionID)
        guard next != self.modelSelectionID else { return }

        let sessionKey = self.sessionKey
        let previous = self.modelSelectionID
        let previousRequestID = self.latestModelSelectionRequestIDsBySession[sessionKey]
        self.nextModelSelectionRequestID &+= 1
        let requestID = self.nextModelSelectionRequestID
        let nextModelRef = self.modelRef(forSelectionID: next)
        self.latestModelSelectionRequestIDsBySession[sessionKey] = requestID
        self.latestModelSelectionIDsBySession[sessionKey] = next
        self.beginModelPatch(for: sessionKey)
        self.modelSelectionID = next
        self.errorText = nil
        defer { self.endModelPatch(for: sessionKey) }

        do {
            try await self.transport.setSessionModel(
                sessionKey: sessionKey,
                model: nextModelRef)
            guard requestID == self.latestModelSelectionRequestIDsBySession[sessionKey] else {
                // Keep older successful patches as rollback state, but do not replay
                // stale UI/session state over a newer in-flight or completed selection.
                self.lastSuccessfulModelSelectionIDsBySession[sessionKey] = next
                return
            }
            self.applySuccessfulModelSelection(next, sessionKey: sessionKey, syncSelection: true)
        } catch {
            guard requestID == self.latestModelSelectionRequestIDsBySession[sessionKey] else { return }
            self.latestModelSelectionIDsBySession[sessionKey] = previous
            if let previousRequestID {
                self.latestModelSelectionRequestIDsBySession[sessionKey] = previousRequestID
            } else {
                self.latestModelSelectionRequestIDsBySession.removeValue(forKey: sessionKey)
            }
            if self.lastSuccessfulModelSelectionIDsBySession[sessionKey] == previous {
                self.applySuccessfulModelSelection(
                    previous,
                    sessionKey: sessionKey,
                    syncSelection: sessionKey == self.sessionKey)
            }
            guard sessionKey == self.sessionKey else { return }
            self.modelSelectionID = previous
            self.errorText = error.localizedDescription
            chatUILogger.error("sessions.patch(model) failed \(error.localizedDescription, privacy: .public)")
        }
    }

    private func beginModelPatch(for sessionKey: String) {
        self.inFlightModelPatchCountsBySession[sessionKey, default: 0] += 1
    }

    private func endModelPatch(for sessionKey: String) {
        let remaining = max(0, (inFlightModelPatchCountsBySession[sessionKey] ?? 0) - 1)
        if remaining == 0 {
            self.inFlightModelPatchCountsBySession.removeValue(forKey: sessionKey)
            let waiters = self.modelPatchWaitersBySession.removeValue(forKey: sessionKey) ?? []
            for waiter in waiters {
                waiter.resume()
            }
            return
        }
        self.inFlightModelPatchCountsBySession[sessionKey] = remaining
    }

    private func waitForPendingModelPatches(in sessionKey: String) async {
        guard (self.inFlightModelPatchCountsBySession[sessionKey] ?? 0) > 0 else { return }
        await withCheckedContinuation { continuation in
            self.modelPatchWaitersBySession[sessionKey, default: []].append(continuation)
        }
    }

    private func syncThinkingLevelOptions() {
        let currentSession = self.sessions.first(where: { $0.key == self.sessionKey })
        var options = self.resolvedThinkingLevelOptions(for: currentSession)
        if let current = Self.normalizedThinkingLevel(thinkingLevel) {
            options = Self.withCurrentThinkingOption(options, current: current)
        }
        self.thinkingLevelOptions = options
    }

    private func resolvedThinkingLevelOptions(
        for currentSession: OpenClawChatSessionEntry?) -> [OpenClawChatThinkingLevelOption]
    {
        if let levels = Self.normalizedThinkingLevelOptions(currentSession?.thinkingLevels), !levels.isEmpty {
            return levels
        }

        let defaultsMatch = currentSession.map {
            Self.sessionModelMatchesDefaults($0, defaults: self.sessionDefaults)
        } ?? true

        if defaultsMatch,
           let levels = Self.normalizedThinkingLevelOptions(sessionDefaults?.thinkingLevels),
           !levels.isEmpty
        {
            return levels
        }

        if let options = Self.thinkingOptions(from: currentSession?.thinkingOptions), !options.isEmpty {
            return options
        }

        if defaultsMatch,
           let options = Self.thinkingOptions(from: sessionDefaults?.thinkingOptions),
           !options.isEmpty
        {
            return options
        }

        return Self.baseThinkingLevelOptions
    }

    private static func sessionModelMatchesDefaults(
        _ session: OpenClawChatSessionEntry,
        defaults: OpenClawChatSessionsDefaults?) -> Bool
    {
        let providerMatches = session.modelProvider == nil || session.modelProvider == defaults?.modelProvider
        let modelMatches = session.model == nil || session.model == defaults?.model
        return providerMatches && modelMatches
    }

    private static func normalizedThinkingLevelOptions(
        _ levels: [OpenClawChatThinkingLevelOption]?) -> [OpenClawChatThinkingLevelOption]?
    {
        guard let levels else { return nil }
        return Self.dedupedThinkingOptions(
            levels.compactMap { level in
                guard let id = Self.normalizedThinkingLevel(level.id) else { return nil }
                let label = level.label.trimmingCharacters(in: .whitespacesAndNewlines)
                return OpenClawChatThinkingLevelOption(id: id, label: label.isEmpty ? id : label)
            })
    }

    private static func thinkingOptions(from labels: [String]?) -> [OpenClawChatThinkingLevelOption]? {
        guard let labels else { return nil }
        return Self.dedupedThinkingOptions(
            labels.compactMap { label in
                guard let id = Self.normalizedThinkingLevel(label) else { return nil }
                let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
                return OpenClawChatThinkingLevelOption(id: id, label: trimmed.isEmpty ? id : trimmed)
            })
    }

    private static func withCurrentThinkingOption(
        _ options: [OpenClawChatThinkingLevelOption],
        current: String) -> [OpenClawChatThinkingLevelOption]
    {
        guard !options.contains(where: { $0.id == current }) else { return options }
        return options + [OpenClawChatThinkingLevelOption(id: current, label: current)]
    }

    private static func dedupedThinkingOptions(
        _ options: [OpenClawChatThinkingLevelOption]) -> [OpenClawChatThinkingLevelOption]
    {
        var result: [OpenClawChatThinkingLevelOption] = []
        var seen = Set<String>()
        for option in options {
            guard !option.id.isEmpty, !seen.contains(option.id) else { continue }
            seen.insert(option.id)
            result.append(option)
        }
        return result
    }

    private func placeholderSession(key: String) -> OpenClawChatSessionEntry {
        OpenClawChatSessionEntry(
            key: key,
            kind: nil,
            displayName: nil,
            surface: nil,
            subject: nil,
            room: nil,
            space: nil,
            updatedAt: nil,
            sessionId: nil,
            systemSent: nil,
            abortedLastRun: nil,
            thinkingLevel: nil,
            verboseLevel: nil,
            inputTokens: nil,
            outputTokens: nil,
            totalTokens: nil,
            modelProvider: nil,
            model: nil,
            contextTokens: nil)
    }

    private func syncSelectedModel() {
        let currentSession = self.sessions.first(where: { $0.key == self.sessionKey })
        let explicitModelID = self.normalizedModelSelectionID(
            currentSession?.model,
            provider: currentSession?.modelProvider)
        if let explicitModelID {
            self.lastSuccessfulModelSelectionIDsBySession[self.sessionKey] = explicitModelID
            self.modelSelectionID = explicitModelID
            return
        }
        self.lastSuccessfulModelSelectionIDsBySession[self.sessionKey] = Self.defaultModelSelectionID
        self.modelSelectionID = Self.defaultModelSelectionID
    }

    private func normalizedSelectionID(_ selectionID: String) -> String {
        let trimmed = selectionID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return Self.defaultModelSelectionID }
        return trimmed
    }

    private func normalizedModelSelectionID(_ modelID: String?, provider: String? = nil) -> String? {
        guard let modelID else { return nil }
        let trimmed = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let provider = Self.normalizedProvider(provider) {
            let providerQualified = Self.providerQualifiedModelSelectionID(modelID: trimmed, provider: provider)
            if let match = modelChoices.first(where: {
                $0.selectionID == providerQualified ||
                    ($0.modelID == trimmed && Self.normalizedProvider($0.provider) == provider)
            }) {
                return match.selectionID
            }
            return providerQualified
        }
        if self.modelChoices.contains(where: { $0.selectionID == trimmed }) {
            return trimmed
        }
        let matches = self.modelChoices.filter { $0.modelID == trimmed || $0.selectionID == trimmed }
        if matches.count == 1 {
            return matches[0].selectionID
        }
        return trimmed
    }

    private func modelRef(forSelectionID selectionID: String) -> String? {
        let normalized = self.normalizedSelectionID(selectionID)
        if normalized == Self.defaultModelSelectionID {
            return nil
        }
        return normalized
    }

    private func generatedNewSessionKey() -> String {
        let baseKey = "ios-\(UUID().uuidString.lowercased())"
        guard let agentID = Self.agentID(fromSessionKey: sessionKey) ??
            Self.agentID(fromSessionKey: resolvedMainSessionKey) ??
            sessions.lazy.compactMap({ Self.agentID(fromSessionKey: $0.key) }).first
        else {
            return baseKey
        }
        return "agent:\(agentID):\(baseKey)"
    }

    private static func agentID(fromSessionKey sessionKey: String) -> String? {
        let parts = sessionKey
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count >= 3, parts[0].lowercased() == "agent" else { return nil }
        let agentID = String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines)
        return agentID.isEmpty ? nil : agentID
    }

    private func modelLabel(for modelID: String) -> String {
        self.modelChoices.first(where: { $0.selectionID == modelID || $0.modelID == modelID })?.displayLabel ??
            modelID
    }

    private func applySuccessfulModelSelection(_ selectionID: String, sessionKey: String, syncSelection: Bool) {
        self.lastSuccessfulModelSelectionIDsBySession[sessionKey] = selectionID
        let resolved = self.resolvedSessionModelIdentity(forSelectionID: selectionID)
        self.updateCurrentSessionModel(
            modelID: resolved.modelID,
            modelProvider: resolved.modelProvider,
            sessionKey: sessionKey,
            syncSelection: syncSelection)
        if sessionKey == self.sessionKey {
            self.syncThinkingLevelOptions()
        }
    }

    private func resolvedSessionModelIdentity(forSelectionID selectionID: String)
        -> (modelID: String?, modelProvider: String?)
    {
        guard let modelRef = modelRef(forSelectionID: selectionID) else {
            return (nil, nil)
        }
        if let choice = modelChoices.first(where: { $0.selectionID == modelRef }) {
            return (choice.modelID, Self.normalizedProvider(choice.provider))
        }
        return (modelRef, nil)
    }

    private static func normalizedProvider(_ provider: String?) -> String? {
        let trimmed = provider?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let trimmed, !trimmed.isEmpty else { return nil }
        return trimmed
    }

    private static func providerQualifiedModelSelectionID(modelID: String, provider: String) -> String {
        let providerPrefix = "\(provider)/"
        if modelID.hasPrefix(providerPrefix) {
            return modelID
        }
        return "\(provider)/\(modelID)"
    }

    private func updateCurrentSessionThinkingLevel(_ thinkingLevel: String?, sessionKey: String) {
        guard let index = sessions.firstIndex(where: { $0.key == sessionKey }) else { return }
        let current = self.sessions[index]
        self.sessions[index] = OpenClawChatSessionEntry(
            key: current.key,
            kind: current.kind,
            displayName: current.displayName,
            surface: current.surface,
            subject: current.subject,
            room: current.room,
            space: current.space,
            updatedAt: current.updatedAt,
            sessionId: current.sessionId,
            systemSent: current.systemSent,
            abortedLastRun: current.abortedLastRun,
            thinkingLevel: thinkingLevel,
            verboseLevel: current.verboseLevel,
            inputTokens: current.inputTokens,
            outputTokens: current.outputTokens,
            totalTokens: current.totalTokens,
            modelProvider: current.modelProvider,
            model: current.model,
            contextTokens: current.contextTokens,
            thinkingLevels: current.thinkingLevels,
            thinkingOptions: current.thinkingOptions,
            thinkingDefault: current.thinkingDefault)
    }

    private func updateCurrentSessionModel(
        modelID: String?,
        modelProvider: String?,
        sessionKey: String,
        syncSelection: Bool)
    {
        if let index = sessions.firstIndex(where: { $0.key == sessionKey }) {
            let current = self.sessions[index]
            self.sessions[index] = OpenClawChatSessionEntry(
                key: current.key,
                kind: current.kind,
                displayName: current.displayName,
                surface: current.surface,
                subject: current.subject,
                room: current.room,
                space: current.space,
                updatedAt: current.updatedAt,
                sessionId: current.sessionId,
                systemSent: current.systemSent,
                abortedLastRun: current.abortedLastRun,
                thinkingLevel: current.thinkingLevel,
                verboseLevel: current.verboseLevel,
                inputTokens: current.inputTokens,
                outputTokens: current.outputTokens,
                totalTokens: current.totalTokens,
                modelProvider: modelProvider,
                model: modelID,
                contextTokens: current.contextTokens)
        } else {
            let placeholder = self.placeholderSession(key: sessionKey)
            self.sessions.append(
                OpenClawChatSessionEntry(
                    key: placeholder.key,
                    kind: placeholder.kind,
                    displayName: placeholder.displayName,
                    surface: placeholder.surface,
                    subject: placeholder.subject,
                    room: placeholder.room,
                    space: placeholder.space,
                    updatedAt: placeholder.updatedAt,
                    sessionId: placeholder.sessionId,
                    systemSent: placeholder.systemSent,
                    abortedLastRun: placeholder.abortedLastRun,
                    thinkingLevel: placeholder.thinkingLevel,
                    verboseLevel: placeholder.verboseLevel,
                    inputTokens: placeholder.inputTokens,
                    outputTokens: placeholder.outputTokens,
                    totalTokens: placeholder.totalTokens,
                    modelProvider: modelProvider,
                    model: modelID,
                    contextTokens: placeholder.contextTokens))
        }
        if syncSelection {
            self.syncSelectedModel()
        }
    }

    private func handleTransportEvent(_ evt: OpenClawChatTransportEvent) {
        switch evt {
        case let .health(ok):
            self.healthOK = ok
            if ok { self.kickOutboxWorker(reason: "health") }
        case .tick:
            let context = self.currentSessionSnapshot()
            Task { await self.pollHealthIfNeeded(force: false, sessionSnapshot: context) }
            self.kickOutboxWorker(reason: "tick")
        case let .chat(chat):
            self.handleChatEvent(chat)
            self.kickOutboxWorker(reason: "chat-event")
        case let .sessionMessage(message):
            self.handleSessionMessageEvent(message)
            self.kickOutboxWorker(reason: "session-message")
        case let .agent(agent):
            self.handleAgentEvent(agent)
        case .seqGap:
            self.errorText = nil
            self.kickOutboxWorker(reason: "sequence-gap")
            let context = self.beginHistoryRequest()
            Task {
                let refreshed = await self.refreshHistoryAfterRun(historyRequest: context)
                // A sequence gap is loss of observation, not proof that the
                // admitted run ended. Retire run-owned transient state only
                // after refreshed durable history proves an assistant response
                // follows the latest user turn.
                if refreshed.didApply,
                   self.isCurrentSession(context.session),
                   !self.pendingRuns.isEmpty,
                   self.hasAssistantMessageAfterLatestUser()
                {
                    self.clearPendingRuns(reason: nil)
                    self.pendingToolCallsById = [:]
                    self.streamingAssistantText = nil
                }
                await self.pollHealthIfNeeded(force: true, sessionSnapshot: context.session)
            }
        }
    }

    private func handleSessionMessageEvent(_ payload: OpenClawSessionMessageEventPayload) {
        if let sessionKey = payload.sessionKey,
           !self.matchesCurrentSessionKey(incoming: sessionKey, agentId: payload.agentId, current: self.sessionKey)
        {
            return
        }

        guard let message = payload.message else { return }

        let sanitized = Self.stripInboundMetadata(from: message)

        // The active client also receives the gateway's echo of the user turn it
        // just sent. performSend already appended an optimistic row carrying a
        // local client timestamp, while the echo carries a server timestamp, so
        // the timestamp-keyed identity/dedupe paths below never collapse them.
        // Adopt the server record only onto a still-visible row created by this
        // client's pending send; same-content user turns from other clients must append.
        if self.adoptPendingLocalUserEcho(incoming: sanitized) {
            self.trackLiveCanonicalMessage(sanitized)
            return
        }

        let reconciled = Self.reconcileMessageIDs(previous: self.messages, incoming: self.messages + [sanitized])
        self.messages = Self.dedupeMessages(reconciled)
        self.trackLiveCanonicalMessage(sanitized)
    }

    private func handleChatEvent(_ chat: OpenClawChatEventPayload) {
        let isOurRun = chat.runId.flatMap { self.pendingRuns.contains($0) } ?? false
        if let runId = chat.runId {
            self.logDiagnostic(
                "chat.ui event chat state=\(chat.state ?? "unknown") "
                    + "runId=\(runId) ours=\(isOurRun) pending=\(self.pendingRunCount)")
        }

        // Gateway may publish canonical session keys (for example "agent:main:main")
        // even when this view currently uses an alias key (for example "main").
        // Never drop events for our own pending run on key mismatch, or the UI can stay
        // stuck at "thinking" until the user reopens and forces a history reload.
        if let sessionKey = chat.sessionKey,
           !self.matchesCurrentSessionKey(incoming: sessionKey, current: self.sessionKey),
           !isOurRun
        {
            return
        }
        if !isOurRun {
            // Keep multiple clients in sync: if another client finishes a run for our session, refresh history.
            switch chat.state {
            case "final", "aborted", "error":
                // An external terminal cannot retire transient state owned by
                // the local run this client is still following.
                if self.pendingRuns.isEmpty {
                    self.streamingAssistantText = nil
                    self.pendingToolCallsById = [:]
                }
                self.appendFinalChatMessageIfPresent(chat)
                let context = self.beginHistoryRequest()
                Task { await self.refreshHistoryAfterRun(historyRequest: context) }
            default:
                break
            }
            return
        }

        switch chat.state {
        case "final", "aborted", "error":
            if chat.state == "error" {
                self.errorText = chat.errorMessage ?? "Chat failed"
            }
            if let runId = chat.runId {
                self.clearPendingRun(runId)
            } else if self.pendingRuns.count <= 1 {
                self.clearPendingRuns(reason: nil)
            }
            self.pendingToolCallsById = [:]
            self.streamingAssistantText = nil
            self.appendFinalChatMessageIfPresent(chat)
            let context = self.beginHistoryRequest()
            Task { await self.refreshHistoryAfterRun(historyRequest: context) }
        default:
            break
        }
    }

    private func appendFinalChatMessageIfPresent(_ chat: OpenClawChatEventPayload) {
        guard chat.state == "final" else { return }
        guard let text = OpenClawChatEventText.assistantText(from: chat) else { return }

        let decoded = chat.message.flatMap {
            try? ChatPayloadDecoding.decode($0, as: OpenClawChatMessage.self)
        }
        let message = if let decoded,
                         Self.isAssistantMessage(decoded)
        {
            Self.messageWithTimestampIfNeeded(decoded)
        } else {
            OpenClawChatMessage(
                role: "assistant",
                content: [
                    OpenClawChatMessageContent(
                        type: "text",
                        text: text,
                        thinking: nil,
                        thinkingSignature: nil,
                        mimeType: nil,
                        fileName: nil,
                        content: nil,
                        id: nil,
                        name: nil,
                        arguments: nil),
                ],
                timestamp: Date().timeIntervalSince1970 * 1000,
                stopReason: "stop")
        }

        let reconciled = Self.reconcileMessageIDs(previous: self.messages, incoming: self.messages + [message])
        self.messages = Self.dedupeMessages(reconciled)
    }

    private static func isAssistantMessage(_ message: OpenClawChatMessage) -> Bool {
        message.role.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "assistant"
    }

    private static func messageWithTimestampIfNeeded(_ message: OpenClawChatMessage) -> OpenClawChatMessage {
        guard message.timestamp == nil else { return message }
        return OpenClawChatMessage(
            id: message.id,
            role: message.role,
            content: message.content,
            timestamp: Date().timeIntervalSince1970 * 1000,
            transcriptMessageID: message.transcriptMessageID,
            idempotencyKey: message.idempotencyKey,
            toolCallId: message.toolCallId,
            toolName: message.toolName,
            usage: message.usage,
            stopReason: message.stopReason,
            errorMessage: message.errorMessage)
    }

    private func handleAgentEvent(_ evt: OpenClawAgentEventPayload) {
        let isPendingRun = self.pendingRuns.contains(evt.runId)
        let isLegacySessionStream = self.pendingRuns.isEmpty && self.sessionId == evt.runId
        if !isPendingRun, !isLegacySessionStream {
            return
        }
        self.logDiagnostic(
            "chat.ui event agent stream=\(evt.stream) "
                + "runId=\(evt.runId) pending=\(self.pendingRunCount)")

        switch evt.stream {
        case "assistant":
            if let text = evt.data["text"]?.value as? String {
                self.streamingAssistantText = text
            }
        case "lifecycle":
            self.handleAgentLifecycleEvent(evt, isPendingRun: isPendingRun)
        case "tool":
            guard let phase = evt.data["phase"]?.value as? String else { return }
            guard let name = evt.data["name"]?.value as? String else { return }
            guard let toolCallId = evt.data["toolCallId"]?.value as? String else { return }
            if phase == "start" {
                let args = evt.data["args"]
                self.pendingToolCallsById[toolCallId] = OpenClawChatPendingToolCall(
                    toolCallId: toolCallId,
                    name: name,
                    args: args,
                    startedAt: evt.ts.map(Double.init) ?? Date().timeIntervalSince1970 * 1000,
                    isError: nil)
            } else if phase == "result" {
                self.pendingToolCallsById[toolCallId] = nil
            }
        default:
            break
        }
    }

    private func handleAgentLifecycleEvent(_ evt: OpenClawAgentEventPayload, isPendingRun: Bool) {
        let phase = Self.lowercasedAgentEventString(evt.data["phase"])
        let status = Self.lowercasedAgentEventString(evt.data["status"])
        let aborted = Self.agentEventBool(evt.data["aborted"])
        let isFailure =
            phase == "error" || phase == "failed" || phase == "aborted" ||
            status == "error" || status == "failed" || status == "aborted"
        let isSuccessfulStatus =
            status == "ok" || status == "success" || status == "succeeded" ||
            status == "complete" || status == "completed"
        let isTerminalPhase = phase == "end" || phase == "complete" || phase == "completed"

        guard isTerminalPhase || isFailure || aborted || isSuccessfulStatus else { return }

        if isFailure || aborted {
            self.errorText = Self.agentLifecycleErrorMessage(evt, aborted: aborted)
        }
        if isPendingRun {
            self.clearPendingRun(evt.runId)
        }
        self.pendingToolCallsById = [:]
        self.streamingAssistantText = nil
        let context = self.beginHistoryRequest()
        Task { await self.refreshHistoryAfterRun(historyRequest: context) }
    }

    private static func lowercasedAgentEventString(_ value: AnyCodable?) -> String? {
        (value?.value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func agentEventBool(_ value: AnyCodable?) -> Bool {
        if let boolValue = value?.value as? Bool {
            return boolValue
        }
        guard let stringValue = lowercasedAgentEventString(value) else {
            return false
        }
        return stringValue == "true" || stringValue == "yes" || stringValue == "1"
    }

    private static func agentLifecycleErrorMessage(_ evt: OpenClawAgentEventPayload, aborted: Bool) -> String {
        if aborted {
            return "Run aborted"
        }
        if let message = evt.data["error"]?.value as? String,
           !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            return message
        }
        if let message = evt.data["message"]?.value as? String,
           !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            return message
        }
        return "Chat failed"
    }

    private func armPostSendRefreshFallback(
        runId: String,
        sessionSnapshot: SessionSnapshot,
        userMessageTimestamp: Double)
    {
        Task { [weak self] in
            for delayMs in Self.postSendRefreshDelaysMs {
                try? await Task.sleep(nanoseconds: delayMs * 1_000_000)
                let shouldContinue = await self?.refreshIfPending(
                    runId: runId,
                    sessionSnapshot: sessionSnapshot,
                    after: userMessageTimestamp,
                    diagnostic: "chat.ui refresh fallback sessionKey=\(sessionSnapshot.key) "
                        + "runId=\(runId) delayMs=\(delayMs)")
                guard shouldContinue == true else {
                    return
                }
            }
        }
    }

    private func armRunCompletionRefresh(
        runId: String,
        sessionSnapshot: SessionSnapshot,
        userMessageTimestamp: Double)
    {
        let timeoutMs = Int(pendingRunTimeoutMs)
        let transport = self.transport
        Task { [weak self, transport] in
            let observedCompletion = await transport.waitForRunCompletion(runId: runId, timeoutMs: timeoutMs)
            guard observedCompletion else { return }
            _ = await self?.refreshIfPending(
                runId: runId,
                sessionSnapshot: sessionSnapshot,
                after: userMessageTimestamp,
                diagnostic: "chat.ui run completion refresh sessionKey=\(sessionSnapshot.key) "
                    + "runId=\(runId)")
        }
    }

    private func refreshIfPending(
        runId: String,
        sessionSnapshot: SessionSnapshot,
        after timestamp: Double,
        diagnostic: String) async -> Bool
    {
        guard self.isCurrentSession(sessionSnapshot),
              self.pendingRuns.contains(runId)
        else {
            return false
        }
        guard !self.clearPendingRunIfAssistantMessagePresent(runId: runId, after: timestamp) else {
            return false
        }
        self.logDiagnostic(diagnostic)
        let historyContext = self.beginHistoryRequest(for: sessionSnapshot)
        let refresh = await self.refreshHistoryAfterRun(historyRequest: historyContext)
        guard refresh.permitsBoundedRetry else { return false }
        guard self.isCurrentSession(sessionSnapshot),
              self.pendingRuns.contains(runId)
        else {
            return false
        }
        return !self.clearPendingRunIfAssistantMessagePresent(runId: runId, after: timestamp)
    }

    @discardableResult
    private func clearPendingRunIfAssistantMessagePresent(runId: String, after timestamp: Double) -> Bool {
        guard self.hasAssistantMessage(after: timestamp) else { return false }
        self.clearPendingRun(runId)
        self.pendingToolCallsById = [:]
        self.streamingAssistantText = nil
        return true
    }

    private func hasAssistantMessageAfterLatestUser() -> Bool {
        Self.hasAssistantMessageAfterLatestUser(in: self.messages)
    }

    private static func hasUnansweredLatestUser(in messages: [OpenClawChatMessage]) -> Bool {
        self.latestUserTurn(in: messages) != nil && !self.hasAssistantMessageAfterLatestUser(in: messages)
    }

    private static func latestUserTurn(in messages: [OpenClawChatMessage]) -> LatestUserTurn? {
        guard let lastUserIndex = messages.lastIndex(where: { $0.role.lowercased() == "user" }) else {
            return nil
        }
        guard let refreshKey = self.userRefreshIdentityKey(for: messages[lastUserIndex]) else {
            return LatestUserTurn(
                refreshKey: nil,
                occurrence: 0,
                timestamp: messages[lastUserIndex].timestamp)
        }
        let occurrence = messages[...lastUserIndex].reduce(into: 0) { count, message in
            guard self.userRefreshIdentityKey(for: message) == refreshKey else { return }
            count += 1
        }
        return LatestUserTurn(
            refreshKey: refreshKey,
            occurrence: occurrence,
            timestamp: messages[lastUserIndex].timestamp)
    }

    private static func hasAnsweredUser(
        _ user: LatestUserTurn,
        in messages: [OpenClawChatMessage])
        -> Bool
    {
        guard let refreshKey = user.refreshKey else { return false }
        var occurrence = 0
        var latestMatchingUserIndex: [OpenClawChatMessage].Index?
        for (index, message) in messages.enumerated() {
            guard self.userRefreshIdentityKey(for: message) == refreshKey else { continue }
            occurrence += 1
            latestMatchingUserIndex = index
            guard occurrence == user.occurrence else { continue }
            let nextIndex = messages.index(after: index)
            guard nextIndex < messages.endIndex else { return false }
            return messages[nextIndex...].contains { message in
                guard message.role.lowercased() == "assistant" else { return false }
                let text = message.content.compactMap(\.text).joined(separator: "\n")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return !text.isEmpty || message.errorMessage != nil
            }
        }
        guard let latestMatchingUserIndex,
              messages.lastIndex(where: { $0.role.lowercased() == "user" }) == latestMatchingUserIndex
        else {
            return false
        }
        if let requestTimestamp = user.timestamp,
           let latestTimestamp = messages[latestMatchingUserIndex].timestamp,
           latestTimestamp < requestTimestamp
        {
            return false
        }
        let nextIndex = messages.index(after: latestMatchingUserIndex)
        guard nextIndex < messages.endIndex else { return false }
        return messages[nextIndex...].contains { message in
            guard message.role.lowercased() == "assistant" else { return false }
            let text = message.content.compactMap(\.text).joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return !text.isEmpty || message.errorMessage != nil
        }
    }

    private static func hasAssistantMessageAfterLatestUser(in messages: [OpenClawChatMessage]) -> Bool {
        guard let lastUserIndex = messages.lastIndex(where: { $0.role.lowercased() == "user" }) else {
            return false
        }
        guard lastUserIndex < messages.index(before: messages.endIndex) else {
            return false
        }
        return messages[messages.index(after: lastUserIndex)...].contains { message in
            guard message.role.lowercased() == "assistant" else { return false }
            let text = message.content.compactMap(\.text).joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return !text.isEmpty || message.errorMessage != nil
        }
    }

    private func hasAssistantMessage(after timestamp: Double) -> Bool {
        self.messages.contains { message in
            guard message.role.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "assistant" else {
                return false
            }
            guard (message.timestamp ?? 0) >= timestamp else { return false }
            let text = message.content.compactMap(\.text).joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return !text.isEmpty || message.errorMessage != nil
        }
    }

    @discardableResult
    private func refreshHistoryAfterRun(historyRequest request: HistoryRequest? = nil) async -> HistoryRefreshOutcome {
        let request = request ?? self.beginHistoryRequest()
        let attemptID = "history-\(request.session.generation)-\(request.id)"
        self.recordChatDiagnostic(
            state: "history_request_started",
            session: request.session,
            diagnosticAttemptID: attemptID,
            resultClass: "requested",
            messageCount: self.messages.count)
        do {
            let payload = try await transport.requestHistory(sessionKey: request.session.key)
            self.recordChatDiagnostic(
                state: "history_request_succeeded",
                session: request.session,
                diagnosticAttemptID: attemptID,
                resultClass: "success",
                messageCount: payload.messages?.count ?? 0)
            let applied = self.applyHistoryPayload(
                payload,
                for: request,
                preservingOptimisticLocalMessages: true)
            if applied {
                self.clearHistoryErrorIfOwned(by: request)
            }
            return applied ? .applied : .discarded
        } catch {
            let invalidRequest = Self.isInvalidRequest(error)
            self.recordChatDiagnostic(
                state: "history_request_rejected",
                session: request.session,
                diagnosticAttemptID: attemptID,
                resultClass: invalidRequest ? "gateway_rejected" : "failed",
                messageCount: self.messages.count)
            if invalidRequest {
                self.applyHistoryError(error, for: request)
            }
            chatUILogger.error("refresh history failed \(error.localizedDescription, privacy: .public)")
            return invalidRequest ? .invalidRequest : .transientFailure
        }
    }

    private func armPendingRunTimeout(runId: String) {
        self.pendingRunTimeoutTasks[runId]?.cancel()
        self.pendingRunTimeoutTasks[runId] = Task { [weak self] in
            let timeoutMs = await MainActor.run { self?.pendingRunTimeoutMs ?? 0 }
            try? await Task.sleep(nanoseconds: timeoutMs * 1_000_000)
            await MainActor.run { [weak self] in
                guard let self else { return }
                guard self.pendingRuns.contains(runId) else { return }
                self.logDiagnostic(
                    "chat.ui pending timeout sessionKey=\(self.sessionKey) "
                        + "runId=\(runId)")
                self.clearPendingRun(runId)
                self.errorText = "Timed out waiting for a reply; try again or refresh."
            }
        }
    }

    private func clearPendingRun(_ runId: String) {
        let wasPending = self.pendingRuns.contains(runId)
        self.pendingRuns.remove(runId)
        self.pendingLocalUserEchoMessageIDsByRunID[runId] = nil
        self.pendingRunTimeoutTasks[runId]?.cancel()
        self.pendingRunTimeoutTasks[runId] = nil
        if wasPending {
            self.logDiagnostic(
                "chat.ui pending cleared sessionKey=\(self.sessionKey) "
                    + "runId=\(runId)")
        }
    }

    private func clearPendingRuns(reason: String?) {
        let runIds = Array(pendingRuns)
        for runId in self.pendingRuns {
            self.pendingRunTimeoutTasks[runId]?.cancel()
        }
        self.pendingRunTimeoutTasks.removeAll()
        self.pendingRuns.removeAll()
        self.pendingLocalUserEchoMessageIDsByRunID.removeAll()
        if let reason, !reason.isEmpty {
            self.errorText = reason
            for runId in runIds {
                self.logDiagnostic(
                    "chat.ui pending cleared sessionKey=\(self.sessionKey) "
                        + "runId=\(runId) reason=\(reason)")
            }
        }
    }

    private func pollHealthIfNeeded(force: Bool, sessionSnapshot: SessionSnapshot? = nil) async {
        if !force, let last = lastHealthPollAt, Date().timeIntervalSince(last) < 10 {
            return
        }
        self.lastHealthPollAt = Date()
        do {
            let ok = try await transport.requestHealth(timeoutMs: 5000)
            if let sessionSnapshot, !self.isCurrentSession(sessionSnapshot) { return }
            self.healthOK = ok
        } catch {
            if let sessionSnapshot, !self.isCurrentSession(sessionSnapshot) { return }
            self.healthOK = false
        }
    }

    private static func normalizedThinkingLevel(_ level: String?) -> String? {
        guard let level else { return nil }
        let trimmed = level.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return nil }
        let collapsed = trimmed.replacingOccurrences(
            of: "[\\s_-]+",
            with: "",
            options: .regularExpression)

        switch collapsed {
        case "adaptive", "auto":
            return "adaptive"
        case "max":
            return "max"
        case "xhigh", "extrahigh":
            return "xhigh"
        case "off", "none":
            return "off"
        case "on", "enable", "enabled":
            return "low"
        case "min", "minimal", "think":
            return "minimal"
        case "low", "thinkhard":
            return "low"
        case "mid", "med", "medium", "thinkharder", "harder":
            return "medium"
        case "high", "ultra", "ultrathink", "thinkhardest", "highest":
            return "high"
        default:
            return trimmed
        }
    }
}
