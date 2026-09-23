import Foundation
import SwiftUI

/// Acceptance belongs to one document/event. It never grants activation or
/// changes the historical lifecycle state, even when Engineering has a next action.
struct ArgusDecisionReceipt: Decodable, Sendable {
    struct Coverage: Decodable, Sendable {
        let bindingScope: String
        let receiptSnapshotSequence: Int64
        let decisionSourceBasis: String
        let evaluatedAt: String
        let projectStateComplete: Bool
    }

    let status: String
    let responsibility: String
    let operationId: String?
    let eventId: String?
    let artifactSha256: String?
    let decisionId: String?
    let receiptId: String?
    let nextAction: String?
    let reviewUrl: String?
    let reason: String?
    let doesNotImplyPendingAction: Bool?
    let ownerAccepted: Bool
    let activationAuthorized: Bool
    let programmeComplete: Bool
    let coverage: Coverage

    var reviewURL: URL? {
        guard let reviewUrl, let url = URL(string: reviewUrl), url.scheme == "https",
              url.host != nil, url.user == nil, url.password == nil else { return nil }
        return url
    }

    func validate(operationID: String, eventID: String, artifacts: [String]) throws {
        guard !self.activationAuthorized, !self.programmeComplete, !self.coverage.projectStateComplete,
              self.coverage.bindingScope == "exact_current_detail_operation_event_artifact",
              self.coverage.decisionSourceBasis == "current_corroborated_recorded_decision_source",
              self.coverage.receiptSnapshotSequence >= 0, !self.coverage.evaluatedAt.isEmpty
        else { throw ArgusOperationsError.invalidResponse }

        if self.status == "not_applicable" {
            guard artifacts.count != 1, !self.ownerAccepted, self.responsibility == "unavailable",
                  self.operationId == nil, self.eventId == nil, self.artifactSha256 == nil
            else { throw ArgusOperationsError.invalidResponse }
            return
        }
        guard self.operationId == operationID, self.eventId == eventID,
              let hash = self.artifactSha256, artifacts == [hash]
        else { throw ArgusOperationsError.invalidResponse }

        switch self.status {
        case "accepted_exact_artifact":
            guard self.ownerAccepted, self.responsibility == "agent_action",
                  self.decisionId?.isEmpty == false, self.receiptId?.isEmpty == false,
                  self.nextAction?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
                  self.reviewURL != nil,
                  hash.count == 64, hash.allSatisfy({ "0123456789abcdef".contains($0) })
            else { throw ArgusOperationsError.invalidResponse }
        case "unavailable":
            guard !self.ownerAccepted, self.responsibility == "engineering_reconciliation",
                  self.reason?.isEmpty == false else { throw ArgusOperationsError.invalidResponse }
        case "not_established":
            guard !self.ownerAccepted, self.responsibility == "unavailable",
                  self.doesNotImplyPendingAction == true else { throw ArgusOperationsError.invalidResponse }
        default:
            throw ArgusOperationsError.invalidResponse
        }
    }
}

struct ArgusDecisionReceiptSummary: View {
    let receipt: ArgusDecisionReceipt

    var body: some View {
        if self.receipt.status == "accepted_exact_artifact" || self.receipt.status == "unavailable" {
            VStack(alignment: .leading, spacing: 10) {
                if self.receipt.status == "accepted_exact_artifact" {
                    Label("Document acceptance recorded", systemImage: "checkmark.seal")
                        .font(.headline).accessibilityAddTraits(.isHeader)
                    Text("Next: Engineering").font(.subheadline.weight(.semibold))
                    if let action = self.receipt.nextAction { Text(action).font(.subheadline) }
                    Text("This decision applies to the exact document in this report.")
                        .font(.caption).foregroundStyle(.secondary)
                    if let url = self.receipt.reviewURL {
                        Link("Read recorded decision", destination: url)
                    }
                } else {
                    Label("Engineering reconciliation needed", systemImage: "arrow.triangle.2.circlepath")
                        .font(.headline).accessibilityAddTraits(.isHeader)
                    Text("The recorded decision could not be matched. This is not a new request for your approval.")
                        .font(.subheadline)
                }
                Text("Decision checked: \(ArgusOperation.observationLabel(self.receipt.coverage.evaluatedAt))")
                    .font(.caption).foregroundStyle(.secondary)
                DisclosureGroup("Decision details") {
                    VStack(alignment: .leading, spacing: 6) {
                        if let id = self.receipt.decisionId { Text("Decision: \(id)") }
                        if let id = self.receipt.receiptId { Text("Receipt: \(id)") }
                        if let hash = self.receipt.artifactSha256 { Text("Document: \(hash)") }
                        if let reason = self.receipt.reason { Text(reason) }
                        Text("This receipt does not establish activation authority or programme completion.")
                    }
                    .font(.caption).textSelection(.enabled)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
