import SwiftUI
import SessionNotchCore

struct SessionListView: View {
    @ObservedObject var store: RegistryStore

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if store.sessions.isEmpty {
                Text("No sessions need you.").foregroundStyle(.secondary).padding(8)
            } else {
                ForEach(store.sessions) { s in
                    HStack(spacing: 8) {
                        Circle().fill(color(for: s.state)).frame(width: 8, height: 8)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("\(s.machine) - \(s.project)").font(.system(size: 12, weight: .medium))
                            Text(s.message ?? label(for: s.state))
                                .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                    }.padding(.horizontal, 8).padding(.vertical, 4)
                }
            }
        }.frame(width: 320).padding(.vertical, 6)
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
