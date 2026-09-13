import Foundation

public protocol LoginItemBackend {
    func status() throws -> LoginItemStatus
    func register() throws
    func unregister() throws
}

public enum LoginItemStatus: Equatable, Sendable {
    case notRegistered
    case enabled
    case requiresApproval
    /// Command-line and development hosts must not manage system login items.
    case unavailable

    public var isRegistered: Bool { self == .enabled || self == .requiresApproval }
}

public enum LoginItemError: Error, Equatable, Sendable {
    case registerFailed
    case unregisterFailed
    case statusUnavailable

    public var l10nKey: L10nKey { .launchAtLoginFailed }
}

public struct LoginItemApplier {
    private let backend: any LoginItemBackend
    private let canMutateSystem: Bool

    public init(backend: any LoginItemBackend, canMutateSystem: Bool) {
        self.backend = backend
        self.canMutateSystem = canMutateSystem
    }

    public func status() throws -> LoginItemStatus {
        guard canMutateSystem else { return .unavailable }
        return try backend.status()
    }

    @discardableResult
    public func apply(enabled: Bool) throws -> LoginItemStatus {
        guard canMutateSystem else { return .unavailable }
        if enabled {
            try backend.register()
        } else {
            try backend.unregister()
        }
        let result = try backend.status()
        guard enabled ? result.isRegistered : result == .notRegistered else {
            throw enabled ? LoginItemError.registerFailed : .unregisterFailed
        }
        return result
    }
}
