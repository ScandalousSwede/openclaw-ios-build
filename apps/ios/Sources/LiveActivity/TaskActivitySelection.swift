import Foundation
import SwiftUI

/// The existing registry listing is discovery, not proof of an activity binding
/// or fulfilled work. The exact projection is checked only after selection.
struct ArgusTaskActivityList: Decodable, Sendable {
    struct Item: Decodable, Equatable, Identifiable, Sendable {
        enum Status: String, Decodable, Sendable {
            case queued, running, completed, failed, cancelled
            case timedOut = "timed_out"

            var label: String {
                switch self {
                case .queued: "Queued"
                case .running: "Running"
                case .completed: "Execution ended; outcome not checked"
                case .failed: "Failed or lost"
                case .cancelled: "Cancelled"
                case .timedOut: "Timed out"
                }
            }
        }

        let taskId: String
        let title: String
        let status: Status
        let updatedAt: Int64
        var id: String { self.taskId }
    }

    let tasks: [Item]
    let nextCursor: String?

    func validate(after cursor: String?) throws {
        guard self.tasks.count <= 100,
              Set(self.tasks.map(\.taskId)).count == self.tasks.count,
              self.tasks.allSatisfy({
                  ArgusTaskActivityReference.validTaskID($0.taskId)
                      && !$0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                      && $0.title.utf8.count <= 4096
                      && (0...9_007_199_254_740_991).contains($0.updatedAt)
              }) else { throw ArgusOperationsError.invalidResponse }
        if let nextCursor {
            guard !nextCursor.isEmpty, nextCursor.utf8.allSatisfy({ (48...57).contains($0) }),
                  let offset = UInt64(nextCursor), offset <= 9_007_199_254_740_991,
                  offset > (cursor.flatMap(UInt64.init) ?? 0), !self.tasks.isEmpty
            else { throw ArgusOperationsError.invalidResponse }
        }
    }
}

extension ArgusTaskActivityReference {
    @MainActor
    static func discover(
        taskID: String,
        identity: () async throws -> ArgusEvidenceNotificationReference.GatewayIdentity,
        task: ([String: String]) async throws -> ArgusTaskActivityResponse,
        stillCurrent: () async -> Bool) async throws -> Self
    {
        guard Self.validTaskID(taskID), await stillCurrent() else { throw ArgusOperationsError.unavailable }
        let gateway = try await identity()
        guard await stillCurrent() else { throw ArgusOperationsError.unavailable }
        let response = try await task(["taskId": taskID])
        guard await stillCurrent() else { throw ArgusOperationsError.unavailable }
        try response.task.validate(taskID: taskID)
        guard let reference = Self(
            gatewayDeviceID: gateway.deviceId, taskID: response.task.taskId,
            requestID: response.task.invocationRequestId) else { throw ArgusOperationsError.invalidResponse }
        return reference
    }
}

@MainActor @Observable
final class ArgusTaskActivityListStore {
    private(set) var gatewayID: String?
    private(set) var items: [ArgusTaskActivityList.Item] = []
    private(set) var nextCursor: String?
    private(set) var unavailable = true
    private(set) var isLoading = false
    private(set) var selectionID: String?
    private(set) var selectionError: String?
    @ObservationIgnored private var generation = 0

    func selectGateway(_ gatewayID: String?) {
        guard self.gatewayID != gatewayID else { return }
        self.gatewayID = gatewayID
        self.items = []
        self.nextCursor = nil
        self.markUnavailable()
    }

    func markUnavailable() {
        self.generation += 1
        self.unavailable = true
        self.isLoading = false
        self.selectionID = nil
        self.selectionError = nil
    }

    func refresh(
        gatewayID: String, more: Bool = false,
        fetch: ([String: String]) async throws -> ArgusTaskActivityList) async
    {
        guard self.gatewayID == gatewayID, !self.isLoading, !Task.isCancelled else { return }
        if more, self.nextCursor == nil { return }
        let cursor = more ? self.nextCursor : nil
        let generation = self.generation
        self.isLoading = true
        defer { if generation == self.generation { self.isLoading = false } }
        do {
            let page = try await fetch(cursor.map { ["cursor": $0] } ?? [:])
            guard generation == self.generation, !Task.isCancelled else { return }
            try page.validate(after: cursor)
            var items = more ? self.items : []
            for item in page.tasks {
                if let index = items.firstIndex(where: { $0.id == item.id }) { items[index] = item }
                else { items.append(item) }
            }
            self.items = items
            self.nextCursor = page.nextCursor
            self.unavailable = false
        } catch {
            guard generation == self.generation, !Task.isCancelled else { return }
            self.unavailable = true
        }
    }

    func select(
        _ item: ArgusTaskActivityList.Item, gatewayID: String,
        resolve: () async throws -> ArgusTaskActivityReference) async -> ArgusTaskActivityRequest?
    {
        guard self.gatewayID == gatewayID, self.selectionID == nil, !self.unavailable,
              self.items.contains(item), !Task.isCancelled else { return nil }
        let generation = self.generation
        self.selectionID = item.id
        self.selectionError = nil
        defer { if generation == self.generation { self.selectionID = nil } }
        do {
            let reference = try await resolve()
            guard generation == self.generation, !Task.isCancelled,
                  self.items.contains(item) else { return nil }
            guard reference.taskID == item.id else { throw ArgusOperationsError.invalidResponse }
            return .init(reference: reference, gatewayOwnerID: gatewayID, title: item.title)
        } catch {
            guard generation == self.generation, !Task.isCancelled else { return nil }
            self.selectionError = "Activity context is unavailable for this task. Some task types do not have an activity binding. No action was submitted."
            return nil
        }
    }
}

struct ArgusTaskActivitySelection: View {
    @Environment(NodeAppModel.self) private var appModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var store = ArgusTaskActivityListStore()
    @State private var expanded = false
    @State private var visibleCount = 10

    var body: some View {
        CommandPanel(padding: 16) {
            DisclosureGroup("Task activity", isExpanded: self.$expanded) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Choose a task to check its exact activity context. This registry list does not cover every kind of work.")
                        .font(.subheadline).foregroundStyle(.secondary)
                    if self.store.unavailable {
                        Text(self.store.items.isEmpty
                            ? "Task activity is unavailable until it can be checked on the paired gateway."
                            : "Showing the last check. Reconnect and refresh before opening a task.")
                            .font(.subheadline)
                    }
                    if self.store.gatewayID == self.appModel.chatOutboxGatewayOwnerID {
                        ForEach(self.store.items.prefix(self.visibleCount)) { item in
                            Button { Task { await self.open(item) } } label: {
                                ArgusTaskActivityRow(item: item)
                            }
                            .buttonStyle(.plain)
                            .disabled(self.store.unavailable || self.store.selectionID != nil || !self.canRead)
                            Divider()
                        }
                    }
                    if let error = self.store.selectionError { Text(error).font(.subheadline) }
                    if self.store.isLoading || self.store.selectionID != nil { ProgressView("Checking task context") }
                    if !self.store.unavailable && self.store.items.isEmpty { Text("No tasks were returned by this registry.") }
                    Button("Refresh tasks") { Task { await self.refresh() } }
                        .disabled(!self.canRead || self.store.isLoading || self.store.selectionID != nil)
                    if self.visibleCount < self.store.items.count {
                        Button("Show more tasks") { self.visibleCount += 10 }
                    } else if self.store.nextCursor != nil {
                        Button("Load more tasks") { Task { await self.refresh(more: true) } }
                            .disabled(!self.canRead || self.store.isLoading || self.store.selectionID != nil)
                    }
                }
                .padding(.top, 10)
            }
        }
        .padding(.horizontal, OpenClawProMetric.pagePadding)
        .onDisappear { self.store.markUnavailable() }
        .task(id: "\(self.appModel.chatOutboxGatewayOwnerID ?? "none")|\(self.canRead)|\(self.expanded)") {
            self.store.selectGateway(self.appModel.chatOutboxGatewayOwnerID)
            self.store.markUnavailable()
            guard self.expanded, self.canRead else { return }
            await self.refresh()
        }
    }

    private var canRead: Bool {
        !self.appModel.isAppleReviewDemoModeEnabled && self.appModel.isOperatorGatewayConnected
            && self.scenePhase == .active
    }

    private func refresh(more: Bool = false) async {
        guard self.canRead, let owner = self.appModel.chatOutboxGatewayOwnerID else { return }
        let client = ArgusOperationsClient(session: self.appModel.operatorSession, gatewayID: owner)
        await self.store.refresh(gatewayID: owner, more: more) {
            try await client.request("tasks.list", params: $0, as: ArgusTaskActivityList.self)
        }
    }

    private func open(_ item: ArgusTaskActivityList.Item) async {
        guard self.canRead, let owner = self.appModel.chatOutboxGatewayOwnerID else { return }
        let session = self.appModel.operatorSession
        guard let route = await session.currentRoute(ifGatewayID: owner), self.canRead,
              self.appModel.chatOutboxGatewayOwnerID == owner else { return }
        let client = ArgusOperationsClient(session: session, gatewayID: owner, pinnedRoute: route)
        let request = await self.store.select(item, gatewayID: owner) {
            try await ArgusTaskActivityReference.discover(
                taskID: item.id,
                identity: { try await client.request(
                    "gateway.identity.get", params: [:], as: ArgusEvidenceNotificationReference.GatewayIdentity.self) },
                task: { try await client.request("tasks.activity.get", params: $0, as: ArgusTaskActivityResponse.self) },
                stillCurrent: {
                    guard await session.isCurrentRoute(route) else { return false }
                    return !Task.isCancelled && self.canRead && self.appModel.chatOutboxGatewayOwnerID == owner
                })
        }
        guard let request, await session.isCurrentRoute(route), self.canRead, !Task.isCancelled,
              self.appModel.chatOutboxGatewayOwnerID == owner else { return }
        self.appModel.openTaskActivity(request)
    }
}

struct ArgusTaskActivityRow: View {
    let item: ArgusTaskActivityList.Item

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(self.item.title).font(.headline).foregroundStyle(.primary)
            Text(self.item.status.label).font(.subheadline).foregroundStyle(.secondary)
            Text("Open task context").font(.subheadline).foregroundStyle(OpenClawBrand.accent)
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }
}
