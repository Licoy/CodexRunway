import Foundation
import Network

/// Minimal localhost HTTP listener that captures a single OAuth redirect.
public final class OAuthCallbackServer: @unchecked Sendable {
    public enum ServerError: Error {
        case portInUse
        case timedOut
        case cancelled
        case failed(String)
    }

    private let port: UInt16
    private var listener: NWListener?
    private var continuation: CheckedContinuation<URL, Error>?
    private let lock = NSLock()

    public init(port: UInt16 = CodexOAuthLogin.preferredCallbackPort) {
        self.port = port
    }

    public func waitForCallback(timeout: TimeInterval = 300) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            self.lock.lock()
            self.continuation = continuation
            self.lock.unlock()
            do {
                try start()
            } catch {
                finish(.failure(error))
                return
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in
                self?.finish(.failure(ServerError.timedOut))
            }
        }
    }

    public func cancel() {
        finish(.failure(ServerError.cancelled))
    }

    private func start() throws {
        let parameters = NWParameters.tcp
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw ServerError.failed("invalid port")
        }
        let listener: NWListener
        do {
            listener = try NWListener(using: parameters, on: nwPort)
        } catch {
            throw ServerError.portInUse
        }
        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection)
        }
        listener.stateUpdateHandler = { [weak self] state in
            if case .failed(let error) = state {
                self?.finish(.failure(ServerError.failed(error.localizedDescription)))
            }
        }
        listener.start(queue: .global())
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: .global())
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, _, error in
            defer { connection.cancel() }
            if let error {
                self?.finish(.failure(ServerError.failed(error.localizedDescription)))
                return
            }
            guard let data, let request = String(data: data, encoding: .utf8) else {
                self?.finish(.failure(ServerError.failed("empty request")))
                return
            }
            let pathLine = request.split(separator: "\r\n", maxSplits: 1).first
                ?? request.split(separator: "\n", maxSplits: 1).first
            guard let pathLine else {
                self?.finish(.failure(ServerError.failed("bad request")))
                return
            }
            // GET /auth/callback?... HTTP/1.1
            let parts = pathLine.split(separator: " ")
            guard parts.count >= 2 else {
                self?.finish(.failure(ServerError.failed("bad request line")))
                return
            }
            let target = String(parts[1])
            let urlString = "http://localhost:\(self?.port ?? 1455)\(target)"
            guard let url = URL(string: urlString) else {
                self?.finish(.failure(ServerError.failed("bad callback url")))
                return
            }
            let body = """
            <!doctype html><html><body style="font-family:system-ui;padding:2rem">
            <h2>Sign-in complete</h2>
            <p>You can close this window and return to CodexRunway.</p>
            </body></html>
            """
            let response = """
            HTTP/1.1 200 OK\r
            Content-Type: text/html; charset=utf-8\r
            Content-Length: \(body.utf8.count)\r
            Connection: close\r
            \r
            \(body)
            """
            let server = self
            connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in
                server?.finish(.success(url))
            })
        }
    }

    private func finish(_ result: Result<URL, Error>) {
        lock.lock()
        let cont = continuation
        continuation = nil
        lock.unlock()
        listener?.cancel()
        listener = nil
        cont?.resume(with: result)
    }
}
