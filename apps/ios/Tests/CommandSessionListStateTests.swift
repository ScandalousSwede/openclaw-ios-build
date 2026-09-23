import Foundation
import OpenClawChatUI
import Testing
@testable import OpenClaw

@MainActor
struct CommandSessionListStateTests {
    private let owner = CommandSessionListState.Owner(gatewayID: "fixture-gateway", credentialGeneration: 0, isDemo: false)

    private func entries(_ key: String) throws -> [OpenClawChatSessionEntry] {
        let data = try JSONSerialization.data(withJSONObject: [["key": key, "displayName": "Synthetic session"]])
        return try JSONDecoder().decode([OpenClawChatSessionEntry].self, from: data)
    }

    @Test func `failed or never loaded list is not reported as empty history`() async {
        let state = CommandSessionListState()
        #expect(state.emptyTitle(for: self.owner, available: true) == "Sessions not loaded")
        await state.refresh(owner: self.owner, available: true, currentOwner: { self.owner }) { throw Failure.expected }
        #expect(state.emptyTitle(for: self.owner, available: true) == "Sessions unavailable")
        await state.refresh(owner: self.owner, available: true, currentOwner: { self.owner }) { [] }
        #expect(state.emptyTitle(for: self.owner, available: true) == "No recent sessions")
        await state.refresh(owner: nil, available: true, currentOwner: { nil }) {
            Issue.record("No selected owner must not issue a session request")
            return []
        }
        #expect(state.emptyTitle(for: nil, available: true) == "Sessions not loaded")
    }

    @Test func `same owner retains sessions across disconnect and failed refresh then accepts fresh data`() async throws {
        let state = CommandSessionListState()
        let old = try self.entries("fixture-old")
        await state.refresh(owner: self.owner, available: true, currentOwner: { self.owner }) { old }
        await state.refresh(owner: self.owner, available: false, currentOwner: { self.owner }) {
            Issue.record("Offline refresh must not request sessions")
            return []
        }
        #expect(state.entries(for: self.owner) == old)
        #expect(state.notice(for: self.owner, available: false)?.contains("last session list") == true)
        await state.refresh(owner: self.owner, available: true, currentOwner: { self.owner }) { throw Failure.expected }
        #expect(state.entries(for: self.owner) == old)
        #expect(state.refreshFailed)
        #expect(state.notice(for: self.owner, available: true)?.contains("last list") == true)
        let fresh = try self.entries("fixture-new")
        await state.refresh(owner: self.owner, available: true, currentOwner: { self.owner }) { fresh }
        #expect(state.entries(for: self.owner) == fresh)
        #expect(!state.refreshFailed && !state.isLoading)
        #expect(state.notice(for: self.owner, available: true) == nil)
    }

    @Test func `gateway credential demo and absent owner boundaries clear the list and fence old taps`() async throws {
        let state = CommandSessionListState()
        let entries = try self.entries("same-key-on-two-gateways")
        let successors: [CommandSessionListState.Owner?] = [
            .init(gatewayID: "other-gateway", credentialGeneration: 0, isDemo: false),
            .init(gatewayID: self.owner.gatewayID, credentialGeneration: 1, isDemo: false),
            .init(gatewayID: self.owner.gatewayID, credentialGeneration: 0, isDemo: true),
            nil,
        ]
        for next in successors {
            await state.refresh(owner: self.owner, available: true, currentOwner: { self.owner }) { entries }
            #expect(state.entries(for: next).isEmpty) // Even before the next SwiftUI task starts.
            #expect(!state.canOpen(sessionKey: entries[0].key, renderedOwner: self.owner, currentOwner: next))
            await state.refresh(owner: next, available: false, currentOwner: { next }) { entries }
            #expect(state.entries(for: next).isEmpty)
            #expect(state.entries(for: self.owner).isEmpty)
            #expect(state.notice(for: next, available: false) == nil)
            await state.refresh(owner: next, available: true, currentOwner: { next }) { entries }
            #expect(!state.canOpen(sessionKey: entries[0].key, renderedOwner: self.owner, currentOwner: next))
            #expect(state.canOpen(sessionKey: entries[0].key, renderedOwner: next, currentOwner: next) == (next != nil))
        }
    }

    @Test func `late response checks current owner before another view task selects it`() async throws {
        let state = CommandSessionListState()
        var current: CommandSessionListState.Owner? = self.owner
        let pending = PendingLoad()
        let task = Task {
            await state.refresh(owner: self.owner, available: true, currentOwner: { current }) {
                try await pending.load()
            }
        }
        await pending.waitUntilStarted()
        current = .init(gatewayID: "replacement", credentialGeneration: 0, isDemo: false)
        pending.finish(.success(try self.entries("old-response")))
        await task.value
        #expect(state.entries(for: self.owner).isEmpty)
        #expect(state.entries(for: current).isEmpty)
        #expect(!state.isLoading && !state.refreshFailed)
    }

    @Test(arguments: [true, false])
    func `newer same owner result survives late success or failure`(lateFailure: Bool) async throws {
        let state = CommandSessionListState()
        let pending = PendingLoad()
        let task = Task {
            await state.refresh(owner: self.owner, available: true, currentOwner: { self.owner }) {
                try await pending.load()
            }
        }
        await pending.waitUntilStarted()
        let latest = try self.entries("latest")
        await state.refresh(owner: self.owner, available: true, currentOwner: { self.owner }) { latest }
        pending.finish(lateFailure ? .failure(Failure.expected) : .success(try self.entries("superseded")))
        await task.value
        #expect(state.entries(for: self.owner) == latest)
        #expect(!state.isLoading && !state.refreshFailed)
    }

    @Test func `cancelled noncooperative response cannot replace retained data`() async throws {
        let state = CommandSessionListState()
        let old = try self.entries("retained")
        await state.refresh(owner: self.owner, available: true, currentOwner: { self.owner }) { old }
        let pending = PendingLoad()
        let task = Task {
            await state.refresh(owner: self.owner, available: true, currentOwner: { self.owner }) {
                try await pending.load()
            }
        }
        await pending.waitUntilStarted()
        task.cancel()
        pending.finish(.success(try self.entries("cancelled")))
        await task.value
        #expect(state.entries(for: self.owner) == old)
        #expect(!state.isLoading && !state.refreshFailed)
    }

    @Test func `offline transition retires pending response without erasing the loaded snapshot`() async throws {
        let state = CommandSessionListState()
        let old = try self.entries("retained")
        await state.refresh(owner: self.owner, available: true, currentOwner: { self.owner }) { old }
        let pending = PendingLoad()
        let task = Task {
            await state.refresh(owner: self.owner, available: true, currentOwner: { self.owner }) {
                try await pending.load()
            }
        }
        await pending.waitUntilStarted()
        await state.refresh(owner: self.owner, available: false, currentOwner: { self.owner }) { [] }
        pending.finish(.success(try self.entries("retired-socket")))
        await task.value
        #expect(state.entries(for: self.owner) == old)
        #expect(!state.isLoading)
    }

    private enum Failure: Error { case expected }

    @MainActor
    private final class PendingLoad {
        private var completion: CheckedContinuation<[OpenClawChatSessionEntry], any Error>?
        private var started: CheckedContinuation<Void, Never>?

        func load() async throws -> [OpenClawChatSessionEntry] {
            try await withCheckedThrowingContinuation { continuation in
                self.completion = continuation
                self.started?.resume()
                self.started = nil
            }
        }

        func waitUntilStarted() async {
            if self.completion != nil { return }
            await withCheckedContinuation { self.started = $0 }
        }

        func finish(_ result: Result<[OpenClawChatSessionEntry], any Error>) {
            self.completion?.resume(with: result)
            self.completion = nil
        }
    }
}
