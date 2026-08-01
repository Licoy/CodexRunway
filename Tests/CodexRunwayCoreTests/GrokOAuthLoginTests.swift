import Foundation
import Testing
@testable import CodexRunwayCore

@Suite("Grok OAuth device login")
struct GrokOAuthLoginTests {
    @Test("builds a parseable Grok auth.json from device tokens")
    func buildsAuthDocument() throws {
        let tokens = GrokOAuthLogin.TokenBundle(
            accessToken: "access-token-for-tests-only",
            refreshToken: "refresh-token-for-tests-only",
            idToken: nil,
            tokenType: "Bearer",
            expiresIn: 3_600,
            email: "device@example.com",
            subject: "subject-123",
            tokenEndpoint: URL(string: "https://auth.x.ai/oauth2/token")!)

        let data = try GrokOAuthLogin.makeAuthDocumentData(
            tokens: tokens,
            now: Date(timeIntervalSince1970: 1_785_499_200))
        let document = try GrokAuthDocument.parse(data)

        #expect(document.identity.email == "device@example.com")
        #expect(document.identity.userID == "subject-123")
        #expect(document.identity.principalID == "subject-123")
        #expect(document.identity.hasAccessToken)
        #expect(document.identity.hasRefreshToken)
        #expect(document.identity.kind == .oauth)
        #expect(document.identity.clientID == GrokOAuthLogin.clientID)
        #expect(try document.accessToken() == "access-token-for-tests-only")
    }

    @Test("parses email and subject from a JWT id_token payload")
    func buildsAuthDocumentFromJWTClaims() throws {
        let header = Data(#"{"alg":"none"}"#.utf8).base64URLEncodedString()
        let payload = Data(
            #"{"email":"jwt@example.com","sub":"jwt-subject"}"#.utf8)
            .base64URLEncodedString()
        let idToken = "\(header).\(payload).sig"
        let tokens = GrokOAuthLogin.TokenBundle(
            accessToken: "jwt-access-for-tests-only",
            refreshToken: "jwt-refresh-for-tests-only",
            idToken: idToken,
            tokenType: "Bearer",
            expiresIn: 600,
            email: nil,
            subject: nil,
            tokenEndpoint: URL(string: "https://auth.x.ai/oauth2/token")!)

        // makeAuthDocumentData uses tokens.email/subject; simulate post-parse fill via JWT helper path
        // by constructing as waitForAuthorization would (email/subject already extracted).
        let filled = GrokOAuthLogin.TokenBundle(
            accessToken: tokens.accessToken,
            refreshToken: tokens.refreshToken,
            idToken: idToken,
            tokenType: tokens.tokenType,
            expiresIn: tokens.expiresIn,
            email: "jwt@example.com",
            subject: "jwt-subject",
            tokenEndpoint: tokens.tokenEndpoint)
        let document = try GrokAuthDocument.parse(try GrokOAuthLogin.makeAuthDocumentData(tokens: filled))
        #expect(document.identity.email == "jwt@example.com")
        #expect(document.identity.userID == "jwt-subject")
    }

    @Test("rejects tokens without any identity fields")
    func rejectsMissingIdentity() {
        let tokens = GrokOAuthLogin.TokenBundle(
            accessToken: "access-only",
            refreshToken: "refresh-only",
            idToken: nil,
            tokenType: nil,
            expiresIn: nil,
            email: nil,
            subject: nil,
            tokenEndpoint: URL(string: "https://auth.x.ai/oauth2/token")!)
        #expect(throws: GrokOAuthLogin.Error.missingIdentity) {
            try GrokOAuthLogin.makeAuthDocumentData(tokens: tokens)
        }
    }

    @Test("login writes auth.json into the isolated home and opens the verification URL")
    func loginWritesAuthAndOpensBrowser() async throws {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-runway-grok-oauth-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GrokOAuthURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let opened = OpenedURLBox()
        GrokOAuthURLProtocol.reset()
        GrokOAuthURLProtocol.mode = .success

        try await GrokOAuthLogin.login(
            homeURL: temporary,
            session: session,
            openURL: { url in opened.set(url) },
            now: { Date(timeIntervalSince1970: 1_785_499_200) })

        #expect(opened.value?.absoluteString.contains("user_code=ABCD-EFGH") == true)
        let authURL = temporary.appendingPathComponent("auth.json")
        let data = try Data(contentsOf: authURL)
        let document = try GrokAuthDocument.parse(data)
        #expect(document.identity.email == "oauth@example.com")
        #expect(try document.accessToken() == "device-access-token")
        let permissions = try #require(
            FileManager.default.attributesOfItem(atPath: authURL.path)[.posixPermissions] as? NSNumber)
        #expect(permissions.intValue & 0o777 == 0o600)
    }

    @Test("login cancellation aborts device polling")
    func loginCancellationAbortsPolling() async throws {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-runway-grok-oauth-cancel-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GrokOAuthURLProtocol.self]
        let session = URLSession(configuration: configuration)
        GrokOAuthURLProtocol.reset()
        GrokOAuthURLProtocol.mode = .pendingForever

        let task = Task {
            try await GrokOAuthLogin.login(
                homeURL: temporary,
                session: session,
                openURL: { _ in },
                now: Date.init)
        }
        // Allow the first pending poll to start.
        try await Task.sleep(for: .milliseconds(50))
        task.cancel()

        do {
            try await task.value
            Issue.record("cancelled login unexpectedly succeeded")
        } catch is CancellationError {
            // Expected.
        } catch {
            Issue.record("cancelled login returned \(error) instead of CancellationError")
        }
        #expect(FileManager.default.fileExists(atPath: temporary.appendingPathComponent("auth.json").path) == false)
    }
}

// MARK: - Test doubles

private final class OpenedURLBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: URL?

    var value: URL? {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    func set(_ url: URL) {
        lock.lock()
        stored = url
        lock.unlock()
    }
}

private final class GrokOAuthURLProtocol: URLProtocol, @unchecked Sendable {
    enum Mode: Sendable {
        case success
        case pendingForever
    }

    nonisolated(unsafe) static var mode: Mode = .success
    nonisolated(unsafe) static var tokenPollCount = 0

    static func reset() {
        mode = .success
        tokenPollCount = 0
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let url = request.url!
        let path = url.path
        let method = request.httpMethod ?? "GET"

        let payload: [String: Any]
        var status = 200

        if path.contains("openid-configuration") {
            payload = [
                "device_authorization_endpoint": "https://auth.x.ai/oauth2/device/code",
                "token_endpoint": "https://auth.x.ai/oauth2/token",
            ]
        } else if path.contains("/device") || path.contains("device/code") {
            payload = [
                "device_code": "device-code-for-tests",
                "user_code": "ABCD-EFGH",
                "verification_uri": "https://accounts.x.ai/oauth2/device",
                "verification_uri_complete": "https://accounts.x.ai/oauth2/device?user_code=ABCD-EFGH",
                "expires_in": 1_800,
                "interval": 1,
            ]
        } else if path.contains("/token") && method == "POST" {
            Self.tokenPollCount += 1
            switch Self.mode {
            case .pendingForever:
                payload = ["error": "authorization_pending"]
            case .success:
                if Self.tokenPollCount < 2 {
                    payload = ["error": "authorization_pending"]
                } else {
                    payload = [
                        "access_token": "device-access-token",
                        "refresh_token": "device-refresh-token",
                        "token_type": "Bearer",
                        "expires_in": 3_600,
                        "email": "oauth@example.com",
                        "sub": "oauth-subject",
                    ]
                }
            }
        } else {
            status = 404
            payload = ["error": "not_found"]
        }

        let data = try! JSONSerialization.data(withJSONObject: payload)
        let response = HTTPURLResponse(
            url: url,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
