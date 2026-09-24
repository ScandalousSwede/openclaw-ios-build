import Foundation

struct ChatForegroundLeaseReply: Decodable, Sendable {
    let state: String
    let leaseId: String?
    let expiresAtMs: Int?
    let ttlMs: Int?
}

struct ChatForegroundLeaseState {
    private(set) var leaseID: String?

    var activeParameters: [String: String] {
        var params = ["state": "active"]
        if let leaseID = self.leaseID { params["leaseId"] = leaseID }
        return params
    }

    mutating func accept(_ reply: ChatForegroundLeaseReply) throws {
        guard reply.state == "active", let leaseID = reply.leaseId, !leaseID.isEmpty,
              let expiresAtMs = reply.expiresAtMs, expiresAtMs > 0,
              let ttlMs = reply.ttlMs, ttlMs >= 5_000 else {
            throw ArgusOperationsError.invalidResponse
        }
        self.leaseID = leaseID
    }

    mutating func releaseParameters() -> [String: String]? {
        guard let leaseID = self.leaseID else { return nil }
        self.leaseID = nil
        return ["state": "inactive", "leaseId": leaseID]
    }
}

@MainActor
enum ChatForegroundLease {
    static func maintain(client: ArgusOperationsClient) async {
        guard let route = await client.session.currentRoute(ifGatewayID: client.gatewayID) else { return }
        let pinnedClient = ArgusOperationsClient(
            session: client.session, gatewayID: client.gatewayID, pinnedRoute: route)
        var state = ChatForegroundLeaseState()
        while !Task.isCancelled {
            guard await client.session.isCurrentRoute(route) else { break }
            do {
                let reply = try await pinnedClient.request(
                    "chat.foreground.set", params: state.activeParameters, as: ChatForegroundLeaseReply.self)
                try state.accept(reply)
            } catch {
                // An older server or a shared-token/password operator connection cannot
                // suppress a foreground alert. Do not claim a lease or retry noisily.
                GatewayDiagnostics.log("chat foreground lease unavailable on current operator route")
                break
            }
            do { try await Task.sleep(for: .seconds(5)) }
            catch { break }
        }
        if let params = state.releaseParameters() {
            // Scene suspension may cancel the parent task. Release is best effort; the
            // server also clears this connection-bound lease on disconnect or 15s expiry.
            Task {
                _ = try? await pinnedClient.request(
                    "chat.foreground.set", params: params, as: ChatForegroundLeaseReply.self)
            }
        }
    }
}
