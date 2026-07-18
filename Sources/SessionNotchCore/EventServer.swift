import Foundation
import Network

public final class EventServer {
    private let port: NWEndpoint.Port
    private let secret: String
    private let onEvent: (Event) -> Void
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "sessionnotch.server")

    /// Set transiently by `start()`/`stop()` while they synchronously wait for a
    /// specific `NWListener.State` transition; cleared once observed.
    private var pendingStateHandler: ((NWListener.State) -> Void)?
    private let stateLock = NSLock()

    public private(set) var boundPort: UInt16?

    public enum StartError: Error { case timedOut }

    public init(port: UInt16, secret: String, onEvent: @escaping (Event) -> Void) {
        self.port = NWEndpoint.Port(rawValue: port)!
        self.secret = secret
        self.onEvent = onEvent
    }

    public func start(host: String?) throws {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        let listener: NWListener
        if let host {
            params.requiredLocalEndpoint = NWEndpoint.hostPort(host: .init(host), port: port)
            listener = try NWListener(using: params)
        } else {
            listener = try NWListener(using: params, on: port)
        }
        listener.newConnectionHandler = { [weak self] conn in self?.handle(conn) }
        listener.stateUpdateHandler = { [weak self] state in self?.dispatchStateChange(state) }

        // NWListener.start(queue:) is asynchronous; wait for `.ready` so that by the
        // time `start(host:)` returns, the socket is actually bound and listening.
        let readySemaphore = DispatchSemaphore(value: 0)
        var startError: Error?
        setPendingStateHandler { state in
            switch state {
            case .ready:
                readySemaphore.signal()
            case .failed(let error):
                // `.waiting` is transient (e.g. address briefly unavailable) and may
                // still recover to `.ready`; only `.failed` is a terminal error here.
                startError = error
                readySemaphore.signal()
            default:
                break
            }
        }
        listener.start(queue: queue)
        let waitResult = readySemaphore.wait(timeout: .now() + 5)
        clearPendingStateHandler()

        if let startError {
            throw startError
        }
        if waitResult == .timedOut {
            listener.cancel()
            throw StartError.timedOut
        }

        self.listener = listener
        self.boundPort = port.rawValue
    }

    public func stop() {
        guard let listener else { return }
        self.listener = nil
        self.boundPort = nil

        // Wait for the listener to fully release the port before returning, so a
        // subsequent `start()` on the same port doesn't race an "address in use" error.
        let cancelledSemaphore = DispatchSemaphore(value: 0)
        setPendingStateHandler { state in
            if case .cancelled = state { cancelledSemaphore.signal() }
        }
        listener.cancel()
        _ = cancelledSemaphore.wait(timeout: .now() + 2)
        clearPendingStateHandler()
    }

    private func setPendingStateHandler(_ handler: @escaping (NWListener.State) -> Void) {
        stateLock.lock()
        pendingStateHandler = handler
        stateLock.unlock()
    }

    private func clearPendingStateHandler() {
        stateLock.lock()
        pendingStateHandler = nil
        stateLock.unlock()
    }

    private func dispatchStateChange(_ state: NWListener.State) {
        stateLock.lock()
        let handler = pendingStateHandler
        stateLock.unlock()
        handler?(state)
    }

    /// Max time a connection may sit open without completing a request. Guards against a
    /// client opening a socket and never sending/finishing a request, which would otherwise
    /// leak the connection forever.
    private static let connectionIdleTimeout: TimeInterval = 15
    /// Max bytes buffered per connection while waiting for a complete request. Guards against
    /// an unbounded body (or a client that never terminates headers) growing memory forever.
    private static let maxRequestBytes = 1 << 20 // 1 MiB

    private func handle(_ conn: NWConnection) {
        conn.start(queue: queue)
        // Cancelling an already-finished/closed connection is a safe no-op, so an unconditional
        // cancel after the idle timeout is enough to bound a stuck/slow-loris-style client.
        queue.asyncAfter(deadline: .now() + Self.connectionIdleTimeout) { [weak conn] in
            conn?.cancel()
        }
        receive(conn, buffer: Data())
    }

    private func receive(_ conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, done, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let result = try? HTTPRequest.parse(buffer) {
                self.respond(conn, to: result.request)
                return
            }
            if error != nil || done {
                conn.cancel()
                return
            }
            if buffer.count > Self.maxRequestBytes {
                conn.cancel()
                return
            }
            self.receive(conn, buffer: buffer)
        }
    }

    private func respond(_ conn: NWConnection, to req: HTTPRequest) {
        let (status, reason): (Int, String)
        if req.method == "GET", req.path == "/health" {
            (status, reason) = (200, "OK")
        } else if !(req.method == "POST" && req.path == "/event") {
            (status, reason) = (404, "Not Found")
        } else if req.headers["x-sessionnotch-secret"] != secret {
            // Plain `!=` is not constant-time, but this is a conscious, acceptable tradeoff:
            // the server only ever runs behind a trusted tailnet, guarded by a 256-bit random
            // secret, so a timing side-channel isn't a meaningful attack surface here.
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
