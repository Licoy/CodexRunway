import Foundation
import Testing

@Suite("Ad-hoc signing identity")
struct AdHocSigningTests {
    @Test("packaging helper records an identifier designated requirement")
    func packagingHelperRecordsStableRequirement() throws {
        let helper = repositoryRoot
            .appendingPathComponent("Scripts", isDirectory: true)
            .appendingPathComponent("codesign-helpers.sh")
        #expect(FileManager.default.isReadableFile(atPath: helper.path))

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [helper.path, "--self-test"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        process.waitUntilExit()
        let log = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        #expect(process.terminationStatus == 0, Comment(rawValue: log))
    }

    @Test("packaging scripts use the stable-identity helper")
    func packagingScriptsUseStableIdentityHelper() throws {
        let package = try String(contentsOf: repositoryRoot
            .appendingPathComponent("Scripts/package-app.sh"), encoding: .utf8)
        let dev = try String(contentsOf: repositoryRoot
            .appendingPathComponent("Scripts/run-dev-app.sh"), encoding: .utf8)
        let verify = try String(contentsOf: repositoryRoot
            .appendingPathComponent("Scripts/verify-packaged-app.sh"), encoding: .utf8)
        for script in [package, dev] {
            #expect(script.contains("source \"$ROOT/Scripts/codesign-helpers.sh\""))
            #expect(script.contains("runway_codesign"))
        }
        #expect(dev.contains("LOCK=\"$HOME/.codex-runway/codex-runway.lock\""))
        #expect(verify.contains("designated => identifier"))
        #expect(verify.contains("NSAppDataUsageDescription"))
    }

    @Test("Info.plist declares App Data usage text")
    func infoPlistDeclaresAppDataUsage() throws {
        let info = repositoryRoot
            .appendingPathComponent("Resources", isDirectory: true)
            .appendingPathComponent("Info.plist")
        let data = try Data(contentsOf: info)
        let object = try PropertyListSerialization.propertyList(from: data, format: nil)
        let plist = try #require(object as? [String: Any])
        let usage = try #require(plist["NSAppDataUsageDescription"] as? String)
        #expect(!usage.isEmpty)
        #expect(usage.localizedCaseInsensitiveContains("Codex"))
    }

    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
