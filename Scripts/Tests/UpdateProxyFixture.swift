import AppKit
import Foundation
import Sparkle
@testable import CodexRunwayCore

@main
@MainActor
enum UpdateProxyFixtureMain {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let delegate = UpdateProxyFixture()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}

@MainActor
private final class UpdateProxyFixture: NSObject, NSApplicationDelegate, SPUUpdaterDelegate, SPUUserDriver {
    private let root = URL(fileURLWithPath: Bundle.main.object(forInfoDictionaryKey: "FixtureRoot") as! String)
    private var bridge: UpdateProxyBridge?
    private var updater: SPUUpdater?
    private var feed: URL?
    private var received: UInt64 = 0

    func applicationDidFinishLaunching(_ notification: Notification) {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
        record("launched", ["version": version, "pid": String(ProcessInfo.processInfo.processIdentifier)])
        if version == "2" {
            finish(["outcome": "relaunched", "version": version])
            return
        }
        Task {
            do {
                let context = try RunwayNetworkContext(sessionFactory: { configuration, delegate in
                    configuration.protocolClasses = [FixtureURLProtocol.self]
                    configuration.connectionProxyDictionary = [:]
                    configuration.urlCredentialStorage = nil
                    return URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
                })
                let bridge = UpdateProxyBridge()
                try await bridge.start()
                self.bridge = bridge
                feed = try bridge.beginCycle(context: context, appcastURL: FixtureURLProtocol.upstream("appcast.xml"))
                let updater = SPUUpdater(hostBundle: .main, applicationBundle: .main, userDriver: self, delegate: self)
                self.updater = updater
                try updater.start()
                updater.automaticallyChecksForUpdates = false
                updater.automaticallyDownloadsUpdates = false
                updater.checkForUpdates()
            } catch { failed("setup-error", error) }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        record("terminating")
        bridge?.stop()
    }

    func feedURLString(for updater: SPUUpdater) -> String? { feed?.absoluteString }
    func updater(_ updater: SPUUpdater, shouldDownloadReleaseNotesForUpdate item: SUAppcastItem) -> Bool { false }

    func updater(_ updater: SPUUpdater, willDownloadUpdate item: SUAppcastItem, with request: NSMutableURLRequest) {
        do {
            guard let upstream = request.url, let bridge else { throw UpdateProxyBridgeError.unavailable }
            request.url = try bridge.register(upstream)
            record("archive-routed")
        } catch {
            request.url = URL(string: "fixture-invalid://unavailable")!
            failed("routing-error", error)
        }
    }

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor check: SPUUpdateCheck, error: (any Error)?) {
        bridge?.endCycle()
        if let error { record("cycle-error", safeError(error)) }
    }

    func show(_ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void) {
        reply(SUUpdatePermissionResponse(automaticUpdateChecks: false, automaticUpdateDownloading: false, sendSystemProfile: false))
    }

    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) { record("checking") }

    func showUpdateFound(with item: SUAppcastItem, state: SPUUserUpdateState, reply: @escaping (SPUUserUpdateChoice) -> Void) {
        record("update-found", ["version": item.versionString])
        reply(.install)
    }

    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) { record("unexpected-release-notes") }
    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: Error) { failed("release-notes-error", error) }

    func showUpdateNotFoundWithError(_ error: Error, acknowledgement: @escaping () -> Void) {
        failed("no-update", error)
        acknowledgement()
    }

    func showUpdaterError(_ error: Error, acknowledgement: @escaping () -> Void) {
        failed("update-error", error)
        acknowledgement()
    }

    func showDownloadInitiated(cancellation: @escaping () -> Void) { record("downloading") }
    func showDownloadDidReceiveExpectedContentLength(_ length: UInt64) { record("archive-length", ["length": String(length)]) }
    func showDownloadDidReceiveData(ofLength length: UInt64) { received += length }
    func showDownloadDidStartExtractingUpdate() { record("extracting", ["received": String(received)]) }
    func showExtractionReceivedProgress(_ progress: Double) { /* The fixture has no progress UI. */ }

    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        record("ready-to-install")
        reply(.install)
    }

    func showInstallingUpdate(withApplicationTerminated terminated: Bool, retryTerminatingApplication: @escaping () -> Void) {
        record("installing", ["terminated": String(terminated)])
    }

    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) {
        record("installed", ["relaunched": String(relaunched)])
        acknowledgement()
    }

    func dismissUpdateInstallation() { record("dismissed") }

    private func failed(_ event: String, _ error: Error) {
        let fields = safeError(error)
        record(event, fields)
        finish(fields.merging(["outcome": "error", "event": event]) { _, new in new })
    }

    private func safeError(_ error: Error) -> [String: String] {
        let value = error as NSError
        var result = ["domain": value.domain, "code": String(value.code)]
        var underlying = value.userInfo[NSUnderlyingErrorKey] as? NSError
        for index in 0..<8 {
            guard let current = underlying else { break }
            result["underlying-\(index)"] = "\(current.domain):\(current.code)"
            underlying = current.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return result
    }

    private func finish(_ result: [String: String]) {
        do {
            let data = try JSONSerialization.data(withJSONObject: result, options: .sortedKeys)
            try data.write(to: root.appendingPathComponent("result.json"), options: .atomic)
        } catch {
            NSLog("Update proxy fixture could not write its result.")
        }
        NSApp.terminate(nil)
    }

    private func record(_ event: String, _ fields: [String: String] = [:]) {
        do {
            let object = fields.merging(["event": event, "at": String(Date().timeIntervalSince1970)]) { _, new in new }
            var data = try JSONSerialization.data(withJSONObject: object, options: .sortedKeys)
            data.append(10)
            let handle = try FileHandle(forWritingTo: root.appendingPathComponent("events.jsonl"))
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } catch {
            NSLog("Update proxy fixture could not write an event.")
        }
    }
}

/// All upstream URLs are consumed by this fixture; unmatched URLs fail instead of reaching the network.
private final class FixtureURLProtocol: URLProtocol {
    static func upstream(_ name: String) -> URL {
        URL(string: "https://github.com/Licoy/codex-runway/releases/download/fixture/\(name)")!
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            guard let url = request.url,
                  [Self.upstream("appcast.xml"), Self.upstream("UpdateProxyFixture.zip")].contains(url),
                  let root = Bundle.main.object(forInfoDictionaryKey: "FixtureRoot") as? String
            else { throw URLError(.unsupportedURL) }
            let body = try Data(contentsOf: URL(fileURLWithPath: root).appendingPathComponent(url.lastPathComponent), options: .mappedIfSafe)
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Length": String(body.count)])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            for start in stride(from: 0, to: body.count, by: 65_536) {
                client?.urlProtocol(self, didLoad: body.subdata(in: start..<min(start + 65_536, body.count)))
            }
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() { /* Each fixture response is synchronously bounded by its file size. */ }
}
