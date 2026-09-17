# 目标

补齐项目自己记录在 0.14.0 验收证据里的两处历史分析缺口，让用户不必手工比对多份文件就能看清跨月变化与更长时间的趋势：新增「多月对比」导出，新增独立「趋势图」窗口。

# 范围

- `UsageReport.ps1` 新增多月对比纯函数：选定月份集合、按「供应商 × 月份」聚合、环比变化、Markdown 与自包含 HTML 渲染、文件名生成。
- `AiUsageWidget.ps1` 的「导出历史」子菜单新增「多月对比 Markdown」与「多月对比 HTML」两项，并新增导出入口，沿用现有导出交互（写入组件目录 + 本地化提示）。
- 新增 `WidgetTrend.ps1` 纯函数模块：把历史记录整理成绘图数据（按供应商的每日序列、采样天数裁剪、坐标换算、坐标轴刻度、缺数据处理），模块内不调用 UI 文案助手。
- 新增 `Show-WidgetTrend` 窗口（仿 `Show-WidgetAbout` 的写法），右键菜单新增「趋势图…」入口；窗口内可切换 7 / 14 / 30 天，折线颜色沿用各组件在卡片上的用量调色板颜色。
- 新增 `-TrendWindow` 启动开关：启动即打开趋势图窗口，供冒烟检查与截图使用；demo 模式使用合成序列，不读真实历史。
- `WidgetInstaller.ps1` 运行文件清单加入 `WidgetTrend.ps1`。
- 语言包 `strings/zh-CN.json` 与 `strings/en-US.json` 新增键，并同步 `WidgetStrings.ps1` 兜底表。
- 测试：新增 `test-WidgetTrend.ps1`，扩充 `test-UsageReport.ps1`。
- 文档：`README.md`、`README.en.md`、`CHANGELOG.md`、`docs/architecture.md`、`site/index.html` 同步新能力；版本号升到 `0.15.0`。

# 非目标

- 不改动卡片本体：行内迷你折线、`WidgetLayout.ps1` 的布局与 DPI 逻辑、多列排布保持现状与现有测试不变。
- 不改现有单月报表（月度 Markdown / HTML、按天汇总 CSV、原始采样 CSV）的内容结构与文件名。
- 不做图表导出为图片、缩放平移等额外交互。
- 不接入新的供应商，不改动凭证读取与网络请求逻辑。
- 不新增第三方依赖，仍只用 .NET 自带的 WinForms / Drawing / DPAPI。
- 不在本次打 tag、推送、创建 Release 或改动 GitHub 仓库设置；这些属于归档时另行授权的动作。

# 验收示例

- Scenario: 历史里存在 3 个以上有数据的月份时，从「导出历史」选择「多月对比 HTML」，组件目录生成 `ai-usage-comparison-<最早月>_<最新月>.html`；该文件自包含、不引用任何外部资源，含「供应商 × 月份」表格，每个单元格给出该月的采样数、天数、月初、月末、最低、最高，并另有「环比变化」列给出本月月末与上月月末的百分点差。
- Scenario: 同一份历史选择「多月对比 Markdown」，生成文件名相同、扩展名为 `.md` 的文件，表头与单元格口径与 HTML 版本一致，且单元格内容里的竖线与换行不会破坏表格结构。
- Scenario: 对比区间内某个供应商在某个月没有采样时，该单元格显示占位符 `-`，同月其他供应商与该供应商其他月份的数值不受影响，导出仍然成功。
- Scenario: `ai-history.jsonl` 不存在或没有任何可解析采样时，选择任一「多月对比」导出只显示本地化的「还没有历史数据可导出」提示，组件目录不产生新文件。
- Scenario: 右键卡片 →「导出历史」子菜单显示六项（原始采样 CSV、按天汇总 CSV、月度报表 Markdown、月度报表 HTML、多月对比 Markdown、多月对比 HTML），多月对比导出成功后的提示中给出已写入文件的完整路径。
- Scenario: 右键卡片 →「趋势图…」打开趋势图窗口，窗口按供应商绘制每日用量折线，默认显示最近 7 天，切换到 14 天或 30 天后折线按新窗口重绘，每个供应商的折线颜色沿用它在卡片上的用量调色板颜色。
- Scenario: 历史里某个供应商只有 5 天采样而窗口选择 30 天时，该供应商只绘制存在的 5 个点，不补零点、不抛异常，图例仍列出该供应商及其最新百分比。
- Scenario: 以 `-Demo -TrendWindow` 启动时，日志出现趋势图窗口已显示与 demo 合成序列的记录，界面回归以 `fatal=False unhandled=False error=False` 结束，且不读写真实历史、凭证与状态文件。
- Scenario: 语言包缺少新键时，趋势图窗口与多月对比报表显示内置英文文案而不是 `report.*` 这类键名；新增键同时登记进中英两个语言包。
- Scenario: 分别在 PowerShell 7.x 与 Windows PowerShell 5.1 下运行全部 `test-*.ps1`（含新增 `test-WidgetTrend.ps1` 与扩充的 `test-UsageReport.ps1`），全部输出 `ALL PASSED`。
- Scenario: 打包链路 `tools/package-release.ps1` 与 `tools/verify-package.ps1` 通过，运行文件清单包含 `WidgetTrend.ps1`，压缩包条目、包内版本号与 `.sha256` 校验一致。

# 约束与不变量

- 解析、聚合与绘图几何必须是纯函数并放在模块文件里，可在无网络、无凭证、无桌面的情况下离线测试；UI 只负责绘制与交互。
- 双引擎一致：Windows PowerShell 5.1 与 PowerShell 7.x 必须同时通过全部测试，聚合与排序不得使用 5.1 不支持的写法。
- 只读不写：趋势图窗口与多月对比报表都不得写入或修改 `ai-history.jsonl`、凭证快照与状态文件。
- 现有导出行为不变：单月报表与两份 CSV 的文件名、列结构与提示文案保持原样。
- 失败隔离：趋势图窗口的数据读取失败只能影响该窗口自身的提示，不得影响卡片刷新与托盘功能。
- 不新增依赖，不新增网络请求。

# 决策

- Q1 工作区隔离：使用独立 worktree（`.worktrees/usage-report-enhancement`，分支 `comet/usage-report-enhancement`，目标分支 `main`）。理由：主目录已有未提交改动，隔离后互不影响。
- Q2 范围：只做「报表与历史分析增强」（跨月对比 + 趋势图），不做供应商扩展、analyzer 警告清理与仓库治理。
- Q3 跨月对比形式：新增独立的「多月对比」导出，默认最近 3 个月；现有单月报表结构保持不变。
- Q4 卡片内图表形式：新增独立「趋势图」窗口，卡片本体与布局逻辑保持不变。
- 版本与变更记录：按语义化版本升到 `0.15.0`，`CHANGELOG.md` 增加 0.15.0 条目；打 tag、推送与创建 Release 不在本次范围。
- 验收口径沿用项目既有做法：双引擎全量测试、`-Demo` 界面冒烟、打包内容校验。

# 待解决问题

无。Q1 - Q4 已由用户确认并记入「决策」，Shape 确认前不存在阻塞项。

# 验证预期

- 双引擎（pwsh 7 / Windows PowerShell 5.1）运行全部 `test-*.ps1`，全部 `ALL PASSED`，失败数为 0。
- `-Demo` 与 `-Demo -TrendWindow` 两种启动方式的日志均不出现 `fatal=True`、`unhandled=True`、`error=True`。
- `tools/build-site.ps1` 构建成功，落地页引用的资源都存在。
- `tools/package-release.ps1` 与 `tools/verify-package.ps1 -Version 0.15.0` 通过。
- PSScriptAnalyzer 不产生 Error 级别发现（Warning 不阻塞，与现状一致）。
- 人工可视验收：趋势图窗口的 7 / 14 / 30 天三种视图与多月对比 HTML 的渲染效果由用户确认。
