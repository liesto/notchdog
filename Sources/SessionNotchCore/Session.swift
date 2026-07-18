import Foundation

public enum SessionState: String, Sendable {
    case working, waitingPermission, idleInput, done, error
}

public struct Session: Identifiable, Equatable, Sendable {
    public let machine: String
    public let sessionID: String
    public var project: String
    public var cwd: String
    public var state: SessionState
    public var message: String?
    public var lastEvent: Date

    public var id: String { "\(machine)#\(sessionID)" }
    public var needsAttention: Bool { state != .working }
}
