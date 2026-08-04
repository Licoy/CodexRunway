<p align="center">
  <img src="Resources/AppIcon.png" alt="Codex Runway logo" width="128" height="128">
</p>

# Codex Runway

[中文](README.md) | English

How much longer can your Codex keep running?

Codex Runway is a native macOS menu bar app for checking Codex and Grok quota. It also provides Codex reset-today status, reset credits, API-equivalent cost, and local sessions, with separate multi-account management for each provider.

## Highlights

- Check remaining Codex quota from the menu bar.
- Switch from the always-visible `Codex | Grok` tabs; the menu bar and context menu follow the selected provider.
- View included Grok quota, product breakdown (Build / Imagine / Chat), weekly/monthly periods, prepaid balance, and on-demand usage via the official CLI chat-proxy billing API.
- On the Grok panel, reuse the same Token Usage multi-chart (heatmap / line / bar) and API Equivalent Cost modules as Codex, plus recent local sessions from Grok CLI logs.
- Manage multiple Grok OAuth / SuperGrok accounts with isolated sign-in, current-login import, paste token/JSON, refresh, aliases, ordering, removal, and explicit switching.
- View 5-hour, weekly, and additional quota windows.
- See whether Codex rate limits have reset today (data from [www.codexrunway.com](https://www.codexrunway.com)), with a link to the related public post.
- Toggle the “reset today?” section in settings and configure its own refresh interval (on by default, every 1 hour).
- Manage multiple Codex accounts: browser sign-in, import local `auth.json`, paste token/JSON (including `/auth/session`), import files, or add an API key.
- Switch accounts safely after confirmation by atomically writing `~/.codex/auth.json`, with an optional Codex restart so CLI / IDE stay in sync.
- Show the current account, subscription tier, and expiration.
- View reset credit count, status, and expiration time.
- View API-equivalent cost and token usage for today, the current cycle, the previous cycle, this month, or a custom range; the default range is configurable in settings.
- Show a year-to-date token usage chart under quota on the main panel (heatmap / line / bar; daily / weekly / cumulative); style is switchable in the panel and settings, heatmap by default; can be turned off.
- Use a local incremental session index for faster cost scans.
- View recent Codex sessions, projects, status, and usage summaries.
- Repair the local session index.
- Support light, dark, system appearance, Chinese, and English.
- Support built-in update checks.

## Screenshots

<p align="center">
  <img src="docs/images/1.png" alt="Codex Runway quota overview" width="260">
  <img src="docs/images/2.png" alt="Codex Runway reset credits details" width="260">
  <img src="docs/images/3.png" alt="Codex Runway API-equivalent cost" width="260">
  <img src="docs/images/4.png" alt="Codex Runway setting page" width="260">
  <img src="docs/images/5.png" alt="Codex Runway sessions" width="260">
</p>

## Installation

### Homebrew (recommended)

Install from the [project-maintained Licoy Homebrew Tap](https://github.com/Licoy/homebrew-tap):

```bash
brew install --cask licoy/tap/codex-runway
```

Codex Runway also supports in-app updates. To force Homebrew to check and install an upgrade, use:

```bash
brew upgrade --cask --greedy codex-runway
```

Uninstalling keeps settings and managed account copies by default. Adding `--zap` also removes data under `~/.codex-runway`, but does not delete the official `~/.codex` or `~/.grok` directories or sessions:

```bash
brew uninstall --cask codex-runway
brew uninstall --cask --zap codex-runway
```

### Manual installation

Download the matching DMG from [GitHub Releases](https://github.com/Licoy/codex-runway/releases):

- Apple Silicon: `CodexRunway-macos-arm64.dmg`
- Intel: `CodexRunway-macos-x86_64.dmg`

Open the DMG and drag `CodexRunway.app` into `Applications`, or download and unpack the ZIP for the same architecture.

### macOS Security Blocks

Current releases are ad-hoc signed and not notarized. If macOS says the developer cannot be verified or the app was not checked for malicious software, right-click `CodexRunway.app` and choose Open, or go to System Settings > Privacy & Security and click Open Anyway.

If macOS says `CodexRunway.app` is damaged and should be moved to the Trash, it is usually the download quarantine attribute. After placing the app in `Applications`, run:

```bash
xattr -dr com.apple.quarantine /Applications/CodexRunway.app
```

Then open the app again.

## Requirements

- macOS 12+
- Codex installed and used on this Mac is recommended
- Import from local `~/.codex/auth.json`, or add accounts in the app (browser sign-in, paste credentials, import files, and more)
- Before using the Grok panel, install the [official Grok CLI](https://docs.x.ai/build/overview):

  ```bash
  curl -fsSL https://x.ai/cli/install.sh | bash
  ```

- Grok account management and billing support OAuth / SuperGrok and compatible legacy sessions only. Run `grok login --oauth`, sign in from the app, import the current login, or paste `~/.grok/auth.json` / credential JSON. API-key-only credentials are not added as managed accounts.
- When `GROK_HOME` is set, the app uses that directory; otherwise it uses `~/.grok`. See [xAI Settings](https://docs.x.ai/build/settings).

## Run Locally

```bash
swift run CodexRunway
```

Self-check:

```bash
swift run CodexRunway --self-check
```

The self-check reads local state only and makes no network request. It prints redacted Codex diagnostics plus the Grok CLI version, credential status, and account identity. Tokens and API keys are never printed.

## Privacy

- Tokens are read from local `~/.codex/auth.json`; multi-account credentials are stored only under `~/.codex-runway/accounts/<id>/auth.json` (directory mode `0700`, file mode `0600`). The account index `index.json` never contains tokens.
- Official Grok credentials are read from `$GROK_HOME/auth.json` (or `~/.grok/auth.json` when unset). Managed copies live at `~/.codex-runway/accounts/grok-<stable-id>/auth.json` with directory mode `0700` and file mode `0600`; the separate `~/.codex-runway/accounts/grok-index.json` contains no tokens.
- Grok quota is fetched with the local OAuth credential against the official CLI chat-proxy `/v1/billing?format=credits` endpoint (the same official API the Grok CLI uses). The app does not read browser cookies or infer fake quota from local sessions.
- While refreshing the current Grok account, the official CLI may rotate tokens; the app mirrors the resulting official credentials only to that managed account. Non-current accounts use an isolated `GROK_HOME` and never write the official credentials.
- A Grok account switch replaces only OAuth / compatible legacy login scopes in the official credentials while preserving API-key and unknown scopes. A switch is guaranteed only for new sessions. Running Grok processes are not terminated and may write the previous account back, so the app shows a strong warning before continuing.
- Official `~/.codex/auth.json` is overwritten only when you confirm an account switch (atomic write), so Codex CLI / IDE stay in sync.
- Refreshing a non-active managed account updates only its library copy, not official `auth.json`. Refreshing the active account keeps the official auth file and the library copy in sync.
- Invalid or mock credentials are never written back to official `~/.codex/auth.json`.
- Access tokens, refresh tokens, ID tokens, and API keys must not be written to logs, README files, issue templates, or self-check output.
- API-equivalent cost is computed from local session JSONL logs by default, with derived data such as a local incremental index under `~/.codex-runway/`. Session contents are not uploaded.
- Online usage supplements API-equivalent cost only when local token data is unavailable. The chart’s “Official stats (all devices)” series comes from current-account profile statistics and may lag or be revised; “Local logs (all sessions)” scans the sessions present on this Mac and historical entries may span accounts. The two series are not a subset relationship and should not be subtracted.
- Session repair only touches `~/.codex/session_index.jsonl`, creates a backup before writing, and never deletes session files.
- “Reset today?” only downloads the public status feed. It sends no Codex account, token, or local session content.
- Update checks request only version information. Codex account and session data are not uploaded.

## Data sources

- **Reset today?**: Data comes from [https://www.codexrunway.com/api/status.json](https://www.codexrunway.com/api/status.json). Unofficial and advisory only; may be delayed or temporarily unavailable.
- **Quota / reset credits / official token usage / some online usage**: When signed in, requests use your local credentials against official ChatGPT / Codex backend APIs. Official token usage belongs to the current account and shows the backend statistics date.
- **Grok quota**: Returned only by the official CLI chat-proxy `/v1/billing?format=credits` endpoint using a local OAuth / SuperGrok login. There is no secondary data source, and API billing or local-session statistics are not mixed into this quota.
- **Local-log token usage / API-equivalent cost / recent sessions**: Computed by default from local `~/.codex` session logs and the local index. Historical local logs have no reliable account attribution, so they may include multiple accounts.

## Development and Contribution

```bash
swift test
swift build
swift build -c release
```

See [CONTRIBUTORS.md](CONTRIBUTORS.md) for contribution notes.

## License

This project follows the repository [LICENSE](LICENSE).
