# Encoding: UTF-8 with BOM.
<#
.SYNOPSIS
  AI Usage Widget 安装器（安装 / 升级 / 卸载 / 查看状态）。

.DESCRIPTION
  安装：把运行文件复制到 %LOCALAPPDATA%\Programs\AIUsageWidget，并创建开始菜单快捷方式。
  升级：重复执行即可；ai-config.json、ai-history.jsonl 等用户数据不会被覆盖。
  卸载：-Uninstall（默认保留用户数据）；-Purge 连用户数据与账户快照一起删除。
  不写注册表、不需要管理员权限。

.PARAMETER Source
  安装源目录，默认是脚本所在目录。
.PARAMETER Destination
  安装目录，默认 %LOCALAPPDATA%\Programs\AIUsageWidget。
.PARAMETER Zip
  从 Release 压缩包安装：解压后自动定位包内的程序目录。
.PARAMETER Uninstall
  卸载。
.PARAMETER Purge
  卸载时连同用户数据与账户快照一起删除（不可恢复）。
.PARAMETER NoShortcut
  安装时不创建开始菜单快捷方式。
.PARAMETER Status
  显示当前安装状态后退出。
.PARAMETER Force
  跳过卸载确认。

.EXAMPLE
  .\install.ps1
.EXAMPLE
  .\install.ps1 -Status
.EXAMPLE
  .\install.ps1 -Uninstall
.EXAMPLE
  .\install.ps1 -Zip .\ai-usage-widget-0.13.0.zip
#>
[CmdletBinding()]
param(
    [string]$Source,
    [string]$Destination,
    [string]$Zip,
    [switch]$Uninstall,
    [switch]$Purge,
    [switch]$NoShortcut,
    [switch]$Status,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $here 'WidgetInstaller.ps1')

$installDir = Get-WidgetInstallDir $Destination
$shortcutPath = Get-WidgetShortcutPath

if ($Status) {
    $manifest = Read-WidgetInstallManifest $installDir
    if (-not $manifest) {
        Write-Host ('未安装：' + $installDir)
        exit 0
    }
    $data = Get-WidgetDataFileList $installDir
    $dataText = if (@($data).Count -gt 0) { (@($data) -join '、') } else { '无' }
    Write-Host ('安装目录：' + $installDir)
    Write-Host ('版本：' + $manifest.version)
    Write-Host ('安装时间：' + $manifest.installedAt)
    Write-Host ('用户数据：' + $dataText)
    exit 0
}

if ($Uninstall) {
    if (-not (Test-Path -LiteralPath $installDir -PathType Container)) {
        Write-Host ('未安装：' + $installDir)
        exit 0
    }
    $accountDir = Get-WidgetAccountStoreDir
    if ($Purge -and -not $Force) {
        Write-Host '即将删除以下内容，且无法恢复：'
        Write-Host ('  程序目录：' + $installDir)
        Write-Host ('  账户快照：' + $accountDir)
        $answer = Read-Host '输入 yes 确认'
        if ($answer -ne 'yes') {
            Write-Host '已取消。'
            exit 1
        }
    }
    $result = Uninstall-AiUsageWidget -Destination $installDir -Purge:$Purge
    if (-not $Purge) {
        if (Remove-WidgetShortcut $shortcutPath) { Write-Host ('已删除快捷方式：' + $shortcutPath) }
    } else {
        Remove-WidgetShortcut $shortcutPath | Out-Null
    }
    $removedCount = @($result.Removed).Count
    Write-Host ('已卸载：' + $installDir + '（删除 ' + $removedCount + ' 个文件）')
    if (@($result.RemovedDirectories).Count -gt 0) {
        Write-Host ('已清理目录：' + (@($result.RemovedDirectories) -join '、'))
    }
    if (@($result.Retained).Count -gt 0) {
        Write-Host ('保留的用户数据（位于 ' + $installDir + '）：' + (@($result.Retained) -join '、'))
        Write-Host '如需彻底删除，请重新运行并加 -Purge。'
    }
    if ($Purge -and (Test-Path -LiteralPath $accountDir)) {
        Remove-Item -LiteralPath $accountDir -Recurse -Force
        Write-Host ('已删除账户快照：' + $accountDir)
    }
    exit 0
}

$cleanup = $null
try {
    if ($Zip) {
        if (-not (Test-Path -LiteralPath $Zip -PathType Leaf)) { throw ('压缩包不存在：' + $Zip) }
        $zipFull = (Resolve-Path -LiteralPath $Zip).Path
        $sumPath = $zipFull + '.sha256'
        if (Test-Path -LiteralPath $sumPath -PathType Leaf) {
            $expected = ((Get-Content -LiteralPath $sumPath -Raw -ErrorAction Stop).Trim() -split '\s+')[0]
            $actual = (Get-FileHash -LiteralPath $zipFull -Algorithm SHA256).Hash
            if (-not $expected -or $expected.ToLowerInvariant() -ne $actual.ToLowerInvariant()) {
                throw '压缩包校验失败：SHA256 不匹配'
            }
        }
        $tmp = Join-Path $env:TEMP ('ai-usage-widget-install-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $tmp | Out-Null
        $cleanup = $tmp
        Expand-Archive -LiteralPath $zipFull -DestinationPath $tmp -Force
        $candidate = $null
        if (Test-Path -LiteralPath (Join-Path $tmp 'AiUsageWidget.ps1') -PathType Leaf) {
            $candidate = $tmp
        } else {
            foreach ($child in (Get-ChildItem -LiteralPath $tmp -Directory)) {
                if (Test-Path -LiteralPath (Join-Path $child.FullName 'AiUsageWidget.ps1') -PathType Leaf) {
                    $candidate = $child.FullName
                    break
                }
            }
        }
        if (-not $candidate) { throw '压缩包里没有找到 AiUsageWidget.ps1' }
        $Source = $candidate
    } elseif (-not $Source) {
        $Source = $here
    }

    if (-not (Test-Path -LiteralPath $Source -PathType Container)) { throw ('安装源不存在：' + $Source) }
    $sourceFull = (Resolve-Path -LiteralPath $Source).Path
    $version = Get-WidgetSourceVersion $sourceFull
    $result = Install-AiUsageWidget -Source $sourceFull -Destination $installDir -Version $version

    $shortcutNote = '未创建（-NoShortcut）'
    if (-not $NoShortcut) {
        $target = Join-Path $result.Destination 'Start-AiUsageWidget.vbs'
        if (Test-Path -LiteralPath $target -PathType Leaf) {
            New-WidgetShortcut -ShortcutPath $shortcutPath -TargetPath $target -WorkingDirectory $result.Destination | Out-Null
            $shortcutNote = $shortcutPath
        } else {
            $shortcutNote = '跳过（缺少启动器 Start-AiUsageWidget.vbs）'
        }
    }

    $copiedCount = @($result.Copied).Count
    Write-Host ''
    Write-Host ('AI Usage Widget ' + $result.Version + ' 已安装')
    Write-Host ('  安装目录：' + $result.Destination)
    Write-Host ('  开始菜单：' + $shortcutNote)
    Write-Host ('  复制文件：' + $copiedCount + ' 个')
    if (@($result.Data).Count -gt 0) {
        Write-Host ('  保留原有用户数据：' + (@($result.Data) -join '、'))
    }
    Write-Host ''
    Write-Host '启动方式：'
    Write-Host ('  wscript.exe "' + (Join-Path $result.Destination 'Start-AiUsageWidget.vbs') + '"')
    Write-Host '  或者从开始菜单打开 AI Usage Widget'
    Write-Host ''
    Write-Host '升级：再次运行本脚本即可，用户数据不会被覆盖。'
    Write-Host '卸载：.\install.ps1 -Uninstall'
} finally {
    if ($cleanup -and (Test-Path -LiteralPath $cleanup)) {
        Remove-Item -LiteralPath $cleanup -Recurse -Force -ErrorAction SilentlyContinue
    }
}
