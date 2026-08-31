import Darwin
import Foundation
import Security

private enum RunwayWidgetSigningIdentifierLookup {
    case found(String)
    case unavailable(OSStatus)
}

enum RunwayWidgetProcessArgumentMatch: Equatable {
    case target(String)
    case nonTarget
    case unknown
}

private struct RunwayWidgetProcessMetadata: Equatable {
    var userIdentifier: uid_t
    var startTimeSeconds: UInt64
    var startTimeMicroseconds: UInt64
}

private struct RunwayWidgetProcessInspectionError: LocalizedError {
    var processIdentifier: pid_t
    var detail: String

    var errorDescription: String? {
        "Could not inspect widget process \(processIdentifier): \(detail)"
    }
}

enum RunwayWidgetProcessInspector {
    typealias ProcessListFetcher = (
        _ buffer: UnsafeMutablePointer<pid_t>?,
        _ capacity: Int
    ) -> Int

    private static let widgetExecutableSuffix =
        "/CodexRunwayWidget.appex/Contents/MacOS/CodexRunwayWidget"

    static func loadRunningProcesses(
        target: RunwayWidgetProcessTarget
    ) throws -> RunwayWidgetProcessInspectionResult {
        let identifiers = try processIdentifiers { buffer, capacity in
            Int(proc_listallpids(
                buffer,
                Int32(capacity * MemoryLayout<pid_t>.stride)))
        }
        return collectProcessInspections(identifiers: identifiers) { process in
            guard processName(for: process) == "CodexRunwayWidget" else { return nil }
            return try loadRunningProcess(process, target: target)
        }
    }

    static func collectProcessInspections(
        identifiers: [pid_t],
        inspect: (pid_t) throws -> RunwayWidgetProcess?
    ) -> RunwayWidgetProcessInspectionResult {
        var result = RunwayWidgetProcessInspectionResult()
        for process in identifiers where process > 0 {
            do {
                if let inspected = try inspect(process) {
                    result.processes.append(inspected)
                }
            } catch {
                result.failures.append(RunwayWidgetProcessInspectionFailure(
                    processIdentifier: process,
                    message: error.localizedDescription))
            }
        }
        return result
    }

    private static func loadRunningProcess(
        _ process: pid_t,
        target: RunwayWidgetProcessTarget
    ) throws -> RunwayWidgetProcess? {
        let identity: RunwayWidgetProcessIdentity
        do {
            guard let loadedIdentity = try processIdentity(
                for: process,
                reportAuditFailure: true)
            else { return nil }
            identity = loadedIdentity
        } catch {
            throw RunwayWidgetProcessInspectionError(
                processIdentifier: process,
                detail: error.localizedDescription)
        }
        guard identity.userIdentifier == geteuid() else { return nil }
        let identifier = try signingIdentifier(
            for: process,
            identity: identity,
            target: target)
        guard let identifier else { return nil }
        guard try processIdentity(for: process) == identity else { return nil }
        return RunwayWidgetProcess(
            identity: identity,
            signingIdentifier: identifier)
    }

    private static func signingIdentifier(
        for process: pid_t,
        identity: RunwayWidgetProcessIdentity,
        target: RunwayWidgetProcessTarget
    ) throws -> String? {
        switch securitySigningIdentifier(for: process) {
        case .found(let signingIdentifier):
            return signingIdentifier
        case .unavailable(let status):
            guard try processIdentity(for: process) == identity else { return nil }
            guard status == errSecErrnoBase + OSStatus(ENOENT) else {
                let message = SecCopyErrorMessageString(status, nil) as String?
                    ?? String(status)
                throw RunwayWidgetProcessInspectionError(
                    processIdentifier: process,
                    detail: message)
            }
            guard let arguments = processArguments(for: process) else {
                throw RunwayWidgetProcessInspectionError(
                    processIdentifier: process,
                    detail: "Could not read deleted-image launch arguments")
            }
            switch widgetProcessMatch(
                fromProcessArguments: arguments,
                target: target)
            {
            case .target(let recovered):
                return recovered
            case .nonTarget:
                return nil
            case .unknown:
                throw RunwayWidgetProcessInspectionError(
                    processIdentifier: process,
                    detail: "Could not verify deleted-image launch arguments")
            }
        }
    }

    static func processIdentifiers(
        fetch: ProcessListFetcher
    ) throws -> [pid_t] {
        errno = 0
        let estimate = fetch(nil, 0)
        guard estimate > 0 else { throw currentPOSIXError() }
        var capacity = max(estimate + 64, 128)
        while true {
            var identifiers = [pid_t](repeating: 0, count: capacity)
            errno = 0
            let count = identifiers.withUnsafeMutableBufferPointer {
                fetch($0.baseAddress, $0.count)
            }
            guard count > 0, count <= capacity else { throw currentPOSIXError() }
            if count < capacity {
                return Array(identifiers.prefix(count))
            }
            guard capacity <= Int.max / 2 else { throw POSIXError(.EOVERFLOW) }
            capacity *= 2
        }
    }

    static func processIdentity(
        for processIdentifier: pid_t,
        reportAuditFailure: Bool = false
    ) throws -> RunwayWidgetProcessIdentity? {
        guard let metadata = try processMetadata(for: processIdentifier),
              metadata.userIdentifier == geteuid()
        else { return nil }
        let auditToken: RunwayWidgetProcessAuditToken?
        do {
            auditToken = try processAuditToken(for: processIdentifier)
        } catch {
            if reportAuditFailure {
                NSLog(
                    "CodexRunway could not acquire atomic identity for widget process %d; using start-time identity: %@",
                    processIdentifier,
                    error.localizedDescription)
            }
            auditToken = nil
        }
        guard try processMetadata(for: processIdentifier) == metadata else { return nil }
        return RunwayWidgetProcessIdentity(
            processIdentifier: processIdentifier,
            userIdentifier: metadata.userIdentifier,
            startTimeSeconds: metadata.startTimeSeconds,
            startTimeMicroseconds: metadata.startTimeMicroseconds,
            auditToken: auditToken)
    }

    private static func processMetadata(
        for processIdentifier: pid_t
    ) throws -> RunwayWidgetProcessMetadata? {
        var information = proc_bsdinfo()
        errno = 0
        let byteCount = proc_pidinfo(
            processIdentifier,
            PROC_PIDTBSDINFO,
            0,
            &information,
            Int32(MemoryLayout<proc_bsdinfo>.size))
        guard byteCount == MemoryLayout<proc_bsdinfo>.size else {
            if Darwin.kill(processIdentifier, 0) != 0, errno == ESRCH { return nil }
            throw currentPOSIXError()
        }
        return RunwayWidgetProcessMetadata(
            userIdentifier: information.pbi_uid,
            startTimeSeconds: information.pbi_start_tvsec,
            startTimeMicroseconds: information.pbi_start_tvusec)
    }

    private static func processAuditToken(
        for processIdentifier: pid_t
    ) throws -> RunwayWidgetProcessAuditToken? {
        var task = mach_port_name_t(MACH_PORT_NULL)
        let taskStatus = task_name_for_pid(mach_task_self_, processIdentifier, &task)
        guard taskStatus == KERN_SUCCESS else {
            if Darwin.kill(processIdentifier, 0) != 0, errno == ESRCH { return nil }
            throw machError(taskStatus)
        }
        defer { mach_port_deallocate(mach_task_self_, task) }

        var rawToken = audit_token_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<audit_token_t>.size / MemoryLayout<natural_t>.size)
        let infoStatus = withUnsafeMutablePointer(to: &rawToken) { pointer in
            pointer.withMemoryRebound(
                to: integer_t.self,
                capacity: Int(count))
            { words in
                task_info(
                    task,
                    task_flavor_t(TASK_AUDIT_TOKEN),
                    words,
                    &count)
            }
        }
        guard infoStatus == KERN_SUCCESS else { throw machError(infoStatus) }
        return RunwayWidgetProcessAuditToken(rawToken: rawToken)
    }

    static func widgetProcessMatch(
        fromProcessArguments arguments: [String],
        target: RunwayWidgetProcessTarget
    ) -> RunwayWidgetProcessArgumentMatch {
        guard let executablePath = arguments.first else { return .unknown }
        let pathMatches = isExpectedWidgetExecutablePath(
            executablePath,
            target: target)
        guard arguments.count == 3,
              arguments[1] == "-LaunchArguments",
              let data = Data(base64Encoded: arguments[2]),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any],
              let serviceName = dictionary["serviceName"] as? String
        else { return pathMatches ? .unknown : .nonTarget }
        guard serviceName == target.signingIdentifier else { return .nonTarget }
        guard pathMatches,
              let type = dictionary["type"] as? NSNumber,
              type.intValue == 1
        else { return .unknown }
        return .target(serviceName)
    }

    private static func isExpectedWidgetExecutablePath(
        _ path: String,
        target: RunwayWidgetProcessTarget
    ) -> Bool {
        guard path.hasPrefix("/") else { return false }
        let standardizedPath = URL(fileURLWithPath: path).standardizedFileURL.path
        if standardizedPath == target.executablePath { return true }
        guard let root = target.sparkleInstallationRootPath else { return false }
        let standardizedRoot = URL(fileURLWithPath: root).standardizedFileURL.path
        return standardizedPath.hasPrefix(standardizedRoot + "/")
            && standardizedPath.hasSuffix(widgetExecutableSuffix)
    }

    private static func processName(for processIdentifier: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 256)
        let length = proc_name(processIdentifier, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(
            decoding: buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) },
            as: UTF8.self)
    }

    private static func securitySigningIdentifier(
        for processIdentifier: pid_t
    ) -> RunwayWidgetSigningIdentifierLookup {
        let attributes = [
            kSecGuestAttributePid as String: NSNumber(value: processIdentifier),
        ] as CFDictionary
        var dynamicCode: SecCode?
        let guestStatus = SecCodeCopyGuestWithAttributes(
            nil,
            attributes,
            [],
            &dynamicCode)
        guard guestStatus == errSecSuccess, let dynamicCode else {
            return .unavailable(guestStatus)
        }
        var staticCode: SecStaticCode?
        let staticStatus = SecCodeCopyStaticCode(dynamicCode, [], &staticCode)
        guard staticStatus == errSecSuccess, let staticCode else {
            return .unavailable(staticStatus)
        }
        var information: CFDictionary?
        let informationStatus = SecCodeCopySigningInformation(
            staticCode,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &information)
        guard informationStatus == errSecSuccess else {
            return .unavailable(informationStatus)
        }
        guard let dictionary = information as? [String: Any],
              let identifier = dictionary[kSecCodeInfoIdentifier as String] as? String
        else { return .unavailable(errSecDecode) }
        return .found(identifier)
    }

    private static func processArguments(for processIdentifier: pid_t) -> [String]? {
        var name = [CTL_KERN, KERN_PROCARGS2, processIdentifier]
        var byteCount = 0
        guard sysctl(&name, u_int(name.count), nil, &byteCount, nil, 0) == 0,
              byteCount >= MemoryLayout<Int32>.size
        else { return nil }
        var bytes = [UInt8](repeating: 0, count: byteCount)
        guard sysctl(&name, u_int(name.count), &bytes, &byteCount, nil, 0) == 0
        else { return nil }
        let argumentCount = bytes.withUnsafeBytes {
            $0.loadUnaligned(as: Int32.self)
        }
        guard argumentCount > 0 else { return nil }
        var cursor = MemoryLayout<Int32>.size
        while cursor < byteCount, bytes[cursor] != 0 { cursor += 1 }
        while cursor < byteCount, bytes[cursor] == 0 { cursor += 1 }
        var arguments: [String] = []
        for _ in 0..<argumentCount {
            let start = cursor
            while cursor < byteCount, bytes[cursor] != 0 { cursor += 1 }
            guard cursor < byteCount else { return nil }
            arguments.append(String(decoding: bytes[start..<cursor], as: UTF8.self))
            cursor += 1
        }
        return arguments
    }

    private static func currentPOSIXError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }

    private static func machError(_ status: kern_return_t) -> NSError {
        NSError(domain: NSMachErrorDomain, code: Int(status))
    }
}
