# 更新日志

本文件记录 AI Usage Widget 的所有重要变更，格式参考 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，
版本号遵循[语义化版本](https://semver.org/lang/zh-CN/)。

> 说明：`0.6.0` 之前的版本号是本次开源时**回填标注**的，仓库历史上并未打过标签；
> 每条记录都注明对应提交，便于逐条追溯。

## [0.9.0] - 2026-09-17

关于窗口与更新检查：右键菜单新增 **关于…**，显示版本、许可证与项目主页，并可从 GitHub Releases 检查新版本。

### Added

- `WidgetUpdates.ps1` + `test-WidgetUpdates.ps1`：版本比较与 GitHub Release 解析（纯函数，可离线测试）。容忍 `v` 前缀与 `-beta.1` 这类预发布后缀；draft / prerelease / 非法 tag / 没有发布记录都不提示更新，宁可漏报也不误报。
- 关于窗口（右键菜单 → **关于…**）：应用名、版本、许可证、项目链接，以及同步的「检查更新」按钮；发现新版本时显示版本号、Release 说明摘要与「打开下载页」按钮。
- 语言包新增 `menu.about` 与 11 个 `about.*` 键，中英文同步。

### Changed

- `Format-FetchError` 先于通用 403 分支识别 `rate limit`，把公开接口用 403 表达的匿名速率限制归类为「请求过于频繁」；关于窗口的失败提示复用同一套本地化文案，不再显示英文异常原文。
- `WidgetInstaller.ps1` 运行文件清单加入 `WidgetUpdates.ps1`。
- 排错文档补充检查更新遇到 GitHub 匿名速率限制时的处理方式。

## [0.8.0] - 2026-09-17

新增第 6 个供应商 OpenRouter：纯 API-key 接入，每个密钥一行，额度按「已用 / 上限」显示；没有上限的密钥会明确说明，而不是伪装成 0%。

### Added

- `OpenRouterQuota.ps1` + `test-OpenRouterQuota.ps1`：密钥短指纹（SHA256 前 8 位）与 `/api/v1/key` 载荷解析；`limit` 为 `null` 时返回 `IsUnlimited`，花超时百分比夹到 100%，非法载荷统一抛 `bad-payload`。
- OpenRouter 供应商接入（`AiUsageWidget.ps1`）：`Read-OpenRouterAuth` 读取 `~/.openrouter/auth.json`（或 `$env:OPENROUTER_HOME`）与 `$env:OPENROUTER_API_KEY`，每个密钥一行，行名是密钥指纹而不是密钥本身。
- 右键菜单「打开用量页」新增 OpenRouter 条目。
- 语言包新增 `row.limitUsage` / `row.unlimited`，分别渲染「已用 $12.50 / 上限 $100.00（12.5%）」与「已用 $12.50（未设上限）」。
- `-Demo` 演示数据新增 OpenRouter 行，截图与 UI 回归覆盖新供应商。
- `test-OpenRouterProvider.ps1`：从主程序抽取函数在同一进程内断言端点、请求头、明细文本、凭证优先级与 worker 转发清单。
- `test-WorkerSource.ps1`：构建后台 worker 脚本并逐个断言，worker 缺函数、缺 `$Cfg` 变量、缺 `switch` 分支时直接失败。

### Fixed

- 修复 0.7.0 引入的回归：后台 worker 里的行函数调用 `T` 取值，但 `T` / `Get-WidgetText` 没有被注入 worker，导致所有供应商的抓取都在构建明细文本时报 `The term 'T' is not recognized`，卡片每一行都只显示错误。现在 worker 会拿到 `T` 与同一张语言表（`WidgetStrings` / `Language`）。

### Changed

- `WidgetConfig.ps1` 的 `providers` 默认值新增 `openrouter`，设置面板出现对应开关。
- `WidgetInstaller.ps1` 运行文件清单加入 `OpenRouterQuota.ps1`，安装与打包自动包含。

## [0.7.0] - 2026-09-17

用量趋势、集中设置与中英双语界面：卡片内画出每行 7 天迷你折线，预测额度耗尽时间，把所有可调项收进 `ai-config.json`，界面文案全部改走语言包。

### Added

- `WidgetConfig.ps1` + `test-WidgetConfig.ps1`：`ai-config.json` 的读取、原子写入与逐字段校验；任何非法值都回退到默认值而不抛错。
- 设置窗口（右键菜单 → **设置…**）：趋势折线与耗尽预测开关、趋势天数、刷新间隔、窗口不透明度、提醒阈值、静音时段、五个供应商开关与界面语言。
- `UsageHistory.ps1` + `test-UsageHistory.ps1`：从 `ai-history.jsonl` 聚合每日序列、最小二乘趋势、耗尽时间预测、sparkline 路径生成与 CSV 导出。
- 卡片内 7 天迷你折线：颜色跟随该行当前用量（绿 / 黄 / 橙 / 红），数据点不足两个时沿用上一帧。
- 悬停提示新增耗尽预测行，例如「按最近趋势约 9 小时后耗尽，早于本次重置」。
- 右键菜单新增 **导出用量 CSV**：把全部历史导出为 Excel 可直接打开的 UTF-8 CSV（带 BOM）。
- `install.ps1` + `WidgetInstaller.ps1` + `test-WidgetInstaller.ps1`：安装 / 升级 / 卸载。安装到 `%LOCALAPPDATA%\Programs\AIUsageWidget` 并创建开始菜单快捷方式；用户数据永不被覆盖，卸载默认保留，`-Purge` 才彻底删除。
- `tools/package-release.ps1` 与 Release 工作流：推送 `v*` 标签后自动在双引擎跑全部测试，打包 zip、生成 SHA256 与 Scoop manifest 并发布 Release；本地可用同一脚本预演打包。
- `WidgetStrings.ps1` + `strings/zh-CN.json` + `strings/en-US.json` + `test-WidgetStrings.ps1`：界面文案集中到语言包，`language` 支持 `auto` / `zh-CN` / `en-US`。语言代码走白名单解析（配置值不会被当成文件名），语言包缺失或 JSON 损坏时回退内置兜底表；测试还会扫描源码里的全部 `T 'key'` 调用，漏登记键名直接失败。

### Fixed

- 修复 0.7.0 引入的回归：后台 worker 里的行函数调用 `T` 取值，但 `T` / `Get-WidgetText` 没有被注入 worker，导致所有供应商的抓取都在构建明细文本时报 `The term 'T' is not recognized`，卡片每一行都只显示错误。现在 worker 会拿到 `T` 与同一张语言表（`WidgetStrings` / `Language`）。

### Changed

- 刷新间隔优先级明确为 `-IntervalSeconds` > `ai-state.json` > `ai-config.json` > 默认 300 秒。
- 阈值提醒改为读取 `ai-config.json` 的 `alertThresholds`，并支持静音时段（自动识别跨午夜）。
- `providers` 里关闭的供应商不再参与行定义、刷新与提醒。
- 关闭趋势折线后进度条自动占满整行，不留空白。
- 状态行、托盘提示、右键菜单、悬停提示、气泡提醒、CSV 导出弹窗、设置窗口与 CLI 输出全部改用语言包；`-Demo` 模式可直接对照两种语言的排版。
- 未识别的抓取异常不再把原始异常文本贴到卡片上，统一显示可读短语；脱敏原文仍写进日志与悬停提示，方便排查。

### Fixed

- PowerShell 7.6 下把泛型列表强转成 `@(...)` 会抛 `Argument types do not match`：历史记录数组统一经 `ConvertTo-UsageHistoryArray` 转换。

## [0.6.0] - 2026-09-17

首个对外开源版本：把内部工具补齐为可分发、可贡献、可回归的项目。

### Added

- `-Version` 开关：输出 `AI Usage Widget 0.6.0` 后退出，便于报障时确认版本。
- `-Demo` 演示模式：使用固定数据渲染界面，不读取任何凭证、不写状态文件、不发网络请求，用于截图与 UI 回归。
- 开源工程基线：`LICENSE`（MIT）、`.gitattributes`、`.editorconfig`。
- 协作文档：`CONTRIBUTING.md`、`SECURITY.md`、`CODE_OF_CONDUCT.md`、Issue 表单与 PR 模板。
- 技术文档：`docs/architecture.md`、`docs/providers.md`（新增供应商七步改造点）、`docs/troubleshooting.md`。
- 中英双语 README：`README.md`、`README.en.md`，附 `-Demo` 模式生成的无隐私截图。
- GitHub Actions CI：在 `windows-latest` 上以 PowerShell 7 与 Windows PowerShell 5.1 双版本执行 `-Version` 校验与全部 `test-*.ps1`（其中 `test-Syntax.ps1` 递归解析全部 `.ps1` / `.psm1`）；PSScriptAnalyzer 以报告形式附加。
- `test-Syntax.ps1`：把原先只存在于 CI 的语法解析收进离线套件，本地双版本跑测试即可覆盖。
- 可选账号别名：程序目录下的 `grok-aliases.json`（或运行期的 `$script:GrokAccountAliases`）可把账号指纹映射成 `a` / `b` 这类短名字。

### Fixed

- 修复 0.7.0 引入的回归：后台 worker 里的行函数调用 `T` 取值，但 `T` / `Get-WidgetText` 没有被注入 worker，导致所有供应商的抓取都在构建明细文本时报 `The term 'T' is not recognized`，卡片每一行都只显示错误。现在 worker 会拿到 `T` 与同一张语言表（`WidgetStrings` / `Language`）。

### Changed

- 启动日志带上版本号：`starting widget v0.6.0`。
- 启动脚本 `Start-AiUsageWidget.vbs` 统一为 LF 行尾，之后不再出现整文件行尾差异。
- Grok 行身份改为纯通用指纹：源码不再硬编码任何账号指纹，别名一律走本机配置。

### Security

- 测试与文档不再包含真实邮箱与本机绝对路径，仓库源码里不出现任何账号标识。

### Fixed

- 版本常量与 `-Version` 开关同名，导致 `pwsh -File .\AiUsageWidget.ps1 -Version` 抛出
  `Cannot convert value "System.String" to type "System.Management.Automation.SwitchParameter"`：
  常量改名为 `$script:AppVersion`。
- 未配置别名的账号行名出现重复前缀（`Grok Grok-1f4a2c7e`），现在直接显示指纹。
- CI 工作流此前从未真正运行：`shell: ${{ matrix.shell }}` 无法解析（`shell:` 不接受 `matrix` 上下文），
  每次 push 都是 0 秒失败且不产生 job。现在步骤固定用 `pwsh`，再以子进程调用目标引擎执行校验与测试。

## [0.5.0] - 2026-09-17

加固集成与显示修正（提交 [`837cd1f`](https://github.com/Regine88/ai-usage-widget/commit/837cd1f)）。

### Added

- 离线校验模块 `UsageValidation.ps1`、DPAPI 快照模块 `SecureSnapshot.ps1`、Kimi 配额解析模块 `KimiQuota.ps1` 及各自测试（[`21b448a`](https://github.com/Regine88/ai-usage-widget/commit/21b448a)）。

### Fixed

- 修复 0.7.0 引入的回归：后台 worker 里的行函数调用 `T` 取值，但 `T` / `Get-WidgetText` 没有被注入 worker，导致所有供应商的抓取都在构建明细文本时报 `The term 'T' is not recognized`，卡片每一行都只显示错误。现在 worker 会拿到 `T` 与同一张语言表（`WidgetStrings` / `Language`）。

### Changed

- 账号条目统一：ChatGPT / Codex 与 Grok 多账号共用同一套行模型与快照命名。
- 凭据快照改走 DPAPI 保护目录，原子替换写入并收紧 ACL。

### Fixed

- 百分比为 `0%` 时不再被当成"无数据"而显示为占位符。
- Kimi 载荷的窗口时长与单位换算修正，周窗口标签不再错位。

## [0.4.0] - 2026-09-17

高 DPI 布局修复（提交 [`cabee6f`](https://github.com/Regine88/ai-usage-widget/commit/cabee6f)）。

### Fixed

- 在 125% / 150% / 200% 缩放下百分比与明细文字被裁剪：卡片尺寸、间距与字号改为按显示器 DPI 缩放。

## [0.3.0] - 2026-09-03

接入 Command Code 与 Antigravity Gemini（提交 [`663942a`](https://github.com/Regine88/ai-usage-widget/commit/663942a)）。

### Added

- Command Code 配额行：`/alpha/billing/credits` 的日 / 5 小时 / 周滚动窗口解析与测试。
- Antigravity Gemini 配额：Windows 凭据管理器取 token、OAuth 刷新、配额解析。
- Grok 多账号快照与模型请求事件记录器（`Record-ModelRequest.ps1`）及单元测试。

### Security

- 请求事件文件只记录元数据（供应商、模型、状态、耗时），从不写入提示词、补全内容或请求体。

## [0.2.0] - 2026-08-25

初始公开提交（[`7205460`](https://github.com/Regine88/ai-usage-widget/commit/7205460)）。

### Added

- 桌面卡片：Grok / ChatGPT 多账号、Kimi 周用量的百分比与明细展示。
- 拖拽与贴边吸附、置顶、托盘图标与右键菜单、双击打开用量页。
- 开机启动快捷方式、日志轮转、刷新间隔设置与阈值气泡提醒。
