import AppKit
import SwiftUI
import Combine

@MainActor
final class StatusItemController {
    private let item: NSStatusItem
    private let popover = NSPopover()
    private let store: RegistryStore

    init(store: RegistryStore) {
        self.store = store
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: SessionListView(store: store))
        item.button?.title = "SN"
        item.button?.target = self
        item.button?.action = #selector(toggle)
        store.objectWillChange.sink { [weak self] in
            DispatchQueue.main.async { self?.updateTitle() }
        }.store(in: &cancellables)
    }

    private var cancellables = Set<AnyCancellable>()

    private func updateTitle() {
        let n = store.sessions.count
        item.button?.title = n == 0 ? "SN" : "SN \(n)"
    }

    @objc private func toggle() {
        guard let button = item.button else { return }
        if popover.isShown { popover.performClose(nil) }
        else { popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY) }
    }
}
