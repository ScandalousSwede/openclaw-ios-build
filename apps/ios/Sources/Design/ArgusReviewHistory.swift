import Foundation
import SwiftUI

struct ArgusReviewHistory: Decodable, Sendable {
    struct Coverage: Decodable, Sendable {
        let complete: Bool
        let hasMore: Bool
        let snapshotSequence: Int
    }

    struct Item: Decodable, Identifiable, Sendable {
        enum State: String, Decodable, Sendable { case pending, accepted, rejected }
        enum Relation: String, Decodable, Sendable { case current, previous }
        struct Binding: Decodable, Sendable {
            let operationId: String
            let eventId: String
            let artifactSha256: [String]
        }
        struct Disposition: Decodable, Sendable {
            let eventId: String
            let recordedAtMs: Int
        }
        let id: String
        let requestEventId: String
        let binding: Binding
        let state: State
        let bindingRelation: Relation
        let requestedAtMs: Int
        let expiresAtMs: Int
        let disposition: Disposition?

        var title: String {
            switch self.state {
            case .pending: "Review requested"
            case .accepted: "Operator accepted this artifact"
            case .rejected: "Operator rejected this artifact"
            }
        }
    }

    let items: [Item]
    let coverage: Coverage
    let ownerAccepted: Bool

    func validate(for operation: ArgusOperation) throws {
        guard !self.ownerAccepted, self.items.count <= 25,
              self.coverage.snapshotSequence >= 0,
              self.coverage.snapshotSequence <= 9_007_199_254_740_991,
              self.coverage.complete != self.coverage.hasMore,
              Set(self.items.map(\.id)).count == self.items.count,
              Set(self.items.map(\.requestEventId)).count == self.items.count,
              operation.source == "canonical:codex-completion-adapter"
        else { throw ArgusOperationsError.invalidResponse }
        for item in self.items {
            let hashes = item.binding.artifactSha256
            guard Self.validID(item.id), Self.validID(item.requestEventId),
                  Self.validID(item.binding.eventId), item.binding.operationId == operation.id,
                  (1...64).contains(hashes.count), Set(hashes).count == hashes.count,
                  hashes.allSatisfy({ $0.range(of: "^[0-9a-f]{64}$", options: .regularExpression) == $0.startIndex..<$0.endIndex }),
                  Self.validTime(item.requestedAtMs), Self.validTime(item.expiresAtMs),
                  item.expiresAtMs - item.requestedAtMs == 1_800_000
            else { throw ArgusOperationsError.invalidResponse }
            if let disposition = item.disposition {
                guard item.state != .pending, Self.validID(disposition.eventId),
                      Self.validTime(disposition.recordedAtMs)
                else { throw ArgusOperationsError.invalidResponse }
            } else if item.state != .pending {
                throw ArgusOperationsError.invalidResponse
            }
            if item.bindingRelation == .current {
                guard item.binding.eventId == operation.eventId,
                      hashes.sorted() == operation.artifacts.map(\.sha256).sorted()
                else { throw ArgusOperationsError.invalidResponse }
            }
        }
    }

    private static func validID(_ value: String) -> Bool {
        value.range(of: "^[A-Za-z0-9_.:-]{1,512}$", options: .regularExpression) == value.startIndex..<value.endIndex
    }

    private static func validTime(_ value: Int) -> Bool {
        (0...9_007_199_254_740_991).contains(value)
    }
}

struct ArgusReviewHistorySummary: View {
    let history: ArgusReviewHistory

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Operator artifact reviews").font(.headline).accessibilityAddTraits(.isHeader)
            Text("Recorded dispositions do not establish owner or scientific acceptance, or independent verification.")
                .font(.caption).foregroundStyle(.secondary)
            if self.history.items.isEmpty {
                Text("No qualified review requests recorded in this snapshot.").font(.subheadline)
            }
            ForEach(self.history.items) { item in
                VStack(alignment: .leading, spacing: 5) {
                    Text(item.title).font(.subheadline.bold())
                    Text(item.bindingRelation == .current ? "Current binding" : "Earlier artifact or work state")
                        .font(.caption).foregroundStyle(.secondary)
                    if let disposition = item.disposition {
                        Text("Recorded \(Date(timeIntervalSince1970: Double(disposition.recordedAtMs) / 1000), format: .dateTime.month().day().hour().minute())")
                            .font(.caption)
                    } else {
                        Text("No qualified disposition recorded").font(.caption)
                        Text("Request expiry: \(Date(timeIntervalSince1970: Double(item.expiresAtMs) / 1000), format: .dateTime.month().day().hour().minute())")
                            .font(.caption)
                    }
                    ForEach(item.binding.artifactSha256, id: \.self) { hash in
                        Text("Artifact \(hash.prefix(12))").font(.caption.monospaced()).textSelection(.enabled)
                    }
                }
                .accessibilityElement(children: .combine)
            }
            if self.history.coverage.hasMore {
                Text("Showing the latest 25 qualified review requests. Earlier history is not included.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text("This history does not indicate which requests can currently be acted on.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
