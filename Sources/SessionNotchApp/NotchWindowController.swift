import AppKit
import SwiftUI
import Combine
import SessionNotchCore

// A borderless panel that hangs from the top-center of the screen (the notch),
// dropping down to show sessions that need attention — Dynamic Island style.
// Plain AppKit so it builds anywhere Swift builds (no notch-UI dependency).
@MainActor
final class NotchWindowController {
    private let panel: NSPanel
    private let hosting: NSHostingView<NotchContentView>
    private var cancellables = Set<AnyCancellable>()

    init(store: RegistryStore) {
        hosting = NSHostingView(rootView: NotchContentView(store: store))
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 44),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.contentView = hosting

        store.$sessions
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.reflow() }
            .store(in: &cancellables)
    }

    func show() {
        reflow()
        panel.orderFrontRegardless()
    }

    // Size the panel to its SwiftUI content and pin it to the top-center (under the notch).
    private func reflow() {
        hosting.layoutSubtreeIfNeeded()
        let fit = hosting.fittingSize
        let w = max(fit.width, 240)
        let h = max(fit.height, 36)
        guard let screen = NSScreen.main else { return }
        let x = screen.frame.midX - w / 2
        let y = screen.frame.maxY - h          // top edge at the very top -> hangs from the notch
        panel.setFrame(NSRect(x: x, y: y, width: w, height: h), display: true)
        panel.orderFrontRegardless()
    }
}

struct NotchContentView: View {
    @ObservedObject var store: RegistryStore

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if store.sessions.isEmpty {
                HStack(spacing: 8) {
                    Circle().fill(Color.green).frame(width: 7, height: 7)
                    Text("notchdog — all clear")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.85))
                }
            } else {
                ForEach(store.sessions) { s in
                    HStack(spacing: 9) {
                        Circle().fill(color(for: s.state)).frame(width: 8, height: 8)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("\(s.machine) · \(s.project)")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.white)
                            Text(s.message ?? label(for: s.state))
                                .font(.system(size: 11))
                                .foregroundStyle(.white.opacity(0.6))
                                .lineLimit(1)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(minWidth: 240, alignment: .leading)
        .background(Color.black.opacity(0.92))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
    }

    private func color(for s: SessionState) -> Color {
        switch s {
        case .waitingPermission, .error: return .red
        case .idleInput: return .yellow
        case .done: return .blue
        case .working: return .gray
        }
    }
    private func label(for s: SessionState) -> String {
        switch s {
        case .waitingPermission: return "waiting for permission"
        case .idleInput: return "waiting for input"
        case .done: return "finished"
        case .error: return "errored"
        case .working: return "working"
        }
    }
}
