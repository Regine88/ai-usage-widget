# Encoding: UTF-8 with BOM. Run: powershell -NoProfile -File .\test-WidgetInstaller.ps1
# 说明：安装与卸载都在临时目录里完成，不触碰真实安装位置，也不会创建真实快捷方式。
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $here 'WidgetInstaller.ps1')

$failed = 0
function Assert-Eq {
    param($Actual, $Expected, [string]$Name)
    if ("$Actual" -ne "$Expected") {
        Write-Host ("FAIL {0}: expected [{1}] got [{2}]" -f $Name, $Expected, $Actual)
        $script:failed++
    } else {
        Write-Host ("OK   {0}" -f $Name)
    }
}

# ---------- 用户数据判定 ----------
Assert-Eq (Test-WidgetDataFileName 'ai-config.json') 'True' 'config file is user data'
Assert-Eq (Test-WidgetDataFileName 'ai-state.json') 'True' 'state file is user data'
Assert-Eq (Test-WidgetDataFileName 'ai-history.jsonl') 'True' 'history file is user data'
Assert-Eq (Test-WidgetDataFileName 'ai-widget.log') 'True' 'log file is user data'
Assert-Eq (Test-WidgetDataFileName 'ai-usage-20260917-120000.csv') 'True' 'csv export is user data'
Assert-Eq (Test-WidgetDataFileName 'AiUsageWidget.ps1') 'False' 'runtime file is not user data'
Assert-Eq (Test-WidgetDataFileName 'ai-history.jsonl.bak') 'False' 'unrelated file is not user data'
Assert-Eq (Test-WidgetDataFileName '') 'False' 'empty name is not user data'

# ---------- 默认路径 ----------
Assert-Eq ((Get-WidgetInstallDir $null) -like '*AIUsageWidget') 'True' 'default install dir'
Assert-Eq (Get-WidgetInstallDir 'C:/tmp/x') 'C:/tmp/x' 'explicit install dir wins'
Assert-Eq ((Get-WidgetShortcutPath) -like '*.lnk') 'True' 'shortcut path is a lnk'
Assert-Eq ((Get-WidgetShortcutPath 'Demo') -like '*Demo.lnk') 'True' 'shortcut name is honored'
Assert-Eq ((Get-WidgetAccountStoreDir) -like '*AIUsageWidget') 'True' 'account store dir'
Assert-Eq ((Get-WidgetSourceVersion $here) -match '^[0-9]+[.][0-9]+[.][0-9]+$') 'True' 'widget version is parsed from the entry script'
Assert-Eq (Get-WidgetSourceVersion (Join-Path $env:TEMP 'no-such-widget-dir')) 'unknown' 'missing entry script gives unknown version'

$root = Join-Path $env:TEMP ('widget-installer-test-' + [guid]::NewGuid().ToString('N'))
$source = Join-Path $root 'source'
$dest = Join-Path $root 'dest'
$strings = Join-Path $source 'strings'
New-Item -ItemType Directory -Path $strings -Force | Out-Null
$utf8 = [Text.UTF8Encoding]::new($false)
try {
    [IO.File]::WriteAllText((Join-Path $source 'AiUsageWidget.ps1'), ('$script:AppVersion = ''9.9.9''' + [Environment]::NewLine), $utf8)
    [IO.File]::WriteAllText((Join-Path $source 'UsageValidation.ps1'), '# placeholder', $utf8)
    [IO.File]::WriteAllText((Join-Path $source 'ai-config.json'), '{ "intervalSeconds": 900 }', $utf8)
    [IO.File]::WriteAllText((Join-Path $source 'README.md'), 'not shipped', $utf8)
    [IO.File]::WriteAllText((Join-Path $strings 'zh-CN.json'), '{ "hello": "world" }', $utf8)

    $runtime = Get-WidgetRuntimeFileList $source
    Assert-Eq (@($runtime) -contains 'AiUsageWidget.ps1') 'True' 'runtime list contains the entry script'
    Assert-Eq (@($runtime) -contains 'README.md') 'False' 'runtime list skips unlisted files'
    Assert-Eq (@($runtime).Count) 3 'runtime list count'

    # ---------- 安装 ----------
    $result = Install-AiUsageWidget -Source $source -Destination $dest -Version '9.9.9'
    Assert-Eq (Test-Path -LiteralPath (Join-Path $dest 'AiUsageWidget.ps1')) 'True' 'entry script copied'
    Assert-Eq (Test-Path -LiteralPath (Join-Path $dest 'UsageValidation.ps1')) 'True' 'module copied'
    Assert-Eq (Test-Path -LiteralPath (Join-Path $dest (Join-Path 'strings' 'zh-CN.json'))) 'True' 'strings dir copied'
    Assert-Eq (Test-Path -LiteralPath (Join-Path $dest 'ai-config.json')) 'False' 'user config never copied'
    Assert-Eq (Test-Path -LiteralPath (Join-Path $dest 'README.md')) 'False' 'unlisted file never copied'
    Assert-Eq (@($result.Copied).Count) 3 'copied count'
    Assert-Eq $result.Version '9.9.9' 'result carries the version'

    $manifest = Read-WidgetInstallManifest $dest
    Assert-Eq $manifest.version '9.9.9' 'manifest version'
    Assert-Eq (@($manifest.files).Count) 3 'manifest lists copied files'
    Assert-Eq (Get-WidgetSourceVersion $dest) '9.9.9' 'version parsed from the copied entry script'
    Assert-Eq (Get-WidgetDataFileList $dest).Count 0 'fresh install has no user data'

    # ---------- 升级 ----------
    [IO.File]::WriteAllText((Join-Path $dest 'ai-history.jsonl'), 'keep me', $utf8)
    [IO.File]::WriteAllText((Join-Path $source 'AiUsageWidget.ps1'), ('$script:AppVersion = ''9.9.10''' + [Environment]::NewLine), $utf8)
    $upgrade = Install-AiUsageWidget -Source $source -Destination $dest -Version '9.9.10'
    Assert-Eq ([IO.File]::ReadAllText((Join-Path $dest 'ai-history.jsonl'))) 'keep me' 'upgrade keeps user data'
    Assert-Eq (Get-WidgetSourceVersion $dest) '9.9.10' 'upgrade replaces code'
    Assert-Eq ((@($upgrade.Data) -join ',') ) 'ai-history.jsonl' 'upgrade reports retained data'

    # ---------- 快捷方式 ----------
    $lnk = Join-Path $root 'test-shortcut.lnk'
    $vbs = Join-Path $source 'Start-AiUsageWidget.vbs'
    [IO.File]::WriteAllText($vbs, 'x', $utf8)
    New-WidgetShortcut -ShortcutPath $lnk -TargetPath $vbs -WorkingDirectory $source | Out-Null
    Assert-Eq (Test-Path -LiteralPath $lnk) 'True' 'shortcut created'
    Assert-Eq (Remove-WidgetShortcut $lnk) 'True' 'shortcut removed'
    Assert-Eq (Remove-WidgetShortcut $lnk) 'False' 'removing a missing shortcut returns false'

    # ---------- 卸载 ----------
    $uninstall = Uninstall-AiUsageWidget -Destination $dest
    Assert-Eq (Test-Path -LiteralPath (Join-Path $dest 'AiUsageWidget.ps1')) 'False' 'uninstall removes the entry script'
    Assert-Eq (Test-Path -LiteralPath (Join-Path $dest 'strings')) 'False' 'uninstall removes the emptied strings dir'
    Assert-Eq (Test-Path -LiteralPath (Join-Path $dest 'ai-install.json')) 'False' 'uninstall removes the manifest'
    Assert-Eq (Test-Path -LiteralPath (Join-Path $dest 'ai-history.jsonl')) 'True' 'uninstall keeps user data'
    Assert-Eq ((@($uninstall.Removed).Count) -gt 0) 'True' 'uninstall reports removed files'
    Assert-Eq ((@($uninstall.Retained) -join ',')) 'ai-history.jsonl' 'uninstall reports retained data'
    Assert-Eq (Test-Path -LiteralPath $dest) 'True' 'uninstall keeps the dir while user data remains'

    $emptyDest = Join-Path $root 'empty-dest'
    Install-AiUsageWidget -Source $source -Destination $emptyDest -Version '9.9.11' | Out-Null
    Uninstall-AiUsageWidget -Destination $emptyDest | Out-Null
    Assert-Eq (Test-Path -LiteralPath $emptyDest) 'False' 'uninstall removes the dir when no user data is left'

    $missing = Uninstall-AiUsageWidget -Destination (Join-Path $root 'nope')
    Assert-Eq (@($missing.Removed).Count) 0 'uninstall of a missing dir is a no-op'

    # ---------- 彻底删除 ----------
    Uninstall-AiUsageWidget -Destination $dest -Purge | Out-Null
    Assert-Eq (Test-Path -LiteralPath $dest) 'False' 'purge removes the directory'

    # ---------- 错误路径 ----------
    $threw = $false
    try { Install-AiUsageWidget -Source (Join-Path $root 'missing-source') -Destination $dest } catch { $threw = $true }
    Assert-Eq $threw 'True' 'missing source throws'

    $empty = Join-Path $root 'empty-source'
    New-Item -ItemType Directory -Path $empty -Force | Out-Null
    $threw2 = $false
    try { Install-AiUsageWidget -Source $empty -Destination $dest } catch { $threw2 = $true }
    Assert-Eq $threw2 'True' 'source without the entry script throws'
} finally {
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}

# ---------- 运行文件清单的相对路径 ----------
# 回归：相对路径曾经用「路径长度相减」计算。Resolve-Path 给出 8.3 短名（例如 TEMP
# 变成 RUNNER~1）而 Get-ChildItem 给出长名时，两者长度不同，相减会把真实文件名
# 砍掉一段（strings\zh-CN.json 变成 rce\strings\zh-CN.json），安装出来的版本会缺
# 文件，CI 在 windows-latest 上因此长期失败。这里覆盖盘符根、多级子目录、带波浪号
# 的目录名，并要求每个相对路径都能拼回真实文件。
Assert-Eq (Get-WidgetPathStem 'C:\tmp\a\') 'C:\tmp\a' 'stem drops the trailing separator'
Assert-Eq (Get-WidgetPathStem 'C:\') 'C:\' 'stem keeps a drive root'
Assert-Eq (Get-WidgetPathStem '/tmp/a/') '/tmp/a' 'stem drops a trailing forward slash'

$relRoot = Join-Path $env:TEMP ('widget-rel-' + [guid]::NewGuid().ToString('N') + '-source')
$relDir = Join-Path (Join-Path $relRoot 'strings') '~extra'
New-Item -ItemType Directory -Path $relDir -Force | Out-Null
try {
    [IO.File]::WriteAllText((Join-Path $relRoot 'AiUsageWidget.ps1'), ('$script:AppVersion = ''9.9.12''' + [Environment]::NewLine), $utf8)
    [IO.File]::WriteAllText((Join-Path $relDir 'zh-CN.json'), '{ "hello": "world" }', $utf8)
    $relList = @(Get-WidgetRuntimeFileList $relRoot)
    Assert-Eq ($relList -contains 'strings\~extra\zh-CN.json') 'True' 'nested file keeps its relative path'
    Assert-Eq (@($relList | Where-Object { -not (Test-Path -LiteralPath (Join-Path $relRoot $_)) }) -join ',') '' 'every listed file resolves from the source dir'
} finally {
    Remove-Item -LiteralPath $relRoot -Recurse -Force -ErrorAction SilentlyContinue
}
# ---------- 清单必须覆盖主程序 dot-source 的每个模块 ----------
# 漏登记时安装 / 打包出来的版本会在启动时直接崩：dot-source 找不到文件。
$entryText = Get-Content -LiteralPath (Join-Path $here 'AiUsageWidget.ps1') -Raw -Encoding utf8
$sourced = @()
foreach ($match in [regex]::Matches($entryText, '\. \(Join-Path \$script:WidgetDir ''([^'']+)''\)')) {
    $sourced += $match.Groups[1].Value
}
Assert-Eq ($sourced.Count -ge 8) 'True' 'entry script dot-sources the modules'
Assert-Eq (@($sourced | Where-Object { @($script:WidgetRuntimeFiles) -notcontains $_ }) -join ',') '' 'every dot-sourced module is in the runtime file list'
Assert-Eq (@($script:WidgetRuntimeFiles).Count) (@($script:WidgetRuntimeFiles | Sort-Object -Unique).Count) 'runtime file list has no duplicates'
Assert-Eq (@($script:WidgetRuntimeFiles | Where-Object { -not (Test-Path -LiteralPath (Join-Path $here $_)) }) -join ',') '' 'every runtime file exists in the repo'
Assert-Eq (@($script:WidgetRuntimeDirs | Where-Object { -not (Test-Path -LiteralPath (Join-Path $here $_)) }) -join ',') '' 'every runtime dir exists in the repo'

if ($failed -gt 0) {
    Write-Host ("FAILED {0}" -f $failed)
    exit 1
}
Write-Host 'ALL PASSED'
exit 0
