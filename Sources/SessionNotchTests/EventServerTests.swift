import Foundation
@testable import SessionNotchCore

private let eventServerTestPort: UInt16 = 47899 // test port, not the app's 47823
private let eventServerHostNilTestPort: UInt16 = 47900 // distinct port for the host:nil test

private func postToTestServer(_ path: String, body: Data, secret: String?,
                               port: UInt16 = eventServerTestPort) async throws -> Int {
    var req = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!)
    req.httpMethod = "POST"
    req.httpBody = body
    if let secret { req.setValue(secret, forHTTPHeaderField: "X-SessionNotch-Secret") }
    let (_, resp) = try await URLSession.shared.data(for: req)
    guard let http = resp as? HTTPURLResponse else {
        throw ExpectationError(description: "response was not HTTPURLResponse")
    }
    return http.statusCode
}

private func getFromTestServer(_ path: String, secret: String?,
                                port: UInt16 = eventServerTestPort) async throws -> Int {
    var req = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!)
    req.httpMethod = "GET"
    if let secret { req.setValue(secret, forHTTPHeaderField: "X-SessionNotch-Secret") }
    let (_, resp) = try await URLSession.shared.data(for: req)
    guard let http = resp as? HTTPURLResponse else {
        throw ExpectationError(description: "response was not HTTPURLResponse")
    }
    return http.statusCode
}

/// Races event delivery (via `start`'s callback) against a bounded timeout, so a future
/// regression that never calls `onEvent` fails the test cleanly instead of hanging the whole
/// test binary forever.
///
/// Deliberately NOT implemented with `withThrowingTaskGroup` + a sibling `Task.sleep` task:
/// if delivery never happens, the group still has to await the orphaned
/// `withCheckedThrowingContinuation` child task, which never resumes — so the whole test binary
/// hangs (Swift reports "SWIFT TASK CONTINUATION MISUSE"). That only helps when delivery is
/// slow, not when it never happens, which is the exact regression this guards against. Instead,
/// a single continuation is resumed at most once by whichever of the delivery callback or the
/// `DispatchQueue.asyncAfter` timer fires first; the loser of the race is dropped harmlessly.
private func awaitDelivery(timeout: TimeInterval = 3,
                            start: (@escaping (Event) -> Void) -> Void) async throws -> Event {
    final class Box { var resumed = false; let lock = NSLock() }
    let box = Box()
    return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Event, Error>) in
        func finish(_ result: Result<Event, Error>) {
            box.lock.lock(); defer { box.lock.unlock() }
            guard !box.resumed else { return }
            box.resumed = true
            cont.resume(with: result)
        }
        start { finish(.success($0)) }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
            finish(.failure(ExpectationError(description: "timed out waiting for event delivery")))
        }
    }
}

func registerEventServerTests(_ runner: TestRunner) async {
    await runner.test("EventServer.awaitDeliveryTimesOut") {
        var threw = false
        do { _ = try await awaitDelivery(timeout: 1) { _ in /* never fires */ } }
        catch { threw = true }
        try expect(threw, "awaitDelivery must throw when delivery never happens")
    }

    await runner.test("EventServer.validEventIsDelivered") {
        final class Box: @unchecked Sendable {
            private var deliver: ((Event) -> Void)?
            private let lock = NSLock()

            func store(_ deliver: @escaping (Event) -> Void) {
                lock.lock(); self.deliver = deliver; lock.unlock()
            }

            func take() -> ((Event) -> Void)? {
                lock.lock()
                defer { lock.unlock() }
                let d = deliver
                deliver = nil
                return d
            }
        }
        let box = Box()
        let server = EventServer(port: eventServerTestPort, secret: "k") { e in
            box.take()?(e)
        }
        try server.start(host: "127.0.0.1")
        defer { server.stop() }

        let received = try await awaitDelivery { deliver in
            box.store(deliver)
            Task {
                let body = try! Event.encoder.encode(
                    Event(machine: "laptop", sessionID: "s1", project: "p", cwd: "/tmp",
                          kind: .idle, message: "hi", ts: Date(timeIntervalSince1970: 1)))
                _ = try? await postToTestServer("/event", body: body, secret: "k")
            }
        }
        try expectEqual(received.sessionID, "s1")
    }

    await runner.test("EventServer.wrongSecretRejected") {
        let server = EventServer(port: eventServerTestPort, secret: "k") { _ in }
        try server.start(host: "127.0.0.1")
        defer { server.stop() }
        let code = try await postToTestServer("/event", body: Data("{}".utf8), secret: "wrong")
        try expectEqual(code, 401)
    }

    await runner.test("EventServer.health") {
        let server = EventServer(port: eventServerTestPort, secret: "k") { _ in }
        try server.start(host: "127.0.0.1")
        defer { server.stop() }
        let code = try await getFromTestServer("/health", secret: nil)
        try expectEqual(code, 200)
    }

    await runner.test("EventServer.unknownPathIs404") {
        let server = EventServer(port: eventServerTestPort, secret: "k") { _ in }
        try server.start(host: "127.0.0.1")
        defer { server.stop() }
        let code = try await getFromTestServer("/nope", secret: nil)
        try expectEqual(code, 404)
    }

    await runner.test("EventServer.getEventReturns404") {
        let server = EventServer(port: eventServerTestPort, secret: "k") { _ in }
        try server.start(host: "127.0.0.1")
        defer { server.stop() }
        let code = try await getFromTestServer("/event", secret: "k")
        try expectEqual(code, 404)
    }

    await runner.test("EventServer.undecodableBodyReturns400") {
        let server = EventServer(port: eventServerTestPort, secret: "k") { _ in }
        try server.start(host: "127.0.0.1")
        defer { server.stop() }
        let code = try await postToTestServer("/event", body: Data("not json".utf8), secret: "k")
        try expectEqual(code, 400)
    }

    await runner.test("EventServer.bindsAllInterfacesWhenHostNil") {
        final class Box: @unchecked Sendable {
            private var deliver: ((Event) -> Void)?
            private let lock = NSLock()

            func store(_ deliver: @escaping (Event) -> Void) {
                lock.lock(); self.deliver = deliver; lock.unlock()
            }

            func take() -> ((Event) -> Void)? {
                lock.lock()
                defer { lock.unlock() }
                let d = deliver
                deliver = nil
                return d
            }
        }
        let box = Box()
        let server = EventServer(port: eventServerHostNilTestPort, secret: "k") { e in
            box.take()?(e)
        }
        try server.start(host: nil)
        defer { server.stop() }

        let received = try await awaitDelivery { deliver in
            box.store(deliver)
            Task {
                let body = try! Event.encoder.encode(
                    Event(machine: "laptop", sessionID: "s2", project: "p", cwd: "/tmp",
                          kind: .idle, message: "hi", ts: Date(timeIntervalSince1970: 1)))
                _ = try? await postToTestServer("/event", body: body, secret: "k",
                                                 port: eventServerHostNilTestPort)
            }
        }
        try expectEqual(received.sessionID, "s2")
    }
}
