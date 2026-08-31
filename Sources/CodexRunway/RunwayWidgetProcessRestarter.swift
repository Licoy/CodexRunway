import Darwin
import Foundation

private struct RunwayWidgetProcessTerminationTimeout: LocalizedError {
    var processIdentifier: pid_t

    var errorDescription: String? {
        "Timed out waiting for widget process \(processIdentifier) to exit"
    }
}

private typealias RunwayAuditTokenSignalFunction = @convention(c) (
    UnsafeMutablePointer<audit_token_t>,
    Int32
) -> Int32

struct RunwayWidgetProcessIdentity: Equatable, Sendable {
    var processIdentifier: pid_t
    var userIdentifier: uid_t
    var startTimeSeconds: UInt64
    var startTimeMicroseconds: UInt64
    var auditToken: RunwayWidgetProcessAuditToken?
}

struct RunwayWidgetProcessAuditToken: Equatable, Sendable {
    private static let wordCount =
        MemoryLayout<audit_token_t>.size / MemoryLayout<UInt32>.size
    private var words: [UInt32]

    init(words: [UInt32]) {
        precondition(words.count == Self.wordCount)
        self.words = words
    }

    init(rawToken: audit_token_t) {
        words = withUnsafeBytes(of: rawToken) {
            Array($0.bindMemory(to: UInt32.self))
        }
    }

    func withRawToken<Result>(
        _ body: (UnsafeMutablePointer<audit_token_t>) throws -> Result
    ) rethrows -> Result {
        var token = audit_token_t()
        withUnsafeMutableBytes(of: &token) { destination in
            words.withUnsafeBytes { destination.copyBytes(from: $0) }
        }
        return try withUnsafeMutablePointer(to: &token, body)
    }
}

struct RunwayWidgetProcess: Equatable, Sendable {
    var identity: RunwayWidgetProcessIdentity
    var signingIdentifier: String

    var processIdentifier: pid_t { identity.processIdentifier }
}

struct RunwayWidgetProcessTerminationFailure: Equatable, Sendable {
    var processIdentifier: pid_t
    var message: String
}

struct RunwayWidgetProcessInspectionFailure: Equatable, Sendable {
    var processIdentifier: pid_t
    var message: String
}

struct RunwayWidgetProcessInspectionResult: Equatable, Sendable {
    var processes: [RunwayWidgetProcess] = []
    var failures: [RunwayWidgetProcessInspectionFailure] = []

    var failureMessage: String? {
        guard !failures.isEmpty else { return nil }
        return failures.map {
            "process \($0.processIdentifier): \($0.message)"
        }.joined(separator: "; ")
    }
}

struct RunwayWidgetProcessTerminationResult: Equatable, Sendable {
    var terminatedProcessIdentifiers: [pid_t] = []
    var failures: [RunwayWidgetProcessTerminationFailure] = []
    var loadFailureMessage: String?

    var canReloadTimelines: Bool {
        loadFailureMessage == nil && failures.isEmpty
    }
}

struct RunwayWidgetProcessTarget: Equatable, Sendable {
    var signingIdentifier: String
    var executablePath: String
    var sparkleInstallationRootPath: String?
}

struct RunwayWidgetProcessRestarter {
    typealias ProcessLoader = (
        _ target: RunwayWidgetProcessTarget
    ) throws -> RunwayWidgetProcessInspectionResult
    typealias ProcessTerminator = (RunwayWidgetProcessIdentity) throws -> Bool
    typealias ProcessIdentityLoader = (
        _ processIdentifier: pid_t
    ) throws -> RunwayWidgetProcessIdentity?
    typealias SignalSender = (
        _ identity: RunwayWidgetProcessIdentity,
        _ signal: Int32
    ) throws -> Bool

    private static let widgetBundleRelativePath =
        "Contents/PlugIns/CodexRunwayWidget.appex"

    private let loadProcesses: ProcessLoader
    private let terminate: ProcessTerminator

    init(
        loadProcesses: @escaping ProcessLoader,
        terminate: @escaping ProcessTerminator
    ) {
        self.loadProcesses = loadProcesses
        self.terminate = terminate
    }

    func terminateWidgetProcesses(
        target: RunwayWidgetProcessTarget
    ) -> RunwayWidgetProcessTerminationResult {
        let inspection: RunwayWidgetProcessInspectionResult
        do {
            inspection = try loadProcesses(target)
        } catch {
            return RunwayWidgetProcessTerminationResult(
                loadFailureMessage: error.localizedDescription)
        }

        var result = RunwayWidgetProcessTerminationResult(
            loadFailureMessage: inspection.failureMessage)
        for process in inspection.processes
        where process.signingIdentifier == target.signingIdentifier
        {
            do {
                if try terminate(process.identity) {
                    result.terminatedProcessIdentifiers.append(process.processIdentifier)
                }
            } catch {
                result.failures.append(RunwayWidgetProcessTerminationFailure(
                    processIdentifier: process.processIdentifier,
                    message: error.localizedDescription))
            }
        }
        return result
    }

    static func terminateLiveWidgetProcesses(
        target: RunwayWidgetProcessTarget
    ) -> RunwayWidgetProcessTerminationResult {
        RunwayWidgetProcessRestarter(
            loadProcesses: RunwayWidgetProcessInspector.loadRunningProcesses,
            terminate: terminateLiveProcess)
            .terminateWidgetProcesses(target: target)
    }

    static func bundledWidgetTarget(in hostBundle: Bundle) -> RunwayWidgetProcessTarget? {
        let widgetBundleURL = hostBundle.bundleURL
            .appendingPathComponent(widgetBundleRelativePath, isDirectory: true)
        guard let widgetBundle = Bundle(url: widgetBundleURL),
              let signingIdentifier = widgetBundle.bundleIdentifier,
              let executablePath = widgetBundle.executableURL?.path
        else { return nil }
        let cacheRoot = FileManager.default.urls(
            for: .cachesDirectory,
            in: .userDomainMask).first
        let sparkleRoot = hostBundle.bundleIdentifier.flatMap { hostIdentifier in
            cacheRoot?
                .appendingPathComponent(hostIdentifier, isDirectory: true)
                .appendingPathComponent("org.sparkle-project.Sparkle", isDirectory: true)
                .appendingPathComponent("Installation", isDirectory: true)
                .path
        }
        return RunwayWidgetProcessTarget(
            signingIdentifier: signingIdentifier,
            executablePath: executablePath,
            sparkleInstallationRootPath: sparkleRoot)
    }

    private static func terminateLiveProcess(
        _ identity: RunwayWidgetProcessIdentity
    ) throws -> Bool {
        try terminateProcess(
            identity,
            loadIdentity: { try RunwayWidgetProcessInspector.processIdentity(for: $0) },
            sendSignal: sendSignal,
            pause: { _ = usleep($0) })
    }

    static func terminateProcess(
        _ identity: RunwayWidgetProcessIdentity,
        loadIdentity: ProcessIdentityLoader,
        sendSignal: SignalSender,
        pause: (useconds_t) -> Void
    ) throws -> Bool {
        guard try loadIdentity(identity.processIdentifier) == identity else { return false }
        guard try sendSignal(identity, SIGTERM) else { return false }
        if try waitForExit(
            identity,
            attempts: 25,
            loadIdentity: loadIdentity,
            pause: pause)
        {
            return true
        }

        NSLog(
            "CodexRunway widget process %d did not exit after SIGTERM; sending SIGKILL.",
            identity.processIdentifier)
        guard try loadIdentity(identity.processIdentifier) == identity else { return true }
        guard try sendSignal(identity, SIGKILL) else { return true }
        if try waitForExit(
            identity,
            attempts: 25,
            loadIdentity: loadIdentity,
            pause: pause)
        {
            return true
        }
        throw RunwayWidgetProcessTerminationTimeout(
            processIdentifier: identity.processIdentifier)
    }

    private static func waitForExit(
        _ identity: RunwayWidgetProcessIdentity,
        attempts: Int,
        loadIdentity: ProcessIdentityLoader,
        pause: (useconds_t) -> Void
    ) throws -> Bool {
        for _ in 0..<attempts {
            guard try loadIdentity(identity.processIdentifier) == identity else {
                return true
            }
            pause(20_000)
        }
        return try loadIdentity(identity.processIdentifier) != identity
    }

    private static func sendSignal(
        _ identity: RunwayWidgetProcessIdentity,
        _ signal: Int32
    ) throws -> Bool {
        if let auditToken = identity.auditToken,
           let signalWithAuditToken = auditTokenSignalFunction()
        {
            let status = auditToken.withRawToken {
                signalWithAuditToken($0, signal)
            }
            guard status == 0 else {
                if status == ESRCH { return false }
                throw POSIXError(POSIXErrorCode(rawValue: status) ?? .EIO)
            }
            return true
        }

        guard try RunwayWidgetProcessInspector.processIdentity(
            for: identity.processIdentifier) == identity
        else { return false }
        guard Darwin.kill(identity.processIdentifier, signal) == 0 else {
            if errno == ESRCH { return false }
            throw currentPOSIXError()
        }
        return true
    }

    private static func auditTokenSignalFunction() -> RunwayAuditTokenSignalFunction? {
        guard let handle = dlopen(nil, RTLD_LAZY),
              let symbol = dlsym(handle, "proc_signal_with_audittoken")
        else { return nil }
        return unsafeBitCast(symbol, to: RunwayAuditTokenSignalFunction.self)
    }

    private static func currentPOSIXError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}
