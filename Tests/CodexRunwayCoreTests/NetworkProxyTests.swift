import CFNetwork
import Darwin
import Foundation
import Testing
@testable import CodexRunwayCore

@Suite("Network proxy configuration and authentication")
struct NetworkProxyTests {
    @Test("missing settings use system mode; malformed stored settings never do", arguments: ["wrong type", "malformed JSON", "unknown mode", "missing fields"])
    func malformedSettingsFail(_ kind: String) throws {
        let suite = "proxy-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = NetworkProxyStore(defaults: defaults)
        #expect(try store.load().mode == .system)
        let values: [String: Any] = [
            "wrong type": "http://localhost:7890",
            "malformed JSON": Data("{".utf8),
            "unknown mode": Data(#"{"mode":"automatic"}"#.utf8),
            "missing fields": Data(#"{"mode":"http"}"#.utf8),
        ]
        defaults.set(values[kind], forKey: "runway.networkProxy")
        #expect(throws: NetworkProxyError.invalidConfiguration) { try store.load() }
    }

    @Test("settings round trip only an opaque credential reference")
    func nonSecretPersistence() throws {
        let suite = "proxy-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = NetworkProxyStore(defaults: defaults)
        let configuration = NetworkProxyConfiguration(
            mode: .http, host: "LOCALHOST", port: 7890,
            usesAuthentication: true, credentialID: UUID().uuidString)
        try store.save(configuration)
        #expect(try store.load() == configuration.validated())
        let encoded = try #require(defaults.data(forKey: "runway.networkProxy"))
        let json = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(json["username"] == nil)
        #expect(json["password"] == nil)
        #expect(json["credentialID"] as? String == configuration.credentialID)
    }

    @Test("hosts normalize DNS and IP addresses", arguments: [
        (" localhost ", "localhost"), ("Proxy.Example", "proxy.example"),
        ("127.0.0.1", "127.0.0.1"), ("[::1]", "::1"), ("2001:DB8::1", "2001:db8::1"),
    ])
    func validHosts(_ input: String, _ expected: String) throws {
        #expect(try NetworkProxyConfiguration(mode: .http, host: input, port: 1).validated().host == expected)
    }

    @Test("host field rejects URLs, userinfo and invalid literals", arguments: [
        "", "http://localhost", "localhost/path", "user@localhost", "localhost?x=1", "localhost#x",
        "localhost:7890", "a b", "a\n.local", "[localhost]", "[::1", "::broken", "256.0.0.1",
        "-bad.example", "bad-.example", "a..example", "a\\b", "proxy%2eexample", "[::1]:7890",
    ])
    func invalidHosts(_ host: String) {
        #expect(throws: NetworkProxyError.invalidHost) {
            try NetworkProxyConfiguration(mode: .socks5, host: host, port: 7890).validated()
        }
    }

    @Test("ports are bounded and invalid credentials block context creation")
    func validatesPortsAndCredentials() throws {
        for port in [0, -1, 65_536] {
            #expect(throws: NetworkProxyError.invalidPort) {
                try NetworkProxyConfiguration(mode: .http, host: "localhost", port: port).validated()
            }
        }
        let configuration = NetworkProxyConfiguration(mode: .http, host: "localhost", port: 7890, usesAuthentication: true)
        #expect(throws: NetworkProxyError.credentialsUnavailable) {
            try RunwayNetworkContext(configuration: configuration)
        }
        #expect(throws: NetworkProxyError.invalidCredentials) {
            try RunwayNetworkContext(configuration: configuration, credentials: .init(username: "bad:user", password: "fixture"))
        }
        #expect(throws: NetworkProxyError.invalidCredentials) {
            try NetworkProxyCredentials(username: "fixture", password: String(repeating: "x", count: 256)).validated(for: .socks5)
        }
    }

    @Test("session policies preserve timeouts and cookie isolation")
    func sessionPolicies() throws {
        let context = try RunwayNetworkContext(configuration: .init(mode: .http, host: "::1", port: 7890))
        let standard = context.sessionConfiguration(for: .standard)
        let dictionary = try #require(standard.connectionProxyDictionary)
        #expect(dictionary[kCFNetworkProxiesHTTPProxy as String] as? String == "::1")
        #expect(dictionary[kCFNetworkProxiesHTTPSProxy as String] as? String == "::1")
        #expect(dictionary[kCFNetworkProxiesHTTPPort as String] as? Int == 7890)
        #expect(dictionary[kCFNetworkProxiesHTTPSPort as String] as? Int == 7890)
        #expect(standard.timeoutIntervalForRequest == 20)
        #expect(standard.timeoutIntervalForResource == 60)
        let reaction = context.sessionConfiguration(for: .withoutCookies)
        #expect(!reaction.httpShouldSetCookies)
        #expect(reaction.httpCookieStorage == nil)
        #expect(reaction.httpCookieAcceptPolicy == .never)
        #expect(context.sessionConfiguration(for: .update).timeoutIntervalForResource > 60)
        #expect(try RunwayNetworkContext().sessionConfiguration(for: .standard).connectionProxyDictionary == nil)
    }

    @Test("SOCKS credentials use the stream keys and are not HTTP headers")
    func socksCredentials() throws {
        let context = try RunwayNetworkContext(
            configuration: .init(mode: .socks5, host: "localhost", port: 1080, usesAuthentication: true),
            credentials: .init(username: "fixture-user", password: "fixture-password"))
        let session = context.sessionConfiguration(for: .standard)
        let dictionary = try #require(session.connectionProxyDictionary)
        #expect(dictionary[kCFStreamPropertySOCKSUser as String] as? String == "fixture-user")
        #expect(dictionary[kCFStreamPropertySOCKSPassword as String] as? String == "fixture-password")
        #expect(dictionary[kCFProxyUsernameKey as String] == nil)
        #expect(session.httpAdditionalHeaders?["Proxy-Authorization"] == nil)
    }

    @Test("HTTP credentials are only offered once to the exact proxy protection space")
    func confinesHTTPAuthentication() throws {
        let context = try RunwayNetworkContext(
            configuration: .init(mode: .http, host: "localhost", port: 7890, usesAuthentication: true),
            credentials: .init(username: "fixture-user", password: "fixture-password"))
        let proxy = URLProtectionSpace(proxyHost: "localhost", port: 7890, type: NSURLProtectionSpaceHTTPProxy,
                                       realm: "fixture", authenticationMethod: NSURLAuthenticationMethodHTTPBasic)
        let answer = context.authenticationResponse(for: challenge(proxy))
        #expect(answer.0 == .useCredential)
        #expect(answer.1?.user == "fixture-user")
        #expect(answer.1?.persistence == URLCredential.Persistence.none)
        #expect(context.authenticationResponse(for: challenge(proxy, failures: 1)).0 == .cancelAuthenticationChallenge)
        let other = URLProtectionSpace(proxyHost: "other.example", port: 7890, type: NSURLProtectionSpaceHTTPProxy,
                                       realm: "fixture", authenticationMethod: NSURLAuthenticationMethodHTTPBasic)
        #expect(context.authenticationResponse(for: challenge(other)).1 == nil)
        let origin = URLProtectionSpace(host: "localhost", port: 7890, protocol: "https",
                                       realm: "fixture", authenticationMethod: NSURLAuthenticationMethodHTTPBasic)
        #expect(context.authenticationResponse(for: challenge(origin)).0 == .performDefaultHandling)
        #expect(context.authenticationResponse(for: challenge(origin)).1 == nil)
    }

    @Test("public SOCKS authentication error codes remain distinct from connection failures")
    func mapsSOCKSErrors() throws {
        let context = try RunwayNetworkContext(configuration: .init(mode: .socks5, host: "localhost", port: 1080))
        for code in [EAUTH, ENEEDAUTH] {
            #expect(context.mappedError(NSError(domain: NSPOSIXErrorDomain, code: Int(code))) as? NetworkProxyError == .authenticationFailed)
        }
        #expect(context.mappedError(NSError(domain: kCFErrorDomainCFNetwork as String, code: 310)) as? NetworkProxyError == .connectionFailed)
        #expect(context.mappedError(URLError(.badURL)) as? NetworkProxyError == .connectionFailed)
        #expect((try RunwayNetworkContext().mappedError(NSError(domain: NSPOSIXErrorDomain, code: Int(EAUTH))) as NSError).domain == NSPOSIXErrorDomain)
    }

    private func challenge(_ space: URLProtectionSpace, failures: Int = 0) -> URLAuthenticationChallenge {
        URLAuthenticationChallenge(protectionSpace: space, proposedCredential: nil, previousFailureCount: failures,
                                   failureResponse: nil, error: nil, sender: ProxyChallengeSender())
    }
}

private final class ProxyChallengeSender: NSObject, URLAuthenticationChallengeSender {
    func use(_ credential: URLCredential, for challenge: URLAuthenticationChallenge) {}
    func continueWithoutCredential(for challenge: URLAuthenticationChallenge) {}
    func cancel(_ challenge: URLAuthenticationChallenge) {}
}
