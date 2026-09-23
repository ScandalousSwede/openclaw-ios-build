import Foundation
import SwiftUI

/// This projection contains fixed lifecycle values, never task text or session
/// identifiers. Execution, semantic outcome and delivery are deliberately separate.
struct ArgusTaskActivitySnapshot: Decodable, Equatable, Sendable {
    enum Status: String, Decodable, Sendable {
        case queued, running, succeeded, failed, cancelled, lost
        case timedOut = "timed_out"
    }

    enum Outcome: String, Decodable, Sendable {
        case succeeded, blocked
    }

    enum Delivery: String, Decodable, Sendable {
        case pending, delivered, failed
        case sessionQueued = "session_queued"
        case parentMissing = "parent_missing"
        case notApplicable = "not_applicable"

        var label: String {
            switch self {
            case .pending: "Delivery pending"
            case .delivered: "Delivery recorded"
            case .failed: "Delivery failed"
            case .sessionQueued: "Queued for session delivery"
            case .parentMissing: "Delivery destination unavailable"
            case .notApplicable: "No delivery expected"
            }
        }
    }

    typealias Phase = ArgusTaskActivityPhase

    let taskId: String
    let invocationRequestId: String
    let lifecycleRevision: UInt64
    let activityExpiresAt: Int64
    let status: Status
    let terminalOutcome: Outcome?
    let deliveryStatus: Delivery
    let phase: Phase

    var expiresAt: Date { Date(timeIntervalSince1970: Double(self.activityExpiresAt) / 1000) }
    var activityState: ArgusTaskActivityState {
        .init(phase: self.phase, lifecycleRevision: self.lifecycleRevision, expiresAtMs: self.activityExpiresAt)
    }

    func validate(taskID: String, requestID: String? = nil) throws {
        let mappedPhase = self.status == .succeeded && self.terminalOutcome == .blocked
            ? Phase.blocked : Phase(rawValue: self.status.rawValue)
        guard self.taskId == taskID,
              ArgusTaskActivityReference.validTaskID(self.taskId),
              ArgusTaskActivityReference.validRequestID(self.invocationRequestId),
              requestID == nil || requestID == self.invocationRequestId,
              (1...9_007_199_254_740_991).contains(self.lifecycleRevision),
              (1...9_007_199_254_740_991).contains(self.activityExpiresAt),
              self.phase == mappedPhase,
              self.terminalOutcome == nil || (self.status != .queued && self.status != .running)
        else { throw ArgusOperationsError.invalidResponse }
    }

    func canStartActivity(at now: Date) -> Bool {
        !self.phase.isTerminal && self.expiresAt > now
    }

    func validateSuccessor(of previous: Self) throws {
        guard self.taskId == previous.taskId, self.invocationRequestId == previous.invocationRequestId,
              self.activityExpiresAt == previous.activityExpiresAt,
              self.lifecycleRevision >= previous.lifecycleRevision,
              self.lifecycleRevision != previous.lifecycleRevision || self == previous
        else { throw ArgusOperationsError.invalidResponse }
    }
}

struct ArgusTaskActivityResponse: Decodable, Sendable {
    let task: ArgusTaskActivitySnapshot
}

extension ArgusTaskActivityReference {
    @MainActor
    func resolve(
        identity: () async throws -> ArgusEvidenceNotificationReference.GatewayIdentity,
        task: ([String: String]) async throws -> ArgusTaskActivityResponse,
        stillCurrent: () async -> Bool) async throws -> ArgusTaskActivitySnapshot
    {
        guard await stillCurrent() else { throw ArgusOperationsError.unavailable }
        let gateway = try await identity()
        guard await stillCurrent() else { throw ArgusOperationsError.unavailable }
        guard gateway.deviceId == self.gatewayDeviceID else { throw ArgusOperationsError.invalidResponse }
        let response = try await task(["taskId": self.taskID, "invocationRequestId": self.requestID])
        guard await stillCurrent() else { throw ArgusOperationsError.unavailable }
        try response.task.validate(taskID: self.taskID, requestID: self.requestID)
        return response.task
    }
}

struct ArgusTaskActivityRequest: Hashable, Identifiable {
    let reference: ArgusTaskActivityReference
    let gatewayOwnerID: String?
    let title: String?
    var id: Self { self }

    init(reference: ArgusTaskActivityReference, gatewayOwnerID: String?, title: String? = nil) {
        self.reference = reference
        self.gatewayOwnerID = gatewayOwnerID
        self.title = title
    }
}

extension NodeAppModel {
    /// URL handling records a read-only destination. The destination reader must
    /// verify gateway and invocation identity before displaying task information.
    @discardableResult
    func handleTaskActivityURL(_ url: URL) -> Bool {
        guard let reference = ArgusTaskActivityReference.parse(url) else { return false }
        if let original = self.lastArgusTaskActivityRequest, original.reference == reference {
            // A warm activity tap must preserve the source title and original
            // paired owner even if another gateway is currently selected.
            self.openTaskActivity(original)
            return true
        }
        self.openTaskActivity(.init(reference: reference, gatewayOwnerID: self.chatOutboxGatewayOwnerID))
        return true
    }

    func openTaskActivity(_ request: ArgusTaskActivityRequest) {
        self.argusEvidenceNotificationRequest = nil
        self.argusTaskActivityRequest = request
        self.argusTaskActivityPresentationID &+= 1
    }

    func reopenLastTaskActivity() {
        guard let request = self.lastArgusTaskActivityRequest else { return }
        // Back clears only presentation. Reopen must retain the original owner;
        // switching gateways never grants an old task reference a new identity.
        self.openTaskActivity(request)
    }
}

struct ArgusTaskActivityResumeButton: View {
    var reopen: () -> Void

    var body: some View {
        Button(action: self.reopen) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "list.bullet.rectangle").foregroundStyle(OpenClawBrand.accent)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Reopen last task activity").font(.headline)
                    Text("Return to the same task and invocation during this app session.")
                        .font(.subheadline).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.right").accessibilityHidden(true)
            }
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct ArgusTaskActivityContextView: View {
    @Environment(NodeAppModel.self) private var appModel
    @Environment(\.scenePhase) private var scenePhase
    let request: ArgusTaskActivityRequest
    @State private var boundGatewayID: String?
    @State private var snapshot: ArgusTaskActivitySnapshot?
    @State private var error: String?
    @State private var retry = 0
    @State private var generation = 0
    @State private var trackingError: String?
    @State private var isVisible = false

    init(request: ArgusTaskActivityRequest) {
        self.request = request
        self._boundGatewayID = State(initialValue: request.gatewayOwnerID)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let snapshot, self.boundGatewayID == self.appModel.chatOutboxGatewayOwnerID {
                    if let title = self.request.title { Text(title).font(.headline) }
                    Text(snapshot.phase.headline).font(.title2.bold())
                    if !self.appModel.isOperatorGatewayConnected || self.error != nil {
                        Text("Showing the last check. Task state may have changed.")
                            .font(.subheadline)
                    }
                    Text(snapshot.deliveryStatus.label)
                    Text("Task state refreshes while this view is open. Background task updates are not available yet.")
                        .font(.subheadline).foregroundStyle(.secondary)
                    if snapshot.terminalOutcome == .blocked {
                        Text("Execution ended with a blocked outcome. This does not mean the requested work was fulfilled.")
                    }
                    TimelineView(.periodic(from: .now, by: 30)) { timeline in
                        if snapshot.expiresAt <= timeline.date {
                            Text("The activity tracking period has ended. This exact task context remains readable.")
                                .foregroundStyle(.secondary)
                        }
                    }
                    DisclosureGroup("Technical details") {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Task: \(snapshot.taskId)")
                            Text("Invocation: \(snapshot.invocationRequestId)")
                            Text("Revision: \(snapshot.lifecycleRevision)")
                            Text("Execution: \(snapshot.status.rawValue)")
                        }
                        .font(.caption).textSelection(.enabled)
                    }
                    if LiveActivityManager.shared.isTracking(self.request.reference) {
                        Button("Stop Lock Screen tracking") {
                            LiveActivityManager.shared.stopTracking(self.request.reference)
                        }
                    } else if snapshot.canStartActivity(at: .now) {
                        Button("Track on Lock Screen") { Task { await self.startTracking() } }
                            .disabled(!self.appModel.isOperatorGatewayConnected || self.error != nil)
                    }
                    if let trackingError { Text(trackingError).font(.subheadline) }
                    if LiveActivityManager.shared.failedTaskStart == self.request.reference {
                        Text("The system could not start the Live Activity. Task context remains available here.")
                            .font(.subheadline)
                    }
                } else if let error {
                    Text(error)
                } else if !self.appModel.isOperatorGatewayConnected {
                    Text("Connect to the original paired gateway to read this task. Reopen last task activity is available from Home during this app session.")
                } else {
                    ProgressView("Checking exact task context")
                }
                if let error, self.snapshot != nil {
                    Text(error).font(.subheadline).foregroundStyle(.secondary)
                }
                Button("Check task state") { self.retry += 1 }
                    .disabled(!self.appModel.isOperatorGatewayConnected)
            }
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
        }
        .navigationTitle("Task activity")
        .onAppear { self.isVisible = true }
        .onDisappear {
            self.isVisible = false
            self.generation += 1
        }
        .task(id: "\(self.appModel.chatOutboxGatewayOwnerID ?? "none")|\(self.appModel.isOperatorGatewayConnected)|\(self.scenePhase)|\(self.retry)") {
            guard self.scenePhase == .active else { return }
            repeat {
                await self.load()
                guard self.appModel.isOperatorGatewayConnected else { return }
                do { try await Task.sleep(for: .seconds(30)) }
                catch { return }
            } while !Task.isCancelled
        }
    }

    private func startTracking() async {
        await self.load()
        guard !Task.isCancelled, let snapshot, self.error == nil,
              self.isVisible, self.scenePhase == .active, self.appModel.isOperatorGatewayConnected,
              self.boundGatewayID == self.appModel.chatOutboxGatewayOwnerID,
              self.appModel.argusTaskActivityRequest == self.request else { return }
        do {
            try LiveActivityManager.shared.trackTask(snapshot, reference: self.request.reference)
            self.trackingError = nil
        } catch {
            self.trackingError = "Tracking could not start. The task must still be active, within its tracking period, and Live Activities must be enabled."
        }
    }

    private func load() async {
        self.generation += 1
        let generation = self.generation
        guard !self.appModel.isAppleReviewDemoModeEnabled else {
            self.snapshot = nil
            self.error = "Task activity is unavailable in demo mode."
            return
        }
        guard let owner = self.appModel.chatOutboxGatewayOwnerID else { return }
        guard self.boundGatewayID == nil || self.boundGatewayID == owner else {
            self.snapshot = nil
            self.error = "The paired gateway changed. This task cannot be opened through another gateway."
            return
        }
        self.boundGatewayID = owner
        guard self.appModel.isOperatorGatewayConnected else { return }
        do {
            let session = self.appModel.operatorSession
            guard let route = await session.currentRoute(ifGatewayID: owner) else {
                throw ArgusOperationsError.unavailable
            }
            let client = ArgusOperationsClient(session: session, gatewayID: owner, pinnedRoute: route)
            let response = try await self.request.reference.resolve(
                identity: { try await client.request(
                    "gateway.identity.get", params: [:],
                    as: ArgusEvidenceNotificationReference.GatewayIdentity.self) },
                task: { try await client.request("tasks.activity.get", params: $0, as: ArgusTaskActivityResponse.self) },
                stillCurrent: {
                    guard self.isVisible, !Task.isCancelled, self.generation == generation,
                          self.appModel.argusTaskActivityRequest == self.request,
                          self.appModel.chatOutboxGatewayOwnerID == owner else { return false }
                    guard await session.isCurrentRoute(route) else { return false }
                    return !Task.isCancelled && self.generation == generation
                        && self.appModel.argusTaskActivityRequest == self.request
                        && self.appModel.chatOutboxGatewayOwnerID == owner
                })
            guard await session.isCurrentRoute(route), !Task.isCancelled, self.generation == generation,
                  self.appModel.argusTaskActivityRequest == self.request,
                  self.appModel.chatOutboxGatewayOwnerID == owner else { return }
            if let snapshot { try response.validateSuccessor(of: snapshot) }
            try LiveActivityManager.shared.refreshTask(response, reference: self.request.reference)
            self.snapshot = response
            self.error = nil
        } catch {
            guard !Task.isCancelled, self.generation == generation else { return }
            switch error {
            case is DecodingError, ArgusOperationsError.invalidResponse: self.snapshot = nil
            default: break
            }
            self.error = "The exact task context is unavailable or could not be verified. No action was submitted."
        }
    }
}
