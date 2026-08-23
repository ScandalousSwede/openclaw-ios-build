import Foundation
import GRDB
import OpenClawKit

/// Delivery state owned by the local client. This is a replay coordinator,
/// never an authority for chat history or gateway routing.
public enum OpenClawChatOutboxOutcome: String, Codable, CaseIterable, Hashable, Sendable {
    case notDispatched = "not_dispatched"
    case dispatchRejected = "dispatch_rejected"
    case accepted
    case ambiguous
    case canonicalHistoryConfirmed = "canonical_history_confirmed"
    case expired
    case cancelled
    case blockedRouteChanged = "blocked_route_changed"

    public var isTerminal: Bool {
        switch self {
        case .canonicalHistoryConfirmed, .expired, .cancelled:
            true
        case .notDispatched, .dispatchRejected, .accepted, .ambiguous, .blockedRouteChanged:
            false
        }
    }
}

public struct OpenClawChatOutboxAttachment: Hashable, Sendable {
    public let type: String
    public let mimeType: String
    public let fileName: String
    public let data: Data

    public init(type: String, mimeType: String, fileName: String, data: Data) {
        self.type = type
        self.mimeType = mimeType
        self.fileName = fileName
        self.data = data
    }
}

/// A lease snapshot that was observed on an authenticated gateway connection.
/// Session selection stays on each command; gateway capability evidence does not.
public struct OpenClawChatOutboxRouteSnapshot: Hashable, Sendable {
    public let routingContract: String
    public let capabilities: [String]
    public let operatorScopes: [String]
    public let verifiedAt: Date

    public init(
        routingContract: String,
        capabilities: [String],
        operatorScopes: [String],
        verifiedAt: Date)
    {
        self.routingContract = routingContract
        self.capabilities = capabilities
        self.operatorScopes = operatorScopes
        self.verifiedAt = verifiedAt
    }
}

public struct OpenClawChatOutboxDraft: Hashable, Sendable {
    public let rawCommandID: String
    public let sessionKey: String
    public let text: String
    public let attachments: [OpenClawChatOutboxAttachment]
    public let thinkingLevel: String
    public let route: OpenClawChatOutboxRouteSnapshot
    public let createdAt: Date

    public init(
        rawCommandID: String,
        sessionKey: String,
        text: String,
        attachments: [OpenClawChatOutboxAttachment] = [],
        thinkingLevel: String,
        route: OpenClawChatOutboxRouteSnapshot,
        createdAt: Date = Date())
    {
        self.rawCommandID = rawCommandID
        self.sessionKey = sessionKey
        self.text = text
        self.attachments = attachments
        self.thinkingLevel = thinkingLevel
        self.route = route
        self.createdAt = createdAt
    }
}

public struct OpenClawChatOutboxCommand: Hashable, Identifiable, Sendable {
    public var id: String { self.rawCommandID }
    public var canonicalUserIdempotencyKey: String { "\(self.rawCommandID):user" }

    public let enqueueSequence: Int64
    public let stableGatewayID: String
    public let rawCommandID: String
    public let sessionKey: String
    public let text: String
    public let attachments: [OpenClawChatOutboxAttachment]
    public let thinkingLevel: String
    public let route: OpenClawChatOutboxRouteSnapshot
    public let createdAt: Date
    public let expiresAt: Date
    public let outcome: OpenClawChatOutboxOutcome
    public let outcomeAt: Date
    public let ackRunID: String?
    public let failureCode: String?
}

public struct OpenClawChatOutboxClaim: Hashable, Sendable {
    public let command: OpenClawChatOutboxCommand
    fileprivate let token: String
    fileprivate let processID: String
}

public struct OpenClawChatOutboxReceipt: Hashable, Identifiable, Sendable {
    public var id: String { self.rawCommandID }

    public let stableGatewayID: String
    public let rawCommandID: String
    public let outcome: OpenClawChatOutboxOutcome
    public let recordedAt: Date
    public let ackRunID: String?
    public let failureCode: String?
    public let canonicalUserIdempotencyKey: String?
}

public struct OpenClawChatOutboxQueueState: Hashable, Sendable {
    public let commands: [OpenClawChatOutboxCommand]

    public var blockingHead: OpenClawChatOutboxCommand? {
        guard let head = self.commands.first, head.outcome != .notDispatched else { return nil }
        return head
    }
}

public enum OpenClawChatOutboxError: Error, Equatable, LocalizedError, Sendable {
    case invalidField(String)
    case missingCapability(String)
    case missingOperatorScope(String)
    case routeSnapshotUnavailable
    case routeSnapshotChanged
    case duplicateCommandID
    case capacityReached(limit: Int)
    case attachmentCountExceeded(limit: Int)
    case attachmentTooLarge(limit: Int)
    case attachmentBudgetExceeded(limit: Int)
    case textTooLarge(limit: Int)
    case invalidTransition
    case staleClaim
    case canonicalIdentityMismatch
    case retired
    case closed
    case storageUnavailable

    public var errorDescription: String? {
        switch self {
        case .invalidField(let field): "Invalid outbox field: \(field)"
        case .missingCapability(let capability): "Missing gateway capability: \(capability)"
        case .missingOperatorScope(let scope): "Missing operator scope: \(scope)"
        case .routeSnapshotUnavailable: "No verified gateway route snapshot is available"
        case .routeSnapshotChanged: "The verified gateway route snapshot changed"
        case .duplicateCommandID: "The chat command identity is already known"
        case .capacityReached(let limit): "The chat outbox is full (limit \(limit))"
        case .attachmentCountExceeded(let limit): "Too many attachments (limit \(limit))"
        case .attachmentTooLarge(let limit): "An attachment exceeds \(limit) bytes"
        case .attachmentBudgetExceeded(let limit): "Attachments exceed \(limit) bytes"
        case .textTooLarge(let limit): "Message text exceeds \(limit) bytes"
        case .invalidTransition: "The outbox state transition is invalid"
        case .staleClaim: "The outbox claim is no longer current"
        case .canonicalIdentityMismatch: "Canonical history identity does not match the command"
        case .retired: "This gateway outbox handle was retired"
        case .closed: "The chat outbox database is closed"
        case .storageUnavailable: "Chat outbox storage is unavailable"
        }
    }
}

/// One installation-wide, non-authoritative database for durable client chat work.
/// A dedicated file keeps plaintext queue lifecycle and secure reset independent
/// from gateway-derived caches and from all server authority databases.
public actor OpenClawChatOutboxDatabase {
    public static let databaseDirectoryName = "ChatOutbox"
    public static let databaseFilename = "openclaw-chat-outbox.sqlite"
    public static let maxUnresolvedCommands = 50
    public static let maxUnresolvedCommandsPerGateway = 50
    public static let commandLifetime: TimeInterval = 48 * 60 * 60
    public static let maxAttachmentsPerCommand = 8
    public static let maxAttachmentBytes = 5_000_000
    public static let maxAttachmentBytesPerCommand = 20_000_000
    public static let maxAttachmentBytesPerInstallation = 50_000_000
    public static let maxAttachmentBytesPerGateway = 50_000_000
    public static let maxTextBytes = 256_000
    public static let maxRecentReceipts = 50
    public static let maxRecentReceiptsPerGateway = 50
    public static let routingCapability = "chat-send-routing-contract"
    public static let requiredOperatorScopes = ["operator.read", "operator.write"]
    static let finalMigrationIdentifier = "openclaw-chat-outbox-v1-final"
    private static let processClaimOwnerID = UUID().uuidString.lowercased()

    public nonisolated let databaseURL: URL

    private let claimProcessID: String
    private var queue: DatabaseQueue?
    private var acceptsStores = true
    private var storageUnavailable = false
    private var databaseGeneration: UInt64 = 1
    private var gatewayGenerations: [String: UInt64] = [:]
    private var blockedGatewayIDs = Set<String>()
    private var debugFailNextPostCommitMaintenance = false

    public init(databaseURL: URL) throws {
        guard databaseURL.isFileURL,
              databaseURL.lastPathComponent == Self.databaseFilename
        else {
            throw OpenClawChatOutboxError.invalidField("databaseURL")
        }
        let claimProcessID = Self.processClaimOwnerID
        self.databaseURL = databaseURL
        self.claimProcessID = claimProcessID
        try FileManager.default.createDirectory(
            at: databaseURL.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        self.queue = try Self.openDatabase(
            at: databaseURL,
            claimProcessID: claimProcessID)
        try Self.applyFileSecurity(at: databaseURL)
    }

    init(databaseURL: URL, claimProcessIDForTesting: String) throws {
        guard databaseURL.isFileURL,
              databaseURL.lastPathComponent == Self.databaseFilename
        else {
            throw OpenClawChatOutboxError.invalidField("databaseURL")
        }
        let claimProcessID = try Self.normalizeIdentifier(
            claimProcessIDForTesting,
            field: "claimProcessID")
        self.databaseURL = databaseURL
        self.claimProcessID = claimProcessID
        try FileManager.default.createDirectory(
            at: databaseURL.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        self.queue = try Self.openDatabase(
            at: databaseURL,
            claimProcessID: claimProcessID)
        try Self.applyFileSecurity(at: databaseURL)
    }

    public static func openApplicationSupport() throws -> OpenClawChatOutboxDatabase {
        let directoryURL = try OpenClawNodeStorage.appSupportDir()
            .appendingPathComponent(Self.databaseDirectoryName, isDirectory: true)
        return try OpenClawChatOutboxDatabase(
            databaseURL: directoryURL.appendingPathComponent(Self.databaseFilename, isDirectory: false))
    }

    public func store(stableGatewayID: String) throws -> OpenClawChatOutboxStore {
        guard self.acceptsStores, self.queue != nil else { throw OpenClawChatOutboxError.closed }
        guard !self.storageUnavailable else { throw OpenClawChatOutboxError.storageUnavailable }
        let gatewayID = try Self.normalizeStableGatewayID(stableGatewayID)
        guard !self.blockedGatewayIDs.contains(gatewayID) else {
            throw OpenClawChatOutboxError.storageUnavailable
        }
        let scope = Scope(
            databaseGeneration: self.databaseGeneration,
            gatewayGeneration: self.gatewayGenerations[gatewayID, default: 0])
        return OpenClawChatOutboxStore(database: self, stableGatewayID: gatewayID, scope: scope)
    }

    /// Closes this owner permanently. Existing stores become unusable.
    public func close() throws {
        self.databaseGeneration &+= 1
        self.acceptsStores = false
        guard let queue = self.queue else { return }
        do {
            _ = try queue.writeWithoutTransaction { db in try db.checkpoint(.truncate) }
            try queue.close()
            self.queue = nil
            try Self.applyFileSecurity(at: self.databaseURL)
        } catch {
            throw OpenClawChatOutboxError.storageUnavailable
        }
    }

    /// Securely removes every row and exact SQLite file, then reopens a clean
    /// store. Generation fencing prevents old workers from writing into it.
    public func securePurgeAll() throws {
        self.databaseGeneration &+= 1
        self.gatewayGenerations.removeAll()
        self.blockedGatewayIDs.removeAll()
        self.acceptsStores = false
        guard let queue = self.queue else { throw OpenClawChatOutboxError.closed }
        do {
            try Self.scrubAndClose(queue)
            self.queue = nil
            try Self.removeDatabaseFiles(at: self.databaseURL)
            self.queue = try Self.openDatabase(
                at: self.databaseURL,
                claimProcessID: self.claimProcessID)
            try Self.applyFileSecurity(at: self.databaseURL)
            self.storageUnavailable = false
            self.acceptsStores = true
        } catch {
            self.queue = nil
            self.storageUnavailable = true
            throw OpenClawChatOutboxError.storageUnavailable
        }
    }

    /// Removes only the exact SQLite database and known sidecars. The caller
    /// must have already closed every owner of this file.
    public nonisolated static func removeDatabaseFiles(at databaseURL: URL) throws {
        guard databaseURL.isFileURL,
              databaseURL.lastPathComponent == self.databaseFilename
        else {
            throw OpenClawChatOutboxError.invalidField("databaseURL")
        }
        let fileManager = FileManager.default
        let fileURLs = self.databaseFileURLs(at: databaseURL)
        // Sidecars first makes deletion crash-monotonic: the main database is
        // never removed while a recoverable WAL could still remain beside it.
        for url in Array(fileURLs.dropFirst()) + [databaseURL]
            where fileManager.fileExists(atPath: url.path)
        {
            try fileManager.removeItem(at: url)
        }
    }
}

public struct OpenClawChatOutboxStore: Sendable {
    public let stableGatewayID: String

    private let database: OpenClawChatOutboxDatabase
    private let scope: OpenClawChatOutboxDatabase.Scope

    fileprivate init(
        database: OpenClawChatOutboxDatabase,
        stableGatewayID: String,
        scope: OpenClawChatOutboxDatabase.Scope)
    {
        self.database = database
        self.stableGatewayID = stableGatewayID
        self.scope = scope
    }

    public func saveVerifiedRouteSnapshot(_ snapshot: OpenClawChatOutboxRouteSnapshot) async throws {
        try await self.database.saveVerifiedRouteSnapshot(
            snapshot,
            stableGatewayID: self.stableGatewayID,
            scope: self.scope)
    }

    public func loadVerifiedRouteSnapshot() async throws -> OpenClawChatOutboxRouteSnapshot? {
        try await self.database.loadVerifiedRouteSnapshot(
            stableGatewayID: self.stableGatewayID,
            scope: self.scope)
    }

    public func persistBeforeDraftClear(
        _ draft: OpenClawChatOutboxDraft,
        now: Date = Date()) async throws -> OpenClawChatOutboxCommand
    {
        try await self.database.persistBeforeDraftClear(
            draft,
            stableGatewayID: self.stableGatewayID,
            scope: self.scope,
            now: now)
    }

    public func loadQueueState(now: Date = Date()) async throws -> OpenClawChatOutboxQueueState {
        try await self.database.loadQueueState(
            stableGatewayID: self.stableGatewayID,
            scope: self.scope,
            now: now)
    }

    public func loadUnresolved(now: Date = Date()) async throws -> [OpenClawChatOutboxCommand] {
        (try await self.loadQueueState(now: now)).commands
    }

    public func claimNext(now: Date = Date()) async throws -> OpenClawChatOutboxClaim? {
        try await self.database.claimNext(
            stableGatewayID: self.stableGatewayID,
            scope: self.scope,
            now: now)
    }

    @discardableResult
    public func recordDispatchOutcome(
        _ outcome: OpenClawChatOutboxOutcome,
        for claim: OpenClawChatOutboxClaim,
        at: Date = Date(),
        ackRunID: String? = nil,
        failureCode: String? = nil) async throws -> Bool
    {
        try await self.database.recordDispatchOutcome(
            outcome,
            claim: claim,
            stableGatewayID: self.stableGatewayID,
            scope: self.scope,
            at: at,
            ackRunID: ackRunID,
            failureCode: failureCode)
    }

    /// Manual-review transition only. A bounded negative history scan is
    /// inconclusive and must never call this automatically. The raw command ID
    /// is preserved, and any same-process active claim keeps this parked.
    @discardableResult
    public func retryAmbiguousAfterReview(
        rawCommandID: String,
        reviewedAt: Date = Date()) async throws -> Bool
    {
        try await self.database.retryAmbiguousAfterReview(
            rawCommandID: rawCommandID,
            stableGatewayID: self.stableGatewayID,
            scope: self.scope,
            reviewedAt: reviewedAt)
    }

    @discardableResult
    public func retryDispatchRejected(
        rawCommandID: String,
        reviewedAt: Date = Date()) async throws -> Bool
    {
        try await self.database.retryDispatchRejected(
            rawCommandID: rawCommandID,
            stableGatewayID: self.stableGatewayID,
            scope: self.scope,
            reviewedAt: reviewedAt)
    }

    @discardableResult
    public func retryAfterRouteReview(
        rawCommandID: String,
        newRoute: OpenClawChatOutboxRouteSnapshot,
        reviewedAt: Date = Date()) async throws -> Bool
    {
        try await self.database.retryAfterRouteReview(
            rawCommandID: rawCommandID,
            newRoute: newRoute,
            stableGatewayID: self.stableGatewayID,
            scope: self.scope,
            reviewedAt: reviewedAt)
    }

    @discardableResult
    public func confirmCanonicalHistory(
        rawCommandID: String,
        canonicalUserIdempotencyKey: String,
        confirmedAt: Date = Date()) async throws -> Bool
    {
        try await self.database.confirmCanonicalHistory(
            rawCommandID: rawCommandID,
            canonicalUserIdempotencyKey: canonicalUserIdempotencyKey,
            stableGatewayID: self.stableGatewayID,
            scope: self.scope,
            confirmedAt: confirmedAt)
    }

    @discardableResult
    public func cancel(rawCommandID: String, at: Date = Date()) async throws -> Bool {
        try await self.database.cancel(
            rawCommandID: rawCommandID,
            stableGatewayID: self.stableGatewayID,
            scope: self.scope,
            at: at)
    }

    public func loadRecentReceipts() async throws -> [OpenClawChatOutboxReceipt] {
        try await self.database.loadRecentReceipts(
            stableGatewayID: self.stableGatewayID,
            scope: self.scope)
    }

    /// Retires this and all sibling handles for the gateway before deletion.
    public func securePurge() async throws {
        try await self.database.securePurgeGateway(
            stableGatewayID: self.stableGatewayID,
            scope: self.scope)
    }
}

extension OpenClawChatOutboxDatabase {
    fileprivate struct Scope: Hashable, Sendable {
        let databaseGeneration: UInt64
        let gatewayGeneration: UInt64
    }

    private static func openDatabase(
        at databaseURL: URL,
        claimProcessID: String) throws -> DatabaseQueue
    {
        var configuration = Configuration()
        configuration.label = "OpenClaw.chat-outbox"
        configuration.journalMode = .wal
        configuration.busyMode = .timeout(5)
        configuration.foreignKeysEnabled = true
        configuration.prepareDatabase { db in
            try db.execute(sql: "PRAGMA secure_delete = ON")
        }

        let queue = try DatabaseQueue(path: databaseURL.path, configuration: configuration)
        var migrator = DatabaseMigrator()
        migrator.registerMigration(self.finalMigrationIdentifier) { db in
            try db.execute(sql: """
            CREATE TABLE gateway_route_snapshots(
                stable_gateway_id TEXT NOT NULL PRIMARY KEY,
                routing_contract TEXT NOT NULL,
                capabilities_json TEXT NOT NULL,
                operator_scopes_json TEXT NOT NULL,
                verified_at REAL NOT NULL
            );

            CREATE TABLE outbox_maintenance(
                id INTEGER NOT NULL PRIMARY KEY CHECK(id = 1),
                needs_checkpoint INTEGER NOT NULL CHECK(needs_checkpoint IN (0, 1))
            );
            INSERT INTO outbox_maintenance(id, needs_checkpoint) VALUES (1, 0);

            CREATE TABLE outbox_commands(
                enqueue_sequence INTEGER PRIMARY KEY AUTOINCREMENT,
                stable_gateway_id TEXT NOT NULL,
                raw_command_id TEXT NOT NULL,
                session_key TEXT NOT NULL,
                text TEXT NOT NULL,
                thinking_level TEXT NOT NULL,
                routing_contract TEXT NOT NULL,
                capabilities_json TEXT NOT NULL,
                operator_scopes_json TEXT NOT NULL,
                route_verified_at REAL NOT NULL,
                created_at REAL NOT NULL,
                expires_at REAL NOT NULL,
                outcome TEXT NOT NULL CHECK(outcome IN (
                    'not_dispatched', 'dispatch_rejected', 'accepted',
                    'ambiguous', 'blocked_route_changed'
                )),
                outcome_at REAL NOT NULL,
                ack_run_id TEXT,
                failure_code TEXT,
                claim_token TEXT,
                claimed_at REAL,
                claim_process_id TEXT,
                attachment_bytes INTEGER NOT NULL DEFAULT 0 CHECK(attachment_bytes >= 0),
                UNIQUE(stable_gateway_id, raw_command_id),
                CHECK(expires_at > created_at),
                CHECK((claim_token IS NULL AND claimed_at IS NULL AND claim_process_id IS NULL) OR
                      (claim_token IS NOT NULL AND claimed_at IS NOT NULL AND claim_process_id IS NOT NULL))
            );
            CREATE INDEX outbox_commands_fifo
                ON outbox_commands(stable_gateway_id, enqueue_sequence);

            CREATE TABLE outbox_attachments(
                stable_gateway_id TEXT NOT NULL,
                raw_command_id TEXT NOT NULL,
                position INTEGER NOT NULL,
                type TEXT NOT NULL,
                mime_type TEXT NOT NULL,
                file_name TEXT NOT NULL,
                payload BLOB NOT NULL,
                PRIMARY KEY(stable_gateway_id, raw_command_id, position),
                FOREIGN KEY(stable_gateway_id, raw_command_id)
                    REFERENCES outbox_commands(stable_gateway_id, raw_command_id)
                    ON DELETE CASCADE
            );

            CREATE TABLE outbox_receipts(
                receipt_sequence INTEGER PRIMARY KEY AUTOINCREMENT,
                stable_gateway_id TEXT NOT NULL,
                raw_command_id TEXT NOT NULL,
                outcome TEXT NOT NULL CHECK(outcome IN (
                    'canonical_history_confirmed', 'expired', 'cancelled'
                )),
                recorded_at REAL NOT NULL,
                ack_run_id TEXT,
                failure_code TEXT,
                canonical_user_idempotency_key TEXT,
                UNIQUE(stable_gateway_id, raw_command_id)
            );
            CREATE INDEX outbox_receipts_recent
                ON outbox_receipts(stable_gateway_id, recorded_at DESC, receipt_sequence DESC);
            """)
        }
        try migrator.migrate(queue)
        let recoveredPriorProcessClaims = try queue.write { db in
            try db.execute(
                sql: """
                UPDATE outbox_commands
                SET claim_token = NULL, claimed_at = NULL, claim_process_id = NULL
                WHERE outcome = 'ambiguous' AND claim_token IS NOT NULL
                  AND (claim_process_id IS NULL OR claim_process_id <> ?)
                """,
                arguments: [claimProcessID])
            return db.changesCount > 0
        }
        if recoveredPriorProcessClaims {
            _ = try queue.writeWithoutTransaction { db in try db.checkpoint(.truncate) }
        }
        // A prior process may have committed a logical purge and died before
        // truncating WAL. Never expose a store until that durable maintenance
        // marker has crossed the checkpoint barrier.
        try self.finishPendingCheckpoint(queue)
        return queue
    }

    private static func scrubAndClose(_ queue: DatabaseQueue) throws {
        try queue.write { db in
            try db.execute(sql: "DELETE FROM outbox_attachments")
            try db.execute(sql: "DELETE FROM outbox_commands")
            try db.execute(sql: "DELETE FROM outbox_receipts")
            try db.execute(sql: "DELETE FROM gateway_route_snapshots")
            try db.execute(sql: "UPDATE outbox_maintenance SET needs_checkpoint = 1 WHERE id = 1")
        }
        try self.finishPendingCheckpoint(queue)
        try queue.close()
    }

    private nonisolated static func databaseFileURLs(at databaseURL: URL) -> [URL] {
        [databaseURL] + ["-wal", "-shm", "-journal"].map { suffix in
            URL(fileURLWithPath: databaseURL.path + suffix, isDirectory: false)
        }
    }

    private static func applyFileSecurity(at databaseURL: URL) throws {
        let fileManager = FileManager.default
        let directoryURL = databaseURL.deletingLastPathComponent()
        var directoryValues = URLResourceValues()
        directoryValues.isExcludedFromBackup = true
        var mutableDirectoryURL = directoryURL
        try mutableDirectoryURL.setResourceValues(directoryValues)
        #if os(iOS)
        try fileManager.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: directoryURL.path)
        #endif

        for fileURL in self.databaseFileURLs(at: databaseURL)
            where fileManager.fileExists(atPath: fileURL.path)
        {
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var mutableFileURL = fileURL
            try mutableFileURL.setResourceValues(values)
            #if os(iOS)
            try fileManager.setAttributes(
                [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                ofItemAtPath: fileURL.path)
            #endif
        }
    }

    private static func normalizeStableGatewayID(_ value: String) throws -> String {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty, normalized.utf8.count <= 512 else {
            throw OpenClawChatOutboxError.invalidField("stableGatewayID")
        }
        return normalized
    }

    private static func normalizeIdentifier(_ value: String, field: String) throws -> String {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized == value,
              !normalized.isEmpty,
              normalized.utf8.count <= 512,
              !normalized.unicodeScalars.contains(where: { scalar in
                  CharacterSet.controlCharacters.contains(scalar)
              })
        else {
            throw OpenClawChatOutboxError.invalidField(field)
        }
        return normalized
    }

    private static func normalizeList(
        _ values: [String],
        field: String,
        maximumCount: Int) throws -> [String]
    {
        guard values.count <= maximumCount else {
            throw OpenClawChatOutboxError.invalidField(field)
        }
        var normalized = Set<String>()
        for value in values {
            let item = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !item.isEmpty, item.utf8.count <= 256 else {
                throw OpenClawChatOutboxError.invalidField(field)
            }
            normalized.insert(item)
        }
        return normalized.sorted()
    }

    private static func normalizeRoute(
        _ route: OpenClawChatOutboxRouteSnapshot) throws -> OpenClawChatOutboxRouteSnapshot
    {
        let routingContract = try self.normalizeIdentifier(
            route.routingContract,
            field: "routingContract")
        let capabilities = try self.normalizeList(
            route.capabilities,
            field: "capabilities",
            maximumCount: 128)
        let operatorScopes = try self.normalizeList(
            route.operatorScopes,
            field: "operatorScopes",
            maximumCount: 64)
        guard capabilities.contains(self.routingCapability) else {
            throw OpenClawChatOutboxError.missingCapability(self.routingCapability)
        }
        for requiredScope in self.requiredOperatorScopes where !operatorScopes.contains(requiredScope) {
            throw OpenClawChatOutboxError.missingOperatorScope(requiredScope)
        }
        guard route.verifiedAt.timeIntervalSince1970.isFinite else {
            throw OpenClawChatOutboxError.invalidField("verifiedAt")
        }
        return OpenClawChatOutboxRouteSnapshot(
            routingContract: routingContract,
            capabilities: capabilities,
            operatorScopes: operatorScopes,
            verifiedAt: route.verifiedAt)
    }

    private static func normalizeDraft(_ draft: OpenClawChatOutboxDraft) throws
        -> OpenClawChatOutboxDraft
    {
        let rawCommandID = try self.normalizeIdentifier(
            draft.rawCommandID,
            field: "rawCommandID")
        guard !rawCommandID.hasSuffix(":user") else {
            throw OpenClawChatOutboxError.invalidField("rawCommandID")
        }
        let sessionKey = try self.normalizeIdentifier(draft.sessionKey, field: "sessionKey")
        guard draft.text.utf8.count <= self.maxTextBytes else {
            throw OpenClawChatOutboxError.textTooLarge(limit: self.maxTextBytes)
        }
        guard draft.attachments.count <= self.maxAttachmentsPerCommand else {
            throw OpenClawChatOutboxError.attachmentCountExceeded(
                limit: self.maxAttachmentsPerCommand)
        }
        var attachmentBytes = 0
        var normalizedAttachments: [OpenClawChatOutboxAttachment] = []
        normalizedAttachments.reserveCapacity(draft.attachments.count)
        for attachment in draft.attachments {
            guard attachment.data.count <= self.maxAttachmentBytes else {
                throw OpenClawChatOutboxError.attachmentTooLarge(limit: self.maxAttachmentBytes)
            }
            let (nextBytes, overflow) = attachmentBytes.addingReportingOverflow(attachment.data.count)
            guard !overflow, nextBytes <= self.maxAttachmentBytesPerCommand else {
                throw OpenClawChatOutboxError.attachmentBudgetExceeded(
                    limit: self.maxAttachmentBytesPerCommand)
            }
            attachmentBytes = nextBytes
            normalizedAttachments.append(OpenClawChatOutboxAttachment(
                type: try self.normalizeIdentifier(attachment.type, field: "attachment.type"),
                mimeType: try self.normalizeIdentifier(
                    attachment.mimeType,
                    field: "attachment.mimeType"),
                fileName: try self.normalizeIdentifier(
                    attachment.fileName,
                    field: "attachment.fileName"),
                data: attachment.data))
        }
        guard !draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
            !normalizedAttachments.isEmpty
        else {
            throw OpenClawChatOutboxError.invalidField("payload")
        }
        guard draft.createdAt.timeIntervalSince1970.isFinite else {
            throw OpenClawChatOutboxError.invalidField("createdAt")
        }
        let thinkingLevel = draft.thinkingLevel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard thinkingLevel.utf8.count <= 128 else {
            throw OpenClawChatOutboxError.invalidField("thinkingLevel")
        }
        return OpenClawChatOutboxDraft(
            rawCommandID: rawCommandID,
            sessionKey: sessionKey,
            text: draft.text,
            attachments: normalizedAttachments,
            thinkingLevel: thinkingLevel,
            route: try self.normalizeRoute(draft.route),
            createdAt: draft.createdAt)
    }

    private func validatedQueue(
        stableGatewayID: String,
        scope: Scope) throws -> DatabaseQueue
    {
        guard self.acceptsStores, let queue = self.queue else {
            throw OpenClawChatOutboxError.closed
        }
        guard !self.storageUnavailable else {
            throw OpenClawChatOutboxError.storageUnavailable
        }
        guard scope.databaseGeneration == self.databaseGeneration,
              scope.gatewayGeneration == self.gatewayGenerations[stableGatewayID, default: 0],
              !self.blockedGatewayIDs.contains(stableGatewayID)
        else {
            throw OpenClawChatOutboxError.retired
        }
        return queue
    }

    private func perform<T>(
        stableGatewayID: String,
        scope: Scope,
        _ operation: (DatabaseQueue) throws -> T) throws -> T
    {
        let queue = try self.validatedQueue(stableGatewayID: stableGatewayID, scope: scope)
        do {
            try Self.finishPendingCheckpoint(queue)
            try Self.applyFileSecurity(at: self.databaseURL)
        } catch {
            self.storageUnavailable = true
            throw OpenClawChatOutboxError.storageUnavailable
        }

        do {
            let result = try operation(queue)
            self.finishPostCommitMaintenance(queue)
            return result
        } catch let error as OpenClawChatOutboxError {
            self.finishPostCommitMaintenance(queue)
            if error == .storageUnavailable {
                self.storageUnavailable = true
            }
            throw error
        } catch {
            self.finishPostCommitMaintenance(queue)
            self.storageUnavailable = true
            throw OpenClawChatOutboxError.storageUnavailable
        }
    }

    /// Post-commit housekeeping must never turn a durable enqueue into a
    /// reported enqueue failure. A failure retires all future operations until
    /// `securePurgeAll()` reconstructs the database, while the committed result
    /// is still returned to the caller so it can safely clear its draft.
    private func finishPostCommitMaintenance(_ queue: DatabaseQueue) {
        if self.debugFailNextPostCommitMaintenance {
            self.debugFailNextPostCommitMaintenance = false
            self.storageUnavailable = true
            return
        }
        do {
            try Self.finishPendingCheckpoint(queue)
            try Self.applyFileSecurity(at: self.databaseURL)
        } catch {
            self.storageUnavailable = true
        }
    }

    private static func encodeList(_ values: [String]) throws -> String {
        let data = try JSONEncoder().encode(values)
        guard let string = String(data: data, encoding: .utf8) else {
            throw OpenClawChatOutboxError.storageUnavailable
        }
        return string
    }

    private static func decodeList(_ value: String) throws -> [String] {
        guard let data = value.data(using: .utf8) else {
            throw OpenClawChatOutboxError.storageUnavailable
        }
        return try JSONDecoder().decode([String].self, from: data)
    }

    private static func finishPendingCheckpoint(_ queue: DatabaseQueue) throws {
        let needsCheckpoint = try queue.read { db in
            (try Int.fetchOne(
                db,
                sql: "SELECT needs_checkpoint FROM outbox_maintenance WHERE id = 1") ?? 1) == 1
        }
        guard needsCheckpoint else { return }
        _ = try queue.writeWithoutTransaction { db in try db.checkpoint(.truncate) }
        try queue.write { db in
            try db.execute(sql: "UPDATE outbox_maintenance SET needs_checkpoint = 0 WHERE id = 1")
        }
    }
}

extension OpenClawChatOutboxDatabase {
    fileprivate func saveVerifiedRouteSnapshot(
        _ snapshot: OpenClawChatOutboxRouteSnapshot,
        stableGatewayID: String,
        scope: Scope) throws
    {
        let snapshot = try Self.normalizeRoute(snapshot)
        try self.perform(stableGatewayID: stableGatewayID, scope: scope) { queue in
            let capabilitiesJSON = try Self.encodeList(snapshot.capabilities)
            let scopesJSON = try Self.encodeList(snapshot.operatorScopes)
            try queue.write { db in
                try db.execute(
                    sql: """
                    INSERT INTO gateway_route_snapshots(
                        stable_gateway_id, routing_contract, capabilities_json,
                        operator_scopes_json, verified_at
                    ) VALUES (?, ?, ?, ?, ?)
                    ON CONFLICT(stable_gateway_id) DO UPDATE SET
                        routing_contract = excluded.routing_contract,
                        capabilities_json = excluded.capabilities_json,
                        operator_scopes_json = excluded.operator_scopes_json,
                        verified_at = excluded.verified_at
                    WHERE excluded.verified_at >= gateway_route_snapshots.verified_at
                    """,
                    arguments: [
                        stableGatewayID,
                        snapshot.routingContract,
                        capabilitiesJSON,
                        scopesJSON,
                        snapshot.verifiedAt.timeIntervalSince1970,
                    ])
                // Keep route evidence only for gateways that still own queued
                // work, plus the gateway that was just verified. A pruned
                // gateway must be re-verified before it can enqueue again.
                try db.execute(
                    sql: """
                    DELETE FROM gateway_route_snapshots
                    WHERE stable_gateway_id <> ? AND NOT EXISTS (
                        SELECT 1 FROM outbox_commands
                        WHERE outbox_commands.stable_gateway_id =
                              gateway_route_snapshots.stable_gateway_id
                    )
                    """,
                    arguments: [stableGatewayID])
            }
        }
    }

    fileprivate func loadVerifiedRouteSnapshot(
        stableGatewayID: String,
        scope: Scope) throws -> OpenClawChatOutboxRouteSnapshot?
    {
        try self.perform(stableGatewayID: stableGatewayID, scope: scope) { queue in
            try queue.read { db in
                guard let row = try Row.fetchOne(
                    db,
                    sql: """
                    SELECT routing_contract, capabilities_json, operator_scopes_json, verified_at
                    FROM gateway_route_snapshots WHERE stable_gateway_id = ?
                    """,
                    arguments: [stableGatewayID])
                else { return nil }
                return try Self.routeSnapshot(from: row)
            }
        }
    }

    fileprivate func persistBeforeDraftClear(
        _ draft: OpenClawChatOutboxDraft,
        stableGatewayID: String,
        scope: Scope,
        now: Date) throws -> OpenClawChatOutboxCommand
    {
        let draft = try Self.normalizeDraft(draft)
        guard now.timeIntervalSince1970.isFinite,
              draft.createdAt.addingTimeInterval(Self.commandLifetime) > now
        else {
            throw OpenClawChatOutboxError.invalidField("createdAt")
        }
        return try self.perform(stableGatewayID: stableGatewayID, scope: scope) { queue in
            try Self.expireAllCommands(in: queue, now: now)
            try queue.write { db in
                guard let verifiedRoute = try Self.readVerifiedRouteSnapshot(
                    db,
                    stableGatewayID: stableGatewayID)
                else {
                    throw OpenClawChatOutboxError.routeSnapshotUnavailable
                }
                guard verifiedRoute == draft.route else {
                    throw OpenClawChatOutboxError.routeSnapshotChanged
                }
                let duplicateActive = try Int.fetchOne(
                    db,
                    sql: """
                    SELECT 1 FROM outbox_commands
                    WHERE stable_gateway_id = ? AND raw_command_id = ?
                    """,
                    arguments: [stableGatewayID, draft.rawCommandID]) != nil
                let duplicateReceipt = try Int.fetchOne(
                    db,
                    sql: """
                    SELECT 1 FROM outbox_receipts
                    WHERE stable_gateway_id = ? AND raw_command_id = ?
                    """,
                    arguments: [stableGatewayID, draft.rawCommandID]) != nil
                guard !duplicateActive, !duplicateReceipt else {
                    throw OpenClawChatOutboxError.duplicateCommandID
                }
                let count = try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM outbox_commands WHERE stable_gateway_id = ?",
                    arguments: [stableGatewayID]) ?? 0
                guard count < Self.maxUnresolvedCommandsPerGateway else {
                    throw OpenClawChatOutboxError.capacityReached(
                        limit: Self.maxUnresolvedCommandsPerGateway)
                }
                let installationCount = try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM outbox_commands") ?? 0
                guard installationCount < Self.maxUnresolvedCommands else {
                    throw OpenClawChatOutboxError.capacityReached(
                        limit: Self.maxUnresolvedCommands)
                }
                let attachmentBytes = draft.attachments.reduce(0) { $0 + $1.data.count }
                let storedAttachmentBytes = try Int.fetchOne(
                    db,
                    sql: """
                    SELECT COALESCE(SUM(attachment_bytes), 0)
                    FROM outbox_commands WHERE stable_gateway_id = ?
                    """,
                    arguments: [stableGatewayID]) ?? 0
                guard storedAttachmentBytes <= Self.maxAttachmentBytesPerGateway - attachmentBytes else {
                    throw OpenClawChatOutboxError.attachmentBudgetExceeded(
                        limit: Self.maxAttachmentBytesPerGateway)
                }
                let installationAttachmentBytes = try Int.fetchOne(
                    db,
                    sql: "SELECT COALESCE(SUM(attachment_bytes), 0) FROM outbox_commands") ?? 0
                guard installationAttachmentBytes <=
                    Self.maxAttachmentBytesPerInstallation - attachmentBytes
                else {
                    throw OpenClawChatOutboxError.attachmentBudgetExceeded(
                        limit: Self.maxAttachmentBytesPerInstallation)
                }
                let capabilitiesJSON = try Self.encodeList(draft.route.capabilities)
                let scopesJSON = try Self.encodeList(draft.route.operatorScopes)
                let createdAt = draft.createdAt.timeIntervalSince1970
                try db.execute(
                    sql: """
                    INSERT INTO outbox_commands(
                        stable_gateway_id, raw_command_id, session_key, text, thinking_level,
                        routing_contract, capabilities_json, operator_scopes_json,
                        route_verified_at, created_at, expires_at, outcome, outcome_at,
                        attachment_bytes
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'not_dispatched', ?, ?)
                    """,
                    arguments: [
                        stableGatewayID,
                        draft.rawCommandID,
                        draft.sessionKey,
                        draft.text,
                        draft.thinkingLevel,
                        draft.route.routingContract,
                        capabilitiesJSON,
                        scopesJSON,
                        draft.route.verifiedAt.timeIntervalSince1970,
                        createdAt,
                        createdAt + Self.commandLifetime,
                        createdAt,
                        attachmentBytes,
                    ])
                for (position, attachment) in draft.attachments.enumerated() {
                    try db.execute(
                        sql: """
                        INSERT INTO outbox_attachments(
                            stable_gateway_id, raw_command_id, position,
                            type, mime_type, file_name, payload
                        ) VALUES (?, ?, ?, ?, ?, ?, ?)
                        """,
                        arguments: [
                            stableGatewayID,
                            draft.rawCommandID,
                            position,
                            attachment.type,
                            attachment.mimeType,
                            attachment.fileName,
                            attachment.data,
                        ])
                }
                guard let command = try Self.readCommand(
                    db,
                    stableGatewayID: stableGatewayID,
                    rawCommandID: draft.rawCommandID)
                else {
                    throw OpenClawChatOutboxError.storageUnavailable
                }
                return command
            }
        }
    }

    fileprivate func loadQueueState(
        stableGatewayID: String,
        scope: Scope,
        now: Date) throws -> OpenClawChatOutboxQueueState
    {
        try self.perform(stableGatewayID: stableGatewayID, scope: scope) { queue in
            try Self.expireCommands(in: queue, stableGatewayID: stableGatewayID, now: now)
            return try queue.read { db in
                return OpenClawChatOutboxQueueState(
                    commands: try Self.readCommands(db, stableGatewayID: stableGatewayID))
            }
        }
    }

    fileprivate func claimNext(
        stableGatewayID: String,
        scope: Scope,
        now: Date) throws -> OpenClawChatOutboxClaim?
    {
        try self.perform(stableGatewayID: stableGatewayID, scope: scope) { queue in
            try Self.expireCommands(in: queue, stableGatewayID: stableGatewayID, now: now)
            try queue.write { db in
                guard let row = try Row.fetchOne(
                    db,
                    sql: """
                    SELECT raw_command_id, outcome, claim_token
                    FROM outbox_commands
                    WHERE stable_gateway_id = ?
                    ORDER BY enqueue_sequence LIMIT 1
                    """,
                    arguments: [stableGatewayID])
                else { return nil }
                let outcome: String = row["outcome"]
                let existingClaim: String? = row["claim_token"]
                guard outcome == OpenClawChatOutboxOutcome.notDispatched.rawValue,
                      existingClaim == nil
                else { return nil }
                let rawCommandID: String = row["raw_command_id"]
                let token = UUID().uuidString.lowercased()
                try db.execute(
                    sql: """
                    UPDATE outbox_commands
                    SET outcome = 'ambiguous', outcome_at = ?, claim_token = ?, claimed_at = ?,
                        claim_process_id = ?, ack_run_id = NULL, failure_code = NULL
                    WHERE stable_gateway_id = ? AND raw_command_id = ?
                      AND outcome = 'not_dispatched' AND claim_token IS NULL
                    """,
                    arguments: [
                        now.timeIntervalSince1970,
                        token,
                        now.timeIntervalSince1970,
                        self.claimProcessID,
                        stableGatewayID,
                        rawCommandID,
                    ])
                guard db.changesCount == 1,
                      let command = try Self.readCommand(
                          db,
                          stableGatewayID: stableGatewayID,
                          rawCommandID: rawCommandID)
                else { return nil }
                return OpenClawChatOutboxClaim(
                    command: command,
                    token: token,
                    processID: self.claimProcessID)
            }
        }
    }

    fileprivate func recordDispatchOutcome(
        _ outcome: OpenClawChatOutboxOutcome,
        claim: OpenClawChatOutboxClaim,
        stableGatewayID: String,
        scope: Scope,
        at: Date,
        ackRunID: String?,
        failureCode: String?) throws -> Bool
    {
        guard !outcome.isTerminal else { throw OpenClawChatOutboxError.invalidTransition }
        guard claim.command.stableGatewayID == stableGatewayID else {
            throw OpenClawChatOutboxError.staleClaim
        }
        if outcome == .accepted {
            guard ackRunID == claim.command.rawCommandID else {
                throw OpenClawChatOutboxError.canonicalIdentityMismatch
            }
        } else if ackRunID != nil {
            // Any known matching ACK is accepted evidence; it must never be
            // stored in a retryable state whose later transition clears it.
            throw OpenClawChatOutboxError.invalidTransition
        }
        if let failureCode, failureCode.utf8.count > 256 {
            throw OpenClawChatOutboxError.invalidField("failureCode")
        }
        return try self.perform(stableGatewayID: stableGatewayID, scope: scope) { queue in
            try queue.write { db in
                try db.execute(
                    sql: """
                    UPDATE outbox_commands
                    SET outcome = ?, outcome_at = ?, ack_run_id = ?, failure_code = ?,
                        claim_token = NULL, claimed_at = NULL, claim_process_id = NULL
                    WHERE stable_gateway_id = ? AND raw_command_id = ?
                      AND outcome = 'ambiguous' AND claim_token = ? AND claim_process_id = ?
                    """,
                    arguments: [
                        outcome.rawValue,
                        at.timeIntervalSince1970,
                        ackRunID,
                        failureCode,
                        stableGatewayID,
                        claim.command.rawCommandID,
                        claim.token,
                        claim.processID,
                    ])
                return db.changesCount == 1
            }
        }
    }

    fileprivate func retryAmbiguousAfterReview(
        rawCommandID: String,
        stableGatewayID: String,
        scope: Scope,
        reviewedAt: Date) throws -> Bool
    {
        let rawCommandID = try Self.normalizeIdentifier(rawCommandID, field: "rawCommandID")
        return try self.requeue(
            rawCommandID: rawCommandID,
            expectedOutcome: .ambiguous,
            stableGatewayID: stableGatewayID,
            scope: scope,
            at: reviewedAt)
    }

    fileprivate func retryDispatchRejected(
        rawCommandID: String,
        stableGatewayID: String,
        scope: Scope,
        reviewedAt: Date) throws -> Bool
    {
        let rawCommandID = try Self.normalizeIdentifier(rawCommandID, field: "rawCommandID")
        return try self.requeue(
            rawCommandID: rawCommandID,
            expectedOutcome: .dispatchRejected,
            stableGatewayID: stableGatewayID,
            scope: scope,
            at: reviewedAt)
    }

    private func requeue(
        rawCommandID: String,
        expectedOutcome: OpenClawChatOutboxOutcome,
        stableGatewayID: String,
        scope: Scope,
        at: Date) throws -> Bool
    {
        try self.perform(stableGatewayID: stableGatewayID, scope: scope) { queue in
            try queue.write { db in
                try db.execute(
                    sql: """
                    UPDATE outbox_commands
                    SET outcome = 'not_dispatched', outcome_at = ?, ack_run_id = NULL,
                        failure_code = NULL, claim_token = NULL, claimed_at = NULL,
                        claim_process_id = NULL
                    WHERE stable_gateway_id = ? AND raw_command_id = ? AND outcome = ?
                      AND claim_token IS NULL AND claimed_at IS NULL AND claim_process_id IS NULL
                    """,
                    arguments: [
                        at.timeIntervalSince1970,
                        stableGatewayID,
                        rawCommandID,
                        expectedOutcome.rawValue,
                    ])
                return db.changesCount == 1
            }
        }
    }

    fileprivate func retryAfterRouteReview(
        rawCommandID: String,
        newRoute: OpenClawChatOutboxRouteSnapshot,
        stableGatewayID: String,
        scope: Scope,
        reviewedAt: Date) throws -> Bool
    {
        let rawCommandID = try Self.normalizeIdentifier(rawCommandID, field: "rawCommandID")
        let newRoute = try Self.normalizeRoute(newRoute)
        return try self.perform(stableGatewayID: stableGatewayID, scope: scope) { queue in
            try queue.write { db in
                guard try Self.readVerifiedRouteSnapshot(db, stableGatewayID: stableGatewayID) == newRoute else {
                    throw OpenClawChatOutboxError.routeSnapshotChanged
                }
                try db.execute(
                    sql: """
                    UPDATE outbox_commands
                    SET routing_contract = ?, capabilities_json = ?, operator_scopes_json = ?,
                        route_verified_at = ?, outcome = 'not_dispatched', outcome_at = ?,
                        ack_run_id = NULL, failure_code = NULL,
                        claim_token = NULL, claimed_at = NULL, claim_process_id = NULL
                    WHERE stable_gateway_id = ? AND raw_command_id = ?
                      AND outcome = 'blocked_route_changed'
                    """,
                    arguments: [
                        newRoute.routingContract,
                        try Self.encodeList(newRoute.capabilities),
                        try Self.encodeList(newRoute.operatorScopes),
                        newRoute.verifiedAt.timeIntervalSince1970,
                        reviewedAt.timeIntervalSince1970,
                        stableGatewayID,
                        rawCommandID,
                    ])
                return db.changesCount == 1
            }
        }
    }

    fileprivate func confirmCanonicalHistory(
        rawCommandID: String,
        canonicalUserIdempotencyKey: String,
        stableGatewayID: String,
        scope: Scope,
        confirmedAt: Date) throws -> Bool
    {
        let rawCommandID = try Self.normalizeIdentifier(rawCommandID, field: "rawCommandID")
        guard canonicalUserIdempotencyKey == "\(rawCommandID):user" else {
            throw OpenClawChatOutboxError.canonicalIdentityMismatch
        }
        return try self.perform(stableGatewayID: stableGatewayID, scope: scope) { queue in
            try queue.write { db in
                let command = try Row.fetchOne(
                    db,
                    sql: """
                    SELECT ack_run_id, failure_code FROM outbox_commands
                    WHERE stable_gateway_id = ? AND raw_command_id = ?
                    """,
                    arguments: [stableGatewayID, rawCommandID])
                let receiptExists = try Int.fetchOne(
                    db,
                    sql: """
                    SELECT 1 FROM outbox_receipts
                    WHERE stable_gateway_id = ? AND raw_command_id = ?
                    """,
                    arguments: [stableGatewayID, rawCommandID]) != nil
                guard command != nil || receiptExists else { return false }
                let ackRunID: String? = command?["ack_run_id"]
                try Self.upsertReceipt(
                    db,
                    stableGatewayID: stableGatewayID,
                    rawCommandID: rawCommandID,
                    outcome: .canonicalHistoryConfirmed,
                    recordedAt: confirmedAt,
                    ackRunID: ackRunID,
                    failureCode: nil,
                    canonicalUserIdempotencyKey: canonicalUserIdempotencyKey)
                try db.execute(
                    sql: """
                    DELETE FROM outbox_commands
                    WHERE stable_gateway_id = ? AND raw_command_id = ?
                    """,
                    arguments: [stableGatewayID, rawCommandID])
                try db.execute(sql: "UPDATE outbox_maintenance SET needs_checkpoint = 1 WHERE id = 1")
                try Self.pruneReceipts(db, stableGatewayID: stableGatewayID)
                return true
            }
        }
    }

    fileprivate func cancel(
        rawCommandID: String,
        stableGatewayID: String,
        scope: Scope,
        at: Date) throws -> Bool
    {
        let rawCommandID = try Self.normalizeIdentifier(rawCommandID, field: "rawCommandID")
        return try self.perform(stableGatewayID: stableGatewayID, scope: scope) { queue in
            try queue.write { db in
                guard let outcomeRaw = try String.fetchOne(
                    db,
                    sql: """
                    SELECT outcome FROM outbox_commands
                    WHERE stable_gateway_id = ? AND raw_command_id = ?
                    """,
                    arguments: [stableGatewayID, rawCommandID]),
                    let outcome = OpenClawChatOutboxOutcome(rawValue: outcomeRaw)
                else { return false }
                guard outcome == .notDispatched || outcome == .dispatchRejected ||
                    outcome == .blockedRouteChanged
                else {
                    throw OpenClawChatOutboxError.invalidTransition
                }
                try Self.upsertReceipt(
                    db,
                    stableGatewayID: stableGatewayID,
                    rawCommandID: rawCommandID,
                    outcome: .cancelled,
                    recordedAt: at,
                    ackRunID: nil,
                    failureCode: nil,
                    canonicalUserIdempotencyKey: nil)
                try db.execute(
                    sql: """
                    DELETE FROM outbox_commands
                    WHERE stable_gateway_id = ? AND raw_command_id = ?
                    """,
                    arguments: [stableGatewayID, rawCommandID])
                try db.execute(sql: "UPDATE outbox_maintenance SET needs_checkpoint = 1 WHERE id = 1")
                try Self.pruneReceipts(db, stableGatewayID: stableGatewayID)
                return true
            }
        }
    }

    fileprivate func loadRecentReceipts(
        stableGatewayID: String,
        scope: Scope) throws -> [OpenClawChatOutboxReceipt]
    {
        try self.perform(stableGatewayID: stableGatewayID, scope: scope) { queue in
            try queue.read { db in
                let rows = try Row.fetchAll(
                    db,
                    sql: """
                    SELECT stable_gateway_id, raw_command_id, outcome, recorded_at,
                           ack_run_id, failure_code, canonical_user_idempotency_key
                    FROM outbox_receipts
                    WHERE stable_gateway_id = ?
                    ORDER BY recorded_at DESC, receipt_sequence DESC
                    LIMIT ?
                    """,
                    arguments: [stableGatewayID, Self.maxRecentReceiptsPerGateway])
                return try rows.map(Self.receipt(from:))
            }
        }
    }

    fileprivate func securePurgeGateway(stableGatewayID: String, scope: Scope) throws {
        _ = try self.validatedQueue(stableGatewayID: stableGatewayID, scope: scope)
        self.gatewayGenerations[stableGatewayID, default: 0] &+= 1
        self.blockedGatewayIDs.insert(stableGatewayID)
        guard let queue = self.queue else { throw OpenClawChatOutboxError.closed }
        do {
            try queue.write { db in
                try db.execute(
                    sql: "DELETE FROM outbox_commands WHERE stable_gateway_id = ?",
                    arguments: [stableGatewayID])
                try db.execute(
                    sql: "DELETE FROM outbox_receipts WHERE stable_gateway_id = ?",
                    arguments: [stableGatewayID])
                try db.execute(
                    sql: "DELETE FROM gateway_route_snapshots WHERE stable_gateway_id = ?",
                    arguments: [stableGatewayID])
                try db.execute(sql: "UPDATE outbox_maintenance SET needs_checkpoint = 1 WHERE id = 1")
            }
            try Self.finishPendingCheckpoint(queue)
            try Self.applyFileSecurity(at: self.databaseURL)
            self.blockedGatewayIDs.remove(stableGatewayID)
        } catch {
            self.storageUnavailable = true
            throw OpenClawChatOutboxError.storageUnavailable
        }
    }
}

extension OpenClawChatOutboxDatabase {
    private static func readVerifiedRouteSnapshot(
        _ db: Database,
        stableGatewayID: String) throws -> OpenClawChatOutboxRouteSnapshot?
    {
        guard let row = try Row.fetchOne(
            db,
            sql: """
            SELECT routing_contract, capabilities_json, operator_scopes_json, verified_at
            FROM gateway_route_snapshots WHERE stable_gateway_id = ?
            """,
            arguments: [stableGatewayID])
        else { return nil }
        return try self.routeSnapshot(from: row)
    }

    private static func routeSnapshot(from row: Row) throws -> OpenClawChatOutboxRouteSnapshot {
        let capabilitiesJSON: String = row["capabilities_json"]
        let scopesJSON: String = row["operator_scopes_json"]
        return OpenClawChatOutboxRouteSnapshot(
            routingContract: row["routing_contract"],
            capabilities: try self.decodeList(capabilitiesJSON),
            operatorScopes: try self.decodeList(scopesJSON),
            verifiedAt: Date(timeIntervalSince1970: row["verified_at"]))
    }

    private static func readCommands(
        _ db: Database,
        stableGatewayID: String) throws -> [OpenClawChatOutboxCommand]
    {
        let rows = try Row.fetchAll(
            db,
            sql: """
            SELECT * FROM outbox_commands
            WHERE stable_gateway_id = ?
            ORDER BY enqueue_sequence
            """,
            arguments: [stableGatewayID])
        return try rows.map { try self.command(from: $0, in: db) }
    }

    private static func readCommand(
        _ db: Database,
        stableGatewayID: String,
        rawCommandID: String) throws -> OpenClawChatOutboxCommand?
    {
        guard let row = try Row.fetchOne(
            db,
            sql: """
            SELECT * FROM outbox_commands
            WHERE stable_gateway_id = ? AND raw_command_id = ?
            """,
            arguments: [stableGatewayID, rawCommandID])
        else { return nil }
        return try self.command(from: row, in: db)
    }

    private static func command(from row: Row, in db: Database) throws -> OpenClawChatOutboxCommand {
        let stableGatewayID: String = row["stable_gateway_id"]
        let rawCommandID: String = row["raw_command_id"]
        let attachmentRows = try Row.fetchAll(
            db,
            sql: """
            SELECT type, mime_type, file_name, payload
            FROM outbox_attachments
            WHERE stable_gateway_id = ? AND raw_command_id = ?
            ORDER BY position
            """,
            arguments: [stableGatewayID, rawCommandID])
        let attachments: [OpenClawChatOutboxAttachment] = attachmentRows.map { attachmentRow in
            OpenClawChatOutboxAttachment(
                type: attachmentRow["type"],
                mimeType: attachmentRow["mime_type"],
                fileName: attachmentRow["file_name"],
                data: attachmentRow["payload"])
        }
        let outcomeRaw: String = row["outcome"]
        guard let outcome = OpenClawChatOutboxOutcome(rawValue: outcomeRaw), !outcome.isTerminal else {
            throw OpenClawChatOutboxError.storageUnavailable
        }
        let capabilitiesJSON: String = row["capabilities_json"]
        let scopesJSON: String = row["operator_scopes_json"]
        return OpenClawChatOutboxCommand(
            enqueueSequence: row["enqueue_sequence"],
            stableGatewayID: stableGatewayID,
            rawCommandID: rawCommandID,
            sessionKey: row["session_key"],
            text: row["text"],
            attachments: attachments,
            thinkingLevel: row["thinking_level"],
            route: OpenClawChatOutboxRouteSnapshot(
                routingContract: row["routing_contract"],
                capabilities: try self.decodeList(capabilitiesJSON),
                operatorScopes: try self.decodeList(scopesJSON),
                verifiedAt: Date(timeIntervalSince1970: row["route_verified_at"])),
            createdAt: Date(timeIntervalSince1970: row["created_at"]),
            expiresAt: Date(timeIntervalSince1970: row["expires_at"]),
            outcome: outcome,
            outcomeAt: Date(timeIntervalSince1970: row["outcome_at"]),
            ackRunID: row["ack_run_id"],
            failureCode: row["failure_code"])
    }

    private static func receipt(from row: Row) throws -> OpenClawChatOutboxReceipt {
        let outcomeRaw: String = row["outcome"]
        guard let outcome = OpenClawChatOutboxOutcome(rawValue: outcomeRaw), outcome.isTerminal else {
            throw OpenClawChatOutboxError.storageUnavailable
        }
        return OpenClawChatOutboxReceipt(
            stableGatewayID: row["stable_gateway_id"],
            rawCommandID: row["raw_command_id"],
            outcome: outcome,
            recordedAt: Date(timeIntervalSince1970: row["recorded_at"]),
            ackRunID: row["ack_run_id"],
            failureCode: row["failure_code"],
            canonicalUserIdempotencyKey: row["canonical_user_idempotency_key"])
    }

    private static func expireCommands(
        in queue: DatabaseQueue,
        stableGatewayID: String,
        now: Date) throws
    {
        try queue.write { db in
            _ = try self.applyExpirations(db, stableGatewayID: stableGatewayID, now: now)
        }
    }

    /// Global capacity must not remain occupied by expired work belonging to a
    /// gateway that is no longer opened. Expiration preserves gateway-scoped
    /// receipts while removing every due payload before installation-wide
    /// capacity accounting.
    private static func expireAllCommands(in queue: DatabaseQueue, now: Date) throws {
        try queue.write { db in
            let gatewayIDs = try String.fetchAll(
                db,
                sql: """
                SELECT DISTINCT stable_gateway_id FROM outbox_commands
                WHERE expires_at <= ? ORDER BY stable_gateway_id
                """,
                arguments: [now.timeIntervalSince1970])
            for stableGatewayID in gatewayIDs {
                _ = try self.applyExpirations(
                    db,
                    stableGatewayID: stableGatewayID,
                    now: now)
            }
        }
    }

    private static func applyExpirations(
        _ db: Database,
        stableGatewayID: String,
        now: Date) throws -> Bool
    {
        let rows = try Row.fetchAll(
            db,
            sql: """
            SELECT raw_command_id, ack_run_id FROM outbox_commands
            WHERE stable_gateway_id = ? AND expires_at <= ?
            ORDER BY enqueue_sequence
            """,
            arguments: [stableGatewayID, now.timeIntervalSince1970])
        for row in rows {
            let rawCommandID: String = row["raw_command_id"]
            let ackRunID: String? = row["ack_run_id"]
            try self.upsertReceipt(
                db,
                stableGatewayID: stableGatewayID,
                rawCommandID: rawCommandID,
                outcome: .expired,
                recordedAt: now,
                ackRunID: ackRunID,
                failureCode: "expired",
                canonicalUserIdempotencyKey: nil)
            // The cascading child delete plus secure_delete scrubs payload
            // cells before the next WAL checkpoint.
            try db.execute(
                sql: """
                DELETE FROM outbox_commands
                WHERE stable_gateway_id = ? AND raw_command_id = ?
                """,
                arguments: [stableGatewayID, rawCommandID])
        }
        if !rows.isEmpty {
            try self.pruneReceipts(db, stableGatewayID: stableGatewayID)
            try db.execute(sql: "UPDATE outbox_maintenance SET needs_checkpoint = 1 WHERE id = 1")
        }
        return !rows.isEmpty
    }

    private static func upsertReceipt(
        _ db: Database,
        stableGatewayID: String,
        rawCommandID: String,
        outcome: OpenClawChatOutboxOutcome,
        recordedAt: Date,
        ackRunID: String?,
        failureCode: String?,
        canonicalUserIdempotencyKey: String?) throws
    {
        guard outcome.isTerminal else { throw OpenClawChatOutboxError.invalidTransition }
        try db.execute(
            sql: """
            INSERT INTO outbox_receipts(
                stable_gateway_id, raw_command_id, outcome, recorded_at,
                ack_run_id, failure_code, canonical_user_idempotency_key
            ) VALUES (?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(stable_gateway_id, raw_command_id) DO UPDATE SET
                outcome = excluded.outcome,
                recorded_at = excluded.recorded_at,
                ack_run_id = COALESCE(excluded.ack_run_id, outbox_receipts.ack_run_id),
                failure_code = excluded.failure_code,
                canonical_user_idempotency_key = excluded.canonical_user_idempotency_key
            """,
            arguments: [
                stableGatewayID,
                rawCommandID,
                outcome.rawValue,
                recordedAt.timeIntervalSince1970,
                ackRunID,
                failureCode,
                canonicalUserIdempotencyKey,
            ])
    }

    private static func pruneReceipts(_ db: Database, stableGatewayID: String) throws {
        try db.execute(
            sql: """
            DELETE FROM outbox_receipts
            WHERE receipt_sequence NOT IN (
                SELECT receipt_sequence FROM outbox_receipts
                ORDER BY recorded_at DESC, receipt_sequence DESC LIMIT ?
            )
            """,
            arguments: [self.maxRecentReceipts])
        try db.execute(
            sql: """
            DELETE FROM outbox_receipts
            WHERE stable_gateway_id = ? AND receipt_sequence NOT IN (
                SELECT receipt_sequence FROM outbox_receipts
                WHERE stable_gateway_id = ?
                ORDER BY recorded_at DESC, receipt_sequence DESC LIMIT ?
            )
            """,
            arguments: [stableGatewayID, stableGatewayID, self.maxRecentReceiptsPerGateway])
    }
}

extension OpenClawChatOutboxDatabase {
    struct DebugState: Equatable, Sendable {
        let journalMode: String
        let busyTimeoutMilliseconds: Int
        let foreignKeysEnabled: Bool
        let secureDeleteEnabled: Bool
        let migrationIdentifiers: [String]
        let commandCount: Int
        let attachmentCount: Int
        let receiptCount: Int
        let routeSnapshotCount: Int
        let needsCheckpoint: Bool
    }

    func debugState() throws -> DebugState {
        guard self.acceptsStores, let queue = self.queue else {
            throw OpenClawChatOutboxError.closed
        }
        do {
            return try queue.read { db in
                DebugState(
                    journalMode: try String.fetchOne(db, sql: "PRAGMA journal_mode") ?? "",
                    busyTimeoutMilliseconds: try Int.fetchOne(
                        db,
                        sql: "PRAGMA busy_timeout") ?? 0,
                    foreignKeysEnabled: (try Int.fetchOne(db, sql: "PRAGMA foreign_keys") ?? 0) == 1,
                    secureDeleteEnabled: (try Int.fetchOne(db, sql: "PRAGMA secure_delete") ?? 0) == 1,
                    migrationIdentifiers: try String.fetchAll(
                        db,
                        sql: "SELECT identifier FROM grdb_migrations ORDER BY rowid"),
                    commandCount: try Int.fetchOne(
                        db,
                        sql: "SELECT COUNT(*) FROM outbox_commands") ?? 0,
                    attachmentCount: try Int.fetchOne(
                        db,
                        sql: "SELECT COUNT(*) FROM outbox_attachments") ?? 0,
                    receiptCount: try Int.fetchOne(
                        db,
                        sql: "SELECT COUNT(*) FROM outbox_receipts") ?? 0,
                    routeSnapshotCount: try Int.fetchOne(
                        db,
                        sql: "SELECT COUNT(*) FROM gateway_route_snapshots") ?? 0,
                    needsCheckpoint: (try Int.fetchOne(
                        db,
                        sql: "SELECT needs_checkpoint FROM outbox_maintenance WHERE id = 1") ?? 1) == 1)
            }
        } catch {
            throw OpenClawChatOutboxError.storageUnavailable
        }
    }

    func debugInjectNextPostCommitMaintenanceFailure() {
        self.debugFailNextPostCommitMaintenance = true
    }

    /// Test-only crash-window fixture: commits the logical purge and durable
    /// checkpoint marker, but deliberately omits the checkpoint barrier.
    func debugCommitGatewayPurgeBeforeCheckpoint(stableGatewayID: String) throws {
        guard self.acceptsStores, !self.storageUnavailable, let queue = self.queue else {
            throw OpenClawChatOutboxError.storageUnavailable
        }
        let stableGatewayID = try Self.normalizeStableGatewayID(stableGatewayID)
        try queue.write { db in
            try db.execute(
                sql: "DELETE FROM outbox_commands WHERE stable_gateway_id = ?",
                arguments: [stableGatewayID])
            try db.execute(
                sql: "DELETE FROM outbox_receipts WHERE stable_gateway_id = ?",
                arguments: [stableGatewayID])
            try db.execute(
                sql: "DELETE FROM gateway_route_snapshots WHERE stable_gateway_id = ?",
                arguments: [stableGatewayID])
            try db.execute(sql: "UPDATE outbox_maintenance SET needs_checkpoint = 1 WHERE id = 1")
        }
    }
}
