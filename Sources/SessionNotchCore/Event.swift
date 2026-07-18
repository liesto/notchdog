import Foundation

public enum EventKind: String, Codable, Sendable {
    case waitingPermission = "waiting_permission"
    case idle
    case done
    case working
    case error
    case sessionEnd = "session_end"
}

public struct Event: Codable, Equatable, Sendable {
    public let machine: String
    public let sessionID: String
    public let project: String
    public let cwd: String
    public let kind: EventKind
    public let message: String?
    public let ts: Date

    enum CodingKeys: String, CodingKey {
        case machine, project, cwd, message, ts
        case sessionID = "session_id"
        case kind = "event"
    }

    public init(machine: String, sessionID: String, project: String,
                cwd: String, kind: EventKind, message: String?, ts: Date) {
        self.machine = machine; self.sessionID = sessionID; self.project = project
        self.cwd = cwd; self.kind = kind; self.message = message; self.ts = ts
    }

    public static let decoder: JSONDecoder = {
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d
    }()
    public static let encoder: JSONEncoder = {
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e
    }()
}
