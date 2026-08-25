import AppKit
import CodexRunwayCore

if CommandLine.arguments.contains(where: { $0 == "--help" || $0 == "-h" }) {
    print(RunwayCLIHelp.text, terminator: "")
    exit(0)
}

if CommandLine.arguments.contains("--self-check") {
    await SelfCheck.run()
    exit(0)
}

if let dumpIndex = CommandLine.arguments.firstIndex(of: "--dump-locale-metrics") {
    let pathIndex = CommandLine.arguments.index(after: dumpIndex)
    guard pathIndex < CommandLine.arguments.endIndex else {
        fputs("usage: --dump-locale-metrics <output-directory>\n", stderr)
        exit(2)
    }
    let directory = CommandLine.arguments[pathIndex]
    do {
        try FileManager.default.createDirectory(
            atPath: directory,
            withIntermediateDirectories: true)
        var lines: [String] = [
            "compactCap=\(LanguagePickerSizing.compactCap)",
            "minimumWidth=\(LanguagePickerSizing.minimumWidth)",
            "horizontalChrome=\(LanguagePickerSizing.horizontalChrome)",
            "longestItem=Simplified Chinese width=\(LanguagePickerSizing.measuredTitleWidth("Simplified Chinese"))",
        ]
        for preference in LanguagePreference.explicitCases {
            let title = preference.menuTitle(uiLanguage: .english)
            let width = LanguagePickerSizing.controlWidth(selectedTitle: title)
            lines.append("\(preference.rawValue)\ttitle=\(title)\twidth=\(width)")
        }
        let widthsURL = URL(fileURLWithPath: directory)
            .appendingPathComponent("language-picker-widths.txt")
        try (lines.joined(separator: "\n") + "\n").write(to: widthsURL, atomically: true, encoding: .utf8)
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        try MainPanelMockRender.writeLayoutDump(
            to: URL(fileURLWithPath: directory).appendingPathComponent("panel-layout").path)
        exit(0)
    } catch {
        fputs("dump failed: \(error.localizedDescription)\n", stderr)
        exit(1)
    }
}

// Dev helper: `--dev-tier-badges` (or CODEX_RUNWAY_DEV_TIER_BADGES=1) shows every
// subscription tier capsule + expiry phase chips in the main popover. Example:
//   swift run CodexRunway -- --dev-tier-badges

// Dev helper: render the rate-limit-reset card with mock data to a PNG.
// Example: CodexRunway --render-reset-today-mock=scheduled /tmp/reset-scheduled.png
if let renderIndex = CommandLine.arguments.firstIndex(where: { $0.hasPrefix("--render-reset-today-mock=") }) {
    let renderFlag = CommandLine.arguments[renderIndex]
    let value = String(renderFlag.dropFirst("--render-reset-today-mock=".count))
    guard let kind = RateLimitResetTodaySnapshot.DevMockKind.parse(value) else {
        fputs("usage: --render-reset-today-mock=yes|no|scheduled|unknown <output.png>\n", stderr)
        exit(2)
    }
    let pathIndex = CommandLine.arguments.index(after: renderIndex)
    guard pathIndex < CommandLine.arguments.endIndex else {
        fputs("usage: --render-reset-today-mock=yes|no|scheduled|unknown <output.png>\n", stderr)
        exit(2)
    }
    let path = CommandLine.arguments[pathIndex]
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    do {
        try RateLimitResetTodayMockRender.write(kind: kind, to: path)
        exit(0)
    } catch {
        fputs("render failed: \(error.localizedDescription)\n", stderr)
        exit(1)
    }
}

// Dev helper: render the main popover (or a detail page) with mock data to PNGs.
// Example: CodexRunway --render-main-panel-mock=all /tmp/panel-shots
//          CodexRunway --render-main-panel-mock=main-dark /tmp/panel-dark.png
if let renderIndex = CommandLine.arguments.firstIndex(where: { $0.hasPrefix("--render-main-panel-mock=") }) {
    let value = String(CommandLine.arguments[renderIndex].dropFirst("--render-main-panel-mock=".count))
    let pathIndex = CommandLine.arguments.index(after: renderIndex)
    guard pathIndex < CommandLine.arguments.endIndex else {
        fputs("usage: --render-main-panel-mock=all|<page>-<light|dark> <output>\n", stderr)
        exit(2)
    }
    let path = CommandLine.arguments[pathIndex]
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    do {
        if value == "all" {
            try MainPanelMockRender.writeAll(to: path)
        } else {
            // "<page>-<scheme>", where page itself may contain dashes (reset-credits).
            guard
                let splitIndex = value.lastIndex(of: "-"),
                let appearance = MainPanelMockRender.Appearance(rawValue: String(value[value.index(after: splitIndex)...])),
                let page = MainPanelMockRender.Page(rawValue: String(value[..<splitIndex]))
            else {
                fputs("usage: --render-main-panel-mock=all|<page>-<light|dark> <output>\n", stderr)
                exit(2)
            }
            try MainPanelMockRender.write(page: page, appearance: appearance, language: .simplifiedChinese, to: path)
        }
        exit(0)
    } catch {
        fputs("render failed: \(error.localizedDescription)\n", stderr)
        exit(1)
    }
}

do {
    if try RunwayDevAppBootstrap.relaunchIfNeeded() {
        exit(0)
    }
} catch {
    fputs("development app bootstrap failed: \(error.localizedDescription)\n", stderr)
    exit(1)
}

guard let instanceGuard = try? SingleInstanceGuard.acquire() else {
    exit(0)
}

private let delegate = AppDelegate()
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
app.delegate = delegate
withExtendedLifetime(instanceGuard) {
    app.run()
}
