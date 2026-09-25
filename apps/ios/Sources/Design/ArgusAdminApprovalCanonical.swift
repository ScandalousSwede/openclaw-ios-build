import CryptoKit
import Foundation

// Pure, offline formatting for the broker's ARGUS-APPROVAL-V1 statement.
// No call site should sign until the broker has proved trusted script provenance.
enum ArgusAdminApprovalCanonical {
    enum Value: Equatable {
        case string(String)
        case integer(Int64)
        case boolean(Bool)
    }

    enum FormatError: Error {
        case invalidArgument
        case invalidStatement
        case unrenderableScript
        case hashMismatch
    }

    struct Statement {
        let requestID: String
        let decision: String
        let scriptPath: String
        let gitCommit: String
        let scriptSHA256: String
        let argsSHA256: String
        let nonce: String
        let expiresAt: String
        let brokerID: String
    }

    static func arguments(_ values: [String: Value]) throws -> Data {
        guard values.count <= 16 else { throw FormatError.invalidArgument }
        var parts: [String] = []
        for key in values.keys.sorted() {
            guard matches(key, "^[A-Za-z][A-Za-z0-9]{0,31}$"),
                  let value = values[key] else { throw FormatError.invalidArgument }
            let encoded: String
            switch value {
            case .string(let text):
                guard text.utf8.count <= 256,
                      text.utf8.allSatisfy({ (32...126).contains($0) }) else {
                    throw FormatError.invalidArgument
                }
                encoded = "\"" + escape(text) + "\""
            case .integer(let number):
                encoded = String(number)
            case .boolean(let flag):
                encoded = flag ? "true" : "false"
            }
            parts.append("\"\(key)\":\(encoded)")
        }
        return Data(("{\(parts.joined(separator: ","))}").utf8)
    }

    static func sha256(_ bytes: Data) -> String {
        SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    // A relay-supplied digest cannot make a different script or argument set reviewable.
    // Keep the exact bytes for hashing; never hash a normalized display string.
    static func reviewedScript(_ bytes: Data, expectedSHA256: String) throws -> String {
        guard !bytes.isEmpty, bytes.count <= 262_144,
              bytes.allSatisfy({ (32...126).contains($0) || $0 == 9 || $0 == 10 || $0 == 13 }),
              let text = String(data: bytes, encoding: .utf8) else {
            throw FormatError.unrenderableScript
        }
        guard matches(expectedSHA256, "^[0-9a-f]{64}$"),
              sha256(bytes) == expectedSHA256 else { throw FormatError.hashMismatch }
        return text
    }

    static func reviewedArguments(_ values: [String: Value], expectedSHA256: String) throws -> Data {
        let canonical = try arguments(values)
        guard matches(expectedSHA256, "^[0-9a-f]{64}$"),
              sha256(canonical) == expectedSHA256 else { throw FormatError.hashMismatch }
        return canonical
    }

    static func statement(_ input: Statement) throws -> Data {
        guard matches(input.requestID, "^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$"),
              matches(input.decision, "^(approve|deny)$"),
              matches(input.scriptPath, "^scripts/windows/elevated/[A-Za-z0-9][A-Za-z0-9._-]*[.]ps1$"),
              matches(input.gitCommit, "^[0-9a-f]{40}$"),
              matches(input.scriptSHA256, "^[0-9a-f]{64}$"),
              matches(input.argsSHA256, "^[0-9a-f]{64}$"),
              matches(input.nonce, "^[0-9a-f]{32}$"),
              matches(input.expiresAt, "^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$"),
              matches(input.brokerID, "^[0-9a-f]{16}$") else {
            throw FormatError.invalidStatement
        }
        let lines = [
            "ARGUS-APPROVAL-V1",
            "request_id:\(input.requestID)",
            "decision:\(input.decision)",
            "script_path:\(input.scriptPath)",
            "git_commit:\(input.gitCommit)",
            "script_sha256:\(input.scriptSHA256)",
            "args_sha256:\(input.argsSHA256)",
            "nonce:\(input.nonce)",
            "expires_at:\(input.expiresAt)",
            "broker_id:\(input.brokerID)",
        ]
        return Data((lines.joined(separator: "\n") + "\n").utf8)
    }

    private static func matches(_ text: String, _ pattern: String) -> Bool {
        text.range(of: pattern, options: .regularExpression) == (text.startIndex..<text.endIndex)
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
