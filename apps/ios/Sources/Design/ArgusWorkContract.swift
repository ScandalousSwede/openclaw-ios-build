import Foundation
import SwiftUI

struct ArgusArtifactContext: Decodable, Sendable {
    let relation: String
    let currentAttemptId: String?
    let artifactAttemptId: String?
}

struct ArgusWorkContract: Decodable, Sendable {
    struct Structural: Decodable, Sendable {
        let status: String
        let semanticCorrectnessEstablished: Bool
        let coversAllCurrentArtifacts: Bool
    }

    struct Assessment: Decodable, Sendable {
        let eventId: String
        let outcome: String
        let artifactSha256: String
        let verificationKind: String
        let semanticCorrectnessEstablished: Bool
    }

    struct Independent: Decodable, Sendable {
        let artifacts: [Assessment]
        let coversAllCurrentArtifacts: Bool
        let semanticCorrectnessEstablished: Bool
    }

    struct Feedback: Decodable, Sendable {
        let eventId: String
        let reason: String?
    }

    struct Continuation: Decodable, Sendable {
        let mode: String
        let action: String
        let operationId: String
        let eventId: String
        let artifactSha256: [String]
        let dispatchEnabled: Bool
    }

    struct Coverage: Decodable, Sendable {
        let scope: String
        let complete: Bool
        let crossScopeAbsenceEstablished: Bool
    }

    let schema: String
    let operationId: String
    let latestEventId: String
    let canonicalState: String
    let structuralVerification: Structural
    let independentVerification: Independent
    let pendingOwnerFeedback: [Feedback]
    let continuation: Continuation
    let coverage: Coverage
    let ownerAccepted: Bool
    let isStateTransition: Bool
    // Older qualified servers omit this additive, exact-document decision join.
    var decisionReceiptProjection: ArgusDecisionReceipt? = nil

    func validate(for item: ArgusOperation) throws {
        let hashes = Set(item.artifacts.map(\.sha256))
        let assessments = self.independentVerification.artifacts
        let assessmentHashes = Set(assessments.map(\.artifactSha256))
        let previousAttempt = item.artifactContext?.relation == "previous_attempt"
        guard self.schema == "argus.work.read-contract.v1", self.operationId == item.id,
              self.latestEventId == item.eventId, self.canonicalState == item.state,
              !self.ownerAccepted, !self.isStateTransition,
              !self.structuralVerification.semanticCorrectnessEstablished,
              !self.independentVerification.semanticCorrectnessEstablished,
              ["passed_recorded", "failed_recorded", "not_established"].contains(self.structuralVerification.status),
              ["canonical_operation_trace", "canonical_federation_observation"].contains(self.coverage.scope),
              !self.coverage.crossScopeAbsenceEstablished,
              self.pendingOwnerFeedback.count <= 50,
              Set(self.pendingOwnerFeedback.map(\.eventId)).count == self.pendingOwnerFeedback.count,
              self.continuation.mode == "read_only", self.continuation.action == "inspect_current_evidence",
              !self.continuation.dispatchEnabled, self.continuation.operationId == item.id,
              self.continuation.eventId == item.eventId,
              Set(self.continuation.artifactSha256) == hashes,
              self.coverage.scope == (item.source.hasPrefix("federation:")
                  ? "canonical_federation_observation" : "canonical_operation_trace"),
              Set(assessments.map(\.eventId)).count == assessments.count,
              assessmentHashes.count == assessments.count,
              !self.independentVerification.coversAllCurrentArtifacts
              || (!hashes.isEmpty && assessmentHashes == hashes && assessments.allSatisfy { $0.outcome == "PASS" }),
              !previousAttempt || (assessments.isEmpty && !self.independentVerification.coversAllCurrentArtifacts
                  && !self.structuralVerification.coversAllCurrentArtifacts),
              self.independentVerification.artifacts.count <= 100,
              self.independentVerification.artifacts.allSatisfy({
                  hashes.contains($0.artifactSha256) && ["PASS", "FAIL"].contains($0.outcome)
                      && !$0.semanticCorrectnessEstablished
              }) else { throw ArgusOperationsError.invalidResponse }
        try self.decisionReceiptProjection?.validate(
            operationID: item.id, eventID: item.eventId, artifacts: item.artifacts.map(\.sha256))
    }
}

struct ArgusWorkSummary: View {
    let work: ArgusWorkContract
    let artifactContext: ArgusArtifactContext?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let receipt = self.work.decisionReceiptProjection {
                ArgusDecisionReceiptSummary(receipt: receipt)
            }
            if !self.work.pendingOwnerFeedback.isEmpty {
                Text("Recorded owner requests").font(.headline).accessibilityAddTraits(.isHeader)
                ForEach(self.work.pendingOwnerFeedback, id: \.eventId) { request in
                    Text(request.reason ?? "Inspect the recorded evidence.")
                }
            }
            if self.work.structuralVerification.status == "failed_recorded" {
                Label("Structural check failed", systemImage: "exclamationmark.triangle")
            } else if self.work.structuralVerification.status == "passed_recorded" {
                Text("Structural check passed. This does not establish semantic correctness or owner acceptance.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if self.work.independentVerification.artifacts.contains(where: { $0.outcome == "FAIL" }) {
                Label("A recorded verifier assessment failed", systemImage: "exclamationmark.triangle")
            }
            if self.work.continuation.artifactSha256.isEmpty {
                Text("No artifact is recorded yet. Refresh for new evidence.")
            }
            DisclosureGroup("Verification and scope") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Recorded state: \(self.work.canonicalState.replacingOccurrences(of: "_", with: " "))")
                    if let context = self.artifactContext {
                        Text(context.relation == "previous_attempt"
                            ? "Artifact belongs to a previous attempt. It does not establish this attempt's result."
                            : context.relation == "current_attempt" ? "Artifact belongs to the current attempt."
                            :
                            "Artifact attempt relationship: \(context.relation.replacingOccurrences(of: "_", with: " "))")
                    }
                    Text(
                        "Structural check: \(self.work.structuralVerification.status.replacingOccurrences(of: "_", with: " "))")
                    ForEach(self.work.independentVerification.artifacts, id: \.eventId) { assessment in
                        Text(
                            "\(assessment.verificationKind == "structural_artifact_contract" ? "Independent structural contract" : "Bound verifier assessment"): \(assessment.outcome)")
                    }
                    Text(self.work.independentVerification.coversAllCurrentArtifacts
                        ? "Recorded assessments cover all current artifacts. These checks alone do not establish semantic correctness or owner acceptance."
                        : "Complete independent coverage of current artifacts is not established.")
                    if self.work.pendingOwnerFeedback.isEmpty {
                        Text("No owner request recorded in this returned scope. Other scopes may contain requests.")
                    }
                    Text("Continuation inspects recorded evidence. No work is dispatched.")
                    Text(
                        "Scope: \(self.work.coverage.scope). \(self.work.coverage.complete ? "Returned scope complete." : "Coverage is partial.")")
                }
                .font(.subheadline)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
