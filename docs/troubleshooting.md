# 排错手册

按现象查表；每条都给出可执行的验证命令。涉及日志时请先删除邮箱、账号与路径中的个人信息再对外粘贴。

## 先做这三件事

```powershell
# 1. 确认版本
pwsh -NoProfile -File .\AiUsageWidget.ps1 -Version

# 2. 用演示数据确认界面本身是好的（不读凭证、不写状态、不联网）
pwsh -NoProfile -File .\AiUsageWidget.ps1 -Demo

# 3. 看最近的日志
Get-Content -LiteralPath .\ai-widget.log -Tail 40
```

如果第 2 步能正常显示九行固定演示数据（Grok / Kimi / ChatGPT / Command Code / OpenRouter / DeepSeek / Claude / Cursor / GLM），说明界面与运行环境没问题，问题在凭证或网络。演示模式不含 Gemini 行。

## 卡片完全没有出现

| 可能原因 | 检查方式 | 处理 |
| --- | --- | --- |
| 已有实例在运行（单实例互斥） | `Get-Process pwsh, powershell -ErrorAction SilentlyContinue` | 先退出托盘图标里的旧实例 |
| 窗口被拖到屏幕外 | 删除状态文件 | `Remove-Item .\ai-state.json` 后重启（会回到默认位置） |
| 启动脚本被安全软件拦截 | 手动执行 `pwsh -NoProfile -File .\AiUsageWidget.ps1` | 看控制台是否报错，并检查 `ai-widget.log` |
| 脚本被"阻止"属性标记 | `Get-Item .\AiUsageWidget.ps1 -Stream Zone.Identifier` | `Unblock-File .\*.ps1` |

## 卡片显示"未找到登录凭证"

说明所有供应商的凭证都不存在。先登录任意一个供应商的 CLI，再点"立即刷新"：

| 供应商 | 登录方式 | 期望文件 |
| --- | --- | --- |
| Grok | Grok CLI 登录 | `~/.grok/auth.json` |
| Kimi | `kimi` CLI 登录 | `~/.kimi-code/credentials/kimi-code.json` |
| ChatGPT / Codex | Codex CLI 登录 | `~/.codex/auth.json` |
| Command Code | Command Code CLI 登录 | `~/.commandcode/auth.json` |
| Gemini / Antigravity | 登录 Antigravity | 凭据管理器条目 `gemini:antigravity` |
| OpenRouter | 在网页端创建 API Key | `~/.openrouter/auth.json` 或 `$env:OPENROUTER_API_KEY` |

Grok 与 ChatGPT / Codex 是多账号模式：`auth.json` 存在后，还需要在右键菜单里"登记 Grok 账号" / "登记 ChatGPT 账号"，
卡片才会为每个已登记账号渲染一行。

## 某一行显示"登录已过期，请重新登录"

- token 过期且自动刷新失败。先用对应 CLI 重新登录，再点"立即刷新"。
- Gemini / Antigravity 需要 `ANTIGRAVITY_CLIENT_SECRET` 环境变量才能刷新；没有该变量时登录过期后无法自动续期。
- 如果 CLI 登录后仍然报错，检查系统时间是否准确（OAuth 校验对时间偏差敏感）。

## 显示"请求超时"或"网络连接失败"

- 单个请求的超时是 15 秒，并由 `WaitOne` 做硬超时；偶发超时会自动进入指数退避（30 秒起，最长 15 分钟）。
- 使用代理时，请确认 PowerShell 能走通代理：`Invoke-RestMethod https://chatgpt.com/backend-api/wham/usage` 之类的探测会直接反映真实连通性。
- "网络连接失败"通常来自 TLS 证书或企业网络中间人代理，不是本程序的问题。
- 失败信息只在卡片上显示简短短语，详细原因（已脱敏）在 `ai-widget.log` 里。

## 显示"请求过于频繁"

服务端返回 429。程序会自动退避，不需要手工处理；频繁刷新（例如 1 分钟间隔 + 多个账号）更容易触发。

## 关于窗口提示“请求过于频繁”

GitHub 对未认证请求按 IP 限制每小时 60 次，检查更新与下载 Release 共用这一份额度。等一段时间再试即可；卡片本身的抓取走各家自己的接口，不受影响。

## Command Code 一行没有数据

- 确认 `~/.commandcode/auth.json` 存在，且组织标识可读取；缺少组织标识时会显示"暂无用量数据"。
- 默认不显示余额，这是刻意设计；需要时把 `$script:CommandCodeShowBalance` 改成 `$true` 再重启。
- 该接口路径为 `/alpha/billing/credits`，如果服务端改了路径，需要在 `CommandCodeQuota.ps1` 与主脚本的调用处同步更新。

## OpenRouter 一行没有数据

- 确认 `~/.openrouter/auth.json`（或 `$env:OPENROUTER_API_KEY`）能读到密钥；读取顺序是文件优先、环境变量兜底。
- 密钥没有设置上限时该行显示"未设上限"，百分比固定为 0%，这是刻意设计，不是取数失败。
- `usage` / `limit` 异常（缺失、非数字、`limit` 不是正数）时显示"暂无用量数据"；可用
  `Invoke-RestMethod https://openrouter.ai/api/v1/key -Headers @{ Authorization = "Bearer $env:OPENROUTER_API_KEY" }` 核对服务端返回。
- 卡片只显示密钥指纹（形如 `OpenRouter-1f4a2c7e`），完整密钥不会出现在界面或日志里。

## DeepSeek 一行没有数据

- 该行只在发现凭证时出现：`~/.deepseek/auth.json`（内含 `apiKey` / `api_key` / `key` / `token`）或 `$env:DEEPSEEK_API_KEY`；两者都没有时是预期的不显示。
- 密钥被吊销或过期会显示"登录已过期，请重新登录"：去 platform.deepseek.com 重新生成密钥并更新文件即可。
- 余额为 `0` 仍然显示 `¥0.00`（或对应币种），这是真实余额而不是读取失败。
- 卡片显示的是**总余额**（充值 + 赠额），明细行分别列出两者，便于核对。

## Kimi 一行没有数据

- 区域文件 `~/.kimi-code/region` 含 `global` 时走 `kimi.ai` 域名，否则走 `kimi.com`；域名与账号区域不匹配会取不到数据。
- 需要临时覆盖时可设置 `KIMI_CODE_OAUTH_HOST` / `KIMI_CODE_BASE_URL`，但主机必须在白名单内，否则请求会被拒绝。

## 主题颜色不对 / 想换回深色

- `ai-config.json` 的 `theme` 只接受 `dark` / `light`，非法值自动回退到 `dark`；设置窗口保存后立即生效，无需重启。
- 想临时对比两套主题，可以运行 `AiUsageWidget.ps1 -Demo -Theme light`（或 `-Theme dark`），只影响本次运行、不改写配置文件。
- 右键菜单与托盘气泡来自系统原生控件，不随主题变化，这是预期行为。
- 如果界面出现品红色块，说明某个控件引用了调色板里不存在的键：请附上截图与 `ai-widget.log` 提 Issue。

## 开机启动没有生效

- 检查启动文件夹快捷方式：`$([Environment]::GetFolderPath('Startup'))` 下的 `AI 周用量.lnk`。
- 右键菜单的"开机启动"是开关：显示"取消开机启动"表示当前已启用。
- 旧的单供应商快捷方式（`Grok 周用量.lnk` 等）会被自动清理，属于正常行为。
- 系统"启动应用"列表中若把 Windows Script Host 禁用了，VBS 启动器不会运行，需要在组策略中放开。

## 文字被裁剪 / 高分屏显示异常

- 布局按启动时那块屏幕的 DPI 缩放（100% / 125% / 150% / 200% 均已覆盖）。
- 若在系统缩放比例切换后仍异常，先退出再启动一次，让缓存的字体与 `UiScale` 重新计算。
- 多显示器不同 DPI 时，卡片不会在拖到另一屏后自动按新 DPI 重算；请在目标屏幕上重新启动一次。

## 想彻底卸载

1. 托盘图标右键 → 退出。
2. 用安装器卸载：`.\install.ps1 -Uninstall`（保留用户数据）或 `.\install.ps1 -Uninstall -Purge`（连用户数据与账户快照一起删除）。
3. 手动卸载时：删除程序目录（含 `ai-state.json`、`ai-history.jsonl`、`ai-request-events.jsonl`、`ai-widget.log`）。
4. 删除受保护的账号快照：`Remove-Item "$env:LOCALAPPDATA\AIUsageWidget" -Recurse`。
5. 右键菜单里若有"取消开机启动"，先点它（或手动删除启动文件夹里的 `AI 周用量.lnk`）。
6. `~/.grok`、`~/.kimi-code`、`~/.codex`、`~/.commandcode`、`~/.openrouter`、`~/.deepseek`、`~/.claude`、`~/.zai`、`~/.zhipu` 以及 Cursor 的 `%APPDATA%\Cursor` 是各供应商自己的数据，本程序不会写入（Claude 令牌过期时会原地刷新），按需自行保留。

## 想改列数 / 卡片变得很宽

卡片按 `columns` 排成 1 - 3 列。3 列时窗体宽度约等于单列的 3 倍，屏幕放不下时会被夹在屏幕边缘。
右键 → **设置…** → 「窗口列数」调小即可，也可以直接改 `ai-config.json` 的 `columns`，保存后立即重排，不用重启。

多列不会压缩每一行：行宽仍是单列宽度，只是把行折成多条"行带"（例如 9 行 3 列 = 3 条行带）。
所以 3 列 9 行和 1 列 3 行一样高。

## 每日汇总没有弹出来

按顺序检查这五条：

1. `ai-config.json` 里 `dailySummary.enabled` 是不是 `true`（对应设置窗口里的「每日汇总」勾选框）；
2. 当前时间是否已经过了 `dailySummary.time`（默认 `09:00`），没到点不会提前弹；
3. 当天是否已经弹过一次：日期写在 `ai-state.json` 的 `lastSummaryDate`，同一天只弹一次，删掉这个字段即可重置；
4. 是否落在静音时段（`quietHours`），静音对所有气泡都生效；
5. 卡片上是否已经有数据：一行都没读到数据时不发汇总。

## GitHub Copilot 一行没有数据

Copilot 行只在**本机存在凭证**时才出现，按顺序尝试下面三处：

| 顺序 | 路径 | 取的键 |
| --- | --- | --- |
| 1 | `~/.config/github-copilot/hosts.json` | `oauth_token` |
| 2 | `~/.config/github-copilot/apps.json` | `access_token` |
| 3 | `~/.local/share/opencode/auth.json` | `github-copilot.access` |

- 三处都没有时这一行完全不出现，不会显示成空行。
- 路径不在默认位置时用 `$env:GH_COPILOT_HOSTS` 直接指定 hosts.json，或用 `$env:COPILOT_CONFIG_DIR` 换配置目录。
- 有凭证却报错：`copilot_internal/user` 是社区在用的内部接口，不是官方文档接口，
  GitHub 改版后可能返回 401 / 404，日志里会记下状态码，请连同版本号一起反馈。

## 导出历史没有生成文件

按顺序检查这五条：

1. 弹出的是「还没有历史数据可导出」：`ai-history.jsonl` 一条记录都没有，先让卡片正常运行一段时间；
2. 导出的是**最近一个有数据的月份**，不是全部历史，文件在程序目录，形如 `ai-usage-report-2026-09.csv` / `.md` / `.html`；
   「多月对比」两项默认取**最近 3 个有数据的月份**，文件名形如 `ai-usage-comparison-2026-07_2026-09.md`；
3. 选中月份没有采样时会提示「该月没有历史采样」，换回有数据的月份即可；
4. CSV 里的中文乱码：导出写的是 UTF-8 带 BOM，如果被编辑器 / Excel 以外的工具转存过，BOM 可能丢失；
5. 提示「导出失败，请查看日志」：`ai-widget.log` 里有 `report export failed` 一行，通常会带出真实的文件系统错误。

Markdown / HTML 报表是该月按天 + 按供应商的汇总，不包含逐条原始采样；要原始数据请用同一子菜单里的「原始采样 CSV」。
多月对比表里某个单元格是 `-`，表示该供应商在那个月没有采样——占位符是正常的，不是导出失败。

## 趋势图窗口是空的或者打不开

先确认数据侧再怀疑界面：

1. `ai-history.jsonl` 有没有内容、时间戳是否落在所选窗口内（趋势图只看最近 7 / 14 / 30 天）；
2. 某个供应商采样不足窗口天数时**只画已有的点**，不补零，这是预期行为；
3. 右键菜单里的入口是「趋势图…」；用 `pwsh -NoProfile -File .\AiUsageWidget.ps1 -Demo -TrendWindow`
   可以在没有凭证、没有历史的情况下确认窗口本身能画出来；
4. 窗口是只读的：它不会写 `ai-history.jsonl`、状态文件与凭证，所以「打开后历史没变化」是正常的；
5. 想确认是数据问题还是界面问题，看 `ai-widget.log` 里 `trend window shown days=... series=...` 这行的 `series` 数量，
   为 0 就说明窗口打开了但所选窗口内确实没有采样。

## GLM 一行提示「该账号未开通 Coding Plan」

这是服务端返回的业务错误（`code != 0`），说明凭证有效、请求也被接受，但该账号没有可查询的 Coding Plan 配额：

- 用 ZCode 凭证时，ZCode 里登录的账号与开通 Coding Plan 的账号必须是同一个；
- 确认开通的是 Coding Plan；普通 API 按量计费的 key 没有这套 5 小时 / 周窗口配额；
- 试一下其他凭证来源（`$env:ZAI_API_KEY` / `~/.zai/auth.json` / `~/.bigmodel/auth.json`）：
  换成别的来源能显示，说明只是 ZCode 那个账号没开通。

## 报告问题前请准备

- `pwsh -NoProfile -File .\AiUsageWidget.ps1 -Version` 的输出。
- 你使用的 PowerShell 版本（5.1 还是 7.x）。
- `ai-widget.log` 中相关片段（**先删除邮箱、账号与路径信息**）。
- 如果能用 `-Demo` 模式复现，请说明；这能直接区分"界面问题"与"凭证/网络问题"。
