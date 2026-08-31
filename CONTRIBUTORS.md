# 贡献者

[README](README.md) | [简体中文](README_ZH.md)

感谢所有为 CodexRunway 提交代码、测试、反馈、文档和设计建议的人。

## 当前维护

- 项目维护者：仓库所有者。
- 贡献者名单：以 Git commit、issue、pull request 和 release 记录为准。
- 新贡献合并后，可以在本文件中补充贡献类型，但不要手工添加无法追溯的姓名或身份。

## 可以贡献什么

- Swift / AppKit / SwiftUI 功能实现。
- 配额、reset credits、API 等价成本、多账号导入/切号和会话修复逻辑的测试。
- macOS 菜单栏、弹层和控制台体验优化。
- 简体中文和英文文案改进。
- 打包、CI、Release 和在线更新流程改进。
- Bug 报告和复现步骤。

## 开发环境

- macOS 12+
- Swift 6+
- 推荐本机已使用过 Codex；可通过 `~/.codex/auth.json` 或应用内导入/登录添加测试账号

常用命令：

```bash
swift test
swift build
swift build -c release
swift run CodexRunway --self-check
swift run CodexRunway
```

打包命令：

```bash
ARCH=arm64 bash Scripts/package-app.sh
ARCH=x86_64 bash Scripts/package-app.sh
```

## 代码边界

- 核心逻辑放在 `Sources/CodexRunwayCore`。
- AppKit / SwiftUI 入口和 UI 放在 `Sources/CodexRunway`。
- UI 不直接解析 JSON、不直接扫描本地会话文件。
- 所有用户可见文案必须走 `L10n`，新增 key 需要同时补英文和简体中文。
- 默认不新增依赖；在线更新功能已批准使用 Sparkle。
- 不创建 Xcode project，除非维护者明确要求。

## 隐私和安全

- 不要在代码、日志、README、issue、测试输出中写入 access token、refresh token、id token 或 API key。
- 读取 `~/.codex/auth.json` 时只使用必要字段。
- 多账号凭据仅允许存放在 `~/.codex-runway/accounts/<id>/auth.json`（目录 `0700`、文件 `0600`，原子写入）；账号索引 `index.json` 不得包含 token。
- 修改官方 `~/.codex/auth.json` 仅限：OAuth refresh 回写、以及用户主动切号时的原子写入。
- 刷新非当前托管账号 token 时只写账号库副本，不得写官方 `auth.json`；刷新当前账号时同步官方 auth 与账号库副本。
- 无效或 mock 凭据不得写回官方 `auth.json`。
- 会话修复只允许处理 `session_index.jsonl`，写入前必须备份。
- 不删除 `~/.codex/sessions/**`、`~/.codex/archived_sessions/**` 或全局状态文件。
- 更新检测只应请求 Release 元数据和 appcast，不上传 Codex 会话内容。

## 测试要求

提交前至少运行：

```bash
swift test
swift build
```

涉及打包或更新时额外运行：

```bash
ARCH=arm64 bash Scripts/package-app.sh
ARCH=x86_64 bash Scripts/package-app.sh
codesign --verify --deep --strict dist/CodexRunway.app
```

涉及本地诊断时运行：

```bash
swift run CodexRunway --self-check
```

如果某项验证无法运行，需要在提交说明或 PR 说明里写明原因。

## 提交规范

提交信息使用 Conventional Commits：

```text
<type>(<scope>): <subject>
```

常用 type：

- `feat`
- `fix`
- `docs`
- `test`
- `refactor`
- `build`
- `ci`
- `chore`

示例：

```text
docs(readme): 完善中英文使用说明
```

## 文档规则

- `README.md` 默认为英文。
- `README_ZH.md` 是简体中文说明，不替代英文首页。
- 文档不要包含外部参考应用名称、链接或代码片段。
- 文档应清楚说明隐私边界、打包方式、在线更新和系统要求。
