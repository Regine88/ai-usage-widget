# Encoding: UTF-8 with BOM.
<#
.SYNOPSIS
  构建 GitHub Pages 站点（静态 HTML，无 Jekyll）。

.DESCRIPTION
  把 site/ 下的静态文件复制到输出目录，把 docs/images 里的截图放进 assets/，
  再替换 HTML 里的 {{VERSION}} 与 {{REPO}} 占位符。任何引用了不存在资源的页面都会直接失败，
  避免发布出一个图片全裂的落地页。

.EXAMPLE
  pwsh -NoProfile -File .\tools\build-site.ps1 -OutDir _site
#>
[CmdletBinding()]
param(
    [string]$OutDir,
    [string]$Root,
    [string]$Repo = 'Regine88/ai-usage-widget'
)

$ErrorActionPreference = 'Stop'
if (-not $Root) {
    $here = Split-Path -Parent $MyInvocation.MyCommand.Path
    $Root = Split-Path -Parent $here
}
$siteDir = Join-Path $Root 'site'
if (-not (Test-Path -LiteralPath $siteDir -PathType Container)) { throw ('缺少站点目录: ' + $siteDir) }
if (-not $OutDir) { $OutDir = Join-Path $Root '_site' }

function Get-SiteVersion {
    param([string]$Dir)
    $text = [IO.File]::ReadAllText((Join-Path $Dir 'AiUsageWidget.ps1'))
    $match = [regex]::Match($text, [regex]::Escape('$script:AppVersion') + "\s*=\s*'([0-9]+\.[0-9]+\.[0-9]+)'")
    if (-not $match.Success) { throw '无法从入口脚本读出版本号' }
    return $match.Groups[1].Value
}

$version = Get-SiteVersion -Dir $Root

if (Test-Path -LiteralPath $OutDir) {
    $resolved = [IO.Path]::GetFullPath($OutDir)
    if ($resolved.Length -lt 4 -or $resolved -eq $Root) { throw ('拒绝清理可疑的输出目录: ' + $resolved) }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
New-Item -ItemType Directory -Path $OutDir -Force | Out-Null

foreach ($file in @(Get-ChildItem -LiteralPath $siteDir -File -Force)) {
    Copy-Item -LiteralPath $file.FullName -Destination (Join-Path $OutDir $file.Name) -Force
}
foreach ($sub in @(Get-ChildItem -LiteralPath $siteDir -Directory -Force)) {
    Copy-Item -LiteralPath $sub.FullName -Destination (Join-Path $OutDir $sub.Name) -Recurse -Force
}

$assetsDir = Join-Path $OutDir 'assets'
New-Item -ItemType Directory -Path $assetsDir -Force | Out-Null
$imageDir = Join-Path $Root 'docs\images'
if (Test-Path -LiteralPath $imageDir -PathType Container) {
    foreach ($image in @(Get-ChildItem -LiteralPath $imageDir -File -Filter '*.png')) {
        Copy-Item -LiteralPath $image.FullName -Destination (Join-Path $assetsDir $image.Name) -Force
    }
}

$pages = @(Get-ChildItem -LiteralPath $OutDir -File -Filter '*.html')
if ($pages.Count -eq 0) { throw '站点里没有任何 HTML 页面' }
foreach ($page in $pages) {
    $text = [IO.File]::ReadAllText($page.FullName)
    $text = $text.Replace('{{VERSION}}', $version).Replace('{{REPO}}', ('https://github.com/' + $Repo))
    [IO.File]::WriteAllText($page.FullName, $text, [Text.UTF8Encoding]::new($false))
    if ($text -match '\{\{') { throw ('页面里还有未替换的占位符: ' + $page.Name) }
    foreach ($match in [regex]::Matches($text, '(?:src|href)="([^"]+)"')) {
        $reference = $match.Groups[1].Value
        if ($reference -match '^(https?:|mailto:|#|data:)') { continue }
        $target = Join-Path $OutDir ($reference -replace '/', '\')
        if (-not (Test-Path -LiteralPath $target)) { throw ('引用了不存在的资源 {0}（页面 {1}）' -f $reference, $page.Name) }
    }
}

Write-Host ('站点已生成: ' + $OutDir)
Write-Host ('  版本 ' + $version)
Write-Host ('  页面 {0} 个, 截图 {1} 张' -f $pages.Count, @(Get-ChildItem -LiteralPath $assetsDir -File -ErrorAction SilentlyContinue).Count)
