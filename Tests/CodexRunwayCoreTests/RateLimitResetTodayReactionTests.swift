import Foundation
import Testing
@testable import CodexRunwayCore

@Suite("Rate limit reset today reaction", .serialized)
struct RateLimitResetTodayReactionTests {
    @Test("parses visitor IDs and rejects anything else")
    func parseVisitorID() {
        #expect(RateLimitResetTodayReaction.parseVisitorID("0ca75a14e041f05a5258f7924fa08914")
            == "0ca75a14e041f05a5258f7924fa08914")
        #expect(RateLimitResetTodayReaction.parseVisitorID("0CA75A14E041F05A5258F7924FA08914")
            == "0ca75a14e041f05a5258f7924fa08914")
        #expect(RateLimitResetTodayReaction.parseVisitorID("  abcdef0123456789abcdef0123456789  ")
            == "abcdef0123456789abcdef0123456789")
        #expect(RateLimitResetTodayReaction.parseVisitorID(nil) == nil)
        #expect(RateLimitResetTodayReaction.parseVisitorID("") == nil)
        #expect(RateLimitResetTodayReaction.parseVisitorID("not-a-visitor-id") == nil)
        #expect(RateLimitResetTodayReaction.parseVisitorID("0ca75a14e041f05a5258f7924fa0891") == nil)
        #expect(RateLimitResetTodayReaction.parseVisitorID("0ca75a14e041f05a5258f7924fa0891400") == nil)
        #expect(RateLimitResetTodayReaction.parseVisitorID("0ca75a14e041f05a5258f7924fa0891g") == nil)
    }

    @Test("decodes the live reaction envelope including unlimited remaining")
    func decodesLiveEnvelope() throws {
        let data = """
        {
          "ok": true,
          "data": {
            "enabled": true,
            "ready": true,
            "polarity": "no",
            "epochId": "f34540ec3645796726174653156e7fe7",
            "seed": 202,
            "count": 266,
            "remaining": null,
            "dailyLimit": 0,
            "pollMs": 5000
          }
        }
        """.data(using: .utf8)!

        let result = try RateLimitResetTodayReaction.decodeEnvelope(data)
        #expect(result.ok)
        #expect(result.error == nil)
        let snapshot = try #require(result.data)
        #expect(snapshot.enabled)
        #expect(snapshot.ready)
        #expect(snapshot.polarity == .no)
        #expect(snapshot.epochId == "f34540ec3645796726174653156e7fe7")
        #expect(snapshot.seed == 202)
        #expect(snapshot.count == 266)
        #expect(snapshot.remaining == nil)
        #expect(snapshot.dailyLimit == 0)
        #expect(snapshot.pollMs == 5_000)
        #expect(snapshot.isVisible)
        #expect(!snapshot.isExhausted)
    }

    @Test("dailyLimit 0 never exhausts remaining")
    func unlimitedNeverExhausts() {
        #expect(!RateLimitResetTodayReaction.isExhausted(remaining: 0, dailyLimit: 0))
        #expect(!RateLimitResetTodayReaction.isExhausted(remaining: nil, dailyLimit: 0))
        #expect(RateLimitResetTodayReaction.isExhausted(remaining: 0, dailyLimit: 5))
        #expect(!RateLimitResetTodayReaction.isExhausted(remaining: 1, dailyLimit: 5))
        #expect(!RateLimitResetTodayReaction.isExhausted(remaining: nil, dailyLimit: 5))
    }

    @Test("429 rollback keeps the previous count")
    func dailyLimitRollback() {
        let local = RateLimitResetTodayReactionLocal(
            epochId: "abc",
            previousCount: 10,
            previousRemaining: 1)
        let rolled = RateLimitResetTodayReaction.reconcileAfterPost(
            local: local,
            response: RateLimitResetTodayReactionPostResult(ok: false, error: "daily_limit"))
        #expect(rolled.count == 10)
        #expect(rolled.exhausted)
        #expect(rolled.epochId == "abc")

        let ok = RateLimitResetTodayReaction.reconcileAfterPost(
            local: local,
            response: RateLimitResetTodayReactionPostResult(
                ok: true,
                data: RateLimitResetTodayReactionSnapshot(
                    enabled: true,
                    ready: true,
                    polarity: .no,
                    epochId: "abc",
                    seed: 10,
                    count: 11,
                    remaining: 0,
                    dailyLimit: 2,
                    pollMs: 2_000)))
        #expect(ok.count == 11)
        #expect(ok.exhausted)
    }

    @Test("epoch change discards in-flight count")
    func epochChangeUsesNewPayload() {
        let local = RateLimitResetTodayReactionLocal(
            epochId: "old",
            previousCount: 140,
            previousRemaining: 3)
        let next = RateLimitResetTodayReaction.reconcileAfterPost(
            local: local,
            response: RateLimitResetTodayReactionPostResult(
                ok: true,
                data: RateLimitResetTodayReactionSnapshot(
                    enabled: true,
                    ready: true,
                    polarity: .yes,
                    epochId: "new",
                    seed: 100,
                    count: 100,
                    remaining: 3,
                    dailyLimit: 5,
                    pollMs: 2_000)))
        #expect(next.count == 100)
        #expect(next.epochId == "new")
        #expect(!next.exhausted)
    }

    @Test("positiveDelta only reports same-epoch increases")
    func positiveDelta() {
        #expect(RateLimitResetTodayReaction.positiveDelta(
            previousCount: 10, nextCount: 11, previousEpoch: "a", nextEpoch: "a") == 1)
        #expect(RateLimitResetTodayReaction.positiveDelta(
            previousCount: 10, nextCount: 15, previousEpoch: "a", nextEpoch: "a") == 5)
        #expect(RateLimitResetTodayReaction.positiveDelta(
            previousCount: 10, nextCount: 10, previousEpoch: "a", nextEpoch: "a") == 0)
        #expect(RateLimitResetTodayReaction.positiveDelta(
            previousCount: 10, nextCount: 9, previousEpoch: "a", nextEpoch: "a") == 0)
        #expect(RateLimitResetTodayReaction.positiveDelta(
            previousCount: 10, nextCount: 50, previousEpoch: "a", nextEpoch: "b") == 0)
        #expect(RateLimitResetTodayReaction.positiveDelta(
            previousCount: nil, nextCount: 11, previousEpoch: "a", nextEpoch: "a") == 0)
        #expect(RateLimitResetTodayReaction.positiveDelta(
            previousCount: 10, nextCount: 11, previousEpoch: nil, nextEpoch: "a") == 0)
        #expect(RateLimitResetTodayReaction.formatDelta(1, language: .english) == "+1")
        #expect(RateLimitResetTodayReaction.formatDelta(12, language: .english) == "+12")
        #expect(RateLimitResetTodayReaction.formatDelta(0, language: .english) == "")
    }

    @Test("POST request sends Origin, Referer, and the stored cookie")
    func postRequestHeaders() {
        let visitor = "abcdef0123456789abcdef0123456789"
        let request = RateLimitResetTodayReaction.makeRequest(method: "POST", visitorID: visitor)
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Origin") == RateLimitResetTodayReaction.origin)
        #expect(request.value(forHTTPHeaderField: "Referer") == RateLimitResetTodayReaction.referer)
        #expect(request.value(forHTTPHeaderField: "Cookie") == "hr_react=\(visitor)")
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
        #expect(request.httpShouldHandleCookies == false)
    }

    @Test("GET request omits Origin and does not invent a cookie")
    func getRequestOmitsOriginAndCookieWhenMissing() {
        let request = RateLimitResetTodayReaction.makeRequest(method: "GET", visitorID: nil)
        #expect(request.httpMethod == "GET")
        #expect(request.value(forHTTPHeaderField: "Origin") == nil)
        #expect(request.value(forHTTPHeaderField: "Referer") == nil)
        #expect(request.value(forHTTPHeaderField: "Cookie") == nil)
    }

    @Test("cookie store round-trips a valid ID and ignores junk")
    func cookieStoreRoundTrip() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-runway-reaction-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RateLimitResetTodayReactionCookieStore(
            fileURL: root.appendingPathComponent("reaction-visitor.json"))

        #expect(store.loadVisitorID() == nil)
        store.saveVisitorID("not-valid")
        #expect(store.loadVisitorID() == nil)
        #expect(!FileManager.default.fileExists(atPath: store.fileURL.path))

        let visitor = "abcdef0123456789abcdef0123456789"
        store.saveVisitorID(visitor)
        #expect(store.loadVisitorID() == visitor)
        let permissions = try #require(
            FileManager.default.attributesOfItem(atPath: store.fileURL.path)[.posixPermissions] as? NSNumber)
        #expect(permissions.intValue & 0o777 == 0o600)

        store.saveVisitorID("FFFF0000aaaa1111bbbb2222cccc3333")
        #expect(store.loadVisitorID() == "ffff0000aaaa1111bbbb2222cccc3333")
    }

    @Test("reads hr_react from Set-Cookie and persists it")
    func persistsSetCookie() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-runway-reaction-setcookie-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RateLimitResetTodayReactionCookieStore(
            fileURL: root.appendingPathComponent("reaction-visitor.json"))
        let visitor = "0ca75a14e041f05a5258f7924fa08914"
        let response = try #require(HTTPURLResponse(
            url: RateLimitResetTodayReaction.reactionURL,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: [
                "Set-Cookie": "hr_react=\(visitor); HttpOnly; Max-Age=31536000; Path=/; SameSite=lax; Secure",
            ]))
        store.saveVisitorID(from: response)
        #expect(store.loadVisitorID() == visitor)
    }

    @Test("fetch stores the minted cookie and reuses it on the next request")
    func fetchPersistsAndReusesCookie() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-runway-reaction-client-\(UUID().uuidString)", isDirectory: true)
        defer {
            MockReactionURLProtocol.reset()
            try? FileManager.default.removeItem(at: root)
        }
        let store = RateLimitResetTodayReactionCookieStore(
            fileURL: root.appendingPathComponent("reaction-visitor.json"))
        let visitor = "ac2a42c46b05a49956fc6f7ea0da262e"
        MockReactionURLProtocol.handler = { request in
            let cookie = request.value(forHTTPHeaderField: "Cookie")
            let minted = cookie == nil
            return MockReactionURLProtocol.Stub(
                status: 200,
                headers: minted
                    ? ["Set-Cookie": "hr_react=\(visitor); HttpOnly; Path=/; SameSite=lax; Secure"]
                    : [:],
                body: Self.okBody(count: minted ? 10 : 11))
        }
        let client = RateLimitResetTodayReactionClient(
            session: MockReactionURLProtocol.session(),
            cookieStore: store,
            devMockKind: nil)

        let first = try await client.fetch()
        #expect(first.count == 10)
        #expect(store.loadVisitorID() == visitor)

        let second = try await client.fetch()
        #expect(second.count == 11)
        let requests = MockReactionURLProtocol.requests
        #expect(requests.count == 2)
        #expect(requests[0].value(forHTTPHeaderField: "Cookie") == nil)
        #expect(requests[1].value(forHTTPHeaderField: "Cookie") == "hr_react=\(visitor)")
        #expect(requests[0].httpMethod == "GET")
        #expect(requests[0].value(forHTTPHeaderField: "Origin") == nil)
    }

    @Test("click sends Origin and Referer")
    func clickSendsSameOriginHeaders() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-runway-reaction-click-\(UUID().uuidString)", isDirectory: true)
        defer {
            MockReactionURLProtocol.reset()
            try? FileManager.default.removeItem(at: root)
        }
        let store = RateLimitResetTodayReactionCookieStore(
            fileURL: root.appendingPathComponent("reaction-visitor.json"))
        store.saveVisitorID("abcdef0123456789abcdef0123456789")
        MockReactionURLProtocol.handler = { _ in
            MockReactionURLProtocol.Stub(status: 200, headers: [:], body: Self.okBody(count: 12))
        }
        let client = RateLimitResetTodayReactionClient(
            session: MockReactionURLProtocol.session(),
            cookieStore: store,
            devMockKind: nil)

        let result = try await client.click()
        #expect(result.ok)
        #expect(result.data?.count == 12)
        let request = try #require(MockReactionURLProtocol.requests.last)
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Origin") == RateLimitResetTodayReaction.origin)
        #expect(request.value(forHTTPHeaderField: "Referer") == RateLimitResetTodayReaction.referer)
        #expect(request.value(forHTTPHeaderField: "Cookie") == "hr_react=abcdef0123456789abcdef0123456789")
    }

    @Test("GET 404 is disabled")
    func fetch404IsDisabled() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-runway-reaction-404-\(UUID().uuidString)", isDirectory: true)
        defer {
            MockReactionURLProtocol.reset()
            try? FileManager.default.removeItem(at: root)
        }
        MockReactionURLProtocol.handler = { _ in
            MockReactionURLProtocol.Stub(
                status: 404,
                headers: [:],
                body: Data(#"{"ok":false,"error":"disabled"}"#.utf8))
        }
        let client = RateLimitResetTodayReactionClient(
            session: MockReactionURLProtocol.session(),
            cookieStore: RateLimitResetTodayReactionCookieStore(
                fileURL: root.appendingPathComponent("reaction-visitor.json")),
            devMockKind: nil)
        await #expect(throws: RateLimitResetTodayReactionError.disabled) {
            _ = try await client.fetch()
        }
    }

    @Test("POST daily_limit returns the envelope without throwing")
    func clickDailyLimitDoesNotThrow() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-runway-reaction-429-\(UUID().uuidString)", isDirectory: true)
        defer {
            MockReactionURLProtocol.reset()
            try? FileManager.default.removeItem(at: root)
        }
        MockReactionURLProtocol.handler = { _ in
            MockReactionURLProtocol.Stub(
                status: 429,
                headers: [:],
                body: Data(#"""
                {"ok":false,"error":"daily_limit","data":{"enabled":true,"ready":true,"polarity":"no","epochId":"abc","seed":10,"count":12,"remaining":0,"dailyLimit":2,"pollMs":2000}}
                """#.utf8))
        }
        let client = RateLimitResetTodayReactionClient(
            session: MockReactionURLProtocol.session(),
            cookieStore: RateLimitResetTodayReactionCookieStore(
                fileURL: root.appendingPathComponent("reaction-visitor.json")),
            devMockKind: nil)
        let result = try await client.click()
        #expect(!result.ok)
        #expect(result.error == "daily_limit")
        #expect(result.data?.count == 12)
    }

    private static func okBody(count: Int) -> Data {
        Data("""
        {"ok":true,"data":{"enabled":true,"ready":true,"polarity":"no","epochId":"abc","seed":10,"count":\(count),"remaining":null,"dailyLimit":0,"pollMs":5000}}
        """.utf8)
    }
}

private final class MockReactionURLProtocol: URLProtocol {
    struct Stub {
        var status: Int
        var headers: [String: String]
        var body: Data
    }

    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) -> Stub)?
    nonisolated(unsafe) static var requests: [URLRequest] = []

    static func reset() {
        handler = nil
        requests = []
    }

    static func session() -> URLSession {
        let configuration = RateLimitResetTodayReactionClient.sessionConfiguration()
        configuration.protocolClasses = [MockReactionURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with _: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.requests.append(request)
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let stub = handler(request)
        let response = HTTPURLResponse(
            url: request.url ?? RateLimitResetTodayReaction.reactionURL,
            statusCode: stub.status,
            httpVersion: "HTTP/1.1",
            headerFields: stub.headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: stub.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
