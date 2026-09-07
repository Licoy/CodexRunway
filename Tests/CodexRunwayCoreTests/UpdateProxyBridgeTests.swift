import Foundation
import Testing
@testable import CodexRunwayCore

@Suite("Update proxy streaming bridge", .serialized)
@MainActor
struct UpdateProxyBridgeTests {
    @Test("raw signed feed and archive bytes survive the bridge, including chunked bodies")
    func preservesBytesAndEndsCycle() async throws {
        let bridge = makeBridge()
        try await bridge.start()
        defer { bridge.stop() }
        let context = try RunwayNetworkContext()
        let feed = try bridge.beginCycle(context: context, appcastURL: upstream("feed"))
        let session = localSession()
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: feed)
        request.setValue("Bearer local-test-only", forHTTPHeaderField: "Authorization")
        let (feedData, response) = try await session.data(for: request)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        #expect(feedData == UpdateBridgeURLProtocol.feed)
        #expect(UpdateBridgeURLProtocol.observed.sawAuthorization == false)
        let archive = try bridge.register(upstream("archive.zip"))
        let (archiveData, archiveResponse) = try await session.data(from: archive)
        #expect(archiveData == UpdateBridgeURLProtocol.archive)
        #expect(archiveResponse.suggestedFilename == "archive.zip")
        bridge.endCycle()
        let (_, endedResponse) = try await session.data(from: feed)
        #expect((endedResponse as? HTTPURLResponse)?.statusCode == 404)
    }

    @Test("truncated upstream data fails instead of completing a partial download")
    func rejectsTruncatedDownload() async throws {
        let bridge = makeBridge()
        try await bridge.start()
        defer { bridge.stop() }
        let context = try RunwayNetworkContext()
        _ = try bridge.beginCycle(context: context, appcastURL: upstream("feed"))
        let archive = try bridge.register(upstream("truncated"))
        let session = localSession()
        defer { session.invalidateAndCancel() }
        do {
            let (_, response) = try await session.data(from: archive)
            #expect(((response as? HTTPURLResponse)?.statusCode ?? 0) >= 400)
        } catch {
            // Once response headers are sent, closing a truncated body must fail the download.
            #expect(error is URLError)
        }
    }

    @Test("cancelling the local downloader cancels the in-flight upstream request")
    func cancelsUpstream() async throws {
        let bridge = makeBridge()
        try await bridge.start()
        defer { bridge.stop() }
        let context = try RunwayNetworkContext()
        _ = try bridge.beginCycle(context: context, appcastURL: upstream("feed"))
        let archive = try bridge.register(upstream("slow"))
        let session = localSession()
        defer { session.invalidateAndCancel() }
        let download = Task { try await session.data(from: archive) }
        for _ in 0..<100 where !UpdateBridgeURLProtocol.observed.startedSlow {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(UpdateBridgeURLProtocol.observed.startedSlow)
        download.cancel()
        _ = await download.result
        for _ in 0..<100 where !UpdateBridgeURLProtocol.observed.stoppedSlow {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(UpdateBridgeURLProtocol.observed.stoppedSlow)
    }

    @Test("encoded HTTP bodies use chunked framing rather than the encoded Content-Length")
    func decodedLength() {
        let response = HTTPURLResponse(url: upstream("feed"), statusCode: 200, httpVersion: nil, headerFields: [
            "Content-Length": "15", "Content-Encoding": "gzip",
        ])!
        #expect(UpdateProxyConnection.contentLength(response) == nil)
        let header = String(decoding: UpdateProxyConnection.responseHeader(status: 200, length: nil), as: UTF8.self)
        #expect(header.contains("Transfer-Encoding: chunked"))
        #expect(!header.contains("Content-Length"))
    }

    @Test("proxy authentication failure is retained as a safe UI error and reset next cycle")
    func safeAuthenticationError() async throws {
        let bridge = makeBridge()
        try await bridge.start()
        defer { bridge.stop() }
        let context = try RunwayNetworkContext()
        let local = try bridge.beginCycle(context: context, appcastURL: upstream("authentication"))
        let session = localSession()
        defer { session.invalidateAndCancel() }
        let (_, response) = try await session.data(from: local)
        #expect((response as? HTTPURLResponse)?.statusCode == 502)
        #expect(bridge.lastError == .authenticationFailed)
        bridge.endCycle()
        #expect(bridge.lastError == .authenticationFailed)
        _ = try bridge.beginCycle(context: context, appcastURL: upstream("feed"))
        #expect(bridge.lastError == nil)
    }

    private func makeBridge() -> UpdateProxyBridge {
        UpdateBridgeURLProtocol.observed.reset()
        return UpdateProxyBridge { _, delegate in
            let configuration = URLSessionConfiguration.ephemeral
            configuration.urlCredentialStorage = nil
            configuration.protocolClasses = [UpdateBridgeURLProtocol.self]
            return URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        }
    }

    private func upstream(_ name: String) -> URL {
        URL(string: "https://github.com/Licoy/CodexRunway/releases/download/test/\(name)")!
    }

    private func localSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForRequest = 3
        configuration.timeoutIntervalForResource = 5
        return URLSession(configuration: configuration)
    }
}

private final class UpdateBridgeURLProtocol: URLProtocol {
    static let feed = Data("<!-- signed feed bytes must stay exact -->\n<rss>原始字节\r\n</rss>".utf8)
    static let archive = Data((0..<262_144).map { UInt8(truncatingIfNeeded: $0) })
    static let observed = Observation()

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "github.com" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        let name = url.lastPathComponent
        Self.observed.record(authorization: request.value(forHTTPHeaderField: "Authorization") != nil, slow: name == "slow")
        let body = name == "archive.zip" ? Self.archive : Self.feed
        var headers: [String: String] = [:]
        if name != "archive.zip" { headers["Content-Length"] = String(name == "truncated" || name == "slow" ? 999_999 : body.count) }
        let response = HTTPURLResponse(url: url, statusCode: name == "authentication" ? 407 : 200, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if name == "slow" { return }
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {
        if request.url?.lastPathComponent == "slow" { Self.observed.stop() }
    }

    final class Observation: @unchecked Sendable {
        private let lock = NSLock()
        private var authorization = false
        private var started = false
        private var stopped = false
        var sawAuthorization: Bool { lock.withLock { authorization } }
        var startedSlow: Bool { lock.withLock { started } }
        var stoppedSlow: Bool { lock.withLock { stopped } }
        func reset() { lock.withLock { authorization = false; started = false; stopped = false } }
        func record(authorization: Bool, slow: Bool) { lock.withLock { self.authorization = authorization; started = slow } }
        func stop() { lock.withLock { stopped = true } }
    }
}
