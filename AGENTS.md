# AGENTS.md

## 项目定位

CodexRunway 是一个原生 macOS 状态栏应用，用 Swift 编写，用于读取本机 Codex 配置和会话数据，展示配额、reset credits、API 等价成本，并修复本机会话索引。

## 技术边界

- 使用 Swift 6、SwiftPM、AppKit、SwiftUI、Foundation。
- macOS 最低版本为 12.0。
- 默认不引入第三方依赖；标准库和系统框架能解决的问题不要加包。在线更新功能批准使用 Sparkle。
- 不创建 Xcode project，除非用户明确要求。
- 状态栏应用必须保持 `LSUIElement=true`，不要显示 Dock 图标。

## 隐私与安全

- 不要在日志、测试输出、README、issue 模板中输出 access token、refresh token、API key。
- CodexRunway 自有目录统一使用 `~/.codex-runway`，默认只保存非密钥的派生数据，不将应用缓存写入 `~/.codex`。
- 多账号凭据是唯一例外：仅允许存放在 `~/.codex-runway/accounts/<id>/auth.json`（目录 `0700`、文件 `0600`，原子写入）。账号索引 `index.json` 不得包含 token。
- 读取 `~/.codex/auth.json` 时只使用必要字段。
- 修改官方 `~/.codex/auth.json` 仅限：OAuth refresh 回写、以及用户主动切号时的原子写入。
- 刷新非当前托管账号 token 时只写账号库副本，不得写官方 `auth.json`；刷新当前账号时同步官方 auth 与账号库副本。
- 会话修复只允许处理 `session_index.jsonl`，写入前必须备份。
- 不删除 `~/.codex/sessions/**`、`~/.codex/archived_sessions/**` 或全局状态文件。

## 代码约定

- 核心逻辑放在 `Sources/CodexRunwayCore`，UI 放在 `Sources/CodexRunway`。
- UI 不直接解析 JSON、不直接扫描文件；通过 core API 获取结果。
- 所有用户可见文案必须通过 `L10n`，新增 key 需要同时补英文和简体中文。
- 函数保持短小，优先用简单结构体和函数，不做多 provider 抽象。
- 错误信息可以面向用户，但不要包含本地密钥或完整认证 JSON。
- 新行为优先补 `Tests/CodexRunwayCoreTests`。

## 常用命令

```bash
swift test
swift run CodexRunway --self-check
bash Scripts/package-app.sh
```

## 文档规则

- README 和源码不要包含外部参考应用名称、链接或代码片段。
- 用户可见文档应说明隐私边界、ad-hoc signed app、开发命令和功能状态。
- 价格表必须带版本日期；未知模型不要估算为精确费用。
