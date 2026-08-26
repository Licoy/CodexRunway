import Foundation

enum RunwayCLIHelp {
    static let text = """
    Usage: swift run CodexRunway -- [options]
           Scripts/run-dev-app.sh [options]

    Options:
      -h, --help
          Show this help and exit.

      --self-check
          Print redacted local diagnostics and exit. No network.

      --dev-tier-badges
          Show every subscription-tier capsule in the popover.
          Env: CODEX_RUNWAY_DEV_TIER_BADGES=1

      --mock-reset-today=yes|no|scheduled|unknown
          Use a local Reset Today fixture instead of the network.
          Env: CODEX_RUNWAY_MOCK_RESET_TODAY=...

      --dump-locale-metrics <output-directory>
          Write language-picker and panel layout metrics, then exit.

      --render-reset-today-mock=yes|no|scheduled|unknown <output.png>
          Render the Reset Today card to a PNG, then exit.

      --render-main-panel-mock=all|<page>-<light|dark> <output>
          Render the main popover or a detail page, then exit.
          Pages: main, accounts, reset-credits, api-cost, quota-estimate.

    Environment:
      CODEX_RUNWAY_DISABLE_DEV_APP=1
          Skip wrapping into CodexRunway-dev.app (raw swift run process).

    """
}
