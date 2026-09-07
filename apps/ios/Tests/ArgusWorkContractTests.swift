import Foundation
import Testing
@testable import OpenClaw

struct ArgusWorkContractTests {
    static func fixture(relation: String = "current_attempt") throws -> (ArgusOperation, ArgusWorkContract) {
        let digest = String(repeating: "a", count: 64)
        let itemJSON: [String: Any] = [
            "operation_id": "ordinary-97", "task_id": "task-97", "event_id": "event-99",
            "title": "Technical result", "source": "canonical:codex-completion-adapter",
            "project": "Argus", "kind": "verifier.outcome.verified", "state": "verified",
            "occurred_at": "2026-09-07T03:00:00Z", "observed_at": "2026-09-07T03:00:00Z",
            "owner_accepted": false, "evidence_scope": "admitted_canonical_technical_operation",
            "artifacts": [["sha256": digest, "bytes": 32]],
            "artifact_context": ["relation": relation, "current_attempt_id": "attempt-2", "artifact_attempt_id": relation == "current_attempt" ? "attempt-2" : "attempt-1"],
        ]
        let workJSON: [String: Any] = [
            "schema": "argus.work.read-contract.v1", "operation_id": "ordinary-97",
            "latest_event_id": "event-99", "canonical_state": "verified",
            "owner_accepted": false, "is_state_transition": false,
            "structural_verification": ["status": "not_established", "semantic_correctness_established": false, "covers_all_current_artifacts": false],
            "independent_verification": ["artifacts": [], "covers_all_current_artifacts": false, "semantic_correctness_established": false],
            "pending_owner_feedback": [],
            "continuation": ["mode": "read_only", "action": "inspect_current_evidence", "operation_id": "ordinary-97", "event_id": "event-99", "artifact_sha256": [digest], "dispatch_enabled": false],
            "coverage": ["scope": "canonical_operation_trace", "complete": false, "cross_scope_absence_established": false],
        ]
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
}
