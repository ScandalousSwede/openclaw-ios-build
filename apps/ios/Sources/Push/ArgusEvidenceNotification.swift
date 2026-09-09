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
    func openArgusEvidenceNotification(_ reference: ArgusEvidenceNotificationReference) {
        // One pending destination; duplicate taps never enqueue work or acknowledge delivery.
        self.argusEvidenceNotificationRequest = .init(
            reference: reference, gatewayOwnerID: self.chatOutboxGatewayOwnerID)
        self.argusEvidenceNotificationPresentationID &+= 1
    }
}

struct ArgusEvidenceNotificationView: View {
    @Environment(NodeAppModel.self) private var appModel
    let request: ArgusEvidenceNotificationRequest
    @State private var boundGatewayID: String?
    @State private var resolved: ArgusOperationDetail?
    @State private var client: ArgusOperationsClient?
    @State private var error: String?
    @State private var retry = 0
    @State private var generation = 0

    init(request: ArgusEvidenceNotificationRequest) {
        self.request = request
        self._boundGatewayID = State(initialValue: request.gatewayOwnerID)
    }

    var body: some View {
        Group {
            if let resolved, let client, self.boundGatewayID == self.appModel.chatOutboxGatewayOwnerID {
                ArgusOperationDetailView(
                    operation: resolved.requested,
                    client: client,
                    initialDetail: resolved,
                    initialArtifactSHA: self.request.reference.artifactSha256)
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Work evidence").font(.headline)
                    if let error {
                        Text(error)
                    } else if !self.appModel.isOperatorGatewayConnected {
                        Text(
                            """
                            Connect to the paired gateway to open this evidence. \
                            The reference is retained while this view is open.
                            """)
                    } else {
                        ProgressView("Checking evidence reference")
                    }
                    Button("Retry") { self.retry += 1 }
                        .disabled(!self.appModel.isOperatorGatewayConnected)
                }
                .padding()
            }
        }
        .navigationTitle("Evidence")
        .task(
            id: """
            \(self.appModel.chatOutboxGatewayOwnerID ?? "none")|\
            \(self.appModel.isOperatorGatewayConnected)|\(self.retry)
            """) {
                await self.load()
        }
    }

    private func load() async {
        self.generation += 1
        let generation = self.generation
        guard !self.appModel.isAppleReviewDemoModeEnabled else {
            self.error = "Notification evidence is unavailable in demo mode."
            return
        }
        guard let gatewayID = self.appModel.chatOutboxGatewayOwnerID else { return }
        if let boundGatewayID, boundGatewayID != gatewayID {
            self.resolved = nil
            self.client = nil
            self.error = "The paired gateway changed. This notification cannot open evidence from another gateway."
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
            self.resolved = response
            self.client = client
            self.error = nil
        } catch {
            guard !Task.isCancelled, self.generation == generation else { return }
            self.resolved = nil
            self.client = nil
            self.error = """
            The exact evidence reference is unavailable or did not match this gateway. \
            Retry after reconnecting.
            """
        }
    }
}
