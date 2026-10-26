import SwiftUI

struct ArgusRoutinePermissionPresentation: Equatable {
    struct Field: Equatable, Identifiable {
        let label: String
        let value: String

        var id: String {
            self.label
        }
    }

    let title: String
    let status: String
    let question: String
    let selectedOption: String
    let fields: [Field]
    let actionsUnavailableReason: String

    static let morningBriefing = ArgusRoutinePermissionPresentation(
        title: "Morning briefing",
        status: "Not yet authorized · illustrative",
        question: "Allow Argus to deliver your morning briefing?",
        selectedOption: "Always allow this routine",
        fields: [
            Field(label: "Schedule and timezone", value: "Not loaded"),
            Field(label: "Recipient and channel", value: "Not loaded"),
            Field(label: "Data and source classes", value: "Not loaded"),
            Field(label: "Allowed effect", value: "Not loaded"),
            Field(label: "Policy revision and effective window", value: "Not loaded"),
            Field(label: "Last qualified delivery", value: "Not loaded"),
        ],
        actionsUnavailableReason:
            "Actions remain unavailable until the authenticated policy, enabled schedule, scope, and current receipt load together.")
}

struct ArgusRoutinePermissionView: View {
    let presentation: ArgusRoutinePermissionPresentation

    init(presentation: ArgusRoutinePermissionPresentation = .morningBriefing) {
        self.presentation = presentation
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ProSectionHeader(title: self.presentation.title, uppercase: false)
            ProCard(tint: OpenClawBrand.warn, radius: SettingsLayout.cardRadius) {
                VStack(alignment: .leading, spacing: 10) {
                    Label(self.presentation.status, systemImage: "clock.badge.exclamationmark")
                        .font(.headline)
                        .foregroundStyle(OpenClawBrand.warn)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("No verified standing permission or enabled schedule is loaded. This screen cannot schedule, send, or unfreeze Argus.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, OpenClawProMetric.pagePadding)

            ProSectionHeader(title: "Permission review", uppercase: false)
            ProCard(radius: SettingsLayout.cardRadius) {
                VStack(alignment: .leading, spacing: 12) {
                    Text(self.presentation.question)
                        .font(.title3.weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    Label {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(self.presentation.selectedOption)
                                .font(.headline)
                            Text("Illustrative selection only. It is not an authenticated grant.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(OpenClawBrand.accent)
                    }
                    Text("Exact routine bindings must load before a durable owner decision can be recorded.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, OpenClawProMetric.pagePadding)

            ProSectionHeader(title: "Exact scope", uppercase: false)
            ProCard(padding: 0, radius: SettingsLayout.cardRadius) {
                VStack(spacing: 0) {
                    ForEach(Array(self.presentation.fields.enumerated()), id: \.element.id) { index, field in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(field.label)
                                .font(.subheadline.weight(.semibold))
                                .fixedSize(horizontal: false, vertical: true)
                            Text(field.value)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                        .accessibilityElement(children: .combine)
                        if index < self.presentation.fields.count - 1 {
                            Divider()
                        }
                    }
                }
            }
            .padding(.horizontal, OpenClawProMetric.pagePadding)

            ProSectionHeader(title: "Routine controls", uppercase: false)
            ProCard(radius: SettingsLayout.cardRadius) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(self.presentation.actionsUnavailableReason)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    self.unavailableAction("Authorize this routine", systemImage: "checkmark.shield")
                    self.unavailableAction("Inspect active permission", systemImage: "doc.text.magnifyingglass")
                    self.unavailableAction("Revoke permission", systemImage: "xmark.shield")
                    Text("Quiet hours and deduplication remain source-controlled. A paused or frozen schedule stays paused even if permission is later granted.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, OpenClawProMetric.pagePadding)
        }
    }

    private func unavailableAction(_ title: String, systemImage: String) -> some View {
        Button(action: {}) {
            Label(title, systemImage: systemImage)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        }
        .buttonStyle(.bordered)
        .disabled(true)
        .accessibilityHint(self.presentation.actionsUnavailableReason)
    }
}
