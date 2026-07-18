import Foundation
import Security

public struct Config: Codable, Equatable, Sendable {
    public var machine: String
    public var endpoint: String
    public var port: Int

    public init(machine: String, endpoint: String, port: Int) {
        self.machine = machine
        self.endpoint = endpoint
        self.port = port
    }

    public static func load(from url: URL) throws -> Config {
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(Config.self, from: data)
    }
}

public enum SecretError: Error { case randomGenerationFailed }

public enum Secret {
    public static func loadOrCreate(at url: URL) throws -> String {
        if let data = try? Data(contentsOf: url),
           let s = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !s.isEmpty {
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            return s
        }
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else { throw SecretError.randomGenerationFailed }
        let hex = bytes.map { String(format: "%02x", $0) }.joined()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try hex.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return hex
    }
}

public enum TailscaleIP {
    public static func isCGNAT(_ ipv4: String) -> Bool {
        let parts = ipv4.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4, parts[0] == 100 else { return false }
        return (64...127).contains(parts[1]) // 100.64.0.0/10
    }

    public static func detect() -> String? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(bitPattern: ptr.pointee.ifa_flags)
            guard (flags & IFF_UP) == IFF_UP, let sa = ptr.pointee.ifa_addr,
                  sa.pointee.sa_family == UInt8(AF_INET) else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count),
                        nil, 0, NI_NUMERICHOST)
            let ip = String(cString: host)
            if isCGNAT(ip) { return ip }
        }
        return nil
    }
}
