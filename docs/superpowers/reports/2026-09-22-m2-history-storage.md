# AI Usage Widget M2 历史存储验收

执行日期：2026-09-22。

## 目标与结论

M2 完成 schema v2、按月归档、旧文件双读迁移、日期与容量保留、定时有效采样、指标分类和周期感知预测。
旧的固定 2000 行截断已移除。

## 实现

schema v2 记录以下字段：

| 字段 | 含义 |
| --- | --- |
| `schemaVersion` / `ts` / `id` | 格式版本、采样时间、稳定行 ID |
| `provider` / `accountId` | 供应商与账号身份 |
| `metricType` | `percent` / `balance` / `unlimited` / `unknown` |
| `window` / `cycle` / `resetAt` | 窗口、周期和重置时间 |
| `value` / `unit` / `used` / `limit` | 原始值、单位、已用和上限 |
| `sampleState` | `changed` / `scheduled` / `legacy` |

存储布局：

- 旧 `<程序目录>\ai-history.jsonl` 保留并继续读取。
- 新样本写入 `<程序目录>\history\ai-history-YYYY-MM.jsonl`。
- 旧文件迁移是按月复制，源文件不删除，重复迁移按记录键去重。
- `Read-UsageHistory` 合并旧文件和全部归档，按时间排序去重。
- `historyRetentionDays` 默认 90 天；`historyMaxBytes` 默认 10 MB；容量不足时优先淘汰旧月份。
- 当前月文件不会被容量策略删除；无法压到上限时返回 `Incomplete=true`。
- 单月 Markdown / HTML 报表显示归档文件数、总字节数和容量不足警告。

采样与统计：

- 数值变化时记录 `changed`；没有变化但超过 `historySampleMinutes` 时记录 `scheduled`。
- DeepSeek 余额与 OpenRouter 无上限指标保留原始值，不参与百分比趋势或月度百分点变化。
- 百分比预测只使用当前 `resetAt` 周期内的样本，少于三个样本时不给估算。
- 5 小时窗口使用周期内原始采样，不会把跨重置周期的点直接拼接拟合。

## 验证

| 检查 | 结果 |
| --- | --- |
| PowerShell 7 全部离线套件 | 40/40 通过 |
| Windows PowerShell 5.1 全部离线套件 | 40/40 通过 |
| 4 个月 × 20 账号 | 80 个样本跨 4 个归档文件准确读取 |
| 24,000 行旧格式迁移 | 全部迁移，再加新样本读取为 24,001；原文件仍保留 24,000 行 |
| 超过 2000 行归档 | 2,500 行全部可读 |
| 重复迁移 | 第二次复制 0 行 |
| 保留与容量 | 旧月份按策略删除；当前月不可删除；容量不足标记不完整 |
| 余额/无上限 | 不进入百分比序列或报表 |
| 跨重置周期 | 只保留当前周期样本，三个样本以下不预测 |
| `tools/package-release.ps1` | 通过 |
| `tools/verify-package.ps1` | 通过，37 个运行文件、42 个压缩包条目 |

当前候选包 SHA256：

`5F308EF2025B8A78EBE8DC51EEE7221B95F8B83C26B28BBF6BC2E8C035ED607C`

## 安装与迁移

- 安装器把 `history\*.jsonl` 识别为用户数据；升级和默认卸载都保留月度归档。
- Scoop manifest 的 `persist` 增加 `history` 目录。
- 原始采样 CSV 跨旧文件与月度归档导出，并包含 schema、账号、指标、窗口、周期、单位和采样状态列。

## 已知边界

- 未进行真实供应商 API、GUI 目视或长时间常驻采样验收。
- 当前容量淘汰以整月为单位；无法只删除当前月中的旧记录。
- 旧记录没有稳定 provider/account 元数据时保留为 legacy 身份，不强行映射到新账号。
