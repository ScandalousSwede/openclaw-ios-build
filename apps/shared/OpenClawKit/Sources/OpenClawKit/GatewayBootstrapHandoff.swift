import Foundation

public enum GatewayBootstrapHandoffRole: String, Codable, Sendable, Equatable, Hashable, CaseIterable {
    case node
    case operatorRole = "operator"
}

public enum GatewayBootstrapHandoffIssue: String, Codable, Sendable, Equatable, Hashable {
    case missingNodeRole = "missing-node-role"
    case missingOperatorRole = "missing-operator-role"
    case missingNodeToken = "missing-node-token"
    case missingOperatorToken = "missing-operator-token"
    case missingOperatorRead = "missing-operator-read"
    case missingOperatorWrite = "missing-operator-write"
    case missingOperatorTalkSecrets = "missing-operator-talk-secrets"
    case unexpectedNodeScopes = "unexpected-node-scopes"
    case unexpectedOperatorScopes = "unexpected-operator-scopes"
    case malformedResponse = "malformed-response"
    case untrustedEndpoint = "untrusted-endpoint"
}

public enum GatewayBootstrapHandoffPersistence: String, Codable, Sendable, Equatable {
    case notAttempted = "not-attempted"
    case succeeded
    case failed
}

public struct GatewayBootstrapHandoffRoleGrant: Codable, Sendable, Equatable {
    public let role: GatewayBootstrapHandoffRole
    public let scopes: [String]

    public init(role: GatewayBootstrapHandoffRole, scopes: [String]) {
        self.role = role
        self.scopes = scopes
    }
}

/// Token-free proof of the roles freshly issued by one setup-code connection.
/// Generation fields bind the proof to the exact admitted physical route; callers
/// must still retrieve it through `GatewayNodeSession.bootstrapHandoffReceipt`.
public struct GatewayBootstrapHandoffReceipt: Codable, Sendable, Equatable {
    public let channelGeneration: UInt64
    public let routeGeneration: UInt64
    public let physicalConnectionGeneration: UInt64
    public let issuedRoles: [GatewayBootstrapHandoffRoleGrant]
    public let issues: [GatewayBootstrapHandoffIssue]
    public let persistence: GatewayBootstrapHandoffPersistence

    init(
        channelGeneration: UInt64,
        routeGeneration: UInt64,
        physicalConnectionGeneration: UInt64,
        issuedRoles: [GatewayBootstrapHandoffRoleGrant],
        issues: [GatewayBootstrapHandoffIssue],
        persistence: GatewayBootstrapHandoffPersistence)
    {
        self.channelGeneration = channelGeneration
        self.routeGeneration = routeGeneration
        self.physicalConnectionGeneration = physicalConnectionGeneration
        self.issuedRoles = issuedRoles
        self.issues = issues
        self.persistence = persistence
    }

    public var validationSucceeded: Bool {
        self.issues.isEmpty
    }

    public var isReady: Bool {
        self.validationSucceeded && self.persistence == .succeeded
    }
}

/// An atomic view of bootstrap evidence for one exact admitted route.
/// `missing` is meaningful only while the requested route is still current;
/// a retired route must never be converted into a failed setup receipt.
public enum GatewayBootstrapHandoffRouteState: Sendable, Equatable {
    case retired
    case missing
    case receipt(GatewayBootstrapHandoffReceipt)
}

struct GatewayBootstrapHandoffCredential: Sendable {
    let role: GatewayBootstrapHandoffRole
    let token: String?
    let scopes: [String]
}

struct GatewayBootstrapHandoffConnectionReceipt: Sendable, Equatable {
    let physicalConnectionGeneration: UInt64
    let issuedRoles: [GatewayBootstrapHandoffRoleGrant]
    let issues: [GatewayBootstrapHandoffIssue]
    let persistence: GatewayBootstrapHandoffPersistence
}

struct GatewayBootstrapHandoffPlan: Sendable {
    let issuedRoles: [GatewayBootstrapHandoffRoleGrant]
    let issues: [GatewayBootstrapHandoffIssue]
    let writes: [DeviceAuthTokenWrite]
}

enum GatewayBootstrapHandoffValidator {
    static let requiredOperatorScopes = [
        "operator.read",
        "operator.write",
        "operator.talk.secrets",
    ]

    private static let allowedOperatorScopes: Set<String> = [
        "operator.approvals",
        "operator.read",
        "operator.talk.secrets",
        "operator.write",
    ]

    static func malformedPlan() -> GatewayBootstrapHandoffPlan {
        GatewayBootstrapHandoffPlan(
            issuedRoles: [],
            issues: [.malformedResponse],
            writes: [])
    }

    static func validate(_ credentials: [GatewayBootstrapHandoffCredential]) -> GatewayBootstrapHandoffPlan {
        var byRole: [GatewayBootstrapHandoffRole: GatewayBootstrapHandoffCredential] = [:]
        for credential in credentials {
            guard byRole[credential.role] == nil else { return self.malformedPlan() }
            byRole[credential.role] = credential
        }

        var issues: [GatewayBootstrapHandoffIssue] = []
        if byRole[.node] == nil {
            issues.append(.missingNodeRole)
        }
        if byRole[.operatorRole] == nil {
            issues.append(.missingOperatorRole)
        }

        if let node = byRole[.node] {
            if node.token == nil {
                issues.append(.missingNodeToken)
            }
            if !self.normalizedScopes(node.scopes).isEmpty {
                issues.append(.unexpectedNodeScopes)
            }
        }
        if let operatorCredential = byRole[.operatorRole] {
            if operatorCredential.token == nil {
                issues.append(.missingOperatorToken)
            }
            let granted = Set(self.normalizedScopes(operatorCredential.scopes))
            for requiredScope in self.requiredOperatorScopes where !granted.contains(requiredScope) {
                let issue: GatewayBootstrapHandoffIssue = switch requiredScope {
                case "operator.read": .missingOperatorRead
                case "operator.write": .missingOperatorWrite
                default: .missingOperatorTalkSecrets
                }
                issues.append(issue)
            }
            if !granted.isSubset(of: self.allowedOperatorScopes) {
                issues.append(.unexpectedOperatorScopes)
            }
        }

        let issuedRoles = GatewayBootstrapHandoffRole.allCases.compactMap { role -> GatewayBootstrapHandoffRoleGrant? in
            guard let credential = byRole[role], credential.token != nil else { return nil }
            let scopes: [String] = switch role {
            case .node:
                []
            case .operatorRole:
                self.normalizedScopes(credential.scopes)
                    .filter { self.allowedOperatorScopes.contains($0) }
            }
            return GatewayBootstrapHandoffRoleGrant(role: role, scopes: scopes)
        }

        guard issues.isEmpty,
              let node = byRole[.node],
              let nodeToken = node.token,
              let operatorCredential = byRole[.operatorRole],
              let operatorToken = operatorCredential.token
        else {
            return GatewayBootstrapHandoffPlan(
                issuedRoles: issuedRoles,
                issues: issues,
                writes: [])
        }

        let operatorScopes = self.normalizedScopes(operatorCredential.scopes)
            .filter { self.allowedOperatorScopes.contains($0) }
        return GatewayBootstrapHandoffPlan(
            issuedRoles: issuedRoles,
            issues: [],
            writes: [
                DeviceAuthTokenWrite(role: GatewayBootstrapHandoffRole.node.rawValue, token: nodeToken, scopes: []),
                DeviceAuthTokenWrite(
                    role: GatewayBootstrapHandoffRole.operatorRole.rawValue,
                    token: operatorToken,
                    scopes: operatorScopes),
            ])
    }

    private static func normalizedScopes(_ scopes: [String]) -> [String] {
        let values = scopes
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return Array(Set(values)).sorted()
    }
}
