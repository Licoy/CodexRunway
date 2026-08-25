import Foundation

enum RunwayDevAppBootstrap {
    static func shouldRelaunch(
        bundleURL: URL,
        operatingSystemMajorVersion: Int,
        isDisabled: Bool,
        scriptExists: Bool
    ) -> Bool {
        bundleURL.pathExtension.lowercased() != "app"
            && operatingSystemMajorVersion >= 14
            && !isDisabled
            && scriptExists
    }

    static func relaunchIfNeeded(
        arguments: [String] = CommandLine.arguments,
        bundle: Bundle = .main,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) throws -> Bool {
        let script = sourceRoot
            .appendingPathComponent("Scripts", isDirectory: true)
            .appendingPathComponent("run-dev-app.sh", isDirectory: false)
        let disabled = environment["CODEX_RUNWAY_DISABLE_DEV_APP"] == "1"
        guard shouldRelaunch(
            bundleURL: bundle.bundleURL,
            operatingSystemMajorVersion: ProcessInfo.processInfo.operatingSystemVersion.majorVersion,
            isDisabled: disabled,
            scriptExists: fileManager.isExecutableFile(atPath: script.path))
        else { return false }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [script.path]
            + scriptArguments(
                executable: executablePath(arguments[0]),
                remaining: Array(arguments.dropFirst()))
        process.standardOutput = FileHandle.standardOutput
        process.standardError = FileHandle.standardError
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw RunwayDevAppBootstrapError(status: process.terminationStatus)
        }
        return true
    }

    static func scriptArguments(executable: String, remaining: [String]) -> [String] {
        ["--host-executable", executable] + remaining
    }

    private static var sourceRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private static func executablePath(_ argument: String) -> String {
        if argument.hasPrefix("/") { return argument }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
            .appendingPathComponent(argument)
            .standardizedFileURL.path
    }
}

private struct RunwayDevAppBootstrapError: LocalizedError {
    var status: Int32

    var errorDescription: String? {
        "Could not prepare Codex Runway Dev (exit \(status))."
    }
}
