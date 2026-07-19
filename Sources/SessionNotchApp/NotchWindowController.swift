import AppKit
import SwiftUI
import Combine
import SessionNotchCore

// A borderless panel aligned to the notch: its black top blends into the physical
// notch, and content renders BELOW the notch line (in visible screen space), so it
// reads as content dropping out of the notch — Dynamic Island style. Plain AppKit.
@MainActor
final class NotchWindowController {
    private let panel: NSPanel
    private let hosting: NSHostingView<NotchContentView>
    private let store: RegistryStore
    private var cancellables = Set<AnyCancellable>()

    init(store: RegistryStore) {
        self.store = store
        hosting = NSHostingView(rootView: NotchContentView(store: store, topInset: 37, notchWidth: 156))
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 156, height: 60),
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

    // Measured notch geometry (points), with a 74x312px (=37x156pt) fallback.
    private func notchMetrics(_ screen: NSScreen) -> (height: CGFloat, width: CGFloat) {
        let h = screen.safeAreaInsets.top > 0 ? screen.safeAreaInsets.top : 37
        let auxL = screen.auxiliaryTopLeftArea?.width ?? 0
        let auxR = screen.auxiliaryTopRightArea?.width ?? 0
        let w = (auxL > 0 && auxR > 0) ? (screen.frame.width - auxL - auxR) : 156
        return (h, w)
    }

    private func reflow() {
        guard let screen = NSScreen.main else { return }
        let (notchH, notchW) = notchMetrics(screen)
        hosting.rootView = NotchContentView(store: store, topInset: notchH, notchWidth: notchW)
        hosting.layoutSubtreeIfNeeded()
        // Idle: collapse to exactly the notch (never taller than the notch height).
        // Alert: size to content, dropping below the notch.
        let empty = store.sessions.isEmpty
        let fit = hosting.fittingSize
        let w = empty ? notchW : max(fit.width, notchW)
        let h = empty ? notchH : fit.height
        let x = screen.frame.midX - w / 2
        let y = screen.frame.maxY - h   // top edge at the very top -> extends the notch downward
        panel.setFrame(NSRect(x: x, y: y, width: w, height: h), display: true)
        panel.orderFrontRegardless()
    }
}

struct NotchContentView: View {
    @ObservedObject var store: RegistryStore
    var topInset: CGFloat = 37       // physical notch height; content sits below this
    var notchWidth: CGFloat = 156

    var body: some View {
        Group {
            if store.sessions.isEmpty {
                // Idle: just the notch (black, blends in) — no drop-down.
                Color.black
            } else {
                VStack(alignment: .center, spacing: 6) {
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
                            Spacer(minLength: 0)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.top, topInset + 6)     // push content below the physical notch
                .padding(.horizontal, 14)
                .padding(.bottom, 10)
                .frame(minWidth: notchWidth)
                .background(Color.black)
            }
        }
        .clipShape(
            .rect(topLeadingRadius: 0, bottomLeadingRadius: 18,
                  bottomTrailingRadius: 18, topTrailingRadius: 0)
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
