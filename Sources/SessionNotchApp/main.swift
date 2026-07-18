import AppKit

// Top-level code in `main.swift` is not implicitly @MainActor-isolated under
// this toolchain, but the entry point genuinely runs on the main thread
// (nothing else could have claimed the MainActor executor yet), so asserting
// that here is safe and lets us call the @MainActor `AppDelegate` init and
// `NSApplication.run()` synchronously.
MainActor.assumeIsolated {
    let delegate = AppDelegate()
    let app = NSApplication.shared
    app.delegate = delegate
    app.run()
}
