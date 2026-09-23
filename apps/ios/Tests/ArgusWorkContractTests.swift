import Foundation
import Testing
@testable import OpenClaw

struct ArgusWorkContractTests {
    static func fixture(
        relation: String = "current_attempt", preArtifact: Bool = false,
        decision: [String: Any]? = nil) throws -> (ArgusOperation, ArgusWorkContract)
    {
        let digest = String(repeating: "a", count: 64)
        let itemJSON: [String: Any] = [
            "operation_id": "ordinary-97", "task_id": "task-97", "event_id": "event-99",
            "title": "Technical result", "source": "canonical:codex-completion-adapter",
            "project": "Argus", "kind": "verifier.outcome.verified", "state": preArtifact ? "running" : "verified",
            "occurred_at": "2026-09-07T03:00:00Z", "observed_at": "2026-09-07T03:00:00Z",
            "owner_accepted": false, "evidence_scope": "admitted_canonical_technical_operation",
            "artifacts": preArtifact ? [] : [["sha256": digest, "bytes": 32]],
            "artifact_context": ["relation": relation, "current_attempt_id": "attempt-2", "artifact_attempt_id": relation == "current_attempt" ? "attempt-2" : "attempt-1"],
        ]
        var workJSON: [String: Any] = [
            "schema": "argus.work.read-contract.v1", "operation_id": "ordinary-97",
            "latest_event_id": "event-99", "canonical_state": preArtifact ? "running" : "verified",
            "owner_accepted": false, "is_state_transition": false,
            "structural_verification": ["status": "not_established", "semantic_correctness_established": false, "covers_all_current_artifacts": false],
            "independent_verification": ["artifacts": [], "covers_all_current_artifacts": false, "semantic_correctness_established": false],
            "pending_owner_feedback": [],
            "continuation": ["mode": "read_only", "action": "inspect_current_evidence", "operation_id": "ordinary-97", "event_id": "event-99", "artifact_sha256": preArtifact ? [] : [digest], "dispatch_enabled": false],
            "coverage": ["scope": "canonical_operation_trace", "complete": false, "cross_scope_absence_established": false],
        ]
        if let decision { workJSON["decision_receipt_projection"] = decision }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return (try decoder.decode(ArgusOperation.self, from: JSONSerialization.data(withJSONObject: itemJSON)),
                try decoder.decode(ArgusWorkContract.self, from: JSONSerialization.data(withJSONObject: workJSON)))
    }

    @Test func currentAndPreviousAttemptRemainExplicitReadOnlyEvidence() throws {
        for relation in ["current_attempt", "previous_attempt"] {
            let (item, work) = try Self.fixture(relation: relation)
            try work.validate(for: item)
            #expect(item.artifactContext?.relation == relation)
            #expect(!work.independentVerification.coversAllCurrentArtifacts)
            #expect(!work.coverage.complete)
            #expect(work.decisionReceiptProjection == nil)
        }
    }

    @Test func unrelatedContinuationAndAuthorityClaimsAreRejected() throws {
        let (item, work) = try Self.fixture()
        func changed(continuation: ArgusWorkContract.Continuation, owner: Bool = false) -> ArgusWorkContract {
            .init(schema: work.schema, operationId: work.operationId, latestEventId: work.latestEventId,
                  canonicalState: work.canonicalState, structuralVerification: work.structuralVerification,
                  independentVerification: work.independentVerification, pendingOwnerFeedback: [],
                  continuation: continuation, coverage: work.coverage, ownerAccepted: owner, isStateTransition: false)
        }
        for continuation in [
            ArgusWorkContract.Continuation(mode: "dispatch", action: "inspect_current_evidence", operationId: item.id, eventId: item.eventId, artifactSha256: [], dispatchEnabled: true),
            .init(mode: "read_only", action: "inspect_current_evidence", operationId: "foreign", eventId: item.eventId, artifactSha256: [], dispatchEnabled: false),
            .init(mode: "read_only", action: "inspect_current_evidence", operationId: item.id, eventId: item.eventId, artifactSha256: [String(repeating: "b", count: 64)], dispatchEnabled: false),
        ] {
            #expect(throws: ArgusOperationsError.self) { try changed(continuation: continuation).validate(for: item) }
        }
        #expect(throws: ArgusOperationsError.self) { try changed(continuation: work.continuation, owner: true).validate(for: item) }
    }
    @Test func runningBeforeFirstArtifactIsReadableWithoutInventedContinuation() throws {
        let (item, work) = try Self.fixture(relation: "unknown", preArtifact: true)
        try work.validate(for: item)
        #expect(item.isAdmitted)
        #expect(item.state == "running")
        #expect(item.artifacts.isEmpty)
        #expect(work.continuation.artifactSha256.isEmpty)
        #expect(!work.independentVerification.coversAllCurrentArtifacts)
    }

    static func decisionPayload(status: String = "accepted_exact_artifact") -> [String: Any] {
        var value: [String: Any] = [
            "status": status, "responsibility": "agent_action",
            "operation_id": "ordinary-97", "event_id": "event-99",
            "artifact_sha256": String(repeating: "a", count: 64),
            "decision_id": "synthetic-decision", "receipt_id": "synthetic-receipt",
            "next_action": "Engineering will reconcile the remaining operational work.",
            "review_url": "https://example.com/synthetic-decision",
            "owner_accepted": true, "activation_authorized": false, "programme_complete": false,
            "coverage": [
                "binding_scope": "exact_current_detail_operation_event_artifact",
                "receipt_snapshot_sequence": 42,
                "decision_source_basis": "current_corroborated_recorded_decision_source",
                "evaluated_at": "2026-09-22T18:16:00Z", "project_state_complete": false,
            ],
        ]
        if status != "accepted_exact_artifact" {
            value["owner_accepted"] = false
            value["responsibility"] = status == "unavailable" ? "engineering_reconciliation" : "unavailable"
            value["reason"] = "The current decision binding is unavailable."
            for key in ["decision_id", "receipt_id", "next_action", "review_url"] {
                value.removeValue(forKey: key)
            }
        }
        if status == "not_established" { value["does_not_imply_pending_action"] = true }
        if status == "not_applicable" {
            for key in ["operation_id", "event_id", "artifact_sha256"] { value.removeValue(forKey: key) }
        }
        return value
    }

    @Test func exactAcceptancePreservesHistoricalStateAndEnvelopeAuthority() throws {
        let (item, work) = try Self.fixture(decision: Self.decisionPayload())
        let detail = ArgusOperationDetail(
            item: item, requested: item, timeline: [],
            coverage: .init(complete: true, hasMore: false, observedAt: item.observedAt),
            ownerAccepted: false, workContract: work)
        try detail.validate(for: item)
        let decision = try #require(work.decisionReceiptProjection)
        #expect(decision.ownerAccepted && decision.responsibility == "agent_action")
        #expect(decision.eventId == item.eventId && decision.artifactSha256 == item.artifacts.first?.sha256)
        #expect(!work.ownerAccepted && !detail.ownerAccepted && !item.ownerAccepted)
        #expect(item.state == "verified" && !decision.activationAuthorized && !decision.programmeComplete)
        #expect(decision.reviewURL?.absoluteString == "https://example.com/synthetic-decision")
    }

    @Test func foreignDecisionBindingsAndBroaderAuthorityAreRejected() throws {
        let changes: [(String, Any)] = [
            ("operation_id", "other-operation"), ("event_id", "other-event"),
            ("artifact_sha256", String(repeating: "b", count: 64)),
            ("owner_accepted", false), ("activation_authorized", true), ("programme_complete", true),
            ("responsibility", "owner_decision"), ("receipt_id", ""),
            ("review_url", "javascript:alert(1)"), ("review_url", "https://user:password@example.com/"),
        ]
        for (key, value) in changes {
            var payload = Self.decisionPayload()
            payload[key] = value
            let (item, work) = try Self.fixture(decision: payload)
            #expect(throws: ArgusOperationsError.self) { try work.validate(for: item) }
        }
        var payload = Self.decisionPayload()
        var coverage = try #require(payload["coverage"] as? [String: Any])
        coverage["project_state_complete"] = true
        payload["coverage"] = coverage
        let (item, work) = try Self.fixture(decision: payload)
        #expect(throws: ArgusOperationsError.self) { try work.validate(for: item) }
    }

    @Test func absentOrUnmatchedDecisionNeverBecomesOwnerApprovalWork() throws {
        for status in ["unavailable", "not_established", "not_applicable"] {
            let (item, work) = try Self.fixture(
                preArtifact: status == "not_applicable", decision: Self.decisionPayload(status: status))
            try work.validate(for: item)
            let decision = try #require(work.decisionReceiptProjection)
            #expect(!decision.ownerAccepted && decision.responsibility != "owner_decision")
            #expect(decision.nextAction == nil && decision.reviewURL == nil)
        }
        let (item, work) = try Self.fixture(decision: Self.decisionPayload(status: "not_applicable"))
        #expect(throws: ArgusOperationsError.self) { try work.validate(for: item) }
    }

}
