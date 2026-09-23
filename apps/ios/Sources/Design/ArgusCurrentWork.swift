import Foundation
import Observation
import SwiftUI

/// Typed decisions and follow-through are separate from technical report history.
struct ArgusCurrentWorkPage: Decodable, Sendable {
    struct Effects: Decodable, Sendable {
        let readOnly: Bool
        let canSubmit: Bool
        let canApprove: Bool
        let canDispatch: Bool
    }

    struct Coverage: Decodable, Sendable {
        struct Source: Decodable, Sendable {
            let status: String
            let scope: String?
        }
        let status: String
        let scope: String
        let observedAt: String
        let programmeCount: Int?
        let programmeComplete: Bool
        let returned: Int
        let hasMore: Bool
        let sources: [String: Source]

        var hasUnavailableSources: Bool {
            self.sources.values.contains { $0.status == "unavailable" }
        }

        var sourceStatus: [String] {
            [("grant_review", "Grant review"), ("recorded_acceptances", "Recorded document decisions")].map { name, label in
                let state = self.sources[name]?.status == "bounded"
                    ? "checked within this limited read." : "unavailable; state unknown."
                return "\(label): \(state)"
            }
        }
    }

    struct Item: Decodable, Sendable {
        struct RecordedChoices: Decodable, Sendable {
            struct Record: Decodable, Sendable, Identifiable {
                let decisionId: String
                let recordedAt: String
                let summary: String
                let state: String
                let supersedes: [String]
                let supersededBy: [String]
                let sourceSha256: String
                var id: String { self.decisionId }
            }
            let status: String
            let source: String
            let records: [Record]
        }

        struct Presentation: Decodable, Sendable {
            struct Provenance: Decodable, Sendable {
                let titleBasis: String
                let summaryBasis: String
                let fallback: Bool
            }
            let title: String
            let summary: String?
            let provenance: Provenance
        }
        let kind: String
        let responsibility: String
        let nextActor: String
        let question: String?
        let outcome: String
        let nextAction: String
        let reviewUrl: String?
        let presentation: Presentation
        let reviewId: String?
        let applicationId: String?
        let revisionId: String?
        let mapSha: String?
        let payloadSha: String?
        let operationId: String?
        let eventId: String?
        let artifactSha256: String?
        let decisionId: String?
        let receiptId: String?
        let source: String?
        let activationAuthorized: Bool?
        let programmeComplete: Bool?
        var recordedChoices: RecordedChoices? = nil

        var reviewURL: URL? {
            guard let reviewUrl, let url = URL(string: reviewUrl), url.scheme == "https",
                  url.host == "linear.app", url.user == nil, url.password == nil,
                  url.path.hasPrefix("/argus-egillese/issue/") else { return nil }
            return url
        }

        var actorLabel: String {
            switch self.nextActor {
            case "existing_engineering_owner": "Engineering"
            case "grant-draft-owner": "Grant draft owner"
            default: self.nextActor
            }
        }

        var outcomeLabel: String {
            switch self.outcome {
            case "decision_not_recorded": "Decision not yet recorded"
            case "exact_artifact_accepted": "Document acceptance recorded"
            case "draft_approved_follow_through": "Draft approved · follow-through remains"
            case "revision_requested_follow_through": "Revision requested"
            case "recorded_choices_pending_incorporation": "Choices recorded · draft update next"
            case "recorded_choices_reconciliation_required": "Recorded choices need reconciliation"
            default: "Source reconciliation needed"
            }
        }

        func validate() throws {
            func text(_ value: String?, max: Int = 500) -> Bool {
                guard let value else { return false }
                return (1...max).contains(value.count)
                    && !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    && !value.unicodeScalars.contains(where: { $0.value < 32 })
            }
            func hash(_ value: String?) -> Bool {
                guard let value else { return false }
                return value.count == 64 && value.allSatisfy { "0123456789abcdef".contains($0) }
            }
            guard text(self.presentation.title, max: 500), text(self.nextActor), text(self.nextAction),
                  self.presentation.summary == nil || text(self.presentation.summary),
                  text(self.presentation.provenance.titleBasis), text(self.presentation.provenance.summaryBasis),
                  self.activationAuthorized != true, self.programmeComplete != true
            else { throw ArgusOperationsError.invalidResponse }
            switch self.kind {
            case "owner_decision", "grant_follow_through":
                guard [self.reviewId, self.applicationId, self.revisionId].allSatisfy({ text($0, max: 300) }),
                      hash(self.mapSha), hash(self.payloadSha), self.reviewURL != nil,
                      self.operationId == nil, self.eventId == nil, self.artifactSha256 == nil,
                      self.decisionId == nil, self.receiptId == nil, self.source == nil
                else { throw ArgusOperationsError.invalidResponse }
                if self.kind == "owner_decision" {
                    guard self.responsibility == "owner_choice", self.outcome == "decision_not_recorded",
                          text(self.question) else { throw ArgusOperationsError.invalidResponse }
                } else {
                    guard self.responsibility == "agent_action", self.question == nil,
                          ["draft_approved_follow_through", "revision_requested_follow_through",
                           "grant_follow_through_state_unknown", "recorded_choices_pending_incorporation",
                           "recorded_choices_reconciliation_required"].contains(self.outcome)
                    else { throw ArgusOperationsError.invalidResponse }
                }
            case "accepted_work":
                guard self.responsibility == "agent_action", self.outcome == "exact_artifact_accepted",
                      self.nextActor == "existing_engineering_owner",
                      self.question == nil, self.reviewURL != nil,
                      self.activationAuthorized == false, self.programmeComplete == false,
                      self.reviewId == nil, self.applicationId == nil, self.revisionId == nil,
                      self.mapSha == nil, self.payloadSha == nil, self.source == nil,
                      [self.operationId, self.eventId, self.decisionId, self.receiptId]
                          .allSatisfy({ text($0, max: 300) }), hash(self.artifactSha256)
                else { throw ArgusOperationsError.invalidResponse }
            case "reconciliation_gap":
                // The installed producer deliberately retains operation/receipt IDs
                // identifying the broken join. They are context, not acceptance;
                // outcome/responsibility stay unknown/Engineering reconciliation.
                guard self.responsibility == "engineering_reconciliation", self.question == nil,
                      self.nextActor == "existing_engineering_owner",
                      self.outcome == "unknown_or_changed", self.reviewUrl == nil,
                      self.reviewId == nil, self.applicationId == nil, self.revisionId == nil,
                      self.mapSha == nil, self.payloadSha == nil, self.eventId == nil,
                      self.artifactSha256 == nil, self.decisionId == nil
                else { throw ArgusOperationsError.invalidResponse }
            default: throw ArgusOperationsError.invalidResponse
            }
            if let choices = self.recordedChoices {
                guard self.kind == "grant_follow_through", self.nextActor == "grant-draft-owner",
                      choices.source == "memory/decisions.jsonl",
                      choices.status == "recorded" || choices.status == "unavailable"
                else { throw ArgusOperationsError.invalidResponse }
                if choices.status == "unavailable" {
                    guard self.outcome == "recorded_choices_reconciliation_required", choices.records.isEmpty
                    else { throw ArgusOperationsError.invalidResponse }
                } else {
                    guard self.outcome == "recorded_choices_pending_incorporation",
                          (2...16).contains(choices.records.count),
                          Set(choices.records.map(\.decisionId)).count == choices.records.count
                    else { throw ArgusOperationsError.invalidResponse }
                    for record in choices.records {
                        guard text(record.decisionId, max: 200), text(record.recordedAt, max: 80),
                              text(record.summary), text(record.state, max: 40), hash(record.sourceSha256),
                              record.supersedes.count <= 16, record.supersededBy.count <= 16,
                              (record.supersedes + record.supersededBy).allSatisfy({ text($0, max: 200) })
                        else { throw ArgusOperationsError.invalidResponse }
                    }
                    let recordsByID = Dictionary(uniqueKeysWithValues: choices.records.map { ($0.id, $0) })
                    for record in choices.records {
                        guard Set(record.supersedes).count == record.supersedes.count,
                              Set(record.supersededBy).count == record.supersededBy.count,
                              record.supersedes.allSatisfy({ id in
                                  id != record.id && recordsByID[id]?.supersededBy.contains(record.id) == true
                              }),
                              record.supersededBy.allSatisfy({ id in
                                  id != record.id && recordsByID[id]?.supersedes.contains(record.id) == true
                              })
                        else { throw ArgusOperationsError.invalidResponse }
                        // A reciprocal cycle is still not a valid earlier/later choice history.
                        var pending = record.supersedes
                        var visited = Set<String>()
                        while let id = pending.popLast() {
                            guard id != record.id else { throw ArgusOperationsError.invalidResponse }
                            if visited.insert(id).inserted, let predecessor = recordsByID[id] {
                                pending.append(contentsOf: predecessor.supersedes)
                            }
                        }
                    }
                }
            } else if ["recorded_choices_pending_incorporation", "recorded_choices_reconciliation_required"]
                .contains(self.outcome)
            {
                throw ArgusOperationsError.invalidResponse
            }
        }
    }

    let schema: String
    let items: [Item]
    let coverage: Coverage
    let effects: Effects

    func validate() throws {
        guard self.schema == "argus.current-work.v1", self.items.count <= 50,
              self.coverage.returned == self.items.count, !self.coverage.programmeComplete,
              self.coverage.programmeCount == nil, !self.coverage.observedAt.isEmpty,
              self.coverage.scope == "current_grant_review_and_recorded_exact_artifact_acceptances",
              self.effects.readOnly, !self.effects.canSubmit, !self.effects.canApprove, !self.effects.canDispatch
        else { throw ArgusOperationsError.invalidResponse }
        try self.items.forEach { try $0.validate() }
        let expectedScopes = [
            "grant_review": "current_grant_review",
            "recorded_acceptances": "recorded_exact_artifact_acceptance_receipts",
        ]
        guard Set(self.coverage.sources.keys) == Set(expectedScopes.keys)
        else { throw ArgusOperationsError.invalidResponse }
        for (name, scope) in expectedScopes {
            guard let source = self.coverage.sources[name], source.scope == scope,
                  ["bounded", "unavailable"].contains(source.status)
            else { throw ArgusOperationsError.invalidResponse }
            if source.status == "unavailable" {
                let kinds = name == "grant_review" ? ["owner_decision", "grant_follow_through"] : ["accepted_work"]
                guard !self.items.contains(where: { kinds.contains($0.kind) })
                else { throw ArgusOperationsError.invalidResponse }
            }
        }
        // The producer intentionally retains valid work and reconciliation gaps
        // when a sibling source is unavailable. Partial coverage is not a failed page.
        let unavailable = self.coverage.sources.values.filter { $0.status == "unavailable" }.count
        let expectedStatus = unavailable == 0 ? "bounded" : unavailable == 1 ? "partial" : "unavailable"
        guard self.coverage.status == expectedStatus else { throw ArgusOperationsError.invalidResponse }
    }
}

@MainActor
@Observable
final class ArgusCurrentWorkStore {
    private(set) var page: ArgusCurrentWorkPage?
    private(set) var unavailable = true
    private(set) var isLoading = false
    @ObservationIgnored private var gatewayID: String?
    @ObservationIgnored private var generation = 0

    func selectGateway(_ id: String?) {
        guard self.gatewayID != id else { return }
        self.gatewayID = id
        self.page = nil
        self.markUnavailable()
    }

    func markUnavailable() {
        self.generation += 1
        self.unavailable = true
        self.isLoading = false
    }

    func refresh(using client: ArgusOperationsClient) async {
        await self.refresh(gatewayID: client.gatewayID) {
            try await client.request("argus.current-work.list", params: [:], as: ArgusCurrentWorkPage.self)
        }
    }

    func refresh(gatewayID: String, fetch: () async throws -> ArgusCurrentWorkPage) async {
        guard self.gatewayID == gatewayID, !self.isLoading, !Task.isCancelled else { return }
        self.isLoading = true
        let generation = self.generation
        defer { if generation == self.generation { self.isLoading = false } }
        do {
            let page = try await fetch()
            guard generation == self.generation, !Task.isCancelled else { return }
            try page.validate()
            self.page = page
            self.unavailable = false
        } catch {
            guard generation == self.generation, !Task.isCancelled else { return }
            self.unavailable = true
        }
    }
}

struct ArgusCurrentWorkContent: View {
    @Environment(\.colorScheme) private var colorScheme
    let store: ArgusCurrentWorkStore
    let client: ArgusOperationsClient?

    var body: some View {
        CommandPanel(padding: 16) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Current decisions & follow-through").font(.headline).accessibilityAddTraits(.isHeader)
                if self.store.unavailable {
                    Label(self.store.page == nil
                        ? "Current work is unavailable. Report history is still below."
                        : "Showing the last check. Decisions and next actions may have changed.", systemImage: "wifi.slash")
                        .font(.subheadline)
                }
                if let page = self.store.page {
                    Text("Checked: \(ArgusOperation.observationLabel(page.coverage.observedAt))")
                        .font(.caption).foregroundStyle(.secondary)
                    if page.coverage.hasUnavailableSources {
                        Label("Some current-work sources are unavailable. Missing state remains unknown.", systemImage: "exclamationmark.triangle")
                            .font(.subheadline)
                    }
                    ForEach(page.coverage.sourceStatus, id: \.self) { status in
                        Text(status).font(.caption).foregroundStyle(.secondary)
                    }
                    self.group(page, responsibility: "owner_choice", heading: "Recorded choices for you")
                    self.group(page, responsibility: "agent_action", heading: "Engineering follow-through")
                    self.group(page, responsibility: "engineering_reconciliation", heading: "Source reconciliation")
                    if page.items.isEmpty {
                        Text("No decisions or follow-through were returned by these sources.")
                    }
                    Text("Other work may not be included; this is not a programme-wide count.")
                        .font(.caption).foregroundStyle(.secondary)
                    if page.coverage.hasMore {
                        Text("More entries exist beyond this returned list.").font(.caption)
                    }
                    DisclosureGroup("Source coverage") {
                        ForEach(page.coverage.sources.keys.sorted(), id: \.self) { name in
                            Text("\(name): \(page.coverage.sources[name]?.status ?? "unavailable")")
                                .font(.caption).textSelection(.enabled)
                        }
                    }
                }
                if self.store.isLoading { ProgressView("Checking current work") }
                if let client {
                    Button("Refresh current work") { Task { await self.store.refresh(using: client) } }
                        .buttonStyle(.bordered).disabled(self.store.isLoading)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, OpenClawProMetric.pagePadding)
    }

    @ViewBuilder
    private func group(_ page: ArgusCurrentWorkPage, responsibility: String, heading: String) -> some View {
        let entries = page.items.enumerated().filter { $0.element.responsibility == responsibility }
        if !entries.isEmpty {
            Text(heading)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(self.groupColor(responsibility))
                .accessibilityAddTraits(.isHeader)
            ForEach(entries, id: \.offset) { entry in
                let item = entry.element
                VStack(alignment: .leading, spacing: 8) {
                    if item.kind == "accepted_work" {
                        Text(item.outcomeLabel).font(.headline)
                        Text("Recorded report").font(.caption).foregroundStyle(.secondary)
                        Text(item.presentation.title).font(.subheadline.weight(.semibold))
                    } else {
                        Text(item.presentation.title).font(.headline)
                        Text(item.outcomeLabel).font(.subheadline.weight(.semibold))
                    }
                    if let choices = item.recordedChoices, choices.status == "recorded" {
                        ForEach(choices.records) { record in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(record.supersededBy.isEmpty ? "Recorded choice" : "Earlier choice · updated later")
                                    .font(.subheadline.weight(.semibold))
                                Text(record.summary).font(.subheadline).textSelection(.enabled)
                                Text(ArgusOperation.observationLabel(record.recordedAt))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Text("The draft owner will incorporate these choices. Draft approval and submission remain separate.")
                            .font(.subheadline)
                    } else if let summary = item.presentation.summary {
                        Text(summary).font(.subheadline)
                    }
                    Text("Next: \(item.actorLabel)").font(.subheadline)
                    if let question = item.question, question != item.presentation.title { Text(question) }
                    Text(item.nextAction).font(.subheadline)
                    if let url = item.reviewURL { Link("Open recorded work", destination: url) }
                    DisclosureGroup("Details") {
                        VStack(alignment: .leading, spacing: 4) {
                            if let id = item.reviewId { Text("Review: \(id)") }
                            if let id = item.applicationId { Text("Application: \(id)") }
                            if let id = item.revisionId { Text("Revision: \(id)") }
                            if let id = item.operationId { Text("Operation: \(id)") }
                            if let id = item.eventId { Text("Event: \(id)") }
                            if let id = item.artifactSha256 { Text("Document: \(id)") }
                            if let id = item.receiptId { Text("Receipt: \(id)") }
                            if let id = item.decisionId { Text("Decision: \(id)") }
                            if let choices = item.recordedChoices {
                                Text("Choice source: \(choices.source) · \(choices.status)")
                                ForEach(choices.records) { record in
                                    Text("Decision: \(record.decisionId) · source state: \(record.state)")
                                    Text("Source digest: \(record.sourceSha256)")
                                    if !record.supersedes.isEmpty {
                                        Text("Supersedes: \(record.supersedes.joined(separator: ", "))")
                                    }
                                    if !record.supersededBy.isEmpty {
                                        Text("Updated by: \(record.supersededBy.joined(separator: ", "))")
                                    }
                                }
                            }
                            Text("Title source: \(item.presentation.provenance.titleBasis)")
                            if item.presentation.provenance.fallback { Text("The source has no more specific display title.") }
                        }
                        .font(.caption).textSelection(.enabled)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .proPanelSurface(
                    tint: responsibility == "agent_action" ? nil : self.groupColor(responsibility).opacity(0.55),
                    radius: 12,
                    isProminent: responsibility == "agent_action",
                    fill: responsibility == "owner_choice" ? OpenClawBrand.decisionSurface(for: self.colorScheme) : nil)
            }
        }
    }

    private func groupColor(_ responsibility: String) -> Color {
        switch responsibility {
        case "owner_choice": OpenClawBrand.decisionAttention
        case "engineering_reconciliation": OpenClawBrand.reconciliationAttention
        default: .primary
        }
    }
}
