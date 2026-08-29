[English](./README.md) · [简体中文](./README_ZH.md) · 繁體中文 · [한국어](./README_KO.md) · [日本語](./README_JA.md) · [Русский](./README_RU.md) · [Français](./README_FR.md)

<p align="center">
  <img src="Resources/AppIcon.png" alt="Codex Runway logo" width="128" height="128">
</p>

# Codex Runway

你的 Codex 還可以跑多久？

Codex Runway 是一個原生 macOS 選單列應用程式，幫你在選單列查看 Codex 與 Grok 額度，並提供 Codex 的今日是否重設、reset credits、API 等價成本與本機工作階段能力，以及兩個供應商各自獨立的多帳號管理。

## 亮點

- 選單列查看 Codex 剩餘額度。
- 在常駐的 `Codex | Grok` 頁籤間切換，選單列和右鍵選單同步展示所選供應商。
- 透過官方 CLI chat-proxy 額度介面查看包含額度、產品拆分（Build / Imagine / Chat）、週/月週期、預付餘額和按需使用情況。
- Grok 主面板與 Codex 一致：展示 Token 用量多圖表（熱力圖 / 折線 / 長條）與 API 等價成本（本機工作階段日誌），以及最近對話。
- 管理多個 Grok OAuth / SuperGrok 帳號：隔離登入、匯入目前登入、貼上 Token / JSON、重新整理、別名、排序、刪除和顯式切號。
- 查看 5 小時、每週和附加額度視窗。
- 查看今日速率限制是否已重設（資料來自 [www.codexrunway.com](https://www.codexrunway.com)），並可跳轉到相關公開動態。
- 設定中可開關「今日是否重設」欄目，並單獨設定其重新整理間隔（預設開啟、每 5 分鐘）。
- 管理多個 Codex 帳號：瀏覽器登入、匯入本機 `auth.json`、貼上 token / JSON（含 `/auth/session`）、匯入檔案或 API Key。
- 確認後安全切號，原子寫回 `~/.codex/auth.json`，可選立即重新啟動 Codex，使 CLI / IDE 同步。
- 顯示目前帳號、訂閱類型與到期資訊。
- 用官方週占用率和每日 Credits 推算本週額度，並與歷史推算比較，方便發現是否被下調；設定中可開關，預設開啟。
- 查看 reset credits 數量、狀態和到期時間。
- 查看 API 等價成本與 token 用量：今日、本週期、上週期、本月或自訂範圍；設定可改主彈窗預設範圍。
- 主彈窗配額下方顯示本年 token 用量圖表（熱力圖 / 折線圖 / 長條圖，每日 / 每週 / 累計），設定中可切換樣式或關閉；預設熱力圖。
- 本機工作階段增量索引，加速成本掃描。
- 查看最近 Codex 工作階段、專案、狀態和用量摘要。
- 修復本機工作階段索引。
- 支援淺色、深色、跟隨系統，以及 English、简体中文、繁體中文、한국어、日本語、Русский、Français 介面。
- 支援內建更新檢測。
- 提供 macOS 14+ 桌面小工具：額度總覽、Token 趨勢、關鍵指標和今日重設。

## 截圖

<p align="center">
  <img src="docs/images/1.webp" alt="Codex Runway 配額概覽" width="260">
  <img src="docs/images/2.webp" alt="Codex Runway 重設次數詳情" width="260">
  <img src="docs/images/3.webp" alt="Codex Runway API 等價成本" width="260">
  <img src="docs/images/4.webp" alt="Codex Runway 設定頁面" width="260">
  <img src="docs/images/5.webp" alt="Codex Runway 多帳號" width="260">
  <img src="docs/images/6.webp" alt="Codex Runway Grok 配額" width="260">
</p>

## 安裝

### Homebrew（建議）

透過專案維護的 [Licoy Homebrew Tap](https://github.com/Licoy/homebrew-tap) 安裝：

```bash
brew install --cask licoy/tap/codex-runway
```

Codex Runway 同時支援應用程式內更新；如希望透過 Homebrew 強制檢查並升級，請使用：

```bash
brew upgrade --cask --greedy codex-runway
```

解除安裝應用程式時預設保留設定和託管帳號副本；加入 `--zap` 會同時移除 `~/.codex-runway` 下的資料，但不會刪除官方 `~/.codex`、`~/.grok` 目錄或工作階段：

```bash
brew uninstall --cask codex-runway
brew uninstall --cask --zap codex-runway
```

### 手動安裝

從 [GitHub Releases](https://github.com/Licoy/codex-runway/releases) 下載與你的 Mac 相符的 DMG：

- Apple Silicon：`CodexRunway-macos-arm64.dmg`
- Intel：`CodexRunway-macos-x86_64.dmg`

開啟 DMG 後把 `CodexRunway.app` 拖入 `Applications`，也可以下載同架構的 ZIP 後手動解壓。

### macOS 安全阻擋

目前 Release 是 ad-hoc signed，未 notarized。首次開啟如果提示「無法驗證開發者」或「未經安全驗證」，請按住 Control 點按 `CodexRunway.app`，選擇「打開」，或在「系統設定 > 隱私權與安全性」中點選「仍要打開」。

如果提示「CodexRunway.app 已損壞，無法打開。你應該將它移到垃圾桶」，通常是下載隔離屬性導致的。把 app 放入 `Applications` 後執行：

```bash
xattr -dr com.apple.quarantine /Applications/CodexRunway.app
```

然後再次開啟應用程式。

## 使用前提

- macOS 12+
- 建議已安裝並使用過 Codex
- 可透過本機 `~/.codex/auth.json` 匯入，或在應用程式內新增帳號（瀏覽器登入、貼上憑證、匯入檔案等）
- 使用 Grok 面板前，請先安裝[官方 Grok CLI](https://docs.x.ai/build/overview)：

  ```bash
  curl -fsSL https://x.ai/cli/install.sh | bash
  ```

- Grok 多帳號與額度僅支援 OAuth / SuperGrok 及相容 legacy session。可先執行 `grok login --oauth`，也可在應用程式內登入、匯入目前登入，或貼上 `~/.grok/auth.json` / 憑證 JSON；僅有 API Key 的登入不會加入託管帳號。
- 如果設定了 `GROK_HOME`，應用程式會沿用該目錄；否則使用 `~/.grok`。詳見 [xAI Settings](https://docs.x.ai/build/settings)。

## 本機執行

```bash
swift run CodexRunway
```

在 macOS 14+，該命令會自動建置並註冊獨立的 `Codex Runway Dev` 應用程式和 Widget 延伸功能，然後啟動它；開發應用程式位於 `.build/codex-runway-widget-dev/CodexRunway-dev.app`，可直接從系統小工具庫新增。啟動前請先結束其他正在執行的 Codex Runway 實例。若只需執行未打包的命令列行程，可設定 `CODEX_RUNWAY_DISABLE_DEV_APP=1`。

自檢命令：

```bash
swift run CodexRunway --self-check
```

自檢只讀取本機狀態，不請求網路；它會輸出脫敏的 Codex 診斷，以及 Grok CLI 版本、憑證狀態和帳號身分。任何 token 或 API Key 都不會列印。

## 桌面小工具

桌面小工具要求 macOS 14+。從包含此修復的版本起，正式 Release 和本機開發建置都會包含 Widget 延伸功能。每個小工具可在系統的「編輯小工具」中獨立選擇 Codex、Grok 或兩者；「今日重設」僅支援 Codex。升級後，macOS 會從應用程式套件的 `Contents/PlugIns` 註冊正式版小工具。

`swift run CodexRunway` 使用獨立的 `swift-dev` 識別碼，不會覆蓋現有安裝。也可使用 `.dev` 識別碼手動產生帶小工具的應用程式：

```bash
INCLUDE_WIDGET=1 \
RUNWAY_BUNDLE_ID=com.github.codex-runway.dev \
RUNWAY_APP_GROUP_ID=group.com.github.codex-runway.dev \
RUNWAY_WIDGET_STORAGE_MODE=local \
bash Scripts/package-app.sh
```

產生的應用程式位於 `dist/CodexRunway.app`。包含此修復的正式 Release 和本機 ad-hoc 建置預設從 `~/.codex-runway/widget-snapshot.json` 讀取權限為 `0600` 的版本化衍生快照；已註冊 App Group 的 Developer ID 建置可改用 `RUNWAY_WIDGET_STORAGE_MODE=app-group`。快照不含信箱、帳號 ID、token、認證 JSON 或外部事件原文。後續仍可接入 Developer ID、App Group 註冊與公證。

## 隱私

- token 從本機 `~/.codex/auth.json` 讀取；多帳號憑證僅保存在 `~/.codex-runway/accounts/<id>/auth.json`（目錄 `0700`、檔案 `0600`）。帳號索引 `index.json` 不含 token。
- Grok 官方憑證從 `$GROK_HOME/auth.json` 讀取（未設定時為 `~/.grok/auth.json`）；託管副本保存在 `~/.codex-runway/accounts/grok-<stable-id>/auth.json`（目錄 `0700`、檔案 `0600`），獨立索引 `~/.codex-runway/accounts/grok-index.json` 不含 token。
- Grok 額度使用本機 OAuth 憑證，向官方 CLI chat-proxy 的 `/v1/billing?format=credits` 請求（與本機 Grok CLI 相同的官方介面）。應用程式不讀取瀏覽器 Cookie，也不會用本機工作階段推算偽額度。
- 重新整理 Grok 額度時讀取對應帳號 home 下的 `auth.json`；目前帳號使用官方 `$GROK_HOME`，非目前託管帳號使用隔離帳號目錄，不會寫官方憑證。
- 切換 Grok 帳號只替換官方憑證中的 OAuth / 相容 legacy 登入 scope，保留 API Key 和未知 scope。切換只保證新工作階段使用新帳號；已執行的 Grok 行程不會被強制終止，並可能把舊帳號重新寫回，因此繼續切換前會顯示強警告。
- 使用者主動切號時，才會將選中憑證原子寫回 `~/.codex/auth.json`，以便 Codex CLI / IDE 同步使用。
- 重新整理非目前託管帳號 token 時只更新帳號庫副本，不寫官方 `auth.json`；重新整理目前帳號時同步官方 auth 與副本。
- 無效或 mock 憑證不會寫回官方 `~/.codex/auth.json`。
- access token、refresh token、id token、API key 不會寫入日誌、README、issue 範本或自檢輸出。
- API 等價成本預設來自本機工作階段 JSONL 日誌，並在 `~/.codex-runway/` 下維護本機增量索引等衍生資料；不上傳工作階段內容。
- 訂閱額度推算只把衍生的 Credits 合計與占用率寫入 `~/.codex-runway/quota-estimate-history.json`，不含 token 或金鑰。
- API 等價成本的線上用量只在本機沒有可用 token 資料時作為補全。Token 圖表的「官方統計（多端）」來自目前帳號的官方資料統計，可能延遲或後續修訂；「本機日誌（全部本機工作階段）」掃描本機現有工作階段，歷史記錄可能跨帳號。兩者口徑不同，不能視為包含關係或直接相減。
- 工作階段修復只處理 `~/.codex/session_index.jsonl`，寫入前會建立備份，不刪除工作階段檔案。
- 「今日是否重設」只下載公開狀態源，不附帶 Codex 帳號、token 或本機工作階段內容。
- 更新檢測只存取版本資訊，不上傳 Codex 帳號或工作階段資料。
- 桌面小工具快照儲存僅保存額度、餘額、衍生成本、Token 日序列和重設狀態等非金鑰資料；主應用程式是唯一寫入者，小工具唯讀。

## 資料來源

- **今日是否重設**：資料來自 [https://www.codexrunway.com/api/status.json](https://www.codexrunway.com/api/status.json)，非官方且僅供參考，可能延遲或暫時無法使用。
- **配額 / reset credits / 訂閱額度推算 / Token 用量官方統計 / 部分線上用量**：在你已登入的前提下，透過本機憑證存取官方 ChatGPT / Codex 後端介面；官方 Token 統計僅對應目前帳號，並顯示伺服端統計截至日期。訂閱額度推算非正式：用週占用率和每日 Credits 外推本週額度（1000 Credits ≈ $40，版本 `credits-usd-2026-08-26`）。
- **Grok 額度**：僅由官方 CLI chat-proxy 的 `/v1/billing?format=credits` 回傳（使用本機 OAuth / SuperGrok 登入憑證）。應用程式不提供第二資料源，也不會把 API 帳單或本機工作階段統計混入該額度。
- **Grok API 等價成本 / 本機工作階段**：根據本機 `~/.grok/sessions` 的 `turn_completed` 用量，按官方 xAI Text API 價目（input / cached / output；prompt ≥ 200k 走長上下文價，價格版本 `xai-builtin-2026-08-13`）逐 turn 估算。未知模型不計精確費用。CLI 的 `costUsdTicks` 是訂閱額度口徑，不用作 API 等價。
- **Token 用量本機日誌 / API 等價成本 / 最近工作階段**：預設基於本機 `~/.codex` 工作階段日誌與本機索引計算。本機歷史日誌沒有可靠的帳號歸屬，因此可能包含多個帳號的資料。

## 開發與貢獻

```bash
swift test
swift build
swift build -c release
```

貢獻說明見 [CONTRIBUTORS.md](CONTRIBUTORS.md)。

## 社群支援

- [LinuxDO](https://linux.do/)

## 授權條款

本專案遵循倉庫中的 [LICENSE](LICENSE)。
