import Foundation
import Combine
import SessionNotchCore

@MainActor
public final class RegistryStore: ObservableObject {
    @Published public private(set) var sessions: [Session] = []
    private let registry: SessionRegistry
    public var onNewAttention: ((Session) -> Void)?

    public init(staleAfter: TimeInterval = 900) {
        registry = SessionRegistry(staleAfter: staleAfter)
        registry.onChange = { [weak self] in self?.refresh() }
        registry.onNewAttention = { [weak self] s in self?.onNewAttention?(s) }
        Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.registry.expireStale(now: Date()); self?.refresh()
        }
    }

    public func apply(_ event: Event) { registry.apply(event) }
    private func refresh() { sessions = registry.needingAttention }
}
