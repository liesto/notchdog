# SessionNotch Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A native macOS notch/floating-bar app on the laptop that shows every Claude Code session — on the laptop or the Studio — that currently needs my attention, fed by Claude Code hooks pushing events over the tailnet.

**Architecture:** Claude Code hooks on each machine POST small JSON events to an embedded HTTP server inside the app (laptop hooks → loopback, Studio hooks → laptop's Tailscale address). A pure in-memory `SessionRegistry` turns the event stream into current per-session attention state, which drives a menu-bar baseline UI first and a `DynamicNotchKit` notch overlay on top. All logic that can be pure is isolated in a `SessionNotchCore` SPM library with full XCTest coverage; the GUI executable is a thin wrapper.

**Tech Stack:** Swift 5.9+, Swift Package Manager, AppKit + SwiftUI, `Network` framework (embedded HTTP — no networking dependency), `DynamicNotchKit` (SPM, notch UI only), `UserNotifications` (banners), bash hook scripts.

## Global Constraints

Every task's requirements implicitly include these:

- **Platform floor:** macOS 14.0. `Package.swift` declares `.macOS(.v14)`.
- **Networking:** use the built-in `Network` framework only. Do **not** add a networking/HTTP dependency.
- **External dependencies:** exactly one — `DynamicNotchKit` (https://github.com/MrKai77/DynamicNotchKit), used only by the executable target for the notch UI. The Core library has **zero** external dependencies.
- **Listen port:** `47823` (non-default, per port-hygiene rules). Never a common dev port.
- **Secret discipline:** the shared secret lives at `~/.sessionnotch/secret` (mode `0600`) and is **never** committed. `private/` and `*.secret` are already git-ignored.
- **No emoji** in code, scripts, or committed output. (Color/glyph in UI is fine via SF Symbols / SwiftUI colors.)
- **Git:** author email `jbw@buildabonfire.com`; work on feature branch `feat/sessionnotch-v1` (create it before Task 1); small scoped commits per task.
- **Event kinds** (the wire vocabulary, used verbatim everywhere): `waiting_permission`, `idle`, `done`, `working`, `error`, `session_end`.
- **Testing convention (supersedes XCTest in every task):** This machine has Command Line Tools only — the `XCTest` and `Testing` modules are absent, so `swift test` cannot run. Tests are instead a plain executable target `SessionNotchTests` (`Sources/SessionNotchTests/`, depends on `SessionNotchCore`), run via `swift run SessionNotchTests [name-substring-filter]`. It uses the in-repo harness (`TestHarness.swift`, defined in Task 1) exposing `TestRunner` (with sync `test(_:_:)` and async `test(_:_:) async`, `finish() -> Never` exiting nonzero on any failure) and free functions `expect(_:_:)`, `expectEqual(_:_:)`, `expectThrows(_:_:)` that throw `ExpectationError`. The XCTest `func testX { XCTAssert... }` blocks shown throughout this plan are the **test specification**: translate each into a `runner.test("testX") { try expect... }` call with the identical assertions. RED = run before implementing and see the failure; GREEN = run after and see `N passed, 0 failed`.

---

## File Structure

```
SessionNotch/
  Package.swift
  Sources/
    SessionNotchCore/
      Event.swift              # wire model (Codable) + EventKind; shared JSON coders
      Session.swift            # Session + SessionState; needsAttention rule
      SessionRegistry.swift    # pure state machine over events (no I/O)
      HTTPRequest.swift        # tiny HTTP/1.1 request parser (pure)
      Config.swift             # config.json model, secret load/create, Tailscale IP detect
      EventServer.swift        # NWListener wiring: bytes -> HTTPRequest -> Event -> registry
    SessionNotchApp/
      main.swift               # entry: build core, start server, install app delegate
      AppDelegate.swift        # NSApplicationDelegate; owns registry, server, UI, notifier
      RegistryStore.swift      # ObservableObject adapter over SessionRegistry (main-thread)
      StatusItemController.swift  # NSStatusItem: count + dropdown list + menu
      Notifier.swift           # UNUserNotification banners on new attention
      NotchPresenter.swift     # protocol + DynamicNotchKit-backed presentation
      SessionListView.swift    # SwiftUI list used by both status popover and notch
  Tests/
    SessionNotchCoreTests/
      EventTests.swift
      SessionRegistryTests.swift
      HTTPRequestTests.swift
      ConfigTests.swift
      EventServerTests.swift
  hooks/
    sessionnotch-lib.sh        # shared: load config, classify, build + POST event
    sessionnotch-notify.sh     # Notification hook
    sessionnotch-stop.sh       # Stop hook
    sessionnotch-prompt.sh     # UserPromptSubmit hook
    sessionnotch-end.sh        # SessionEnd hook
    install-hooks.sh           # merge hook config into ~/.claude/settings.json
  tests/hooks/
    run.sh                     # feeds fixtures to hooks, asserts posted JSON
    fixtures/                  # recorded Claude Code hook payloads
  scripts/
    make-app.sh                # wrap the SPM binary into SessionNotch.app (Info.plist + ad-hoc sign)
  PROJECT.json
  README.md
```

**Thread model:** `SessionRegistry` is main-thread-confined. `EventServer` receives on its own `NWListener` queue and hops each decoded event to the main queue before calling `registry.apply`. Tests call `apply` directly on the test thread (equivalent to main).

---

## Task 1: Package scaffold + Event model

**Files:**
- Create: `Package.swift`
- Create: `Sources/SessionNotchCore/Event.swift`
- Create: `PROJECT.json`
- Create: `README.md` (skeleton)
- Test: `Tests/SessionNotchCoreTests/EventTests.swift`

**Interfaces:**
- Produces: `enum EventKind: String, Codable` with cases mapping to the wire strings; `struct Event: Codable, Equatable` with fields `machine, sessionID, project, cwd, kind, message, ts`; `Event.decoder` / `Event.encoder` (ISO-8601 dates).

- [ ] **Step 1: Create the branch**

```bash
cd ~/Agent/SessionNotch && git checkout -b feat/sessionnotch-v1
```

- [ ] **Step 2: Write `Package.swift`**

```swift
// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SessionNotch",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "SessionNotchCore", targets: ["SessionNotchCore"]),
        .executable(name: "SessionNotch", targets: ["SessionNotchApp"]),
    ],
    dependencies: [
        .package(url: "https://github.com/MrKai77/DynamicNotchKit", from: "1.0.0"),
    ],
    targets: [
        .target(name: "SessionNotchCore"),
        .executableTarget(
            name: "SessionNotchApp",
            dependencies: [
                "SessionNotchCore",
                .product(name: "DynamicNotchKit", package: "DynamicNotchKit"),
            ]
        ),
        .testTarget(name: "SessionNotchCoreTests", dependencies: ["SessionNotchCore"]),
    ]
)
```

Note: confirm the latest `DynamicNotchKit` tag with `swift package resolve` after Step 4; adjust `from:` if 1.0.0 predates the published tags. The Core library and its tests do not link DynamicNotchKit, so Tasks 1–5 build and test even if that package needs version tweaking.

- [ ] **Step 3: Write the failing test** — `Tests/SessionNotchCoreTests/EventTests.swift`

```swift
import XCTest
@testable import SessionNotchCore

final class EventTests: XCTestCase {
    func testDecodeWireJSON() throws {
        let json = """
        {"machine":"studio","session_id":"abc123","project":"event-results",
         "cwd":"/Users/w/Agent/USMS/Event Results","event":"waiting_permission",
         "message":"needs permission to run: npm test","ts":"2026-07-18T17:05:22Z"}
        """.data(using: .utf8)!
        let e = try Event.decoder.decode(Event.self, from: json)
        XCTAssertEqual(e.machine, "studio")
        XCTAssertEqual(e.sessionID, "abc123")
        XCTAssertEqual(e.kind, .waitingPermission)
        XCTAssertEqual(e.message, "needs permission to run: npm test")
    }

    func testRoundTrip() throws {
        let e = Event(machine: "laptop", sessionID: "s1", project: "p",
                      cwd: "/tmp", kind: .done, message: nil,
                      ts: Date(timeIntervalSince1970: 1_700_000_000))
        let data = try Event.encoder.encode(e)
        let back = try Event.decoder.decode(Event.self, from: data)
        XCTAssertEqual(e, back)
    }
}
```

- [ ] **Step 4: Run test to verify it fails**

Run: `swift test --filter EventTests`
Expected: FAIL — `SessionNotchCore` has no `Event` type. (This also triggers the first dependency resolve; if DynamicNotchKit resolution errors, pin the version now.)

- [ ] **Step 5: Implement `Sources/SessionNotchCore/Event.swift`**

```swift
import Foundation

public enum EventKind: String, Codable, Sendable {
    case waitingPermission = "waiting_permission"
    case idle
    case done
    case working
    case error
    case sessionEnd = "session_end"
}

public struct Event: Codable, Equatable, Sendable {
    public let machine: String
    public let sessionID: String
    public let project: String
    public let cwd: String
    public let kind: EventKind
    public let message: String?
    public let ts: Date

    enum CodingKeys: String, CodingKey {
        case machine, project, cwd, message, ts
        case sessionID = "session_id"
        case kind = "event"
    }

    public init(machine: String, sessionID: String, project: String,
                cwd: String, kind: EventKind, message: String?, ts: Date) {
        self.machine = machine; self.sessionID = sessionID; self.project = project
        self.cwd = cwd; self.kind = kind; self.message = message; self.ts = ts
    }

    public static let decoder: JSONDecoder = {
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d
    }()
    public static let encoder: JSONEncoder = {
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e
    }()
}
```

- [ ] **Step 6: Run test to verify it passes**

Run: `swift test --filter EventTests`
Expected: PASS (2 tests).

- [ ] **Step 7: Write `PROJECT.json` and `README.md` skeleton**

`PROJECT.json`:
```json
{
  "title": "SessionNotch",
  "description": "macOS notch app showing Claude Code sessions needing attention across laptop + Studio",
  "group": "Personal",
  "stage": "building",
  "tags": ["macos", "swift", "claude-code", "tooling"],
  "completed": [],
  "next": ["Implement per docs/superpowers/plans/2026-07-18-sessionnotch.md"],
  "updatedAt": "2026-07-18"
}
```

`README.md` skeleton (one line each): title, one-paragraph what/why, and a "See `docs/superpowers/specs/2026-07-18-sessionnotch-design.md`" pointer. Full usage docs land in Task 8.

- [ ] **Step 8: Commit**

```bash
git add Package.swift Sources/SessionNotchCore/Event.swift Tests/SessionNotchCoreTests/EventTests.swift PROJECT.json README.md
git commit -m "feat: package scaffold and Event wire model"
```

---

## Task 2: SessionRegistry state machine

**Files:**
- Create: `Sources/SessionNotchCore/Session.swift`
- Create: `Sources/SessionNotchCore/SessionRegistry.swift`
- Test: `Tests/SessionNotchCoreTests/SessionRegistryTests.swift`

**Interfaces:**
- Consumes: `Event`, `EventKind` (Task 1).
- Produces:
  - `enum SessionState: String { working, waitingPermission, idleInput, done, error }`
  - `struct Session: Identifiable, Equatable` with `machine, sessionID, project, cwd, state, message, lastEvent: Date`, computed `id: String` (`"\(machine)#\(sessionID)"`) and `needsAttention: Bool` (`state != .working`).
  - `final class SessionRegistry` with: `init(staleAfter: TimeInterval = 900)`; `@discardableResult func apply(_ event: Event) -> Session?`; `func expireStale(now: Date)`; `var needingAttention: [Session]` (sorted newest-first); callbacks `var onChange: (() -> Void)?` and `var onNewAttention: ((Session) -> Void)?`.

- [ ] **Step 1: Write the failing tests** — `Tests/SessionNotchCoreTests/SessionRegistryTests.swift`

```swift
import XCTest
@testable import SessionNotchCore

final class SessionRegistryTests: XCTestCase {
    private func ev(_ kind: EventKind, machine: String = "studio",
                    session: String = "s1", at t: TimeInterval = 0) -> Event {
        Event(machine: machine, sessionID: session, project: "proj",
              cwd: "/tmp/proj", kind: kind, message: nil,
              ts: Date(timeIntervalSince1970: t))
    }

    func testPermissionEventNeedsAttention() {
        let r = SessionRegistry()
        r.apply(ev(.waitingPermission))
        XCTAssertEqual(r.needingAttention.count, 1)
        XCTAssertEqual(r.needingAttention.first?.state, .waitingPermission)
    }

    func testWorkingClearsAttention() {
        let r = SessionRegistry()
        r.apply(ev(.waitingPermission, at: 0))
        r.apply(ev(.working, at: 1))
        XCTAssertTrue(r.needingAttention.isEmpty)
    }

    func testSessionEndRemovesSession() {
        let r = SessionRegistry()
        r.apply(ev(.done, at: 0))
        r.apply(ev(.sessionEnd, at: 1))
        XCTAssertTrue(r.needingAttention.isEmpty)
    }

    func testNewAttentionFiresOncePerEntry() {
        let r = SessionRegistry()
        var fired = 0
        r.onNewAttention = { _ in fired += 1 }
        r.apply(ev(.waitingPermission, at: 0)) // enter attention -> fire
        r.apply(ev(.done, at: 1))              // still attention -> no fire
        r.apply(ev(.working, at: 2))           // clear
        r.apply(ev(.idle, at: 3))              // re-enter -> fire
        XCTAssertEqual(fired, 2)
    }

    func testExpireStaleDropsOldSessions() {
        let r = SessionRegistry(staleAfter: 60)
        r.apply(ev(.done, at: 0))
        r.expireStale(now: Date(timeIntervalSince1970: 120))
        XCTAssertTrue(r.needingAttention.isEmpty)
    }

    func testKeyedByMachineAndSession() {
        let r = SessionRegistry()
        r.apply(ev(.idle, machine: "studio", session: "s1", at: 0))
        r.apply(ev(.idle, machine: "laptop", session: "s1", at: 0))
        XCTAssertEqual(r.needingAttention.count, 2)
    }

    func testNewestFirstOrdering() {
        let r = SessionRegistry()
        r.apply(ev(.idle, session: "old", at: 10))
        r.apply(ev(.idle, session: "new", at: 20))
        XCTAssertEqual(r.needingAttention.first?.sessionID, "new")
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter SessionRegistryTests`
Expected: FAIL — no `Session`/`SessionRegistry` types.

- [ ] **Step 3: Implement `Sources/SessionNotchCore/Session.swift`**

```swift
import Foundation

public enum SessionState: String, Sendable {
    case working, waitingPermission, idleInput, done, error
}

public struct Session: Identifiable, Equatable, Sendable {
    public let machine: String
    public let sessionID: String
    public var project: String
    public var cwd: String
    public var state: SessionState
    public var message: String?
    public var lastEvent: Date

    public var id: String { "\(machine)#\(sessionID)" }
    public var needsAttention: Bool { state != .working }
}
```

- [ ] **Step 4: Implement `Sources/SessionNotchCore/SessionRegistry.swift`**

```swift
import Foundation

public final class SessionRegistry {
    private(set) public var sessions: [String: Session] = [:]
    public let staleAfter: TimeInterval
    public var onChange: (() -> Void)?
    public var onNewAttention: ((Session) -> Void)?

    public init(staleAfter: TimeInterval = 900) { self.staleAfter = staleAfter }

    private static func state(for kind: EventKind) -> SessionState? {
        switch kind {
        case .waitingPermission: return .waitingPermission
        case .idle: return .idleInput
        case .done: return .done
        case .working: return .working
        case .error: return .error
        case .sessionEnd: return nil
        }
    }

    @discardableResult
    public func apply(_ event: Event) -> Session? {
        let key = "\(event.machine)#\(event.sessionID)"

        if event.kind == .sessionEnd {
            if sessions.removeValue(forKey: key) != nil { onChange?() }
            return nil
        }
        guard let newState = Self.state(for: event.kind) else { return nil }

        let wasAttention = sessions[key]?.needsAttention ?? false
        var s = sessions[key] ?? Session(machine: event.machine, sessionID: event.sessionID,
                                         project: event.project, cwd: event.cwd,
                                         state: newState, message: event.message,
                                         lastEvent: event.ts)
        s.project = event.project
        s.cwd = event.cwd
        s.state = newState
        s.message = event.message
        s.lastEvent = event.ts
        sessions[key] = s

        if s.needsAttention && !wasAttention { onNewAttention?(s) }
        onChange?()
        return s
    }

    public func expireStale(now: Date) {
        let cutoff = now.addingTimeInterval(-staleAfter)
        let before = sessions.count
        sessions = sessions.filter { $0.value.lastEvent >= cutoff }
        if sessions.count != before { onChange?() }
    }

    public var needingAttention: [Session] {
        sessions.values.filter { $0.needsAttention }.sorted { $0.lastEvent > $1.lastEvent }
    }
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `swift test --filter SessionRegistryTests`
Expected: PASS (7 tests).

- [ ] **Step 6: Commit**

```bash
git add Sources/SessionNotchCore/Session.swift Sources/SessionNotchCore/SessionRegistry.swift Tests/SessionNotchCoreTests/SessionRegistryTests.swift
git commit -m "feat: SessionRegistry attention state machine"
```

---

## Task 3: HTTP request parser

**Files:**
- Create: `Sources/SessionNotchCore/HTTPRequest.swift`
- Test: `Tests/SessionNotchCoreTests/HTTPRequestTests.swift`

**Interfaces:**
- Produces: `struct HTTPRequest { let method: String; let path: String; let headers: [String:String] (lowercased keys); let body: Data }` and `static func parse(_ data: Data) throws -> (request: HTTPRequest, consumed: Int)?` returning `nil` when more bytes are needed, throwing `HTTPRequest.ParseError.malformed` on a broken request line.

- [ ] **Step 1: Write the failing tests** — `Tests/SessionNotchCoreTests/HTTPRequestTests.swift`

```swift
import XCTest
@testable import SessionNotchCore

final class HTTPRequestTests: XCTestCase {
    func testParsePostWithBody() throws {
        let raw = "POST /event HTTP/1.1\r\nHost: x\r\nX-SessionNotch-Secret: k\r\nContent-Length: 5\r\n\r\nhello"
        let result = try HTTPRequest.parse(Data(raw.utf8))
        let req = try XCTUnwrap(result).request
        XCTAssertEqual(req.method, "POST")
        XCTAssertEqual(req.path, "/event")
        XCTAssertEqual(req.headers["x-sessionnotch-secret"], "k")
        XCTAssertEqual(String(data: req.body, encoding: .utf8), "hello")
    }

    func testIncompleteBodyReturnsNil() throws {
        let raw = "POST /event HTTP/1.1\r\nContent-Length: 10\r\n\r\nshort"
        XCTAssertNil(try HTTPRequest.parse(Data(raw.utf8)))
    }

    func testIncompleteHeadersReturnsNil() throws {
        XCTAssertNil(try HTTPRequest.parse(Data("GET /health HTTP/1.1\r\nHost: x".utf8)))
    }

    func testGetNoBody() throws {
        let raw = "GET /health HTTP/1.1\r\nHost: x\r\n\r\n"
        let req = try XCTUnwrap(try HTTPRequest.parse(Data(raw.utf8))).request
        XCTAssertEqual(req.method, "GET")
        XCTAssertEqual(req.path, "/health")
        XCTAssertTrue(req.body.isEmpty)
    }

    func testMalformedRequestLineThrows() {
        XCTAssertThrowsError(try HTTPRequest.parse(Data("GARBAGE\r\n\r\n".utf8)))
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter HTTPRequestTests`
Expected: FAIL — no `HTTPRequest` type.

- [ ] **Step 3: Implement `Sources/SessionNotchCore/HTTPRequest.swift`**

```swift
import Foundation

public struct HTTPRequest {
    public let method: String
    public let path: String
    public let headers: [String: String]   // lowercased keys
    public let body: Data

    public enum ParseError: Error { case malformed }

    /// Parse a single HTTP/1.1 request from the front of `data`.
    /// Returns nil if more bytes are needed; throws on a malformed request line.
    public static func parse(_ data: Data) throws -> (request: HTTPRequest, consumed: Int)? {
        let sep = Data("\r\n\r\n".utf8)
        guard let sepRange = data.range(of: sep) else { return nil } // headers incomplete

        let headerData = data[data.startIndex..<sepRange.lowerBound]
        guard let headerString = String(data: headerData, encoding: .utf8) else {
            throw ParseError.malformed
        }
        var lines = headerString.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { throw ParseError.malformed }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else { throw ParseError.malformed }
        let method = String(parts[0])
        let path = String(parts[1])
        lines.removeFirst()

        var headers: [String: String] = [:]
        for line in lines where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }

        let contentLength = Int(headers["content-length"] ?? "0") ?? 0
        let bodyStart = sepRange.upperBound
        let available = data.distance(from: bodyStart, to: data.endIndex)
        if available < contentLength { return nil } // body incomplete

        let bodyEnd = data.index(bodyStart, offsetBy: contentLength)
        let body = Data(data[bodyStart..<bodyEnd])
        let consumed = data.distance(from: data.startIndex, to: bodyEnd)
        return (HTTPRequest(method: method, path: path, headers: headers, body: body), consumed)
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter HTTPRequestTests`
Expected: PASS (5 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/SessionNotchCore/HTTPRequest.swift Tests/SessionNotchCoreTests/HTTPRequestTests.swift
git commit -m "feat: minimal HTTP/1.1 request parser"
```

---

## Task 4: Config, secret, and Tailscale IP detection

**Files:**
- Create: `Sources/SessionNotchCore/Config.swift`
- Test: `Tests/SessionNotchCoreTests/ConfigTests.swift`

**Interfaces:**
- Produces:
  - `struct Config: Codable, Equatable { var machine: String; var endpoint: String; var port: Int }` with `static func load(from url: URL) throws -> Config`.
  - `enum Secret { static func loadOrCreate(at url: URL) throws -> String }` — returns existing secret file contents (trimmed) or generates a 64-hex-char secret, writing it `0600`.
  - `enum TailscaleIP { static func detect() -> String?; static func isCGNAT(_ ipv4: String) -> Bool }` — `detect()` scans interfaces for an IPv4 in `100.64.0.0/10`.

- [ ] **Step 1: Write the failing tests** — `Tests/SessionNotchCoreTests/ConfigTests.swift`

```swift
import XCTest
@testable import SessionNotchCore

final class ConfigTests: XCTestCase {
    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("sn-\(UUID().uuidString)")
    }

    func testLoadConfig() throws {
        let url = tempURL()
        try #"{"machine":"laptop","endpoint":"http://127.0.0.1:47823/event","port":47823}"#
            .write(to: url, atomically: true, encoding: .utf8)
        let c = try Config.load(from: url)
        XCTAssertEqual(c.machine, "laptop")
        XCTAssertEqual(c.port, 47823)
    }

    func testSecretCreatedWith0600() throws {
        let url = tempURL()
        let s1 = try Secret.loadOrCreate(at: url)
        XCTAssertEqual(s1.count, 64)
        let perms = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(perms?.int16Value, 0o600)
        let s2 = try Secret.loadOrCreate(at: url) // stable on reload
        XCTAssertEqual(s1, s2)
    }

    func testIsCGNAT() {
        XCTAssertTrue(TailscaleIP.isCGNAT("100.90.12.34"))
        XCTAssertTrue(TailscaleIP.isCGNAT("100.127.0.1"))
        XCTAssertFalse(TailscaleIP.isCGNAT("192.168.1.10"))
        XCTAssertFalse(TailscaleIP.isCGNAT("100.128.0.1")) // above /10
        XCTAssertFalse(TailscaleIP.isCGNAT("10.0.0.1"))
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter ConfigTests`
Expected: FAIL — no `Config`/`Secret`/`TailscaleIP`.

- [ ] **Step 3: Implement `Sources/SessionNotchCore/Config.swift`**

```swift
import Foundation

public struct Config: Codable, Equatable, Sendable {
    public var machine: String
    public var endpoint: String
    public var port: Int

    public static func load(from url: URL) throws -> Config {
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(Config.self, from: data)
    }
}

public enum Secret {
    public static func loadOrCreate(at url: URL) throws -> String {
        if let data = try? Data(contentsOf: url),
           let s = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !s.isEmpty {
            return s
        }
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let hex = bytes.map { String(format: "%02x", $0) }.joined()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try hex.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return hex
    }
}

public enum TailscaleIP {
    public static func isCGNAT(_ ipv4: String) -> Bool {
        let parts = ipv4.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4, parts[0] == 100 else { return false }
        return (64...127).contains(parts[1]) // 100.64.0.0/10
    }

    public static func detect() -> String? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(ptr.pointee.ifa_flags)
            guard (flags & IFF_UP) == IFF_UP, let sa = ptr.pointee.ifa_addr,
                  sa.pointee.sa_family == UInt8(AF_INET) else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count),
                        nil, 0, NI_NUMERICHOST)
            let ip = String(cString: host)
            if isCGNAT(ip) { return ip }
        }
        return nil
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter ConfigTests`
Expected: PASS (3 tests). `testIsCGNAT` and secret tests are deterministic; `detect()` is exercised in Task 9 on real hardware.

- [ ] **Step 5: Commit**

```bash
git add Sources/SessionNotchCore/Config.swift Tests/SessionNotchCoreTests/ConfigTests.swift
git commit -m "feat: config load, secret generation, Tailscale IP detection"
```

---

## Task 5: EventServer (NWListener)

**Files:**
- Create: `Sources/SessionNotchCore/EventServer.swift`
- Test: `Tests/SessionNotchCoreTests/EventServerTests.swift`

**Interfaces:**
- Consumes: `HTTPRequest`, `Event`, `SessionRegistry`.
- Produces: `final class EventServer` with `init(port: UInt16, secret: String, onEvent: @escaping (Event) -> Void)`; `func start(host: String?) throws` (nil host = all interfaces, else bind to that IPv4); `func stop()`; `var boundPort: UInt16?`. Routing: `POST /event` with valid `X-SessionNotch-Secret` → decode `Event` → `onEvent` on main queue → `204`; bad secret → `401`; other paths → `404`; `GET /health` → `200`.

- [ ] **Step 1: Write the failing integration test** — `Tests/SessionNotchCoreTests/EventServerTests.swift`

```swift
import XCTest
@testable import SessionNotchCore

final class EventServerTests: XCTestCase {
    private let port: UInt16 = 47899 // test port, not the app's 47823

    private func post(_ path: String, body: Data, secret: String?) async throws -> Int {
        var req = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!)
        req.httpMethod = "POST"
        req.httpBody = body
        if let secret { req.setValue(secret, forHTTPHeaderField: "X-SessionNotch-Secret") }
        let (_, resp) = try await URLSession.shared.data(for: req)
        return (resp as! HTTPURLResponse).statusCode
    }

    func testValidEventIsDelivered() async throws {
        let exp = expectation(description: "event")
        var received: Event?
        let server = EventServer(port: port, secret: "k") { e in received = e; exp.fulfill() }
        try server.start(host: "127.0.0.1")
        defer { server.stop() }

        let body = try Event.encoder.encode(
            Event(machine: "laptop", sessionID: "s1", project: "p", cwd: "/tmp",
                  kind: .idle, message: "hi", ts: Date(timeIntervalSince1970: 1)))
        let code = try await post("/event", body: body, secret: "k")
        XCTAssertEqual(code, 204)
        await fulfillment(of: [exp], timeout: 2)
        XCTAssertEqual(received?.sessionID, "s1")
    }

    func testWrongSecretRejected() async throws {
        let server = EventServer(port: port, secret: "k") { _ in }
        try server.start(host: "127.0.0.1")
        defer { server.stop() }
        let code = try await post("/event", body: Data("{}".utf8), secret: "wrong")
        XCTAssertEqual(code, 401)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter EventServerTests`
Expected: FAIL — no `EventServer` type.

- [ ] **Step 3: Implement `Sources/SessionNotchCore/EventServer.swift`**

```swift
import Foundation
import Network

public final class EventServer {
    private let port: NWEndpoint.Port
    private let secret: String
    private let onEvent: (Event) -> Void
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "sessionnotch.server")

    public private(set) var boundPort: UInt16?

    public init(port: UInt16, secret: String, onEvent: @escaping (Event) -> Void) {
        self.port = NWEndpoint.Port(rawValue: port)!
        self.secret = secret
        self.onEvent = onEvent
    }

    public func start(host: String?) throws {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        if let host {
            params.requiredLocalEndpoint = NWEndpoint.hostPort(host: .init(host), port: port)
        }
        let listener = try NWListener(using: params, on: port)
        listener.newConnectionHandler = { [weak self] conn in self?.handle(conn) }
        listener.start(queue: queue)
        self.listener = listener
        self.boundPort = port.rawValue
    }

    public func stop() { listener?.cancel(); listener = nil }

    private func handle(_ conn: NWConnection) {
        conn.start(queue: queue)
        receive(conn, buffer: Data())
    }

    private func receive(_ conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, done, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let parsed = try? HTTPRequest.parse(buffer), let result = parsed {
                self.respond(conn, to: result.request)
                return
            }
            if error != nil || done { conn.cancel(); return }
            self.receive(conn, buffer: buffer)
        }
    }

    private func respond(_ conn: NWConnection, to req: HTTPRequest) {
        let (status, reason): (Int, String)
        if req.method == "GET", req.path == "/health" {
            (status, reason) = (200, "OK")
        } else if req.path != "/event" {
            (status, reason) = (404, "Not Found")
        } else if req.headers["x-sessionnotch-secret"] != secret {
            (status, reason) = (401, "Unauthorized")
        } else if let event = try? Event.decoder.decode(Event.self, from: req.body) {
            DispatchQueue.main.async { self.onEvent(event) }
            (status, reason) = (204, "No Content")
        } else {
            (status, reason) = (400, "Bad Request")
        }
        let response = "HTTP/1.1 \(status) \(reason)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
        conn.send(content: Data(response.utf8), completion: .contentProcessed { _ in conn.cancel() })
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter EventServerTests`
Expected: PASS (2 tests). If the sandbox blocks localhost sockets, run with network access enabled.

- [ ] **Step 5: Run the whole core suite**

Run: `swift test`
Expected: all Core tests PASS.

- [ ] **Step 6: Commit**

```bash
git add Sources/SessionNotchCore/EventServer.swift Tests/SessionNotchCoreTests/EventServerTests.swift
git commit -m "feat: NWListener-based event server with secret auth"
```

---

## Task 6: App shell — menu-bar baseline, notifier, and packaging

This is the first end-to-end milestone: a running `.app` that receives events and shows them in the menu bar with banners. The notch overlay is added in Task 7 on top of the same store.

**Files:**
- Create: `Sources/SessionNotchApp/main.swift`
- Create: `Sources/SessionNotchApp/AppDelegate.swift`
- Create: `Sources/SessionNotchApp/RegistryStore.swift`
- Create: `Sources/SessionNotchApp/StatusItemController.swift`
- Create: `Sources/SessionNotchApp/Notifier.swift`
- Create: `Sources/SessionNotchApp/SessionListView.swift`
- Create: `scripts/make-app.sh`

**Interfaces:**
- Consumes: `SessionRegistry`, `EventServer`, `Config`, `Secret`, `TailscaleIP` (Core).
- Produces: `final class RegistryStore: ObservableObject` wrapping `SessionRegistry` on the main thread, exposing `@Published var sessions: [Session]`; `func apply(_ event: Event)`. Used by Task 7.

- [ ] **Step 1: `RegistryStore.swift` — ObservableObject adapter**

```swift
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
```

- [ ] **Step 2: `Notifier.swift` — banners**

```swift
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
```

- [ ] **Step 3: `SessionListView.swift` — shared SwiftUI list**

```swift
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
```

- [ ] **Step 4: `StatusItemController.swift`**

```swift
import AppKit
import SwiftUI

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
```

Add `import Combine` at the top of this file (needed for `sink`/`Set<AnyCancellable>`).

- [ ] **Step 5: `AppDelegate.swift` — wire everything**

```swift
import AppKit
import SessionNotchCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var store: RegistryStore!
    private var server: EventServer!
    private var statusController: StatusItemController!

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory) // menu-bar app, no Dock icon
        Notifier.requestAuthorization()

        let home = FileManager.default.homeDirectoryForCurrentUser
        let dir = home.appendingPathComponent(".sessionnotch")
        let secret = (try? Secret.loadOrCreate(at: dir.appendingPathComponent("secret"))) ?? ""

        store = RegistryStore()
        store.onNewAttention = { Notifier.notify($0) }
        statusController = StatusItemController(store: store)

        server = EventServer(port: 47823, secret: secret) { [weak self] event in
            self?.store.apply(event)
        }
        // Bind loopback + the Tailscale address so both machines can reach us.
        try? server.start(host: nil) // all interfaces; secret is the gate
        NSLog("SessionNotch listening on 47823; tailscale=\(TailscaleIP.detect() ?? "none")")
    }
}
```

Note: binding `host: nil` listens on all interfaces (secret-gated). If you prefer to restrict to the Tailscale IP only, start with `host: TailscaleIP.detect()` plus a second loopback listener — but v1 ships all-interfaces + secret, matching the spec's "secret is the real gate."

- [ ] **Step 6: `main.swift` — entry point**

```swift
import AppKit

let delegate = AppDelegate()
let app = NSApplication.shared
app.delegate = delegate
app.run()
```

- [ ] **Step 7: `scripts/make-app.sh` — wrap the binary into a bundle**

```bash
#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="${1:-release}"
swift build -c "$CONFIG"
BIN="$(swift build -c "$CONFIG" --show-bin-path)/SessionNotch"
APP="$ROOT/build/SessionNotch.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/SessionNotch"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>SessionNotch</string>
  <key>CFBundleIdentifier</key><string>com.buildabonfire.sessionnotch</string>
  <key>CFBundleExecutable</key><string>SessionNotch</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>LSUIElement</key><true/>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
</dict></plist>
PLIST
codesign --force --sign - "$APP" >/dev/null 2>&1 || true
echo "Built $APP"
```

`chmod +x scripts/make-app.sh`. The bundle id + `LSUIElement` are what make `UNUserNotification` work and keep it out of the Dock.

- [ ] **Step 8: Build the app bundle and smoke-test end-to-end**

Run:
```bash
bash scripts/make-app.sh debug
open build/SessionNotch.app
```
Then post a fake event from another terminal:
```bash
SECRET=$(cat ~/.sessionnotch/secret)
curl -s -o /dev/null -w "%{http_code}\n" -X POST http://127.0.0.1:47823/event \
  -H "X-SessionNotch-Secret: $SECRET" \
  -d '{"machine":"laptop","session_id":"demo","project":"smoke","cwd":"/tmp","event":"waiting_permission","message":"approve npm test","ts":"2026-07-18T18:00:00Z"}'
```
Expected: `204`; the menu-bar title shows `SN 1`; a banner appears (grant notification permission on first run); clicking the menu-bar item shows the row `laptop - smoke`. Post again with `"event":"working"` and confirm the count returns to `SN`.

- [ ] **Step 9: Commit**

```bash
git add Sources/SessionNotchApp scripts/make-app.sh
git commit -m "feat: menu-bar app shell, notifier, and app bundle packaging"
```

---

## Task 7: Notch presentation via DynamicNotchKit

**Files:**
- Create: `Sources/SessionNotchApp/NotchPresenter.swift`
- Modify: `Sources/SessionNotchApp/AppDelegate.swift` (instantiate the presenter)

**Interfaces:**
- Consumes: `RegistryStore`, `SessionListView`, `DynamicNotchKit`.
- Produces: `protocol NotchPresenting { func show(); func hide() }` and `final class NotchPresenter: NotchPresenting` wrapping a `DynamicNotch` whose content is `SessionListView(store:)`, auto-showing when `store.sessions` is non-empty.

- [ ] **Step 1: Verify the DynamicNotchKit API**

Run: `swift package resolve` then inspect the resolved source:
```bash
find .build/checkouts/DynamicNotchKit -name "*.swift" | xargs grep -l "public" | head
```
Read the initializer + `show`/`hide` signatures. The code below targets the common `DynamicNotch(content:)` + `show(for:)` / `hide()` shape; adjust names to the resolved version. The `NotchPresenting` protocol isolates any drift so only this file changes.

- [ ] **Step 2: Implement `NotchPresenter.swift`**

```swift
import SwiftUI
import Combine
import DynamicNotchKit

@MainActor
protocol NotchPresenting { func show(); func hide() }

@MainActor
final class NotchPresenter: NotchPresenting {
    private let store: RegistryStore
    private let notch: DynamicNotch<AnyView>
    private var cancellables = Set<AnyCancellable>()

    init(store: RegistryStore) {
        self.store = store
        self.notch = DynamicNotch(content: AnyView(SessionListView(store: store)))
        // Show whenever something needs attention; hide when the board clears.
        store.$sessions
            .receive(on: RunLoop.main)
            .sink { [weak self] sessions in
                if sessions.isEmpty { self?.hide() } else { self?.show() }
            }
            .store(in: &cancellables)
    }

    func show() { notch.show() }   // adjust to resolved API (e.g. notch.show(for:))
    func hide() { notch.hide() }
}
```

- [ ] **Step 3: Wire it in `AppDelegate.applicationDidFinishLaunching`**

Add after `statusController = ...`:
```swift
        notchPresenter = NotchPresenter(store: store)
```
And add the stored property near the other properties:
```swift
    private var notchPresenter: NotchPresenter!
```

- [ ] **Step 4: Rebuild and verify the notch**

Run:
```bash
bash scripts/make-app.sh debug && open build/SessionNotch.app
SECRET=$(cat ~/.sessionnotch/secret)
curl -s -X POST http://127.0.0.1:47823/event -H "X-SessionNotch-Secret: $SECRET" \
  -d '{"machine":"studio","session_id":"n1","project":"notch-demo","cwd":"/tmp","event":"idle","message":"answer my question","ts":"2026-07-18T18:10:00Z"}' >/dev/null
```
Expected: the notch/floating bar drops down showing `studio - notch-demo`. Post the same session with `"event":"working"` and confirm the notch retracts.

- [ ] **Step 5: Commit**

```bash
git add Sources/SessionNotchApp/NotchPresenter.swift Sources/SessionNotchApp/AppDelegate.swift
git commit -m "feat: DynamicNotchKit notch presentation driven by registry"
```

---

## Task 8: Hook scripts

**Files:**
- Create: `hooks/sessionnotch-lib.sh`
- Create: `hooks/sessionnotch-notify.sh`
- Create: `hooks/sessionnotch-stop.sh`
- Create: `hooks/sessionnotch-prompt.sh`
- Create: `hooks/sessionnotch-end.sh`
- Create: `hooks/install-hooks.sh`
- Create: `tests/hooks/run.sh`
- Create: `tests/hooks/fixtures/notification-permission.json`, `notification-idle.json`, `stop.json`, `prompt.json`, `end-normal.json`, `end-error.json`

**Interfaces:**
- Consumes: the app's `POST /event` contract and `~/.sessionnotch/{config.json,secret}`.
- Produces: hook scripts that read Claude Code hook JSON on stdin and POST an `Event`. Classification: Notification message containing `permission` → `waiting_permission`, else → `idle`; SessionEnd `reason` in {`error`,`crash`,`aborted`} → `error`, else → `session_end`.

- [ ] **Step 1: Write the shared library `hooks/sessionnotch-lib.sh`**

```bash
#!/usr/bin/env bash
# Shared helpers for SessionNotch hooks. Sourced by each hook script.
set -euo pipefail

SN_DIR="${SESSIONNOTCH_DIR:-$HOME/.sessionnotch}"

sn_post() {
  # $1=event kind, $2=message (optional). Reads Claude hook JSON from $SN_INPUT.
  local kind="$1" message="${2:-}"
  local cfg="$SN_DIR/config.json" secret_file="$SN_DIR/secret"
  [ -f "$cfg" ] && [ -f "$secret_file" ] || exit 0   # not configured: no-op

  local endpoint machine secret
  endpoint=$(jq -r '.endpoint' "$cfg")
  machine=$(jq -r '.machine' "$cfg")
  secret=$(cat "$secret_file")

  local session cwd project ts
  session=$(printf '%s' "$SN_INPUT" | jq -r '.session_id // "unknown"')
  cwd=$(printf '%s' "$SN_INPUT" | jq -r '.cwd // "."')
  project=$(basename "$cwd")
  ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)

  local payload
  payload=$(jq -n --arg m "$machine" --arg s "$session" --arg p "$project" \
    --arg c "$cwd" --arg e "$kind" --arg msg "$message" --arg t "$ts" \
    '{machine:$m, session_id:$s, project:$p, cwd:$c, event:$e,
      message:(if $msg=="" then null else $msg end), ts:$t}')

  curl -s --max-time 2 -X POST "$endpoint" \
    -H "X-SessionNotch-Secret: $secret" -d "$payload" >/dev/null 2>&1 || true
}
```

- [ ] **Step 2: Write the four hook scripts**

`hooks/sessionnotch-notify.sh`:
```bash
#!/usr/bin/env bash
set -euo pipefail
SN_INPUT="$(cat)"; export SN_INPUT
source "$(dirname "$0")/sessionnotch-lib.sh"
msg=$(printf '%s' "$SN_INPUT" | jq -r '.message // ""')
if printf '%s' "$msg" | grep -qi 'permission'; then
  sn_post waiting_permission "$msg"
else
  sn_post idle "$msg"
fi
```

`hooks/sessionnotch-stop.sh`:
```bash
#!/usr/bin/env bash
set -euo pipefail
SN_INPUT="$(cat)"; export SN_INPUT
source "$(dirname "$0")/sessionnotch-lib.sh"
sn_post done ""
```

`hooks/sessionnotch-prompt.sh`:
```bash
#!/usr/bin/env bash
set -euo pipefail
SN_INPUT="$(cat)"; export SN_INPUT
source "$(dirname "$0")/sessionnotch-lib.sh"
sn_post working ""
```

`hooks/sessionnotch-end.sh`:
```bash
#!/usr/bin/env bash
set -euo pipefail
SN_INPUT="$(cat)"; export SN_INPUT
source "$(dirname "$0")/sessionnotch-lib.sh"
reason=$(printf '%s' "$SN_INPUT" | jq -r '.reason // ""')
case "$reason" in
  error|crash|aborted) sn_post error "$reason" ;;
  *) sn_post session_end "" ;;
esac
```

`chmod +x hooks/*.sh`.

- [ ] **Step 3: Write fixtures**

Example `tests/hooks/fixtures/notification-permission.json`:
```json
{"session_id":"s1","cwd":"/Users/w/Agent/USMS/Event Results","message":"Claude needs your permission to run: npm test"}
```
`notification-idle.json`: same shape, `"message":"Claude is waiting for your input"`.
`stop.json`: `{"session_id":"s1","cwd":"/tmp/p"}`.
`prompt.json`: `{"session_id":"s1","cwd":"/tmp/p"}`.
`end-error.json`: `{"session_id":"s1","cwd":"/tmp/p","reason":"error"}`.
`end-normal.json`: `{"session_id":"s1","cwd":"/tmp/p","reason":"clear"}`.

- [ ] **Step 4: Write the hook test harness `tests/hooks/run.sh`**

```bash
#!/usr/bin/env bash
# Runs each hook against a fixture with a stub endpoint; asserts the posted event kind.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TMP="$(mktemp -d)"
export SESSIONNOTCH_DIR="$TMP"
echo "testsecret" > "$TMP/secret"

# Stub server: nc writes the request body to a file, replies 204.
PORT=47898
printf '{"machine":"testbox","endpoint":"http://127.0.0.1:%s/event","port":%s}' "$PORT" "$PORT" > "$TMP/config.json"

assert_kind() { # $1 hook script, $2 fixture, $3 expected kind
  local out="$TMP/req.txt"
  ( printf 'HTTP/1.1 204 No Content\r\nContent-Length: 0\r\n\r\n' | nc -l "$PORT" > "$out" ) &
  local ncpid=$!
  sleep 0.2
  "$ROOT/hooks/$1" < "$ROOT/tests/hooks/fixtures/$2" || true
  wait "$ncpid" 2>/dev/null || true
  if grep -q "\"event\":\"$3\"" "$out"; then echo "ok: $1 $2 -> $3"; else
    echo "FAIL: $1 $2 expected $3"; cat "$out"; exit 1; fi
}

assert_kind sessionnotch-notify.sh notification-permission.json waiting_permission
assert_kind sessionnotch-notify.sh notification-idle.json idle
assert_kind sessionnotch-stop.sh   stop.json                 done
assert_kind sessionnotch-prompt.sh prompt.json               working
assert_kind sessionnotch-end.sh    end-error.json            error
assert_kind sessionnotch-end.sh    end-normal.json           session_end
echo "all hook tests passed"
```

- [ ] **Step 5: Run the hook tests**

Run: `bash tests/hooks/run.sh`
Expected: `all hook tests passed`. Requires `jq`, `curl`, `nc` (all present on macOS; `jq` via `brew install jq` if missing).

- [ ] **Step 6: Write `hooks/install-hooks.sh`**

```bash
#!/usr/bin/env bash
# Merge SessionNotch hooks into ~/.claude/settings.json and write ~/.sessionnotch/config.json.
# Usage: install-hooks.sh <machine-name> <endpoint-url>
set -euo pipefail
MACHINE="${1:?machine name}"; ENDPOINT="${2:?endpoint url, e.g. http://laptop.tail-scale.ts.net:47823/event}"
HOOKS_DIR="$(cd "$(dirname "$0")" && pwd)"
SN_DIR="$HOME/.sessionnotch"; mkdir -p "$SN_DIR"

jq -n --arg m "$MACHINE" --arg e "$ENDPOINT" \
  '{machine:$m, endpoint:$e, port:47823}' > "$SN_DIR/config.json"

SETTINGS="$HOME/.claude/settings.json"
[ -f "$SETTINGS" ] || echo '{}' > "$SETTINGS"
cp "$SETTINGS" "$SETTINGS.sessionnotch.bak"

hook() { printf '{"matcher":"","hooks":[{"type":"command","command":"%s"}]}' "$1"; }
NOTIFY=$(hook "$HOOKS_DIR/sessionnotch-notify.sh")
STOP=$(hook "$HOOKS_DIR/sessionnotch-stop.sh")
PROMPT=$(hook "$HOOKS_DIR/sessionnotch-prompt.sh")
END=$(hook "$HOOKS_DIR/sessionnotch-end.sh")

jq --argjson n "$NOTIFY" --argjson s "$STOP" --argjson p "$PROMPT" --argjson e "$END" '
  .hooks.Notification = ((.hooks.Notification // []) + [$n]) |
  .hooks.Stop = ((.hooks.Stop // []) + [$s]) |
  .hooks.UserPromptSubmit = ((.hooks.UserPromptSubmit // []) + [$p]) |
  .hooks.SessionEnd = ((.hooks.SessionEnd // []) + [$e])
' "$SETTINGS" > "$SETTINGS.tmp" && mv "$SETTINGS.tmp" "$SETTINGS"
echo "Installed hooks for machine '$MACHINE' -> $ENDPOINT (backup: $SETTINGS.sessionnotch.bak)"
```

Note: confirm the exact hook event names (`Notification`, `Stop`, `UserPromptSubmit`, `SessionEnd`) and payload fields against the installed Claude Code version's hooks docs before running; adjust the JSON shape if the schema differs. The `.bak` file makes this reversible.

- [ ] **Step 7: Commit**

```bash
git add hooks tests/hooks
git commit -m "feat: Claude Code hook scripts, install script, and hook tests"
```

---

## Task 9: Cross-machine install + manual end-to-end

No new code — this task installs and verifies the real thing on both machines, then finalizes docs.

**Files:**
- Modify: `README.md` (full install + usage)
- Modify: `PROJECT.json` (`completed` / `next`)

- [ ] **Step 1: Build the release app on the laptop**

Run: `bash scripts/make-app.sh release && open build/SessionNotch.app`
Confirm it launches (menu-bar `SN`), and note the Tailscale IP printed in Console (`log stream --predicate 'process == "SessionNotch"'`) or via `NSLog`.

- [ ] **Step 2: Install hooks on the laptop**

Run (loopback endpoint):
```bash
bash hooks/install-hooks.sh laptop "http://127.0.0.1:47823/event"
```

- [ ] **Step 3: Install hooks on the Studio**

Determine the laptop's MagicDNS name (`tailscale status` on the laptop, or use the CGNAT IP). On the Studio:
```bash
bash ~/Agent/SessionNotch/hooks/install-hooks.sh studio "http://<laptop-magicdns-or-100.x-ip>:47823/event"
```
Copy the laptop's secret to the Studio so the header matches:
```bash
# on the laptop: print length only, then copy the value out-of-band into the Studio file
install -m 600 /dev/null ~/.sessionnotch/secret   # run on Studio, then paste the value
```
The two machines must share the **same** `~/.sessionnotch/secret`.

- [ ] **Step 4: Verify laptop → app**

In a laptop Claude Code session, trigger a permission prompt (e.g. run a command needing approval). Expected: notch drops with `laptop - <project>`, banner fires, menu-bar count increments; replying clears it.

- [ ] **Step 5: Verify Studio → app over tailnet**

In a Studio Claude Code session (your normal Remote-SSH workflow), trigger a permission prompt. Expected: within ~1s the laptop notch shows `studio - <project>`. If nothing appears, check: `tailscale ping <laptop>` from the Studio, `curl` the `/health` endpoint from the Studio, and that both secrets match.

- [ ] **Step 6: Finalize docs**

Write `README.md` covering: what it is, build (`scripts/make-app.sh`), per-machine install (`install-hooks.sh`), the shared-secret requirement, the `47823` port, and the v1 limitation (no crash-wrapper, no jump-to-terminal). Update `PROJECT.json`: move the build item to `completed`, set `next` to `["Add login-item autostart", "v2: claude wrapper for true crash detection", "v2: jump-to-VS-Code-window"]`, bump `updatedAt`.

- [ ] **Step 7: Commit and open the finish-branch flow**

```bash
git add README.md PROJECT.json
git commit -m "docs: install + usage; mark v1 build complete"
```
Then use the `superpowers:finishing-a-development-branch` skill to decide merge vs PR.

---

## Self-Review

**Spec coverage:**
- Push-over-tailnet architecture → Tasks 5, 6, 8, 9. ✓
- Four triggers (permission/idle/done/error) → EventKind (Task 1), registry states (Task 2), hook classification (Task 8). ✓
- Both machines → per-machine config + install (Task 8/9), keyed registry (Task 2). ✓
- Notch UI + banners → Tasks 6 (banners, baseline) + 7 (notch). ✓
- Secret-authed server, interface binding, health route → Task 5. ✓
- Fallback state file — **partial gap:** the spec mentions a per-machine fallback state file for re-sync; v1 as planned is fire-and-forget only. Resolution: this is a deliberate deferral (a re-started app simply re-populates as new events arrive within the stale window). Noted here rather than adding a task; add to `PROJECT.json` `next` if desired.
- SessionEnd-only error detection, crash-wrapper deferred → Task 8 classification + README note. ✓
- Config/secret discipline → Task 4 + `.gitignore` (already present). ✓

**Placeholder scan:** No TBD/TODO in steps; all code blocks are concrete. The only "adjust to the resolved API" notes are on DynamicNotchKit (external, version-dependent) and Claude Code hook schema names — both isolated behind a protocol / a `.bak`-backed install with explicit verification steps.

**Type consistency:** `Event`/`EventKind` fields and wire keys match across Tasks 1, 5, 8. `Session`/`SessionState`/`needsAttention` consistent across Tasks 2, 6, 7. `RegistryStore.sessions` (published) consumed identically by `SessionListView`, `StatusItemController`, `NotchPresenter`. `EventServer` init signature matches its use in Task 6.
