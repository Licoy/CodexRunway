# Issue #27：重置次数到期摘要设计

设计状态：已实施并完成本地验证；核验日期：2026-09-05；设计核验基线：`36383dc`

需求来源：[issue #27](https://github.com/Licoy/CodexRunway/issues/27) 及其补充评论，反馈基于 0.0.72，本方案按当前工作区代码核验

## 推荐方案

移除“总剩余”这一展示指标，改为“最近到期 / 最迟到期”，两个入口都按最近在左、最迟在右排列

例如当前预览中的三张可用卡分别剩余 3 天、16 天、25 天，摘要应显示最近 3 天、最迟 25 天，现有相加所得 44 天不代表任何一张卡的有效期，也不代表用户能够连续使用 44 天

### 展示

主面板沿用现有重置次数模块：

```text
重置次数
3 可用 / 4 总计
最近到期：3 天                  最迟到期：25 天
3 次可用重置                                  >
```

详情页沿用现有两列统计卡：

| 左列 | 右列 |
| --- | --- |
| 可用：3 | 即将到期：1 |
| 最近到期：3 天 | 最迟到期：25 天 |

- 主值继续显示距到期的剩余时长，沿用 `DurationFormatter`，两个入口统一使用 `includeSeconds: false`，不为本功能新增定时器
- 悬停日期项时显示完整本地日期与时间，复用 `ResetCreditDateFormatter.expiresAt`，文案明确数据基于上次刷新且只统计已知到期时间
- 最近到期沿用橙色标识，最迟到期使用原统计卡的蓝色标识，颜色跟随指标移动
- 主面板保留左右两列，长译文允许在各自列内换行；详情页先检查现有单行标题，若翻译实际截断，仅对这两张到期卡放宽标题换行，不改共享统计卡的所有使用场景
- 卡片明细表继续按到期时间升序显示，用户仍可逐张查看具体日期

## 数据口径与边界

沿用当前 `ResetCreditSummary` 对“最近到期”的候选集合，即 `status == "available"` 且 `expiresAt != nil`

在同一个候选集合中按 `expiresAt` 取 `min` 和 `max`，分别作为最近与最迟到期；剩余时长取各自卡片对应的 `remainingSeconds`，这与当前基于快照计算时长的方式一致

| 情况 | 预期行为 |
| --- | --- |
| 多张可用卡 | 显示最早与最晚的到期值，不再相加 |
| 已使用、不可用或未知状态的卡日期更晚 | 不参与最近或最迟统计 |
| 只有一张有日期的可用卡，或日期都相同 | 两个值相同，保留两个位置 |
| 没有可用卡 | 两项均显示 `--`，可用数量沿用现有值 |
| 可用卡全部缺少到期时间 | 两项均显示 `--`，说明没有可统计的到期时间，不显示 0 天或永久有效 |
| 部分可用卡缺少到期时间 | 只统计有日期的卡，提示中明确范围为已知到期时间，不把缺失值当无限远 |
| 服务端数量与明细数量不一致 | 数量继续使用现有来源，到期摘要继续依据明细，不从数量推算日期 |
| 服务端仍标记 available，但日期已经过去 | 沿用当前状态与剩余时长口径，解码后的剩余时长为 0，完整日期可查；本 issue 不顺便改可用性判断、风险分类或告警 |

`nil` 表示没有可统计日期，不做时间兜底；未加载状态、刷新失败处理与刷新节奏沿用现有流程

## 最小实现步骤

1. 在 `Sources/CodexRunwayCore/DisplayModels.swift` 的 `ResetCreditSummary` 中新增 `latestExpiryDate: Date?` 与 `latestExpiryRemaining: TimeInterval?`，复用候选集合取最大日期，保留现有 next 字段名；清除已无用途的 `totalRemainingDuration` 及其求和逻辑
2. 修改 `Sources/CodexRunway/RunwaySummaryViews.swift` 与 `Sources/CodexRunway/RunwaySidePanel.swift`，落实左右顺序、空值和日期提示，直接复用现有组件与格式化器
3. 在 `L10nKey` 新增 `latestExpiry` 和摘要日期说明所需的键，补齐英、简中、繁中、日、韩、俄、法 7 种语言，确认无引用后移除旧 `totalRemaining` 键及译文，不用旧键承载新含义
4. 在现有 `QuotaTests` 更新“总和为 400”的旧需求断言为最大日期及对应剩余时长，保留最近到期、数量和风险断言，补充上述关键边界；在 `GrokQuotaPresentationTests` 校验共同摘要的最迟到期
5. 运行核心与展示相关测试、全量测试和 self-check，复用现有 mock 检查主面板与详情页的浅色、深色及长语言文案布局

预计变更集中于 3 个功能文件、7 个国际化相关文件（键定义 1 个、翻译表 6 个）及现有测试，是否调整预览或布局测试以实际验收缺口为准，不新增依赖、配置开关或通用聚合层

## 验收与范围

- 主面板与详情页均不再显示“总剩余”，左最近、右最迟，同一快照下结果一致
- 现有预览数据应从 44 天总和变为最近 3 天、最迟 25 天，详情页仍显示 3 次可用、1 次即将到期
- 最近与最迟都只取可用且有日期的卡，空值、单卡、同日期及不可用卡不干扰结果
- 新文案在全部 7 种语言中完整，400 pt 主面板无横向溢出，到期标题与主值可读
- Codex 与 Grok 因共用组件同步获得新的摘要，保留各自原有的数据获取和可用性判定
- 原生右键菜单原本没有“总剩余”，Widget 仅消费次数与风险数量，本次无需扩展这些显示或修改存储结构

建议实现后的验证命令：

```bash
swift test
swift run CodexRunway --self-check
swift run CodexRunway --render-main-panel-mock=main-light /tmp/issue-27-main-light.png
swift run CodexRunway --render-main-panel-mock=main-dark /tmp/issue-27-main-dark.png
swift run CodexRunway --render-main-panel-mock=reset-credits-light /tmp/issue-27-detail-light.png
swift run CodexRunway --render-main-panel-mock=reset-credits-dark /tmp/issue-27-detail-dark.png
```

这些截图命令目前固定简中且使用 Codex 数据，不能据此声称通过了全部语言和 Grok 专属预览；其余语言使用现有 `MainPanelMockRender.render(language:)` 入口检查，共用语义以 Grok 展示测试补足

方案阶段运行过原有基线 `swift test --filter 'QuotaTests|GrokQuotaPresentationTests|PreferencesTests'`，实际输出为 `Build complete! (5.14s)`、`47 tests in 3 suites passed`，实施后的验证结果见文末

## 已核验的源码依据

以下路径相对于仓库根目录，位置对应本轮代码基线

| 结论 | 源码依据 |
| --- | --- |
| 总剩余确实是求和，next 从有日期的 available 卡中取最小值 | [DisplayModels.swift:98](../../Sources/CodexRunwayCore/DisplayModels.swift#L98) |
| 当前主面板左总剩余、右剩余时长，详情第二排左总剩余、右最近到期 | [RunwaySummaryViews.swift:1139](../../Sources/CodexRunway/RunwaySummaryViews.swift#L1139)、[RunwaySidePanel.swift:366](../../Sources/CodexRunway/RunwaySidePanel.swift#L366) |
| Codex/Grok 共用主面板摘要和详情组件 | [RunwayPopoverView.swift:248](../../Sources/CodexRunway/RunwayPopoverView.swift#L248)、[RunwayPopoverView.swift:294](../../Sources/CodexRunway/RunwayPopoverView.swift#L294)、[RunwaySidePanel.swift:80](../../Sources/CodexRunway/RunwaySidePanel.swift#L80) |
| Grok 将 validityEnd 映射为 expiresAt 后复用同一摘要 | [GrokResetCredits.swift:35](../../Sources/CodexRunwayCore/GrokResetCredits.swift#L35)、[GrokQuotaPresentation.swift:161](../../Sources/CodexRunway/GrokQuotaPresentation.swift#L161) |
| 卡片标题和数值目前限单行，主面板宽度为 400 pt | [RunwayDetailComponents.swift:6](../../Sources/CodexRunway/RunwayDetailComponents.swift#L6)、[MainPanelLayout.swift:5](../../Sources/CodexRunway/MainPanelLayout.swift#L5) |
| 完整日期有现成格式化器与语言测试 | [Formatters.swift:179](../../Sources/CodexRunwayCore/Formatters.swift#L179)、[PreferencesTests.swift:482](../../Tests/CodexRunwayCoreTests/PreferencesTests.swift#L482) |
| L10nKey 定义和完整性测试要求每个支持语言都有译文，英文回退不能通过完整性测试 | [Preferences.swift:3](../../Sources/CodexRunwayCore/Preferences.swift#L3)、[Preferences.swift:586](../../Sources/CodexRunwayCore/Preferences.swift#L586)、[PreferencesTests.swift:94](../../Tests/CodexRunwayCoreTests/PreferencesTests.swift#L94) |
| 现有 noExpiry 英文为 no expiry，可能表达无限期，新的摘要未知状态应使用独立说明键 | [LocalizationTables.swift:219](../../Sources/CodexRunwayCore/LocalizationTables.swift#L219) |
| 右键菜单没有总剩余，使用另一组摘要与逐卡数据 | [StatusControllerMenu.swift:30](../../Sources/CodexRunway/StatusControllerMenu.swift#L30)、[RunwayModel.swift:2364](../../Sources/CodexRunway/RunwayModel.swift#L2364) |
| Widget 契约仅含可用数和即将到期数，重置卡告警使用逐卡风险分类 | [RunwayWidgetSnapshot.swift:56](../../Sources/CodexRunwayCore/RunwayWidgetSnapshot.swift#L56)、[RunwayAlerts.swift:58](../../Sources/CodexRunwayCore/RunwayAlerts.swift#L58) |
| 预览数据已有 3、16、25 天的卡，mock 使用临时目录和测试服务 | [DevPreviewFixtures.swift:74](../../Sources/CodexRunwayCore/DevPreviewFixtures.swift#L74)、[MainPanelMockRender.swift:220](../../Sources/CodexRunway/MainPanelMockRender.swift#L220) |
| 现有布局测试在无有效 NSHostingView 时可能跳过，不能只凭绿灯宣称视觉通过 | [MainPanelLayoutTests.swift:9](../../Tests/CodexRunwayTests/MainPanelLayoutTests.swift#L9) |
| Grok 展示和映射测试可复用 | [GrokQuotaPresentationTests.swift:121](../../Tests/CodexRunwayTests/GrokQuotaPresentationTests.swift#L121)、[GrokResetCreditsTests.swift:97](../../Tests/CodexRunwayCoreTests/GrokResetCreditsTests.swift#L97) |

## 实施记录

- 已移除总剩余字段、求和及全部旧译文，两个入口统一为最近在左、最迟在右，Codex 与 Grok 复用同一摘要
- 新增 18 行的 `ResetCreditExpiryPresentation.swift`，供两个入口共用分钟精度时长、完整日期、数据更新时间及已知日期统计范围提示，未知时间显示 `--`
- 已补齐全部 7 种语言，保持原有可用性、风险分类、刷新节奏、明细排序、Widget 和原生菜单行为
- 新增核心边界与展示测试，并扩展 Grok 展示测试，保留原有数量、风险和最近到期断言
- 全量 `swift test` 通过，实际输出为 `Build complete! (6.19s)`、`644 tests in 83 suites passed after 6.638 seconds`
- `swift run CodexRunway --self-check` 在当前沙箱中受 SwiftPM 缓存目录权限限制，随后直接运行刚编译完成的 `./.build/debug/CodexRunway --self-check`，退出码为 0，认证状态与本机会话统计检查正常执行
- 使用临时测试入口复用现有离屏渲染器，生成 7 种语言、主面板与详情页、明暗主题的 28 张图，宽度检查均为 400 pt；另检查了 7 种语言摘要的已知日期与无日期状态
- 已查看全部 7 种语言的详情统计区域明暗对照和摘要对照，最近 3 天、最迟 25 天显示正确，标题完整，原有统计卡无需调整换行；透明截图仅为检查可读性合成相应明暗底色
- 离线预览位于 `/tmp/codex-runway-issue27-preview`，临时渲染测试已删除，未加入业务代码或常规测试套件
- `git diff --check` 通过，未修改认证数据或账号状态
