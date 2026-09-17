# 0.14.0 验收记录（2026-09-17）

对应计划：`docs/superpowers/plans/2026-09-17-ai-usage-widget-open-source-roadmap.md`（P1 收尾与开源发布面完善）。

## 结论

0.14.0 交付四块内容：历史月度报表与导出增强、发布流程的打包内容校验、GitHub Pages 落地页，
并把智谱 BigModel（含 ZCode 凭证）并入 GLM 行。发布链路第一次做到「打包之后必须校验内容」，
Release 工作流在校验不通过时直接失败，不再把缺文件的包发出去。

## 交付物

| 内容 | 交付物 | 状态 |
| --- | --- | --- |
| 报表纯函数 | `UsageReport.ps1`：月份归一与边界、按天汇总、月度汇总、CSV / Markdown / 自包含 HTML | 完成 |
| 导出入口 | 右键「导出历史」四项；`Export-UsageReportInteractive`；默认最近一个有数据的月份，空历史只提示不写文件 | 完成 |
| 打包校验 | `WidgetPackage.ps1` + `tools/verify-package.ps1`：条目比对、禁止文件、包内版本号、`.sha256`、Scoop manifest | 完成 |
| CI / Release | CI 新增 `Package contents` job；Release 打包后插入 `Verify package contents` 步骤 | 完成 |
| 落地页 | `site/` + `tools/build-site.ps1` + `.github/workflows/pages.yml`，构建时注入版本号与仓库地址 | 完成 |
| 新供应商 | BigModel 并入 GLM 行：`~/.bigmodel/auth.json`、`$env:BIGMODEL_API_KEY`、ZCode `~/.zcode/v2/config.json` | 完成 |
| 文案 | `strings/*.json`：`menu.export*`、`report.*`、`error.planMissing`；`WidgetStrings.ps1` 兜底表同步 | 完成 |
| 安装清单 | `WidgetInstaller.ps1` 运行文件清单加入 `UsageReport.ps1`（34 个运行文件 + 5 个附加条目） | 完成 |
| 文档 | README 双语文、CHANGELOG、`docs/architecture.md`、`docs/providers.md`、`docs/troubleshooting.md` | 完成 |

## 验证证据

```text
TOTAL=68 FAILED=0
ALL SUITES PASSED

34 套件 x 2 引擎（pwsh 7 / Windows PowerShell 5.1）= 68 次执行，failures = 0
新增套件：test-UsageReport.ps1、test-WidgetPackage.ps1、test-SiteAssets.ps1
扩充套件：test-ZaiQuota.ps1（业务错误信封）、test-ZaiProvider.ps1（BigModel / ZCode 凭证）、
          test-WidgetStrings.ps1（导出菜单键改名）

CI：run 35212636619  success  （10:51:14Z -> 10:52:20Z，66s）
  Package contents                 success
  Test (PowerShell 7)              success
  Test (Windows PowerShell 5.1)    success
  PSScriptAnalyzer                 success

Pages：run 35212636605  success
  Build site  success / Deploy  success
  线上自检：https://regine88.github.io/ai-usage-widget/ 返回 200（9893 字节，
  含 0.14.0、无未替换占位符）；style.css 200；assets/demo-card.png 200。

打包内容自检（本地 tools/verify-package.ps1 -Version 0.14.0）：
  运行文件 34 个 + 附加 5 个，压缩包条目 39 个，全部检查通过，exitcode=0

文档相对链接检查：35 个链接全部解析成功。
```

## 界面回归（-Demo 冒烟）

```text
starting widget v0.14.0 (demo mode)
config interval=60s language=auto trend=True forecast=True
strings language=zh-CN keys=162
form location 2140,1030
run loop / form shown / timer started
rows rebuilt: demo-grok,demo-kimi,demo-codex,demo-commandcode,demo-openrouter,
              demo-deepseek,demo-claude,demo-cursor,demo-glm,demo-copilot
fatal=False unhandled=False error=False
```

演示实例以隐藏控制台启动，读取日志后按 PID 精确结束；用户正在运行的真实实例（pid 16700）不受影响。

## 已知边界

- 报表按月导出，月份来自历史里已经出现的数据；界面内没有图表，跨月对比需要打开两份报表。
- 「导出历史」的原始采样 CSV 仍是全部历史；按天 / Markdown / HTML 只覆盖所选月份。
- BigModel 中国站与 Z.AI 国际站同路径同鉴权；账号没开通 Coding Plan 时显示本地化业务错误。
- `tools/verify-package.ps1` 校验包内容与仓库清单的一致性，不校验外部下载源与 Scoop 安装结果。
- 落地页按路径过滤触发：只有 `site/**`、`docs/images/**`、`tools/build-site.ps1` 或工作流本身变化时才会重新部署。

## 验证命令

```powershell
# 双引擎全量测试
foreach ($engine in 'pwsh', 'powershell') {
    Get-ChildItem -Filter 'test-*.ps1' | ForEach-Object {
        & $engine -NoProfile -ExecutionPolicy Bypass -File $_.FullName
    }
}

# 打包 + 内容校验
pwsh -NoProfile -File .\tools\package-release.ps1 -Version 0.14.0 -OutDir dist
pwsh -NoProfile -File .\tools\verify-package.ps1 -Version 0.14.0 -OutDir dist

# 落地页构建（输出到 _site/）
pwsh -NoProfile -File .\tools\build-site.ps1 -OutDir _site

# 界面回归
pwsh -NoProfile -STA -File .\AiUsageWidget.ps1 -Demo
```
