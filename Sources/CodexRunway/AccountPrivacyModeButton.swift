import CodexRunwayCore
import SwiftUI

private struct AccountPrivacyModeKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var accountPrivacyMode: Bool {
        get { self[AccountPrivacyModeKey.self] }
        set { self[AccountPrivacyModeKey.self] = newValue }
    }
}

func maskedAccountIdentity(_ value: String, enabled: Bool) -> String {
    enabled ? AccountPrivacyMask.mask(value) : value
}

/// Shared privacy toggle for the main panel header and the popover account toolbar.
struct AccountPrivacyModeButton: View {
    enum Chrome {
        case header
        case toolbar
    }

    var isEnabled: Bool
    var title: String
    var chrome: Chrome
    var action: () -> Void

    @State private var isHovered = false

    private var symbol: String {
        isEnabled ? "eye.slash" : "eye"
    }

    var body: some View {
        switch chrome {
        case .header:
            headerButton
        case .toolbar:
            toolbarButton
        }
    }

    private var headerButton: some View {
        iconButton(width: 26, height: 24, radius: RunwaySurface.radiusControl)
    }

    private var toolbarButton: some View {
        iconButton(width: 32, height: 26, radius: RunwaySurface.radiusRow)
            .pointingHandCursor()
    }

    private func iconButton(width: CGFloat, height: CGFloat, radius: CGFloat) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.body)
                .frame(width: 14, height: 14)
                .foregroundStyle(iconColor)
                .frame(width: width, height: height)
                .background(buttonFill, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
                .contentShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(title)
        .accessibilityLabel(title)
        .accessibilityAddTraits(isEnabled ? .isSelected : [])
        .accessibilityRemoveTraits(isEnabled ? [] : .isSelected)
        .onHover { isHovered = $0 }
    }

    private var iconColor: Color {
        if isEnabled { return Color.accentColor }
        return isHovered ? Color.primary : Color.secondary
    }

    private var buttonFill: Color {
        if isEnabled || isHovered { return RunwaySurface.hoverNeutral }
        return Color.clear
    }
}

private enum SettingsAccountIconMetrics {
    static let width: CGFloat = 26
    static let height: CGFloat = 22
}

/// Fixed-size icon button for the settings accounts toolbar.
struct SettingsAccountIconButton: View {
    var systemImage: String
    var title: String
    var isDisabled: Bool = false
    var isSelected: Bool = false
    var action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            SettingsAccountIconLabel(
                systemImage: systemImage,
                isSelected: isSelected,
                isHovered: isHovered && !isDisabled)
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .help(title)
        .accessibilityLabel(title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityRemoveTraits(isSelected ? [] : .isSelected)
        .opacity(isDisabled ? 0.4 : 1)
        .pointingHandCursor(enabled: !isDisabled)
        .onHover { isHovered = $0 }
    }
}

struct SettingsAccountMenuItem {
    var title: String
    var action: () -> Void
}

/// Same visible chassis as `SettingsAccountIconButton`. A symbol-only SwiftUI menu
/// drops the border, so the click target is an AppKit view that pops the menu.
struct SettingsAccountIconMenu: View {
    var systemImage: String
    var title: String
    var isDisabled: Bool = false
    var items: [SettingsAccountMenuItem]

    @State private var isHovered = false

    var body: some View {
        SettingsAccountIconLabel(
            systemImage: systemImage,
            isHovered: isHovered && !isDisabled)
            .overlay {
                SettingsAccountMenuCatcherView(
                    items: items,
                    isDisabled: isDisabled,
                    help: title,
                    onHover: { isHovered = $0 })
                    .frame(
                        width: SettingsAccountIconMetrics.width,
                        height: SettingsAccountIconMetrics.height)
            }
            .help(title)
            .accessibilityLabel(title)
            .accessibilityAddTraits(.isButton)
            .opacity(isDisabled ? 0.4 : 1)
            .pointingHandCursor(enabled: !isDisabled)
    }
}

private struct SettingsAccountMenuCatcherView: NSViewRepresentable {
    var items: [SettingsAccountMenuItem]
    var isDisabled: Bool
    var help: String
    var onHover: (Bool) -> Void

    func makeNSView(context: Context) -> SettingsAccountMenuCatcher {
        SettingsAccountMenuCatcher()
    }

    func updateNSView(_ view: SettingsAccountMenuCatcher, context: Context) {
        view.items = items
        view.isDisabled = isDisabled
        view.toolTip = help
        view.onHover = onHover
    }
}

@MainActor
private final class SettingsAccountMenuCatcher: NSView {
    var items: [SettingsAccountMenuItem] = []
    var isDisabled = false
    var onHover: ((Bool) -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        guard !isDisabled, !items.isEmpty else { return }
        let menu = NSMenu()
        menu.autoenablesItems = false
        for (index, item) in items.enumerated() {
            let menuItem = NSMenuItem(title: item.title, action: #selector(pick(_:)), keyEquivalent: "")
            menuItem.target = self
            menuItem.tag = index
            menu.addItem(menuItem)
        }
        // y is up; the menu's top edge sits on the button's bottom edge.
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: 0), in: self)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas {
            removeTrackingArea(area)
        }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) {
        guard !isDisabled else { return }
        onHover?(true)
    }

    override func mouseExited(with event: NSEvent) {
        onHover?(false)
    }

    @objc private func pick(_ sender: NSMenuItem) {
        let index = sender.tag
        guard items.indices.contains(index) else { return }
        items[index].action()
    }
}

private struct SettingsAccountIconLabel: View {
    var systemImage: String
    var isSelected: Bool = false
    var isHovered: Bool = false

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
            .frame(width: SettingsAccountIconMetrics.width, height: SettingsAccountIconMetrics.height)
            .background(fill, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(Color(nsColor: .separatorColor).opacity(0.9), lineWidth: 1))
            .contentShape(Rectangle())
    }

    private var fill: Color {
        if isSelected { return Color.accentColor.opacity(0.16) }
        if isHovered { return Color.primary.opacity(0.08) }
        return Color(nsColor: .controlBackgroundColor)
    }
}
