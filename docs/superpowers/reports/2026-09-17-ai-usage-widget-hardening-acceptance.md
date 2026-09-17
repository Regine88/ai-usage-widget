# AI Usage Widget 安全加固验收报告

**日期：** 2026-09-17
**范围：** `docs/superpowers/plans/2026-09-05-ai-usage-widget-hardening.md` 全部任务
**结论：** 通过。全部步骤落地，双版本（Windows PowerShell 5.1 / PowerShell 7）离线回归全绿；真实 API 冒烟覆盖 4 个已启用 provider，无错误、无退避。

## 交付物

- 新增模块：`UsageValidation.ps1`（有限数值校验、脱敏、通用纯转换）、`SecureSnapshot.ps1`（当前用户 DPAPI 快照、哈希命名、互斥与原子替换）、`KimiQuota.ps1`（Kimi 用量载荷解析）
- 主 Widget：`AiUsageWidget.ps1` 接入安全快照、校验、并发保存、错误脱敏、统一入口与工作线程函数名单
- 兼容包装器：`ChatGptUsageWidget.ps1`、`GrokUsageWidget.ps1`、`KimiUsageWidget.ps1` 转发到主 Widget
- 启动器：4 个 `Start-*.vbs` 只使用两个固定 PowerShell 路径，移除 `-ExecutionPolicy Bypass`
- 测试：新增 `test-UsageValidation.ps1`、`test-SecureSnapshot.ps1`、`test-KimiQuota.ps1`、`test-WidgetSecurity.ps1`；更新 `test-CommandCodeQuota.ps1`、`test-GrokAccounts.ps1`、`test-ModelRequestRecorder.ps1`

## 验证记录

| 验证项 | 方法 | 结果 |
| --- | --- | --- |
| 双版本回归 | 全部 `test-*.ps1`（8 个套件）分别运行于 PowerShell 7 与 Windows PowerShell 5.1 | 全部 `ALL PASSED` |
| AST 解析 | 全部 `.ps1` 静态解析 | 无语法错误 |
| 安全扫描 | 扫描 `ssl-no-revoke`、`ExecutionPolicy Bypass`、`GOCSPX-`、PATH 枚举 PowerShell 查找 | 无违规（仅测试规则自身字符串命中） |
| 工作线程函数 | `Get-WorkerScriptSource` 函数名单与全部文件定义比对 | 无缺失 |
| 受保护快照迁移 | `test-GrokAccounts.ps1` 覆盖发现、命名、旧明文清理 | 通过 |
| 真实 API 冒烟 | 运行中 Widget 2026-09-17 10:07 刷新轮次日志 | grok 9%、kimi 0%、codex 17%、commandcode 29.4% 全部 `ok`，`applied 4`，无 `error`/`backoff` |

## 本次验收新增修复

- **Kimi 用量解析修复**：`/usages` 实际返回 `limit` + `remaining`（字符串数字），原实现按 `used` 读取，导致 Kimi 行连续失败并退避（日志累计 118 次以上）。`KimiQuota.ps1` 以 `limit - remaining` 计算已用量（顶层与窗口两层），`used` 字段存在时仍优先，向后兼容。
- **显式 0 在结果应用层的丢失修复**：`Convert-FetchRow` 中 `$Raw.Percent -ne ''` 在 PowerShell 类型转换下把数值 `0` 判为空（`''` 转为 `0`），导致 `0%` 被误判为缺失。新增 `Convert-OptionalNumber`（显式 `0` 保留、空白与缺失返回 `$null`、非法值抛错）并接入，回归断言加入 `test-UsageValidation.ps1`。

## 未覆盖与说明

- Gemini 行未出现在冒烟范围：本机未配置 Antigravity 凭据（Windows 凭据管理器无对应条目），属预期行为；配置并登录后行自动出现。
- 真实 GUI 交互（托盘气泡、双击打开用量页、拖拽位置记忆）为人工确认项，未纳入自动化断言。
- 历史明文凭据若曾出现在旧快照中，建议在各 provider 侧按需轮换 token（见设计文档"兼容性与风险"）。
- 旧运行产物已清理：`widget.log`、`chatgpt-widget.log`、`kimi-widget.log`、`state.json`、`chatgpt-state.json`、`kimi-state.json`。

## 环境

- Windows 桌面；PowerShell 7（`C:\Program Files\PowerShell\7\pwsh.exe`）与 Windows PowerShell 5.1 双版本
- 项目目录：`C:\path\to\ai-usage-widget`
