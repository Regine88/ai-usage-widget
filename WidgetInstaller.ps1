# Encoding: UTF-8 with BOM.
# WidgetInstaller.ps1 - 安装、升级与卸载的实现（纯函数 + 文件操作）。
#
# 约定：
#  - 运行文件清单只包含代码与启动器；用户数据（配置、历史、日志、导出 CSV）
#    永远不会被安装流程覆盖，卸载时也默认保留。
#  - 目标目录由调用方传入，测试可以在临时目录里完整跑一遍安装与卸载。
#  - 不写注册表、不需要管理员权限。

$script:WidgetRuntimeFiles = @(
    'AiUsageWidget.ps1'
    'UsageValidation.ps1'
    'SecureSnapshot.ps1'
    'GrokAccounts.ps1'
    'GeminiAntigravity.ps1'
    'KimiQuota.ps1'
    'CommandCodeQuota.ps1'
    'OpenRouterQuota.ps1'
    'DeepSeekQuota.ps1'
    'ApiKeyAuth.ps1'
    'WidgetPalette.ps1'
    'WidgetUpdates.ps1'
    'ModelRequestRecorder.ps1'
    'UsageHistory.ps1'
    'WidgetConfig.ps1'
    'WidgetStrings.ps1'
    'WidgetInstaller.ps1'
    'Record-ModelRequest.ps1'
    'GrokUsageWidget.ps1'
    'KimiUsageWidget.ps1'
    'ChatGptUsageWidget.ps1'
    'Start-AiUsageWidget.vbs'
    'Start-GrokUsageWidget.vbs'
    'Start-KimiUsageWidget.vbs'
    'Start-ChatGptUsageWidget.vbs'
)

$script:WidgetRuntimeDirs = @('strings')

$script:WidgetDataFiles = @(
    'ai-config.json'
    'ai-state.json'
    'ai-history.jsonl'
    'ai-request-events.jsonl'
    'ai-widget.log'
    'grok-aliases.json'
    'ai-usage-*.csv'
)

$script:WidgetInstallManifestName = 'ai-install.json'

# 目录路径去掉结尾分隔符，盘符根保留反斜杠（"C:" 追加分隔符后才是根）。
# 注意：只能用来拼接相对路径，不能拿它和 Get-ChildItem 的 FullName 比前缀——
# FullName 会把 8.3 短名（如 RUNNER~1）换成真实长名（runneradmin），同一目录的
# 两种写法长度不同，按长度截取会砍掉真实文件名。
function Get-WidgetPathStem {
    param([string]$Path)
    $stem = ([string]$Path).TrimEnd([char]92, [char]47)
    if ($stem.EndsWith(':')) { $stem += [char]92 }
    return $stem
}

# 文件在其运行子目录里的相对路径，例如 strings\zh-CN.json。
# 只用 $file.FullName 里 $SubDir 之后的部分，因为 FullName 的写法可能和调用方传入的
# $Dir 不同：Windows runner 上 TEMP 写作 8.3 短名 RUNNER~1，FullName 展开成长名
# runneradmin。按长度截取前缀会把 strings\zh-CN.json 砍成 rce\strings\zh-CN.json，
# 而拿两种写法互相 StartsWith 又永远配不上。
function Get-WidgetRuntimeRelativePath {
    param([string]$Full, [string]$Sub)
    $full = ([string]$Full).Replace([char]47, [char]92)
    $marker = '\' + $Sub + '\'
    $at = $full.LastIndexOf($marker, [StringComparison]::OrdinalIgnoreCase)
    if ($at -lt 0) { throw ('路径不在运行目录内: ' + $full) }
    return ($Sub + '\' + $full.Substring($at + $marker.Length))
}

function Get-WidgetRuntimeFileList {
    param([Parameter(Mandatory)][string]$Dir)
    $list = New-Object System.Collections.ArrayList
    if (Test-Path -LiteralPath $Dir -PathType Container) {
        foreach ($rel in $script:WidgetRuntimeFiles) {
            if (Test-Path -LiteralPath (Join-Path $Dir $rel) -PathType Leaf) { [void]$list.Add($rel) }
        }
        foreach ($sub in $script:WidgetRuntimeDirs) {
            $subDir = Join-Path $Dir $sub
            if (-not (Test-Path -LiteralPath $subDir -PathType Container)) { continue }
            foreach ($file in (Get-ChildItem -LiteralPath $subDir -Recurse -File)) {
                [void]$list.Add((Get-WidgetRuntimeRelativePath $file.FullName $sub))
            }
        }
    }
    return [object[]]$list.ToArray()
}

function Test-WidgetDataFileName {
    param([string]$Name)
    if (-not $Name) { return $false }
    foreach ($pattern in $script:WidgetDataFiles) {
        if ($Name -like $pattern) { return $true }
    }
    return $false
}

function Get-WidgetDataFileList {
    param([Parameter(Mandatory)][string]$Dir)
    $list = New-Object System.Collections.ArrayList
    if (Test-Path -LiteralPath $Dir -PathType Container) {
        foreach ($file in (Get-ChildItem -LiteralPath $Dir -File)) {
            if (Test-WidgetDataFileName $file.Name) { [void]$list.Add($file.Name) }
        }
    }
    return [object[]]$list.ToArray()
}

function Get-WidgetSourceVersion {
    param([Parameter(Mandatory)][string]$Dir)
    $entry = Join-Path $Dir 'AiUsageWidget.ps1'
    if (-not (Test-Path -LiteralPath $entry -PathType Leaf)) { return 'unknown' }
    try {
        $text = [IO.File]::ReadAllText($entry)
        $match = [regex]::Match($text, '[$]script:AppVersion[ ]*=[ ]*''([^'']+)''')
        if ($match.Success) { return $match.Groups[1].Value }
    } catch {
    }
    return 'unknown'
}

function Get-WidgetDefaultInstallDir {
    $base = [Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)
    if (-not $base) { $base = $env:LOCALAPPDATA }
    return (Join-Path $base 'Programs')
}

function Get-WidgetInstallDir {
    param([string]$Destination)
    if ($Destination) { return $Destination }
    return (Join-Path (Get-WidgetDefaultInstallDir) 'AIUsageWidget')
}

function Get-WidgetAccountStoreDir {
    $base = [Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)
    if (-not $base) { $base = $env:LOCALAPPDATA }
    return (Join-Path $base 'AIUsageWidget')
}

function Get-WidgetInstallManifestPath {
    param([Parameter(Mandatory)][string]$Dir)
    return (Join-Path $Dir $script:WidgetInstallManifestName)
}

function Read-WidgetInstallManifest {
    param([Parameter(Mandatory)][string]$Dir)
    $path = Get-WidgetInstallManifestPath $Dir
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $null }
    try {
        return (Get-Content -LiteralPath $path -Raw -Encoding utf8 | ConvertFrom-Json)
    } catch {
        return $null
    }
}

function Write-WidgetInstallManifest {
    param(
        [Parameter(Mandatory)][string]$Dir,
        [string]$Version,
        $Files,
        [string]$Source
    )
    if (-not $Version) { $Version = 'unknown' }
    $encoded = [ordered]@{
        version = $Version
        installedAt = (Get-Date).ToString('o')
        source = $Source
        files = [object[]]@($Files)
    }
    $json = $encoded | ConvertTo-Json -Depth 4
    $path = Get-WidgetInstallManifestPath $Dir
    [IO.File]::WriteAllText($path, ($json.TrimEnd([char]13, [char]10) + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
    return $path
}

function Install-AiUsageWidget {
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Destination,
        [string]$Version
    )
    if (-not (Test-Path -LiteralPath $Source -PathType Container)) { throw ('安装源不存在: ' + $Source) }
    $sourceFull = (Resolve-Path -LiteralPath $Source).Path
    if (-not (Test-Path -LiteralPath (Join-Path $sourceFull 'AiUsageWidget.ps1') -PathType Leaf)) {
        throw ('安装源里没有 AiUsageWidget.ps1: ' + $sourceFull)
    }
    $files = Get-WidgetRuntimeFileList $sourceFull
    if ($files.Count -eq 0) { throw ('安装源里没有可复制的运行文件: ' + $sourceFull) }

    if (-not (Test-Path -LiteralPath $Destination)) {
        New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    }
    $destFull = (Resolve-Path -LiteralPath $Destination).Path
    $sourceStem = Get-WidgetPathStem $sourceFull

    $copied = New-Object System.Collections.ArrayList
    $skipped = New-Object System.Collections.ArrayList
    foreach ($rel in $files) {
        $from = Join-Path $sourceStem $rel
        $to = Join-Path $destFull $rel
        $samePath = [string]::Equals([IO.Path]::GetFullPath($from), [IO.Path]::GetFullPath($to), [StringComparison]::OrdinalIgnoreCase)
        if ($samePath) { [void]$skipped.Add($rel); continue }
        $parent = Split-Path -Parent $to
        if ($parent -and -not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
        Copy-Item -LiteralPath $from -Destination $to -Force
        [void]$copied.Add($rel)
    }
    Write-WidgetInstallManifest -Dir $destFull -Version $Version -Files ([object[]]$copied.ToArray()) -Source $sourceFull | Out-Null
    return @{
        Destination = $destFull
        Source = $sourceFull
        Version = if ($Version) { $Version } else { 'unknown' }
        Copied = [object[]]$copied.ToArray()
        Skipped = [object[]]$skipped.ToArray()
        Data = Get-WidgetDataFileList $destFull
    }
}

function Uninstall-AiUsageWidget {
    param(
        [Parameter(Mandatory)][string]$Destination,
        [switch]$Purge
    )
    $removed = New-Object System.Collections.ArrayList
    $dirsRemoved = New-Object System.Collections.ArrayList
    if (-not (Test-Path -LiteralPath $Destination -PathType Container)) {
        return @{ Removed = [object[]]@(); Retained = [object[]]@(); RemovedDirectories = [object[]]@(); Purged = $false }
    }
    $destFull = (Resolve-Path -LiteralPath $Destination).Path

    foreach ($rel in (Get-WidgetRuntimeFileList $destFull)) {
        $full = Join-Path $destFull $rel
        if (Test-Path -LiteralPath $full -PathType Leaf) {
            Remove-Item -LiteralPath $full -Force
            [void]$removed.Add($rel)
        }
    }
    $manifest = Get-WidgetInstallManifestPath $destFull
    if (Test-Path -LiteralPath $manifest -PathType Leaf) {
        Remove-Item -LiteralPath $manifest -Force
        [void]$removed.Add($script:WidgetInstallManifestName)
    }
    foreach ($sub in $script:WidgetRuntimeDirs) {
        $subDir = Join-Path $destFull $sub
        if (-not (Test-Path -LiteralPath $subDir -PathType Container)) { continue }
        $leftover = @(Get-ChildItem -LiteralPath $subDir -Recurse -Force)
        if ($leftover.Count -eq 0) {
            Remove-Item -LiteralPath $subDir -Force
            [void]$dirsRemoved.Add($sub)
        }
    }

    $retained = Get-WidgetDataFileList $destFull
    $purged = $false
    if ($Purge) {
        Remove-Item -LiteralPath $destFull -Recurse -Force
        $retained = [object[]]@()
        $purged = $true
    } elseif (@(Get-ChildItem -LiteralPath $destFull -Recurse -Force).Count -eq 0) {
        # 没有用户数据残留时不留空目录
        Remove-Item -LiteralPath $destFull -Force
        [void]$dirsRemoved.Add('.')
    }
    return @{
        Removed = [object[]]$removed.ToArray()
        Retained = [object[]]@($retained)
        RemovedDirectories = [object[]]$dirsRemoved.ToArray()
        Purged = $purged
    }
}

function Get-WidgetShortcutDir {
    $programs = [Environment]::GetFolderPath([Environment+SpecialFolder]::Programs)
    if (-not $programs) {
        $appData = [Environment]::GetFolderPath([Environment+SpecialFolder]::ApplicationData)
        $programs = Join-Path (Join-Path (Join-Path $appData 'Microsoft') 'Windows') 'Start Menu'
        $programs = Join-Path $programs 'Programs'
    }
    return $programs
}

function Get-WidgetShortcutPath {
    param([string]$Name = 'AI Usage Widget')
    return (Join-Path (Get-WidgetShortcutDir) ($Name + '.lnk'))
}

function New-WidgetShortcut {
    param(
        [Parameter(Mandatory)][string]$ShortcutPath,
        [Parameter(Mandatory)][string]$TargetPath,
        [string]$WorkingDirectory,
        [string]$Description = 'AI Usage Widget'
    )
    $wscript = Join-Path (Join-Path $env:SystemRoot 'System32') 'wscript.exe'
    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($ShortcutPath)
    $shortcut.TargetPath = $wscript
    $shortcut.Arguments = '"' + $TargetPath + '"'
    if ($WorkingDirectory) { $shortcut.WorkingDirectory = $WorkingDirectory }
    if ($Description) { $shortcut.Description = $Description }
    $shortcut.Save()
    return $ShortcutPath
}

function Remove-WidgetShortcut {
    param([Parameter(Mandatory)][string]$ShortcutPath)
    if (Test-Path -LiteralPath $ShortcutPath -PathType Leaf) {
        Remove-Item -LiteralPath $ShortcutPath -Force
        return $true
    }
    return $false
}
