# 0.13.0 验收记录（2026-09-17）

对应计划：`docs/superpowers/plans/2026-09-17-ai-usage-widget-open-source-roadmap.md`（P1 / P2 收口）。

## 结论

0.13.0 交付 GitHub Copilot 供应商与两块路线图遗留能力：多列布局与每日汇总。
计划里的 P1 / P2 功能项到此全部收口；通义千问与豆包经调研确认没有可用配额接口，
按 `docs/providers.md` 的记录明确不接入。

发布链路完整跑通：CI 与 Release 工作流均绿，`v0.13.0` Release 三个资产已发布。

## 交付物

| 内容 | 交付物 | 状态 |
| --- | --- | --- |
| Copilot 解析模块 | `CopilotQuota.ps1`（纯函数，不读盘不联网）+ `test-CopilotQuota.ps1` | 完成 |
| Copilot 集成 | `Read-CopilotTokenFromFile` / `Get-CopilotToken` / `Get-CopilotAuthHeaders` / `Get-CopilotUsageSnapshot` / `Get-CopilotRowData` + `test-CopilotProvider.ps1` | 完成 |
| 多列布局 | `WidgetLayout.ps1`：`ConvertTo-WidgetLayoutColumns`、`Get-WidgetLayoutMetrics -Columns`、`Get-WidgetLayoutRowAnchor`、按行带折算的 `Get-WidgetFormHeight` | 完成 |
| 每日汇总 | `WidgetConfig.ps1` 的 `Test-DailySummaryDue` + 主程序 `Send-DailySummaryIfDue`，日期存 `ai-state.json` 的 `lastSummaryDate` | 完成 |
| 按供应商阈值 | `ConvertFrom-ProviderAlertThresholdsText` / `Format-ProviderAlertThresholds`，设置窗口多行文本框可直接编辑 | 完成 |
| 设置窗口 | 新增 Copilot 开关、窗口列数、每日汇总、分供应商阈值；供应商复选框改三列排布 | 完成 |
| 文档 | `README.md` / `README.en.md` / `CHANGELOG.md` / `docs/providers.md` / `docs/architecture.md` / `docs/troubleshooting.md` | 完成 |
| 安装清单 | `WidgetInstaller.ps1` 运行文件清单加入 `CopilotQuota.ps1`（漏掉会导致装完就缺模块） | 完成 |

## 验证证据

```text
TOTAL=62 FAILED=0
ALL SUITES PASSED

31 套件 × 2 引擎（pwsh 7 / Windows PowerShell 5.1）= 62 次执行，failures = 0
新增套件：test-CopilotQuota.ps1、test-CopilotProvider.ps1
扩充套件：test-WidgetLayout.ps1（列数 / 行锚点 / 行带高度）、test-WidgetConfig.ps1（列数、每日汇总、分供应商阈值往返）

PSScriptAnalyzer（Severity Error, Warning）：findings=491  errors=0
CI：run 35210468252  success  1m4s
Release：run 35210515100  success  1m12s

Release 资产（v0.13.0）：
  ai-usage-widget-0.13.0.zip          121183 bytes  sha256 1e70209c...
  ai-usage-widget-0.13.0.zip.sha256
  ai-usage-widget.json                （Scoop manifest）
打包内容核对：解压后的 38 个文件里包含 CopilotQuota.ps1。
文档相对链接检查：35 个链接全部解析成功。
```

## 界面回归（-Demo 冒烟）

以 `pwsh -NoProfile -STA -File .\AiUsageWidget.ps1 -Demo` 启动隐藏控制台的演示实例，
12 秒后读取日志并按 PID 精确结束该进程；用户正在运行的真实实例（pid 16700）未受影响，
演示模式使用独立互斥体，可与真实卡片并存。

```text
config interval=60s language=auto trend=True forecast=True
strings language=zh-CN keys=138
form shown
timer started
rows rebuilt: demo-grok,demo-kimi,demo-codex,demo-commandcode,demo-openrouter,
              demo-deepseek,demo-claude,demo-cursor,demo-glm,demo-copilot
fatal=False  unhandled=False  error=False
```

日志确认演示数据从 9 行扩展到 10 行（新增 `demo-copilot`），语言包 138 个键在两种语言下键集一致，
行重建与定时器都按预期执行，全程没有 fatal / unhandled / error。

## 已知边界

- `copilot_internal/user` 是社区在用的内部接口，不是 GitHub 官方文档接口；改版后可能返回 401 / 404，
  此时该行报错、其余行不受影响，排错步骤写在 `docs/troubleshooting.md`。
- 多列只改变窗口宽度与行带折算，不改变单行宽度；列数变化会立即重排，无需重启。
- 每日汇总只汇总当下快照，不做历史对比，也不区分工作日 / 节假日。

## 验证命令

```powershell
# 双引擎全量测试（本机复现 CI 的测试矩阵）
foreach ($engine in 'pwsh', 'powershell') {
    Get-ChildItem -Filter 'test-*.ps1' | ForEach-Object {
        & $engine -NoProfile -ExecutionPolicy Bypass -File $_.FullName
    }
}

# 静态检查门禁（CI 只看 Error）
Invoke-ScriptAnalyzer -Path . -Recurse -Severity Error, Warning

# 界面回归
pwsh -NoProfile -STA -File .\AiUsageWidget.ps1 -Demo
```
