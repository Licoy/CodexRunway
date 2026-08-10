import Darwin
import Foundation
import Testing
@testable import CodexRunway

@Suite("Runway widget process restarter")
struct RunwayWidgetProcessRestarterTests {
    @Test("restarts every process signed as the production widget only")
    func restartsProductionWidgetProcessesOnly() {
        let processes = [
            RunwayWidgetProcess(
                identity: identity(processIdentifier: 101),
                signingIdentifier: "com.github.codex-runway.widget"),
            RunwayWidgetProcess(
                identity: identity(processIdentifier: 102),
                signingIdentifier: "com.github.codex-runway.widget"),
            RunwayWidgetProcess(
                identity: identity(processIdentifier: 103),
                signingIdentifier: "com.github.codex-runway.widget.swift-dev"),
            RunwayWidgetProcess(
                identity: identity(processIdentifier: 104),
                signingIdentifier: "com.example.other-widget"),
        ]
        var terminated: [pid_t] = []
        let restarter = RunwayWidgetProcessRestarter(
            loadProcesses: { _ in
                RunwayWidgetProcessInspectionResult(processes: processes)
            },
            terminate: {
                terminated.append($0.processIdentifier)
                return true
            })

        let result = restarter.terminateWidgetProcesses(target: productionTarget)

        #expect(terminated == [101, 102])
        #expect(result.terminatedProcessIdentifiers == [101, 102])
        #expect(result.failures.isEmpty)
        #expect(result.canReloadTimelines)
    }

    @Test("reports a matching widget process that cannot be terminated")
    func reportsTerminationFailure() {
        let process = RunwayWidgetProcess(
            identity: identity(processIdentifier: 201),
            signingIdentifier: "com.github.codex-runway.widget")
        let restarter = RunwayWidgetProcessRestarter(
            loadProcesses: { _ in
                RunwayWidgetProcessInspectionResult(processes: [process])
            },
            terminate: { _ in throw POSIXError(.EPERM) })

        let result = restarter.terminateWidgetProcesses(target: productionTarget)

        #expect(result.terminatedProcessIdentifiers.isEmpty)
        #expect(result.failures.map(\.processIdentifier) == [201])
        #expect(result.failures.first?.message.isEmpty == false)
        #expect(result.canReloadTimelines == false)
    }

    @Test("terminates confirmed targets while blocking reload for unknown processes")
    func terminatesConfirmedTargetsAlongsideUnknownProcesses() {
        let production = RunwayWidgetProcess(
            identity: identity(processIdentifier: 202),
            signingIdentifier: "com.github.codex-runway.widget")
        let development = RunwayWidgetProcess(
            identity: identity(processIdentifier: 203),
            signingIdentifier: "com.github.codex-runway.widget.swift-dev")
        var terminated: [pid_t] = []
        let restarter = RunwayWidgetProcessRestarter(
            loadProcesses: { _ in
                RunwayWidgetProcessInspectionResult(
                    processes: [production, development],
                    failures: [RunwayWidgetProcessInspectionFailure(
                        processIdentifier: 204,
                        message: "ambiguous deleted image")])
            },
            terminate: {
                terminated.append($0.processIdentifier)
                return true
            })

        let result = restarter.terminateWidgetProcesses(target: productionTarget)

        #expect(terminated == [202])
        #expect(result.terminatedProcessIdentifiers == [202])
        #expect(result.loadFailureMessage?.contains("204") == true)
        #expect(result.canReloadTimelines == false)
    }

    @Test("blocks timeline reload when process inspection fails")
    func blocksTimelineReloadAfterInspectionFailure() {
        let restarter = RunwayWidgetProcessRestarter(
            loadProcesses: { _ in throw POSIXError(.EIO) },
            terminate: { _ in true })

        let result = restarter.terminateWidgetProcesses(target: productionTarget)

        #expect(result.loadFailureMessage?.isEmpty == false)
        #expect(result.canReloadTimelines == false)
    }

    @Test("does not signal a reused process identifier")
    func doesNotSignalReusedProcessIdentifier() throws {
        let original = identity(
            processIdentifier: 301,
            startTimeSeconds: 10)
        let replacement = identity(
            processIdentifier: 301,
            startTimeSeconds: 11)
        var signals: [Int32] = []

        let terminated = try RunwayWidgetProcessRestarter.terminateProcess(
            original,
            loadIdentity: { _ in replacement },
            sendSignal: { _, signal in
                signals.append(signal)
                return true
            },
            pause: { _ in })

        #expect(signals.isEmpty)
        #expect(terminated == false)
    }

    @Test("waits for the exact process to exit after termination")
    func waitsForExactProcessExit() throws {
        let original = identity(processIdentifier: 302)
        var isRunning = true
        var signals: [Int32] = []

        let terminated = try RunwayWidgetProcessRestarter.terminateProcess(
            original,
            loadIdentity: { _ in isRunning ? original : nil },
            sendSignal: { _, signal in
                signals.append(signal)
                isRunning = false
                return true
            },
            pause: { _ in })

        #expect(terminated)
        #expect(signals == [SIGTERM])
    }

    @Test("forces a widget process that ignores termination")
    func forcesProcessAfterTerminationTimeout() throws {
        let original = identity(processIdentifier: 303)
        var wasKilled = false
        var signals: [Int32] = []

        let terminated = try RunwayWidgetProcessRestarter.terminateProcess(
            original,
            loadIdentity: { _ in wasKilled ? nil : original },
            sendSignal: { _, signal in
                signals.append(signal)
                if signal == SIGKILL { wasKilled = true }
                return true
            },
            pause: { _ in })

        #expect(terminated)
        #expect(signals == [SIGTERM, SIGKILL])
    }

    @Test("expands a full process identifier buffer")
    func expandsFullProcessIdentifierBuffer() throws {
        var populatedCapacities: [Int] = []

        let identifiers = try RunwayWidgetProcessInspector.processIdentifiers {
            buffer,
            capacity in
            guard let buffer else { return 1 }
            populatedCapacities.append(capacity)
            if populatedCapacities.count == 1 {
                for index in 0..<capacity {
                    buffer[index] = pid_t(index + 1)
                }
                return capacity
            }
            buffer[0] = 401
            buffer[1] = 402
            return 2
        }

        #expect(populatedCapacities.count == 2)
        #expect(populatedCapacities[1] == populatedCapacities[0] * 2)
        #expect(identifiers == [401, 402])
    }

    @Test("collects confirmed processes before and after an unknown candidate")
    func collectsConfirmedProcessesAcrossUnknownCandidate() {
        let first = RunwayWidgetProcess(
            identity: identity(processIdentifier: 501),
            signingIdentifier: "com.github.codex-runway.widget")
        let last = RunwayWidgetProcess(
            identity: identity(processIdentifier: 504),
            signingIdentifier: "com.github.codex-runway.widget")

        let result = RunwayWidgetProcessInspector.collectProcessInspections(
            identifiers: [501, 502, 503, 504])
        { process in
            switch process {
            case 501: return first
            case 502: return nil
            case 503: throw POSIXError(.EIO)
            case 504: return last
            default: return nil
            }
        }

        #expect(result.processes.map(\.processIdentifier) == [501, 504])
        #expect(result.failures.map(\.processIdentifier) == [503])
    }

    @Test("recovers the exact widget service from deleted-image launch arguments")
    func recoversSigningIdentifierFromLaunchArguments() throws {
        let productionID = "com.github.codex-runway.widget"
        let launchData = try JSONSerialization.data(withJSONObject: [
            "type": 1,
            "serviceName": productionID,
        ])
        let arguments = [
            "/Applications/CodexRunway.app/Contents/PlugIns/"
                + "CodexRunwayWidget.appex/Contents/MacOS/CodexRunwayWidget",
            "-LaunchArguments",
            launchData.base64EncodedString(),
        ]

        #expect(RunwayWidgetProcessInspector.widgetProcessMatch(
            fromProcessArguments: arguments,
            target: productionTarget) == .target(productionID))
        #expect(RunwayWidgetProcessInspector.widgetProcessMatch(
            fromProcessArguments: ["/private/tmp/CodexRunwayWidget"],
            target: productionTarget) == .nonTarget)

        let invalidLaunchData = try JSONSerialization.data(withJSONObject: [
            "type": 2,
            "serviceName": productionID,
        ])
        #expect(RunwayWidgetProcessInspector.widgetProcessMatch(
            fromProcessArguments: [
                arguments[0],
                "-LaunchArguments",
                invalidLaunchData.base64EncodedString(),
            ],
            target: productionTarget) == .unknown)

        let developmentLaunchData = try JSONSerialization.data(withJSONObject: [
            "type": 1,
            "serviceName": "com.github.codex-runway.widget.swift-dev",
        ])
        #expect(RunwayWidgetProcessInspector.widgetProcessMatch(
            fromProcessArguments: [
                arguments[0],
                "-LaunchArguments",
                developmentLaunchData.base64EncodedString(),
            ],
            target: productionTarget) == .nonTarget)

        let stagingArguments = [
            "/Users/example/Library/Caches/com.github.codex-runway/"
                + "org.sparkle-project.Sparkle/Installation/ABC/CodexRunway.app/"
                + "Contents/PlugIns/CodexRunwayWidget.appex/Contents/MacOS/"
                + "CodexRunwayWidget",
            "-LaunchArguments",
            launchData.base64EncodedString(),
        ]
        #expect(RunwayWidgetProcessInspector.widgetProcessMatch(
            fromProcessArguments: stagingArguments,
            target: productionTarget) == .target(productionID))

        var wrongPathArguments = arguments
        wrongPathArguments[0] = "/private/tmp/CodexRunwayWidget"
        #expect(RunwayWidgetProcessInspector.widgetProcessMatch(
            fromProcessArguments: wrongPathArguments,
            target: productionTarget) == .unknown)
    }

    private func identity(
        processIdentifier: pid_t,
        startTimeSeconds: UInt64 = 1
    ) -> RunwayWidgetProcessIdentity {
        RunwayWidgetProcessIdentity(
            processIdentifier: processIdentifier,
            userIdentifier: 501,
            startTimeSeconds: startTimeSeconds,
            startTimeMicroseconds: 0,
            auditToken: RunwayWidgetProcessAuditToken(
                words: [
                    0, 0, 0, 0,
                    0,
                    UInt32(bitPattern: processIdentifier),
                    0,
                    UInt32(truncatingIfNeeded: startTimeSeconds),
                ]))
    }

    private var productionTarget: RunwayWidgetProcessTarget {
        RunwayWidgetProcessTarget(
            signingIdentifier: "com.github.codex-runway.widget",
            executablePath: "/Applications/CodexRunway.app/Contents/PlugIns/"
                + "CodexRunwayWidget.appex/Contents/MacOS/CodexRunwayWidget",
            sparkleInstallationRootPath: "/Users/example/Library/Caches/"
                + "com.github.codex-runway/org.sparkle-project.Sparkle/Installation")
    }
}
