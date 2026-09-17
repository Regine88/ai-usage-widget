# 供应商支持与扩展指南

本文记录每个供应商的数据来源、降级策略，以及新增一个供应商需要改动的全部位置。

## 支持情况总览

| 供应商 | 行 Kind | 凭证来源 | 配额接口 | 行数 |
| --- | --- | --- | --- | --- |
| Grok | `grok` | `~/.grok/auth.json`（或 `$env:GROK_HOME`） | `https://cli-chat-proxy.grok.com/v1/billing?format=credits` | 每个已登记账号一行 |
| Gemini / Antigravity | `gemini` | Windows 凭据管理器 `gemini:antigravity` | `https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuotaSummary` | 1 |
| Kimi | `kimi` | `~/.kimi-code/credentials/kimi-code.json`（或 `$env:KIMI_CODE_HOME`） | `https://api.kimi.com/coding/v1` 或 `https://api.kimi.ai/coding/v1` | 1 |
| ChatGPT / Codex | `codex` | `~/.codex/auth.json`（或 `$env:CODEX_HOME`） | `https://chatgpt.com/backend-api/wham/usage` | 每个账号一行 |
| Command Code | `commandcode` | `~/.commandcode/auth.json`（或 `$env:COMMAND_CODE_HOME`） | `https://api.commandcode.ai` 的 `/alpha/billing/credits`（5 小时 / 周） | 1 |
| OpenRouter | `openrouter` | `~/.openrouter/auth.json`（或 `$env:OPENROUTER_HOME`）、`$env:OPENROUTER_API_KEY` | `https://openrouter.ai/api/v1/key` | 每个密钥一行 |
| DeepSeek | `deepseek` | `~/.deepseek/auth.json`（或 `$env:DEEPSEEK_HOME`）、`$env:DEEPSEEK_API_KEY` | `https://api.deepseek.com/user/balance` | 1 |
| Claude Code | `claude` | `~/.claude/.credentials.json`（或 `$env:CLAUDE_HOME`） | `https://api.anthropic.com/api/oauth/usage` | 1 |
| Cursor | `cursor` | `%APPDATA%\Cursor\User\globalStorage\state.vscdb`（或 `$env:CURSOR_STATE_DB`） | `https://api2.cursor.sh/aiserver.v1.DashboardService/GetCurrentPeriodUsage` | 1 |
| GLM / Z.AI / 智谱 BigModel | `glm` | `~/.zai/auth.json` / `~/.zhipu/auth.json` / `~/.bigmodel/auth.json`、ZCode 的 `~/.zcode/v2/config.json`、`$env:ZAI_API_KEY` / `$env:ZHIPU_API_KEY` / `$env:BIGMODEL_API_KEY` | `https://api.z.ai/api/monitor/usage/quota/limit`（中国站 `https://open.bigmodel.cn/api/monitor/usage/quota/limit`） | 1 |
| GitHub Copilot | `copilot` | `~/.config/github-copilot/hosts.json` / `apps.json`、`~/.local/share/opencode/auth.json`（或 `$env:COPILOT_CONFIG_DIR` / `$env:GH_COPILOT_HOSTS`） | `https://api.github.com/copilot_internal/user` | 1 |

## 各供应商细节

### Grok

- **账号识别**：`GrokAccounts.ps1` 读取 `auth.json` 里的 token，取出账号标识后生成短指纹作为行名与快照文件名；
  仓库里不出现邮箱，日志里也只有指纹。
- **多账号**：右键"登记 Grok 账号"会把当前 `~/.grok/auth.json` 复制为受保护的账号快照；
  卡片为每个快照渲染一行，行名形如 `Grok-1f4a2c7e`。
- **账号别名**（可选）：默认行名就是指纹。想换成短名字时，在程序目录放一个 `grok-aliases.json`，
  形如 `{ "Grok-1f4a2c7e": "a" }`（键是行名里的指纹）；也可以在运行期设置 `$script:GrokAccountAliases`。
  别名由真实账号标识推导而来，属于本机数据：该文件已被 `.gitignore` 排除，不要提交。
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
- **窗口**：接口返回 5 小时与周两个滚动窗口，`Convert-CCWindow` 统一换算；
  余额默认不显示，需要时把 `$script:CommandCodeShowBalance` 设为 `$true`。
- **时间**：`Convert-CommandCodeTime` 负责把服务端时间转成本地重置时间。
- **降级**：组织标识缺失或返回空窗口时显示"暂无用量数据"，不影响其他行。

### OpenRouter

- **凭证**：`~/.openrouter/auth.json`（可用 `$env:OPENROUTER_HOME` 改目录）里的 `apiKey` / `api_key` / `key` / `token`，
  以及 `$env:OPENROUTER_API_KEY`；同一密钥在两处出现只算一行。
- **多密钥**：每个密钥一行，行名是密钥的短指纹（形如 `OpenRouter-1f4a2c7e`），密钥本身既不进界面也不进日志。
- **额度语义**：`/api/v1/key` 返回该密钥的累计消费 `usage` 与创建时设定的上限 `limit`。
  有上限时显示「已用 $12.50 / 上限 $100.00（12.5%）」；`limit` 为 `null` 时显示「已用 $12.50（未设上限）」，
  这一行按 0% 参与配色与趋势，而不是伪装成「没有数据」。
- **无刷新流程**：密钥在网页端创建，没有 OAuth 刷新流程；`401` 直接显示「登录已过期，请重新登录」，不重试。
- **降级**：`usage` 缺失或不是有限数、`limit` 不是正数时该行显示「暂无用量数据」，不影响其他行。

### DeepSeek

- **凭证**：`~/.deepseek/auth.json`（可用 `$env:DEEPSEEK_HOME` 改目录）里的 `apiKey` / `api_key` / `key` / `token`，
  以及 `$env:DEEPSEEK_API_KEY`；读取与请求规则和 OpenRouter 共用 `ApiKeyAuth.ps1`（DRY，不再各写一份）。
- **余额语义**：`/user/balance` 返回账户预充值余额，`balance_infos` 可能同时含 USD 与 CNY 两个钱包；
  取第一个**有余额**的钱包，全为 0 时退回第一个可读钱包。金额按 invariant culture 格式化，绝不随系统区域设置变成逗号。
- **行显示**：余额型供应商没有百分比，主数值直接显示金额（如 `¥1.58`），该行按 0% 参与配色；
  明细行给出来源构成（充值 / 赠额），`is_available` 显式为 false 时额外提示余额不足。
- **无刷新流程**：密钥在网页端创建，没有 OAuth 刷新流程；`401` 直接显示「登录已过期，请重新登录」，不重试。
- **降级**：`balance_infos` 缺失或无法解析时该行显示「暂无用量数据」，不影响其他行。

### Claude Code

- **凭证**：`~/.claude/.credentials.json`（可用 `$env:CLAUDE_HOME` 改目录）里的 `claudeAiOauth` 或 `oauth`。只认 OAuth，不认 `ANTHROPIC_API_KEY`（API key 账户没有订阅配额窗口）。
- **窗口**：`GET https://api.anthropic.com/api/oauth/usage`，请求头带 `anthropic-beta: oauth-2025-04-20`。`five_hour` / `seven_day` 的 `utilization` 已是已用百分比；卡片主数值取两者中较大的那个。
- **刷新**：access token 过期前 2 分钟用 refresh token 打 `platform.claude.com/v1/oauth/token`，失败再试 `console.anthropic.com`；刷新成功后写回原凭证文件。
- **降级**：没有 `.credentials.json` 时这一行不出现。载荷缺窗口或百分比非法时该行报错，不影响其他行。

### Cursor

- **凭证**：本机 Cursor 编辑器的 `%APPDATA%\Cursor\User\globalStorage\state.vscdb` 中 `cursorAuth/accessToken`（JWT）。不引入 sqlite 依赖，按 key 扫描文本。可用 `$env:CURSOR_STATE_DB` 覆盖路径。
- **额度语义**：`POST https://api2.cursor.sh/aiserver.v1.DashboardService/GetCurrentPeriodUsage`，`planUsage.totalPercentUsed` 为已用百分比；`remaining` / `limit` 单位是美分，明细里换成美元。
- **无刷新流程**：token 由 Cursor 自己维护；`401` 显示登录过期。
- **降级**：找不到 state 库或扫不到 JWT 时这一行不出现。接口缺 `planUsage` 时该行报错。

### GLM / Z.AI

- **凭证**：按 `Resolve-ZaiCredential` 的顺序查找：`$env:ZAI_API_KEY` → `$env:ZHIPU_API_KEY` → `$env:BIGMODEL_API_KEY`
  → `~/.zai/auth.json` → `~/.zhipu/auth.json` → `~/.bigmodel/auth.json` → ZCode 的 `~/.zcode/v2/config.json`
  （读 `builtin:bigmodel-coding-plan` 或 `builtin:bigmodel` 的 `options.apiKey`；可用 `$env:ZCODE_CONFIG` 换路径）。
  请求头是 `Authorization: <key>`，**没有** `Bearer ` 前缀。找不到任何凭证时这一行不出现。
- **主机**：默认 `https://api.z.ai`；凭证来自智谱中国站（`ZHIPU_API_KEY` / `BIGMODEL_API_KEY` / `.zhipu` / `.bigmodel` / ZCode）时改走
  `https://open.bigmodel.cn`。也可用 `$env:ZAI_API_BASE` 覆盖。
- **窗口**：`GET /api/monitor/usage/quota/limit` 的 `limits[]`，匹配 5 小时与周两类 `type`；`percentage` 是已用百分比。
  中国站与国际站路径一致、鉴权方式也一致（2026-09-17 实测：同一把密钥在两个主机上返回同一种业务错误）。
- **业务错误**：服务端用 `{"code":500,"msg":"当前用户不存在coding plan","success":false}` 这类信封表达
  「账号没有 Coding Plan」。`Get-ZaiBusinessError` 把 `msg` 交给 `Format-FetchError`，
  该行显示本地化的「该账号未开通 Coding Plan」，而不是笼统的读取失败。
- **降级**：`limits` 为空或无法识别窗口时该行报错，不影响其他行。

### GitHub Copilot

- **凭证**：按顺序尝试 `~/.config/github-copilot/hosts.json`（`github.com.oauth_token`）、同目录的 `apps.json`（`access_token`）、
  `~/.local/share/opencode/auth.json`（`github-copilot.access`）。`$env:COPILOT_CONFIG_DIR` 换配置目录，`$env:GH_COPILOT_HOSTS` 直接指定 hosts.json。
- **解析**：这些文件的结构随扩展版本变化，所以 `Find-CopilotToken` 深度优先地找第一个非空字符串形式的 `oauth_token` / `oauthToken` / `access_token` / `accessToken` / `access`，不绑定固定层级；数字与布尔值一律忽略。
- **请求头**：`Authorization: token <token>`，另加 `Editor-Version: vscode/1.96.2` 与 `X-Github-Api-Version: 2025-04-01`。这是社区通用做法，不是官方文档接口，GitHub 改版时这里最先失效。
- **数据映射**：主数值取 `quota_snapshots.premium_interactions`。`Convert-CopilotQuotaDetail` 优先用 `entitlement` / `remaining` 算已用百分比，缺计数时退回 `percent_remaining`；`unlimited: true`（chat / completions 常见）按 0% 处理，明细里直接写「不限量」。
- **重置**：`quota_reset_date` 给出下一个配额周期的起始日，换算成本地时间后进明细与耗尽预测。
- **降级**：三处都找不到 token 时这一行不出现；载荷缺少 `premium_interactions` 时该行报错，不影响其他行。

### 暂不接入的供应商

下面两家目前没有稳定的配额接口，接进来只会变成"永远读不到数据"，因此本轮不接入。
真要继续，先确认接口存在，再按下面的七步走。

| 供应商 | 现状 |
| --- | --- |
| 通义千问 Qwen（qwen-code OAuth） | `portal.qwen.ai` 只有 chat 端点，`~/.qwen/oauth_creds.json` 里没有配额字段，官方也没有公开的用量接口。 |
| 豆包 / 火山引擎 Ark | 用量只出现在控制台的浏览器会话里（`console.volcengine.com/api/top/...`），或者需要 AK/SK 签名（`open.volcengineapi.com?Action=GetCodingPlanUsage`）；前者要抓 Cookie，后者要实现一套签名，都不适合放进只读卡片。 |
| Trae（字节） | 只有内部接口 `coresg-normal.trae.ai/api/v1/commercial/get_mode_info` 与 `/api/v1/commercial/chat_mode`（POST，约 19 个请求头，含 `Cloud-IDE-JWT`），token 存在 `%APPDATA%\Trae\User\globalStorage\state.vscdb`，拿不到可离线验证的成功载荷。 |
| Amp（Sourcegraph） | 2026-09-17 在本机扫描时 `~/.amp` 只有 CLI 安装包（`bin/`、`package/`）与两个 bootstrap 脚本，没有可读的凭证文件，无法验证配额接口。 |
| CodeBuddy（腾讯） | 本机只有 IDE 数据目录（`%APPDATA%\CodeBuddy`）与 `~/.codebuddy` 的插件配置，没有 CLI 凭证文件，同样无法验证配额接口。 |

调研记录（2026-09-17）：智谱 BigModel 已并入 GLM 行（见上一节）；Trae / Amp / CodeBuddy 在本机都有使用痕迹，
但不具备「可读凭证 + 可验证接口」的组合，因此本轮不接入，等条件具备再按下面的七步走。

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

实现 `Get-ClaudeUsageSnapshot`（发请求 + 解析）与 `Get-ClaudeRowData`（返回 `Percent` / `Detail` / `Tip` / `Reset`，余额型再带一个 `Display`）。
`Percent` 一律表示**已用**百分比；余额型供应商用 `Display` 直接给出主数值文本（如 `¥1.58`），`Percent` 保持 `0`。

### 4. `Get-ProviderRows` 增加行定义

在 `AiUsageWidget.ps1` 的 `Get-ProviderRows` 中先判断凭证是否存在（`Test-Path` 或凭据管理器查询），
存在才追加行；不存在就完全不出现，避免出现空行。
同时把新供应商的默认开关加进 `WidgetConfig.ps1` 的 `Get-WidgetConfigDefaults` → `providers`，
否则设置窗口里不会出现它（`Test-ProviderEnabled` 对未知 `Kind` 默认放行，所以功能本身不受影响）。

### 5. 注入 worker

更新 `Get-WorkerScriptSource` 里的三处：

- `$fnNames` 数组：把新函数名按**调用顺序**加入（先工具函数，再业务函数）；
- 变量白名单 `foreach ($v in ...)`：把新用到的路径、URL、client id 加进去；
- `switch ($row.Kind)`：增加 `'claude' { $d = Get-ClaudeRowData }` 分支。

### 6. 菜单与用量页

在 `New-WidgetForm` 的"打开用量页"子菜单里增加条目，指向该供应商的官方用量页面。

### 7. 文档与打包清单

在本文的"支持情况总览"里补一行，并写清字段来源、限流与失败降级策略。
同时更新 `README.md` / `README.en.md` 的支持列表与 `CHANGELOG.md`。

新模块必须加进 `WidgetInstaller.ps1` 的运行文件清单；漏掉会出现「装完就缺模块」，
Release 包也会缺文件，`tools/verify-package.ps1`（以及 CI 的 `Package contents` job）会直接报「缺少条目」。

## 测试要求

- 新增模块必须有同名 `test-*.ps1`，并断言 `ALL PASSED`。
- 测试不得联网、不得读取真实凭证、不得写入用户目录；用内联载荷或 `$env:TEMP` 下的临时文件。
- 在 Windows PowerShell 5.1 与 PowerShell 7 下都要通过，CI 会双版本执行。

## 常见坑

| 现象 | 原因 |
| --- | --- |
| 其他行正常，新行永远"无数据" | worker 的 `$fnNames` 或 `$Cfg` 少了一项，或 `switch ($row.Kind)` 没加分派 |
| 显示成 0% 却不刷新 | 把 `0` 当成了"没有数据"；`0` 是合法百分比，需要照常显示 |
| 余额型供应商显示成「0%」 | 行数据没有带 `Display`，主数值回退成了百分比；补上 `Display` 字段即可（见 DeepSeek 一节） |
| 中文乱码 | 新增 `.ps1` 文件没带 UTF-8 BOM，Windows PowerShell 5.1 会按 ANSI 读取 |
| 一个供应商慢导致整轮卡住 | 请求没有走 `Invoke-WidgetRest`，丢失了硬超时保护 |
| 设置窗口里没有新供应商的开关 | 忘了在 `Get-WidgetConfigDefaults` 的 `providers` 里加键（只是无法在界面关闭，功能正常） |
| Release 包里缺了新模块 | 忘了把它加进 `WidgetInstaller.ps1` 的运行文件清单；本地 `tools/verify-package.ps1` 与 CI 的 `Package contents` job 都会拦住 |
| 日志里出现 token 片段 | 直接写了原始异常或响应体，应改用 `Convert-SafeLogText` |
