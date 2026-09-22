# AI Usage Widget M1 凭证写回验收

执行日期：2026-09-22。

## 目标

修复多账号刷新期间“A 的令牌结果覆盖已切换到的 B 登录”的 P0 风险。写回必须满足：

1. 在文件锁或本程序进程内锁内重新读取当前凭证。
2. 同时核对稳定账号 ID 与 refresh token，不能只信任锁外持有的对象。
3. 身份匹配时只更新 token 与过期时间，保留外部工具写入的未知字段。
4. 身份已切换时保持当前登录，把旧账号结果写入旧账号的 DPAPI 快照。
5. 文件系统凭证使用临时文件与原子替换；失败不得静默伪装成成功。

## 实现

`SecureSnapshot.ps1` 新增共享的 `Update-JsonFile` 与 `Write-JsonFileAtomic`：

- `Update-JsonFile` 复用 `Invoke-SecureSnapshotFileLock`，在锁内读取、调用账号校验、局部修改并原子替换。
- 临时文件在 `finally` 中清理；JSON 深度固定，未知字段不会被锁外对象覆盖。
- DPAPI 快照继续使用已有的 `Update-SecureSnapshot`，更新前也增加账号校验。

`UsageValidation.ps1` 新增 `Assert-CredentialIdentity` 与
`Test-CredentialAccountChanged`。优先比较稳定账号 ID；没有稳定 ID 时，旧 refresh token 仍匹配才视为同一身份。

改造的写回路径：

| 供应商 | 活动凭证 | 切换后的行为 |
| --- | --- | --- |
| Grok | JSON 文件 | 保持当前账号，刷新结果写旧账号快照 |
| Gemini / Antigravity | Windows 凭据管理器 | 保持当前账号，刷新结果写旧账号快照 |
| Kimi | JSON 文件 | 保持当前账号，刷新结果写旧账号快照 |
| Codex | JSON 文件 | 保持当前账号，刷新结果写旧账号快照 |
| Cline | JSON 文件 | 保持当前账号，刷新结果写旧账号快照 |
| Claude Code | JSON 文件 | 保持当前账号，刷新结果写旧账号快照 |

Grok 行 ID 也改为始终由账号 ID 指纹生成，显示别名变化不会再拆分历史行。

## 回归覆盖

新增或扩展的测试模拟以下时序：

1. 从 A 的活动凭证建立账号行。
2. 外部客户端把活动文件或凭据管理器切到 B。
3. A 的刷新请求随后成功，调用对应的 `Save-*Auth`。
4. 断言 B 的 token、refresh token 与无关字段未被修改。
5. 断言 A 的 DPAPI 快照收到新 token 与 refresh token。

覆盖套件：

- `test-GrokProvider.ps1`
- `test-MultiAccount.ps1`：Kimi、Codex、Claude
- `test-ClineProvider.ps1`
- `test-GeminiProvider.ps1`
- `test-SecureSnapshot.ps1`：通用 JSON 原子更新与未知字段保留
- `test-GrokAccounts.ps1`：稳定行 ID 不受显示别名变化影响

## 验证结果

| 检查 | 结果 |
| --- | --- |
| PowerShell 7 全部离线套件 | 40/40 通过 |
| Windows PowerShell 5.1 全部离线套件 | 40/40 通过 |
| `tools/package-release.ps1` | 通过 |
| `tools/verify-package.ps1` | 通过，36 个运行文件、41 个压缩包条目 |
| 包 SHA256 | `5C626C60AEDA950632EA80D3644166AAAD1B8D5D2C66694960E28297DDACCAF6` |
| PSScriptAnalyzer | 0 个 Error；既有 Warning 基线仍较多 |

发布包由当前未提交的 0.16.0 候选工作区构建，入口版本暂时保持 0.15.0；该哈希仅作为本轮候选验证，
不得直接用于现有 0.15.0 Release。

## 已知边界

外部 CLI 与本程序不共享同一套锁协议。文件类和 Windows 凭据管理器写入都只能在身份复核与原子替换
之间形成本程序可控的短窗口，不能让不合作的外部进程参与同一事务。该限制已写入架构与供应商文档。

M2 的历史 schema、保留策略和统计口径不在本报告范围内。

## 后续复核加固

独立验收探针补充发现同账号迟到刷新与保存失败传播两处缺口，本轮已继续收紧：

- 凭证对象保留发起刷新时的 access / refresh 版本；锁内同时核对账号和原始版本。
- 同账号外部登录已经更新时，迟到刷新标记为 `credential-stale` 并丢弃，不覆盖活动文件或较新的快照。
- 账号切换仍按原流程把结果写入旧账号快照。
- Cline、Claude 与 Gemini 的凭证保存异常不再只写日志后返回成功，而是向上传播。

独立探针复核结果：

- `M1_same_account_stale_write`：`NewerCredentialPreserved=true`，`UnknownFieldPreserved=true`
- `M1_Claude_save_failure`：`FailurePropagated=true`
- `M1_Cline_save_failure`：`FailurePropagated=true`
