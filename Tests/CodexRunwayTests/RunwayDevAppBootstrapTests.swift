import Foundation
import Testing
@testable import CodexRunway

@Suite("Runway dev app bootstrap")
struct RunwayDevAppBootstrapTests {
    @Test("swift run relaunches through a registered app host on macOS 14 or newer")
    func relaunchPolicy() {
        let commandBundle = URL(fileURLWithPath: "/tmp/swift-build/debug", isDirectory: true)
        let appBundle = URL(fileURLWithPath: "/tmp/CodexRunway.app", isDirectory: true)

        #expect(RunwayDevAppBootstrap.shouldRelaunch(
            bundleURL: commandBundle,
            operatingSystemMajorVersion: 14,
            isDisabled: false,
            scriptExists: true))
        #expect(!RunwayDevAppBootstrap.shouldRelaunch(
            bundleURL: appBundle,
            operatingSystemMajorVersion: 14,
            isDisabled: false,
            scriptExists: true))
        #expect(!RunwayDevAppBootstrap.shouldRelaunch(
            bundleURL: commandBundle,
            operatingSystemMajorVersion: 13,
            isDisabled: false,
            scriptExists: true))
        #expect(!RunwayDevAppBootstrap.shouldRelaunch(
            bundleURL: commandBundle,
            operatingSystemMajorVersion: 14,
            isDisabled: true,
            scriptExists: true))
    }

    @Test("CLI help lists every CodexRunway flag")
    func cliHelpListsFlags() {
        let help = RunwayCLIHelp.text
        #expect(help.contains("--self-check"))
        #expect(help.contains("--dev-tier-badges"))
        #expect(help.contains("--mock-reset-today="))
        #expect(help.contains("--dump-locale-metrics"))
        #expect(help.contains("--render-reset-today-mock="))
        #expect(help.contains("--render-main-panel-mock="))
        #expect(help.contains("CODEX_RUNWAY_DISABLE_DEV_APP"))
    }

    @Test("bootstrap forwards the built executable as --host-executable")
    func hostExecutableArguments() {
        #expect(RunwayDevAppBootstrap.scriptArguments(
            executable: "/tmp/CodexRunway",
            remaining: ["--dev-tier-badges"]) == [
                "--host-executable",
                "/tmp/CodexRunway",
                "--dev-tier-badges",
            ])
        #expect(RunwayDevAppBootstrap.scriptArguments(
            executable: "/tmp/CodexRunway",
            remaining: []) == [
                "--host-executable",
                "/tmp/CodexRunway",
            ])
    }
}
