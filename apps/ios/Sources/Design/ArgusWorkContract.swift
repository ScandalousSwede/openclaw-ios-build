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
              (!self.independentVerification.coversAllCurrentArtifacts
                  || (!hashes.isEmpty && assessmentHashes == hashes && assessments.allSatisfy { $0.outcome == "PASS" })),
              (!previousAttempt || (assessments.isEmpty && !self.independentVerification.coversAllCurrentArtifacts
                  && !self.structuralVerification.coversAllCurrentArtifacts)) ,
              self.independentVerification.artifacts.count <= 100,
              self.independentVerification.artifacts.allSatisfy({
                  hashes.contains($0.artifactSha256) && ["PASS", "FAIL"].contains($0.outcome)
                      && !$0.semanticCorrectnessEstablished
              }) else { throw ArgusOperationsError.invalidResponse }
    }
}

struct ArgusWorkSummary: View {
    let work: ArgusWorkContract
    let artifactContext: ArgusArtifactContext?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Current evidence").font(.headline).accessibilityAddTraits(.isHeader)
            Text("Recorded state: \(self.work.canonicalState.replacingOccurrences(of: "_", with: " "))")
            if let context = self.artifactContext {
                Text(context.relation == "previous_attempt"
                     ? "Artifact belongs to a previous attempt. It does not establish this attempt's result."
                     : context.relation == "current_attempt" ? "Artifact belongs to the current attempt."
                     : "Artifact attempt relationship: \(context.relation.replacingOccurrences(of: "_", with: " "))")
            }
            Text("Structural check: \(self.work.structuralVerification.status.replacingOccurrences(of: "_", with: " "))")
            ForEach(self.work.independentVerification.artifacts, id: \.eventId) { assessment in
                Text("\(assessment.verificationKind == "structural_artifact_contract" ? "Independent structural contract" : "Bound verifier assessment"): \(assessment.outcome)")
            }
            Text(self.work.independentVerification.coversAllCurrentArtifacts
                 ? "Recorded assessments cover all current artifacts. Semantic correctness and owner acceptance remain unestablished."
                 : "Complete independent coverage of current artifacts is not established.")
                .font(.caption).foregroundStyle(.secondary)
            if self.work.pendingOwnerFeedback.isEmpty {
                Text("No owner request recorded in this returned scope. Other scopes may contain requests.")
            } else {
                Text("Recorded owner requests").font(.headline)
                ForEach(self.work.pendingOwnerFeedback, id: \.eventId) { request in
                    Text(request.reason ?? "Inspect the recorded evidence.")
                }
            }
            Text(self.work.continuation.artifactSha256.isEmpty
                 ? "No artifact is recorded yet. Inspect the current status and refresh for new evidence. No work is dispatched."
                 : "Continuation: inspect the current evidence and open its verified artifact below. No work is dispatched.")
            Text("Scope: \(self.work.coverage.scope). \(self.work.coverage.complete ? "Returned scope complete." : "Coverage is partial.")")
                .font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
