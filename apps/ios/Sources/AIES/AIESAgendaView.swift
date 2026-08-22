import SwiftUI

/// Epistemically explicit AIES agenda summary. The view is intentionally not
/// installed until a server-owned agenda fetch surface is available.
struct AIESAgendaSummaryView: View {
    let presentation: AIESAgendaPresentation
    var displayTimezone: TimeZone = .autoupdatingCurrent

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("AIES agenda")
                .font(.headline)
            Text(self.presentation.statusMessage)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if let fetchedAt = self.presentation.fetchedAt {
                Text(AIESAgendaTimeRendering.lastUpdated(fetchedAt, displayTimezone: self.displayTimezone))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(Array(self.presentation.items.prefix(8))) { event in
                VStack(alignment: .leading, spacing: 2) {
                    Text(event.title)
                        .font(.subheadline.weight(.semibold))
                    if let display = try? AIESAgendaTimeRendering.display(
                        for: event,
                        deviceTimezone: self.displayTimezone)
                    {
                        Text(display.eventTime)
                            .font(.caption)
                        if let deviceTime = display.deviceTime {
                            Text("Your time: \(deviceTime)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        Text("Time unavailable")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
    }
}
