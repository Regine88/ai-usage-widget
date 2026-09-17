# 安全策略

## 支持的版本

只有最新发布的小版本会收到安全修复。当前维护版本：`0.11.x`。

## 报告漏洞

**请勿在公开 Issue 中披露安全问题。** 请使用 GitHub 的私密通道：

- [报告安全漏洞](https://github.com/Regine88/ai-usage-widget/security/advisories/new)（Security Advisories，仅维护者可见）

请尽量包含：影响的版本、复现步骤、影响范围（例如"能在不触发 UAC 的情况下读取他人 token"）以及你的验证环境。
维护者会尽快确认收到并在修复完成后公开致谢（如果你愿意署名）。

## 这个程序会接触哪些数据

AI Usage Widget 是一个纯本地工具：它读取各 AI 服务已经存在本机的登录凭证，调用对应服务接口查询配额，然后把结果画在桌面上。
它**没有**自己的账号体系，**不会**向本项目维护者或任何第三方上传数据，也**没有**遥测、埋点或自动更新回传。

| 数据 | 位置 | 说明 |
| --- | --- | --- |
| 供应商凭证 | `~/.grok/auth.json`、`~/.kimi-code/credentials/kimi-code.json`、`~/.codex/auth.json`、`~/.commandcode/auth.json`、`~/.openrouter/auth.json`、`~/.deepseek/auth.json`、Windows 凭据管理器 `gemini:antigravity`，以及对应的环境变量 | 由各自的 CLI 或工具写入，本程序只读取 |
| 受保护账号快照 | `%LOCALAPPDATA%\AIUsageWidget\accounts\` | 使用当前用户 DPAPI 加密，文件名是账号哈希，不含明文 token |
| 运行状态 | 程序目录 `ai-state.json` | 窗口位置、刷新间隔、置顶状态等界面设置 |
| 用量历史 | 程序目录 `ai-history.jsonl` | 百分比与时间戳，不含任何凭证 |
| 请求事件 | 程序目录 `ai-request-events.jsonl` | 仅元数据：供应商、模型名、状态、耗时；**从不**记录提示词、补全内容、请求体或响应体 |
| 日志 | 程序目录 `ai-widget.log` | 状态码与错误摘要，账号只以哈希指纹出现；自动轮转 |

## 设计上的安全约束

- 凭据快照使用当前用户范围的 DPAPI 保护，并以哈希命名，使用原子替换写入，同时收紧目录 ACL。
- 所有外部请求固定使用 HTTPS，统一走 `Invoke-WidgetRest`，入口先做主机白名单校验（允许 path/query），带超时与状态码分类，不跟随可疑重定向。Kimi 用户可覆盖的主机另外走更严的 `Resolve-TrustedHttpsEndpoint`（禁止 query/fragment）。
- 日志与错误提示走统一的脱敏函数，不打印 token、cookie、邮箱或完整响应体。
- 后台抓取在独立 MTA runspace 中执行，只接收配置对象、只回传纯数据，避免 UI 线程持有凭据。
- 程序不申请管理员权限，不写注册表启动项（开机启动通过当前用户启动文件夹的快捷方式实现）。
- 仓库 `.gitignore` 覆盖凭据、状态、日志与历史文件，CI 不接触真实账号。

## 使用者的责任

- 不要把 `ai-widget.log`、`ai-state.json` 或任何 `*auth*.json` 直接贴到 Issue 里；需要日志时请先删除账号与邮箱信息。
- 请遵守各供应商的服务条款，本程序只是读取你本机已有的配额信息，不绕过任何付费或限流机制。
