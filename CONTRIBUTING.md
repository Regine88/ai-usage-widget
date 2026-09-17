# 贡献指南

感谢你愿意改进 AI Usage Widget。本文档说明本地开发环境、测试方式、代码约定与提交流程。

## 环境要求

| 项目 | 要求 |
| --- | --- |
| 操作系统 | Windows 10 / 11（依赖 WinForms 与 DPAPI） |
| PowerShell | Windows PowerShell 5.1 **与** PowerShell 7.x 都要能运行 |
| 第三方依赖 | 无。测试全部离线执行，不访问网络、不需要真实账号 |
| 编辑器 | 任意；仓库提供 `.editorconfig` 与 `.gitattributes` |

## 快速开始

```powershell
git clone https://github.com/Regine88/ai-usage-widget.git
cd ai-usage-widget

# 用演示数据启动界面：不读取凭证、不写状态文件、不联网
pwsh -NoProfile -File .\AiUsageWidget.ps1 -Demo

# 查看版本
pwsh -NoProfile -File .\AiUsageWidget.ps1 -Version
```

只想改解析逻辑或写测试时，不需要安装或登录任何供应商账号。

## 运行测试

每个 `test-*.ps1` 都是自包含的离线套件，成功时会打印 `ALL PASSED`，失败时以非零退出码结束。
提交前请在**两个** PowerShell 版本下都跑一遍：

```powershell
$ps51 = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
foreach ($exe in @('pwsh', $ps51)) {
    Get-ChildItem -Filter 'test-*.ps1' | Sort-Object Name | ForEach-Object {
        $out = & $exe -NoProfile -ExecutionPolicy Bypass -File $_.FullName 2>&1 | Out-String
        '{0,-32} {1}' -f $_.Name, $(if ($LASTEXITCODE -eq 0 -and $out -match 'ALL PASSED') { 'PASS' } else { 'FAIL' })
    }
}
```

CI（`.github/workflows/ci.yml`）会在 `windows-latest` 上做同样的事，另外附带语法解析检查与 PSScriptAnalyzer 报告。

## 代码约定

- **单文件主程序 + 纯函数模块**：界面与调度留在 `AiUsageWidget.ps1`，可复用的逻辑抽到模块文件（`*Quota.ps1`、`UsageValidation.ps1`、`SecureSnapshot.ps1`），模块不得依赖 WinForms。
- **纯函数优先**：解析函数只接收载荷、只返回数据，不读文件、不发请求，这样才能离线测试。
- **KISS / DRY**：先检索是否已有可复用实现（`UsageValidation.ps1` 是共享工具的首选落点），不要复制粘贴。
- **保护调用链**：修改函数签名时同步更新所有调用点，包括后台 worker 的脚本注入列表。
- **错误必须可降级**：网络与解析失败要落到可见的提示文本，不能让 UI 线程抛异常。
- **缩进 4 空格，UTF-8 with BOM**：新增 `.ps1` 文件必须带 BOM，否则 Windows PowerShell 5.1 会把中文读成乱码。
- **不加调试残留**：提交前清理临时文件、注释掉的死代码与调试输出。

## 新增供应商

按 `docs/providers.md` 的七步改造点执行：解析模块 → 凭证读取 → 快照 → 行数据 → 行定义 → worker 注入 → 菜单与文档。
每一步都有对应位置说明，缺一步就会出现"卡片上永远没有这一行"这类静默失败。

## 提交与 PR

- 提交信息用英文祈使句写一行标题，说明"做了什么"，例如 `Add Kimi quota parsing module`。
- 一个 PR 只做一件事；重构与行为变更不要混在一起。
- PR 描述里写清**实际执行的验证命令与结果**，不要只写"应该没问题"。
- 涉及界面改动时，用 `-Demo` 模式截图附在 PR 里。

## 安全红线

- **绝不提交**凭据、快照、日志与含个人信息的文件：`*auth*.json`、`ai-state.json`、`ai-*.jsonl`、`*.log`、`.commandcode/`。`.gitignore` 已覆盖这些路径，请不要绕过。
- 不要为了"方便调试"把 token 打印到日志或 Issue 里。日志只允许出现哈希指纹与状态码。
- 新增外部请求时必须走既有的 `Invoke-WidgetRest` / 模块内 `Invoke-*Get`，以便统一处理超时、状态码与脱敏。
- 发现安全问题时按 `SECURITY.md` 走私密渠道，不要开公开 Issue。

## 行为准则

参与本项目即表示同意遵守 [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md)。
