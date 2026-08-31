import AppKit
import Foundation

@MainActor
final class RunwayUpdateStatusWindowController: NSWindowController {
    private let titleLabel = NSTextField(labelWithString: "")
    private let progress = NSProgressIndicator()
    private let primaryButton = NSButton()
    private let secondaryButton = NSButton()
    private var primaryAction: (() -> Void)?
    private var secondaryAction: (() -> Void)?

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 150),
            styleMask: [.titled],
            backing: .buffered,
            defer: false)
        window.title = "CodexRunway"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        configureContent()
    }

    required init?(coder: NSCoder) {
        nil
    }

    func show(
        title: String,
        progress progressValue: Double?,
        primaryTitle: String? = nil,
        primaryAction: (() -> Void)? = nil,
        secondaryTitle: String? = nil,
        secondaryAction: (() -> Void)? = nil)
    {
        titleLabel.stringValue = title
        configureProgress(progressValue)
        configure(button: primaryButton, title: primaryTitle)
        configure(button: secondaryButton, title: secondaryTitle)
        self.primaryAction = primaryAction
        self.secondaryAction = secondaryAction
        focus()
    }

    func update(progress value: Double) {
        progress.isIndeterminate = false
        progress.doubleValue = min(1, max(0, value))
    }

    func focus() {
        guard let window else { return }
        NSApp.activate(ignoringOtherApps: true)
        window.center()
        window.makeKeyAndOrderFront(nil)
    }

    private func configureContent() {
        titleLabel.font = .boldSystemFont(ofSize: 18)
        progress.minValue = 0
        progress.maxValue = 1

        primaryButton.target = self
        primaryButton.action = #selector(primaryPressed)
        primaryButton.bezelStyle = .rounded
        secondaryButton.target = self
        secondaryButton.action = #selector(secondaryPressed)
        secondaryButton.bezelStyle = .rounded

        let buttons = NSStackView(views: [secondaryButton, primaryButton])
        buttons.orientation = .horizontal
        buttons.spacing = 8
        buttons.alignment = .centerY

        let stack = NSStackView(views: [titleLabel, progress, buttons])
        stack.orientation = .vertical
        stack.spacing = 16
        stack.edgeInsets = NSEdgeInsets(top: 22, left: 24, bottom: 20, right: 24)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let contentView = NSView()
        window?.contentView = contentView
        contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            stack.topAnchor.constraint(equalTo: contentView.topAnchor),
            stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
        ])
    }

    private func configureProgress(_ value: Double?) {
        progress.isIndeterminate = value == nil
        if let value {
            progress.stopAnimation(nil)
            progress.doubleValue = min(1, max(0, value))
        } else {
            progress.startAnimation(nil)
        }
    }

    private func configure(button: NSButton, title: String?) {
        button.isHidden = title == nil
        button.title = title ?? ""
        button.isEnabled = title != nil
    }

    @objc private func primaryPressed() {
        primaryAction?()
    }

    @objc private func secondaryPressed() {
        secondaryAction?()
    }
}
