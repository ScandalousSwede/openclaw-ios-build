import Foundation
import Testing
@testable import OpenClawChatUI

@Suite(.serialized)
struct OpenClawChatOutboxStorageTests {
    private struct Fixture: Sendable {
        let directoryURL: URL
        let databaseURL: URL
        let database: OpenClawChatOutboxDatabase
        let store: OpenClawChatOutboxStore
    }

    private func withFixture<T>(
        gatewayID: String = "gateway-a",
        _ body: (Fixture) async throws -> T) async throws -> T
    {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let databaseURL = directoryURL.appendingPathComponent(
            OpenClawChatOutboxDatabase.databaseFilename,
            isDirectory: false)
        let database = try OpenClawChatOutboxDatabase(databaseURL: databaseURL)
        let store = try await database.store(stableGatewayID: gatewayID)
        let fixture = Fixture(
            directoryURL: directoryURL,
            databaseURL: databaseURL,
            database: database,
            store: store)
        do {
            let result = try await body(fixture)
            try? await database.close()
            try? OpenClawChatOutboxDatabase.removeDatabaseFiles(at: databaseURL)
            try? FileManager.default.removeItem(at: directoryURL)
            return result
        } catch {
            try? await database.close()
            try? OpenClawChatOutboxDatabase.removeDatabaseFiles(at: databaseURL)
            try? FileManager.default.removeItem(at: directoryURL)
            throw error
        }
    }

    private func route(
        contract: String = "per-sender|main|main",
        verifiedAt: Date = Date(timeIntervalSince1970: 1_800_000_000))
        -> OpenClawChatOutboxRouteSnapshot
    {
        OpenClawChatOutboxRouteSnapshot(
            routingContract: contract,
            capabilities: ["chat-send-routing-contract", "chat.history", "chat.send"],
            operatorScopes: ["operator.read", "operator.talk.secrets", "operator.write"],
            verifiedAt: verifiedAt)
    }

    private func draft(
        id: String,
        route: OpenClawChatOutboxRouteSnapshot? = nil,
        text: String = "hello",
        attachments: [OpenClawChatOutboxAttachment] = [],
        createdAt: Date = Date(timeIntervalSince1970: 1_800_000_010))
        -> OpenClawChatOutboxDraft
    {
        OpenClawChatOutboxDraft(
            rawCommandID: id,
            sessionKey: "main",
            text: text,
            attachments: attachments,
            thinkingLevel: "off",
            route: route ?? self.route(),
            createdAt: createdAt)
    }

    private func attachment(
        name: String = "note.jpg",
        byteCount: Int = 32,
        byte: UInt8 = 0x41) -> OpenClawChatOutboxAttachment
    {
        OpenClawChatOutboxAttachment(
            type: "image",
            mimeType: "image/jpeg",
            fileName: name,
            data: Data(repeating: byte, count: byteCount))
    }

    private func expectError(
        _ expected: OpenClawChatOutboxError,
        operation: () async throws -> Void) async
    {
        do {
            try await operation()
            Issue.record("Expected \(expected), but the operation succeeded")
        } catch let error as OpenClawChatOutboxError {
            #expect(error == expected)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("clean install uses the final migration and hardened SQLite configuration")
    func cleanInstallAndConfiguration() async throws {
        try await self.withFixture { fixture in
            let state = try await fixture.database.debugState()
            #expect(state.journalMode.lowercased() == "wal")
            #expect(state.busyTimeoutMilliseconds == 5000)
            #expect(state.foreignKeysEnabled)
            #expect(state.secureDeleteEnabled)
            #expect(state.migrationIdentifiers == [
                OpenClawChatOutboxDatabase.finalMigrationIdentifier,
            ])

            let directoryValues = try fixture.directoryURL.resourceValues(
                forKeys: [.isExcludedFromBackupKey])
            let databaseValues = try fixture.databaseURL.resourceValues(
                forKeys: [.isExcludedFromBackupKey])
            #expect(directoryValues.isExcludedFromBackup == true)
            #expect(databaseValues.isExcludedFromBackup == true)
        }
    }

    @Test("verified route survives relaunch and queued payload remains FIFO")
    func relaunchRestoration() async throws {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let databaseURL = directoryURL.appendingPathComponent(
            OpenClawChatOutboxDatabase.databaseFilename,
            isDirectory: false)
        defer {
            try? OpenClawChatOutboxDatabase.removeDatabaseFiles(at: databaseURL)
            try? FileManager.default.removeItem(at: directoryURL)
        }
        let firstDatabase = try OpenClawChatOutboxDatabase(databaseURL: databaseURL)
        let firstStore = try await firstDatabase.store(stableGatewayID: "gateway-a")
        let route = self.route()
        try await firstStore.saveVerifiedRouteSnapshot(route)
        let first = try await firstStore.persistBeforeDraftClear(self.draft(id: "command-1"))
        let second = try await firstStore.persistBeforeDraftClear(self.draft(id: "command-2"))
        #expect(first.enqueueSequence < second.enqueueSequence)
        try await firstDatabase.close()

        let secondDatabase = try OpenClawChatOutboxDatabase(databaseURL: databaseURL)
        let secondStore = try await secondDatabase.store(stableGatewayID: "gateway-a")
        let restoredRoute = try await secondStore.loadVerifiedRouteSnapshot()
        let restored = try await secondStore.loadUnresolved(
            now: Date(timeIntervalSince1970: 1_800_000_020))
        #expect(restoredRoute == route)
        #expect(restored.map(\.rawCommandID) == ["command-1", "command-2"])
        #expect(restored[0].canonicalUserIdempotencyKey == "command-1:user")
        try await secondDatabase.close()
    }

    @Test("enqueue requires the separately persisted verified route")
    func routeSnapshotGate() async throws {
        try await self.withFixture { fixture in
            await self.expectError(.routeSnapshotUnavailable) {
                _ = try await fixture.store.persistBeforeDraftClear(self.draft(id: "missing-route"))
            }
            let firstRoute = self.route()
            try await fixture.store.saveVerifiedRouteSnapshot(firstRoute)
            let changedRoute = self.route(
                contract: "per-sender|main|other",
                verifiedAt: firstRoute.verifiedAt.addingTimeInterval(1))
            await self.expectError(.routeSnapshotChanged) {
                _ = try await fixture.store.persistBeforeDraftClear(
                    self.draft(id: "stale-route", route: changedRoute))
            }
            #expect(try await fixture.store.loadUnresolved().isEmpty)
        }
    }

    @Test("verified routes require the routing capability and minimum chat scope union")
    func routeCapabilityAndScopeGate() async throws {
        try await self.withFixture { fixture in
            let missingCapability = OpenClawChatOutboxRouteSnapshot(
                routingContract: "per-sender|main|main",
                capabilities: ["chat.send", "chat.history"],
                operatorScopes: ["operator.read", "operator.write", "operator.talk.secrets"],
                verifiedAt: Date())
            await self.expectError(.missingCapability("chat-send-routing-contract")) {
                try await fixture.store.saveVerifiedRouteSnapshot(missingCapability)
            }
            let missingRead = OpenClawChatOutboxRouteSnapshot(
                routingContract: "per-sender|main|main",
                capabilities: ["chat-send-routing-contract"],
                operatorScopes: ["operator.write", "operator.talk.secrets"],
                verifiedAt: Date())
            await self.expectError(.missingOperatorScope("operator.read")) {
                try await fixture.store.saveVerifiedRouteSnapshot(missingRead)
            }
            #expect(try await fixture.store.loadVerifiedRouteSnapshot() == nil)
        }
    }

    @Test("the fifty-first installation-wide command fails closed without eviction")
    func boundedCapacityAndGatewayIsolation() async throws {
        try await self.withFixture { fixture in
            let route = self.route()
            try await fixture.store.saveVerifiedRouteSnapshot(route)
            for index in 0..<OpenClawChatOutboxDatabase.maxUnresolvedCommandsPerGateway {
                _ = try await fixture.store.persistBeforeDraftClear(
                    self.draft(id: "command-\(index)", route: route))
            }
            await self.expectError(.capacityReached(limit: 50)) {
                _ = try await fixture.store.persistBeforeDraftClear(
                    self.draft(id: "command-50", route: route))
            }
            let stillQueued = try await fixture.store.loadUnresolved(
                now: Date(timeIntervalSince1970: 1_800_000_020))
            #expect(stillQueued.count == 50)
            #expect(stillQueued.first?.rawCommandID == "command-0")

            let other = try await fixture.database.store(stableGatewayID: "gateway-b")
            try await other.saveVerifiedRouteSnapshot(route)
            await self.expectError(.capacityReached(limit: 50)) {
                _ = try await other.persistBeforeDraftClear(self.draft(id: "other", route: route))
            }
            let cancelled = try await fixture.store.cancel(rawCommandID: "command-49")
            #expect(cancelled)
            _ = try await other.persistBeforeDraftClear(self.draft(id: "other", route: route))
            #expect(try await other.loadUnresolved().count == 1)
            #expect(try await fixture.store.loadUnresolved().count == 49)
        }
    }

    @Test("attachment limits reject atomically and preserve existing rows")
    func attachmentBoundsAreAtomic() async throws {
        try await self.withFixture { fixture in
            let route = self.route()
            try await fixture.store.saveVerifiedRouteSnapshot(route)
            let tooMany = (0...OpenClawChatOutboxDatabase.maxAttachmentsPerCommand).map { index in
                self.attachment(name: "\(index).jpg")
            }
            await self.expectError(.attachmentCountExceeded(limit: 8)) {
                _ = try await fixture.store.persistBeforeDraftClear(
                    self.draft(id: "too-many", route: route, attachments: tooMany))
            }
            await self.expectError(.attachmentTooLarge(limit: 5_000_000)) {
                _ = try await fixture.store.persistBeforeDraftClear(self.draft(
                    id: "too-large",
                    route: route,
                    attachments: [self.attachment(byteCount: 5_000_001)]))
            }
            let perCommandOverflow = [
                self.attachment(name: "1.jpg", byteCount: 5_000_000),
                self.attachment(name: "2.jpg", byteCount: 5_000_000),
                self.attachment(name: "3.jpg", byteCount: 5_000_000),
                self.attachment(name: "4.jpg", byteCount: 5_000_000),
                self.attachment(name: "5.jpg", byteCount: 1),
            ]
            await self.expectError(.attachmentBudgetExceeded(limit: 20_000_000)) {
                _ = try await fixture.store.persistBeforeDraftClear(self.draft(
                    id: "budget",
                    route: route,
                    attachments: perCommandOverflow))
            }
            let state = try await fixture.database.debugState()
            #expect(state.commandCount == 0)
            #expect(state.attachmentCount == 0)
        }
    }

    @Test("aggregate attachment bytes are bounded per gateway and installation")
    func aggregateAttachmentBudget() async throws {
        try await self.withFixture { fixture in
            let route = self.route()
            try await fixture.store.saveVerifiedRouteSnapshot(route)
            let fiveMB = self.attachment(byteCount: 5_000_000)
            let twentyMB = [fiveMB, fiveMB, fiveMB, fiveMB]
            let tenMB = [fiveMB, fiveMB]
            _ = try await fixture.store.persistBeforeDraftClear(self.draft(
                id: "twenty-a",
                route: route,
                attachments: twentyMB))
            _ = try await fixture.store.persistBeforeDraftClear(self.draft(
                id: "twenty-b",
                route: route,
                attachments: twentyMB))
            _ = try await fixture.store.persistBeforeDraftClear(self.draft(
                id: "ten",
                route: route,
                attachments: tenMB))

            await self.expectError(.attachmentBudgetExceeded(limit: 50_000_000)) {
                _ = try await fixture.store.persistBeforeDraftClear(self.draft(
                    id: "over-gateway-budget",
                    route: route,
                    attachments: [self.attachment(byteCount: 1)]))
            }
            let state = try await fixture.database.debugState()
            #expect(state.commandCount == 3)
            #expect(state.attachmentCount == 10)

            let other = try await fixture.database.store(stableGatewayID: "gateway-b")
            try await other.saveVerifiedRouteSnapshot(route)
            await self.expectError(.attachmentBudgetExceeded(limit: 50_000_000)) {
                _ = try await other.persistBeforeDraftClear(self.draft(
                    id: "other-gateway-over-installation-budget",
                    route: route,
                    attachments: [self.attachment(byteCount: 1)]))
            }
        }
    }

    @Test("expired work from a dormant gateway cannot consume global capacity")
    func globalCapacityExpiresDormantGateways() async throws {
        try await self.withFixture { fixture in
            let route = self.route()
            try await fixture.store.saveVerifiedRouteSnapshot(route)
            let createdAt = Date(timeIntervalSince1970: 1_700_000_000)
            let enqueueNow = createdAt.addingTimeInterval(1)
            for index in 0..<OpenClawChatOutboxDatabase.maxUnresolvedCommands {
                _ = try await fixture.store.persistBeforeDraftClear(
                    self.draft(
                        id: "dormant-\(index)",
                        route: route,
                        createdAt: createdAt),
                    now: enqueueNow)
            }

            let other = try await fixture.database.store(stableGatewayID: "gateway-b")
            try await other.saveVerifiedRouteSnapshot(route)
            let afterExpiry = createdAt.addingTimeInterval(
                OpenClawChatOutboxDatabase.commandLifetime + 1)
            _ = try await other.persistBeforeDraftClear(
                self.draft(id: "replacement", route: route, createdAt: afterExpiry),
                now: afterExpiry)

            let firstGateway = try await fixture.store.loadUnresolved(now: afterExpiry)
            let secondGateway = try await other.loadUnresolved(now: afterExpiry)
            #expect(firstGateway.isEmpty)
            #expect(secondGateway.map(\.rawCommandID) == ["replacement"])
        }
    }

    @Test("route snapshots and terminal receipts remain installation bounded")
    func metadataIsInstallationBounded() async throws {
        try await self.withFixture { fixture in
            let route = self.route()
            for index in 0..<OpenClawChatOutboxDatabase.maxRecentReceipts + 10 {
                let store = try await fixture.database.store(stableGatewayID: "gateway-\(index)")
                try await store.saveVerifiedRouteSnapshot(route)
                _ = try await store.persistBeforeDraftClear(
                    self.draft(id: "terminal-\(index)", route: route))
                let cancelled = try await store.cancel(rawCommandID: "terminal-\(index)")
                #expect(cancelled)
            }
            let boundedState = try await fixture.database.debugState()
            #expect(boundedState.receiptCount == OpenClawChatOutboxDatabase.maxRecentReceipts)
            #expect(boundedState.routeSnapshotCount == 1)

            let queued = try await fixture.database.store(stableGatewayID: "queued-gateway")
            try await queued.saveVerifiedRouteSnapshot(route)
            _ = try await queued.persistBeforeDraftClear(self.draft(id: "still-queued", route: route))
            let current = try await fixture.database.store(stableGatewayID: "current-gateway")
            try await current.saveVerifiedRouteSnapshot(route)
            let retainedState = try await fixture.database.debugState()
            #expect(retainedState.routeSnapshotCount == 2)
            #expect(try await queued.loadVerifiedRouteSnapshot() == route)
        }
    }

    @Test("claim is FIFO, pessimistically ambiguous, and stale callbacks are fenced")
    func atomicClaimAndStaleMutationFence() async throws {
        try await self.withFixture { fixture in
            let route = self.route()
            try await fixture.store.saveVerifiedRouteSnapshot(route)
            _ = try await fixture.store.persistBeforeDraftClear(self.draft(id: "first", route: route))
            _ = try await fixture.store.persistBeforeDraftClear(self.draft(id: "second", route: route))

            let firstClaim = try #require(try await fixture.store.claimNext())
            #expect(firstClaim.command.rawCommandID == "first")
            #expect(firstClaim.command.outcome == .ambiguous)
            #expect(try await fixture.store.claimNext() == nil)
            #expect(try await fixture.store.loadQueueState().blockingHead?.rawCommandID == "first")
            #expect(try await fixture.store.retryAmbiguousAfterReview(
                rawCommandID: "first") == false)

            await self.expectError(.invalidTransition) {
                _ = try await fixture.store.recordDispatchOutcome(
                    .ambiguous,
                    for: firstClaim,
                    ackRunID: "first",
                    failureCode: "ack_must_be_accepted")
            }

            #expect(try await fixture.store.recordDispatchOutcome(
                .ambiguous,
                for: firstClaim,
                failureCode: "transport_timeout"))
            // This is the explicit operator-review escape hatch, not an
            // automatic consequence of a bounded negative history scan.
            #expect(try await fixture.store.retryAmbiguousAfterReview(
                rawCommandID: "first"))
            let replacementClaim = try #require(try await fixture.store.claimNext())
            #expect(replacementClaim.command.rawCommandID == "first")
            #expect(replacementClaim != firstClaim)
            #expect(try await fixture.store.recordDispatchOutcome(
                .accepted,
                for: firstClaim,
                ackRunID: "first") == false)
            #expect(try await fixture.store.recordDispatchOutcome(
                .accepted,
                for: replacementClaim,
                ackRunID: "first"))
        }
    }

    @Test("post-commit housekeeping failure returns the committed enqueue and fails future work closed")
    func postCommitFailureCannotMasqueradeAsFailedPersistence() async throws {
        try await self.withFixture { fixture in
            let route = self.route()
            try await fixture.store.saveVerifiedRouteSnapshot(route)
            await fixture.database.debugInjectNextPostCommitMaintenanceFailure()

            let command = try await fixture.store.persistBeforeDraftClear(
                self.draft(id: "committed-before-housekeeping-failure", route: route))
            #expect(command.rawCommandID == "committed-before-housekeeping-failure")
            let committedState = try await fixture.database.debugState()
            #expect(committedState.commandCount == 1)
            await self.expectError(.storageUnavailable) {
                _ = try await fixture.store.loadUnresolved()
            }

            try await fixture.database.securePurgeAll()
            let replacement = try await fixture.database.store(stableGatewayID: "gateway-a")
            let restored = try await replacement.loadUnresolved()
            #expect(restored.isEmpty)
        }
    }

    @Test("an in-flight claim survives relaunch and proven pre-wire failure keeps its raw identity")
    func inFlightRelaunchAndNotDispatchedRetry() async throws {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let databaseURL = directoryURL.appendingPathComponent(
            OpenClawChatOutboxDatabase.databaseFilename,
            isDirectory: false)
        defer {
            try? OpenClawChatOutboxDatabase.removeDatabaseFiles(at: databaseURL)
            try? FileManager.default.removeItem(at: directoryURL)
        }
        let route = self.route()
        let firstDatabase = try OpenClawChatOutboxDatabase(
            databaseURL: databaseURL,
            claimProcessIDForTesting: "process-one")
        let firstStore = try await firstDatabase.store(stableGatewayID: "gateway-a")
        try await firstStore.saveVerifiedRouteSnapshot(route)
        _ = try await firstStore.persistBeforeDraftClear(self.draft(id: "stable-raw-id", route: route))
        let firstClaim = try #require(try await firstStore.claimNext())
        #expect(firstClaim.command.outcome == .ambiguous)
        try await firstDatabase.close()

        let sameProcessDatabase = try OpenClawChatOutboxDatabase(
            databaseURL: databaseURL,
            claimProcessIDForTesting: "process-one")
        let sameProcessStore = try await sameProcessDatabase.store(stableGatewayID: "gateway-a")
        let sameProcessRetry = try await sameProcessStore.retryAmbiguousAfterReview(
            rawCommandID: "stable-raw-id")
        #expect(sameProcessRetry == false)
        try await sameProcessDatabase.close()

        let secondDatabase = try OpenClawChatOutboxDatabase(
            databaseURL: databaseURL,
            claimProcessIDForTesting: "process-two")
        let secondStore = try await secondDatabase.store(stableGatewayID: "gateway-a")
        let restoredState = try await secondStore.loadQueueState()
        #expect(restoredState.blockingHead?.rawCommandID == "stable-raw-id")
        let blockedClaim = try await secondStore.claimNext()
        #expect(blockedClaim == nil)
        // Represents explicit operator review after the coordinator has kept
        // the inconclusive history miss parked.
        let reviewedRetry = try await secondStore.retryAmbiguousAfterReview(
            rawCommandID: "stable-raw-id")
        #expect(reviewedRetry)
        let secondClaim = try #require(try await secondStore.claimNext())
        let provenPreWire = try await secondStore.recordDispatchOutcome(
            .notDispatched,
            for: secondClaim,
            failureCode: "not_written_to_socket")
        #expect(provenPreWire)
        let thirdClaim = try #require(try await secondStore.claimNext())
        #expect(thirdClaim.command.rawCommandID == "stable-raw-id")
        #expect(thirdClaim.command.canonicalUserIdempotencyKey == "stable-raw-id:user")
        try await secondDatabase.close()
    }

    @Test("raw command identity cannot be reused while active or after a terminal receipt")
    func duplicateIdentityFailsClosed() async throws {
        try await self.withFixture { fixture in
            let route = self.route()
            try await fixture.store.saveVerifiedRouteSnapshot(route)
            _ = try await fixture.store.persistBeforeDraftClear(self.draft(id: "one-id", route: route))
            await self.expectError(.duplicateCommandID) {
                _ = try await fixture.store.persistBeforeDraftClear(
                    self.draft(id: "one-id", route: route))
            }
            let cancelled = try await fixture.store.cancel(rawCommandID: "one-id")
            #expect(cancelled)
            await self.expectError(.duplicateCommandID) {
                _ = try await fixture.store.persistBeforeDraftClear(
                    self.draft(id: "one-id", route: route))
            }
        }
    }

    @Test("canonical confirmation requires the gateway-appended user identity")
    func canonicalConfirmation() async throws {
        try await self.withFixture { fixture in
            let route = self.route()
            try await fixture.store.saveVerifiedRouteSnapshot(route)
            _ = try await fixture.store.persistBeforeDraftClear(self.draft(id: "raw-id", route: route))
            let claim = try #require(try await fixture.store.claimNext())
            #expect(try await fixture.store.recordDispatchOutcome(
                .accepted,
                for: claim,
                ackRunID: "raw-id"))
            await self.expectError(.canonicalIdentityMismatch) {
                _ = try await fixture.store.confirmCanonicalHistory(
                    rawCommandID: "raw-id",
                    canonicalUserIdempotencyKey: "raw-id")
            }
            #expect(try await fixture.store.loadUnresolved().count == 1)
            #expect(try await fixture.store.confirmCanonicalHistory(
                rawCommandID: "raw-id",
                canonicalUserIdempotencyKey: "raw-id:user"))
            #expect(try await fixture.store.loadUnresolved().isEmpty)
            let receipt = try #require(try await fixture.store.loadRecentReceipts().first)
            #expect(receipt.outcome == .canonicalHistoryConfirmed)
            #expect(receipt.ackRunID == "raw-id")
            #expect(receipt.canonicalUserIdempotencyKey == "raw-id:user")
        }
    }

    @Test("route changes remain blocked until explicit review with a verified replacement")
    func routeChangeReview() async throws {
        try await self.withFixture { fixture in
            let oldRoute = self.route()
            try await fixture.store.saveVerifiedRouteSnapshot(oldRoute)
            _ = try await fixture.store.persistBeforeDraftClear(
                self.draft(id: "route-change", route: oldRoute))
            let claim = try #require(try await fixture.store.claimNext())
            #expect(try await fixture.store.recordDispatchOutcome(
                .blockedRouteChanged,
                for: claim,
                failureCode: "session-routing-changed"))
            #expect(try await fixture.store.claimNext() == nil)

            let newRoute = self.route(
                contract: "per-sender|main|replacement",
                verifiedAt: oldRoute.verifiedAt.addingTimeInterval(1))
            await self.expectError(.routeSnapshotChanged) {
                _ = try await fixture.store.retryAfterRouteReview(
                    rawCommandID: "route-change",
                    newRoute: newRoute)
            }
            try await fixture.store.saveVerifiedRouteSnapshot(newRoute)
            #expect(try await fixture.store.retryAfterRouteReview(
                rawCommandID: "route-change",
                newRoute: newRoute))
            let retried = try #require(try await fixture.store.loadUnresolved().first)
            #expect(retried.rawCommandID == "route-change")
            #expect(retried.outcome == .notDispatched)
            #expect(retried.route == newRoute)
        }
    }

    @Test("expiry emits a metadata receipt and scrubs text and attachment payloads")
    func expiryPurgesPayload() async throws {
        let secretText = "unique-private-outbox-text-7e4d"
        let secretAttachment = Data("unique-private-attachment-92aa".utf8)
        let secretAttachmentText = String(decoding: secretAttachment, as: UTF8.self)
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let databaseURL = directoryURL.appendingPathComponent(
            OpenClawChatOutboxDatabase.databaseFilename,
            isDirectory: false)
        defer {
            try? OpenClawChatOutboxDatabase.removeDatabaseFiles(at: databaseURL)
            try? FileManager.default.removeItem(at: directoryURL)
        }
        let database = try OpenClawChatOutboxDatabase(databaseURL: databaseURL)
        let store = try await database.store(stableGatewayID: "gateway-a")
        let route = self.route()
        try await store.saveVerifiedRouteSnapshot(route)
        let createdAt = Date(timeIntervalSince1970: 1_800_000_000)
        _ = try await store.persistBeforeDraftClear(self.draft(
            id: "expires",
            route: route,
            text: secretText,
            attachments: [OpenClawChatOutboxAttachment(
                type: "file",
                mimeType: "application/octet-stream",
                fileName: "private.bin",
                data: secretAttachment)],
            createdAt: createdAt))
        let afterExpiry = createdAt.addingTimeInterval(
            OpenClawChatOutboxDatabase.commandLifetime + 1)
        #expect(try await store.loadUnresolved(now: afterExpiry).isEmpty)
        let receipt = try #require(try await store.loadRecentReceipts().first)
        #expect(receipt.outcome == .expired)
        let state = try await database.debugState()
        #expect(state.commandCount == 0)
        #expect(state.attachmentCount == 0)
        try await database.close()

        for fileURL in [databaseURL] + ["-wal", "-shm", "-journal"].map({ suffix in
            URL(fileURLWithPath: databaseURL.path + suffix)
        }) where FileManager.default.fileExists(atPath: fileURL.path) {
            let bytes = try Data(contentsOf: fileURL)
            #expect(bytes.range(of: Data(secretText.utf8)) == nil)
            #expect(bytes.range(of: Data(secretAttachmentText.utf8)) == nil)
        }
    }

    @Test("gateway purge is isolated and generation-fences every old handle")
    func gatewayPurgeRetiresOldStores() async throws {
        try await self.withFixture { fixture in
            let route = self.route()
            let other = try await fixture.database.store(stableGatewayID: "gateway-b")
            try await fixture.store.saveVerifiedRouteSnapshot(route)
            try await other.saveVerifiedRouteSnapshot(route)
            _ = try await fixture.store.persistBeforeDraftClear(self.draft(id: "a", route: route))
            _ = try await other.persistBeforeDraftClear(self.draft(id: "b", route: route))

            try await fixture.store.securePurge()
            await self.expectError(.retired) {
                _ = try await fixture.store.loadUnresolved()
            }
            let replacement = try await fixture.database.store(stableGatewayID: "gateway-a")
            #expect(try await replacement.loadVerifiedRouteSnapshot() == nil)
            #expect(try await replacement.loadUnresolved().isEmpty)
            #expect(try await other.loadUnresolved().map(\.rawCommandID) == ["b"])
        }
    }

    @Test("a committed purge marker is checkpointed before the next owner exposes stores")
    func purgeCrashWindowRecoversAtOpen() async throws {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let databaseURL = directoryURL.appendingPathComponent(
            OpenClawChatOutboxDatabase.databaseFilename,
            isDirectory: false)
        defer {
            try? OpenClawChatOutboxDatabase.removeDatabaseFiles(at: databaseURL)
            try? FileManager.default.removeItem(at: directoryURL)
        }
        let firstDatabase = try OpenClawChatOutboxDatabase(
            databaseURL: databaseURL,
            claimProcessIDForTesting: "purge-process-one")
        let firstStore = try await firstDatabase.store(stableGatewayID: "gateway-a")
        let route = self.route()
        try await firstStore.saveVerifiedRouteSnapshot(route)
        _ = try await firstStore.persistBeforeDraftClear(self.draft(
            id: "purge-crash-window",
            route: route,
            text: "payload-that-must-not-survive-logically"))

        try await firstDatabase.debugCommitGatewayPurgeBeforeCheckpoint(
            stableGatewayID: "gateway-a")
        let committedMarker = try await firstDatabase.debugState()
        #expect(committedMarker.commandCount == 0)
        #expect(committedMarker.needsCheckpoint)

        // This second owner models a new process observing the committed WAL.
        // openDatabase must complete the durable checkpoint barrier before it
        // can return any gateway store.
        let secondDatabase = try OpenClawChatOutboxDatabase(
            databaseURL: databaseURL,
            claimProcessIDForTesting: "purge-process-two")
        let recoveredState = try await secondDatabase.debugState()
        #expect(recoveredState.commandCount == 0)
        #expect(recoveredState.attachmentCount == 0)
        #expect(recoveredState.needsCheckpoint == false)
        let secondStore = try await secondDatabase.store(stableGatewayID: "gateway-a")
        #expect(try await secondStore.loadVerifiedRouteSnapshot() == nil)
        try await secondDatabase.close()
        try await firstDatabase.close()
    }

    @Test("full purge reopens clean while old stores stay retired")
    func fullPurgeIsReusableAndFenced() async throws {
        try await self.withFixture { fixture in
            let route = self.route()
            try await fixture.store.saveVerifiedRouteSnapshot(route)
            _ = try await fixture.store.persistBeforeDraftClear(self.draft(id: "before", route: route))
            try await fixture.database.securePurgeAll()
            await self.expectError(.retired) {
                _ = try await fixture.store.loadUnresolved()
            }
            let replacement = try await fixture.database.store(stableGatewayID: "gateway-a")
            #expect(try await replacement.loadUnresolved().isEmpty)
            #expect(try await replacement.loadVerifiedRouteSnapshot() == nil)
        }
    }

    @Test("exact static purge removes SQLite sidecars but preserves adjacent files")
    func exactSidecarPurge() throws {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let databaseURL = directoryURL.appendingPathComponent(
            OpenClawChatOutboxDatabase.databaseFilename,
            isDirectory: false)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let exactTargets = [databaseURL] + ["-wal", "-shm", "-journal"].map { suffix in
            URL(fileURLWithPath: databaseURL.path + suffix)
        }
        for target in exactTargets {
            try Data("remove".utf8).write(to: target)
        }
        let adjacent = URL(fileURLWithPath: databaseURL.path + "-backup")
        try Data("preserve".utf8).write(to: adjacent)

        try OpenClawChatOutboxDatabase.removeDatabaseFiles(at: databaseURL)

        #expect(exactTargets.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
        #expect(FileManager.default.fileExists(atPath: adjacent.path))
    }

    @Test("closed or impossible storage fails without clearing caller-owned draft")
    func storageFailureIsExplicit() async throws {
        try await self.withFixture { fixture in
            let route = self.route()
            try await fixture.store.saveVerifiedRouteSnapshot(route)
            try await fixture.database.close()
            await self.expectError(.closed) {
                _ = try await fixture.store.persistBeforeDraftClear(
                    self.draft(id: "preserved-draft", route: route))
            }
        }

        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let parentFileURL = directoryURL.appendingPathComponent("not-a-directory")
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        try Data("file".utf8).write(to: parentFileURL)
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let impossibleURL = parentFileURL.appendingPathComponent(
            OpenClawChatOutboxDatabase.databaseFilename)
        #expect(throws: Error.self) {
            _ = try OpenClawChatOutboxDatabase(databaseURL: impossibleURL)
        }
    }
}
