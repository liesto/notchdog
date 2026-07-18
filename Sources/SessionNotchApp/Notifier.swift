import Foundation
import UserNotifications
import SessionNotchCore

enum Notifier {
    static func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func notify(_ s: Session) {
        let content = UNMutableNotificationContent()
        let what: String
        switch s.state {
        case .waitingPermission: what = "waiting for permission"
        case .idleInput: what = "waiting for input"
        case .done: what = "finished"
        case .error: what = "errored"
        case .working: return
        }
        content.title = "\(s.machine) - \(s.project)"
        content.body = s.message ?? "Session \(what)."
        content.sound = .default
        let req = UNNotificationRequest(identifier: s.id + "-" + s.state.rawValue,
                                        content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req)
    }
}
