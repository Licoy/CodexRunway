<p align="center">
  <img src="Resources/AppIcon.png" alt="Codex Runway logo" width="128" height="128">
</p>

# Codex Runway

中文 | [English](./README_EN.md)

你的 Codex 还可以跑多久？

Codex Runway 是一个原生 macOS 状态栏应用，帮你在菜单栏查看 Codex 配额、今日是否重置、reset credits、API 等价成本与本机会话，并支持多账号管理、安全切号与内置更新检测。

## 亮点

- 菜单栏查看 Codex 剩余额度。
- 查看 5 小时、每周和附加额度窗口。
- 查看今日速率限制是否已重置（第三方公开状态）；有下次重置窗口时显示倒计时，可跳转相关推文。
- 设置中可开关「今日是否重置」栏目，并单独配置其刷新间隔（默认开启、每 1 小时）。
- 管理多个 Codex 账号：浏览器登录、导入本机 `auth.json`、粘贴 token / JSON（含 `/auth/session`）、导入文件或 API Key。
- 确认后安全切号，原子写回 `~/.codex/auth.json`，可选立即重启 Codex，使 CLI / IDE 同步。
- 显示当前账号、订阅类型与到期信息。
- 查看 reset credits 数量、状态和到期时间。
- 查看 API 等价成本与 token 用量：今日、本周期、上周期、本月或自定义范围；设置可改主弹窗默认范围。
- 主弹窗配额下方显示本年 token 用量图表（热力图 / 折线图 / 柱状图，每日 / 每周 / 累计），设置中可切换样式或关闭；默认热力图。
- 本机会话增量索引，加速成本扫描。
- 查看最近 Codex 会话、项目、状态和用量摘要。
- 修复本机会话索引。
- 支持浅色、深色、跟随系统和中英文界面。
- 支持内置更新检测。

## 截图

<p align="center">
  <img src="docs/images/1.png" alt="Codex Runway 配额概览" width="260">
  <img src="docs/images/2.png" alt="Codex Runway 重置次数详情" width="260">
  <img src="docs/images/3.png" alt="Codex Runway API 等价成本" width="260">
  <img src="docs/images/4.png" alt="Codex Runway 设置页面" width="260">
  <img src="docs/images/5.png" alt="Codex Runway 最近会话" width="260">
</p>

## 安装

从 GitHub Release 下载与你的 Mac 匹配的压缩包：

- Apple Silicon：`CodexRunway-macos-arm64.zip`
- Intel：`CodexRunway-macos-x86_64.zip`

解压后把 `CodexRunway.app` 放到 `Applications` 或任意目录运行。

### macOS 安全阻挡

当前 Release 是 ad-hoc signed，未 notarized。首次打开如果提示“无法验证开发者”或“未经安全验证”，请右键点击 `CodexRunway.app`，选择“打开”，或在“系统设置 > 隐私与安全性”中点击“仍要打开”。

如果提示“CodexRunway.app 已损坏，无法打开。您应该将它移到废纸篓”，通常是下载隔离属性导致的。把 app 放入 `Applications` 后运行：

```bash
xattr -dr com.apple.quarantine /Applications/CodexRunway.app
```

然后再次打开应用。

## 使用前提

- macOS 12+
- 推荐已安装并使用过 Codex
- 可通过本机 `~/.codex/auth.json` 导入，或在应用内添加账号（浏览器登录、粘贴凭据、导入文件等）

## 本地运行

```bash
swift run CodexRunway
```

自检命令：

```bash
swift run CodexRunway --self-check
```

自检会输出本地诊断信息，token 会被 redacted。

## 隐私

- token 从本机 `~/.codex/auth.json` 读取；多账号凭据仅保存在 `~/.codex-runway/accounts/<id>/auth.json`（目录 `0700`、文件 `0600`）。账号索引 `index.json` 不含 token。
- 用户主动切号时，才会将选中凭据原子写回 `~/.codex/auth.json`，以便 Codex CLI / IDE 同步使用。
- 刷新非当前托管账号 token 时只更新账号库副本，不写官方 `auth.json`；刷新当前账号时同步官方 auth 与副本。
- 无效或 mock 凭据不会写回官方 `~/.codex/auth.json`。
- access token、refresh token、id token、API key 不会写入日志、README、issue 模板或自检输出。
- API 等价成本默认来自本机会话 JSONL 日志，并在 `~/.codex-runway/` 下维护本地增量索引等派生数据；不上传会话内容。
- API 等价成本的在线用量只在本地没有可用 token 数据时作为补全；热力图的“全部设备”数据来自官方 Codex 资料统计。
- 会话修复只处理 `~/.codex/session_index.jsonl`，写入前会创建备份，不删除会话文件。
- 更新检测只访问版本信息，不上传 Codex 账号或会话数据。

## 数据来源

- **今日是否重置**：状态来自第三方公开站点 [hascodexratelimitreset.today](https://hascodexratelimitreset.today/) 及其 `api/status` 接口。Codex Runway 仅拉取公开结果，不附带任何 Codex 账号或 token；结果仅供参考，应用不控制也不保证该数据源的准确性与可用性。
- **配额 / reset credits / 热力图全部设备 / 部分在线用量**：在你已登录的前提下，通过本机凭据访问官方 ChatGPT / Codex 后端接口；热力图使用官方资料统计口径。
- **API 等价成本与最近会话**：默认基于本机 `~/.codex` 会话日志与本地索引计算。

## 开发与贡献

```bash
swift test
swift build
swift build -c release
```

贡献说明见 [CONTRIBUTORS.md](CONTRIBUTORS.md)。

## 社区支持

- [LinuxDO](https://linux.do/)

## 许可证

本项目遵循仓库中的 [LICENSE](LICENSE)。
