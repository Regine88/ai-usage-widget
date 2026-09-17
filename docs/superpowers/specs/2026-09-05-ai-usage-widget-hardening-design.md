# AI Usage Widget 安全加固与架构收敛设计

## 目标

在不修改原始 CLI 登录凭据文件的前提下，修复项目中的凭据明文落盘、启动链路不受信任、错误数据被显示为 0、凭据刷新并发覆盖、重复入口和旧版 UI 同步请求问题，并保留现有多账户展示能力。

## 方案

采用 Windows 当前用户 DPAPI 保护的快照存储。ChatGPT/Codex 与 Grok 的多账户快照写入 `%LOCALAPPDATA%\AIUsageWidget\accounts`，文件名由 provider 与 account id 的 SHA-256 派生；快照内容仍保留原始认证 JSON 的最小必要字段，读取时在内存中还原。写入使用同一文件的命名互斥和临时文件原子替换。现存项目目录快照只在迁移成功后删除，原始 `%USERPROFILE%\.codex\auth.json` 与 `%USERPROFILE%\.grok\auth.json` 不改动。

启动链路固定使用 `C:\Program Files\PowerShell\7\pwsh.exe`，不存在时回退到 Windows PowerShell 5.1 的系统路径；所有启动器和自重启参数移除 `ExecutionPolicy Bypass`。网络调用移除 `--ssl-no-revoke`。Gemini/Antigravity client secret 从 `ANTIGRAVITY_CLIENT_SECRET` 读取，缺失时返回可识别的配置错误，不再在源码中保存 secret。

用量解析新增统一的有限数值检查：必需字段缺失、不可解析、NaN、Infinity 或不在 0–100 范围内时抛出错误；显式的 0 保持为 0。模型请求记录器对空白 provider 在非严格模式返回空事件，在严格模式抛出清晰错误。旧版 ChatGPT/Grok/Kimi 脚本改为兼容包装器，统一转发到 `AiUsageWidget.ps1`，消除重复认证与 UI 线程网络请求。

## 兼容性与风险

- DPAPI 快照只能由同一 Windows 用户解密；这是预期的本地安全边界。
- 用户需要在运行 Gemini 行之前设置 `ANTIGRAVITY_CLIENT_SECRET`；未设置时 Gemini 行显示配置错误，其余 provider 继续工作。
- 三个旧入口继续保留文件名和常用参数，但启动的是合并 Widget；这是消除重复实现后的兼容行为。
- 不自动吊销云端 token；项目目录中已发现的凭据快照需由用户在 provider 侧轮换或撤销。

## 验证

先补纯函数测试，再实现 DPAPI 快照和解析校验；每个阶段运行 Windows PowerShell 5.1 与 PowerShell 7 的回归测试、所有 `.ps1` AST 解析、启动器安全字符串扫描和明文快照扫描。真实 API、GUI 和云端 token 吊销不在离线验证范围内。
