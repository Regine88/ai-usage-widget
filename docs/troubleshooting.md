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

如果第 2 步能正常显示四行固定数据，说明界面与运行环境没问题，问题在凭证或网络。

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

## Kimi 一行没有数据

- 区域文件 `~/.kimi-code/region` 含 `global` 时走 `kimi.ai` 域名，否则走 `kimi.com`；域名与账号区域不匹配会取不到数据。
- 需要临时覆盖时可设置 `KIMI_CODE_OAUTH_HOST` / `KIMI_CODE_BASE_URL`，但主机必须在白名单内，否则请求会被拒绝。

## 开机启动没有生效

- 检查启动文件夹快捷方式：`$([Environment]::GetFolderPath('Startup'))` 下的 `AI 周用量.lnk`。
- 右键菜单的"开机启动"是开关：显示"取消开机启动"表示当前已启用。
- 旧的单供应商快捷方式（`Grok 周用量.lnk` 等）会被自动清理，属于正常行为。
- 系统"启动应用"列表中若把 Windows Script Host 禁用了，VBS 启动器不会运行，需要在组策略中放开。

## 文字被裁剪 / 高分屏显示异常

- 布局按显示器 DPI 缩放（100% / 125% / 150% / 200% 均已覆盖）。
- 若在缩放比例切换后仍异常，先退出再启动一次，让缓存的自定义字体重新计算。
- 多显示器不同 DPI 时，把卡片拖到目标屏幕后会按该屏幕重新缩放。

## 想彻底卸载

1. 托盘图标右键 → 退出。
2. 用安装器卸载：`.install.ps1 -Uninstall`（保留用户数据）或 `.install.ps1 -Uninstall -Purge`（连用户数据与账户快照一起删除）。
3. 手动卸载时：删除程序目录（含 `ai-state.json`、`ai-history.jsonl`、`ai-request-events.jsonl`、`ai-widget.log`）。
4. 删除受保护的账号快照：`Remove-Item "$env:LOCALAPPDATA\AIUsageWidget" -Recurse`。
5. 右键菜单里若有"取消开机启动"，先点它（或手动删除启动文件夹里的 `AI 周用量.lnk`）。
6. `~/.grok`、`~/.kimi-code`、`~/.codex`、`~/.commandcode` 是各供应商 CLI 的数据，本程序不会写入，按需自行保留。

## 报告问题前请准备

- `pwsh -NoProfile -File .\AiUsageWidget.ps1 -Version` 的输出。
- 你使用的 PowerShell 版本（5.1 还是 7.x）。
- `ai-widget.log` 中相关片段（**先删除邮箱、账号与路径信息**）。
- 如果能用 `-Demo` 模式复现，请说明；这能直接区分"界面问题"与"凭证/网络问题"。
