# 供应商支持与扩展指南

本文记录每个供应商的数据来源、降级策略，以及新增一个供应商需要改动的全部位置。

## 支持情况总览

| 供应商 | 行 Kind | 凭证来源 | 配额接口 | 行数 |
| --- | --- | --- | --- | --- |
| Grok | `grok` | `~/.grok/auth.json`（或 `$env:GROK_HOME`） | `https://cli-chat-proxy.grok.com/v1/billing?format=credits` | 每个已登记账号一行 |
| Gemini / Antigravity | `gemini` | Windows 凭据管理器 `gemini:antigravity` | `https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuotaSummary` | 1 |
| Kimi | `kimi` | `~/.kimi-code/credentials/kimi-code.json`（或 `$env:KIMI_CODE_HOME`） | `https://api.kimi.com/coding/v1` 或 `https://api.kimi.ai/coding/v1` | 1 |
| ChatGPT / Codex | `codex` | `~/.codex/auth.json`（或 `$env:CODEX_HOME`） | `https://chatgpt.com/backend-api/wham/usage` | 每个账号一行 |
| Command Code | `commandcode` | `~/.commandcode/auth.json`（或 `$env:COMMAND_CODE_HOME`） | `https://api.commandcode.ai` 的 `/alpha/billing/credits` | 1 |

## 各供应商细节

### Grok

- **账号识别**：`GrokAccounts.ps1` 读取 `auth.json` 里的 token，取出账号标识后生成短指纹作为行名与快照文件名；
  仓库里不出现邮箱，日志里也只有指纹。
- **多账号**：右键"登记 Grok 账号"会把当前 `~/.grok/auth.json` 复制为受保护的账号快照；
  卡片为每个快照渲染一行，行名形如 `Grok-1f4a2c7e`。
- **令牌刷新**：过期时用 `https://auth.x.ai/oauth2/token` 刷新，并回写 `auth.json`；刷新失败显示"登录已过期，请重新登录"。
- **数据映射**：`Get-GrokUsageSnapshot` 取 billing credits，`Get-GrokRowData` 组合出百分比、明细与重置时间。
- **刷新代价**：每个账号一次请求，多账号时行数等于账号数。

### Gemini / Antigravity

- **凭证**：直接复用 Antigravity 写在 Windows 凭据管理器里的条目，target 为 `gemini:antigravity`；本程序只读写这一条。
- **刷新**：token 过期时用 `https://oauth2.googleapis.com/token` 刷新，需要 `ANTIGRAVITY_CLIENT_SECRET` 环境变量；
  缺少该变量时不会崩，只是提示无法刷新登录。
- **数据映射**：`Convert-GeminiQuota` 把 `retrieveUserQuotaSummary` 的返回转成百分比与重置时间。
- **降级**：凭据不存在时该行整体不出现（不会显示成一个空洞）。

### Kimi

- **凭证**：`~/.kimi-code/credentials/kimi-code.json`；区域由 `~/.kimi-code/region` 决定（含 `global` 时走 `kimi.ai` 域名）。
- **主机选择**：`Get-KimiHosts` 支持 `KIMI_CODE_OAUTH_HOST` / `KIMI_CODE_BASE_URL` 覆盖，但最终都要通过
  `Resolve-TrustedHttpsEndpoint` 白名单校验（仅允许 `auth.kimi.com`、`auth.kimi.ai`、`api.kimi.com`、`api.kimi.ai`）。
- **解析**：`KimiQuota.ps1` 是纯函数模块，负责把载荷里的窗口时长换算成小时、识别周窗口与已用比例；
  `Resolve-KimiUsedLimit` 处理"已用/限额"两种字段可能缺一的载荷。
- **降级**：载荷缺字段时返回"暂无用量数据"而不是抛异常。

### ChatGPT / Codex

- **凭证**：`~/.codex/auth.json`；`Get-CodexAccounts` 枚举本机已保存的账号快照。
- **刷新**：使用 `https://auth.openai.com/oauth/token` 刷新后回写 `auth.json`。
- **窗口**：`Get-CodexWindowInfo` 从 `wham/usage` 的返回里同时取 5 小时窗口与周窗口，
  两者都放进明细文本，例如 `5h 32% · 周 68%`。
- **多账号**：右键"登记 ChatGPT 账号"新增一个账号快照；同一时刻登录的账号由 `Sync-ActiveCodexSnapshot` 保持最新。

### Command Code

- **凭证**：`~/.commandcode/auth.json`；`Get-CommandCodeOrgId` 取组织标识。
- **窗口**：接口返回日、5 小时、周三个滚动窗口，`Convert-CCWindow` 统一换算；
  余额默认不显示，需要时把 `$script:CommandCodeShowBalance` 设为 `$true`。
- **时间**：`Convert-CommandCodeTime` 负责把服务端时间转成本地重置时间。
- **降级**：组织标识缺失或返回空窗口时显示"暂无用量数据"，不影响其他行。

## 新增一个供应商

以接入 `Claude Code` 为例，一共七步，缺任何一步都会静默失效。

### 1. 新建纯解析模块 + 测试

`ClaudeQuota.ps1` 只做解析与换算，不读文件、不发请求：

```powershell
# ClaudeQuota.ps1
function Convert-ClaudeWindow {
    param($Window)
    if (-not $Window) { throw 'Claude 限额窗口为空' }
    # 返回 @{ Percent = ...; Reset = ...; Label = '周' }
}
```

配套 `test-ClaudeQuota.ps1` 使用真实载荷的**脱敏副本**，断言边界情况：字段缺失、0%、超过 100%、时间单位异常。

### 2. 凭证读取与刷新

在模块里实现 `Read-ClaudeAuth` / `Save-ClaudeAuth` / `Update-ClaudeToken`，并让快照统一走 `SecureSnapshot.ps1`
（不要自己写文件读写），这样 ACL、原子替换与文件锁都是现成的。

### 3. 快照与行数据

实现 `Get-ClaudeUsageSnapshot`（发请求 + 解析）与 `Get-ClaudeRowData`（返回 `Percent` / `Detail` / `Tip` / `Reset`）。
`Percent` 一律表示**已用**百分比。

### 4. `Get-ProviderRows` 增加行定义

在 `AiUsageWidget.ps1` 的 `Get-ProviderRows` 中先判断凭证是否存在（`Test-Path` 或凭据管理器查询），
存在才追加行；不存在就完全不出现，避免出现空行。

### 5. 注入 worker

更新 `Get-WorkerScriptSource` 里的三处：

- `$fnNames` 数组：把新函数名按**调用顺序**加入（先工具函数，再业务函数）；
- 变量白名单 `foreach ($v in ...)`：把新用到的路径、URL、client id 加进去；
- `switch ($row.Kind)`：增加 `'claude' { $d = Get-ClaudeRowData }` 分支。

### 6. 菜单与用量页

在 `New-WidgetForm` 的"打开用量页"子菜单里增加条目，指向该供应商的官方用量页面。

### 7. 文档

在本文的"支持情况总览"里补一行，并写清字段来源、限流与失败降级策略。
同时更新 `README.md` / `README.en.md` 的支持列表与 `CHANGELOG.md`。

## 测试要求

- 新增模块必须有同名 `test-*.ps1`，并断言 `ALL PASSED`。
- 测试不得联网、不得读取真实凭证、不得写入用户目录；用内联载荷或 `$env:TEMP` 下的临时文件。
- 在 Windows PowerShell 5.1 与 PowerShell 7 下都要通过，CI 会双版本执行。

## 常见坑

| 现象 | 原因 |
| --- | --- |
| 其他行正常，新行永远"无数据" | worker 的 `$fnNames` 或 `$Cfg` 少了一项，或 `switch ($row.Kind)` 没加分派 |
| 显示成 0% 却不刷新 | 把 `0` 当成了"没有数据"；`0` 是合法百分比，需要照常显示 |
| 中文乱码 | 新增 `.ps1` 文件没带 UTF-8 BOM，Windows PowerShell 5.1 会按 ANSI 读取 |
| 一个供应商慢导致整轮卡住 | 请求没有走 `Invoke-WidgetRest`，丢失了硬超时保护 |
| 日志里出现 token 片段 | 直接写了原始异常或响应体，应改用 `Convert-SafeLogText` |
