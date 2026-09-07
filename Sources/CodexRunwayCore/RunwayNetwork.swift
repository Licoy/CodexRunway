import Foundation

public enum RunwayNetworkPolicy: Sendable {
    case standard
    case withoutCookies
    case update
}

/// New requests resolve the current context; existing requests retain their own context until completion.
public enum RunwayNetwork {
    private static let storage = ContextStorage()
    @TaskLocal static var scopedContext: RunwayNetworkContext?

    public static func context() throws -> RunwayNetworkContext {
        if let scopedContext { return scopedContext }
        return try storage.get().get()
    }

    public static func configure(
        configuration: NetworkProxyConfiguration,
        credentials: NetworkProxyCredentials? = nil) throws
    {
        configure(context: try RunwayNetworkContext(configuration: configuration, credentials: credentials))
    }

    public static func configure(context: RunwayNetworkContext) {
        storage.set(.success(context))
    }

    public static func block(error: NetworkProxyError) { storage.set(.failure(error)) }

    public static func data(
        for request: URLRequest,
        session: URLSession? = nil,
        policy: RunwayNetworkPolicy = .standard) async throws -> (Data, URLResponse)
    {
        if let session { return try await session.data(for: request) }
        return try await context().data(for: request, policy: policy)
    }

    private final class ContextStorage: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Result<RunwayNetworkContext, NetworkProxyError> = .success(.system())

        func get() -> Result<RunwayNetworkContext, NetworkProxyError> {
            lock.lock()
            defer { lock.unlock() }
            return value
        }

        func set(_ value: Result<RunwayNetworkContext, NetworkProxyError>) {
            lock.lock()
            let previous = self.value
            self.value = value
            lock.unlock()
            // Session invalidation must not run while the state lock is held.
            withExtendedLifetime(previous) {}
        }
    }
}
