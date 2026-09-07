import AppKit
import CodexRunwayCore
import Foundation
import Sparkle

@MainActor
final class RunwaySparkleUserDriver: NSObject, SPUUserDriver {
    private let settings: RunwaySettings
    private let statusWindow = RunwayUpdateStatusWindowController()
    private var expectedContentLength: UInt64 = 0
    private var downloadedLength: UInt64 = 0
    var proxyErrorMessage: (() -> String?)?

    init(settings: RunwaySettings) {
        self.settings = settings
    }

    func show(
        _ request: SPUUpdatePermissionRequest,
        reply: @escaping (SUUpdatePermissionResponse) -> Void)
    {
        reply(SUUpdatePermissionResponse(
            automaticUpdateChecks: settings.preferences.automaticallyChecksForUpdates,
            automaticUpdateDownloading: false,
            sendSystemProfile: false))
    }

    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
        showStatus(
            title: .updateChecking,
            progress: nil,
            primary: .cancel)
        {
            cancellation()
            self.statusWindow.close()
        }
    }

    func showUpdateFound(
        with appcastItem: SUAppcastItem,
        state: SPUUserUpdateState,
        reply: @escaping (SPUUserUpdateChoice) -> Void)
    {
        statusWindow.close()
        if appcastItem.isInformationOnlyUpdate {
            showInformationOnlyUpdate(appcastItem, reply: reply)
            return
        }

        let version = appcastItem.displayVersionString
        let messageKey: L10nKey = state.stage == .notDownloaded ? .updateVersionAvailable : .updateDownloadedReady
        let response = alert(
            title: .updateAvailable,
            message: String(format: text(messageKey), version),
            buttons: [
                text(state.stage == .notDownloaded ? .updateDownloadAndInstall : .updateInstallAndRelaunch),
                text(.updateInstallLater),
                text(.updateSkipVersion),
            ])
        switch response {
        case .alertFirstButtonReturn:
            reply(.install)
        case .alertSecondButtonReturn:
            reply(.dismiss)
        default:
            reply(.skip)
        }
    }

    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {}

    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: Error) {}

    func showUpdateNotFoundWithError(_ error: Error, acknowledgement: @escaping () -> Void) {
        statusWindow.close()
        showError(title: .checkForUpdates, error: error)
        acknowledgement()
    }

    func showUpdaterError(_ error: Error, acknowledgement: @escaping () -> Void) {
        statusWindow.close()
        showError(title: .updateCheckFailed, error: error)
        acknowledgement()
    }

    func showDownloadInitiated(cancellation: @escaping () -> Void) {
        expectedContentLength = 0
        downloadedLength = 0
        showStatus(
            title: .updateDownloading,
            progress: 0,
            primary: .cancel)
        {
            cancellation()
            self.statusWindow.close()
        }
    }

    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {
        self.expectedContentLength = expectedContentLength
        updateDownloadProgress()
    }

    func showDownloadDidReceiveData(ofLength length: UInt64) {
        downloadedLength += length
        updateDownloadProgress()
    }

    func showDownloadDidStartExtractingUpdate() {
        showStatus(title: .updateExtracting, progress: nil)
    }

    func showExtractionReceivedProgress(_ progress: Double) {
        statusWindow.update(progress: progress)
    }

    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        var didReply = false
        func finish(_ choice: SPUUserUpdateChoice) {
            guard !didReply else { return }
            didReply = true
            statusWindow.close()
            reply(choice)
        }

        statusWindow.show(
            title: text(.updateReadyToInstall),
            progress: 1,
            primaryTitle: text(.updateInstallAndRelaunch),
            primaryAction: { finish(.install) },
            secondaryTitle: text(.updateInstallLater),
            secondaryAction: { finish(.dismiss) })
    }

    func showInstallingUpdate(
        withApplicationTerminated applicationTerminated: Bool,
        retryTerminatingApplication: @escaping () -> Void)
    {
        showStatus(
            title: .updateInstalling,
            progress: nil,
            primary: applicationTerminated ? nil : .updateInstallAndRelaunch,
            primaryAction: applicationTerminated ? nil : retryTerminatingApplication)
    }

    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) {
        statusWindow.close()
        _ = alert(
            title: .updateInstalled,
            message: text(.updateInstalledMessage),
            buttons: [text(.ok)])
        acknowledgement()
    }

    func dismissUpdateInstallation() {
        statusWindow.close()
    }

    func showUpdateInFocus() {
        statusWindow.focus()
    }

    private func showInformationOnlyUpdate(
        _ appcastItem: SUAppcastItem,
        reply: @escaping (SPUUserUpdateChoice) -> Void)
    {
        let response = alert(
            title: .updateAvailable,
            message: String(format: text(.updateVersionAvailable), appcastItem.displayVersionString),
            buttons: [text(.updateLearnMore), text(.updateInstallLater)])
        if response == .alertFirstButtonReturn, let url = appcastItem.infoURL {
            ExternalURLLauncher.open(url)
        }
        reply(.dismiss)
    }

    private func updateDownloadProgress() {
        guard expectedContentLength > 0 else { return }
        statusWindow.update(progress: Double(downloadedLength) / Double(expectedContentLength))
    }

    private func showStatus(
        title: L10nKey,
        progress: Double?,
        primary: L10nKey? = nil,
        primaryAction: (() -> Void)? = nil)
    {
        statusWindow.show(
            title: text(title),
            progress: progress,
            primaryTitle: primary.map(text),
            primaryAction: primaryAction)
    }

    private func showError(title: L10nKey, error: Error) {
        let message = proxyErrorMessage?() ?? Self.errorMessage(for: error, proxyHint: text(.updateNetworkProxyHint))
        _ = alert(title: title, message: message, buttons: [text(.ok)])
    }

    static func errorMessage(for error: Error, proxyHint: String) -> String {
        let nsError = error as NSError
        let message = nsError.localizedRecoverySuggestion ?? nsError.localizedDescription
        var current: NSError? = nsError
        while let checked = current {
            if checked.domain == NSURLErrorDomain {
                return "\(message)\n\n\(proxyHint)"
            }
            current = checked.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return message
    }

    private func alert(title: L10nKey, message: String, buttons: [String]) -> NSApplication.ModalResponse {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = text(title)
        alert.informativeText = message
        buttons.forEach { alert.addButton(withTitle: $0) }
        return alert.runModal()
    }

    private func text(_ key: L10nKey) -> String {
        settings.l10n.text(key)
    }
}
