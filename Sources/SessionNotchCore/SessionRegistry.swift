import Foundation

public final class SessionRegistry {
    private(set) public var sessions: [String: Session] = [:]
    public let staleAfter: TimeInterval
    public var onChange: (() -> Void)?
    public var onNewAttention: ((Session) -> Void)?

    public init(staleAfter: TimeInterval = 900) { self.staleAfter = staleAfter }

    private static func state(for kind: EventKind) -> SessionState? {
        switch kind {
        case .waitingPermission: return .waitingPermission
        case .idle: return .idleInput
        case .done: return .done
        case .working: return .working
        case .error: return .error
        case .sessionEnd: return nil
        }
    }

    @discardableResult
    public func apply(_ event: Event) -> Session? {
        let key = "\(event.machine)#\(event.sessionID)"

        if event.kind == .sessionEnd {
            if sessions.removeValue(forKey: key) != nil { onChange?() }
            return nil
        }
        guard let newState = Self.state(for: event.kind) else { return nil }

        let wasAttention = sessions[key]?.needsAttention ?? false
        var s = sessions[key] ?? Session(machine: event.machine, sessionID: event.sessionID,
                                         project: event.project, cwd: event.cwd,
                                         state: newState, message: event.message,
                                         lastEvent: event.ts)
        s.project = event.project
        s.cwd = event.cwd
        s.state = newState
        s.message = event.message
        s.lastEvent = event.ts
        sessions[key] = s

        if s.needsAttention && !wasAttention { onNewAttention?(s) }
        onChange?()
        return s
    }

    /// Manually clear every tracked session (e.g. the notch "x" button).
    public func clearAll() {
        guard !sessions.isEmpty else { return }
        sessions.removeAll()
        onChange?()
    }

    public func expireStale(now: Date) {
        let cutoff = now.addingTimeInterval(-staleAfter)
        let before = sessions.count
        sessions = sessions.filter { $0.value.lastEvent >= cutoff }
        if sessions.count != before { onChange?() }
    }

    public var needingAttention: [Session] {
        sessions.values.filter { $0.needsAttention }.sorted { $0.lastEvent > $1.lastEvent }
    }
}
