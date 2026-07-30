import AppKit
import CodexRunwayCore

@MainActor
extension StatusController {
    func installStatusBarView() {
        guard let button = statusItem.button else { return }
        button.title = ""
        statusBarView.translatesAutoresizingMaskIntoConstraints = false
        button.addSubview(statusBarView)
        NSLayoutConstraint.activate([
            statusBarView.leadingAnchor.constraint(equalTo: button.leadingAnchor),
            statusBarView.trailingAnchor.constraint(equalTo: button.trailingAnchor),
            statusBarView.topAnchor.constraint(equalTo: button.topAnchor),
            statusBarView.bottomAnchor.constraint(equalTo: button.bottomAnchor),
        ])
        updateStatusBarView()
    }

    func updateStatusBarView() {
        let state = StatusBarContentState(
            configuration: StatusBarContentState.Configuration(
                preferences: settings.preferences,
                language: settings.l10n.language),
            content: StatusBarContentState.Content(
                text: model.statusText,
                meters: model.quotaMeters,
                displayMinute: Int(Date().timeIntervalSince1970 / 60)))
        let didChange = statusBarView.update(state)
        guard didChange else { return }
        statusItem.length = statusBarView.preferredWidth
        let quotaDetails = model.quotaMeters
            .map { "\($0.title): \($0.remainingPercent)%" }
            .joined(separator: " · ")
        statusItem.button?.toolTip = quotaDetails.isEmpty
            ? "Codex Runway · \(model.statusText)"
            : "Codex Runway · \(model.statusText)\n\(quotaDetails)"
    }
}
