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
}
