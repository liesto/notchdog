import Foundation
@testable import SessionNotchCore

private let eventServerTestPort: UInt16 = 47899 // test port, not the app's 47823

private func postToTestServer(_ path: String, body: Data, secret: String?) async throws -> Int {
    var req = URLRequest(url: URL(string: "http://127.0.0.1:\(eventServerTestPort)\(path)")!)
    req.httpMethod = "POST"
    req.httpBody = body
    if let secret { req.setValue(secret, forHTTPHeaderField: "X-SessionNotch-Secret") }
    let (_, resp) = try await URLSession.shared.data(for: req)
    guard let http = resp as? HTTPURLResponse else {
        throw ExpectationError(description: "response was not HTTPURLResponse")
    }
    return http.statusCode
}

func registerEventServerTests(_ runner: TestRunner) async {
    await runner.test("EventServer.validEventIsDelivered") {
        final class Box: @unchecked Sendable {
            private var continuation: CheckedContinuation<Event, Error>?
            private let lock = NSLock()

            func store(_ cont: CheckedContinuation<Event, Error>) {
                lock.lock(); continuation = cont; lock.unlock()
            }

            func takeContinuation() -> CheckedContinuation<Event, Error>? {
                lock.lock()
                defer { lock.unlock() }
                let c = continuation
                continuation = nil
                return c
            }
        }
        let box = Box()
        let server = EventServer(port: eventServerTestPort, secret: "k") { e in
            box.takeContinuation()?.resume(returning: e)
        }
        try server.start(host: "127.0.0.1")
        defer { server.stop() }

        let received: Event = try await withCheckedThrowingContinuation { cont in
            box.store(cont)
            Task {
                do {
                    let body = try Event.encoder.encode(
                        Event(machine: "laptop", sessionID: "s1", project: "p", cwd: "/tmp",
                              kind: .idle, message: "hi", ts: Date(timeIntervalSince1970: 1)))
                    let code = try await postToTestServer("/event", body: body, secret: "k")
                    if code != 204 {
                        box.takeContinuation()?.resume(
                            throwing: ExpectationError(description: "expected 204, got \(code)"))
                    }
                } catch {
                    box.takeContinuation()?.resume(throwing: error)
                }
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
        var req = URLRequest(url: URL(string: "http://127.0.0.1:\(eventServerTestPort)/health")!)
        req.httpMethod = "GET"
        let (_, resp) = try await URLSession.shared.data(for: req)
        let http = resp as! HTTPURLResponse
        try expectEqual(http.statusCode, 200)
    }

    await runner.test("EventServer.unknownPathIs404") {
        let server = EventServer(port: eventServerTestPort, secret: "k") { _ in }
        try server.start(host: "127.0.0.1")
        defer { server.stop() }
        var req = URLRequest(url: URL(string: "http://127.0.0.1:\(eventServerTestPort)/nope")!)
        req.httpMethod = "GET"
        let (_, resp) = try await URLSession.shared.data(for: req)
        let http = resp as! HTTPURLResponse
        try expectEqual(http.statusCode, 404)
    }
}
