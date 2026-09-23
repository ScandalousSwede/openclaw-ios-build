import CryptoKit
import Foundation
import Testing
@testable import OpenClaw

@MainActor
struct ArgusOperationsTests {
    static func currentWorkFixture(
        mutate: (inout [String: Any]) -> Void = { _ in }) throws -> ArgusCurrentWorkPage
    {
        let provenance: [String: Any] = [
            "title_basis": "synthetic_source_display", "summary_basis": "unavailable", "fallback": false,
        ]
        var payload: [String: Any] = [
            "schema": "argus.current-work.v1",
            "items": [
                [
                    "kind": "owner_decision", "responsibility": "owner_choice", "next_actor": "Synthetic owner",
                    "question": "Which project scope should this draft use?", "outcome": "decision_not_recorded",
                    "next_action": "Choose the scope in the existing review.",
                    "review_url": "https://linear.app/argus-egillese/issue/SYNTHETIC-1",
                    "review_id": "synthetic-review", "application_id": "synthetic-application",
                    "revision_id": "synthetic-revision", "map_sha": String(repeating: "a", count: 64),
                    "payload_sha": String(repeating: "b", count: 64),
                    "presentation": ["title": "Synthetic research grant", "provenance": provenance],
                ],
                [
                    "kind": "accepted_work", "responsibility": "agent_action",
                    "next_actor": "existing_engineering_owner", "outcome": "exact_artifact_accepted",
                    "next_action": "Engineering will finish the remaining operational work.",
                    "review_url": "https://linear.app/argus-egillese/issue/SYNTHETIC-2",
                    "operation_id": "synthetic-operation", "event_id": "synthetic-event",
                    "artifact_sha256": String(repeating: "c", count: 64),
                    "decision_id": "synthetic-decision", "receipt_id": "synthetic-receipt",
                    "activation_authorized": false, "programme_complete": false,
                    "presentation": ["title": "Synthetic package recovery; activation remains unapproved", "provenance": provenance],
                ],
            ],
            "coverage": [
                "status": "bounded", "scope": "current_grant_review_and_recorded_exact_artifact_acceptances",
                "observed_at": "2026-09-22T18:16:00Z", "programme_count": NSNull(),
                "programme_complete": false, "returned": 2, "has_more": false,
                "sources": [
                    "grant_review": ["status": "bounded", "scope": "current_grant_review"],
                    "recorded_acceptances": ["status": "bounded", "scope": "recorded_exact_artifact_acceptance_receipts"],
                ],
            ],
            "effects": ["read_only": true, "can_submit": false, "can_approve": false, "can_dispatch": false],
        ]
        mutate(&payload)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(ArgusCurrentWorkPage.self, from: JSONSerialization.data(withJSONObject: payload))
    }

    @Test func currentWorkPreservesRealDecisionKindsAndIdentities() throws {
        let page = try Self.currentWorkFixture()
        try page.validate()
        #expect(page.items[0].operationId == nil)
        #expect(page.items[0].revisionId == "synthetic-revision")
        #expect(page.items[0].responsibility == "owner_choice")
        #expect(page.items[1].responsibility == "agent_action")
        #expect(page.items[1].receiptId == "synthetic-receipt")
        #expect(page.items[1].actorLabel == "Engineering")
        #expect(page.items[1].outcomeLabel == "Document acceptance recorded")
        #expect(!page.coverage.programmeComplete && page.coverage.programmeCount == nil)
    }

    static func recordedChoicesFixture(
        mutate: (inout [String: Any]) -> Void = { _ in }) throws -> ArgusCurrentWorkPage
    {
        try Self.currentWorkFixture { payload in
            var items = payload["items"] as! [[String: Any]]
            items[0]["kind"] = "grant_follow_through"
            items[0]["responsibility"] = "agent_action"
            items[0]["next_actor"] = "grant-draft-owner"
            items[0]["question"] = nil
            items[0]["outcome"] = "recorded_choices_pending_incorporation"
            items[0]["next_action"] = "Incorporate the recorded choices in the next bound draft."
            items[0]["recorded_choices"] = [
                "status": "recorded", "source": "memory/decisions.jsonl",
                "records": [
                    ["decision_id": "synthetic-scope", "recorded_at": "2026-09-23T15:02:17Z",
                     "summary": "Synthetic scope recorded; sharing remains open.", "state": "active",
                     "supersedes": [], "superseded_by": ["synthetic-sharing"],
                     "source_sha256": String(repeating: "d", count: 64)],
                    ["decision_id": "synthetic-sharing", "recorded_at": "2026-09-23T15:03:19Z",
                     "summary": "Synthetic choice: no sharing; closes the earlier open item.", "state": "active",
                     "supersedes": ["synthetic-scope"], "superseded_by": [],
                     "source_sha256": String(repeating: "e", count: 64)],
                ],
            ]
            mutate(&items[0])
            payload["items"] = items
        }
    }

    @Test func recordedGrantChoicesKeepHistoryAndDraftOwnerWithoutApproval() throws {
        let page = try Self.recordedChoicesFixture()
        try page.validate()
        let item = page.items[0]
        let choices = try #require(item.recordedChoices)
        #expect(item.question == nil && item.responsibility == "agent_action")
        #expect(item.actorLabel == "Grant draft owner")
        #expect(item.outcomeLabel == "Choices recorded · draft update next")
        #expect(item.revisionId == "synthetic-revision")
        #expect(choices.records[0].supersededBy == [choices.records[1].decisionId])
        #expect(choices.records[1].supersedes == [choices.records[0].decisionId])
        #expect(!page.effects.canApprove && !page.effects.canSubmit && !page.effects.canDispatch)
    }

    @Test func unavailableRecordedChoicesRequireReconciliationInsteadOfAnotherQuestion() throws {
        let page = try Self.recordedChoicesFixture { item in
            item["outcome"] = "recorded_choices_reconciliation_required"
            item["recorded_choices"] = [
                "status": "unavailable", "source": "memory/decisions.jsonl", "records": [],
            ]
        }
        try page.validate()
        #expect(page.items[0].question == nil)
        #expect(page.items[0].actorLabel == "Grant draft owner")
        #expect(page.items[0].outcomeLabel == "Recorded choices need reconciliation")
    }

    @Test func recordedChoicesRejectMissingHistoryContradictoryAuthorityAndMalformedRecords() throws {
        for change in 0..<16 {
            let page = try Self.recordedChoicesFixture { item in
                var choices = item["recorded_choices"] as! [String: Any]
                var records = choices["records"] as! [[String: Any]]
                switch change {
                case 0: item["recorded_choices"] = nil; return
                case 1: item["next_actor"] = "Synthetic owner"
                case 2: item["question"] = "Please answer the same question again"
                case 3: item["outcome"] = "draft_approved_follow_through"
                case 4: choices["status"] = "unavailable"
                case 5: choices["source"] = "other-source"
                case 6: records[1]["decision_id"] = records[0]["decision_id"]
                case 7: records[0]["source_sha256"] = "invalid"
                case 8: records[0]["summary"] = String(repeating: "x", count: 501)
                case 9: records[0]["supersedes"] = Array(repeating: "id", count: 17)
                case 10: records = [records[0]]
                case 11: records[0]["superseded_by"] = ["missing-decision"]
                case 12: records[0]["supersedes"] = ["synthetic-scope"]
                case 13: records[1]["supersedes"] = []
                case 14:
                    records[0]["supersedes"] = ["synthetic-sharing"]
                    records[1]["superseded_by"] = ["synthetic-scope"]
                default: records[0]["superseded_by"] = ["synthetic-sharing", "synthetic-sharing"]
                }
                choices["records"] = records
                item["recorded_choices"] = choices
            }
            #expect(throws: ArgusOperationsError.self) { try page.validate() }
        }
    }

    @Test func currentWorkRejectsInventedOwnerNeedsAndBroaderEffects() throws {
        for (field, value) in [
            ("responsibility", "owner_choice"), ("outcome", "decision_not_recorded"),
            ("review_url", "https://example.com/foreign"), ("artifact_sha256", "not-a-digest"),
        ] {
            let page = try Self.currentWorkFixture { payload in
                var items = payload["items"] as! [[String: Any]]
                items[1][field] = value
                payload["items"] = items
            }
            #expect(throws: ArgusOperationsError.self) { try page.validate() }
        }
        for effect in ["can_submit", "can_approve", "can_dispatch"] {
            let page = try Self.currentWorkFixture { payload in
                var effects = payload["effects"] as! [String: Any]
                effects[effect] = true
                payload["effects"] = effects
            }
            #expect(throws: ArgusOperationsError.self) { try page.validate() }
        }
        for field in ["activation_authorized", "programme_complete"] {
            for value in [nil, true] as [Bool?] {
                let page = try Self.currentWorkFixture { payload in
                    var items = payload["items"] as! [[String: Any]]
                    if let value {
                        items[1][field] = value
                    } else {
                        items[1].removeValue(forKey: field)
                    }
                    payload["items"] = items
                }
                #expect(throws: ArgusOperationsError.self) { try page.validate() }
            }
        }
        for (index, fields) in [
            (0, ["decision_id", "receipt_id", "operation_id", "event_id", "artifact_sha256", "source"]),
            (1, ["review_id", "application_id", "revision_id", "map_sha", "payload_sha", "source"]),
        ] {
            for field in fields {
                let page = try Self.currentWorkFixture { payload in
                    var items = payload["items"] as! [[String: Any]]
                    items[index][field] = "synthetic-foreign-identity"
                    payload["items"] = items
                }
                #expect(throws: ArgusOperationsError.self) { try page.validate() }
            }
        }
    }

    @Test func grantFollowThroughAndReconciliationNeverBecomeOwnerChoices() throws {
        let page = try Self.currentWorkFixture { payload in
            var items = payload["items"] as! [[String: Any]]
            items[0]["kind"] = "grant_follow_through"
            items[0]["responsibility"] = "agent_action"
            items[0]["question"] = nil
            items[0]["outcome"] = "revision_requested_follow_through"
            items[1] = [
                "kind": "reconciliation_gap", "responsibility": "engineering_reconciliation",
                "next_actor": "existing_engineering_owner", "outcome": "unknown_or_changed",
                "next_action": "Engineering will reconcile the source.", "source": "synthetic-source",
                "presentation": items[1]["presentation"]!,
            ]
            payload["items"] = items
        }
        try page.validate()
        #expect(page.items.allSatisfy { $0.responsibility != "owner_choice" && $0.question == nil })
        #expect(page.items[0].outcomeLabel == "Revision requested")
        #expect(page.items[1].reviewURL == nil)
        let malformed = try Self.currentWorkFixture { payload in
            payload["items"] = [[
                "kind": "reconciliation_gap", "responsibility": "engineering_reconciliation",
                "next_actor": "existing_engineering_owner", "outcome": "unknown_or_changed",
                "next_action": "Reconcile the source.", "event_id": "foreign-event",
                "presentation": ["title": "Synthetic gap", "provenance": [
                    "title_basis": "synthetic", "summary_basis": "unavailable", "fallback": true,
                ]],
            ]]
            var coverage = payload["coverage"] as! [String: Any]
            coverage["returned"] = 1
            payload["coverage"] = coverage
        }
        #expect(throws: ArgusOperationsError.self) { try malformed.validate() }
    }

    @Test func currentWorkUnavailableRetainsOnlySameOwnerAndRejectsLateReturn() async throws {
        let page = try Self.currentWorkFixture()
        let store = ArgusCurrentWorkStore()
        store.selectGateway("owner-a")
        await store.refresh(gatewayID: "owner-a") { page }
        #expect(store.page?.items.count == 2 && !store.unavailable)
        await store.refresh(gatewayID: "owner-a") { throw ArgusOperationsError.unavailable }
        #expect(store.page?.items.count == 2 && store.unavailable)
        await store.refresh(gatewayID: "owner-a") {
            store.selectGateway("owner-b")
            return page
        }
        #expect(store.page == nil && store.unavailable && !store.isLoading)
        await store.refresh(gatewayID: "owner-b") {
            store.markUnavailable()
            return page
        }
        #expect(store.page == nil && store.unavailable)
    }

    @Test func currentWorkPartialCoverageKeepsTheAvailableWorkAndExposesUnknownSourceState() async throws {
        for missing in ["grant_review", "recorded_acceptances"] {
            let page = try Self.currentWorkFixture { payload in
                let items = payload["items"] as! [[String: Any]]
                payload["items"] = [items[missing == "grant_review" ? 1 : 0]]
                var coverage = payload["coverage"] as! [String: Any]
                var sources = coverage["sources"] as! [String: [String: Any]]
                sources[missing]!["status"] = "unavailable"
                coverage["sources"] = sources
                coverage["status"] = "partial"
                coverage["returned"] = 1
                payload["coverage"] = coverage
            }
            let store = ArgusCurrentWorkStore()
            store.selectGateway("synthetic-owner")
            await store.refresh(gatewayID: "synthetic-owner") { page }
            #expect(store.page?.items.count == 1 && !store.unavailable)
            #expect(page.coverage.hasUnavailableSources)
            #expect(page.coverage.sourceStatus.contains { $0.contains("unavailable; state unknown") })
            #expect(page.coverage.sourceStatus.contains { $0.contains("checked within this limited read") })
        }
    }

    @Test func currentWorkAllUnavailableKeepsUnknownCoverage() throws {
        let page = try Self.currentWorkFixture { payload in
            payload["items"] = [[String: Any]]()
            var coverage = payload["coverage"] as! [String: Any]
            var sources = coverage["sources"] as! [String: [String: Any]]
            for name in sources.keys { sources[name]!["status"] = "unavailable" }
            coverage["sources"] = sources
            coverage["status"] = "unavailable"
            coverage["returned"] = 0
            payload["coverage"] = coverage
        }
        try page.validate()
        #expect(page.coverage.hasUnavailableSources)
        #expect(page.coverage.sourceStatus.allSatisfy { $0.contains("state unknown") })
    }

    @Test func currentWorkRejectsContradictoryCoverageWithoutDiscardingThePriorPage() async throws {
        let store = ArgusCurrentWorkStore()
        store.selectGateway("synthetic-owner")
        let valid = try Self.currentWorkFixture()
        await store.refresh(gatewayID: "synthetic-owner") { valid }
        for defect in ["missing-source", "wrong-scope", "wrong-status", "overall-status", "unavailable-row"] {
            let page = try Self.currentWorkFixture { payload in
                var coverage = payload["coverage"] as! [String: Any]
                var sources = coverage["sources"] as! [String: [String: Any]]
                switch defect {
                case "missing-source": sources.removeValue(forKey: "recorded_acceptances")
                case "wrong-scope": sources["recorded_acceptances"]!["scope"] = "current_grant_review"
                case "wrong-status": sources["recorded_acceptances"]!["status"] = "failed"
                case "overall-status": coverage["status"] = "partial"
                default:
                    sources["recorded_acceptances"]!["status"] = "unavailable"
                    coverage["status"] = "partial"
                }
                coverage["sources"] = sources
                payload["coverage"] = coverage
            }
            await store.refresh(gatewayID: "synthetic-owner") { page }
            #expect(store.unavailable && store.page?.items.count == 2)
            #expect(store.page?.coverage.status == "bounded")
        }
    }

    @Test func currentWorkKeepsGrantDraftOwnerAndRejectsChangedFixedActor() throws {
        let page = try Self.currentWorkFixture { payload in
            var items = payload["items"] as! [[String: Any]]
            items[0]["kind"] = "grant_follow_through"
            items[0]["responsibility"] = "agent_action"
            items[0]["next_actor"] = "grant-draft-owner"
            items[0]["question"] = nil
            items[0]["outcome"] = "revision_requested_follow_through"
            payload["items"] = items
        }
        try page.validate()
        #expect(page.items[0].actorLabel == "Grant draft owner")
        let malformed = try Self.currentWorkFixture { payload in
            var items = payload["items"] as! [[String: Any]]
            items[1]["next_actor"] = "Synthetic owner"
            payload["items"] = items
        }
        #expect(throws: ArgusOperationsError.self) { try malformed.validate() }
    }

    @Test func emptyCurrentWorkKeepsBoundedCoverageAndUnknownProgrammeCount() async throws {
        let page = try Self.currentWorkFixture { payload in
            payload["items"] = [[String: Any]]()
            var coverage = payload["coverage"] as! [String: Any]
            coverage["returned"] = 0
            payload["coverage"] = coverage
        }
        let store = ArgusCurrentWorkStore()
        store.selectGateway("owner")
        await store.refresh(gatewayID: "owner") { page }
        #expect(store.page?.items.isEmpty == true && !store.unavailable)
        #expect(store.page?.coverage.programmeCount == nil)
        #expect(store.page?.coverage.programmeComplete == false)
    }

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
        #expect(item.recordLabel == "Correction recorded · Recorded update")
        #expect(item.supersedesEventId == "previous-event")
        #expect(item.heading == item.title)
        let event = item.eventId
        item.display = .init(
            label: "Collector retry repaired",
            changeSummary: "Disabled features remain disabled.",
            artifactLabel: nil,
            continuationLabel: nil)
        #expect(item.heading == "Collector retry repaired")
        #expect(item.recordSummary == "Disabled features remain disabled.")
        #expect(item.state == "failed" && item.eventId == event && item.isAdmitted)
    }

    @Test func `reports explain available actions without claiming live task state or owner approval`() throws {
        for state in ["artifact_produced", "blocked", "delivered", "verified"] {
            var item = try #require(self.page(
                state: state, source: "canonical:codex-completion-adapter",
                scope: "admitted_canonical_technical_operation",
                artifacts: [["sha256": String(repeating: "a", count: 64), "bytes": 12]])
                .items.first)
            #expect(item.recordLabel == "Report with documents")
            #expect(item.detailActionLabel == "Open report")
            #expect(item.recordSummary == "Open this report to read its attached documents and recorded outcome.")
            #expect(item.state == state && !item.ownerAccepted)
            #expect(item.occurredAt != item.observedAt)
            item.artifactContext = .init(
                relation: "previous_attempt", currentAttemptId: "new", artifactAttemptId: "old")
            #expect(item.recordSummary == "Documents from an earlier attempt are available in this report.")
            #expect(item.detailActionLabel == "Open report")
        }
        let update = try #require(self.page().items.first)
        #expect(update.detailActionLabel == "View update")
        #expect(update.recordSummary == "A recorded update is available. No document is attached to this event.")
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

    static func briefingFixture() throws -> (ArgusOperation, ArgusArtifactPreview) {
        let text = """
        **Synthetic morning briefing**

        **Next actions:**
        1. Read the existing draft: https://linear.app/argus-egillese/issue/SYNTHETIC-1
        2. Keep this unsent follow-up attached to the same briefing.

        **Recorded context:** This is a labelled fixture, not a live request.
        """
        let data = Data(text.utf8)
        let digest = SHA256.hash(data).map { String(format: "%02x", $0) }.joined()
        let payload: [String: Any] = [
            "operation_id": "synthetic-briefing", "task_id": "synthetic-summary-task", "event_id": "synthetic-summary-event",
            "title": "Synthetic delivery envelope", "source": "federation:synthetic", "project": "Argus",
            "display": ["label": "Synthetic delivery envelope"],
            "kind": "result.proposed", "state": "observed", "owner_accepted": false,
            "occurred_at": "2026-09-23T14:30:00Z", "observed_at": "2026-09-23T14:31:00Z",
            "artifacts": [["sha256": digest, "bytes": data.count]],
            "native": ["adapter": "openclaw-cron", "native_event": "summary.available"],
        ]
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let item = try decoder.decode(ArgusOperation.self, from: JSONSerialization.data(withJSONObject: payload))
        return (item, ArgusArtifactPreview(id: "\(item.eventId):\(digest)", data: data, mimeType: "text/plain"))
    }

    @Test func briefingClassificationUsesSourceContractInsteadOfDeliveryTitle() throws {
        var (item, _) = try Self.briefingFixture()
        #expect(item.heading == "Briefing" && item.detailActionLabel == "Read briefing")
        #expect(item.briefingArtifact?.sha256 == item.artifacts[0].sha256)
        item.native = .init(adapter: "openclaw-cron", nativeEvent: "other.event")
        #expect(item.briefingArtifact == nil && item.heading == "Synthetic delivery envelope")
        item.display = .init(label: "Readable ordinary report", changeSummary: nil, artifactLabel: nil, continuationLabel: nil)
        #expect(item.heading == "Readable ordinary report")
    }

    @Test func briefingReopenRetainsExactBytesAcrossTransientReaderClosureButNotOwnerOrPurge() throws {
        let (item, preview) = try Self.briefingFixture()
        let cache = ArgusBriefingCache()
        cache.selectOwner("gateway-a")
        let generation = cache.generation
        cache.retain(preview, for: item, owner: "gateway-a", generation: generation)
        // Closing the detail/transport retires its loader, not the verified session cache.
        let loader = ArgusArtifactOpenStore()
        loader.setAvailable(false)
        #expect(cache.value(for: item, owner: "gateway-a")?.data == preview.data)
        #expect(cache.value(for: item, owner: "gateway-b") == nil)
        cache.clear()
        cache.retain(preview, for: item, owner: "gateway-a", generation: generation)
        #expect(cache.value(for: item, owner: "gateway-a") == nil)
        cache.retain(preview, for: item, owner: "gateway-a", generation: cache.generation)
        cache.selectOwner("gateway-b")
        #expect(cache.value(for: item, owner: "gateway-a") == nil)
        cache.selectOwner("gateway-a")
        #expect(cache.value(for: item, owner: "gateway-a") == nil)
    }

    @Test func briefingCacheRejectsWrongBytesEventAndMime() throws {
        let (item, preview) = try Self.briefingFixture()
        let cache = ArgusBriefingCache()
        cache.selectOwner("gateway-a")
        for invalid in [
            ArgusArtifactPreview(id: preview.id, data: Data("altered".utf8), mimeType: "text/plain"),
            ArgusArtifactPreview(id: "different-event", data: preview.data, mimeType: "text/plain"),
            ArgusArtifactPreview(id: preview.id, data: preview.data, mimeType: "text/html"),
        ] {
            cache.retain(invalid, for: item, owner: "gateway-a", generation: cache.generation)
            #expect(cache.value(for: item, owner: "gateway-a") == nil)
        }
        let text = try #require(String(data: preview.data, encoding: .utf8))
        #expect(ArgusBriefingContent.links(in: text).map(\.absoluteString) == [
            "https://linear.app/argus-egillese/issue/SYNTHETIC-1",
        ])
        #expect(ArgusBriefingContent.links(in: "http://example.com javascript:bad").isEmpty)
        let manyLinks = (0..<1000).map { "https://example.com/document-\($0)" }.joined(separator: "\n")
        let boundedLinks = ArgusBriefingContent.links(in: manyLinks)
        #expect(boundedLinks.count == 32 && boundedLinks.last?.lastPathComponent == "document-31")
        let markdown = "**Briefing** [Custom](openclaw://example) [Credentials](https://user:pass@example.com/private) [Report](https://example.org/report)"
        let formatted = ArgusBriefingContent.formattedBody(markdown)
        #expect(formatted.runs.allSatisfy { $0.link == nil })
        #expect(String(formatted.characters) == "Briefing Custom Credentials Report")
        #expect(formatted.runs.contains { $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true })
        #expect(ArgusBriefingContent.links(in: markdown).map(\.absoluteString) == ["https://example.org/report"])
    }

    @Test func gatewayTransitionClearsBriefingEvenWithoutAMountedReader() throws {
        let (item, preview) = try Self.briefingFixture()
        let model = NodeAppModel()
        model._test_setChatOutboxGatewayOwnerID("gateway-a")
        model.argusBriefingCache.retain(
            preview, for: item, owner: "gateway-a", generation: model.argusBriefingCache.generation)
        #expect(model.argusBriefingCache.value(for: item, owner: "gateway-a")?.data == preview.data)
        model._test_setChatOutboxGatewayOwnerID("gateway-b")
        model._test_setChatOutboxGatewayOwnerID("gateway-a")
        #expect(model.argusBriefingCache.value(for: item, owner: "gateway-a") == nil)
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
