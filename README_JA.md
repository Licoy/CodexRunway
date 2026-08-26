[English](./README.md) · [简体中文](./README_ZH.md) · [繁體中文](./README_ZH_HANT.md) · [한국어](./README_KO.md) · 日本語 · [Русский](./README_RU.md) · [Français](./README_FR.md)

<p align="center">
  <img src="Resources/AppIcon.png" alt="Codex Runway logo" width="128" height="128">
</p>

# Codex Runway

Codex はあとどれだけ走り続けられるでしょうか？

Codex Runway は、Codex と Grok のクォータを確認するネイティブ macOS メニューバーアプリです。Codex の本日リセット状況、reset credits、API 換算コスト、ローカルセッションに加え、プロバイダーごとの複数アカウント管理を提供します。

## ハイライト

- メニューバーから Codex の残りクォータを確認します。
- 常時表示の `Codex | Grok` タブで切り替え、メニューバーとコンテキストメニューは選択中のプロバイダーに従います。
- 公式 CLI chat-proxy 課金 API で、含まれる Grok クォータ、製品内訳（Build / Imagine / Chat）、週/月周期、プリペイド残高、オンデマンド使用量を表示します。
- Grok パネルでも Codex と同じ Token 使用量マルチチャート（ヒートマップ / 折れ線 / 棒）と API 換算コスト、Grok CLI ログの最近のローカルセッションを使います。
- 複数の Grok OAuth / SuperGrok アカウントを、隔離サインイン、現在のログイン読み込み、トークン/JSON 貼り付け、更新、エイリアス、並べ替え、削除、明示的な切り替えで管理します。
- 5 時間、週間、追加のクォータウィンドウを表示します。
- 本日 Codex のレート制限がリセットされたかを確認します（データは [www.codexrunway.com](https://www.codexrunway.com)、関連する公開投稿へのリンク付き）。
- 設定で「本日リセット済み？」セクションの表示と、専用の更新間隔を切り替えます（既定はオン、1 時間ごと）。
- 複数の Codex アカウントを管理します：ブラウザサインイン、ローカル `auth.json` の読み込み、トークン/JSON の貼り付け（`/auth/session` 含む）、ファイル読み込み、API キー追加。
- 確認後に `~/.codex/auth.json` を原子的に書き換えて安全に切り替え、CLI / IDE を揃えるために Codex をすぐ再起動できます。
- 現在のアカウント、サブスクリプション階層、有効期限を表示します。
- 公式の週次使用率と日次 Credits から今週の枠を推定し、過去の推定と比較して引き下げを確認します。設定で切り替えられ、既定はオンです。
- リセットクレジットの数、状態、期限を表示します。
- 今日、現在のサイクル、前のサイクル、今月、またはカスタム範囲の API 換算コストとトークン使用量を表示します。既定の範囲は設定で変更できます。
- メインパネルのクォータ下に年初来のトークン使用量チャート（ヒートマップ / 折れ線 / 棒、日次 / 週次 / 累計）を表示します。スタイルはパネルと設定で切り替えられ、既定はヒートマップです。オフにもできます。
- ローカルの増分セッションインデックスでコストスキャンを速くします。
- 最近の Codex セッション、プロジェクト、状態、使用量の概要を表示します。
- ローカルセッションインデックスを修復します。
- ライト、ダーク、システムの外観と English、简体中文、繁體中文、한국어、日本語、Русский、Français をサポートします。
- 組み込みのアップデート確認をサポートします。
- macOS 14+ のデスクトップウィジェットで、クォータ概要、トークン推移、主要指標、本日リセット状態を提供します。

## スクリーンショット

<p align="center">
  <img src="docs/images/1.webp" alt="Codex Runway クォータ概要" width="260">
  <img src="docs/images/2.webp" alt="Codex Runway リセットクレジット詳細" width="260">
  <img src="docs/images/3.webp" alt="Codex Runway API 換算コスト" width="260">
  <img src="docs/images/4.webp" alt="Codex Runway 設定ページ" width="260">
  <img src="docs/images/5.webp" alt="Codex Runway 複数アカウント" width="260">
  <img src="docs/images/6.webp" alt="Codex Runway Grok クォータ" width="260">
</p>

## インストール

### Homebrew（推奨）

プロジェクトが保守する [Licoy Homebrew Tap](https://github.com/Licoy/homebrew-tap) からインストールします：

```bash
brew install --cask licoy/tap/codex-runway
```

Codex Runway はアプリ内アップデートにも対応します。Homebrew にアップグレードの確認とインストールを強制するには：

```bash
brew upgrade --cask --greedy codex-runway
```

アンインストール時は既定で設定と管理アカウントのコピーを残します。`--zap` を付けると `~/.codex-runway` のデータも消しますが、公式の `~/.codex` や `~/.grok` ディレクトリやセッションは削除しません：

```bash
brew uninstall --cask codex-runway
brew uninstall --cask --zap codex-runway
```

### 手動インストール

[GitHub Releases](https://github.com/Licoy/codex-runway/releases) から Mac に合う DMG を入手します：

- Apple Silicon: `CodexRunway-macos-arm64.dmg`
- Intel: `CodexRunway-macos-x86_64.dmg`

DMG を開き、`CodexRunway.app` を `Applications` にドラッグするか、同じアーキテクチャの ZIP を展開します。

### macOS のセキュリティブロック

現在のリリースは ad-hoc signed で、notarized されていません。開発者を確認できない、または悪意のあるソフトウェアの検査がされていないと出る場合は、`CodexRunway.app` を Control クリックして「開く」を選ぶか、システム設定 > プライバシーとセキュリティで「このまま開く」をクリックします。

`CodexRunway.app` が壊れているのでゴミ箱へ、と出る場合は、たいていダウンロード隔離属性です。アプリを `Applications` に置いたあと、次を実行します：

```bash
xattr -dr com.apple.quarantine /Applications/CodexRunway.app
```

その後、アプリを再度開きます。

## 要件

- macOS 12+
- この Mac に Codex がインストールされ、使われていることを推奨します
- ローカルの `~/.codex/auth.json` から読み込むか、アプリ内でアカウントを追加します（ブラウザサインイン、資格情報の貼り付け、ファイル読み込みなど）
- Grok パネルを使う前に、[公式 Grok CLI](https://docs.x.ai/build/overview) をインストールしてください：

  ```bash
  curl -fsSL https://x.ai/cli/install.sh | bash
  ```

- Grok のアカウント管理と課金は OAuth / SuperGrok および互換レガシーセッションのみ対応です。`grok login --oauth` を実行するか、アプリからサインイン、現在のログイン読み込み、`~/.grok/auth.json` / 資格情報 JSON の貼り付けを使います。API キーのみの資格情報は管理アカウントに追加しません。
- `GROK_HOME` が設定されていればそのディレクトリを使い、なければ `~/.grok` を使います。[xAI Settings](https://docs.x.ai/build/settings) を参照してください。

## ローカル実行

```bash
swift run CodexRunway
```

macOS 14+ では、このコマンドが独立した `Codex Runway Dev` アプリと Widget 拡張をビルドして登録し、起動します。開発アプリは `.build/codex-runway-widget-dev/CodexRunway-dev.app` にあり、システムのウィジェットギャラリーから直接追加できます。先に他の Codex Runway インスタンスを終了してください。ウィジェットなしの未パッケージのコマンドラインプロセスだけが必要なときは `CODEX_RUNWAY_DISABLE_DEV_APP=1` を設定します。

セルフチェック：

```bash
swift run CodexRunway --self-check
```

セルフチェックはローカル状態だけを読み、ネットワーク要求はしません。伏せ字にした Codex 診断と、Grok CLI のバージョン、資格情報の状態、アカウント識別を出力します。トークンと API キーは決して表示しません。

## デスクトップウィジェット

デスクトップウィジェットは macOS 14 以降が必要です。この修正を含むバージョンから、公開リリースとローカル開発ビルドの両方に Widget 拡張が含まれます。各ウィジェットは「ウィジェットを編集」で Codex、Grok、または両方を独立して選べます。本日リセットは Codex 専用です。アップグレード後、macOS はアプリの `Contents/PlugIns` から本番ウィジェットを登録します。

`swift run CodexRunway` は独立した `swift-dev` 識別子を使い、既存インストールを置き換えません。`.dev` 識別子でウィジェット付きアプリを手動パッケージすることもできます：

```bash
INCLUDE_WIDGET=1 \
RUNWAY_BUNDLE_ID=com.github.codex-runway.dev \
RUNWAY_APP_GROUP_ID=group.com.github.codex-runway.dev \
RUNWAY_WIDGET_STORAGE_MODE=local \
bash Scripts/package-app.sh
```

アプリは `dist/CodexRunway.app` に書き出されます。この修正を含む公開リリースとローカル ad-hoc ビルドは、権限 `0600` の読み取り専用バージョン付きスナップショット `~/.codex-runway/widget-snapshot.json` を使います。登録済み App Group のある Developer ID ビルドは `RUNWAY_WIDGET_STORAGE_MODE=app-group` にできます。スナップショットにメール、アカウント ID、トークン、認証 JSON、外部イベント原文は含まれません。Developer ID 署名、App Group 登録、公証は今後の配布作業として残っています。

## プライバシー

- トークンはローカルの `~/.codex/auth.json` から読みます。複数アカウントの資格情報は `~/.codex-runway/accounts/<id>/auth.json` にだけ保存します（ディレクトリ `0700`、ファイル `0600`）。アカウント索引 `index.json` にトークンは含まれません。
- 公式 Grok 資格情報は `$GROK_HOME/auth.json`（未設定時は `~/.grok/auth.json`）から読みます。管理コピーは `~/.codex-runway/accounts/grok-<stable-id>/auth.json`（ディレクトリ `0700`、ファイル `0600`）に置き、別の `~/.codex-runway/accounts/grok-index.json` にトークンは含まれません。
- Grok クォータはローカル OAuth 資格情報で公式 CLI chat-proxy の `/v1/billing?format=credits`（Grok CLI と同じ公式 API）に要求します。アプリはブラウザ Cookie を読まず、ローカルセッションから偽のクォータを推定しません。
- 現在の Grok アカウントを更新している間、公式 CLI がトークンをローテーションすることがあります。アプリはその結果の公式資格情報を、その管理アカウントにだけ反映します。現在でないアカウントは隔離された `GROK_HOME` を使い、公式資格情報は書きません。
- Grok アカウント切り替えは、公式資格情報の OAuth / 互換レガシーログインスコープだけを置き換え、API キーと未知スコープは残します。切り替えが保証されるのは新しいセッションだけです。実行中の Grok プロセスは終了されず、前のアカウントを書き戻すことがあるため、続行前に強い警告を出します。
- 公式の `~/.codex/auth.json` は、アカウント切り替えを確認したときだけ原子的に上書きし、Codex CLI / IDE を同期します。
- 非アクティブな管理アカウントの更新はライブラリコピーだけを更新し、公式 `auth.json` は書きません。アクティブアカウントの更新は公式 auth とライブラリコピーを揃えます。
- 無効または mock の資格情報は公式の `~/.codex/auth.json` に書き戻しません。
- アクセストークン、リフレッシュトークン、ID トークン、API キーはログ、README、issue テンプレート、セルフチェック出力に書きません。
- API 換算コストは既定でローカルセッション JSONL ログから計算し、`~/.codex-runway/` にローカル増分インデックスなどの派生データを置きます。セッション内容はアップロードしません。
- 週次クォータ推定は派生した Credits 合計と使用率だけを `~/.codex-runway/quota-estimate-history.json` に保存します。トークンや鍵は含みません。
- オンライン使用量は、ローカルトークンデータがないときだけ API 換算コストを補います。チャートの「公式統計（全デバイス）」は現在アカウントのプロフィール統計で、遅延や改訂があり得ます。「ローカルログ（全セッション）」はこの Mac 上のセッションをスキャンし、履歴は複数アカウントにまたがることがあります。両者は部分集合関係ではなく、引き算してはいけません。
- セッション修復は `~/.codex/session_index.jsonl` だけを扱い、書き込み前にバックアップを作り、セッションファイルは削除しません。
- 「本日リセット済み？」は公開ステータスフィードだけをダウンロードします。Codex アカウント、トークン、ローカルセッション内容は送りません。
- アップデート確認はバージョン情報だけを要求します。Codex アカウントとセッションデータはアップロードしません。
- ウィジェットスナップショットには、秘密でない派生クォータ、残高、コスト、日次トークン、リセット状態だけが含まれます。書き込みはメインアプリのみで、ウィジェットは読み取り専用です。

## データソース

- **本日リセット済み？**: データは [https://www.codexrunway.com/api/status.json](https://www.codexrunway.com/api/status.json) からです。非公式で参考用であり、遅延や一時的な欠落があり得ます。
- **クォータ / reset credits / 週次クォータ推定 / 公式トークン使用量 / 一部のオンライン使用量**: サインイン済みなら、ローカル資格情報で公式 ChatGPT / Codex バックエンド API に要求します。公式トークン使用量は現在アカウントに属し、バックエンド統計日を表示します。週次クォータ推定は非公式で、週次使用率と日次 Credits から外挿します（1000 Credits ≈ $40、バージョン `credits-usd-2026-08-26`）。
- **Grok クォータ**: ローカル OAuth / SuperGrok ログインで公式 CLI chat-proxy の `/v1/billing?format=credits` だけが返します。第二のデータ源はなく、API 請求やローカルセッション統計をこのクォータに混ぜません。
- **Grok API 換算コスト / ローカルセッション**: ローカル `~/.grok/sessions` の `turn_completed` 使用量を、公式 xAI Text API 価格（input / cached / output、prompt ≥ 200k は長文脈料金、価格版 `xai-builtin-2026-08-13`）で turn ごとに見積もります。未知モデルを正確な費用として作りません。CLI の `costUsdTicks` はサブスクリプションクレジット会計であり、API 換算には使いません。
- **ローカルログのトークン使用量 / API 換算コスト / 最近のセッション**: 既定ではローカル `~/.codex` セッションログとローカルインデックスから計算します。過去のローカルログには信頼できるアカウント帰属がないため、複数アカウントを含むことがあります。

## 開発と貢献

```bash
swift test
swift build
swift build -c release
```

貢献については [CONTRIBUTORS.md](CONTRIBUTORS.md) を参照してください。

## コミュニティ

- [LinuxDO](https://linux.do/)

## ライセンス

このプロジェクトはリポジトリの [LICENSE](LICENSE) に従います。
