import CFNetwork
import Darwin
import Foundation

/// Owns sessions without a delegate -> context retain cycle; ARC retires a replaced context after its callers finish.
public final class RunwayNetworkContext: @unchecked Sendable {
    typealias SessionFactory = @Sendable (URLSessionConfiguration, (any URLSessionDelegate)?) -> URLSession
    public let configuration: NetworkProxyConfiguration
    private let authentication: ProxyAuthenticationDelegate
    private let standard: URLSession
    private let withoutCookies: URLSession
    private let factory: SessionFactory

    public convenience init(
        configuration: NetworkProxyConfiguration = NetworkProxyConfiguration(),
        credentials: NetworkProxyCredentials? = nil) throws
    {
        try self.init(configuration: configuration, credentials: credentials, sessionFactory: Self.defaultFactory)
    }

    convenience init(
        configuration: NetworkProxyConfiguration = NetworkProxyConfiguration(),
        credentials: NetworkProxyCredentials? = nil,
        sessionFactory: @escaping SessionFactory) throws
    {
        let validated = try configuration.validated()
        let activeCredentials: NetworkProxyCredentials?
        if validated.usesAuthentication {
            guard let credentials else { throw NetworkProxyError.credentialsUnavailable }
            activeCredentials = try credentials.validated(for: validated.mode)
        } else {
            activeCredentials = nil
        }
        self.init(validated: validated, credentials: activeCredentials, factory: sessionFactory)
    }

    private init(
        validated: NetworkProxyConfiguration,
        credentials: NetworkProxyCredentials?,
        factory: @escaping SessionFactory)
    {
        configuration = validated
        authentication = ProxyAuthenticationDelegate(configuration: validated, credentials: credentials)
        self.factory = factory
        standard = factory(Self.sessionConfiguration(validated, credentials: credentials, policy: .standard), authentication)
        withoutCookies = factory(Self.sessionConfiguration(validated, credentials: credentials, policy: .withoutCookies), authentication)
    }

    deinit {
        standard.finishTasksAndInvalidate()
        withoutCookies.finishTasksAndInvalidate()
    }

    static func system() -> RunwayNetworkContext {
        RunwayNetworkContext(validated: NetworkProxyConfiguration(), credentials: nil, factory: defaultFactory)
    }

    public func data(
        for request: URLRequest,
        policy: RunwayNetworkPolicy = .standard) async throws -> (Data, URLResponse)
    {
        defer { withExtendedLifetime(self) {} }
        let session: URLSession
        switch policy {
        case .standard: session = standard
        case .withoutCookies: session = withoutCookies
        case .update: session = makeSession(policy: .update)
        }
        defer { if policy == .update { session.finishTasksAndInvalidate() } }
        // A cancelled authentication challenge may surface as URLError.cancelled on macOS.
        // Keep task-local evidence so concurrent requests and user cancellation stay distinct.
        let requestAuthentication = ProxyAuthenticationDelegate(
            configuration: configuration, credentials: authentication.credentials)
        do {
            let result = try await session.data(for: request, delegate: requestAuthentication)
            if configuration.mode != .system, (result.1 as? HTTPURLResponse)?.statusCode == 407 {
                throw NetworkProxyError.authenticationFailed
            }
            return result
        } catch {
            if requestAuthentication.failed, !Task.isCancelled {
                throw NetworkProxyError.authenticationFailed
            }
            throw mappedError(error)
        }
    }

    public func makeSession(
        policy: RunwayNetworkPolicy = .standard,
        delegate: (any URLSessionDelegate)? = nil) -> URLSession
    {
        factory(sessionConfiguration(for: policy), delegate ?? authentication)
    }

    public func sessionConfiguration(for policy: RunwayNetworkPolicy) -> URLSessionConfiguration {
        Self.sessionConfiguration(configuration, credentials: authentication.credentials, policy: policy)
    }

    public func authenticationResponse(
        for challenge: URLAuthenticationChallenge) -> (URLSession.AuthChallengeDisposition, URLCredential?)
    {
        authentication.response(for: challenge)
    }

    public func mappedError(_ error: Error) -> Error {
        guard configuration.mode != .system else { return error }
        if error is NetworkProxyError || error is CancellationError { return error }
        let native = error as NSError
        if configuration.mode == .socks5, native.domain == NSPOSIXErrorDomain,
           native.code == Int(EAUTH) || native.code == Int(ENEEDAUTH)
        {
            return NetworkProxyError.authenticationFailed
        }
        if native.domain == kCFErrorDomainCFNetwork as String || native.domain == NSPOSIXErrorDomain {
            return NetworkProxyError.connectionFailed
        }
        guard let urlError = error as? URLError else { return error }
        switch urlError.code {
        case .cancelled: return error
        case .userAuthenticationRequired, .userCancelledAuthentication:
            return NetworkProxyError.authenticationFailed
        default:
            return NetworkProxyError.connectionFailed
        }
    }

    private static let defaultFactory: SessionFactory = { configuration, delegate in
        URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
    }

    private static func sessionConfiguration(
        _ proxy: NetworkProxyConfiguration,
        credentials: NetworkProxyCredentials?,
        policy: RunwayNetworkPolicy) -> URLSessionConfiguration
    {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = policy == .update ? 60 : 20
        configuration.timeoutIntervalForResource = policy == .update ? 3_600 : 60
        // Explicitly bound credentials to this context instead of consulting the shared credential store.
        if proxy.mode != .system { configuration.urlCredentialStorage = nil }
        if policy == .withoutCookies || policy == .update {
            configuration.httpShouldSetCookies = false
            configuration.httpCookieAcceptPolicy = .never
            configuration.httpCookieStorage = nil
        }
        configuration.connectionProxyDictionary = proxyDictionary(proxy, credentials: credentials)
        return configuration
    }

    private static func proxyDictionary(
        _ proxy: NetworkProxyConfiguration,
        credentials: NetworkProxyCredentials?) -> [AnyHashable: Any]?
    {
        switch proxy.mode {
        case .system:
            return nil
        case .http:
            return [
                kCFNetworkProxiesHTTPEnable as String: 1,
                kCFNetworkProxiesHTTPProxy as String: proxy.host,
                kCFNetworkProxiesHTTPPort as String: proxy.port,
                kCFNetworkProxiesHTTPSEnable as String: 1,
                kCFNetworkProxiesHTTPSProxy as String: proxy.host,
                kCFNetworkProxiesHTTPSPort as String: proxy.port,
            ]
        case .socks5:
            var result: [AnyHashable: Any] = [
                kCFNetworkProxiesSOCKSEnable as String: 1,
                kCFNetworkProxiesSOCKSProxy as String: proxy.host,
                kCFNetworkProxiesSOCKSPort as String: proxy.port,
                kCFStreamPropertySOCKSVersion as String: kCFStreamSocketSOCKSVersion5,
            ]
            if let credentials {
                result[kCFStreamPropertySOCKSUser as String] = credentials.username
                result[kCFStreamPropertySOCKSPassword as String] = credentials.password
            }
            return result
        }
    }
}

private final class ProxyAuthenticationDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    let configuration: NetworkProxyConfiguration
    let credentials: NetworkProxyCredentials?
    private let lock = NSLock()
    private var rejectedAuthentication = false

    var failed: Bool { lock.withLock { rejectedAuthentication } }

    init(configuration: NetworkProxyConfiguration, credentials: NetworkProxyCredentials?) {
        self.configuration = configuration
        self.credentials = credentials
    }

    func response(for challenge: URLAuthenticationChallenge) -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        let space = challenge.protectionSpace
        guard configuration.mode == .http, space.isProxy(),
              space.host.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).lowercased() == configuration.host,
              space.port == configuration.port
        else { return (.performDefaultHandling, nil) }
        guard space.authenticationMethod == NSURLAuthenticationMethodHTTPBasic,
              challenge.previousFailureCount == 0, let credentials
        else { return (.cancelAuthenticationChallenge, nil) }
        return (.useCredential, URLCredential(user: credentials.username, password: credentials.password, persistence: .none))
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void)
    {
        let response = response(for: challenge)
        if response.0 == .cancelAuthenticationChallenge {
            lock.withLock { rejectedAuthentication = true }
        }
        completionHandler(response.0, response.1)
    }
}
