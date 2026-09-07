import Foundation
import Network

/// Only the updater owns this listener; idle listeners have no capability routes or credentials.
@MainActor
public final class UpdateProxyBridge {
    typealias SessionFactory = @Sendable (RunwayNetworkContext, any URLSessionDelegate) -> URLSession

    private struct Cycle {
        let context: RunwayNetworkContext
        let failure: UpdateProxyFailureState
        var routes = UpdateProxyRoutes()
    }

    private let queue = DispatchQueue(label: "com.github.codex-runway.update-proxy")
    private let sessionFactory: SessionFactory
    private var listener: NWListener?
    private var port: UInt16?
    private var readiness: CheckedContinuation<Void, Error>?
    private var cycle: Cycle?
    private var failure = UpdateProxyFailureState()
    private var connections: [UUID: UpdateProxyConnection] = [:]

    public var isReady: Bool { port != nil }
    public var lastError: NetworkProxyError? { failure.error }

    public func clearFailure() { failure = UpdateProxyFailureState() }
    public func recordFailure(_ error: NetworkProxyError) { failure.error = error }

    public convenience init() {
        self.init { context, delegate in context.makeSession(policy: .update, delegate: delegate) }
    }

    init(sessionFactory: @escaping SessionFactory) {
        self.sessionFactory = sessionFactory
    }

    public func start() async throws {
        guard !isReady else { return }
        guard listener == nil else { throw UpdateProxyBridgeError.unavailable }
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters, on: .any)
        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in self?.accept(connection) }
        }
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            Task { @MainActor in
                guard let self, let listener, self.listener === listener else { return }
                self.listenerChanged(state)
            }
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                readiness = continuation
                listener.start(queue: queue)
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.stop() }
        }
    }

    public func beginCycle(context: RunwayNetworkContext, appcastURL: URL) throws -> URL {
        guard let port, cycle == nil else { throw UpdateProxyBridgeError.unavailable }
        let nextFailure = UpdateProxyFailureState()
        var next = Cycle(context: context, failure: nextFailure)
        let url = try next.routes.register(appcastURL, port: port)
        failure = nextFailure
        cycle = next
        return url
    }

    public func register(_ upstream: URL) throws -> URL {
        guard let port, var current = cycle else { throw UpdateProxyBridgeError.unavailable }
        let url = try current.routes.register(upstream, port: port)
        cycle = current
        return url
    }

    public func endCycle() {
        // Active transfers retain their own immutable context until they complete or cancel.
        cycle = nil
    }

    public func stop() {
        endCycle()
        port = nil
        listener?.cancel()
        listener = nil
        let pending = readiness
        readiness = nil
        pending?.resume(throwing: UpdateProxyBridgeError.unavailable)
        let active = Array(connections.values)
        connections.removeAll()
        active.forEach { $0.cancel() }
    }

    private func listenerChanged(_ state: NWListener.State) {
        switch state {
        case .ready:
            guard let boundPort = listener?.port?.rawValue else { stop(); return }
            port = boundPort
            let pending = readiness
            readiness = nil
            pending?.resume()
        case .failed, .cancelled:
            stop()
        default:
            break
        }
    }

    private func accept(_ connection: NWConnection) {
        guard isReady, connections.count < 8 else { connection.cancel(); return }
        let id = UUID()
        let transfer = UpdateProxyConnection(connection: connection, sessionFactory: sessionFactory) { [weak self] request in
            guard let self, let port = self.port, let cycle = self.cycle,
                  let upstream = cycle.routes.upstream(for: request, port: port)
            else { return nil }
            return UpdateProxyResource(url: upstream, context: cycle.context) { [failure = cycle.failure] error in
                failure.error = error
            }
        } onFinish: { [weak self] in
            self?.connections.removeValue(forKey: id)
        }
        connections[id] = transfer
        transfer.start(queue: queue)
    }
}

@MainActor
private final class UpdateProxyFailureState {
    var error: NetworkProxyError?
}
