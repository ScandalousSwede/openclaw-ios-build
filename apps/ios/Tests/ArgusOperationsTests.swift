import CryptoKit
import Foundation
import Testing
@testable import OpenClaw

@MainActor
struct ArgusOperationsTests {
    private func page(id: String = "external-unfamiliar-47", cursor: String? = nil, state: String = "observed", source: String = "federation:external-test", scope: String? = nil) throws -> ArgusOperationsPage {
        let payload: [String: Any] = [
            "items": [[
                "operation_id": id, "task_id": "technical-result-47", "event_id": "event-47",
                "title": "Synthetic external result", "source": source, "evidence_scope": scope as Any? ?? NSNull(),
                "project": "Argus", "kind": "evidence", "state": state,
                "occurred_at": "2026-09-06T00:00:00Z", "observed_at": "2026-09-06T00:01:00Z",
                "artifacts": [], "owner_accepted": false,
            ]],
            "coverage": ["complete": cursor == nil, "has_more": cursor != nil,
                         "observed_at": "2026-09-06T00:01:00Z"],
            "next_cursor": cursor as Any? ?? NSNull(), "automatic_dispatch_enabled": false,
        ]
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(ArgusOperationsPage.self, from: JSONSerialization.data(withJSONObject: payload))
    }

    @Test func pagingDeduplicatesAndOfflinePreservesOnlySameGatewayEvidence() throws {
        let store = ArgusOperationsStore()
        store.selectGateway("gateway-a")
        try store.accept(self.page(cursor: "next-page"), more: false)
        try store.accept(self.page(), more: true)
        #expect(store.items.count == 1)
        #expect(store.nextCursor == nil)
        #expect(!store.unavailable)
        store.markUnavailable()
        #expect(store.unavailable)
        #expect(store.items.count == 1)
        store.selectGateway("gateway-b")
        #expect(store.items.isEmpty)
        #expect(store.coverage == nil)
    }

    @Test func malformedContinuationCannotReplaceObservedSnapshot() throws {
        let store = ArgusOperationsStore()
        let valid = try self.page()
        try store.accept(valid, more: false)
        let malformed = ArgusOperationsPage(
            items: [], coverage: valid.coverage, nextCursor: "unexpected", automaticDispatchEnabled: false)
        #expect(throws: ArgusOperationsError.self) { try store.accept(malformed, more: false) }
        #expect(store.items.count == 1)
    }

    @Test func artifactMustMatchRequestedIdentityDigestAndBytes() throws {
        let data = Data("synthetic technical result".utf8)
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let reference = ArgusOperation.Artifact(sha256: hash, bytes: data.count)
        let response = ArgusOperationArtifact(
            sha256: hash, bytes: data.count, mimeType: "text/plain",
            contentBase64: data.base64EncodedString(), operationId: "operation-47")
        #expect(try response.validatedData(for: "operation-47", artifact: reference) == data)
        #expect(throws: ArgusOperationsError.self) {
            try response.validatedData(for: "another-operation", artifact: reference)
        }
        let tampered = ArgusOperationArtifact(
            sha256: hash, bytes: data.count, mimeType: "text/plain",
            contentBase64: Data(repeating: 0, count: data.count).base64EncodedString(), operationId: "operation-47")
        #expect(throws: ArgusOperationsError.self) {
            try tampered.validatedData(for: "operation-47", artifact: reference)
        }
    }

    @Test func activeMarkupIsNeverAnArtifactPreviewType() {
        let response = ArgusOperationArtifact(
            sha256: String(repeating: "a", count: 64), bytes: 0, mimeType: "text/html",
            contentBase64: "", operationId: "operation-47")
        #expect(throws: ArgusOperationsError.self) {
            try response.validatedData(
                for: "operation-47", artifact: .init(sha256: response.sha256, bytes: 0))
        }
    }
    @Test func mixedCanonicalAndFederationPageAcceptsActualLifecycle() throws {
        let store = ArgusOperationsStore()
        let external = try self.page()
        let canonical = try self.page(id: "ordinary-97", state: "verified",
            source: "canonical:codex-completion-adapter", scope: "admitted_canonical_technical_operation")
        try store.accept(ArgusOperationsPage(items: external.items + canonical.items,
            coverage: external.coverage, nextCursor: nil, automaticDispatchEnabled: false), more: false)
        #expect(store.items.map(\.state) == ["observed", "verified"])
        for state in ["running", "failed", "retry_scheduled", "artifact_produced", "disposed"] {
            let value = try self.page(state: state, source: "canonical:codex-completion-adapter",
                scope: "admitted_canonical_technical_operation")
            try store.accept(value, more: false)
            #expect(store.items.first?.state == state)
        }
    }

    @Test func invalidCanonicalScopeOrStateCannotReplaceSnapshot() throws {
        let store = ArgusOperationsStore()
        try store.accept(self.page(), more: false)
        for invalid in [
            try self.page(state: "verified"),
            try self.page(state: "verified", source: "canonical:codex-completion-adapter"),
            try self.page(state: "invented", source: "canonical:codex-completion-adapter",
                scope: "admitted_canonical_technical_operation"),
        ] {
            #expect(throws: ArgusOperationsError.self) { try store.accept(invalid, more: false) }
            #expect(store.items.first?.state == "observed")
        }
    }

    @Test func canonicalDetailAllowsRepeatedOperationWithDistinctTimelineEvents() throws {
        let item = try self.page(state: "verified", source: "canonical:codex-completion-adapter",
            scope: "admitted_canonical_technical_operation").items[0]
        let detail = ArgusOperationDetail(item: item, requested: item, timeline: [item],
            coverage: .init(complete: true, hasMore: false, observedAt: nil), ownerAccepted: false)
        try detail.validate(for: item)
        let foreign = try self.page(id: "foreign-operation").items[0]
        #expect(throws: ArgusOperationsError.self) { try detail.validate(for: foreign) }
    }

    @Test func suspendedRefreshCannotOverwriteNewObservationScope() async throws {
        let store = ArgusOperationsStore()
        store.selectGateway("gateway-a")
        let old = try self.page(id: "old")
        let fresh = try self.page(id: "fresh")
        var pending: CheckedContinuation<ArgusOperationsPage, Never>?
        let first = Task { @MainActor in
            await store.refresh(gatewayID: "gateway-a") { _ in
                await withCheckedContinuation { pending = $0 }
            }
        }
        while pending == nil { await Task.yield() }
        store.markUnavailable() // background/disconnect invalidates the active observation
        await store.refresh(gatewayID: "gateway-a") { _ in fresh }
        pending?.resume(returning: old)
        await first.value
        #expect(store.items.map(\.id) == ["fresh"])
        #expect(!store.isLoading)
        #expect(!store.unavailable)
    }

    @Test func cancelledRefreshCannotPublishLateResponse() async throws {
        let store = ArgusOperationsStore()
        store.selectGateway("gateway-a")
        let page = try self.page()
        var pending: CheckedContinuation<ArgusOperationsPage, Never>?
        let task = Task { @MainActor in
            await store.refresh(gatewayID: "gateway-a") { _ in
                await withCheckedContinuation { pending = $0 }
            }
        }
        while pending == nil { await Task.yield() }
        task.cancel()
        pending?.resume(returning: page)
        await task.value
        #expect(store.items.isEmpty)
        #expect(!store.isLoading)
    }

}
