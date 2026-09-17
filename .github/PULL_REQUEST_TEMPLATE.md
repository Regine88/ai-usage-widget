## 改动内容

<!-- 用一两句话说明这个 PR 做了什么、为什么需要。关联 Issue 请写 "Closes #123"。 -->

## 改动类型

- [ ] 修复缺陷
- [ ] 新增供应商
- [ ] 新功能
- [ ] 文档 / 工程
- [ ] 重构（无行为变化）

## 验证方式

<!-- 写出实际执行的命令与结果，而不是"应该没问题"。 -->

- [ ] `pwsh -NoProfile -File .\test-<相关模块>.ps1` 输出 `ALL PASSED`
- [ ] Windows PowerShell 5.1 下同一测试输出 `ALL PASSED`
- [ ] 涉及 UI 的改动，使用 `.\AiUsageWidget.ps1 -Demo` 目视确认过

## 自查清单

- [ ] 未提交任何凭据、快照、日志或含个人信息的文件（`*.log`、`ai-state.json`、`*auth*.json`、`*.jsonl`）
- [ ] 新增解析逻辑带离线测试，且测试不依赖网络与真实账号
- [ ] 函数签名变动时已同步更新所有调用点
- [ ] 已更新相关文档（`README`、`docs/`、`CHANGELOG.md`）
- [ ] 新增 `.ps1` 文件保存为 UTF-8 with BOM
