# 更新日志

本文件记录 AI Usage Widget 的所有重要变更，格式参考 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，
版本号遵循[语义化版本](https://semver.org/lang/zh-CN/)。

> 说明：`0.6.0` 之前的版本号是本次开源时**回填标注**的，仓库历史上并未打过标签；
> 每条记录都注明对应提交，便于逐条追溯。

## [0.7.0] - 2026-09-17

用量趋势与集中设置：卡片内画出每行 7 天迷你折线，预测额度耗尽时间，并把所有可调项收进 `ai-config.json`。

### Added

- `WidgetConfig.ps1` + `test-WidgetConfig.ps1`：`ai-config.json` 的读取、原子写入与逐字段校验；任何非法值都回退到默认值而不抛错。
- 设置窗口（右键菜单 → **设置…**）：趋势折线与耗尽预测开关、趋势天数、刷新间隔、窗口不透明度、提醒阈值、静音时段、五个供应商开关与界面语言。
- `UsageHistory.ps1` + `test-UsageHistory.ps1`：从 `ai-history.jsonl` 聚合每日序列、最小二乘趋势、耗尽时间预测、sparkline 路径生成与 CSV 导出。
- 卡片内 7 天迷你折线：颜色跟随该行当前用量（绿 / 黄 / 橙 / 红），数据点不足两个时沿用上一帧。
- 悬停提示新增耗尽预测行，例如「按最近趋势约 9 小时后耗尽，早于本次重置」。
- 右键菜单新增 **导出用量 CSV**：把全部历史导出为 Excel 可直接打开的 UTF-8 CSV（带 BOM）。
- `install.ps1` + `WidgetInstaller.ps1` + `test-WidgetInstaller.ps1`：安装 / 升级 / 卸载。安装到 `%LOCALAPPDATA%\Programs\AIUsageWidget` 并创建开始菜单快捷方式；用户数据永不被覆盖，卸载默认保留，`-Purge` 才彻底删除。
- `tools/package-release.ps1` 与 Release 工作流：推送 `v*` 标签后自动在双引擎跑全部测试，打包 zip、生成 SHA256 与 Scoop manifest 并发布 Release；本地可用同一脚本预演打包。

### Changed

- 刷新间隔优先级明确为 `-IntervalSeconds` > `ai-state.json` > `ai-config.json` > 默认 300 秒。
- 阈值提醒改为读取 `ai-config.json` 的 `alertThresholds`，并支持静音时段（自动识别跨午夜）。
- `providers` 里关闭的供应商不再参与行定义、刷新与提醒。
- 关闭趋势折线后进度条自动占满整行，不留空白。

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
