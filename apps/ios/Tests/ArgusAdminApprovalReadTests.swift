import Foundation
import Testing
@testable import OpenClaw

struct ArgusAdminApprovalReadTests {
    private static let brokerID = "0123456789abcdef"
    private static let requestID = "11111111-2222-4333-8444-555555555555"

    private static func fixture() throws -> ([String: Any], Data) {
        let script = Data("Write-Output 'ok'\r\n".utf8)
        let args = try ArgusAdminApprovalCanonical.arguments([
            "Interface": .string("Ethernet"), "SkipAsSource": .boolean(false),
        ])
        let request: [String: Any] = [
            "request_id": requestID,
            "script_path": "scripts/windows/elevated/pc3-nic-config.ps1",
            "git_commit": String(repeating: "a", count: 40),
            "script_sha256": ArgusAdminApprovalCanonical.sha256(script),
            "args": ["Interface": "Ethernet", "SkipAsSource": false],
            "args_canonical": String(decoding: args, as: UTF8.self),
            "args_sha256": ArgusAdminApprovalCanonical.sha256(args),
            "nonce": String(repeating: "0", count: 32),
            "reason": "Restore the PC3 NIC setting",
            "issue": "ARG-431",
            "requested_by": "engineering",
            "requested_at": "2026-09-25T22:00:00Z",
            "expires_at": "2026-09-26T22:00:00Z",
        ]
        return (request, script)
    }

    private static func decode<T: Decodable>(_ value: [String: Any], as _: T.Type) throws -> T {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(T.self, from: JSONSerialization.data(withJSONObject: value))
    }

    @Test func exactRelayListAndGetProduceReviewableScript() throws {
        let (request, script) = try Self.fixture()
        let index = try Self.decode([
            "broker_id": Self.brokerID,
            "updated_at": "2026-09-25T22:01:00Z",
            "pending": [request],
        ], as: ArgusAdminApprovalIndex.self).validated()
        let selected = try #require(index.pending.first)
        let detail = try Self.decode([
            "broker_id": Self.brokerID,
            "request": request,
            "script_b64": script.base64EncodedString(),
        ], as: ArgusAdminApprovalDetail.self)
        let reviewed = try detail.reviewed(against: index, selected: selected)
        #expect(reviewed.scriptText == "Write-Output 'ok'\r\n")
        #expect(reviewed.request.requestId == Self.requestID)
    }

    @Test func lyingRelayCannotSwapBytesBrokerOrArguments() throws {
        let (request, script) = try Self.fixture()
        let index = try Self.decode([
            "broker_id": Self.brokerID,
            "updated_at": "2026-09-25T22:01:00Z",
            "pending": [request],
        ], as: ArgusAdminApprovalIndex.self).validated()
        let selected = try #require(index.pending.first)
        let wrongBroker = try Self.decode([
            "broker_id": "ffffffffffffffff", "request": request,
            "script_b64": script.base64EncodedString(),
        ], as: ArgusAdminApprovalDetail.self)
        #expect(throws: ArgusAdminApprovalReadError.self) {
            try wrongBroker.reviewed(against: index, selected: selected)
        }
        let wrongScript = try Self.decode([
            "broker_id": Self.brokerID, "request": request,
            "script_b64": Data("Write-Output 'changed'\r\n".utf8).base64EncodedString(),
        ], as: ArgusAdminApprovalDetail.self)
        #expect(throws: ArgusAdminApprovalCanonical.FormatError.self) {
            try wrongScript.reviewed(against: index, selected: selected)
        }
        var altered = request
        altered["args"] = ["Interface": "Wi-Fi", "SkipAsSource": false]
        let swapped = try Self.decode([
            "broker_id": Self.brokerID, "request": altered,
            "script_b64": script.base64EncodedString(),
        ], as: ArgusAdminApprovalDetail.self)
        #expect(throws: ArgusAdminApprovalReadError.self) {
            try swapped.reviewed(against: index, selected: selected)
        }
    }

    @Test func duplicateOrTamperedListIsNotReviewable() throws {
        let (request, _) = try Self.fixture()
        let duplicate = try Self.decode([
            "broker_id": Self.brokerID, "updated_at": "2026-09-25T22:01:00Z",
            "pending": [request, request],
        ], as: ArgusAdminApprovalIndex.self)
        #expect(throws: ArgusAdminApprovalReadError.self) { try duplicate.validated() }

        var tampered = request
        tampered["args_canonical"] = "{}"
        let index = try Self.decode([
            "broker_id": Self.brokerID, "updated_at": "2026-09-25T22:01:00Z",
            "pending": [tampered],
        ], as: ArgusAdminApprovalIndex.self)
        #expect(throws: ArgusAdminApprovalReadError.self) { try index.validated() }
    }

    @Test func previousApprovedBytesProduceLocalChangesAndMissingOrAlteredBytesRefuse() throws {
        let (base, script) = try Self.fixture()
        let old = Data("Write-Output 'old'\r\n".utf8)
        let oldHash = ArgusAdminApprovalCanonical.sha256(old)
        let oldCommit = String(repeating: "b", count: 40)
        var request = base
        request["previous"] = ["commit": oldCommit, "script_sha256": oldHash]
        let index = try Self.decode([
            "broker_id": Self.brokerID, "updated_at": "2026-09-25T22:01:00Z",
            "pending": [request],
        ], as: ArgusAdminApprovalIndex.self).validated()
        let selected = try #require(index.pending.first)
        let prior: [String: Any] = [
            "commit": oldCommit, "script_sha256": oldHash,
            "script_b64": old.base64EncodedString(),
        ]
        let exact = try Self.decode([
            "broker_id": Self.brokerID, "request": request,
            "script_b64": script.base64EncodedString(), "previous": prior,
            "diff_b64": Data("relay-controlled text is not the displayed change".utf8).base64EncodedString(),
        ], as: ArgusAdminApprovalDetail.self)
        let reviewed = try exact.reviewed(against: index, selected: selected)
        #expect(reviewed.changes?.contains("− old line 1: Write-Output 'old'␍") == true)
        #expect(reviewed.changes?.contains("+ new line 1: Write-Output 'ok'␍") == true)
        #expect(reviewed.changes?.contains("relay-controlled") == false)

        let missing = try Self.decode([
            "broker_id": Self.brokerID, "request": request,
            "script_b64": script.base64EncodedString(),
        ], as: ArgusAdminApprovalDetail.self)
        #expect(throws: ArgusAdminApprovalReadError.self) {
            try missing.reviewed(against: index, selected: selected)
        }
        var wrong = prior
        wrong["script_b64"] = Data("Write-Output 'different'\r\n".utf8).base64EncodedString()
        let altered = try Self.decode([
            "broker_id": Self.brokerID, "request": request,
            "script_b64": script.base64EncodedString(), "previous": wrong,
        ], as: ArgusAdminApprovalDetail.self)
        #expect(throws: ArgusAdminApprovalCanonical.FormatError.self) {
            try altered.reviewed(against: index, selected: selected)
        }
    }
}
