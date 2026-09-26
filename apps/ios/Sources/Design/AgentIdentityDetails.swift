import OpenClawProtocol
import SwiftUI

/// A read-only copy of the roster row preserves the opened identity across roster refreshes.
struct AgentIdentitySnapshot: Hashable {
    let id: String
    let name: String
    let model: String?
    let workspace: String?
    let runtime: String?

    init(agent: AgentSummary) {
        self.id = agent.id
        self.name = Self.nonEmpty(agent.name) ?? "Unnamed agent"
        self.model = ["primary", "name", "id", "model"].lazy
            .compactMap { Self.nonEmpty(agent.model?[$0]?.value as? String) }.first
        self.workspace = Self.nonEmpty(agent.workspace)
        self.runtime = Self.nonEmpty(agent.agentruntime?["id"]?.value as? String)
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }
}

struct AgentIdentityDetails: View {
    let snapshot: AgentIdentitySnapshot
    @State private var technicalDetailsExpanded: Bool

    init(snapshot: AgentIdentitySnapshot, technicalDetailsExpanded: Bool = false) {
        self.snapshot = snapshot
        self._technicalDetailsExpanded = State(initialValue: technicalDetailsExpanded)
    }

    var body: some View {
        ZStack {
            OpenClawProBackground()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ProCard {
                        VStack(alignment: .leading, spacing: 12) {
                            Text(self.snapshot.name)
                                .font(.title2.weight(.bold))
                                .fixedSize(horizontal: false, vertical: true)
                                .textSelection(.enabled)
                            self.detail("Model reported by gateway", value: self.snapshot.model)
                        }
                    }
                    Text("Details from the gateway roster row opened in this view.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    ProCard {
                        DisclosureGroup("Technical details", isExpanded: self.$technicalDetailsExpanded) {
                            VStack(alignment: .leading, spacing: 12) {
                                self.detail("Agent ID", value: self.snapshot.id)
                                self.detail("Workspace", value: self.snapshot.workspace)
                                self.detail("Runtime reported by gateway", value: self.snapshot.runtime)
                            }
                            .padding(.top, 12)
                        }
                    }
                }
                .padding(.horizontal, OpenClawProMetric.pagePadding)
                .padding(.vertical, 18)
            }
            .safeAreaPadding(.bottom, OpenClawProMetric.bottomScrollInset)
        }
        .navigationTitle("Agent details")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func detail(_ label: String, value: String?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value ?? "Not provided by the roster.")
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
