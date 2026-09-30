import Foundation
import OpenClawKit
import SwiftUI
import UserNotifications

struct ArgusEvidenceNotificationReference: Hashable, Sendable {
    static let kind = "argus.evidence"
    let gatewayDeviceId: String
    let operationId: String
    let eventId: String
    let artifactSha256: String?

    static func parse(actionIdentifier: String, userInfo: [AnyHashable: Any]) -> Self? {
        guard actionIdentifier == UNNotificationDefaultActionIdentifier,
              let value = userInfo["openclaw"] as? [String: Any],
              value["kind"] as? String == kind,
              Set(value.keys).isSubset(of: ["kind", "gatewayDeviceId", "operationId", "eventId", "artifactSha256"]),
              let gateway = value["gatewayDeviceId"] as? String, validIdentity(gateway, limit: 128),
              let operation = value["operationId"] as? String, validIdentity(operation, limit: 300),
              let event = value["eventId"] as? String, validIdentity(event, limit: 300)
        else { return nil }
        let artifact = value["artifactSha256"] as? String
        if value["artifactSha256"] != nil {
            guard let artifact, artifact.utf8.count == 64, artifact.range(
                of: "^[0-9a-f]{64}$",
                options: .regularExpression) != nil
            else {
                return nil
            }
        }
        return Self(gatewayDeviceId: gateway, operationId: operation, eventId: event, artifactSha256: artifact)
    }

    private static func validIdentity(_ value: String, limit: Int) -> Bool {
        (1...limit).contains(value.unicodeScalars.count)
            && value == value.trimmingCharacters(in: .whitespacesAndNewlines)
            && !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
    }

    struct GatewayIdentity: Decodable, Sendable { let deviceId: String }

    @MainActor
    func resolve(
        identity: @MainActor () async throws -> GatewayIdentity,
        detail: @MainActor ([String: String]) async throws -> ArgusOperationDetail,
        stillCurrent: @MainActor () async -> Bool) async throws -> ArgusOperationDetail
    {
        guard await stillCurrent() else { throw ArgusOperationsError.unavailable }
        let gateway = try await identity()
        guard await stillCurrent() else { throw ArgusOperationsError.unavailable }
        guard Self.validIdentity(gateway.deviceId, limit: 128), gateway.deviceId == self.gatewayDeviceId else {
            throw ArgusOperationsError.invalidResponse
        }
        let response = try await detail(["operation_id": self.operationId, "event_id": self.eventId])
        guard await stillCurrent() else { throw ArgusOperationsError.unavailable }
        guard response.requested.id == self.operationId, response.requested.eventId == self.eventId else {
            throw ArgusOperationsError.invalidResponse
        }
        try response.validate(for: response.requested)
        // Federation groups observations by producer/task; each observation can have its own operation ID.
        if response.requested.source == "canonical:codex-completion-adapter" {
            guard response.item.id == self.operationId,
                  response.timeline.allSatisfy({ $0.id == self.operationId })
            else {
                throw ArgusOperationsError.invalidResponse
            }
        }
        if let digest = self.artifactSha256 {
            guard response.requested.artifacts.contains(where: { $0.sha256 == digest }) else {
                throw ArgusOperationsError.invalidResponse
            }
        }
        return response
    }
}

struct ArgusEvidenceNotificationRequest: Hashable, Identifiable {
    let reference: ArgusEvidenceNotificationReference
    let gatewayOwnerID: String?
    var id: Self {
        self
    }
}

extension NodeAppModel {
    func reopenLastArgusEvidenceNotification() {
        guard let request = self.lastArgusEvidenceNotificationRequest else { return }
        // Keep the original route binding; reopening must not rebind old evidence to a new gateway.
        self.argusTaskActivityRequest = nil
        self.argusEvidenceNotificationRequest = request
        self.argusEvidenceNotificationPresentationID &+= 1
    }

    func openArgusEvidenceNotification(_ reference: ArgusEvidenceNotificationReference) {
        // One pending destination; duplicate taps never enqueue work or acknowledge delivery.
        self.argusTaskActivityRequest = nil
        self.argusEvidenceNotificationRequest = .init(
            reference: reference, gatewayOwnerID: self.chatOutboxGatewayOwnerID)
        self.argusEvidenceNotificationPresentationID &+= 1
    }
}

struct ArgusEvidenceResumeButton: View {
    var reopen: () -> Void

    var body: some View {
        Button(action: self.reopen) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "doc.text.magnifyingglass")
                    .foregroundStyle(OpenClawBrand.accent)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Reopen last notification")
                        .font(.headline)
                    Text("Return to its exact work evidence. Available during this app session.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.right")
                    .accessibilityHidden(true)
            }
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("argus.reopenLastNotification")
    }
}

struct ArgusEvidenceNotificationTaskID: Equatable {
    let gatewayOwnerID: String?
    let connected: Bool
    let routeAdmissionGeneration: UInt64
    let scenePhase: ScenePhase
    let retry: Int
}

struct ArgusEvidenceNotificationReadState {
    private(set) var resolved: ArgusOperationDetail?
    private(set) var client: ArgusOperationsClient?
    private(set) var error: String?
    var canRetryRetainedDetail: Bool {
        self.resolved != nil && self.client != nil && self.error != nil
    }

    mutating func publish(_ detail: ArgusOperationDetail, using client: ArgusOperationsClient) {
        self.resolved = detail
        self.client = client
        self.error = nil
    }

    mutating func invalidate(_ message: String) {
        self.resolved = nil
        self.client = nil
        self.error = message
    }

    mutating func fail(_ failure: Error) {
        if let sourceError = failure as? ArgusOperationsError,
           case .invalidResponse = sourceError {
            self.invalidate("The exact evidence reference did not match this gateway.")
        } else if self.resolved != nil && self.client != nil {
            self.error = "Showing last verified evidence. Reconnect to check for updates."
        } else {
            self.error = "The exact evidence reference is unavailable. Retry after reconnecting."
        }
    }
}

struct ArgusEvidenceNotificationView: View {
    @Environment(NodeAppModel.self) private var appModel
    @Environment(\.scenePhase) private var scenePhase
    let request: ArgusEvidenceNotificationRequest
    @State private var boundGatewayID: String?
    @State private var readState = ArgusEvidenceNotificationReadState()
    @State private var retry = 0
    @State private var generation = 0

    init(request: ArgusEvidenceNotificationRequest) {
        self.request = request
        self._boundGatewayID = State(initialValue: request.gatewayOwnerID)
    }

    var body: some View {
        Group {
            if let resolved = self.readState.resolved, let client = self.readState.client,
               self.boundGatewayID == self.appModel.chatOutboxGatewayOwnerID {
                ArgusOperationDetailView(
                    operation: resolved.requested,
                    client: client,
                    initialDetail: resolved,
                    initialArtifactSHA: self.request.reference.artifactSha256)
                    .safeAreaInset(edge: .top, spacing: 0) {
                        VStack(spacing: 0) {
                            if self.isAutomaticallyRecovering {
                                ArgusEvidenceRecoveryNotice(retainsDetail: true)
                                    .padding()
                            }
                            if let warning = self.readState.error {
                                VStack(alignment: .leading, spacing: 8) {
                                    Text(warning).font(.subheadline)
                                    if self.readState.canRetryRetainedDetail {
                                        Button("Retry evidence check") { self.retry += 1 }
                                            .disabled(!self.appModel.isOperatorGatewayConnected)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal)
                            }
                        }
                    }
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Work evidence").font(.headline)
                    if let error = self.readState.error {
                        Text(error)
                    } else if self.isAutomaticallyRecovering {
                        ArgusEvidenceRecoveryNotice(retainsDetail: false)
                        Text("You can reopen this notification from Home during this app session.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    } else if self.appModel.gatewayPairingPaused || self.appModel.operatorReconnectNeedsUserAction {
                        Text(self.appModel.gatewayDisplayStatusText)
                        Text("Review the connection in Settings before opening this evidence.")
                            .font(.subheadline)
                    } else if !self.appModel.isOperatorGatewayConnected {
                        Text(
                            """
                            Connect to the paired gateway to open this evidence. \
                            You can return from Home using Reopen last notification during this app session.
                            """)
                    } else {
                        ProgressView("Checking evidence reference")
                    }
                    if !self.isAutomaticallyRecovering {
                        Button("Retry") { self.retry += 1 }
                            .disabled(!self.appModel.isOperatorGatewayConnected)
                    }
                }
                .padding()
            }
        }
        .navigationTitle("Evidence")
        .task(id: ArgusEvidenceNotificationTaskID(
            gatewayOwnerID: self.appModel.chatOutboxGatewayOwnerID,
            connected: self.appModel.isOperatorGatewayConnected,
            routeAdmissionGeneration: self.appModel.operatorRouteAdmissionGeneration,
            scenePhase: self.scenePhase,
            retry: self.retry)) {
                guard self.scenePhase == .active else { return }
                await self.load()
        }
    }

    private var isAutomaticallyRecovering: Bool {
        ArgusEvidenceRecoveryNotice.isEligible(
            connected: self.appModel.isOperatorGatewayConnected,
            automaticReconnect: self.appModel.gatewayAutoReconnectEnabled,
            pairingPaused: self.appModel.gatewayPairingPaused,
            requiresUserAction: self.appModel.operatorReconnectNeedsUserAction,
            demoMode: self.appModel.isAppleReviewDemoModeEnabled,
            configuredOwner: self.appModel.activeGatewayConnectConfig?.effectiveStableID,
            currentOwner: self.appModel.chatOutboxGatewayOwnerID,
            boundOwner: self.boundGatewayID,
            hasError: self.readState.resolved == nil && self.readState.error != nil)
    }

    private func load() async {
        self.generation += 1
        let generation = self.generation
        guard !Task.isCancelled, self.appModel.argusEvidenceNotificationRequest == self.request else { return }
        guard !self.appModel.isAppleReviewDemoModeEnabled else {
            self.readState.invalidate("Notification evidence is unavailable in demo mode.")
            return
        }
        guard let gatewayID = self.appModel.chatOutboxGatewayOwnerID else { return }
        if let boundGatewayID, boundGatewayID != gatewayID {
            self.readState.invalidate(
                "The paired gateway changed. This notification cannot open evidence from another gateway.")
            return
        }
        self.boundGatewayID = gatewayID
        guard self.appModel.isOperatorGatewayConnected else { return }
        do {
            let session = self.appModel.operatorSession
            guard let route = await session.currentRoute(ifGatewayID: gatewayID) else {
                throw ArgusOperationsError.unavailable
            }
            let client = ArgusOperationsClient(session: session, gatewayID: gatewayID, pinnedRoute: route)
            let response = try await self.request.reference.resolve(
                identity: { try await client.request(
                    "gateway.identity.get",
                    params: [:],
                    as: ArgusEvidenceNotificationReference.GatewayIdentity.self) },
                detail: {
                    try await client.request("argus.operations.detail", params: $0, as: ArgusOperationDetail.self)
                },
                stillCurrent: {
                    guard !Task.isCancelled, self.generation == generation,
                          self.appModel.argusEvidenceNotificationRequest == self.request,
                          self.appModel.chatOutboxGatewayOwnerID == gatewayID else { return false }
                    guard await session.isCurrentRoute(route) else { return false }
                    return !Task.isCancelled && self.generation == generation
                        && self.appModel.argusEvidenceNotificationRequest == self.request
                        && self.appModel.chatOutboxGatewayOwnerID == gatewayID
                })
            guard await session.isCurrentRoute(route), !Task.isCancelled, self.generation == generation,
                  self.appModel.argusEvidenceNotificationRequest == self.request,
                  self.appModel.chatOutboxGatewayOwnerID == gatewayID else { return }
            self.readState.publish(response, using: client)
        } catch {
            guard !Task.isCancelled, self.generation == generation else { return }
            self.readState.fail(error)
        }
    }
}

struct ArgusEvidenceRecoveryNotice: View {
    let retainsDetail: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(self.retainsDetail ? "Reconnecting…" : "Waiting for connection")
                .font(.subheadline.weight(.semibold))
            Text(self.retainsDetail ? "Your last view is still here." : "We’ll try again automatically.")
                .font(.subheadline)
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(OpenClawBrand.graphite, in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(OpenClawBrand.accent.opacity(0.25), lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
    }

    static func isEligible(
        connected: Bool, automaticReconnect: Bool, pairingPaused: Bool, requiresUserAction: Bool, demoMode: Bool,
        configuredOwner: String?, currentOwner: String?, boundOwner: String?, hasError: Bool) -> Bool
    {
        guard !connected, automaticReconnect, !pairingPaused, !requiresUserAction, !demoMode, !hasError,
              let configuredOwner, !configuredOwner.isEmpty,
              configuredOwner == currentOwner, configuredOwner == boundOwner else { return false }
        return true
    }
}
