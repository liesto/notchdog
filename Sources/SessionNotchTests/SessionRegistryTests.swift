import Foundation
@testable import SessionNotchCore

func registerSessionRegistryTests(_ runner: TestRunner) async {
    func ev(_ kind: EventKind, machine: String = "studio",
            session: String = "s1", at t: TimeInterval = 0) -> Event {
        Event(machine: machine, sessionID: session, project: "proj",
              cwd: "/tmp/proj", kind: kind, message: nil,
              ts: Date(timeIntervalSince1970: t))
    }

    runner.test("SessionRegistry.permissionEventNeedsAttention") {
        let r = SessionRegistry()
        r.apply(ev(.waitingPermission))
        try expectEqual(r.needingAttention.count, 1)
        try expectEqual(r.needingAttention.first?.state, .waitingPermission)
    }

    runner.test("SessionRegistry.workingClearsAttention") {
        let r = SessionRegistry()
        r.apply(ev(.waitingPermission, at: 0))
        r.apply(ev(.working, at: 1))
        try expect(r.needingAttention.isEmpty)
    }

    runner.test("SessionRegistry.doneClearsAttention") {
        // A resolved session (Stop hook -> done) must drop off the notch immediately,
        // not linger as a blue alert until stale/sessionEnd.
        let r = SessionRegistry()
        r.apply(ev(.waitingPermission, at: 0))
        try expectEqual(r.needingAttention.count, 1)
        r.apply(ev(.done, at: 1))
        try expect(r.needingAttention.isEmpty)
    }

    runner.test("SessionRegistry.sessionEndRemovesSession") {
        let r = SessionRegistry()
        r.apply(ev(.done, at: 0))
        r.apply(ev(.sessionEnd, at: 1))
        try expect(r.needingAttention.isEmpty)
    }

    runner.test("SessionRegistry.newAttentionFiresOncePerEntry") {
        let r = SessionRegistry()
        var fired = 0
        r.onNewAttention = { _ in fired += 1 }
        r.apply(ev(.waitingPermission, at: 0)) // enter attention -> fire
        r.apply(ev(.done, at: 1))              // still attention -> no fire
        r.apply(ev(.working, at: 2))           // clear
        r.apply(ev(.idle, at: 3))               // re-enter -> fire
        try expectEqual(fired, 2)
    }

    runner.test("SessionRegistry.expireStaleDropsOldSessions") {
        let r = SessionRegistry(staleAfter: 60)
        r.apply(ev(.done, at: 0))
        r.expireStale(now: Date(timeIntervalSince1970: 120))
        try expect(r.needingAttention.isEmpty)
    }

    runner.test("SessionRegistry.keyedByMachineAndSession") {
        let r = SessionRegistry()
        r.apply(ev(.idle, machine: "studio", session: "s1", at: 0))
        r.apply(ev(.idle, machine: "laptop", session: "s1", at: 0))
        try expectEqual(r.needingAttention.count, 2)
    }

    runner.test("SessionRegistry.newestFirstOrdering") {
        let r = SessionRegistry()
        r.apply(ev(.idle, session: "old", at: 10))
        r.apply(ev(.idle, session: "new", at: 20))
        try expectEqual(r.needingAttention.first?.sessionID, "new")
    }
}
