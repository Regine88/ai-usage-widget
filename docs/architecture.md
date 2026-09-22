# 架构说明

本文面向要改动这个项目的开发者，说明进程结构、数据流、模块边界与既有约定。

## 设计目标与约束

- **纯本地**：只读取本机已有的登录凭证，只调用各供应商自己的配额接口，不上传任何数据、无遥测。
- **零依赖**：不依赖任何第三方 PowerShell 模块，只用 .NET 自带的 WinForms、Drawing 与 DPAPI。
- **双版本可用**：Windows PowerShell 5.1 与 PowerShell 7.x 行为一致，两者都必须通过全部测试。
- **可离线测试**：解析与校验逻辑全部是纯函数，放进模块文件后可在没有网络、没有账号的情况下测试。
- **单进程常驻**：一个隐藏 PowerShell 进程 + 一个 WinForms 窗口，没有服务、没有后台守护进程、不写注册表。

## 进程与线程模型

```text
wscript.exe  Start-AiUsageWidget.vbs
  |
  +-- pwsh.exe / powershell.exe  -NoProfile -STA -WindowStyle Hidden -File AiUsageWidget.ps1
        |
        +-- UI 线程（STA）
        |     WinForms 卡片 + NotifyIcon 托盘 + System.Windows.Forms.Timer 定时器
        |
        +-- 抓取 runspace pool（MTA，最多 3 个并发 job）
              |  Get-WorkerScriptSource 动态拼出的脚本：白名单函数源码 + 配置变量
              |  Split-WidgetProviderRows 按供应商分组并均衡到 3 个有界 job
              |
              +-- 每次 HTTP 请求再开一个嵌套 runspace
                    硬超时 WaitOne((TimeoutSec + 5) * 1000)，超时即 Stop()
```

要点：

- 入口脚本在非 STA 线程被调用时会用受信任路径的 PowerShell 以 `-STA -WindowStyle Hidden` **重启自己**（见 `Get-TrustedPowerShellPath`、脚本第 51 行起的分支），保证 UI 线程是 STA。
- `Invoke-WidgetRest` 之所以要嵌套 runspace，是因为 `Invoke-RestMethod -TimeoutSec` 在线程边界上可能被忽略；用 `WaitOne` 做硬超时，保证任何一个慢供应商都不会拖死整个刷新。
- 抓取使用常驻 runspace pool（`$script:WorkerPool`），最多 3 个 job；同一供应商的账号保持在同一 job，
  避免同供应商并发和限速冲突。每次刷新有 generation，旧 job 结果不会写入新一轮状态。

## 文件职责

| 文件 | 职责 |
| --- | --- |
| `AiUsageWidget.ps1` | 主程序：常量与路径、UI 构建、菜单与托盘、定时器、后台抓取调度、行渲染、状态持久化 |
| `UsageValidation.ps1` | 共享纯函数：数值有限性校验、百分比断言、比例换算、日志脱敏、账号指纹、受信任 HTTPS 主机校验 |
| `WidgetProviders.ps1` | 静态供应商注册表、有界调度分组、错误分类与退避策略 |
| `SecureSnapshot.ps1` | 当前用户 DPAPI 保护快照：读写、原子替换、目录 ACL、文件锁 |
| `ApiKeyAuth.ps1` | API-key 类供应商共用：凭证来源（文件 / 环境变量）、`Authorization: Bearer` 头构造、受信任主机鉴权请求（OpenRouter / DeepSeek） |
| `GrokAccounts.ps1` | Grok 多账号：从 `~/.grok/auth.json` 解析账号、指纹命名、快照同步 |
| `GeminiAntigravity.ps1` | Antigravity Gemini 配额：Windows 凭据管理器读写、多账号快照、OAuth 刷新、配额载荷转换 |
| `KimiQuota.ps1` | Kimi 载荷解析纯函数：窗口时长换算、已用/限额解析 |
| `CommandCodeQuota.ps1` | Command Code 配额解析纯函数：日 / 5 小时 / 周窗口、余额与时间换算 |
| `OpenRouterQuota.ps1` | OpenRouter 密钥配额解析纯函数：密钥指纹、`usage` / `limit` 换算与无上限判定 |
| `DeepSeekQuota.ps1` | DeepSeek 余额解析纯函数：多钱包挑选、币种符号、金额格式化（invariant culture） |
| `ClineQuota.ps1` | Cline Dashboard 配额与 OAuth 凭证解析纯函数：5 小时 / 周 / 月窗口、重置时间、`workos:` token 归一 |
| `ClaudeQuota.ps1` | Claude Code OAuth 用量解析：5 小时 / 周窗口、`utilization` 百分比 |
| `CursorQuota.ps1` | Cursor 计费周期解析，以及从 state.vscdb 取出 JWT 的扫描函数 |
| `ZaiQuota.ps1` | GLM / Z.AI Coding Plan 配额解析：5 小时 / 周窗口 |
| `CopilotQuota.ps1` | GitHub Copilot 配额解析纯函数：`entitlement` / `remaining` / `percent_remaining` 换算、重置日期解析，以及从 hosts.json / apps.json / OpenCode auth.json 里深度优先找 token |
| `WidgetUpdates.ps1` | 版本比较与 GitHub Release 解析纯函数：tag 规范化、draft / prerelease / 非法载荷判定 |
| `ModelRequestRecorder.ps1` | 请求事件记录与查询（仅元数据），以及脱敏工具 |
| `UsageHistory.ps1` | 历史聚合与趋势：从 `ai-history.jsonl` 生成每日序列、最小二乘斜率、耗尽预测、sparkline 路径与 CSV 导出 |
| `UsageReport.ps1` | 历史报表纯函数：月份归一与边界、按天汇总、月度汇总（复用趋势斜率）、CSV / Markdown / 自包含 HTML 渲染与文件名生成 |
| `WidgetTrend.ps1` | 趋势图纯函数：窗口天数归一、按天裁剪的每日序列、数据点坐标换算、坐标轴刻度与日期标签、最新百分比；不引用 WinForms，也不调用文案助手 |
| `WidgetConfig.ps1` | `ai-config.json` 的读写与校验（供应商开关、刷新间隔、主题、布局、锁定位置、不透明度、阈值、静音时段、语言），非法值回退默认 |
| `WidgetPalette.ps1` | 深色 / 浅色调色板：`ConvertTo-WidgetTheme` 白名单解析、`Get-WidgetPalette` 返回 13 键颜色表，界面颜色的唯一来源 |
| `WidgetLayout.ps1` | 卡片尺寸纯函数：`Get-WidgetLayoutMetrics`（full / compact）与 `Get-WidgetFormHeight`，不引用 WinForms |
| `WidgetFormat.ps1` | 百分比、余额主数值、重置时间、抓取错误与耗尽预测文案（调用 `T`） |
| `WidgetStrings.ps1` | 界面文案：语言代码白名单解析、语言包读取与兜底表、`T` / `Get-WidgetText` 取值（主进程与 worker 共用同一张表） |
| `strings/*.json` | 语言包：纯键值 JSON，多种语言的键集必须一致，`_` 前缀的键在加载时忽略 |
| `WidgetInstaller.ps1` | 安装 / 升级 / 卸载实现：运行文件清单、用户数据判定与开始菜单快捷方式；安装器与发布打包共用这份清单 |
| `WidgetPackage.ps1` | 发布包内容校验纯函数：期望条目清单、禁止条目判定、压缩包条目比对、包内版本号与 Scoop manifest 检查 |
| `tools/package-release.ps1` | Release 打包：按清单组装 zip、生成 SHA256 与 Scoop manifest（本地与 CI 共用） |
| `tools/verify-package.ps1` | 打包后校验入口：解压 zip 后调 `WidgetPackage.ps1` 比对条目、版本号与 manifest，失败即非零退出 |
| `tools/build-site.ps1` | 落地页构建：替换 `site/` 里的 `{{VERSION}}` / `{{REPO}}` 占位符输出到 `_site/`，并校验相对引用存在 |
| `site/` | 中英双语落地页源码（`index.html` / `style.css` / `.nojekyll`），由 Pages 工作流构建 |
| `Record-ModelRequest.ps1` | 供外部工具调用的独立入口：追加一条请求事件 |
| `Start-*.vbs` | 无窗口启动器；`Start-AiUsageWidget.vbs` 对应聚合卡片 |
| `test-*.ps1` | 每个模块对应的离线测试套件，成功时打印 `ALL PASSED` |

历史遗留的单供应商脚本（`GrokUsageWidget.ps1`、`KimiUsageWidget.ps1`、`ChatGptUsageWidget.ps1`）保留为独立入口，聚合卡片是当前的推荐用法。

## 一次刷新的完整数据流

1. `System.Windows.Forms.Timer` 触发 `Update-Widget`（或用户按 F5 / 点"立即刷新"）。
2. `Get-ProviderRows` 检查每个供应商的凭证是否存在，生成行定义 `@{ Id; Kind; Name; Auth; ... }`；没有任何凭证时直接显示"未找到登录凭证"并结束。 `ai-config.json` 里 `providers` 关闭的供应商会被 `Test-ProviderEnabled` 过滤掉。
3. Codex 相关的活跃快照先做一次 `Sync-ActiveCodexSnapshot`，保证多账号条目与磁盘上的 `auth.json` 一致。
4. 行集合的 `Id` 拼接成签名，与上一轮不同则 `Rebuild-ProviderRows` 重建控件。
5. `Start-BackgroundFetch` 把行定义与配置对象拆成最多 3 个供应商分组，传给常驻 MTA runspace pool；
   worker 只拿到**纯数据**（没有函数闭包、没有凭据缓存）。
6. worker 逐行调用对应的 `Get-*RowData`，每行独立 try/catch，返回
   `@{ Id; Percent; Display; Detail; Tip; Reset; Error }` 对象的数组。
7. `Receive-BackgroundFetch` → `Apply-FetchResults` 把结果写进 UI：成功行调用 `Set-RowUsage` 并用最近 7 天序列刷新迷你折线、计算耗尽预测，失败行调用 `Set-RowError`；
   同时 `Write-UsageHistory` 追加历史、`Send-UsageAlert` 按 `ai-config.json` 的阈值弹气泡（静音时段内跳过）。
8. 失败按 `auth` / `rate-limit` / `timeout` / `parse` / `network` 分类；429 默认等待 60 秒，
  认证失败等待 300 秒，其余使用有上限的指数退避和抖动。手动刷新可跳过退避。
9. 每个成功 job 完成后立即应用结果，不再等整批结束；失败行保留上次成功值与时刻，并显示下次重试时间。
10. 状态栏显示 `更新于 HH:mm`；刷新超时会显示"刷新超时，等待下次尝试"。

## 关键约定

### 行模型

每个供应商最终都要产出统一的行数据：

| 字段 | 含义 | 备注 |
| --- | --- | --- |
| `Percent` | **已用**百分比 | `0` 是合法值，必须照常显示，不能当缺数据 |
| `Display` | 主数值文本（可选） | 余额型供应商直接放金额（如 `¥1.58`）；为空时回退 `Percent` 百分比文本 |
| `Detail` | 明细文本，例如 `5h 32% · 周 68%` | 由各供应商自行组合 |
| `Tip` | 悬停提示 | 可含重置时间、套餐名等 |
| `Reset` | 重置时间 | 由 `Format-ResetText` / `Format-ResetTime` 统一格式化 |
| `ResetAt` | 重置时刻的 ISO 8601 文本 | 供耗尽预测判断“重置前是否耗尽”，缺失时预测退化为纯趋势 |

百分比方向由 `Convert-DisplayPercentToUsagePercent` 统一换算，避免各供应商对"剩余/已用"的理解不一致。

### 错误降级

任何异常都不允许冒泡到 UI 线程。`Format-FetchError` 会把技术异常映射为可读短语：

| 原始信息 | 卡片显示 |
| --- | --- |
| `timeout` / `超时` / `canceled due to` | 请求超时 |
| `SSL` / `certificate` / `信任关系` | 网络连接失败 |
| `401` / `Unauthorized` | 登录已过期，请重新登录 |
| `403` / `Forbidden` | 无访问权限 |
| `429` | 请求过于频繁 |
| `missing-credential` / `no-credential` | 未登录 |

未命中的异常统一显示「读取失败，请稍后重试」；脱敏后的原文只写进日志与悬停提示，不贴到卡片正文。

### 脱敏

`Convert-SafeLogText` 是所有日志与错误文本的唯一出口：折叠换行、截断长度、丢弃疑似 token 的片段。
账号在日志里只以 `Get-AccountFingerprint` 生成的短哈希出现，永不出现邮箱。

### 界面语言

全部界面文案集中在 `strings/<language>.json`，加载与取值都由 `WidgetStrings.ps1` 负责：

- 配置里的 `language` 先过 `ConvertTo-WidgetLanguage` 的白名单（`zh*` → `zh-CN`，`en*` → `en-US`，`auto` 或未登记的值跟随系统 UI 语言），
  解析结果才用来拼语言包路径——配置值永远不会被直接当成文件名。
- 语言包读不到或 JSON 损坏时回退到内置兜底表，缺键时返回键名本身，界面不会因为语言包出问题而空白。
- worker 通过 `$Cfg.WidgetStrings` 拿到同一张表，后台拼好的行文本与界面语言保持一致。
- 新增语言的登记点是 `$script:WidgetStringLanguages`；新增文案要同时补两个语言包与兜底表，
  `test-WidgetStrings.ps1` 会扫描源码里所有 `T 'key'` 调用，漏登记键名直接失败。

### 界面主题

界面颜色只有一个来源：`WidgetPalette.ps1` 的调色板。`Get-WidgetPalette <theme>` 返回 13 个键的哈希表
（`Text` / `Muted` / `Dim` / `Background` / `Field` / `Track` / `Button` / `Danger` / `ErrorText` /
`Link` / `Success` / `Warning` / `Ok`），`Get-WidgetColor` / `Set-UiThemeColor` 负责取值与控件配色；
缺键时故意画成品红，漏配立刻可见。

- 主题持久化在 `ai-config.json` 的 `theme` 字段（`dark` / `light`，非法值回退 `dark`），
  设置窗口保存后 `Apply-WidgetConfig` 立即重建调色板并重画窗口底色，无需重启。
- `-Theme dark|light` 只在本次运行覆盖配置；`ConvertTo-WidgetTheme` 是白名单解析入口，
  与语言代码一样，配置值永远不会被直接当成未知字符串使用。
- `test-WidgetPalette.ps1` 断言两套主题的键集合一致、同主题内不得出现同色、文字与背景保持最低对比度。

### 单实例

`Ensure-SingleInstance` 使用命名互斥体 `Local\AiUsageDesktopWidget`；演示模式使用 `Local\AiUsageDesktopWidgetDemo`，
因此可以同时开一个真实卡片和一个演示卡片做对比。

### 多列布局

`columns`（1 - 3）只影响 `WidgetLayout.ps1` 与 `Rebuild-ProviderRows` 两处：

- `Get-WidgetLayoutMetrics` 多了 `-Columns`，算出 `Columns`、`ColumnStride`（`ContentW + ColumnGap`）与 `FormWidth`；
  `Get-WidgetFormHeight` 按**行带数**折算高度（`Ceiling(行数 / 列数)`），所以 3 列 9 行和 1 列 3 行一样高。
- `Get-WidgetLayoutRowAnchor -Metrics -Index` 是唯一的行列换算入口：先横向填满一行，再换行带，返回 `@{ Column; Band; X; Y }`。
  行控件用返回的 `X` / `Y` 定位，控件名用行序号（`name-0` / `pct-0`）而不是 Y 坐标，避免同一行带里重名。
- 列数变化会让 `Apply-WidgetConfig` 清掉 `$script:UiMetrics` 并重建行，不需要重启卡片。

### 每日汇总

`ai-config.json` 的 `dailySummary` 是 `{ enabled, time }`。判定在 `Test-DailySummaryDue`（纯函数）：
开启、当天还没发过、且本地时间已过 `time` 三条同时成立才算到点。

`Send-DailySummaryIfDue` 在每轮抓取结束后调用：到点就收集当前各行文本、弹一次气泡，
并把日期写进 `ai-state.json` 的 `lastSummaryDate`，因此重启卡片也不会在同一天重复提醒。

### 历史报表导出

`UsageReport.ps1` 全部是纯函数：`ConvertTo-UsageReportMonth` / `Get-UsageReportMonthStart` 负责月份归一与边界，
`Get-UsageHistoryDailyRollup` 按天聚出「起始 / 结束百分比、样本数、最小值、最大值、变化量」，
`Get-UsageHistoryMonthlySummary` 在此基础上按供应商汇总，并复用 `Get-UsageTrendSlope` 算日均斜率。
只有 `metricType=percent` 的 schema v2 样本以及旧版 `pct` 样本进入百分比报表；余额和无上限记录保留在
原始导出中，但不会被填成 0% 或计算成百分比变化。

渲染层三选一：`ConvertTo-UsageReportCsv`（按天汇总，UTF-8 带 BOM 让 Excel 认出中文）、
`ConvertTo-UsageReportMarkdown`、`ConvertTo-UsageReportHtml`（自包含，样式内联、不引用任何外部资源）。
菜单的「导出历史」默认取最近一个有数据的月份，输出到程序目录的 `ai-usage-report-<YYYY-MM>.<ext>`；
没有任何历史记录时只提示 `report.empty`，不会生成空文件。

### 多月对比与趋势图

`Get-UsageReportComparisonMonths` 从历史里挑出最近 N 个有采样的月份（默认 3），
`Get-UsageHistoryMonthComparison` 复用月度汇总再补一条「与上月月末的百分点差」，
行集固定为「区间内出现过的供应商 × 选中月份」：某个月没有采样的供应商同样占一行，
各数值单元格是 `-` 而不是 0；渲染走 `ConvertTo-UsageReportComparisonMarkdown` /
`ConvertTo-UsageReportComparisonHtml`，文件名是 `ai-usage-comparison-<最早月>_<最新月>.<ext>`。
单月报表的那套函数与文件名保持原样，两条路径互不影响。

趋势图的数据侧在 `WidgetTrend.ps1`：`Get-UsageTrendChartModel` 把历史按供应商拆成「天数 → 百分比」的点列，
只保留窗口内真正有采样的点，因此采样不足窗口的供应商不会被补零点。
`Show-WidgetTrend`（主脚本）只负责画线和切换 7 / 14 / 30 天，颜色取自调色板里该行卡片使用的用量色。
窗口整体只读：既不写 `ai-history.jsonl`，也不动凭证与状态文件；读取失败只影响窗口自身的提示。

### 历史 schema 与归档

旧版 `ai-history.jsonl` 继续可读；新样本写入同级 `history\ai-history-YYYY-MM.jsonl`。schema v2 字段包括：

| 字段 | 含义 |
| --- | --- |
| `schemaVersion` / `ts` / `id` | 格式版本、采样时刻、稳定行 ID |
| `provider` / `accountId` | 供应商和稳定账号身份 |
| `metricType` | `percent` / `balance` / `unlimited` / `unknown` |
| `window` / `cycle` / `resetAt` | 配额窗口、重置周期与重置时刻 |
| `value` / `unit` / `used` / `limit` | 原始指标值、单位、已用和上限 |
| `sampleState` | `changed` / `scheduled` / `legacy`，区分变化采样与定时采样 |

`Import-UsageHistoryLegacy` 把旧行按月份复制进归档，保留原文件并重复执行去重；`Read-UsageHistory`
同时读取旧文件和全部月度归档，按时间排序并去重。删除采用按日期和总容量淘汰，不再按固定 2000 行截断。
`Invoke-UsageHistoryRetention` 返回容量不足状态，当前月归档不会被容量淘汰。

百分比预测使用 `Get-UsageHistorySampleSeries`，只保留当前 `resetAt` 周期内的样本；当日窗口不足两天的
5 小时配额时仍使用周期内采样，而不是把不同重置周期拼接后拟合。

> 命名坑：脚本顶层的 `$script:TrendWindow` 与 `-TrendWindow` 开关参数**是同一个变量**，
> 用它保存窗口对象会把开关覆盖掉。所以窗口引用放在 `$script:TrendForm`，
> `$script:TrendWindowRequested` 只保存开关的布尔值。

## worker 边界（新增供应商最容易踩的地方）

worker 是一个**全新的 runspace**，它既没有主脚本的函数，也没有主脚本的变量。`Get-WorkerScriptSource` 负责：

1. 把白名单里的函数**源码**逐个拼进 worker 脚本（`$fnNames` 列表）；
2. 把配置变量（路径、OAuth client id、URL 等）从 `$Cfg` 重新赋值给 worker 内的 `$script:*`（见 worker 脚本开头的 `foreach ($v in ...)`）；
3. 追加一段调度代码，按 `$row.Kind` 分派到对应的 `Get-*RowData`。

因此新增供应商时必须同时更新**三处**：`$fnNames`、`$Cfg` 变量列表、`switch ($row.Kind)` 分支。
漏掉任何一处，表现为"其他供应商正常，这一行永远没有数据"。

## 存储布局

| 路径 | 内容 | 是否入库 |
| --- | --- | --- |
| `%LOCALAPPDATA%\AIUsageWidget\accounts\` | DPAPI 保护的账号快照，文件名为账号指纹 | 否 |
| `<程序目录>\ai-state.json` | 窗口位置、置顶、刷新间隔 | 否（`.gitignore`） |
| `<安装目录>\ai-install.json` | 安装元数据：版本、安装时间与文件清单（由安装器维护） | 否 |
| `<程序目录>\ai-config.json` | 供应商开关、刷新间隔、主题、不透明度、趋势与提醒设置 | 否（`.gitignore`） |
| `<程序目录>\ai-history.jsonl` | 旧版历史文件；只读兼容，不再作为新样本主存储 | 否 |
| `<程序目录>\history\ai-history-YYYY-MM.jsonl` | schema v2 月度历史归档，默认保留 90 天并受容量上限约束 | 否 |
| `<程序目录>\ai-usage-report-<YYYY-MM>.csv / .md / .html` | 手动导出的历史报表（按天汇总 CSV / Markdown / HTML） | 否 |
| `<程序目录>\ai-request-events.jsonl` | 请求事件元数据 | 否 |
| `<程序目录>\ai-widget.log` | 日志，自动轮转 | 否 |
| `~/.grok/auth.json`、`~/.cline/data/settings/providers.json` 等 | 各供应商自己的凭证；本程序默认只读，OAuth token 过期时原地刷新 | 否 |

## 安全设计要点

- 快照使用当前用户范围 DPAPI 加解密，写入走"临时文件 → 原子替换"，并用 `Set-SecureSnapshotAcl` 收紧目录权限；
  并发写入由 `Invoke-SecureSnapshotFileLock` 串行化。
- `Invoke-WidgetRest` 入口走 `Assert-TrustedHttpsHost`：必须是 `https`，主机必须在内置允许列表里，允许 path 与 query（Grok billing 带 `?format=credits`）。Kimi 用户可覆盖的主机另外走更严的 `Resolve-TrustedHttpsEndpoint`（禁止 query / fragment / userinfo）。
- 不申请管理员权限、不写注册表启动项；开机启动只是往当前用户启动文件夹放一个指向 VBS 的快捷方式。
- 日志与错误文本统一脱敏；请求事件只记录供应商、模型、状态与耗时。

## 凭证身份与写回

每个账号行都携带 `ProviderId`（由行 `Kind` 选择）、`AccountId`、凭证来源与当前路径；稳定行 ID 由
`Kind + AccountId` 的本地短指纹生成。账号身份优先使用供应商提供的稳定字段，没有稳定字段时才退回到
refresh token 的短指纹，因此无法证明连续性的轮换会保留为独立身份，不强行合并。

| 供应商 | 优先身份 | 回退身份 | 是否写回 |
| --- | --- | --- | --- |
| Grok | 邮箱 | auth 条目 key | OAuth 刷新 |
| Gemini / Antigravity | 邮箱、项目 ID | refresh token 指纹 | OAuth 刷新，活动登录与快照分流 |
| Kimi | 用户 / 账号 ID、邮箱 | refresh token 指纹 | OAuth 刷新 |
| Codex | `tokens.account_id` | 无 | OAuth 刷新 |
| Cline | `auth.accountId` | refresh token 指纹 | OAuth 刷新 |
| Claude | account UUID、邮箱 | refresh token 指纹 | OAuth 刷新 |
| Command Code | `userId` | API key 指纹 | 否 |
| Cursor | JWT 邮箱 | token 指纹 | 否 |
| GLM / Z.AI | 密钥指纹 | 无 | 否 |
| GitHub Copilot | token 指纹 | 无 | 否 |

活动凭证采用 `Update-JsonFile` 在 `Invoke-SecureSnapshotFileLock` 内重新读取，只修改 access token、
refresh token 与过期时间等目标字段，再走临时文件替换。写回前同时核对稳定账号 ID，以及发起刷新时
记录的原始 access / refresh 版本，避免同账号的迟到结果覆盖较新的外部登录：

- 身份匹配时更新活动文件或 Windows 凭据管理器，并同步刷新受保护快照。
- 读到另一个账号时保持当前登录不变，把旧账号的刷新结果写入旧账号快照；该行后续改用快照凭证。
- JSON 文件中的未知字段通过锁内重读和局部字段更新保留，不再用锁外内存对象覆盖整份文件。

外部 CLI 不参与本程序的命名互斥体事务，因此“检查身份”和“原子替换”之间仍存在极小的竞争窗口。
本程序能保证不基于已知的陈旧账号写入，但不能让不合作的外部进程与本程序形成跨进程事务；活动文件与
凭据管理器的最终写回都按这个边界设计。

## 可测性设计

- 每个模块都有同名 `test-*.ps1`，测试只调用纯函数并断言返回值，不读磁盘、不联网、不使用真实凭据。
- 涉及 WinForms 的代码不写测试，改用 `-Demo` 模式做人工回归：固定数据渲染、不写状态、不联网。
- CI 在两个 PowerShell 版本上跑同样的套件，任何一侧失败都视为构建失败。

## 发布流水线

打包与校验是两条独立路径，共用同一份 `WidgetInstaller.ps1` 运行文件清单：

1. `tools/package-release.ps1` 按清单组装 zip，并生成 `.sha256` 与 Scoop manifest；
2. `tools/verify-package.ps1` 解压 zip 后用 `WidgetPackage.ps1` 比对「期望条目 vs 压缩包条目」，
   检查禁止文件（数据 / 凭证 / 日志）、包内版本号、`.sha256` 与 manifest 的 version / hash / url / extract_dir / checkver / persist；
3. CI 的 `package` job 与 Release 工作流的 `Verify package contents` 步骤都会跑第 2 步，校验失败即构建失败。

落地页走独立的 `pages.yml`：`tools/build-site.ps1` 注入版本号与仓库地址后输出 `_site/`，
引用了缺失资源的页面会直接构建失败。

## 已知取舍与后续方向

- 主程序仍是单文件（UI 与调度耦合），但布局计算在 `WidgetLayout.ps1`、文案格式化在 `WidgetFormat.ps1`，均可离线测试。
- WinForms 没有原生暗色主题支持，当前的暗色 / 浅色卡片是自绘圆角面板 + `WidgetPalette.ps1` 调色板。
- 提醒阈值可全局配置，也可在 `ai-config.json` 的 `providerAlertThresholds` 里按供应商覆盖，两者都能在设置窗口编辑。
- 紧凑布局与多列布局都已提供；跨显示器 DPI 不会在拖动时重算（`UiScale` 在进程内缓存）。
- 每日汇总只汇总"当下快照"，不做历史上的对比，也没有节假日 / 工作日区分。
- 历史报表按月导出，月份来自历史记录里已经出现的数据；趋势图窗口支持 7 / 14 / 30 天切换，
  多月对比导出按供应商与月份并列展示，但两者仍以历史采样覆盖率为边界，不补造缺失数据。
