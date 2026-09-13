import Testing
@testable import CodexRunwayCore

@Suite("Login items")
struct LoginItemTests {
    @Test("apply enabled registers and apply disabled unregisters")
    func applyEnabledRegistersAndDisabledUnregisters() throws {
        let backend = RecordingLoginItemBackend()
        let applier = LoginItemApplier(backend: backend, canMutateSystem: true)

        try applier.apply(enabled: true)
        #expect(backend.calls == [.register])
        #expect(backend.isEnabled)

        try applier.apply(enabled: false)
        #expect(backend.calls == [.register, .unregister])
        #expect(!backend.isEnabled)
    }

    @Test("default preference apply issues a register attempt")
    func defaultPreferenceIssuesRegister() throws {
        let backend = RecordingLoginItemBackend()
        let applier = LoginItemApplier(backend: backend, canMutateSystem: true)

        try applier.apply(enabled: RunwayPreferences().launchAtLoginEnabled)

        #expect(RunwayPreferences().launchAtLoginEnabled)
        #expect(backend.calls == [.register])
        #expect(backend.isEnabled)
    }

    @Test("unpackaged processes skip OS mutation")
    func skipOSMutationWhenNotPackaged() throws {
        let backend = RecordingLoginItemBackend()
        let applier = LoginItemApplier(backend: backend, canMutateSystem: false)

        #expect(try applier.status() == .unavailable)
        #expect(try applier.apply(enabled: true) == .unavailable)
        #expect(try applier.apply(enabled: false) == .unavailable)

        #expect(backend.calls.isEmpty)
        #expect(!backend.isEnabled)
    }

    @Test("registration pending approval remains distinguishable from enabled")
    func pendingApproval() throws {
        let backend = RecordingLoginItemBackend()
        backend.reportedStatus = .requiresApproval
        let applier = LoginItemApplier(backend: backend, canMutateSystem: true)

        #expect(try applier.apply(enabled: true) == .requiresApproval)
    }

    @Test("successful calls must also reach the requested system state")
    func unchangedStateFails() {
        let backend = RecordingLoginItemBackend()
        let applier = LoginItemApplier(backend: backend, canMutateSystem: true)
        backend.reportedStatus = .notRegistered
        #expect(throws: LoginItemError.registerFailed) { try applier.apply(enabled: true) }
        backend.reportedStatus = .enabled
        #expect(throws: LoginItemError.unregisterFailed) { try applier.apply(enabled: false) }
    }

    @Test("system status failures propagate instead of reporting disabled")
    func statusFailurePropagates() {
        let backend = RecordingLoginItemBackend()
        backend.statusError = .statusUnavailable
        let applier = LoginItemApplier(backend: backend, canMutateSystem: true)

        #expect(throws: LoginItemError.statusUnavailable) { try applier.status() }
        #expect(throws: LoginItemError.statusUnavailable) { try applier.apply(enabled: false) }
    }
}

final class RecordingLoginItemBackend: LoginItemBackend {
    enum Call: Equatable {
        case register
        case unregister
    }

    private(set) var calls: [Call] = []
    private(set) var isEnabled = false
    var registerError: Error?
    var unregisterError: Error?
    var statusError: LoginItemError?
    var reportedStatus: LoginItemStatus?

    func status() throws -> LoginItemStatus {
        if let statusError { throw statusError }
        return reportedStatus ?? (isEnabled ? .enabled : .notRegistered)
    }

    func register() throws {
        calls.append(.register)
        if let registerError { throw registerError }
        isEnabled = true
    }

    func unregister() throws {
        calls.append(.unregister)
        if let unregisterError { throw unregisterError }
        isEnabled = false
    }
}
