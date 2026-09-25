import Foundation
import Testing
@testable import OpenClaw

struct ArgusAdminApprovalCanonicalTests {
    @Test func brokerVectorsMatchByteForByte() throws {
        let args = try ArgusAdminApprovalCanonical.arguments([
            "SkipAsSource": .boolean(false),
            "Interface": .string("Ethernet"),
        ])
        #expect(String(data: args, encoding: .utf8) == #"{"Interface":"Ethernet","SkipAsSource":false}"#)
        #expect(ArgusAdminApprovalCanonical.sha256(args)
            == "1f320185d26e4606034da6947f9f1a81927fc3e56db961a45179f59255c79292")

        let script = Data("ok\n".utf8)
        let scriptHash = ArgusAdminApprovalCanonical.sha256(script)
        #expect(scriptHash == "cddd1879475bcede88339fe1c3775d12e77ef9485231bebe48cd0076404bb5f3")

        let statement = try ArgusAdminApprovalCanonical.statement(.init(
            requestID: "11111111-2222-4333-8444-555555555555",
            decision: "approve",
            scriptPath: "scripts/windows/elevated/pc3-nic-config.ps1",
            gitCommit: String(repeating: "a", count: 40),
            scriptSHA256: scriptHash,
            argsSHA256: ArgusAdminApprovalCanonical.sha256(args),
            nonce: String(repeating: "0", count: 32),
            expiresAt: "2026-09-26T22:00:00Z",
            brokerID: "0123456789abcdef"))
        #expect(statement.last == 10)
        #expect(ArgusAdminApprovalCanonical.sha256(statement)
            == "b0012171958597ac076af9a5facd5a5da66ad63bf139ea16c00a8ddbb8b8768e")
    }

    @Test func invalidOrAmbiguousInputsRefuseToFormat() throws {
        #expect(throws: ArgusAdminApprovalCanonical.FormatError.self) {
            try ArgusAdminApprovalCanonical.arguments(["Interface": .string("Ethernet\n-Force")])
        }
        #expect(throws: ArgusAdminApprovalCanonical.FormatError.self) {
            try ArgusAdminApprovalCanonical.arguments(["bad/key": .boolean(true)])
        }
        let escaped = try ArgusAdminApprovalCanonical.arguments(["Interface": .string(#"A"B\C"#)])
        #expect(String(data: escaped, encoding: .utf8) == #"{"Interface":"A\"B\\C"}"#)

        let valid = ArgusAdminApprovalCanonical.Statement(
            requestID: "11111111-2222-4333-8444-555555555555",
            decision: "approve",
            scriptPath: "scripts/windows/elevated/pc3-nic-config.ps1",
            gitCommit: String(repeating: "a", count: 40),
            scriptSHA256: String(repeating: "b", count: 64),
            argsSHA256: String(repeating: "c", count: 64),
            nonce: String(repeating: "0", count: 32),
            expiresAt: "2026-09-26T22:00:00Z",
            brokerID: "0123456789abcdef")
        #expect(throws: ArgusAdminApprovalCanonical.FormatError.self) {
            try ArgusAdminApprovalCanonical.statement(.init(
                requestID: valid.requestID, decision: valid.decision,
                scriptPath: "scripts/windows/elevated/pc3-nic-config.ps1\napprove",
                gitCommit: valid.gitCommit, scriptSHA256: valid.scriptSHA256,
                argsSHA256: valid.argsSHA256, nonce: valid.nonce,
                expiresAt: valid.expiresAt, brokerID: valid.brokerID))
        }
    }

    @Test func onlyExactDisplayablePendingBytesCanBeReviewed() throws {
        let script = Data("Write-Output 'ok'\r\n".utf8)
        let digest = ArgusAdminApprovalCanonical.sha256(script)
        #expect(try ArgusAdminApprovalCanonical.reviewedScript(script, expectedSHA256: digest)
            == "Write-Output 'ok'\r\n")
        #expect(throws: ArgusAdminApprovalCanonical.FormatError.self) {
            try ArgusAdminApprovalCanonical.reviewedScript(
                Data("Write-Output 'changed'\r\n".utf8), expectedSHA256: digest)
        }
        #expect(throws: ArgusAdminApprovalCanonical.FormatError.self) {
            try ArgusAdminApprovalCanonical.reviewedScript(
                Data([87, 114, 105, 116, 101, 0, 10]),
                expectedSHA256: ArgusAdminApprovalCanonical.sha256(Data([87, 114, 105, 116, 101, 0, 10])))
        }

        let values: [String: ArgusAdminApprovalCanonical.Value] = ["Interface": .string("Ethernet")]
        let args = try ArgusAdminApprovalCanonical.arguments(values)
        #expect(try ArgusAdminApprovalCanonical.reviewedArguments(
            values, expectedSHA256: ArgusAdminApprovalCanonical.sha256(args)) == args)
        #expect(throws: ArgusAdminApprovalCanonical.FormatError.self) {
            try ArgusAdminApprovalCanonical.reviewedArguments(
                ["Interface": .string("Wi-Fi")],
                expectedSHA256: ArgusAdminApprovalCanonical.sha256(args))
        }
    }
}
