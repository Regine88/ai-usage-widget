# 更新日志

本文件记录 AI Usage Widget 的所有重要变更，格式参考 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，
版本号遵循[语义化版本](https://semver.org/lang/zh-CN/)。

> 说明：`0.6.0` 之前的版本号是本次开源时**回填标注**的，仓库历史上并未打过标签；
> 每条记录都注明对应提交，便于逐条追溯。

## [0.6.0] - 2026-09-17

首个对外开源版本：把内部工具补齐为可分发、可贡献、可回归的项目。

### Added

- `-Version` 开关：输出 `AI Usage Widget 0.6.0` 后退出，便于报障时确认版本。
- `-Demo` 演示模式：使用固定数据渲染界面，不读取任何凭证、不写状态文件、不发网络请求，用于截图与 UI 回归。
- 开源工程基线：`LICENSE`（MIT）、`.gitattributes`、`.editorconfig`。
- 协作文档：`CONTRIBUTING.md`、`SECURITY.md`、`CODE_OF_CONDUCT.md`、Issue 表单与 PR 模板。
- 技术文档：`docs/architecture.md`、`docs/providers.md`（新增供应商七步改造点）、`docs/troubleshooting.md`。
- 中英双语 README：`README.md`、`README.en.md`，附 `-Demo` 模式生成的无隐私截图。
- GitHub Actions CI：在 `windows-latest` 上以 PowerShell 7 与 Windows PowerShell 5.1 双版本执行语法解析检查、`-Version` 校验与全部 `test-*.ps1`；PSScriptAnalyzer 以报告形式附加。
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

## [0.5.0] - 2026-09-17

加固集成与显示修正（提交 [`5e766de`](https://github.com/Regine88/ai-usage-widget/commit/5e766de)）。

### Added

- 离线校验模块 `UsageValidation.ps1`、DPAPI 快照模块 `SecureSnapshot.ps1`、Kimi 配额解析模块 `KimiQuota.ps1` 及各自测试（[`640572d`](https://github.com/Regine88/ai-usage-widget/commit/640572d)）。

### Changed

- 账号条目统一：ChatGPT / Codex 与 Grok 多账号共用同一套行模型与快照命名。
- 凭据快照改走 DPAPI 保护目录，原子替换写入并收紧 ACL。

### Fixed

- 百分比为 `0%` 时不再被当成"无数据"而显示为占位符。
- Kimi 载荷的窗口时长与单位换算修正，周窗口标签不再错位。

## [0.4.0] - 2026-09-17

高 DPI 布局修复（提交 [`2e24c36`](https://github.com/Regine88/ai-usage-widget/commit/2e24c36)）。

### Fixed

- 在 125% / 150% / 200% 缩放下百分比与明细文字被裁剪：卡片尺寸、间距与字号改为按显示器 DPI 缩放。

## [0.3.0] - 2026-09-03

接入 Command Code 与 Antigravity Gemini（提交 [`3dcf9bd`](https://github.com/Regine88/ai-usage-widget/commit/3dcf9bd)）。

### Added

- Command Code 配额行：`/alpha/billing/credits` 的日 / 5 小时 / 周滚动窗口解析与测试。
- Antigravity Gemini 配额：Windows 凭据管理器取 token、OAuth 刷新、配额解析。
- Grok 多账号快照与模型请求事件记录器（`Record-ModelRequest.ps1`）及单元测试。

### Security

- 请求事件文件只记录元数据（供应商、模型、状态、耗时），从不写入提示词、补全内容或请求体。

## [0.2.0] - 2026-08-25

初始公开提交（[`eb58997`](https://github.com/Regine88/ai-usage-widget/commit/eb58997)）。

### Added

- 桌面卡片：Grok / ChatGPT 多账号、Kimi 周用量的百分比与明细展示。
- 拖拽与贴边吸附、置顶、托盘图标与右键菜单、双击打开用量页。
- 开机启动快捷方式、日志轮转、刷新间隔设置与阈值气泡提醒。
