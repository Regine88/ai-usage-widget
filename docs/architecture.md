# 架构说明

本文面向要改动这个项目的开发者，说明进程结构、数据流、模块边界与既有约定。

## 设计目标与约束

- **纯本地**：只读取本机已有的登录凭证，只调用各供应商自己的配额接口，不上传任何数据、无遥测。
- **零依赖**：不依赖任何第三方 PowerShell 模块，只用 .NET 自带的 WinForms、Drawing 与 DPAPI。
- **双版本可用**：Windows PowerShell 5.1 与 PowerShell 7.x 行为一致，两者都必须通过全部测试。
- **可离线测试**：解析与校验逻辑全部是纯函数，放进模块文件后可在没有网络、没有账号的情况下测试。
- **单进程常驻**：一个隐藏 PowerShell 进程 + 一个 WinForms 窗口，没有服务、没有后台守护进程、不写注册表。

## 进程与线程模型

```text
wscript.exe  Start-AiUsageWidget.vbs
  |
  +-- pwsh.exe / powershell.exe  -NoProfile -STA -WindowStyle Hidden -File AiUsageWidget.ps1
        |
        +-- UI 线程（STA）
        |     WinForms 卡片 + NotifyIcon 托盘 + System.Windows.Forms.Timer 定时器
        |
        +-- 抓取 runspace（MTA，常驻复用）
              |  Get-WorkerScriptSource 动态拼出的脚本：白名单函数源码 + 配置变量
              |
              +-- 每次 HTTP 请求再开一个嵌套 runspace
                    硬超时 WaitOne((TimeoutSec + 5) * 1000)，超时即 Stop()
```

要点：

- 入口脚本在非 STA 线程被调用时会用受信任路径的 PowerShell 以 `-STA -WindowStyle Hidden` **重启自己**（见 `Get-TrustedPowerShellPath`、脚本第 48 行起的分支），保证 UI 线程是 STA。
- `Invoke-WidgetRest` 之所以要嵌套 runspace，是因为 `Invoke-RestMethod -TimeoutSec` 在线程边界上可能被忽略；用 `WaitOne` 做硬超时，保证任何一个慢供应商都不会拖死整个刷新。
- 抓取 runspace 是常驻的（`$script:WorkerRs`），每次刷新复用，避免频繁创建 runspace 的开销。

## 文件职责

| 文件 | 职责 |
| --- | --- |
| `AiUsageWidget.ps1` | 主程序：常量与路径、UI 构建、菜单与托盘、定时器、后台抓取调度、行渲染、状态持久化 |
| `UsageValidation.ps1` | 共享纯函数：数值有限性校验、百分比断言、比例换算、日志脱敏、账号指纹、受信任 HTTPS 主机校验 |
| `SecureSnapshot.ps1` | 当前用户 DPAPI 保护快照：读写、原子替换、目录 ACL、文件锁 |
| `GrokAccounts.ps1` | Grok 多账号：从 `~/.grok/auth.json` 解析账号、指纹命名、快照同步 |
| `GeminiAntigravity.ps1` | Antigravity Gemini 配额：Windows 凭据管理器读写、OAuth 刷新、配额载荷转换 |
| `KimiQuota.ps1` | Kimi 载荷解析纯函数：窗口时长换算、已用/限额解析 |
| `CommandCodeQuota.ps1` | Command Code 配额解析纯函数：日 / 5 小时 / 周窗口、余额与时间换算 |
| `OpenRouterQuota.ps1` | OpenRouter 密钥配额解析纯函数：密钥指纹、`usage` / `limit` 换算与无上限判定 |
`WidgetUpdates.ps1` | 版本比较与 GitHub Release 解析纯函数：tag 规范化、draft / prerelease / 非法载荷判定 |
| `ModelRequestRecorder.ps1` | 请求事件记录与查询（仅元数据），以及脱敏工具 |
| `UsageHistory.ps1` | 历史聚合与趋势：从 `ai-history.jsonl` 生成每日序列、最小二乘斜率、耗尽预测、sparkline 路径与 CSV 导出 |
| `WidgetConfig.ps1` | `ai-config.json` 的读写与校验（供应商开关、刷新间隔、不透明度、阈值、静音时段、语言），非法值回退默认 |
| `WidgetStrings.ps1` | 界面文案：语言代码白名单解析、语言包读取与兜底表、`T` / `Get-WidgetText` 取值（主进程与 worker 共用同一张表） |
| `strings/*.json` | 语言包：纯键值 JSON，多种语言的键集必须一致，`_` 前缀的键在加载时忽略 |
| `WidgetInstaller.ps1` | 安装 / 升级 / 卸载实现：运行文件清单、用户数据判定与开始菜单快捷方式；安装器与发布打包共用这份清单 |
| `tools/package-release.ps1` | Release 打包：按清单组装 zip、生成 SHA256 与 Scoop manifest（本地与 CI 共用） |
| `Record-ModelRequest.ps1` | 供外部工具调用的独立入口：追加一条请求事件 |
| `Start-*.vbs` | 无窗口启动器；`Start-AiUsageWidget.vbs` 对应聚合卡片 |
| `test-*.ps1` | 每个模块对应的离线测试套件，成功时打印 `ALL PASSED` |

历史遗留的单供应商脚本（`GrokUsageWidget.ps1`、`KimiUsageWidget.ps1`、`ChatGptUsageWidget.ps1`）保留为独立入口，聚合卡片是当前的推荐用法。

## 一次刷新的完整数据流

1. `System.Windows.Forms.Timer` 触发 `Update-Widget`（或用户按 F5 / 点"立即刷新"）。
2. `Get-ProviderRows` 检查每个供应商的凭证是否存在，生成行定义 `@{ Id; Kind; Name; Auth; ... }`；没有任何凭证时直接显示"未找到登录凭证"并结束。 `ai-config.json` 里 `providers` 关闭的供应商会被 `Test-ProviderEnabled` 过滤掉。
3. Codex 相关的活跃快照先做一次 `Sync-ActiveCodexSnapshot`，保证多账号条目与磁盘上的 `auth.json` 一致。
4. 行集合的 `Id` 拼接成签名，与上一轮不同则 `Rebuild-ProviderRows` 重建控件。
5. `Start-BackgroundFetch` 把行定义与配置对象传给常驻 MTA runspace；worker 只拿到**纯数据**（没有函数闭包、没有凭据缓存）。
6. worker 逐行调用对应的 `Get-*RowData`，每行独立 try/catch，返回
   `@{ Id; Percent; Detail; Tip; Reset; Error }` 对象的数组。
7. `Receive-BackgroundFetch` → `Apply-FetchResults` 把结果写进 UI：成功行调用 `Set-RowUsage` 并用最近 7 天序列刷新迷你折线、计算耗尽预测，失败行调用 `Set-RowError`；
   同时 `Write-UsageHistory` 追加历史、`Send-UsageAlert` 按 `ai-config.json` 的阈值弹气泡（静音时段内跳过）。
8. 失败行通过 `Register-ProviderFailure` 进入指数退避：`min(900, 30 * 2^(n-1))` 秒，成功一次即清零。
9. 状态栏显示 `更新于 HH:mm`；刷新超时会显示"刷新超时，等待下次尝试"。

## 关键约定

### 行模型

每个供应商最终都要产出统一的行数据：

| 字段 | 含义 | 备注 |
| --- | --- | --- |
| `Percent` | **已用**百分比 | `0` 是合法值，必须照常显示，不能当缺数据 |
| `Detail` | 明细文本，例如 `5h 32% · 周 68%` | 由各供应商自行组合 |
| `Tip` | 悬停提示 | 可含重置时间、套餐名等 |
| `Reset` | 重置时间 | 由 `Format-ResetText` / `Format-ResetTime` 统一格式化 |
| `ResetAt` | 重置时刻的 ISO 8601 文本 | 供耗尽预测判断“重置前是否耗尽”，缺失时预测退化为纯趋势 |

百分比方向由 `Convert-DisplayPercentToUsagePercent` 统一换算，避免各供应商对"剩余/已用"的理解不一致。

### 错误降级

任何异常都不允许冒泡到 UI 线程。`Format-FetchError` 会把技术异常映射为可读短语：

| 原始信息 | 卡片显示 |
| --- | --- |
| `timeout` / `超时` / `canceled due to` | 请求超时 |
| `SSL` / `certificate` / `信任关系` | 网络连接失败 |
| `401` / `Unauthorized` | 登录已过期，请重新登录 |
| `403` / `Forbidden` | 无访问权限 |
| `429` | 请求过于频繁 |
| `missing-credential` / `no-credential` | 未登录 |

未命中的异常统一显示「读取失败，请稍后重试」；脱敏后的原文只写进日志与悬停提示，不贴到卡片正文。

### 脱敏

`Convert-SafeLogText` 是所有日志与错误文本的唯一出口：折叠换行、截断长度、丢弃疑似 token 的片段。
账号在日志里只以 `Get-AccountFingerprint` 生成的短哈希出现，永不出现邮箱。

### 界面语言

全部界面文案集中在 `strings/<language>.json`，加载与取值都由 `WidgetStrings.ps1` 负责：

- 配置里的 `language` 先过 `ConvertTo-WidgetLanguage` 的白名单（`zh*` → `zh-CN`，`en*` → `en-US`，`auto` 或未登记的值跟随系统 UI 语言），
  解析结果才用来拼语言包路径——配置值永远不会被直接当成文件名。
- 语言包读不到或 JSON 损坏时回退到内置兜底表，缺键时返回键名本身，界面不会因为语言包出问题而空白。
- worker 通过 `$Cfg.WidgetStrings` 拿到同一张表，后台拼好的行文本与界面语言保持一致。
- 新增语言的登记点是 `$script:WidgetStringLanguages`；新增文案要同时补两个语言包与兜底表，
  `test-WidgetStrings.ps1` 会扫描源码里所有 `T 'key'` 调用，漏登记键名直接失败。

### 单实例

`Ensure-SingleInstance` 使用命名互斥体 `Local\AiUsageDesktopWidget`；演示模式使用 `Local\AiUsageDesktopWidgetDemo`，
因此可以同时开一个真实卡片和一个演示卡片做对比。

## worker 边界（新增供应商最容易踩的地方）

worker 是一个**全新的 runspace**，它既没有主脚本的函数，也没有主脚本的变量。`Get-WorkerScriptSource` 负责：

1. 把白名单里的函数**源码**逐个拼进 worker 脚本（`$fnNames` 列表）；
2. 把配置变量（路径、OAuth client id、URL 等）从 `$Cfg` 重新赋值给 worker 内的 `$script:*`（见 worker 脚本开头的 `foreach ($v in ...)`）；
3. 追加一段调度代码，按 `$row.Kind` 分派到对应的 `Get-*RowData`。

因此新增供应商时必须同时更新**三处**：`$fnNames`、`$Cfg` 变量列表、`switch ($row.Kind)` 分支。
漏掉任何一处，表现为"其他供应商正常，这一行永远没有数据"。

## 存储布局

| 路径 | 内容 | 是否入库 |
| --- | --- | --- |
| `%LOCALAPPDATA%\AIUsageWidget\accounts\` | DPAPI 保护的账号快照，文件名为账号指纹 | 否 |
| `<程序目录>\ai-state.json` | 窗口位置、置顶、刷新间隔 | 否（`.gitignore`） |
| `<安装目录>\ai-install.json` | 安装元数据：版本、安装时间与文件清单（由安装器维护） | 否 |
| `<程序目录>\ai-config.json` | 供应商开关、刷新间隔、不透明度、趋势与提醒设置 | 否（`.gitignore`） |
| `<程序目录>\ai-history.jsonl` | 用量百分比时间序列（超过 1MB 自动保留最后 2000 行） | 否 |
| `<程序目录>\ai-request-events.jsonl` | 请求事件元数据 | 否 |
| `<程序目录>\ai-widget.log` | 日志，自动轮转 | 否 |
| `~/.grok/auth.json` 等 | 各供应商自己的凭证，本程序只读 | 否 |

## 安全设计要点

- 快照使用当前用户范围 DPAPI 加解密，写入走"临时文件 → 原子替换"，并用 `Set-SecureSnapshotAcl` 收紧目录权限；
  并发写入由 `Invoke-SecureSnapshotFileLock` 串行化。
- 所有外部主机在请求前要过 `Resolve-TrustedHttpsEndpoint` 白名单校验，只有 `https` 且主机在允许列表内才继续。
- 不申请管理员权限、不写注册表启动项；开机启动只是往当前用户启动文件夹放一个指向 VBS 的快捷方式。
- 日志与错误文本统一脱敏；请求事件只记录供应商、模型、状态与耗时。

## 可测性设计

- 每个模块都有同名 `test-*.ps1`，测试只调用纯函数并断言返回值，不读磁盘、不联网、不使用真实凭据。
- 涉及 WinForms 的代码不写测试，改用 `-Demo` 模式做人工回归：固定数据渲染、不写状态、不联网。
- CI 在两个 PowerShell 版本上跑同样的套件，任何一侧失败都视为构建失败。

## 已知取舍与后续方向

- 主程序仍是单文件（约 2200 行），便于分发但 UI 与调度耦合；P2 计划把布局计算与文本格式化抽成可测模块。
- WinForms 没有原生暗色主题支持，当前的暗色卡片是自绘圆角面板 + 手工配色。
- 提醒阈值与静音时段已可全局配置（`ai-config.json`），按供应商自定义阈值仍在路线图的 P2 阶段。
