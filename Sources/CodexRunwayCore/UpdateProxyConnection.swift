import Foundation
import Network

@MainActor
struct UpdateProxyResource {
    let url: URL
    let context: RunwayNetworkContext
    let report: (NetworkProxyError?) -> Void
}

@MainActor
final class UpdateProxyConnection {
    private let connection: NWConnection
    private let sessionFactory: UpdateProxyBridge.SessionFactory
    private let resolve: (Data) -> UpdateProxyResource?
    private let onFinish: () -> Void
    private var task: Task<Void, Never>?
    private var session: URLSession?
    private var disconnect: Task<Void, Never>?
    private var sentHeaders = false
    private var finished = false

    init(
        connection: NWConnection,
        sessionFactory: @escaping UpdateProxyBridge.SessionFactory,
        resolve: @escaping (Data) -> UpdateProxyResource?,
        onFinish: @escaping () -> Void)
    {
        self.connection = connection
        self.sessionFactory = sessionFactory
        self.resolve = resolve
        self.onFinish = onFinish
    }

    func start(queue: DispatchQueue) {
        connection.stateUpdateHandler = { [weak self] state in
            if case .failed = state { Task { @MainActor in self?.cancel() } }
        }
        connection.start(queue: queue)
        task = Task { await run() }
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            guard let self, self.session == nil else { return }
            self.cancel()
        }
    }

    func cancel() {
        task?.cancel()
        finish()
    }

    private func run() async {
        defer { finish() }
        var active: UpdateProxyResource?
        var authentication: UpdateProxySessionDelegate?
        do {
            let rawRequest = try await readRequest()
            guard let resource = resolve(rawRequest) else {
                try await send(Data("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8))
                return
            }
            active = resource
            let delegate = UpdateProxySessionDelegate(context: resource.context)
            authentication = delegate
            let session = sessionFactory(resource.context, delegate)
            self.session = session
            watchDisconnect()
            var request = URLRequest(url: resource.url)
            request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
            let (bytes, response) = try await session.bytes(for: request)
            if (response as? HTTPURLResponse)?.statusCode == 407 { throw NetworkProxyError.authenticationFailed }
            guard let response = response as? HTTPURLResponse, [200, 206].contains(response.statusCode) else {
                throw UpdateProxyBridgeError.invalidResponse
            }
            let length = Self.contentLength(response)
            try await send(Self.responseHeader(status: response.statusCode, length: length, filename: resource.url.lastPathComponent))
            sentHeaders = true
            try await stream(bytes, length: length)
            resource.report(nil)
        } catch {
            if !Task.isCancelled, let active {
                active.report(authentication?.failure ?? (active.context.mappedError(error) as? NetworkProxyError) ?? .connectionFailed)
            }
            if !sentHeaders && !Task.isCancelled {
                // No upstream URL, redirect signature, or credential is returned to the local client.
                try? await send(Data("HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8))
            }
        }
    }

    private func readRequest() async throws -> Data {
        var request = Data()
        while request.range(of: Data("\r\n\r\n".utf8)) == nil {
            let (data, complete) = try await receive(maximum: 4_096)
            if let data { request.append(data) }
            guard request.count <= 16_384 else { throw UpdateProxyBridgeError.invalidRequest }
            if complete { throw UpdateProxyBridgeError.connectionClosed }
        }
        return request
    }

    private func watchDisconnect() {
        disconnect = Task { [weak self] in
            guard let self else { return }
            do { _ = try await receive(maximum: 1) } catch {
                if !Task.isCancelled { cancel() }
                return
            }
            if !Task.isCancelled { cancel() }
        }
    }

    // Consume bytes on the generic executor; only complete chunks need the connection's actor.
    nonisolated private func stream(_ bytes: URLSession.AsyncBytes, length: Int64?) async throws {
        var chunk = Data()
        chunk.reserveCapacity(65_536)
        var total: Int64 = 0
        for try await byte in bytes {
            chunk.append(byte)
            total += 1
            if let length, total > length { throw UpdateProxyBridgeError.invalidResponse }
            if chunk.count == 65_536 {
                try await sendChunk(chunk, task: bytes.task, chunked: length == nil)
                chunk.removeAll(keepingCapacity: true)
            }
        }
        if let length, total != length { throw UpdateProxyBridgeError.invalidResponse }
        if !chunk.isEmpty { try await sendChunk(chunk, task: bytes.task, chunked: length == nil) }
        if length == nil { try await send(Data("0\r\n\r\n".utf8)) }
    }

    private func sendChunk(_ chunk: Data, task: URLSessionDataTask, chunked: Bool) async throws {
        // Bound application buffering and pause the upstream while the local downloader catches up.
        task.suspend()
        defer { task.resume() }
        if chunked {
            var framed = Data("\(String(chunk.count, radix: 16))\r\n".utf8)
            framed.append(chunk)
            framed.append(Data("\r\n".utf8))
            try await send(framed)
        } else {
            try await send(chunk)
        }
    }

    private func receive(maximum: Int) async throws -> (Data?, Bool) {
        try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: maximum) { data, _, complete, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: (data, complete)) }
            }
        }
    }

    private func send(_ data: Data) async throws {
        try Task.checkCancellation()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            })
        }
    }

    private func finish() {
        guard !finished else { return }
        finished = true
        disconnect?.cancel()
        disconnect = nil
        session?.invalidateAndCancel()
        session = nil
        connection.cancel()
        task = nil
        onFinish()
    }

    static func contentLength(_ response: HTTPURLResponse) -> Int64? {
        guard response.value(forHTTPHeaderField: "Content-Encoding").map({ $0.lowercased() == "identity" }) ?? true,
              let header = response.value(forHTTPHeaderField: "Content-Length"),
              let length = Int64(header), length >= 0
        else { return nil }
        return length
    }

    static func responseHeader(status: Int, length: Int64?, filename: String? = nil) -> Data {
        let framing = length.map { "Content-Length: \($0)" } ?? "Transfer-Encoding: chunked"
        let disposition = filename.map { "Content-Disposition: attachment; filename=\"\(safeFilename($0))\"\r\n" } ?? ""
        return Data("HTTP/1.1 \(status) OK\r\nContent-Type: application/octet-stream\r\n\(framing)\r\n\(disposition)Connection: close\r\nCache-Control: no-store\r\n\r\n".utf8)
    }

    private static func safeFilename(_ filename: String) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-".utf8)
        let sanitized = String(decoding: filename.utf8.filter { allowed.contains($0) }, as: UTF8.self)
        return sanitized.isEmpty || sanitized == "." || sanitized == ".." ? "update" : sanitized
    }
}

private final class UpdateProxySessionDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let context: RunwayNetworkContext
    private let lock = NSLock()
    private var storedFailure: NetworkProxyError?
    var failure: NetworkProxyError? { lock.withLock { storedFailure } }

    init(context: RunwayNetworkContext) { self.context = context }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void)
    {
        guard let url = request.url, UpdateProxyRoutes.isAllowedRedirect(url) else {
            lock.withLock { storedFailure = .invalidUpdateURL }
            completionHandler(nil)
            return
        }
        var forwarded = URLRequest(url: url)
        forwarded.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        completionHandler(forwarded)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void)
    {
        let response = context.authenticationResponse(for: challenge)
        if response.0 == .cancelAuthenticationChallenge, challenge.protectionSpace.isProxy() {
            lock.withLock { storedFailure = .authenticationFailed }
        }
        completionHandler(response.0, response.1)
    }
}
