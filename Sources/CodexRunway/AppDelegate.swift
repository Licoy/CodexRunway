import AppKit
import CodexRunwayCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: StatusController?
    private var pendingWidgetLinks: [RunwayWidgetDeepLink] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        // LSUIElement apps have no default Edit menu, so ⌘V / ⌘C fail in SwiftUI text fields
        // until we install a minimal main menu that wires standard edit selectors.
        installMainMenu()
        controller = StatusController()
        controller?.start()
        for link in pendingWidgetLinks {
            controller?.openWidget(link)
        }
        pendingWidgetLinks.removeAll()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            guard let link = RunwayWidgetDeepLink(url: url) else { continue }
            if let controller {
                controller.openWidget(link)
            } else {
                pendingWidgetLinks.append(link)
            }
        }
    }

    private func installMainMenu() {
        let mainMenu = NSMenu()

        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        appItem.submenu = appMenu
        appMenu.addItem(
            withTitle: "Quit Codex Runway",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q")

        let editItem = NSMenuItem()
        mainMenu.addItem(editItem)
        let editMenu = NSMenu(title: "Edit")
        editItem.submenu = editMenu
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        NSApp.mainMenu = mainMenu
    }
}
