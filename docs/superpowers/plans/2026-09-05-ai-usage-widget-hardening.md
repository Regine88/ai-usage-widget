# AI Usage Widget 安全加固实现计划

> **验收状态（2026-09-17）：** 全部任务已完成并通过双版本离线回归与真实 API 冒烟，验收记录见 `docs/superpowers/reports/2026-09-17-ai-usage-widget-hardening-acceptance.md`。

> **面向 AI 代理的工作者：** 必需子技能：使用 superpowers:subagent-driven-development（推荐）或 superpowers:executing-plans 逐任务实现此计划。步骤使用复选框（`- [x]`）语法来跟踪进度。

**目标：** 完成凭据保护、启动与网络安全加固、用量数据校验、并发安全、旧入口收敛和离线回归验证。

**架构：** 新增两个纯 PowerShell 辅助模块：`UsageValidation.ps1` 负责有限数值和安全文本，`SecureSnapshot.ps1` 负责 DPAPI 快照、哈希命名、互斥与原子替换。主 Widget 和 Grok 账户发现复用这两个模块；旧入口只负责转发到主 Widget。

**技术栈：** Windows PowerShell 5.1、PowerShell 7、WinForms、Windows DPAPI、PowerShell AST、现有脚本测试框架。

---

## 文件清单

- 创建：`UsageValidation.ps1`，统一校验百分比、窗口和日志文本。
- 创建：`SecureSnapshot.ps1`，实现当前用户 DPAPI 快照存取和原子写入。
- 创建：`test-UsageValidation.ps1` 与 `test-SecureSnapshot.ps1`，覆盖缺失值、显式 0、越界值、空 provider 和 DPAPI round-trip。
- 修改：`AiUsageWidget.ps1`，接入安全快照、校验、并发保存、启动器和错误脱敏。
- 修改：`GrokAccounts.ps1`，从受保护快照发现多账户并完成旧快照迁移。
- 修改：`GeminiAntigravity.ps1`，移除源码 secret，处理保存失败并校验配额字段。
- 修改：`CommandCodeQuota.ps1`，保留显式 0，拒绝非有限百分比。
- 修改：`ModelRequestRecorder.ps1`，修复空白 provider 与错误脱敏。
- 替换：`ChatGptUsageWidget.ps1`、`GrokUsageWidget.ps1`、`KimiUsageWidget.ps1`，保留参数兼容的统一入口包装器。
- 修改：四个 `Start-*.vbs` 启动器，固定受信任 PowerShell 路径并移除 Bypass。
- 修改：现有四个测试脚本，更新安全快照和校验行为断言。

### 任务 1：补充失败测试和纯函数边界

**文件：**
- 创建：`test-UsageValidation.ps1`
- 修改：`test-CommandCodeQuota.ps1`
- 修改：`test-ModelRequestRecorder.ps1`

- [x] **步骤 1：写入边界断言**

加入以下行为断言：缺失百分比抛出异常；显式 `0` 返回 `0`；NaN/Infinity/负数/大于 100 抛出异常；空白 provider 的非严格记录返回 `$null`，严格模式抛出“provider”错误；Command Code 的 `usagePercent = 0` 不回退到 weekly。

- [x] **步骤 2：运行测试确认当前实现失败**

运行：

```powershell
powershell -NoProfile -File .\test-UsageValidation.ps1
powershell -NoProfile -File .\test-CommandCodeQuota.ps1
powershell -NoProfile -File .\test-ModelRequestRecorder.ps1
```

预期：新增校验测试和显式零值断言失败，既有测试继续暴露现有实现差异。

### 任务 2：实现校验和受保护快照模块

**文件：**
- 创建：`UsageValidation.ps1`
- 创建：`SecureSnapshot.ps1`
- 创建：`test-SecureSnapshot.ps1`
- 修改：`test-UsageValidation.ps1`

- [x] **步骤 1：实现最小校验 API**

提供 `Assert-UsagePercent`、`Test-FiniteNumber`、`Convert-SafeLogText`；输入缺失、不可解析或越界时抛出明确异常，输入 `0` 返回数值 `0`。

- [x] **步骤 2：实现 DPAPI 快照 API**

提供 `Get-SecureSnapshotPath`、`Read-SecureSnapshot`、`Write-SecureSnapshot`、`Get-SecureSnapshotFiles`、`Remove-SecureSnapshot`。密文使用 `ConvertTo-SecureString`/`ConvertFrom-SecureString` 的当前用户 DPAPI，文件名使用 SHA-256，写入持有 `Local\AiUsageWidgetSnapshot-<hash>` 互斥，并通过同目录临时文件替换目标文件。

- [x] **步骤 3：运行模块测试确认通过**

运行：

```powershell
powershell -NoProfile -File .\test-UsageValidation.ps1
powershell -NoProfile -File .\test-SecureSnapshot.ps1
```

预期：输出 `ALL PASSED`；测试目录之外不产生快照文件。

### 任务 3：接入主 Widget 与 Grok 账户迁移

**文件：**
- 修改：`AiUsageWidget.ps1`
- 修改：`GrokAccounts.ps1`
- 修改：`GeminiAntigravity.ps1`
- 修改：`CommandCodeQuota.ps1`
- 修改：`ModelRequestRecorder.ps1`

- [x] **步骤 1：接入安全快照和并发保存**

主 Widget 通过 `SecureSnapshot.ps1` 读取 `codex`/`grok` 账户，新增账户时写入 DPAPI 快照；刷新 token 时对原始 CLI 文件和受保护快照分别使用命名互斥与原子替换。旧项目目录 `chatgpt-auth-*.json`、`grok-auth-*.json` 仅在成功读取并写入受保护快照后删除。

- [x] **步骤 2：接入所有工作线程函数**

把安全快照和校验函数加入 `Get-WorkerScriptSource` 的函数名单及 `$Cfg`，确保后台 runspace 与 STA 主线程使用相同实现。

- [x] **步骤 3：修复 API 校验与日志**

Grok、Kimi、Codex、Gemini、Command Code 解析缺失/非法字段时抛错；日志和 tooltip 通过 `Convert-SafeLogText` 脱敏，账户显示使用短标签，不写入完整邮箱、URL query 或响应正文。Gemini 保存失败不再静默吞掉，改为记录安全错误并继续返回内存 token。

- [x] **步骤 4：运行现有纯函数测试**

运行：

```powershell
powershell -NoProfile -File .\test-CommandCodeQuota.ps1
powershell -NoProfile -File .\test-GeminiQuota.ps1
powershell -NoProfile -File .\test-GrokAccounts.ps1
powershell -NoProfile -File .\test-ModelRequestRecorder.ps1
```

预期：所有脚本输出 `ALL PASSED`。

### 任务 4：加固启动器、Gemini 配置和统一入口

**文件：**
- 修改：`AiUsageWidget.ps1`
- 修改：`Start-AiUsageWidget.vbs`
- 修改：`Start-ChatGptUsageWidget.vbs`
- 修改：`Start-GrokUsageWidget.vbs`
- 修改：`Start-KimiUsageWidget.vbs`
- 替换：`ChatGptUsageWidget.ps1`
- 替换：`GrokUsageWidget.ps1`
- 替换：`KimiUsageWidget.ps1`

- [x] **步骤 1：固定 PowerShell 路径**

所有 VBS 和 STA 自重启逻辑只检查 `C:\Program Files\PowerShell\7\pwsh.exe` 与 `%WINDIR%\System32\WindowsPowerShell\v1.0\powershell.exe`，移除 PATH 枚举和 `-ExecutionPolicy Bypass`。

- [x] **步骤 2：统一旧入口**

旧脚本保留 `Install`、`Uninstall`、`AddAccount`、`IntervalSeconds` 参数，将参数转发到同目录 `AiUsageWidget.ps1`，不再加载重复 UI、认证和同步网络代码。

- [x] **步骤 3：移除网络不安全选项**

从 `Invoke-CurlJson` 删除 `--ssl-no-revoke`，保留 TLS 证书和系统吊销校验。

- [x] **步骤 4：运行 AST 和字符串安全扫描**

运行：

```powershell
Get-ChildItem -File -Filter '*.ps1' | ForEach-Object { [System.Management.Automation.Language.Parser]::ParseFile($_.FullName,[ref]$null,[ref]$null) | Out-Null }
rg -n --glob '*.ps1' --glob '*.vbs' 'ExecutionPolicy.*Bypass|ssl-no-revoke|FindPowerShell|GOCSPX-' .
```

预期：AST 无异常；扫描只允许出现迁移说明中的历史字符串，不允许出现可执行路径、curl 选项或源码 client secret。

### 任务 5：迁移、清理和完整验收

**文件：**
- 修改：`test-GrokAccounts.ps1`
- 修改：新增测试脚本
- 运行：项目目录内所有测试和扫描命令

- [x] **步骤 1：验证受保护快照发现**

使用临时 `%LOCALAPPDATA%` 目录写入两条 DPAPI 快照，确认主账户发现能读取它们，且项目目录没有生成 `*-auth-*.json`。

- [x] **步骤 2：验证旧快照迁移**

在临时目录创建一份旧格式快照，运行迁移函数，确认受保护文件存在、旧文件消失、账户仍能被发现；迁移失败时旧文件必须保留并报告错误。

- [x] **步骤 3：运行双版本回归**

运行 Windows PowerShell 5.1 和 PowerShell 7 的全部 `test-*.ps1`，再进行所有 `.ps1` AST 解析、明文敏感文件扫描和工作区状态检查。

- [x] **步骤 4：输出验收报告**

报告变更文件、通过的命令、未执行的真实 API/GUI 验证，以及仍需用户执行的 provider token 轮换动作。项目不是 Git 仓库，不执行提交操作。
