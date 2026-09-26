import Foundation
import OpenClawKit
import OpenClawProtocol
import SwiftUI

extension AgentProTab {
    var cronStatusCard: some View {
        ProCard(radius: AgentLayout.cardRadius) {
            VStack(alignment: .leading, spacing: 12) {
                AgentToolsMetricHeading(title: "Scheduler",
                    value: (self.overview?.cronStatus).map { $0.enabled ? "on" : "off" } ?? "Unavailable",
                    color: self.cronColor)
                AgentToolsMetricRow {
                    // cron.list is bounded to eight rows; it cannot replace the scheduler's total.
                    let jobCount = self.overview?.cronStatus?.jobs
                    self.detailMetric(label: "Jobs", value: jobCount.map(String.init) ?? "Unavailable")
                    self.detailMetric(label: "Next", value: self.cronNextRunLabel)
                }
                if let cronActionStatusText {
                    Text(cronActionStatusText)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.horizontal, OpenClawProMetric.pagePadding)
    }

    var cronNextRunLabel: String {
        guard let status = self.overview?.cronStatus else { return "Unavailable" }
        guard let nextWakeAtMs = status.nextwakeatms else { return "none" }
        return Self.relativeTime(fromMilliseconds: nextWakeAtMs)
    }

    func cronJobsList(limit: Int?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ProSectionHeader(title: "Jobs")
            ProCard(padding: 0, radius: AgentLayout.cardRadius) {
                let jobs = self.sortedCronJobs
                let visible = limit.map { Array(jobs.prefix($0)) } ?? jobs
                if visible.isEmpty {
                    self.emptyCronRow
                        .padding(14)
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(visible.enumerated()), id: \.element.id) { index, job in
                            self.cronJobDetailRow(job)
                            if index < visible.count - 1 {
                                Divider().padding(.leading, 60)
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, OpenClawProMetric.pagePadding)
        }
    }

    var sortedCronJobs: [CronJob] {
        (self.overview?.cronJobs ?? [])
            .sorted { lhs, rhs in
                let lhsNext = AgentProValueReader.intValue(lhs.state["nextRunAtMs"])
                let rhsNext = AgentProValueReader.intValue(rhs.state["nextRunAtMs"])
                switch (lhsNext, rhsNext) {
                case let (lhsNext?, rhsNext?): return lhsNext < rhsNext
                case (_?, nil): return true
                case (nil, _?): return false
                case (nil, nil): return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
                }
            }
    }

    func cronJobDetailRow(_ job: CronJob) -> some View {
        let busy = self.cronActionBusyIDs.contains(job.id)
        return HStack(alignment: .top, spacing: 12) {
            ProIconBadge(
                systemName: job.enabled ? "clock.arrow.circlepath" : "pause.circle",
                color: job.enabled ? OpenClawBrand.accent : .secondary)
            VStack(alignment: .leading, spacing: 4) {
                Text(job.name)
                    .font(.subheadline.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                Text(self.cronJobDetail(job))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Text(self.cronScheduleSummary(job))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                self.cronJobActionButtons(job, busy: busy)
            }
            Spacer(minLength: 8)
            if busy {
                ProgressView()
                    .progressViewStyle(.circular)
                    .controlSize(.small)
            } else {
                Text(self.cronJobState(job))
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(job.enabled ? OpenClawBrand.accent : .secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 14)
    }

    func cronJobActionButtons(_ job: CronJob, busy: Bool) -> some View {
        let runButton = Button {
            self.pendingCronAction = CronActionConfirmation(job: job, kind: .run)
        } label: {
            Label("Run now", systemImage: "play.fill")
                .frame(minWidth: 44, minHeight: 44)
        }
        let scheduleButton = Button {
            self.pendingCronAction = CronActionConfirmation(job: job, kind: job.enabled ? .pause : .enable)
        } label: {
            Label(job.enabled ? "Pause" : "Enable", systemImage: job.enabled ? "pause.fill" : "checkmark")
                .frame(minWidth: 44, minHeight: 44)
        }
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                runButton
                scheduleButton
            }
            VStack(alignment: .leading, spacing: 8) {
                runButton
                scheduleButton
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled(busy || !self.liveGatewayConnected)
    }

    // Confirmation records local intent, not a per-job permission or policy classification.
    // Gateway access checks and actual response disposition remain authoritative.
    struct CronActionConfirmation {
        enum Kind { case run, pause, enable }
        let job: CronJob
        let kind: Kind

        var title: String {
            switch self.kind {
            case .run: "Run \(self.job.name) now?"
            case .pause: "Pause \(self.job.name)?"
            case .enable: "Enable \(self.job.name)?"
            }
        }

        var buttonTitle: String {
            switch self.kind {
            case .run: "Run now"
            case .pause: "Pause schedule"
            case .enable: "Enable schedule"
            }
        }

        var message: String {
            let consequence: String = switch self.kind {
            case .run:
                "Send a manual run request now, even if this job's schedule is paused. Its configured actions may run. A queued request does not confirm completion."
            case .pause:
                "Stop future scheduled runs. This does not cancel a run that has already started."
            case .enable:
                "Allow future scheduled runs. This does not send a manual run request."
            }
            let schedule = self.job.enabled ? "Enabled" : "Paused"
            let running = AgentProValueReader.intValue(self.job.state["runningAtMs"]) != nil
                ? "Gateway reported an active run."
                : "Running state not reported."
            return "\(consequence)\n\nSchedule: \(schedule). \(running)\nJob ID: \(self.job.id)"
        }

        func matches(_ current: CronJob) -> Bool {
            current.id == self.job.id && current.updatedatms == self.job.updatedatms &&
                current.name == self.job.name && current.enabled == self.job.enabled
        }
    }

    @MainActor
    func confirmCronAction(_ confirmation: CronActionConfirmation) async {
        guard self.liveGatewayConnected else {
            self.cronActionStatusText = "Connection lost. No job request was sent."
            return
        }
        // A refreshed local job must match what the user confirmed. This is not an
        // atomic server revision check; the mutation RPC still enforces its own contract.
        guard let current = self.overview?.cronJobs?.first(where: { $0.id == confirmation.job.id }),
              confirmation.matches(current) else {
            self.cronActionStatusText = "The job changed or is no longer in this view. Refresh and review it again. No request was sent."
            return
        }
        switch confirmation.kind {
        case .run: await self.runCronJob(current)
        case .pause: await self.setCronJob(current, enabled: false)
        case .enable: await self.setCronJob(current, enabled: true)
        }
    }

    @MainActor
    func runCronJob(_ job: CronJob) async {
        await self.runCronAction(job) {
            let params = CronRunParams(id: job.id, mode: "force")
            let data = try await self.requestGateway(method: "cron.run", params: params, timeoutSeconds: 20)
            return Self.cronRunResponseMessage(data, name: job.name)
        }
    }

    @MainActor
    func setCronJob(_ job: CronJob, enabled: Bool) async {
        await self.runCronAction(job) {
            let params = CronUpdateParams(id: job.id, patch: CronUpdatePatch(enabled: enabled))
            let data = try await self.requestGateway(method: "cron.update", params: params, timeoutSeconds: 20)
            guard let updated = try? JSONDecoder().decode(CronJob.self, from: data),
                  updated.id == job.id, updated.enabled == enabled else {
                return "The gateway returned without confirming the schedule change for \(job.name). Refresh its state."
            }
            return enabled ? "Enabled \(updated.name)." : "Paused \(updated.name). This does not cancel an active run."
        }
    }

    @MainActor
    func runCronAction(
        _ job: CronJob,
        action: () async throws -> String) async
    {
        guard self.liveGatewayConnected, !self.cronActionBusyIDs.contains(job.id) else { return }
        self.cronActionBusyIDs.insert(job.id)
        self.cronActionStatusText = nil
        defer { self.cronActionBusyIDs.remove(job.id) }
        do {
            self.cronActionStatusText = try await action()
            await self.refreshOverview(force: true)
        } catch {
            self.cronActionStatusText = Self.skillMutationMessage(error)
        }
    }

    private struct CronRunResponse: Decodable {
        let ok: Bool?
        let enqueued: Bool?
        let runId: String?
        let ran: Bool?
        let reason: String?
    }

    static func cronRunResponseMessage(_ data: Data, name: String) -> String {
        let unknown = "The gateway returned without confirming a run for \(name). Check run history before retrying."
        guard let result = try? JSONDecoder().decode(CronRunResponse.self, from: data),
              result.ok == true else { return unknown }
        if result.ran == false {
            switch result.reason {
            case "already-running": return "\(name) is already running; no new run was queued."
            case "not-due": return "\(name) was not due; no run was queued."
            case "invalid-spec": return "\(name) has an invalid job configuration; no run was queued."
            default: return "The gateway did not run \(name). Check run history for the reason."
            }
        }
        if result.enqueued == true,
           result.runId?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            return "Queued \(name). Check run history for the outcome."
        }
        if result.ran == true {
            return "The gateway reports that \(name) ran. Check run history for the outcome."
        }
        return unknown
    }

    func cronScheduleSummary(_ job: CronJob) -> String {
        guard let schedule = job.schedule.value as? [String: AnyCodable] else { return "Schedule configured" }
        if let expr = Self.stringValue(schedule["expr"]) {
            return "Cron \(expr)"
        }
        if let everyMs = AgentProValueReader.intValue(schedule["everyMs"]) {
            return "Every \(Self.duration(milliseconds: everyMs))"
        }
        if let kind = Self.stringValue(schedule["kind"]) {
            return kind
        }
        return "Schedule configured"
    }
}
