import CryptoKit
import Foundation
import Observation
import Testing
import UserNotifications
@testable import OpenClaw

@MainActor
@Suite(.serialized)
struct ArgusEvidenceNotificationTests {
    private static let gateway = "fixture-gateway-device"
    private static let owner = "fixture-paired-route"

    static func fixture() -> (ArgusOperationDetail, Data) {
        let bytes = Data("Synthetic artifact from the exact notification event.".utf8)
        let hash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let requested = ArgusOperation(
            operationId: "fixture-operation",
            taskId: "fixture-task",
            eventId: "fixture-requested-event",
            title: "Synthetic earlier result",
            source: "federation:fixture",
            project: "Argus",
            kind: "evidence",
            state: "observed",
            occurredAt: "2026-09-09T00:00:00Z",
            observedAt: "2026-09-09T00:00:00Z",
            artifacts: [.init(sha256: hash, bytes: bytes.count, displayName: "requested.txt")],
            supersedesEventId: nil,
            ownerAccepted: false)
        let current = ArgusOperation(
            operationId: "fixture-correction-operation",
            taskId: requested.taskId,
            eventId: "fixture-correction-event",
            title: "Synthetic corrected result",
            source: requested.source,
            project: requested.project,
            kind: "evidence",
            state: "observed",
            occurredAt: "2026-09-09T00:01:00Z",
            observedAt: "2026-09-09T00:01:00Z",
            artifacts: [.init(sha256: String(repeating: "b", count: 64), bytes: 10, displayName: "correction.txt")],
            supersedesEventId: requested.eventId,
            ownerAccepted: false)
        return (.init(
            item: current,
            requested: requested,
            timeline: [requested],
            coverage: .init(complete: true, hasMore: false, observedAt: current.observedAt),
            ownerAccepted: false), bytes)
    }

    private func payload(for detail: ArgusOperationDetail) -> [AnyHashable: Any] {
        ["openclaw": [
            "kind": "argus.evidence",
            "gatewayDeviceId": Self.gateway,
            "operationId": detail.requested.id,
            "eventId": detail.requested.eventId,
            "artifactSha256": detail.requested.artifacts[0].sha256,
        ]]
    }

    @Test func `notification opens exact detail and artifact across corrections`() async throws {
        let (detail, bytes) = Self.fixture()
        let model = NodeAppModel()
        model._test_setChatOutboxGatewayOwnerID(Self.owner)
        let delegate = OpenClawAppDelegate()
        delegate.appModel = model
        #expect(delegate.routeArgusEvidenceNotification(
            actionIdentifier: UNNotificationDefaultActionIdentifier,
            userInfo: self.payload(for: detail)))
        let request = try #require(model.argusEvidenceNotificationRequest)
        #expect(request.gatewayOwnerID == Self.owner)
        var calls: [String] = []
        let resolved = try await request.reference.resolve(
            identity: { calls.append("identity"); return .init(deviceId: Self.gateway) },
            detail: { params in
                calls.append("detail")
                #expect(params == ["operation_id": detail.requested.id, "event_id": detail.requested.eventId])
                return detail
            },
            stillCurrent: { model.argusEvidenceNotificationRequest == request })
        #expect(calls == ["identity", "detail"])
        #expect(resolved.item.eventId != resolved.requested.eventId)
        #expect(resolved.item.id != resolved.requested.id)
        let artifact = try #require(resolved.requested.artifacts.first {
            $0.sha256 == request.reference.artifactSha256
        })
        let opener = ArgusArtifactOpenStore()
        opener.setAvailable(true)
        await opener.open(artifact, item: resolved.requested) { params in
            #expect(params == [
                "operation_id": detail.requested.id,
                "event_id": detail.requested.eventId,
                "sha256": artifact.sha256,
            ])
            return .init(
                sha256: artifact.sha256,
                bytes: bytes.count,
                mimeType: "text/plain",
                contentBase64: bytes.base64EncodedString(),
                operationId: detail.requested.id,
                eventId: detail.requested.eventId)
        }
        #expect(opener.preview?.data == bytes)
        #expect(!resolved.ownerAccepted)
        #expect(delegate.routeArgusEvidenceNotification(
            actionIdentifier: UNNotificationDefaultActionIdentifier,
            userInfo: self.payload(for: detail)))
        #expect(model.argusEvidenceNotificationRequest == request)
    }

    @MainActor private final class PresentationObservation {
        var requests = 0
    }

    @Test func `each repeated tap emits a presentation request without changing the detail destination`() throws {
        let (detail, _) = Self.fixture()
        let model = NodeAppModel()
        let delegate = OpenClawAppDelegate()
        delegate.appModel = model
        let observation = PresentationObservation()
        for _ in 0..<2 {
            withObservationTracking {
                _ = model.argusEvidenceNotificationPresentationID
            } onChange: {
                MainActor.assumeIsolated { observation.requests += 1 }
            }
            #expect(delegate.routeArgusEvidenceNotification(
                actionIdentifier: UNNotificationDefaultActionIdentifier,
                userInfo: self.payload(for: detail)))
        }
        #expect(observation.requests == 2)
        #expect(model.argusEvidenceNotificationPresentationID == 2)
        let destination = try #require(model.argusEvidenceNotificationRequest)
        #expect(!delegate.routeArgusEvidenceNotification(
            actionIdentifier: UNNotificationDismissActionIdentifier,
            userInfo: self.payload(for: detail)))
        #expect(model.argusEvidenceNotificationPresentationID == 2)
        #expect(model.argusEvidenceNotificationRequest == destination)
    }

    @Test func `pending artifact retries disconnects but stops verification failures`() async throws {
        let (detail, bytes) = Self.fixture()
        let artifact = try #require(detail.requested.artifacts.first)
        let opener = ArgusArtifactOpenStore(initialArtifactSHA: artifact.sha256)
        let response = ArgusOperationArtifact(
            sha256: artifact.sha256,
            bytes: bytes.count,
            mimeType: "text/plain",
            contentBase64: bytes.base64EncodedString(),
            operationId: detail.requested.id,
            eventId: detail.requested.eventId)
        var requests: [[String: String]] = []
        opener.setAvailable(true)
        await opener.openPendingArtifact(for: detail.requested) { params in
            requests.append(params)
            opener.setAvailable(false)
            return response
        }
        #expect(opener.preview == nil)
        #expect(opener.pendingInitialArtifactSHA == artifact.sha256)
        opener.setAvailable(true)
        await opener.openPendingArtifact(for: detail.requested) { params in
            requests.append(params)
            return response
        }
        #expect(requests.count == 2 && requests[0] == requests[1])
        #expect(requests[1] == [
            "operation_id": detail.requested.id,
            "event_id": detail.requested.eventId,
            "sha256": artifact.sha256,
        ])
        #expect(opener.preview?.data == bytes)
        #expect(opener.pendingInitialArtifactSHA == nil)
        let rejected = ArgusArtifactOpenStore(initialArtifactSHA: artifact.sha256)
        rejected.setAvailable(true)
        await rejected.openPendingArtifact(for: detail.requested) { _ in
            .init(
                sha256: artifact.sha256,
                bytes: bytes.count,
                mimeType: "text/plain",
                contentBase64: Data(repeating: 0, count: bytes.count).base64EncodedString(),
                operationId: detail.requested.id,
                eventId: detail.requested.eventId)
        }
        #expect(rejected.preview == nil && rejected.error != nil)
        #expect(rejected.pendingInitialArtifactSHA == nil)
        rejected.setAvailable(true)
        await rejected.openPendingArtifact(for: detail.requested) { _ in
            Issue.record("Failed verification was automatically retried")
            return response
        }
    }

    @Test func `delayed parent route qualification retriggers the same pending artifact opener`() async throws {
        let (detail, bytes) = Self.fixture()
        let artifact = try #require(detail.requested.artifacts.first)
        let opener = ArgusArtifactOpenStore(initialArtifactSHA: artifact.sha256)
        let offline = ArgusOperationDetailTaskID(
            isVisible: true,
            sameGateway: true,
            isConnected: false,
            routeGeneration: 1,
            socketGeneration: 1)
        let reconnectBeforeQualification = ArgusOperationDetailTaskID(
            isVisible: true, sameGateway: true, isConnected: true, routeGeneration: 1, socketGeneration: 1)
        #expect(offline != reconnectBeforeQualification)
        opener.setAvailable(true)
        var requests: [[String: String]] = []
        await opener.openPendingArtifact(for: detail.requested) { params in
            requests.append(params)
            // Connectivity returned before the parent finished identity/detail requalification.
            throw ArgusOperationsError.unavailable
        }
        #expect(opener.preview == nil && opener.pendingInitialArtifactSHA == artifact.sha256)
        let qualifiedReplacement = ArgusOperationDetailTaskID(
            isVisible: true, sameGateway: true, isConnected: true, routeGeneration: 2, socketGeneration: 2)
        // The production .task uses this exact identity. Availability alone is unchanged.
        #expect(qualifiedReplacement.isConnected == reconnectBeforeQualification.isConnected)
        #expect(qualifiedReplacement != reconnectBeforeQualification)
        await opener.openPendingArtifact(for: detail.requested) { params in
            requests.append(params)
            return .init(
                sha256: artifact.sha256,
                bytes: bytes.count,
                mimeType: "text/plain",
                contentBase64: bytes.base64EncodedString(),
                operationId: detail.requested.id,
                eventId: detail.requested.eventId)
        }
        try #require(requests.count == 2)
        #expect(requests[0] == requests[1])
        #expect(opener.preview?.data == bytes && opener.pendingInitialArtifactSHA == nil)
        let repeatedPublication = ArgusOperationDetailTaskID(
            isVisible: true, sameGateway: true, isConnected: true, routeGeneration: 2, socketGeneration: 2)
        #expect(repeatedPublication == qualifiedReplacement)
    }

    @Test func `offline reference survives while superseded or retired reads cannot publish`() async throws {
        let (detail, _) = Self.fixture()
        let model = NodeAppModel()
        model._test_setChatOutboxGatewayOwnerID(Self.owner)
        let delegate = OpenClawAppDelegate()
        delegate.appModel = model
        _ = delegate.routeArgusEvidenceNotification(
            actionIdentifier: UNNotificationDefaultActionIdentifier,
            userInfo: self.payload(for: detail))
        let request = try #require(model.argusEvidenceNotificationRequest)
        var connected = false
        var calls = 0
        do {
            _ = try await request.reference.resolve(
                identity: { calls += 1; return .init(deviceId: Self.gateway) },
                detail: { _ in detail },
                stillCurrent: { connected })
            Issue.record("Offline read unexpectedly resolved")
        } catch {}
        #expect(calls == 0 && model.argusEvidenceNotificationRequest == request)
        connected = true
        _ = try await request.reference.resolve(
            identity: { .init(deviceId: Self.gateway) }, detail: { _ in detail }, stillCurrent: { connected })
        for retireAtIdentity in [true, false] {
            connected = true
            do {
                _ = try await request.reference.resolve(
                    identity: {
                        if retireAtIdentity {
                            connected = false
                        }; return .init(deviceId: Self.gateway)
                    },
                    detail: { _ in connected = false; return detail },
                    stillCurrent: { connected })
                Issue.record("Retired route unexpectedly resolved")
            } catch {}
        }
        var newer = try #require(self.payload(for: detail)["openclaw"] as? [String: String])
        newer["operationId"] = detail.item.id
        newer["eventId"] = detail.item.eventId
        newer["artifactSha256"] = detail.item.artifacts[0].sha256
        _ = delegate.routeArgusEvidenceNotification(
            actionIdentifier: UNNotificationDefaultActionIdentifier,
            userInfo: ["openclaw": newer])
        #expect(model.argusEvidenceNotificationRequest != request)
    }

    @Test func `foreign gateway or unrelated event and artifact cannot resolve`() async throws {
        let (detail, _) = Self.fixture()
        let reference = try #require(ArgusEvidenceNotificationReference.parse(
            actionIdentifier: UNNotificationDefaultActionIdentifier, userInfo: self.payload(for: detail)))
        var reads = 0
        do {
            _ = try await reference.resolve(
                identity: { .init(deviceId: "foreign-gateway") },
                detail: { _ in reads += 1; return detail },
                stillCurrent: { true })
            Issue.record("Foreign gateway unexpectedly resolved")
        } catch {}
        #expect(reads == 0)
        let foreignItem = ArgusOperation(
            operationId: "another-operation",
            taskId: "another-task",
            eventId: detail.item.eventId,
            title: detail.item.title,
            source: detail.item.source,
            project: detail.item.project,
            kind: detail.item.kind,
            state: detail.item.state,
            occurredAt: detail.item.occurredAt,
            observedAt: detail.item.observedAt,
            artifacts: detail.item.artifacts,
            supersedesEventId: detail.item.supersedesEventId,
            ownerAccepted: false)
        let foreignCurrent = ArgusOperationDetail(
            item: foreignItem,
            requested: detail.requested,
            timeline: detail.timeline,
            coverage: detail.coverage,
            ownerAccepted: false)
        do {
            _ = try await reference.resolve(
                identity: { .init(deviceId: Self.gateway) },
                detail: { _ in foreignCurrent },
                stillCurrent: { true })
            Issue.record("Another task's current view unexpectedly resolved")
        } catch {}
        for wrong in [
            ArgusEvidenceNotificationReference(
                gatewayDeviceId: Self.gateway,
                operationId: "foreign-operation",
                eventId: reference.eventId,
                artifactSha256: reference.artifactSha256),
            .init(
                gatewayDeviceId: Self.gateway,
                operationId: reference.operationId,
                eventId: "foreign-event",
                artifactSha256: reference.artifactSha256),
            .init(
                gatewayDeviceId: Self.gateway,
                operationId: reference.operationId,
                eventId: reference.eventId,
                artifactSha256: String(repeating: "c", count: 64)),
        ] {
            do {
                _ = try await wrong.resolve(
                    identity: { .init(deviceId: Self.gateway) },
                    detail: { _ in detail },
                    stillCurrent: { true })
                Issue.record("Unrelated notification unexpectedly resolved")
            } catch {}
        }
    }

    @Test func `ordinary canonical history keeps one operation identity`() async throws {
        let (federation, _) = Self.fixture()
        func canonical(_ id: String, event: String) -> ArgusOperation {
            var item = ArgusOperation(
                operationId: id,
                taskId: "fixture-task",
                eventId: event,
                title: "Synthetic canonical observation",
                source: "canonical:codex-completion-adapter",
                project: "Argus",
                kind: "evidence",
                state: "observed",
                occurredAt: federation.requested.occurredAt,
                observedAt: federation.requested.observedAt,
                artifacts: [],
                supersedesEventId: nil,
                ownerAccepted: false)
            item.evidenceScope = "admitted_canonical_technical_operation"
            return item
        }
        let requested = canonical("fixture-canonical-operation", event: "fixture-canonical-requested")
        let reference = ArgusEvidenceNotificationReference(
            gatewayDeviceId: Self.gateway,
            operationId: requested.id,
            eventId: requested.eventId,
            artifactSha256: nil)
        for valid in [true, false] {
            let detail = ArgusOperationDetail(
                item: canonical(valid ? requested.id : "unrelated-operation", event: "fixture-current"),
                requested: requested,
                timeline: [requested],
                coverage: federation.coverage,
                ownerAccepted: false)
            do {
                _ = try await reference.resolve(
                    identity: { .init(deviceId: Self.gateway) },
                    detail: { _ in detail },
                    stillCurrent: { true })
                #expect(valid)
            } catch {
                #expect(!valid)
            }
        }
    }

    @Test func `parser admits only bounded exact evidence references and default taps`() throws {
        let (detail, _) = Self.fixture()
        let original = try #require(self.payload(for: detail)["openclaw"] as? [String: String])
        for (key, value) in [
            ("gatewayDeviceId", " foreign "), ("gatewayDeviceId", String(repeating: "g", count: 129)),
            ("operationId", String(repeating: "o", count: 301)), ("eventId", "line\nbreak"),
            ("artifactSha256", String(repeating: "A", count: 64)),
            ("artifactSha256", detail.requested.artifacts[0].sha256 + "\n"),
            ("url", "https://example.invalid/"), ("kind", "push.test"),
        ] {
            var invalid = original
            invalid[key] = value
            #expect(ArgusEvidenceNotificationReference.parse(
                actionIdentifier: UNNotificationDefaultActionIdentifier,
                userInfo: ["openclaw": invalid]) == nil)
        }
        #expect(ArgusEvidenceNotificationReference.parse(
            actionIdentifier: UNNotificationDismissActionIdentifier,
            userInfo: self.payload(for: detail)) == nil)
        var withoutArtifact = original
        withoutArtifact.removeValue(forKey: "artifactSha256")
        #expect(ArgusEvidenceNotificationReference.parse(
            actionIdentifier: UNNotificationDefaultActionIdentifier,
            userInfo: ["openclaw": withoutArtifact])?
            .artifactSha256 == nil)
    }
}
