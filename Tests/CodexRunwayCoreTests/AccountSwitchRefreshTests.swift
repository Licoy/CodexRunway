import Foundation
import Testing
@testable import CodexRunwayCore

@Suite("Account switch refresh boundaries", .serialized)
struct AccountSwitchRefreshTests {
    @Test("rotated current credentials stay synchronized when quota fails", arguments: [true, false], [false, true])
    func refreshSuccessQuotaFailure(currentTarget: Bool, timeout: Bool) async throws {
        let fixture = try Fixture(currentTarget: currentTarget)
        defer { fixture.remove() }
        let officialBefore = try Data(contentsOf: fixture.store.officialAuthURL)
        let switcher = AccountSwitcher(
            store: fixture.store,
            tokenRefresher: RefreshBoundaryURLProtocol.refresher(status: 200),
            fetchQuota: { auth in
                if timeout { throw URLError(.timedOut) }
                return try await SwitchQuotaURLProtocol.client(status: 500).fetchQuota(auth: auth)
            })

        await #expect(throws: URLError(timeout ? .timedOut : .badServerResponse)) {
            try await switcher.switchTo(accountId: fixture.target.id)
        }
        let managed = try fixture.store.loadCredential(id: fixture.target.id)
        #expect(managed.tokens.refreshToken == "rotated-refresh-token-for-tests-only")
        if currentTarget {
            #expect(try fixture.store.loadOfficialAuth() == managed)
        } else {
            #expect(try Data(contentsOf: fixture.store.officialAuthURL) == officialBefore)
        }
        let index = try fixture.store.loadIndex()
        #expect(index.activeAccountId == fixture.current.id)
        #expect(index.account(id: fixture.target.id)?.requiresReauth == false)
    }

    @Test("expired target keeps login and cached quota on refresh HTTP failures", arguments: [true, false], [403, 429, 500, 503])
    func temporaryRefreshFailure(currentTarget: Bool, status: Int) async throws {
        let fixture = try Fixture(currentTarget: currentTarget)
        defer { fixture.remove() }
        let before = try Data(contentsOf: fixture.store.officialAuthURL)
        let managedBefore = try fixture.store.loadCredential(id: fixture.target.id)
        let indexBefore = try fixture.store.loadIndex()
        let switcher = AccountSwitcher(
            store: fixture.store,
            tokenRefresher: RefreshBoundaryURLProtocol.refresher(status: status),
            fetchQuota: { _ in
                Issue.record("Quota must not be requested after refresh failed")
                throw URLError(.unsupportedURL)
            })

        await #expect(throws: TokenRefreshHTTPError(statusCode: status)) {
            try await switcher.switchTo(accountId: fixture.target.id)
        }
        #expect(RefreshBoundaryURLProtocol.requests.count == 1)
        #expect(try Data(contentsOf: fixture.store.officialAuthURL) == before)
        #expect(try fixture.store.loadCredential(id: fixture.target.id) == managedBefore)
        #expect(try fixture.store.loadIndex() == indexBefore)
    }

    @Test("refresh authorization refusal marks expired target for reauthorization", arguments: [400, 401])
    func refusedRefresh(status: Int) async throws {
        let fixture = try Fixture(currentTarget: false)
        defer { fixture.remove() }
        let before = try Data(contentsOf: fixture.store.officialAuthURL)
        let switcher = AccountSwitcher(store: fixture.store, tokenRefresher: RefreshBoundaryURLProtocol.refresher(status: status))

        await #expect(throws: URLError(.userAuthenticationRequired)) {
            try await switcher.switchTo(accountId: fixture.target.id)
        }
        let target = try #require(fixture.store.loadIndex().account(id: fixture.target.id))
        #expect(target.requiresReauth)
        #expect(target.cachedQuota == nil)
        #expect(try Data(contentsOf: fixture.store.officialAuthURL) == before)
        #expect(RefreshBoundaryURLProtocol.requests.count == 1)
    }

    @Test("client-id compatibility fallback remains supported")
    func clientIDFallback() async throws {
        var auth = Fixture.auth(id: "legacy", expired: true)
        let refresher = RefreshBoundaryURLProtocol.refresher(status: 200, compatibility: true)
        try await refresher.refresh(&auth)
        #expect(RefreshBoundaryURLProtocol.requests.count == 2)
        #expect(RefreshBoundaryURLProtocol.requests[0].contains("client_id="))
        #expect(!RefreshBoundaryURLProtocol.requests[1].contains("client_id="))
        #expect(auth.tokens.refreshToken == "rotated-refresh-token-for-tests-only")
    }

    @Test("reauth persistence read and write failures are reported without losing the auth error", arguments: [false, true])
    func reportsPersistenceFailure(writeFailure: Bool) async throws {
        let fixture = try Fixture(currentTarget: false, expired: false)
        defer {
            try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: fixture.store.indexURL.path)
            fixture.remove()
        }
        let reports = ErrorReports()
        let original = URLError(.userAuthenticationRequired, userInfo: ["test-marker": "original-auth-error"])
        var switcher = AccountSwitcher(store: fixture.store, fetchQuota: { _ in
            if writeFailure {
                try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: fixture.store.indexURL.path)
            } else {
                try Data("invalid index".utf8).write(to: fixture.store.indexURL)
            }
            throw original
        })
        switcher.reportPersistenceFailure = { reports.record($0) }
        do {
            _ = try await switcher.switchTo(accountId: fixture.target.id)
            Issue.record("Expected the original authentication failure")
        } catch let error as URLError {
            #expect(error.code == original.code)
            #expect(error.userInfo["test-marker"] as? String == "original-auth-error")
        }
        #expect(reports.count == 1)
    }
}

private struct Fixture: Sendable {
    let root: URL
    let store: AccountStore
    let current: ManagedAccount
    let target: ManagedAccount

    init(currentTarget: Bool, expired: Bool = true) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("switch-refresh-\(UUID().uuidString)")
        store = AccountStore(rootURL: root.appendingPathComponent("accounts"), officialAuthURL: root.appendingPathComponent("auth.json"))
        let currentAuth = Self.auth(id: "current", expired: currentTarget && expired)
        current = try store.upsert(auth: currentAuth, makeActive: true)
        target = currentTarget ? current : try store.upsert(auth: Self.auth(id: "target", expired: expired))
        try store.saveOfficialAuth(currentAuth)
        let quota = QuotaSnapshot(
            plan: "plus", primary: RateWindow(usedPercent: 25, windowMinutes: 300, resetsAt: nil),
            secondary: nil, additionalWindows: [], creditsBalance: nil, updatedAt: Date())
        try store.updateMetadata(target.applying(quota: quota))
    }

    func remove() { try? FileManager.default.removeItem(at: root) }

    static func auth(id: String, expired: Bool) -> CodexAuth {
        let identity = jwt(["email": "\(id)@example.com", "https://api.openai.com/auth": ["chatgpt_account_id": id]])
        return CodexAuth(authMode: "chatgpt", tokens: .init(
            idToken: identity, accessToken: jwt(["exp": expired ? 1 : 4_100_000_000, "sub": "test-user-\(id)"]),
            refreshToken: "test-refresh-token-for-\(id)-only", accountId: id), lastRefresh: nil)
    }

    static func jwt(_ payload: [String: Any]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        return [Data(#"{"alg":"none"}"#.utf8), data, Data()]
            .map { $0.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") }
            .joined(separator: ".")
    }
}

private final class ErrorReports: @unchecked Sendable {
    private let lock = NSLock()
    private var errors: [Error] = []
    var count: Int { lock.lock(); defer { lock.unlock() }; return errors.count }
    func record(_ error: Error) { lock.lock(); defer { lock.unlock() }; errors.append(error) }
}

private final class RefreshBoundaryURLProtocol: URLProtocol {
    nonisolated(unsafe) static var requests: [String] = []

    static func refresher(status: Int, compatibility: Bool = false) -> TokenRefresher {
        requests = []
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RefreshBoundaryURLProtocol.self]
        return TokenRefresher(session: URLSession(configuration: configuration),
                              tokenURL: URL(string: "https://refresh-\(status).invalid/\(compatibility ? "compatibility" : "token")")!)
    }

    override class func canInit(with _: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        // URLSession may move a request body into a stream before URLProtocol sees it.
        let body: String
        if let data = request.httpBody {
            body = String(decoding: data, as: UTF8.self)
        } else if let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var bytes = [UInt8](repeating: 0, count: 4096)
            let count = stream.read(&bytes, maxLength: bytes.count)
            body = count > 0 ? String(decoding: bytes.prefix(count), as: UTF8.self) : ""
        } else { body = "" }
        Self.requests.append(body)
        let rejectClient = request.url!.path == "/compatibility" && body.contains("client_id=")
        let status = rejectClient ? 400 : Int(request.url!.host!.split(separator: ".")[0].dropFirst("refresh-".count))!
        let payload: [String: Any] = status == 200
            ? ["access_token": Fixture.jwt(["exp": 4_100_000_000]), "refresh_token": "rotated-refresh-token-for-tests-only"]
            : ["error": rejectClient ? "invalid_client" : "invalid_grant"]
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: try! JSONSerialization.data(withJSONObject: payload))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
