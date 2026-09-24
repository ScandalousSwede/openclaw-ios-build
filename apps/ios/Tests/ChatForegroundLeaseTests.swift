import Foundation
import Testing
@testable import OpenClaw

@Suite
struct ChatForegroundLeaseTests {
    @Test func `active refresh and inactive release carry only the server lease ID`() throws {
        var state = ChatForegroundLeaseState()
        #expect(state.activeParameters == ["state": "active"])
        let reply = try JSONDecoder().decode(ChatForegroundLeaseReply.self, from: Data(
            #"{"state":"active","leaseId":"lease-1","expiresAtMs":20000,"ttlMs":15000}"#.utf8))
        try state.accept(reply)
        #expect(state.activeParameters == ["state": "active", "leaseId": "lease-1"])
        #expect(state.releaseParameters() == ["state": "inactive", "leaseId": "lease-1"])
        #expect(state.releaseParameters() == nil)
        #expect(state.activeParameters == ["state": "active"])
    }

    @Test func `invalid acknowledgment cannot mark foreground active`() {
        let invalid: [ChatForegroundLeaseReply] = [
            .init(state: "inactive", leaseId: "lease-1", expiresAtMs: 20_000, ttlMs: 15_000),
            .init(state: "active", leaseId: nil, expiresAtMs: 20_000, ttlMs: 15_000),
            .init(state: "active", leaseId: "lease-1", expiresAtMs: 0, ttlMs: 15_000),
            .init(state: "active", leaseId: "lease-1", expiresAtMs: 20_000, ttlMs: nil),
            .init(state: "active", leaseId: "lease-1", expiresAtMs: 20_000, ttlMs: 4_999),
        ]
        for reply in invalid {
            var state = ChatForegroundLeaseState()
            do {
                try state.accept(reply)
                Issue.record("accepted an invalid foreground lease")
            } catch {}
            #expect(state.releaseParameters() == nil)
        }
    }
}
