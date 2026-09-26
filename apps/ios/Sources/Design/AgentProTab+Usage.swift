import OpenClawKit
import OpenClawProtocol
import SwiftUI

extension AgentProTab {
    var usageTotalsCard: some View {
        ProCard(radius: AgentLayout.cardRadius) {
            VStack(alignment: .leading, spacing: 12) {
                AgentToolsMetricHeading(title: "Totals", value: (self.overview?.usage?.days).map { "\($0)d" } ?? "Unavailable", color: OpenClawBrand.accent)
                AgentToolsMetricRow {
                    self.detailMetric(label: "Reported cost", value: (self.overview?.usage?.totalCost).map(Self.currency) ?? "Unavailable")
                    self.detailMetric(label: "Tokens", value: self.usageTokenValue)
                    self.detailMetric(label: "Cache", value: self.usageCacheValue)
                }
                if let usage = self.overview?.usage {
                    Text(usage.costCoverageText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.horizontal, OpenClawProMetric.pagePadding)
    }

    var usageTokenValue: String {
        guard let tokens = self.overview?.usage?.totalTokens else { return "Unavailable" }
        return Self.compactNumber(tokens)
    }

    var usageCacheValue: String {
        guard let cacheStatus = self.normalized(self.overview?.usage?.cacheStatus?["status"]?.value as? String) else {
            return "Not reported"
        }
        return cacheStatus
    }

    var usageDailyList: some View {
        VStack(alignment: .leading, spacing: 8) {
            ProSectionHeader(title: "Daily")
            ProCard(padding: 0, radius: AgentLayout.cardRadius) {
                let days = self.overview?.usage?.daily ?? []
                if days.isEmpty {
                    self.emptyDetailRow(
                        icon: "chart.bar",
                        title: self.usageDailyEmptyTitle,
                        detail: self.usageDailyEmptyDetail)
                        .padding(14)
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(days.prefix(14).enumerated()), id: \.element.date) { index, day in
                            self.usageDayRow(day)
                            if index < min(days.count, 14) - 1 {
                                Divider().padding(.leading, 60)
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, OpenClawProMetric.pagePadding)
        }
    }

    var usageDailyEmptyTitle: String {
        self.overview?.usage?.daily != nil ? "No daily usage reported" : "Daily usage unavailable"
    }

    var usageDailyEmptyDetail: String {
        guard let usage = self.overview?.usage else { return "Usage could not load at this check." }
        return usage.daily != nil
            ? "The gateway returned an empty daily usage list at this check."
            : "The gateway did not report daily usage rows."
    }

    func usageDayTokenLabel(_ day: CostUsageDailyEntryLite) -> String {
        day.totalTokens.map { "\(Self.compactNumber($0)) tokens" } ?? "Tokens not reported"
    }

    func usageDayCostLabel(_ day: CostUsageDailyEntryLite) -> String {
        day.totalCost.map { "Reported cost \(Self.currency($0))" } ?? "Cost not reported"
    }

    func usageDayRow(_ day: CostUsageDailyEntryLite) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            AgentToolsMetricRow {
                HStack(spacing: 12) {
                    ProIconBadge(systemName: "calendar", color: OpenClawBrand.accent)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(day.date)
                            .font(.subheadline.weight(.semibold))
                        Text(self.usageDayTokenLabel(day))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                Text(self.usageDayCostLabel(day))
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(OpenClawBrand.accent)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(day.costCoverageText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 14)
    }
}
