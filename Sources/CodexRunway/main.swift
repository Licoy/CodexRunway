import AppKit
import CodexRunwayCore

if CommandLine.arguments.contains("--self-check") {
    SelfCheck.run()
    exit(0)
}

// Dev helper: `--dev-tier-badges` (or CODEX_RUNWAY_DEV_TIER_BADGES=1) shows every
// subscription tier capsule + expiry phase chips in the main popover. Example:
//   swift run CodexRunway -- --dev-tier-badges

// Dev helper: render the rate-limit-reset card with mock data to a PNG.
// Example: CodexRunway --render-reset-today-mock=yes-countdown /tmp/reset-yes.png
if let renderIndex = CommandLine.arguments.firstIndex(where: { $0.hasPrefix("--render-reset-today-mock=") }) {
    let renderFlag = CommandLine.arguments[renderIndex]
    let value = String(renderFlag.dropFirst("--render-reset-today-mock=".count))
    guard let kind = RateLimitResetTodaySnapshot.DevMockKind.parse(value) else {
        fputs("usage: --render-reset-today-mock=yes|yes-countdown|no <output.png>\n", stderr)
        exit(2)
    }
    let pathIndex = CommandLine.arguments.index(after: renderIndex)
    guard pathIndex < CommandLine.arguments.endIndex else {
        fputs("usage: --render-reset-today-mock=yes|yes-countdown|no <output.png>\n", stderr)
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
