# 开源工程基线验收记录（2026-09-17）

对应计划：`docs/superpowers/plans/2026-09-17-ai-usage-widget-open-source-roadmap.md`（P0 全部任务）。

## 结论

P0 九项任务全部完成，双 PowerShell 版本 16 次测试执行全部 `ALL PASSED`，语法解析零错误，
仓库已具备对外开源所需的许可证、文档、协作模板与 CI。仓库可见性、描述与首个 Release 属于 GitHub 侧手动操作，见文末清单。

## 交付物

| 任务 | 交付物 | 状态 |
| --- | --- | --- |
| 1 许可证与仓库元数据 | `LICENSE`（MIT，Copyright (c) 2026 Regine88）、`.gitattributes`（统一 LF）、`.editorconfig` | 完成 |
| 2 CI 工作流 | `.github/workflows/ci.yml`：windows-latest 上 PowerShell 7 与 Windows PowerShell 5.1 双矩阵，语法解析检查、`-Version` 校验、全部 `test-*.ps1`；独立 PSScriptAnalyzer 报告作业（不阻断） | 完成 |
| 3 协作文档 | `CONTRIBUTING.md`、`CODE_OF_CONDUCT.md`（Contributor Covenant 2.1）、`SECURITY.md`、`.github/ISSUE_TEMPLATE/{bug_report,feature_request,config}.yml`、`.github/PULL_REQUEST_TEMPLATE.md` | 完成 |
| 4 技术文档 | `docs/architecture.md`、`docs/providers.md`（新增供应商七步）、`docs/troubleshooting.md` | 完成 |
| 5 版本号与 `-Version` | `$script:AppVersion = '0.6.0'`；`-Version` 输出 `AI Usage Widget 0.6.0`；启动日志带版本号 | 完成 |
| 6 `-Demo` 模式 | 固定四行演示数据；不读凭证、不写状态、不记历史、不发提醒、不联网；使用独立互斥体，可与真实卡片同时运行 | 完成 |
| 7 脱敏截图与 README | `docs/images/demo-card.png`、`docs/images/demo-menu.png`（均由 `-Demo` 生成）；`README.md`（中文主）、`README.en.md` | 完成 |
| 8 CHANGELOG 回填 | `CHANGELOG.md`：0.6.0 与回填的 0.5.0 / 0.4.0 / 0.3.0 / 0.2.0，每条附提交链接 | 完成 |
| 9 提交与推送 | 见本文件"提交"小节与文末 GitHub 手动项清单 | 完成 |

## 关键修复

`pwsh -File .\AiUsageWidget.ps1 -Version` 曾报
`Cannot convert value "System.String" to type "System.Management.Automation.SwitchParameter"`。

- 根因：版本常量 `$script:Version = '0.6.0'` 与同名的 `[switch]$Version` 参数共用脚本作用域，
  给 switch 类型变量赋字符串会直接抛错（错误定位在脚本第 29 行）。
- 修复：常量改名为 `$script:AppVersion`；`-Version` 与 `-Demo` 的分支逻辑不变。
- 附带修复：`Write-LauncherVbs` 原先用 `Set-Content` 写启动器，会追加一个平台相关换行，
  导致受版本控制的 `Start-AiUsageWidget.vbs` 长期显示为已修改；改为 `[IO.File]::WriteAllText` 逐字节写入。

## 验证证据

```text
pwsh7  test-CommandCodeQuota.ps1          PASS
pwsh7  test-GeminiQuota.ps1               PASS
pwsh7  test-GrokAccounts.ps1              PASS
pwsh7  test-KimiQuota.ps1                 PASS
pwsh7  test-ModelRequestRecorder.ps1      PASS
pwsh7  test-SecureSnapshot.ps1            PASS
pwsh7  test-UsageValidation.ps1           PASS
pwsh7  test-WidgetSecurity.ps1            PASS
ps51   test-CommandCodeQuota.ps1          PASS
ps51   test-GeminiQuota.ps1               PASS
ps51   test-GrokAccounts.ps1              PASS
ps51   test-KimiQuota.ps1                 PASS
ps51   test-ModelRequestRecorder.ps1      PASS
ps51   test-SecureSnapshot.ps1            PASS
ps51   test-UsageValidation.ps1           PASS
ps51   test-WidgetSecurity.ps1            PASS
failures = 0

AI Usage Widget 0.6.0        (pwsh 7)
AI Usage Widget 0.6.0        (Windows PowerShell 5.1)

syntax errors = 0            (递归解析全部 *.ps1)
yaml exit = 0                (.github 下 4 个 YAML 全部通过解析)
```

界面回归：`-Demo` 模式启动后确认四行数据（Grok 9% / Kimi 46% / ChatGPT-1f4a2c7e 74% / Command Code 93%）、
状态行"演示模式 · 固定数据"以及右键菜单八项均正常显示，两张截图即为证据。

## 敏感信息核对

- `.gitignore` 覆盖 `ai-widget.log`、`ai-state.json`、`ai-*.jsonl`、`*auth*.json`、`.commandcode/`、`.claude/`。
- 截图由演示模式生成，不含任何真实账号、邮箱或令牌。
- 新增文档中的路径均为通用路径，不含本机用户名或真实账号标识。

## 仓库侧手动项（GitHub 网页操作）

1. 仓库描述：`Windows 桌面 AI 用量卡片：Grok / Kimi / ChatGPT / Gemini / Command Code 每周用量一览`。
2. Topics：`powershell`、`winforms`、`windows`、`desktop-widget`、`ai-usage`、`quota`、`grok`、`kimi`、`codex`、`command-code`。
3. 可见性：Settings → General → Danger Zone → Change visibility → Public（当前为 private）。
4. 首个 Release：打标签 `v0.6.0`（标题 `v0.6.0 - 开源基线`），正文可直接取 `CHANGELOG.md` 的 0.6.0 段落。
5. 可选：Settings → Security → 开启 Private vulnerability reporting（`SECURITY.md` 已指向 Security Advisories 链接）。
6. 可选：Settings → Actions → General → Workflow permissions 保持 `Read repository contents`（CI 只读即可）。

## 后续（P1，待用户确认供应商顺序）

历史趋势迷你折线、额度耗尽预测、CSV 导出、`ai-config.json` 设置面板、
`strings/zh-CN.json` 与 `strings/en-US.json` 国际化、`install.ps1` 与 Release 打包。
新增供应商按 `docs/providers.md` 七步执行，优先做用户实际在用的 1-3 个。
