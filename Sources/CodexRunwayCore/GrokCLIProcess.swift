import Darwin
import Foundation

final class GrokRPCProcess: @unchecked Sendable {
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let lock = NSLock()
    private var bufferedOutput = Data()
    private var forceKillScheduled = false

    init(executableURL: URL, environment: [String: String], homeURL: URL) {
        process.executableURL = executableURL
        process.arguments = ["agent", "stdio"]
        process.environment = mergedGrokEnvironment(environment, homeURL: homeURL)
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
    }

    func fetchBilling(
        initializeTimeout: TimeInterval,
        requestTimeout: TimeInterval) async throws -> GrokQuotaSnapshot
    {
        try launch()
        defer { terminate() }
        _ = try await request(
            id: 1,
            method: "initialize",
            params: initializeParameters,
            timeout: initializeTimeout)
        let response = try await request(
            id: 2,
            method: "x.ai/billing",
            params: [:],
            timeout: requestTimeout).value
        guard let result = response["result"] else {
            throw GrokCLIError.malformedResponse("missing result")
        }
        let data = try JSONSerialization.data(withJSONObject: result)
        return try GrokQuotaSnapshot.decodeBillingResponse(from: data)
    }

    private var initializeParameters: [String: Any] {
        [
            "protocolVersion": 1,
            "clientCapabilities": [
                "fs": ["readTextFile": false, "writeTextFile": false],
                "terminal": false,
            ],
        ]
    }

    private func request(
        id: Int,
        method: String,
        params: [String: Any],
        timeout: TimeInterval) async throws -> RPCMessage
    {
        let requestData = try encodedRequest(id: id, method: method, params: params)
        return try await withProcessTimeout(seconds: timeout, operation: method, terminate: terminate) {
            try await runBlocking {
                try self.sendRequest(requestData)
                return RPCMessage(value: try self.readResponse(id: id))
            }
        }
    }

    private func launch() throws {
        do {
            try process.run()
        } catch {
            throw GrokCLIError.launchFailed(error.localizedDescription)
        }
    }

    private func encodedRequest(id: Int, method: String, params: [String: Any]) throws -> Data {
        let payload: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id,
            "method": method,
            "params": params,
        ]
        var data = try JSONSerialization.data(withJSONObject: payload, options: [.withoutEscapingSlashes])
        data.append(0x0A)
        return data
    }

    private func sendRequest(_ data: Data) throws {
        try input.fileHandleForWriting.write(contentsOf: data)
    }

    private func readResponse(id: Int) throws -> [String: Any] {
        while true {
            let line = try readLine()
            guard let message = try JSONSerialization.jsonObject(with: line) as? [String: Any] else {
                throw GrokCLIError.malformedResponse("JSON-RPC message is not an object")
            }
            guard jsonRPCID(message["id"]) == id else { continue }
            if let error = message["error"] as? [String: Any] {
                throw Self.requestError(error)
            }
            return message
        }
    }

    private func readLine() throws -> Data {
        while true {
            if let newline = bufferedOutput.firstIndex(of: 0x0A) {
                let line = bufferedOutput[..<newline]
                bufferedOutput.removeSubrange(...newline)
                if line.isEmpty { continue }
                return Data(line)
            }
            let chunk = output.fileHandleForReading.availableData
            guard !chunk.isEmpty else {
                throw GrokCLIError.unexpectedEOF
            }
            bufferedOutput.append(chunk)
        }
    }

    private func terminate() {
        let processIdentifier: Int32? = lock.withLock {
            try? input.fileHandleForWriting.close()
            guard process.isRunning else { return nil }
            process.terminate()
            guard !forceKillScheduled else { return nil }
            forceKillScheduled = true
            return process.processIdentifier
        }
        guard let processIdentifier else { return }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + .milliseconds(250)) {
            self.forceKillIfNeeded(processIdentifier)
        }
    }

    private func forceKillIfNeeded(_ processIdentifier: Int32) {
        lock.withLock {
            guard process.isRunning, process.processIdentifier == processIdentifier else { return }
            _ = Darwin.kill(processIdentifier, SIGKILL)
        }
    }

    private static func requestError(_ value: [String: Any]) -> GrokCLIError {
        let message = (value["message"] as? String) ?? "unknown JSON-RPC error"
        let detail = value["data"] as? String
        let lowered = [message, detail].compactMap { $0 }.joined(separator: " ").lowercased()
        if lowered.contains("authentication required")
            || lowered.contains("not authenticated")
            || lowered.contains("grok login")
        {
            return .authenticationRequired
        }
        let safeMessage = String(message.replacingOccurrences(of: "\n", with: " ").prefix(500))
        return .requestFailed(safeMessage)
    }

    private struct RPCMessage: @unchecked Sendable {
        var value: [String: Any]
    }
}

final class GrokCommandProcess: @unchecked Sendable {
    private let process = Process()
    private let output: Pipe?
    private let lock = NSLock()
    private var forceKillScheduled = false

    init(
        executableURL: URL,
        arguments: [String],
        environment: [String: String],
        homeURL: URL?,
        capturesOutput: Bool)
    {
        let output = capturesOutput ? Pipe() : nil
        self.output = output
        process.executableURL = executableURL
        process.arguments = arguments
        process.environment = mergedGrokEnvironment(environment, homeURL: homeURL)
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output ?? FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
    }

    func run(timeout: TimeInterval, operation: String) async throws -> Data {
        do {
            try process.run()
        } catch {
            throw GrokCLIError.launchFailed(error.localizedDescription)
        }
        defer { terminate() }
        return try await withProcessTimeout(seconds: timeout, operation: operation, terminate: terminate) {
            try await runBlocking {
                self.waitForExit()
                let data = self.output?.fileHandleForReading.readDataToEndOfFile() ?? Data()
                guard self.process.terminationStatus == 0 else {
                    throw GrokCLIError.processFailed(exitCode: self.process.terminationStatus)
                }
                return data
            }
        }
    }

    private func waitForExit() {
        while process.isRunning {
            Thread.sleep(forTimeInterval: 0.01)
        }
    }

    private func terminate() {
        let processIdentifier: Int32? = lock.withLock {
            guard process.isRunning else { return nil }
            process.terminate()
            guard !forceKillScheduled else { return nil }
            forceKillScheduled = true
            return process.processIdentifier
        }
        guard let processIdentifier else { return }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + .milliseconds(250)) {
            self.forceKillIfNeeded(processIdentifier)
        }
    }

    private func forceKillIfNeeded(_ processIdentifier: Int32) {
        lock.withLock {
            guard process.isRunning, process.processIdentifier == processIdentifier else { return }
            _ = Darwin.kill(processIdentifier, SIGKILL)
        }
    }
}

private func mergedGrokEnvironment(_ overrides: [String: String], homeURL: URL?) -> [String: String] {
    var environment = ProcessInfo.processInfo.environment
    environment.merge(overrides) { _, override in override }
    if let homeURL {
        environment["GROK_HOME"] = homeURL.path
    }
    return environment
}

private func jsonRPCID(_ value: Any?) -> Int? {
    if let value = value as? Int { return value }
    return (value as? NSNumber)?.intValue
}

private func runBlocking<T: Sendable>(_ operation: @escaping @Sendable () throws -> T) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                continuation.resume(returning: try operation())
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}

private func withProcessTimeout<T: Sendable>(
    seconds: TimeInterval,
    operation: String,
    terminate: @escaping @Sendable () -> Void,
    body: @escaping @Sendable () async throws -> T) async throws -> T
{
    try await withTaskCancellationHandler {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await body() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
                terminate()
                throw GrokCLIError.timeout(operation: operation)
            }
            do {
                guard let result = try await group.next() else {
                    throw GrokCLIError.timeout(operation: operation)
                }
                group.cancelAll()
                return result
            } catch {
                group.cancelAll()
                if Task.isCancelled {
                    terminate()
                    throw CancellationError()
                }
                throw error
            }
        }
    } onCancel: {
        terminate()
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
