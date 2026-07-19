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
        let fit = hosting.fittingSize
        if store.sessions.isEmpty {
            // Idle: collapse to exactly the notch, centered — no drop-down.
            let x = screen.frame.midX - notchW / 2
            panel.setFrame(NSRect(x: x, y: screen.frame.maxY - notchH,
                                  width: notchW, height: notchH), display: true)
        } else {
            // Alert: hang straight DOWN from the notch, centered, so the black 0…notchH
            // band (cutout in its center) reads as the notch and row 1 starts right at
            // the cutout bottom — no empty band. Content extends below the menu bar only.
            let x = screen.frame.midX - fit.width / 2
            panel.setFrame(NSRect(x: x, y: screen.frame.maxY - fit.height,
                                  width: fit.width, height: fit.height), display: true)
        }
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
                // Idle: just the notch (black, rounded bottom) — no drop-down.
                Color.black
                    .clipShape(.rect(bottomLeadingRadius: 18, bottomTrailingRadius: 18))
            } else {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(store.sessions) { s in
                        HStack(spacing: 8) {
                            Circle().fill(color(for: s.state)).frame(width: 7, height: 7)
                            Text("\(s.machine) · \(s.project)")
                                .font(.system(size: 12.5, weight: .semibold))
                                .foregroundStyle(.white)
                                .fixedSize()          // hug the text; never stretch
                        }
                    }
                }
                // Row 1 starts right at the cutout bottom (y = notch height); the black
                // above it IS the notch. Never narrower than the notch so the black top
                // matches the cutout width. Trailing room reserved for the "x".
                .padding(.top, topInset)
                .padding(.leading, 14)
                .padding(.trailing, 30)
                .padding(.bottom, 9)
                .frame(minWidth: notchWidth, alignment: .leading)
                .fixedSize(horizontal: true, vertical: false)
                // Custom notch shape: a notch-width strip over the cutout that flares to
                // full content width only BELOW the cutout — the top band never covers a
                // menu item at any label length, and the body drops clean below.
                .background(NotchShape(notchWidth: notchWidth, stripHeight: topInset).fill(Color.black))
                .overlay(alignment: .topTrailing) {
                    // "x" to clear all alerts — in the body (below the strip), top-right.
                    Button { store.clearAll() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.white.opacity(0.5))
                            .padding(5)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.top, topInset + 2)
                    .padding(.trailing, 8)
                }
                .clipShape(NotchShape(notchWidth: notchWidth, stripHeight: topInset))
            }
        }
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

// The notch made to "extend downward": a strip exactly the notch width in the top
// `stripHeight` band (it sits over the cutout, so it's invisible and covers nothing at
// menu-bar level), flaring out to the full content width only BELOW the cutout, with
// rounded bottom corners. Content is centered, so the flare is symmetric.
struct NotchShape: Shape {
    var notchWidth: CGFloat
    var stripHeight: CGFloat
    var bottomRadius: CGFloat = 18

    func path(in rect: CGRect) -> Path {
        let w = rect.width, h = rect.height
        let sx0 = (w - notchWidth) / 2          // strip left edge
        let sx1 = (w + notchWidth) / 2          // strip right edge
        let sh = min(stripHeight, h)            // strip band height
        let r = max(0, min(bottomRadius, (h - sh) / 2, w / 2))
        var p = Path()
        p.move(to: CGPoint(x: sx0, y: 0))               // strip top-left
        p.addLine(to: CGPoint(x: sx1, y: 0))            // strip top-right
        p.addLine(to: CGPoint(x: sx1, y: sh))           // down to body top (right of strip)
        p.addLine(to: CGPoint(x: w, y: sh))             // body top-right corner (square)
        p.addLine(to: CGPoint(x: w, y: h - r))          // body right edge
        p.addQuadCurve(to: CGPoint(x: w - r, y: h), control: CGPoint(x: w, y: h))
        p.addLine(to: CGPoint(x: r, y: h))              // bottom edge
        p.addQuadCurve(to: CGPoint(x: 0, y: h - r), control: CGPoint(x: 0, y: h))
        p.addLine(to: CGPoint(x: 0, y: sh))             // body left edge up
        p.addLine(to: CGPoint(x: sx0, y: sh))           // body top-left to strip
        p.closeSubpath()                                // strip left edge up to start
        return p
    }
}
