import Foundation
@testable import SessionNotchCore

func registerEventTests(_ runner: TestRunner) async {
    runner.test("Event.decodeWireJSON") {
        let json = #"{"machine":"studio","session_id":"abc123","project":"event-results","cwd":"/Users/w/Agent/USMS/Event Results","event":"waiting_permission","message":"needs permission to run: npm test","ts":"2026-07-18T17:05:22Z"}"#.data(using: .utf8)!
        let e = try Event.decoder.decode(Event.self, from: json)
        try expectEqual(e.machine, "studio")
        try expectEqual(e.sessionID, "abc123")
        try expectEqual(e.kind, .waitingPermission)
        try expectEqual(e.message, "needs permission to run: npm test")
    }
    runner.test("Event.roundTrip") {
        let e = Event(machine: "laptop", sessionID: "s1", project: "p", cwd: "/tmp",
                      kind: .done, message: nil, ts: Date(timeIntervalSince1970: 1_700_000_000))
        let data = try Event.encoder.encode(e)
        let back = try Event.decoder.decode(Event.self, from: data)
        try expectEqual(e, back)
    }
}
