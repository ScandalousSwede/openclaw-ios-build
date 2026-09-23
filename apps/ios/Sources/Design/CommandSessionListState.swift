import Foundation
import Observation
import OpenClawChatUI

/// One in-memory list for Home and its Sessions destination. Never crosses gateway or credential ownership.
@MainActor
@Observable
final class CommandSessionListState {
    static let fetchLimit = 200

    struct Owner: Hashable {
        let gatewayID: String
        let credentialGeneration: UInt64
        let isDemo: Bool
    }

    struct RefreshID: Hashable {
        let owner: Owner?
        let available: Bool
        let active: Bool
        let sessionKey: String
    }

    private var owner: Owner?
    private var sessions: [OpenClawChatSessionEntry] = []
    private var hasSnapshot = false
    private var requestID: UUID?
    private(set) var isLoading = false
    private(set) var refreshFailed = false

    func entries(for owner: Owner?) -> [OpenClawChatSessionEntry] {
        guard owner != nil, owner == self.owner else { return [] }
        return self.sessions
    }

    func canOpen(sessionKey: String, renderedOwner: Owner?, currentOwner: Owner?) -> Bool {
        renderedOwner != nil && renderedOwner == currentOwner && renderedOwner == self.owner
            && self.sessions.contains { $0.key == sessionKey }
    }

    func notice(for owner: Owner?, available: Bool) -> String? {
        guard owner != nil, owner == self.owner else { return nil }
        if !available, self.hasSnapshot {
            return "Showing the last session list. It will refresh when the connection returns."
        }
        guard self.refreshFailed else { return nil }
        return self.hasSnapshot
            ? "Couldn’t refresh sessions. Your last list is still here."
            : "Couldn’t load sessions. Reopen this page to try again."
    }

    func emptyTitle(for owner: Owner?, available: Bool) -> String {
        guard available else { return "Gateway offline" }
        guard owner != nil, owner == self.owner else { return "Sessions not loaded" }
        if self.isLoading { return "Loading sessions" }
        if self.refreshFailed, !self.hasSnapshot { return "Sessions unavailable" }
        return self.hasSnapshot ? "No recent sessions" : "Sessions not loaded"
    }

    func refresh(
        owner: Owner?,
        available: Bool,
        currentOwner: () -> Owner?,
        load: () async throws -> [OpenClawChatSessionEntry]) async
    {
        guard !Task.isCancelled, currentOwner() == owner else { return }
        if self.owner != owner {
            self.owner = owner
            self.sessions = []
            self.hasSnapshot = false
            self.refreshFailed = false
        }
        // An offline transition also retires any non-cooperative request still returning from the old socket.
        let requestID = UUID()
        self.requestID = requestID
        self.isLoading = false
        guard owner != nil, available else { return }
        self.isLoading = true
        self.refreshFailed = false
        defer {
            if self.requestID == requestID {
                self.isLoading = false
            }
        }
        do {
            let sessions = try await load()
            guard !Task.isCancelled, self.requestID == requestID, currentOwner() == owner else { return }
            self.sessions = Array(sessions.prefix(Self.fetchLimit))
            self.hasSnapshot = true
        } catch {
            guard !Task.isCancelled, self.requestID == requestID, currentOwner() == owner else { return }
            self.refreshFailed = true
        }
    }
}

extension NodeAppModel {
    var commandSessionListOwner: CommandSessionListState.Owner? {
        if self.isAppleReviewDemoModeEnabled {
            return .init(gatewayID: "", credentialGeneration: self.chatOutboxOwnerGeneration, isDemo: true)
        }
        guard let gatewayID = self.chatOutboxGatewayOwnerID else { return nil }
        return .init(gatewayID: gatewayID, credentialGeneration: self.chatOutboxOwnerGeneration, isDemo: false)
    }

    var isCommandSessionListAvailable: Bool {
        self.isAppleReviewDemoModeEnabled || self.isOperatorGatewayConnected
    }

    func commandSessionListRefreshID(active: Bool) -> CommandSessionListState.RefreshID {
        .init(
            owner: self.commandSessionListOwner,
            available: self.isCommandSessionListAvailable,
            active: active,
            sessionKey: self.chatSessionKey)
    }

    func refreshCommandSessions(_ state: CommandSessionListState, active: Bool) async {
        let owner = self.commandSessionListOwner
        await state.refresh(
            owner: owner,
            available: active && self.isCommandSessionListAvailable,
            currentOwner: { self.commandSessionListOwner })
        {
            guard let owner else { throw CancellationError() }
            if owner.isDemo {
                return try await AppleReviewDemoChatTransport()
                    .listSessions(limit: CommandSessionListState.fetchLimit).sessions
            }
            // Bind the read to the actual selected gateway/socket, not merely the current UI's gateway label.
            guard let route = await self.operatorSession.currentRoute(ifGatewayID: owner.gatewayID) else {
                throw CancellationError()
            }
            let params = try IOSGatewayChatTransport.makeListSessionsParamsJSON(
                limit: CommandSessionListState.fetchLimit)
            let data = try await self.operatorSession.request(
                method: "sessions.list", paramsJSON: params, timeoutSeconds: 15, ifCurrentRoute: route)
            return try JSONDecoder().decode(OpenClawChatSessionsListResponse.self, from: data).sessions
        }
    }
}
