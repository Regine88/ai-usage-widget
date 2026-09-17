# Encoding: UTF-8 with BOM.
<#
.SYNOPSIS
  校验 GitHub Release 产物：zip 内容、版本号、SHA256 与 Scoop manifest 是否自洽。

.DESCRIPTION
  在打包之后、发布之前运行。任何一项不通过都会以非零退出码结束，
  避免“装完缺模块”“把本机配置打进发布包”这类问题流到用户手里。

.EXAMPLE
  pwsh -NoProfile -File .\tools\verify-package.ps1 -Version 0.14.0
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Version,
    [string]$OutDir,
    [string]$Root,
    [string]$Repo = 'Regine88/ai-usage-widget'
)

$ErrorActionPreference = 'Stop'
if (-not $Root) {
    $here = Split-Path -Parent $MyInvocation.MyCommand.Path
    $Root = Split-Path -Parent $here
}
if (-not $OutDir) { $OutDir = Join-Path $Root 'dist' }

. (Join-Path $Root 'WidgetInstaller.ps1')
. (Join-Path $Root 'WidgetPackage.ps1')

$packageName = 'ai-usage-widget-' + $Version
$zipName = $packageName + '.zip'
$zipPath = Join-Path $OutDir $zipName
$problems = @()

if (-not (Test-Path -LiteralPath $zipPath -PathType Leaf)) { throw ('发布包不存在: ' + $zipPath) }

$runtime = Get-WidgetRuntimeFileList $Root
if (@($runtime).Count -eq 0) { throw ('没有找到可打包的运行文件: ' + $Root) }
$expected = Get-WidgetPackageExpectedEntries -Runtime $runtime -Extra (Get-WidgetPackageExtraFiles)
$actual = Read-WidgetZipEntryNames -Path $zipPath
$comparison = Compare-WidgetPackageEntries -Expected $expected -Actual $actual -Prefix $packageName

if (@($comparison.Missing).Count -gt 0) { $problems += ('缺少文件: ' + (@($comparison.Missing) -join ', ')) }
if (@($comparison.Extra).Count -gt 0) { $problems += ('多余文件: ' + (@($comparison.Extra) -join ', ')) }
if (@($comparison.Forbidden).Count -gt 0) { $problems += ('含数据或凭证文件: ' + (@($comparison.Forbidden) -join ', ')) }

$entryScript = Read-WidgetZipEntryText -Path $zipPath -EntryName ($packageName + '/AiUsageWidget.ps1')
if (-not $entryScript) { $problems += '压缩包里读不到 AiUsageWidget.ps1' }
elseif (-not (Test-WidgetPackageVersionText -Text $entryScript -Version $Version)) { $problems += ('压缩包里的版本号不是 ' + $Version) }

$hash = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash
$hashPath = $zipPath + '.sha256'
if (-not (Test-Path -LiteralPath $hashPath -PathType Leaf)) {
    $problems += '缺少 .sha256 文件'
} else {
    $declared = ([IO.File]::ReadAllText($hashPath) -split '\s+')[0]
    if ($declared -ne $hash) { $problems += '.sha256 与实际压缩包不一致' }
}

$manifestPath = Join-Path $OutDir 'ai-usage-widget.json'
if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
    $problems += '缺少 Scoop manifest'
} else {
    try { $manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding utf8 | ConvertFrom-Json }
    catch { $manifest = $null }
    $problems += @(Get-WidgetPackageManifestProblems -Manifest $manifest -Version $Version -Hash $hash -ZipName $zipName -Repo $Repo)
}

# 发布说明必须来自当前版本的 CHANGELOG 段落，避免 Release 里出现上一版的文案。
$notesPath = Join-Path $OutDir 'RELEASE_NOTES.md'
$changelogPath = Join-Path $Root 'CHANGELOG.md'
if (Test-Path -LiteralPath $notesPath -PathType Leaf) {
    $notes = [IO.File]::ReadAllText($notesPath)
    if ($notes.Length -lt 20) { $problems += 'RELEASE_NOTES.md 内容过短' }
    $section = [regex]::Match([IO.File]::ReadAllText($changelogPath), ('(?ms)^## \[' + [regex]::Escape($Version) + '\][^\r\n]*\r?\n(.*?)(?=^## \[|\z)'))
    if ($section.Success) {
        $head = ($section.Groups[1].Value.Trim() -split "`r?`n" | Where-Object { $_.Trim() } | Select-Object -First 1)
        if ($head -and ($notes -notlike ('*' + $head.Trim() + '*'))) { $problems += 'RELEASE_NOTES.md 与 CHANGELOG 的该版本段落不一致' }
    }
}

Write-Host ('校验发布包: ' + $zipPath)
Write-Host ('  运行文件 {0} 个 + 附加 {1} 个' -f @($runtime).Count, @(Get-WidgetPackageExtraFiles).Count)
Write-Host ('  压缩包条目 {0} 个' -f @($actual).Count)
Write-Host ('  SHA256 ' + $hash)

if ($problems.Count -gt 0) {
    foreach ($problem in $problems) { Write-Host ('  [失败] ' + $problem) }
    throw ('发布包校验失败，共 {0} 项' -f $problems.Count)
}

Write-Host '  全部检查通过'
