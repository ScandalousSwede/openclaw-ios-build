import CryptoKit
import Foundation
import Testing
@testable import OpenClaw

@MainActor
struct ArgusOperationsTests {
    private func page(
        id: String = "external-unfamiliar-47",
        cursor: String? = nil,
        state: String = "observed",
        source: String = "federation:external-test",
        scope: String? = nil,
        project: String = "Argus",
        supersedes: String? = nil,
        artifacts: [[String: Any]] = []) throws -> ArgusOperationsPage
    {
        let payload: [String: Any] = [
            "items": [[
                "operation_id": id, "task_id": "technical-result-47", "event_id": "event-47",
                "title": "Synthetic external result", "source": source, "evidence_scope": scope as Any? ?? NSNull(),
                "project": project, "kind": "evidence", "state": state,
                "occurred_at": "2026-09-06T00:00:00Z", "observed_at": "2026-09-06T00:01:00Z",
                "artifacts": artifacts, "owner_accepted": false,
                "supersedes_event_id": supersedes as Any? ?? NSNull(),
            ]],
            "coverage": [
                "complete": cursor == nil,
                "has_more": cursor != nil,
                "observed_at": "2026-09-06T00:01:00Z",
            ],
            "next_cursor": cursor as Any? ?? NSNull(), "automatic_dispatch_enabled": false,
        ]
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(ArgusOperationsPage.self, from: JSONSerialization.data(withJSONObject: payload))
    }

    @Test func `presentation preserves failed correction and admitted heading without changing identity`() throws {
        var item = try #require(self.page(
            state: "failed",
            source: "canonical:codex-completion-adapter",
            scope: "admitted_canonical_technical_operation",
            supersedes: "previous-event")
            .items.first)
        #expect(item.isAdmitted)
        #expect(item.stateLabel == "Correction observed · Failed")
        #expect(item.heading == item.title)
        let event = item.eventId
        item.display = .init(
            label: "Collector retry repaired",
            changeSummary: "Disabled features remain disabled.",
            artifactLabel: nil,
            continuationLabel: nil)
        #expect(item.heading == "Collector retry repaired")
        #expect(item.state == "failed" && item.eventId == event && item.isAdmitted)
    }

    @Test func `observation times format ISO instants and preserve unrecognized evidence`() {
        let instant = Date(timeIntervalSince1970: 1_788_825_600)
        let iso = ISO8601DateFormatter().string(from: instant)
        #expect(ArgusOperation.observationLabel(iso) == instant.formatted(date: .abbreviated, time: .shortened))
        #expect(ArgusOperation.observationLabel(iso.replacingOccurrences(of: "Z", with: ".123Z"))
            == instant.formatted(date: .abbreviated, time: .shortened))
        #expect(ArgusOperation.observationLabel("source timestamp unavailable") == "source timestamp unavailable")
    }

    @Test func `paging deduplicates and offline preserves only same gateway evidence`() throws {
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

    @Test func `malformed continuation cannot replace observed snapshot`() throws {
        let store = ArgusOperationsStore()
        let valid = try self.page()
        try store.accept(valid, more: false)
        let malformed = ArgusOperationsPage(
            items: [], coverage: valid.coverage, nextCursor: "unexpected", automaticDispatchEnabled: false)
        #expect(throws: ArgusOperationsError.self) { try store.accept(malformed, more: false) }
        #expect(store.items.count == 1)
    }

    @Test func `artifact must match requested identity digest and bytes`() throws {
        let data = Data("synthetic technical result".utf8)
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let reference = ArgusOperation.Artifact(sha256: hash, bytes: data.count, displayName: "result.txt")
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

    private func artifactReference(name: Any? = nil, bytes: Any = 4) throws -> ArgusOperation.Artifact {
        var payload: [String: Any] = ["sha256": String(repeating: "a", count: 64), "bytes": bytes]
        if let name {
            payload["display_name"] = name
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(ArgusOperation.Artifact.self, from: JSONSerialization.data(withJSONObject: payload))
    }

    @Test func `artifact names decode additively and label corresponding artifact`() throws {
        let named = try self.artifactReference(name: "result.pdf")
        let other = try self.artifactReference(name: "checks.json")
        let legacy = try self.artifactReference()
        #expect(named.buttonLabel(operationLabel: "Run output") == "result.pdf")
        #expect(other.buttonLabel(operationLabel: "Run output") == "checks.json")
        #expect(legacy.buttonLabel(operationLabel: "Run output") == "Run output")
        #expect(legacy.buttonLabel(operationLabel: nil) == "Artifact aaaaaaaaaaaa")
        #expect(try self.artifactReference(name: NSNull()).displayName == nil)
        #expect(named.id == legacy.id && named.bytes == legacy.bytes)
        #expect(try self.artifactReference(bytes: NSNull()).bytes == nil)
    }

    @Test func `artifact names reject paths controls bidi and oversize scalars`() throws {
        let invalid = [
            "",
            " ",
            "\u{FEFF}",
            "\u{00A0}\u{3000}",
            ".",
            "..",
            "a/b",
            "a\\b",
            "\u{0000}",
            "\u{001F}",
            "\u{007F}",
            "\u{009F}",
            "\u{061C}",
            "\u{200E}",
            "\u{200F}",
            "\u{202A}",
            "\u{202E}",
            "\u{2066}",
            "\u{2069}",
            String(repeating: "😀", count: 161),
        ]
        for value in invalid {
            #expect(throws: DecodingError.self) { try self.artifactReference(name: value) }
        }
        #expect(throws: DecodingError.self) { try self.artifactReference(name: 3) }
        #expect(try self.artifactReference(name: String(repeating: "😀", count: 160)).displayName != nil)
        #expect(try self.artifactReference(name: "résultat 技術.txt").displayName == "résultat 技術.txt")
        #expect(try self.artifactReference(name: "a\u{FEFF}.txt").displayName != nil)
    }

    @Test func `null artifact size decodes whole page and renders unknown`() throws {
        let page = try self.page(artifacts: [[
            "sha256": String(repeating: "a", count: 64), "bytes": NSNull(), "display_name": "before.json",
        ]])
        let store = ArgusOperationsStore()
        try store.accept(page, more: false)
        let reference = try #require(store.items.first?.artifacts.first)
        #expect(reference.bytes == nil)
        #expect(reference.byteCountLabel == "Size unknown")
        #expect(reference.buttonLabel(operationLabel: nil) == "before.json")
        #expect(try self.artifactReference(bytes: 0).byteCountLabel == "0 bytes")
        #expect(try self.artifactReference(bytes: 2654).byteCountLabel == "2654 bytes")
        #expect(throws: DecodingError.self) { try self.artifactReference(bytes: "unknown") }
    }

    @Test func `unknown reference size still requires actual bytes digest and event`() throws {
        let data = Data("original historical technical bytes".utf8)
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let reference = ArgusOperation.Artifact(sha256: hash, bytes: nil, displayName: "before.txt")
        func response(
            bytes: Int,
            body: Data,
            digest: String? = nil,
            mime: String = "text/plain",
            event: String = "historical-event") -> ArgusOperationArtifact
        {
            ArgusOperationArtifact(
                sha256: digest ?? hash,
                bytes: bytes,
                mimeType: mime,
                contentBase64: body.base64EncodedString(),
                operationId: "historical-operation",
                eventId: event)
        }
        let valid = response(bytes: data.count, body: data)
        #expect(try valid.validatedData(
            for: "historical-operation",
            eventID: "historical-event",
            artifact: reference) == data)
        for invalid in [
            response(bytes: data.count + 1, body: data),
            response(bytes: data.count, body: Data(repeating: 0, count: data.count)),
            response(bytes: data.count, body: data, digest: String(repeating: "f", count: 64)),
            response(bytes: 1_048_577, body: data),
            response(bytes: data.count, body: data, mime: "text/html"),
            response(bytes: data.count, body: data, event: "current-event"),
        ] {
            #expect(throws: ArgusOperationsError.self) {
                try invalid.validatedData(for: "historical-operation", eventID: "historical-event", artifact: reference)
            }
        }
        let wrongKnownSize = ArgusOperation.Artifact(sha256: hash, bytes: data.count + 1)
        #expect(throws: ArgusOperationsError.self) {
            try valid.validatedData(for: "historical-operation", eventID: "historical-event", artifact: wrongKnownSize)
        }
    }

    @Test func `unknown reference size opens through event bound loader`() async throws {
        let (item, known, response) = try self.historicalArtifactFixture()
        let reference = ArgusOperation.Artifact(sha256: known.sha256, bytes: nil, displayName: "prior.txt")
        let store = ArgusArtifactOpenStore()
        store.setAvailable(true)
        await store.open(reference, item: item) { params in
            #expect(params["event_id"] == item.eventId)
            return response
        }
        #expect(store.preview?.data == Data("historical technical result".utf8))
        #expect(store.error == nil)
    }

    @Test func `canonical UTF 8 text wire normalizes only allowed preview MIME`() async throws {
        let (item, artifact, original) = try self.historicalArtifactFixture()
        let payload: [String: Any] = [
            "operation_id": item.id, "event_id": item.eventId, "sha256": artifact.sha256,
            "bytes": original.bytes, "mime_type": "text/plain; charset=utf-8",
            "content_base64": original.contentBase64,
        ]
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let response = try decoder.decode(
            ArgusOperationArtifact.self,
            from: JSONSerialization.data(withJSONObject: payload))
        let store = ArgusArtifactOpenStore()
        store.setAvailable(true)
        await store.open(artifact, item: item) { _ in response }
        #expect(store.preview?.mimeType == "text/plain")
        #expect(store.preview.flatMap { String(data: $0.data, encoding: .utf8) } == "historical technical result")
        #expect(store.error == nil)
        let invalidUTF8 = Data([0xFF])
        let invalidHash = SHA256.hash(data: invalidUTF8).map { String(format: "%02x", $0) }.joined()
        var malformed = payload
        malformed["content_base64"] = invalidUTF8.base64EncodedString()
        malformed["bytes"] = 1
        malformed["sha256"] = invalidHash
        let badText = try decoder.decode(
            ArgusOperationArtifact.self,
            from: JSONSerialization.data(withJSONObject: malformed))
        #expect(throws: ArgusOperationsError.self) {
            try badText.validatedData(
                for: item.id,
                eventID: item.eventId,
                artifact: .init(sha256: invalidHash, bytes: nil))
        }
        for mime in [
            "text/plain; charset=iso-8859-1",
            "text/html; charset=utf-8",
            "text/plain; charset=utf-8; extra=1",
        ] {
            var invalid = payload
            invalid["mime_type"] = mime
            let rejected = try decoder.decode(
                ArgusOperationArtifact.self,
                from: JSONSerialization.data(withJSONObject: invalid))
            #expect(rejected.previewMimeType == nil)
            #expect(throws: ArgusOperationsError.self) {
                try rejected.validatedData(for: item.id, eventID: item.eventId, artifact: artifact)
            }
        }
    }

    @Test func `active markup is never an artifact preview type`() {
        let response = ArgusOperationArtifact(
            sha256: String(repeating: "a", count: 64), bytes: 0, mimeType: "text/html",
            contentBase64: "", operationId: "operation-47")
        #expect(throws: ArgusOperationsError.self) {
            try response.validatedData(
                for: "operation-47", artifact: .init(sha256: response.sha256, bytes: 0))
        }
    }

    @Test func `mixed canonical and federation page accepts actual lifecycle`() throws {
        let store = ArgusOperationsStore()
        let external = try self.page()
        let canonical = try self.page(
            id: "ordinary-97",
            state: "verified",
            source: "canonical:codex-completion-adapter",
            scope: "admitted_canonical_technical_operation")
        try store.accept(ArgusOperationsPage(
            items: external.items + canonical.items,
            coverage: external.coverage,
            nextCursor: nil,
            automaticDispatchEnabled: false), more: false)
        #expect(store.items.map(\.state) == ["observed", "verified"])
        for state in ["running", "failed", "retry_scheduled", "artifact_produced", "disposed"] {
            let value = try self.page(
                state: state,
                source: "canonical:codex-completion-adapter",
                scope: "admitted_canonical_technical_operation")
            try store.accept(value, more: false)
            #expect(store.items.first?.state == state)
        }
    }

    @Test func `invalid canonical scope or state cannot replace snapshot`() throws {
        let store = ArgusOperationsStore()
        try store.accept(self.page(), more: false)
        for invalid in try [
            self.page(state: "verified"),
            self.page(state: "verified", source: "canonical:codex-completion-adapter"),
            self.page(
                state: "invented",
                source: "canonical:codex-completion-adapter",
                scope: "admitted_canonical_technical_operation"),
        ] {
            #expect(throws: ArgusOperationsError.self) { try store.accept(invalid, more: false) }
            #expect(store.items.first?.state == "observed")
        }
    }

    @Test func `canonical detail allows repeated operation with distinct timeline events`() throws {
        let item = try self.page(
            state: "verified",
            source: "canonical:codex-completion-adapter",
            scope: "admitted_canonical_technical_operation").items[0]
        let detail = ArgusOperationDetail(
            item: item,
            requested: item,
            timeline: [item],
            coverage: .init(complete: true, hasMore: false, observedAt: nil),
            ownerAccepted: false)
        try detail.validate(for: item)
        let foreign = try self.page(id: "foreign-operation").items[0]
        #expect(throws: ArgusOperationsError.self) { try detail.validate(for: foreign) }
    }

    @Test func `suspended refresh cannot overwrite new observation scope`() async throws {
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
        while pending == nil {
            await Task.yield()
        }
        store.markUnavailable() // background/disconnect invalidates the active observation
        await store.refresh(gatewayID: "gateway-a") { _ in fresh }
        pending?.resume(returning: old)
        await first.value
        #expect(store.items.map(\.id) == ["fresh"])
        #expect(!store.isLoading)
        #expect(!store.unavailable)
    }

    @Test func `cancelled refresh cannot publish late response`() async throws {
        let store = ArgusOperationsStore()
        store.selectGateway("gateway-a")
        let page = try self.page()
        var pending: CheckedContinuation<ArgusOperationsPage, Never>?
        let task = Task { @MainActor in
            await store.refresh(gatewayID: "gateway-a") { _ in
                await withCheckedContinuation { pending = $0 }
            }
        }
        while pending == nil {
            await Task.yield()
        }
        task.cancel()
        pending?.resume(returning: page)
        await task.value
        #expect(store.items.isEmpty)
        #expect(!store.isLoading)
    }

    private func historicalArtifactFixture() throws
    -> (ArgusOperation, ArgusOperation.Artifact, ArgusOperationArtifact) {
        let item = try self.page().items[0]
        let data = Data("historical technical result".utf8)
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let artifact = ArgusOperation.Artifact(sha256: hash, bytes: data.count, displayName: "prior.txt")
        let response = ArgusOperationArtifact(
            sha256: hash,
            bytes: data.count,
            mimeType: "text/plain",
            contentBase64: data.base64EncodedString(),
            operationId: item.id,
            eventId: item.eventId)
        return (item, artifact, response)
    }

    @Test func `historical artifact request and response bind exact event`() async throws {
        let (item, artifact, response) = try self.historicalArtifactFixture()
        let store = ArgusArtifactOpenStore()
        store.setAvailable(true)
        await store.open(artifact, item: item) { params in
            #expect(params == ["operation_id": item.id, "event_id": item.eventId, "sha256": artifact.sha256])
            return response
        }
        #expect(store.preview?.data == Data("historical technical result".utf8))
        var wrong = response
        wrong.eventId = "newer-event"
        await store.open(artifact, item: item) { _ in wrong }
        #expect(store.preview == nil && store.error != nil)
        wrong.eventId = nil
        await store.open(artifact, item: item) { _ in wrong }
        #expect(store.preview == nil && store.error != nil)
    }

    @Test func `delayed artifact cannot reappear after scope loss and return`() async throws {
        let (item, artifact, response) = try self.historicalArtifactFixture()
        // Same state transition covers disconnect, gateway-away/back and dismissed/reopened detail.
        let store = ArgusArtifactOpenStore()
        store.setAvailable(true)
        var pending: CheckedContinuation<ArgusOperationArtifact, Never>?
        let task = Task { @MainActor in
            await store.open(artifact, item: item) { _ in
                await withCheckedContinuation { pending = $0 }
            }
        }
        while pending == nil {
            await Task.yield()
        }
        store.setAvailable(false)
        var unavailableFetchCalled = false
        await store.open(artifact, item: item) { _ in unavailableFetchCalled = true; return response }
        #expect(!unavailableFetchCalled)
        store.setAvailable(true)
        pending?.resume(returning: response)
        await task.value
        #expect(store.preview == nil && !store.isLoading && store.error == nil)
        await store.open(artifact, item: item) { _ in response }
        #expect(store.preview?.data == Data("historical technical result".utf8))
    }

    @Test func `cancelled artifact open cannot publish preview`() async throws {
        let (item, artifact, response) = try self.historicalArtifactFixture()
        let store = ArgusArtifactOpenStore()
        store.setAvailable(true)
        var pending: CheckedContinuation<ArgusOperationArtifact, Never>?
        let task = Task { @MainActor in
            await store.open(artifact, item: item) { _ in await withCheckedContinuation { pending = $0 } }
        }
        while pending == nil {
            await Task.yield()
        }
        task.cancel()
        pending?.resume(returning: response)
        await task.value
        #expect(store.preview == nil && !store.isLoading && store.error == nil)
    }

    @Test func `selected historical detail survives bounded timeline without duplicate events`() throws {
        let (base, artifact, _) = try self.historicalArtifactFixture()
        let old = ArgusOperation(
            operationId: base.id,
            taskId: base.taskId,
            eventId: base.eventId,
            title: base.title,
            source: base.source,
            project: base.project,
            kind: base.kind,
            state: base.state,
            occurredAt: base.occurredAt,
            observedAt: base.observedAt,
            artifacts: [artifact],
            supersedesEventId: nil,
            ownerAccepted: false)
        let newer = ArgusOperation(
            operationId: old.id,
            taskId: old.taskId,
            eventId: "newer-event",
            title: old.title,
            source: old.source,
            project: old.project,
            kind: old.kind,
            state: old.state,
            occurredAt: old.occurredAt,
            observedAt: old.observedAt,
            artifacts: [],
            supersedesEventId: nil,
            ownerAccepted: false)
        let detail = ArgusOperationDetail(
            item: newer,
            requested: old,
            timeline: [newer, newer],
            coverage: .init(complete: false, hasMore: true, observedAt: nil),
            ownerAccepted: false)
        try detail.validate(for: old)
        #expect(detail.displayTimeline.map(\.eventId) == ["newer-event", old.eventId])
        #expect(detail.displayTimeline.last?.artifacts.first?.sha256 == artifact.sha256)
        #expect(ArgusOperationDetail.requestParameters(for: old)["event_id"] == old.eventId)
        #expect(throws: ArgusOperationsError.self) { try detail.validate(for: newer) }
    }

    static func reviewHistoryFixture() throws -> (ArgusOperation, [String: Any]) {
        let (item, _) = try ArgusWorkContractTests.fixture(relation: "previous_attempt")
        let rows: [[String: Any]] = ["pending", "accepted", "rejected"].enumerated().map { index, state in
            [
                "id": "review-\(index)",
                "request_event_id": "request-\(index)",
                "binding": [
                    "operation_id": item.id,
                    "event_id": "earlier-event-\(index)",
                    "artifact_sha256": [String(repeating: "a", count: 64)],
                ],
                "state": state,
                "binding_relation": "previous",
                "requested_at_ms": 1_800_000_000_000,
                "expires_at_ms": 1_800_001_800_000,
                "disposition": state == "pending" ? NSNull() :
                    ["event_id": "disposition-\(index)", "recorded_at_ms": 1_800_000_060_000],
            ]
        }
        return (item, ["items": rows, "coverage": [
            "complete": true,
            "has_more": false,
            "snapshot_sequence": 42,
        ], "owner_accepted": false])
    }

    static func decodeReviewHistory(_ payload: [String: Any]) throws -> ArgusReviewHistory {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(ArgusReviewHistory.self, from: JSONSerialization.data(withJSONObject: payload))
    }

    @Test func `recorded reviews preserve earlier binding without owner acceptance`() throws {
        let (item, payload) = try Self.reviewHistoryFixture()
        let history = try Self.decodeReviewHistory(payload)
        let detail = ArgusOperationDetail(
            item: item,
            requested: item,
            timeline: [item],
            coverage: .init(complete: true, hasMore: false, observedAt: nil),
            ownerAccepted: false,
            reviewHistory: history)
        try detail.validate(for: item)
        #expect(history.items.map(\.title) == [
            "Review requested",
            "Operator accepted this artifact",
            "Operator rejected this artifact",
        ])
        #expect(history.items.allSatisfy { $0.bindingRelation == .previous })
        #expect(history.items[0].disposition == nil)
        #expect(!detail.ownerAccepted)
        #expect(detail.workContract == nil)
    }

    @Test func `malformed review state binding and receipt cannot be presented`() throws {
        let (item, payload) = try Self.reviewHistoryFixture()
        let original = try #require(payload["items"] as? [[String: Any]])
        let cases: [(String, Any)] = [
            ("state", "open"),
            ("state", "accepted"),
            ("binding_relation", "current"),
            ("id", "bad\nid"),
            ("expires_at_ms", -1),
        ]
        for (key, value) in cases {
            var rows = original
            rows[0][key] = value
            var bad = payload
            bad["items"] = rows
            #expect(throws: (any Error).self) {
                let result = try Self.decodeReviewHistory(bad)
                try result.validate(for: item)
            }
        }
        var rows = original
        rows[0]["binding"] = [
            "operation_id": "foreign-operation",
            "event_id": "event",
            "artifact_sha256": [String(repeating: "a", count: 64)],
        ]
        var bad = payload
        bad["items"] = rows
        #expect(throws: ArgusOperationsError.self) {
            try Self.decodeReviewHistory(bad).validate(for: item)
        }
    }

    @Test func `duplicate and oversized review history fail closed`() throws {
        let (item, payload) = try Self.reviewHistoryFixture()
        let rows = try #require(payload["items"] as? [[String: Any]])
        for count in [2, 26] {
            var bad = payload
            bad["items"] = (0..<count).map { index in
                var row = rows[0]
                if count > 25 {
                    row["id"] = "unique-review-\(index)"
                    row["request_event_id"] = "unique-request-\(index)"
                }
                return row
            }
            #expect(throws: ArgusOperationsError.self) {
                try Self.decodeReviewHistory(bad).validate(for: item)
            }
        }
    }

    @Test func `detail without optional review history still decodes`() throws {
        let item: [String: Any] = [
            "operation_id": "old-operation",
            "task_id": "old-task",
            "event_id": "old-event",
            "title": "Synthetic older gateway response",
            "source": "canonical:codex-completion-adapter",
            "project": "Argus",
            "kind": "evidence",
            "state": "running",
            "occurred_at": "2026-09-07T00:00:00Z",
            "observed_at": "2026-09-07T00:00:00Z",
            "artifacts": [],
            "owner_accepted": false,
            "evidence_scope": "admitted_canonical_technical_operation",
        ]
        let payload: [String: Any] = [
            "item": item,
            "requested": item,
            "timeline": [item],
            "coverage": ["complete": true, "has_more": false],
            "owner_accepted": false,
        ]
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let detail = try decoder.decode(
            ArgusOperationDetail.self,
            from: JSONSerialization.data(withJSONObject: payload))
        try detail.validate(for: detail.item)
        #expect(detail.reviewHistory == nil)
    }

    @Test func `project selection requests exact scope and resets pagination`() async throws {
        let store = ArgusOperationsStore()
        store.selectGateway("gateway-a")
        #expect(store.project == .argus)
        try store.accept(self.page(cursor: "argus-cursor"), more: false)
        store.selectProject(.miKobots)
        #expect(store.items.isEmpty)
        #expect(store.nextCursor == nil)
        #expect(store.coverage == nil)
        let robotics = try self.page(project: "MiKobots")
        await store.refresh(gatewayID: "gateway-a") { params in
            #expect(params == ["project": "MiKobots"])
            return robotics
        }
        #expect(store.items.first?.project == "MiKobots")
        #expect(throws: ArgusOperationsError.self) { try store.accept(self.page(), more: false) }
        store.selectProject(.epc)
        let epc = try self.page(project: "EPC")
        await store.refresh(gatewayID: "gateway-a") { params in
            #expect(params == ["project": "EPC"])
            return epc
        }
        #expect(store.items.first?.project == "EPC")
        store.selectProject(.argus)
        #expect(store.items.isEmpty)
    }

    @Test func `project switch fences suspended prior project response`() async throws {
        let store = ArgusOperationsStore()
        store.selectGateway("gateway-a")
        let old = try self.page(id: "old-argus")
        let current = try self.page(id: "new-mikobots", project: "MiKobots")
        var pending: CheckedContinuation<ArgusOperationsPage, Never>?
        let first = Task { @MainActor in
            await store.refresh(gatewayID: "gateway-a") { _ in
                await withCheckedContinuation { pending = $0 }
            }
        }
        while pending == nil {
            await Task.yield()
        }
        store.selectProject(.miKobots)
        await store.refresh(gatewayID: "gateway-a") { _ in current }
        pending?.resume(returning: old)
        await first.value
        #expect(store.items.map(\.id) == ["new-mikobots"])
        #expect(!store.isLoading)
        #expect(!store.unavailable)
    }

    @Test func `project detail cannot cross project and canonical scope stays argus`() throws {
        let robotics = try self.page(project: "MiKobots").items[0]
        let argus = try self.page().items[0]
        let valid = ArgusOperationDetail(
            item: robotics,
            requested: robotics,
            timeline: [robotics],
            coverage: .init(complete: true, hasMore: false, observedAt: nil),
            ownerAccepted: false)
        try valid.validate(for: robotics)
        let invalid = ArgusOperationDetail(
            item: argus,
            requested: robotics,
            timeline: [argus],
            coverage: valid.coverage,
            ownerAccepted: false)
        #expect(throws: ArgusOperationsError.self) { try invalid.validate(for: robotics) }
        #expect(try !(self.page(project: "Unknown").items[0]).isAdmitted)
        let canonical = try self.page(
            state: "verified",
            source: "canonical:codex-completion-adapter",
            scope: "admitted_canonical_technical_operation",
            project: "MiKobots").items[0]
        #expect(!canonical.isAdmitted)
    }
}
