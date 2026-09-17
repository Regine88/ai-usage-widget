# AI Usage Widget 开源化与功能扩展计划

> **状态（2026-09-17）：** 已确认并执行。P0 九项任务全部完成，验收记录见 `docs/superpowers/reports/2026-09-17-ai-usage-widget-open-source-acceptance.md`。

> **P1 / P2 进度（2026-09-17，0.13.0）：** Claude Code、Cursor、GLM / Z.AI、GitHub Copilot 已接入；
> 通义与豆包经调研确认没有可用的配额接口，已在 `docs/providers.md` 记录原因并关闭。
> P2 浅色主题、紧凑布局、锁定位置、更新检查、多列布局、每日汇总、按供应商阈值均已完成，
> 该计划的 P1 / P2 功能项全部收口。

**目标：** 把当前内部工具补齐为可公开、可贡献、可发布的开源项目，并按用户价值排序扩展功能。

**架构约束：** 保持“单文件主程序 + 纯函数模块”的现状；新增能力优先落在模块（可离线测试）而非 UI 内联代码；Windows PowerShell 5.1 与 PowerShell 7 双版本必须同时通过全部测试。

**技术栈：** Windows PowerShell 5.1 / PowerShell 7 / WinForms / Windows DPAPI / GitHub Actions（windows-latest）。

---

## 一、现状评估

### 已具备

- 6 个供应商：Grok（多账号）、Gemini / Antigravity、Kimi、ChatGPT / Codex（多账号）、Command Code、OpenRouter（多账号）
- 暗色圆角常驻卡片：拖拽与贴边吸附、置顶开关、双击打开用量页、右键菜单（立即刷新 / 刷新间隔 / 登记账号 / 打开用量页 / 浮在窗口上 / 开机启动 / 退出）
- 托盘图标与 70/90 阈值气泡提醒、日志轮转、`ai-history.jsonl` 用量历史、`ai-request-events.jsonl` 请求事件
- 凭据安全：DPAPI 快照、哈希命名、ACL 收紧、原子替换、互斥锁
- 后台 MTA worker 抓取，UI 线程不阻塞
- 16 个离线测试套件，双 PowerShell 版本全绿
- 高 DPI 自适应布局（2026-09-17 修复）

### 开源缺口

| 类别 | 缺失项 |
| --- | --- |
| 法律 | `LICENSE` |
| 文档 | README（中 / 英）、架构说明、供应商扩展指南、排错手册、脱敏截图 |
| 协作 | CONTRIBUTING、CODE_OF_CONDUCT、SECURITY、Issue / PR 模板、CHANGELOG |
| 工程 | CI、PSScriptAnalyzer 检查、版本号与发布流程、一键安装 / 升级脚本 |
| 仓库设置 | 描述、topics、可见性（当前 private）、Release |

---

## 二、P0：开源工程基线（无破坏性，纯新增）

**文件清单**

- 创建：`LICENSE`（协议待确认，默认 MIT）
- 创建：`README.md`（中文主文档）、`README.en.md`（英文）
- 创建：`CHANGELOG.md`（Keep a Changelog，回填已有 5 次提交）
- 创建：`CONTRIBUTING.md`、`CODE_OF_CONDUCT.md`（Contributor Covenant 2.1）、`SECURITY.md`
- 创建：`.editorconfig`、`.gitattributes`（统一 LF，消除启动器 VBS 行尾噪音）
- 创建：`.github/workflows/ci.yml`
- 创建：`.github/ISSUE_TEMPLATE/bug_report.yml`、`feature_request.yml`、`config.yml`、`.github/PULL_REQUEST_TEMPLATE.md`
- 创建：`docs/architecture.md`、`docs/providers.md`、`docs/troubleshooting.md`、`docs/images/`（脱敏截图）
- 修改：`AiUsageWidget.ps1`（新增 `$script:Version`、`-Version` 开关、`-Demo` 演示数据模式）

**任务**

- [x] 任务 1：许可证与仓库元数据（`LICENSE`、`.gitattributes`、`.editorconfig`）
- [x] 任务 2：CI 工作流（windows-latest；pwsh 7 与 powershell 5.1 跑全部测试；语法解析检查；PSScriptAnalyzer 报告）
- [x] 任务 3：协作文档（CONTRIBUTING / CODE_OF_CONDUCT / SECURITY / Issue 与 PR 模板）
- [x] 任务 4：架构与扩展文档（architecture / providers / troubleshooting）
- [x] 任务 5：版本号与 `-Version` 输出
- [x] 任务 6：`-Demo` 模式（无凭证渲染固定数据，供截图与 UI 回归）
- [x] 任务 7：脱敏截图 + README（中英）
- [x] 任务 8：CHANGELOG 回填
- [x] 任务 9：提交并推送，附 GitHub 侧手动项清单（仓库描述、topics、公开可见性、首个 Release）

---

## 三、功能路线图

### P1（建议优先）

1. **更多供应商**（已收口）：Claude Code、Cursor、GitHub Copilot、OpenRouter、DeepSeek、GLM(z.ai)、通义 / 豆包。
   **已完成：OpenRouter**（0.8.0）、**DeepSeek**（0.10.0）、**Claude Code / Cursor / GLM**（0.12.0）、
   **GitHub Copilot**（0.13.0，见 `CopilotQuota.ps1`）。
   通义与豆包没有公开配额接口（详见 `docs/providers.md` 的「暂不接入的供应商」），确认不接入。
2. **历史与趋势**（已完成，0.7.0）：卡片内 7 天迷你折线（`ai-history.jsonl` 已在记录）、额度耗尽时间预测、CSV 导出。
3. **设置面板**（已完成，0.7.0）：`ai-config.json` 集中配置 + WinForms 设置窗口（供应商开关、刷新间隔、透明度、阈值、静音时段、界面语言）。
4. **国际化**（已完成，0.7.0）：`strings/zh-CN.json`、`strings/en-US.json`，UI、托盘、菜单、提示与 CLI 文案统一切换；`test-WidgetStrings.ps1` 扫描源码防止漏登记键名。
5. **分发**（已完成，0.7.0）：`install.ps1`（安装 / 升级 / 卸载）+ GitHub Release 自动打包 zip + Scoop manifest。

### P2（体验增强）

6. 主题与布局：**浅色主题已完成**（0.10.0）；**紧凑布局与锁定位置已完成**（0.11.0）；**多列已完成**（0.13.0，
   `WidgetLayout.ps1` 的 `Get-WidgetLayoutRowAnchor` + `-Columns`，设置窗口可调 1 - 3 列）。
7. 提醒增强：**重置提醒已完成**（0.9.0）；**每日汇总与按供应商自定义阈值已完成**（0.13.0，
   `Test-DailySummaryDue` + `providerAlertThresholds` 多行文本框）。
8. **更新检查与“关于”窗口**（已完成，0.9.0）：右键菜单 → **关于…**，显示版本 / 许可证 / 项目链接，手动检查 GitHub 最新 Release；`WidgetUpdates.ps1` 负责版本比较与载荷解析。
9. 工程质量：布局与格式化逻辑抽成可测模块，补布局回归测试。

---

## 四、新增供应商的固定改造点（以 Claude Code 为例）

1. 新建 `ClaudeQuota.ps1`（纯解析、纯函数）+ `test-ClaudeQuota.ps1`
2. 凭证读取与刷新（`Read-*Auth` / `Update-*Token`），快照统一走 `SecureSnapshot.ps1`
3. `Get-ClaudeUsageSnapshot` 与 `Get-ClaudeRowData`（返回 `Percent` / `Detail` / `Tip` / `Reset`）
4. `Get-ProviderRows` 增加凭证存在性判断与行定义
5. `Get-WorkerScriptSource` 追加函数名与 `$Cfg` 变量转发
6. 右键菜单“打开用量页”增加条目
7. `docs/providers.md` 记录字段来源、限流与失败降级策略

---

## 五、验收标准

- 双版本（pwsh 7 / Windows PowerShell 5.1）全部测试 `ALL PASSED`
- CI 在 PR 上通过；README 截图可用 `-Demo` 模式复现
- 无凭据、日志或含个人信息文件入库，`git status` 干净
- 新功能均带离线测试或可复现的手动验收步骤

---

## 六、决策结果（2026-09-17）

1. 许可证：**MIT**（已落地 LICENSE）。
2. 语言范围：**README 中英双语已完成**；UI 中英切换（strings/*.json）已在 0.7.0 落地。
3. 优先新增供应商：**待用户指定**，按 docs/providers.md 七步执行。
4. 仓库可见性：仍为 private，**需在 GitHub 网页手动改为 public**（见验收记录中的仓库侧手动项）。
