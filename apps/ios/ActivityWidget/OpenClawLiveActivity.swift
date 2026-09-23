import ActivityKit
import SwiftUI
import WidgetKit

struct OpenClawLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: OpenClawActivityAttributes.self) { context in
            self.lockScreenView(context: context)
                .widgetURL(context.attributes.taskReference?.url)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    self.statusDot(state: context.state)
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(self.statusText(context))
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(2)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    self.trailingView(state: context.state)
                }
            } compactLeading: {
                self.statusDot(state: context.state)
            } compactTrailing: {
                self.compactStatusIcon(state: context.state)
            } minimal: {
                self.statusDot(state: context.state)
            }
            .widgetURL(context.attributes.taskReference?.url)
        }
    }

    private func lockScreenView(context: ActivityViewContext<OpenClawActivityAttributes>) -> some View {
        HStack(spacing: 10) {
            self.statusIcon(state: context.state)
                .frame(width: 30, height: 30)
                .background(.thinMaterial, in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                // Session and task activities belong to the same Argus client.
                Text("Argus")
                    .font(.subheadline.bold())
                    .lineLimit(1)
                Text(self.statusText(context))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            self.trailingView(state: context.state)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func trailingView(state: OpenClawActivityAttributes.ContentState) -> some View {
        self.statusIcon(state: state)
            .font(.system(size: 16, weight: .semibold))
            .frame(width: 28, height: 28)
    }

    private func statusDot(state: OpenClawActivityAttributes.ContentState) -> some View {
        Circle()
            .fill(self.dotColor(state: state))
            .frame(width: 6, height: 6)
    }

    private func compactStatusIcon(state: OpenClawActivityAttributes.ContentState) -> some View {
        self.statusIcon(state: state)
            .font(.system(size: 12, weight: .semibold))
            .frame(width: 18, height: 18)
    }

    @ViewBuilder
    private func statusIcon(state: OpenClawActivityAttributes.ContentState) -> some View {
        if let task = state.task {
            Image(systemName: self.taskIcon(task))
                .foregroundStyle(self.dotColor(state: state))
        } else if state.isConnecting {
            Image(systemName: "arrow.triangle.2.circlepath")
                .foregroundStyle(.cyan)
        } else if state.isDisconnected {
            Image(systemName: "wifi.slash")
                .foregroundStyle(.red)
        } else if state.isIdle {
            Image(systemName: "checkmark")
                .foregroundStyle(.green)
        } else {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        }
    }

    private func dotColor(state: OpenClawActivityAttributes.ContentState) -> Color {
        if let task = state.task {
            if task.trackingEnded { return .secondary }
            switch task.phase {
            case .queued, .running: return .cyan
            case .succeeded: return .green
            case .blocked: return .orange
            case .failed, .timedOut, .lost: return .red
            case .cancelled: return .secondary
            }
        }
        if state.isDisconnected { return .red }
        if state.isConnecting { return .cyan }
        if state.isIdle { return .green }
        return .orange
    }

    private func statusText(_ context: ActivityViewContext<OpenClawActivityAttributes>) -> String {
        guard let task = context.state.task else { return context.state.statusText }
        if task.phase.isTerminal { return task.phase.headline }
        if task.trackingEnded { return "Tracking ended" }
        if context.isStale { return "Tracking period ended. Open Argus to check." }
        return task.phase.headline
    }

    private func taskIcon(_ task: ArgusTaskActivityState) -> String {
        if task.trackingEnded && !task.phase.isTerminal { return "pause.circle" }
        switch task.phase {
        case .queued: return "clock"
        case .running: return "arrow.triangle.2.circlepath"
        case .succeeded: return "checkmark"
        case .blocked: return "exclamationmark.triangle"
        case .failed, .timedOut, .lost: return "exclamationmark.circle"
        case .cancelled: return "xmark.circle"
        }
    }
}
