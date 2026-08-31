import AppKit
import CodexRunwayCore

extension StatusController {
    func populateMenu(_ menu: NSMenu) {
        let l10n = settings.l10n
        menu.removeAllItems()
        let providerName = model.selectedProvider == .codex
            ? l10n.text(.providerCodex)
            : l10n.text(.providerGrok)
        menu.addItem(disabledMenuItem("CodexRunway · \(providerName) · \(model.selectedStatusText)"))
        addSection(
            model.selectedProvider == .codex ? l10n.text(.quota) : l10n.text(.grokIncludedQuota),
            text: model.selectedQuotaText,
            lines: model.selectedQuotaLines,
            to: menu)
        if model.selectedProvider == .grok {
            addSharedMenuActions(to: menu, l10n: l10n)
            menu.addItem(NSMenuItem.separator())
            menu.addItem(menuItem(l10n.text(.quit), action: #selector(quit)))
            return
        }
        if settings.preferences.showsRateLimitResetToday {
            addSection(
                l10n.text(.rateLimitResetToday),
                text: model.rateLimitResetTodayText,
                lines: model.rateLimitResetTodayLines,
                to: menu)
        }
        addSection(l10n.text(.resetCredits), text: model.resetCreditsText, lines: model.resetCreditLines, to: menu)
        addSection(l10n.text(.apiCost), text: model.costText, lines: model.costLines, to: menu)
        addSection(l10n.text(.sessionRepair), text: model.sessionText, lines: model.sessionLines, to: menu)
        addSection(l10n.text(.recentSessions), text: "\(model.recentSessions.count)", lines: model.recentSessionLines, to: menu)
        addSharedMenuActions(to: menu, l10n: l10n)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(menuItem(l10n.text(.repairIndex), action: #selector(repairFromMenu)))
        menu.addItem(menuItem(l10n.text(.codexFolder), action: #selector(openCodexFolder)))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(menuItem(l10n.text(.quit), action: #selector(quit)))
    }

    private func addSharedMenuActions(to menu: NSMenu, l10n: L10n) {
        menu.addItem(NSMenuItem.separator())
        menu.addItem(menuItem(l10n.text(.showDetails), action: #selector(showDetailsFromMenu)))
        menu.addItem(menuItem(l10n.text(.openDetailsWindow), action: #selector(openDetailsWindowFromMenu)))
        menu.addItem(menuItem(l10n.text(.openControlPanel), action: #selector(openControlPanelFromMenu)))
        menu.addItem(menuItem(l10n.text(.refresh), action: #selector(refreshFromMenu)))
        menu.addItem(menuItem(l10n.text(.checkForUpdates), action: #selector(checkForUpdatesFromMenu)))
    }

    private func addSection(_ title: String, text: String, lines: [RunwayModel.DetailLine], to menu: NSMenu) {
        menu.addItem(NSMenuItem.separator())
        menu.addItem(disabledMenuItem("\(title): \(text)"))
        for line in lines.prefix(8) {
            menu.addItem(disabledMenuItem("  \(line.title): \(line.value)"))
        }
    }

    private func disabledMenuItem(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: Self.menuTitle(title), action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private static func menuTitle(_ value: String) -> String {
        value.count > 96 ? String(value.prefix(93)) + "..." : value
    }

    private func menuItem(_ title: String, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }
}
