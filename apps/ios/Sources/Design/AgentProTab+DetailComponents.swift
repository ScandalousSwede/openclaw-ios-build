import OpenClawKit
import OpenClawProtocol
import SwiftUI

extension AgentProTab {
    func detailMetric(label: String, value: String) -> some View {
        AgentToolsMetricTile(label: label, value: value)
    }

    func emptyDetailRow(icon: String, title: String, detail: String) -> some View {
        HStack(spacing: 12) {
            ProIconBadge(systemName: icon, color: .secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
        }
    }
}

/// Keep the existing dense metric row at ordinary text sizes; enlarged labels need full width.
struct AgentToolsMetricRow<Content: View>: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ViewBuilder let content: () -> Content

    var body: some View {
        if self.dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 10, content: self.content)
        } else {
            HStack(spacing: 10, content: self.content)
        }
    }
}

/// The same card heading/pill stays on separate full-width lines at accessibility sizes.
struct AgentToolsMetricHeading: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let title: String
    let value: String
    let color: Color

    var body: some View {
        if self.dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 8) {
                Text(self.title).font(.headline)
                ProValuePill(value: self.value, color: self.color)
            }
        } else {
            HStack {
                Text(self.title).font(.headline)
                Spacer()
                ProValuePill(value: self.value, color: self.color)
            }
        }
    }
}

struct AgentToolsMetricTile: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(self.label)
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(self.value)
                .font(.subheadline.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

/// Enlarged job content uses the full card width instead of a column between icon and status.
struct AgentToolsCronJobRow<Actions: View>: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let name: String
    let detail: String
    let schedule: String
    let state: String
    let enabled: Bool
    let busy: Bool
    @ViewBuilder let actions: () -> Actions

    var body: some View {
        Group {
            if self.dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .top) {
                        self.icon
                        Spacer(minLength: 8)
                        self.status
                    }
                    self.content
                }
            } else {
                HStack(alignment: .top, spacing: 12) {
                    self.icon
                    self.content
                    Spacer(minLength: 8)
                    self.status
                }
            }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 14)
    }

    private var icon: some View {
        ProIconBadge(systemName: self.enabled ? "clock.arrow.circlepath" : "pause.circle",
                     color: self.enabled ? OpenClawBrand.accent : .secondary)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(self.name)
                .font(.subheadline.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
            Text(self.detail).font(.caption).foregroundStyle(.secondary)
                .lineLimit(self.dynamicTypeSize.isAccessibilitySize ? nil : 2)
            Text(self.schedule).font(.caption2).foregroundStyle(.secondary)
                .lineLimit(self.dynamicTypeSize.isAccessibilitySize ? nil : 1)
            self.actions()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private var status: some View {
        if self.busy {
            ProgressView().progressViewStyle(.circular).controlSize(.small)
        } else {
            Text(self.state).font(.caption2.weight(.semibold))
                .foregroundStyle(self.enabled ? OpenClawBrand.accent : .secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
