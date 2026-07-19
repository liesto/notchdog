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
        // Above the menu bar so the black top covers it and blends into the screen edge.
        panel.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false   // no shadow/border rim; top must go pure black
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
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(store.sessions) { s in
                        HStack(spacing: 9) {
                            Circle().fill(color(for: s.state)).frame(width: 8, height: 8)
                            Text("\(s.machine) · \(s.project)")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(.white)
                            Spacer(minLength: 0)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                // Content sits below the physical notch cutout (nothing can render in
                // the camera hole); the black above it covers the menu bar = "the notch".
                .padding(.top, topInset + 6)
                .padding(.horizontal, 14)
                .padding(.bottom, 10)
                .frame(minWidth: notchWidth)
                .background(Color.black)
                .overlay(alignment: .topTrailing) {
                    // "x" to clear all alerts — only present while alerts show.
                    Button { store.clearAll() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.white.opacity(0.5))
                            .padding(5)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 6)
                    .padding(.trailing, 8)
                }
            }
        }
        .clipShape(
            .rect(topLeadingRadius: 0, bottomLeadingRadius: 18,
                  bottomTrailingRadius: 18, topTrailingRadius: 0)
        )
    }

    private func color(for s: SessionState) -> Color {
        switch s {
        case .waitingPermission, .idleInput: return Color(red: 1.0, green: 0.88, blue: 0.1)
        case .error: return .red
        case .done: return .blue
        case .working: return .gray
        }
    }
}
