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
        guard let target = RunwayWidgetProcessRestarter
            .bundledWidgetTarget(in: .main)
        else {
            let isPackagedApplication = Bundle.main.bundleURL.pathExtension == "app"
            if isPackagedApplication {
                NSLog("CodexRunway could not identify the bundled widget extension.")
            }
            finishLaunching(initialWidgetReloadAllowed: !isPackagedApplication)
            return
        }
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                RunwayWidgetProcessRestarter
                    .terminateLiveWidgetProcesses(target: target)
            }.value
            finishLaunching(initialWidgetReloadAllowed: reportWidgetRestart(result))
        }
    }

    private func finishLaunching(initialWidgetReloadAllowed: Bool) {
        controller = StatusController(
            initialWidgetReloadAllowed: initialWidgetReloadAllowed)
        controller?.start()
        for link in pendingWidgetLinks {
            controller?.openWidget(link)
        }
        pendingWidgetLinks.removeAll()
    }

    private func reportWidgetRestart(
        _ result: RunwayWidgetProcessTerminationResult
    ) -> Bool {
        if let message = result.loadFailureMessage {
            NSLog("CodexRunway could not inspect widget processes: %@", message)
        }
        for failure in result.failures {
            NSLog(
                "CodexRunway could not restart widget process %d: %@",
                failure.processIdentifier,
                failure.message)
        }
        if !result.terminatedProcessIdentifiers.isEmpty {
            NSLog(
                "CodexRunway restarted %d widget process(es) before timeline reload.",
                result.terminatedProcessIdentifiers.count)
        }
        return result.canReloadTimelines
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
            withTitle: "Quit CodexRunway",
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
