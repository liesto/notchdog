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
    /// Only states that actually need the user show on the notch. `.working` is busy and
    /// `.done` is resolved/finished — neither needs you, so both drop off the notch.
    public var needsAttention: Bool {
        switch state {
        case .waitingPermission, .idleInput, .error: return true
        case .working, .done: return false
        }
    }
}
