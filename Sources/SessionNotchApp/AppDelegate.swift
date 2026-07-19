import AppKit
import SessionNotchCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var store: RegistryStore!
    private var server: EventServer!
    private var statusController: StatusItemController!
    private var mainWindow: MainWindowController!

    func applicationDidFinishLaunching(_ notification: Notification) {
        // .regular so the floating window reliably shows and can be focused;
        // the app is still primarily driven from the menu-bar item.
        NSApp.setActivationPolicy(.regular)
        Notifier.requestAuthorization()

        let home = FileManager.default.homeDirectoryForCurrentUser
        let dir = home.appendingPathComponent(".sessionnotch")

        store = RegistryStore()
        store.onNewAttention = { Notifier.notify($0) }
        statusController = StatusItemController(store: store)
        mainWindow = MainWindowController(store: store)
        mainWindow.show()

        guard let secret = try? Secret.loadOrCreate(at: dir.appendingPathComponent("secret")),
              !secret.isEmpty else {
            NSLog("SessionNotch: could not load or generate a secret; event server NOT started")
            return
        }
        server = EventServer(port: 47823, secret: secret) { [weak self] event in
            self?.store.apply(event)
        }
        // Bind loopback + the Tailscale address so both machines can reach us.
        try? server.start(host: nil) // all interfaces; secret is the gate
        NSLog("SessionNotch listening on 47823; tailscale=\(TailscaleIP.detect() ?? "none")")
    }
}
