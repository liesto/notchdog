import Foundation
@testable import SessionNotchCore

private func tempURL() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("sn-\(UUID().uuidString)")
}

func registerConfigTests(_ runner: TestRunner) async {
    runner.test("Config.loadConfig") {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try #"{"machine":"laptop","endpoint":"http://127.0.0.1:47823/event","port":47823}"#
            .write(to: url, atomically: true, encoding: .utf8)
        let c = try Config.load(from: url)
        try expectEqual(c.machine, "laptop")
        try expectEqual(c.port, 47823)
    }

    runner.test("Secret.createdWith0600") {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let s1 = try Secret.loadOrCreate(at: url)
        try expectEqual(s1.count, 64)
        let perms = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        try expectEqual(perms?.int16Value, Int16(0o600))
        let s2 = try Secret.loadOrCreate(at: url) // stable on reload
        try expectEqual(s1, s2)
    }

    runner.test("TailscaleIP.isCGNAT") {
        try expect(TailscaleIP.isCGNAT("100.90.12.34"))
        try expect(TailscaleIP.isCGNAT("100.127.0.1"))
        try expect(!TailscaleIP.isCGNAT("192.168.1.10"))
        try expect(!TailscaleIP.isCGNAT("100.128.0.1")) // above /10
        try expect(!TailscaleIP.isCGNAT("10.0.0.1"))
    }
}
