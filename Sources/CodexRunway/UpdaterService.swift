import AppKit
import CodexRunwayCore
import Foundation
import Sparkle

@MainActor
final class UpdaterService: NSObject, SPUUpdaterDelegate {
    private let settings: RunwaySettings
    private var updater: SPUUpdater?
    private var userDriver: RunwaySparkleUserDriver?
    private var proxyBridge: UpdateProxyBridge?
    private var proxyPreparation: Task<Void, Never>?
    private var cycleFeedURL: URL?
    private var cycleContext: RunwayNetworkContext?
    private var stopped = false
    private static let automaticCheckInterval: TimeInterval = 3_600

    init(settings: RunwaySettings) {
        self.settings = settings
        super.init()
        prepareUpdater()
    }

    func applyPreferences() {
        updater?.automaticallyDownloadsUpdates = false
        updater?.automaticallyChecksForUpdates = settings.preferences.automaticallyChecksForUpdates
        updater?.updateCheckInterval = Self.automaticCheckInterval
        prepareUpdater()
    }

    func stop() {
        stopped = true
        proxyPreparation?.cancel()
        proxyPreparation = nil
        cycleFeedURL = nil
        cycleContext = nil
        proxyBridge?.stop()
        proxyBridge = nil
    }

    func checkForUpdates() {
        prepareUpdater()
        if isAppBundle, hasSparklePublicKey, updater == nil {
            showAlert(title: settings.l10n.text(.updateCheckFailed), message: settings.l10n.text(.updateProxyUnavailable))
            return
        }
        switch installReadiness {
        case .ready:
            break
        case .developmentMode:
            showAlert(
                title: settings.l10n.text(.updateCheckFailed),
                message: settings.l10n.text(.updateUnavailableInDevelopment))
            return
        case .signingKeyMissing:
            showAlert(
                title: settings.l10n.text(.updateCheckFailed),
                message: settings.l10n.text(.updateSigningKeyMissing))
            return
        }

        updater?.checkForUpdates()
    }

    func feedURLString(for updater: SPUUpdater) -> String? {
        (cycleFeedURL ?? Self.appcastURL).absoluteString
    }

    func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        // Sparkle can restart its driver without finishing the update cycle.
        guard cycleContext == nil else { return }
        proxyBridge?.clearFailure()
        do {
            let context = try RunwayNetwork.context()
            if context.configuration.mode != .system {
                guard let proxyBridge, proxyBridge.isReady else { throw UpdateProxyBridgeError.unavailable }
                cycleFeedURL = try proxyBridge.beginCycle(context: context, appcastURL: Self.appcastURL)
            }
            cycleContext = context
        } catch {
            throw NSError(domain: "CodexRunway.UpdateProxy", code: 1, userInfo: [
                NSLocalizedDescriptionKey: settings.l10n.text(.updateProxyUnavailable),
            ])
        }
    }

    func updater(_ updater: SPUUpdater, shouldDownloadReleaseNotesForUpdate updateItem: SUAppcastItem) -> Bool {
        false
    }

    func updater(_ updater: SPUUpdater, willDownloadUpdate item: SUAppcastItem, with request: NSMutableURLRequest) {
        guard cycleFeedURL != nil else { return }
        do {
            guard let upstream = request.url, let proxyBridge else { throw UpdateProxyBridgeError.unavailable }
            request.url = try proxyBridge.register(upstream)
        } catch {
            proxyBridge?.recordFailure(.invalidUpdateURL)
            // Sparkle rejects unsupported schemes before making a request; never leave the remote URL in place.
            request.url = URL(string: "codex-runway-invalid://update-proxy-unavailable")!
        }
    }

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: (any Error)?) {
        cycleFeedURL = nil
        cycleContext = nil
        proxyBridge?.endCycle()
    }

    private func prepareUpdater() {
        guard !stopped, isAppBundle, hasSparklePublicKey, proxyPreparation == nil else { return }
        let context: RunwayNetworkContext
        do { context = try RunwayNetwork.context() } catch {
            NSLog("CodexRunway: update network configuration is unavailable.")
            return
        }
        guard context.configuration.mode != .system, proxyBridge?.isReady != true else {
            startUpdaterIfNeeded()
            return
        }
        proxyPreparation = Task { [weak self] in
            guard let self else { return }
            defer { proxyPreparation = nil }
            let bridge = proxyBridge ?? UpdateProxyBridge()
            do {
                try await bridge.start()
                try Task.checkCancellation()
                proxyBridge = bridge
                if updater == nil { startUpdaterIfNeeded() }
                else { updater?.resetUpdateCycle() }
            } catch {
                NSLog("CodexRunway: could not start the update proxy listener.")
                bridge.stop()
                // A later explicit settings change or manual check can prepare again; no direct fallback.
                proxyBridge = nil
            }
        }
    }

    private func startUpdaterIfNeeded() {
        guard updater == nil else { return }
        do { try configureSparkle() } catch {
            showAlert(title: settings.l10n.text(.updateCheckFailed), message: error.localizedDescription)
            return
        }
        updater?.automaticallyDownloadsUpdates = false
        updater?.automaticallyChecksForUpdates = settings.preferences.automaticallyChecksForUpdates
        updater?.updateCheckInterval = Self.automaticCheckInterval
        checkForUpdatesOnLaunch()
    }

    private func configureSparkle() throws {
        guard isAppBundle, hasSparklePublicKey else { return }
        let userDriver = RunwaySparkleUserDriver(settings: settings)
        userDriver.proxyErrorMessage = { [weak self] in
            guard let self, let error = proxyBridge?.lastError else { return nil }
            return settings.l10n.text(error.l10nKey)
        }
        let updater = SPUUpdater(
            hostBundle: .main,
            applicationBundle: .main,
            userDriver: userDriver,
            delegate: self)
        try updater.start()
        self.userDriver = userDriver
        self.updater = updater
    }

    private func showAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: settings.l10n.text(.ok))
        alert.runModal()
    }

    private var hasSparklePublicKey: Bool {
        UpdateInstallEnvironment.hasValidSparklePublicKey(sparklePublicKey)
    }

    private var installReadiness: UpdateInstallReadiness {
        installEnvironment.readiness
    }

    private var installEnvironment: UpdateInstallEnvironment {
        UpdateInstallEnvironment(
            bundlePathExtension: Bundle.main.bundleURL.pathExtension,
            sparklePublicKey: sparklePublicKey,
            hasUpdater: updater != nil)
    }

    private func checkForUpdatesOnLaunch() {
        guard installEnvironment.shouldCheckForUpdatesOnLaunch(
            automaticallyChecksForUpdates: settings.preferences.automaticallyChecksForUpdates)
        else { return }
        updater?.checkForUpdatesInBackground()
    }

    private var isAppBundle: Bool {
        Bundle.main.bundleURL.pathExtension.lowercased() == "app"
    }

    private var sparklePublicKey: String? {
        Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String
    }

    private static var architecture: String {
        #if arch(arm64)
        "arm64"
        #else
        "x86_64"
        #endif
    }

    private static var appcastURL: URL {
        URL(string: "https://github.com/Licoy/codex-runway/releases/latest/download/appcast-\(architecture).xml")!
    }
}
