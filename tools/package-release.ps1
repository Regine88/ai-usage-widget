# Encoding: UTF-8 with BOM.
<#
.SYNOPSIS
  打包 GitHub Release 压缩包，并生成 .sha256 与 Scoop manifest。

.DESCRIPTION
  发布内容与 install.ps1 复制的运行文件保持一致（共用 WidgetInstaller.ps1 的清单），
  再额外附带 install.ps1 与文档。输出目录默认是仓库根目录下的 dist。

.EXAMPLE
  pwsh -NoProfile -File .\tools\package-release.ps1 -Version 0.10.0
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Version,
    [string]$OutDir,
    [string]$Repo = 'Regine88/ai-usage-widget'
)

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$root = Split-Path -Parent $here
if (-not $OutDir) { $OutDir = Join-Path $root 'dist' }
. (Join-Path $root 'WidgetInstaller.ps1')

$packageName = 'ai-usage-widget-' + $Version
$stageRoot = Join-Path $OutDir 'stage'
$stageDir = Join-Path $stageRoot $packageName

if (Test-Path -LiteralPath $stageRoot) { Remove-Item -LiteralPath $stageRoot -Recurse -Force }
New-Item -ItemType Directory -Path $stageDir -Force | Out-Null

$runtime = Get-WidgetRuntimeFileList $root
if (@($runtime).Count -eq 0) { throw ('没有找到可打包的运行文件: ' + $root) }
foreach ($rel in $runtime) {
    $from = Join-Path $root $rel
    $to = Join-Path $stageDir $rel
    $parent = Split-Path -Parent $to
    if ($parent -and -not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    Copy-Item -LiteralPath $from -Destination $to -Force
}

foreach ($extra in @('install.ps1', 'LICENSE', 'README.md', 'README.en.md', 'CHANGELOG.md')) {
    $from = Join-Path $root $extra
    if (Test-Path -LiteralPath $from -PathType Leaf) { Copy-Item -LiteralPath $from -Destination (Join-Path $stageDir $extra) -Force }
}

$zipName = $packageName + '.zip'
$zipPath = Join-Path $OutDir $zipName
if (Test-Path -LiteralPath $zipPath) { Remove-Item -LiteralPath $zipPath -Force }
Compress-Archive -Path $stageDir -DestinationPath $zipPath -CompressionLevel Optimal

$hash = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash
$shaLine = $hash + '  ' + $zipName + [Environment]::NewLine
[IO.File]::WriteAllText((Join-Path $OutDir ($zipName + '.sha256')), $shaLine, [Text.UTF8Encoding]::new($false))

$baseUrl = 'https://github.com/' + $Repo + '/releases/download/v' + $Version + '/'
$manifest = [ordered]@{
    version = $Version
    description = 'Desktop widget that shows AI subscription quota usage'
    homepage = 'https://github.com/' + $Repo
    license = 'MIT'
    url = $baseUrl + $zipName
    hash = $hash
    extract_dir = $packageName
    shortcuts = @(, @('Start-AiUsageWidget.vbs', 'AI Usage Widget'))
    persist = @(
        'ai-config.json'
        'ai-state.json'
        'ai-history.jsonl'
        'ai-request-events.jsonl'
        'ai-widget.log'
        'grok-aliases.json'
    )
    checkver = @{ github = 'https://github.com/' + $Repo }
    autoupdate = @{ url = 'https://github.com/' + $Repo + '/releases/download/v$version/ai-usage-widget-$version.zip' }
}
$manifestJson = $manifest | ConvertTo-Json -Depth 6
$manifestPath = Join-Path $OutDir 'ai-usage-widget.json'
[IO.File]::WriteAllText($manifestPath, ($manifestJson.TrimEnd([char]13, [char]10) + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))

Remove-Item -LiteralPath $stageRoot -Recurse -Force

Write-Host ('打包完成: ' + $zipPath)
Write-Host ('SHA256  : ' + $hash)
Write-Host ('清单    : ' + $manifestPath)
Write-Host ('包含文件: ' + @($runtime).Count + ' 个运行文件 + install.ps1 与文档')
