# Encoding: UTF-8 with BOM. Run: powershell -NoProfile -File .\test-SiteAssets.ps1
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path

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

$siteDir = Join-Path $here 'site'
$indexPath = Join-Path $siteDir 'index.html'
Assert-Eq (Test-Path -LiteralPath $indexPath) 'True' 'the landing page exists'
$html = [IO.File]::ReadAllText($indexPath)

Assert-Eq ($html -match '<html lang="zh-CN">') 'True' 'the page declares its language'
Assert-Eq ($html.Contains('<meta charset="utf-8">')) 'True' 'the page declares utf-8'
Assert-Eq ($html.Contains('{{VERSION}}')) 'True' 'the version placeholder is present for the build'
Assert-Eq ($html.Contains('{{REPO}}')) 'True' 'the repository placeholder is present for the build'
Assert-Eq ($html -match 'file://') 'False' 'no file protocol links'
Assert-Eq ($html -match '[A-Za-z]:\\\\') 'False' 'no absolute local paths'

# 站内锚点必须都有落点
$ids = @([regex]::Matches($html, 'id="([^"]+)"') | ForEach-Object { $_.Groups[1].Value })
$anchors = @([regex]::Matches($html, 'href="#([^"]+)"') | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
Assert-Eq (@($anchors | Where-Object { $ids -notcontains $_ }) -join ',') '' 'every in-page anchor has a target'

# 相对引用必须能在仓库里找到源头（assets/* 来自 docs/images）
$references = @([regex]::Matches($html, '(?:src|href)="([^"]+)"') | ForEach-Object { $_.Groups[1].Value } |
    Where-Object { $_ -notmatch '^(https?:|mailto:|#|data:|\{\{)' } | Sort-Object -Unique)
Assert-Eq (@($references).Count -gt 0) 'True' 'the page references local assets'
$missing = @()
foreach ($reference in $references) {
    $candidate = if ($reference -like 'assets/*') {
        Join-Path (Join-Path $here 'docs\images') (Split-Path -Leaf $reference)
    } else {
        Join-Path $siteDir ($reference -replace '/', '\')
    }
    if (-not (Test-Path -LiteralPath $candidate)) { $missing += $reference }
}
Assert-Eq ($missing -join ',') '' 'every referenced asset exists in the repo'

# 样式表本身不能依赖外部资源
$css = [IO.File]::ReadAllText((Join-Path $siteDir 'style.css'))
Assert-Eq ($css -match '@import') 'False' 'the stylesheet does not import remote css'
Assert-Eq ($css -match 'url\(\s*[''"]?https?:') 'False' 'the stylesheet does not load remote files'

# 构建一次，检查占位符替换与产物完整性
$outDir = Join-Path $env:TEMP ('widget-site-' + [guid]::NewGuid().ToString('N'))
try {
    & pwsh -NoProfile -ExecutionPolicy Bypass -File (Join-Path $here 'tools\build-site.ps1') -OutDir $outDir -Root $here *> $null
    Assert-Eq $LASTEXITCODE 0 'the site build succeeds'

    $built = [IO.File]::ReadAllText((Join-Path $outDir 'index.html'))
    Assert-Eq ($built -match '\{\{') 'False' 'the build replaces every placeholder'
    Assert-Eq ($built.Contains('https://github.com/Regine88/ai-usage-widget')) 'True' 'the build injects the repository url'

    $entryText = [IO.File]::ReadAllText((Join-Path $here 'AiUsageWidget.ps1'))
    $version = [regex]::Match($entryText, '\$script:AppVersion\s*=\s''([0-9.]+)''').Groups[1].Value
    Assert-Eq ($version -match '^[0-9]+\.[0-9]+\.[0-9]+$') 'True' 'the entry script exposes a version'
    Assert-Eq ($built.Contains($version)) 'True' 'the built page carries the current version'

    $expectedImages = @(Get-ChildItem -LiteralPath (Join-Path $here 'docs\images') -File -Filter '*.png').Count
    $builtImages = @(Get-ChildItem -LiteralPath (Join-Path $outDir 'assets') -File -Filter '*.png').Count
    Assert-Eq $builtImages $expectedImages 'every screenshot is copied into the site'

    $broken = @()
    foreach ($match in [regex]::Matches($built, '(?:src|href)="([^"]+)"')) {
        $reference = $match.Groups[1].Value
        if ($reference -match '^(https?:|mailto:|#|data:)') { continue }
        if (-not (Test-Path -LiteralPath (Join-Path $outDir ($reference -replace '/', '\')))) { $broken += $reference }
    }
    Assert-Eq ($broken -join ',') '' 'every reference resolves in the built site'
    Assert-Eq (Test-Path -LiteralPath (Join-Path $outDir '.nojekyll')) 'True' 'the site disables jekyll'
} finally {
    Remove-Item -LiteralPath $outDir -Recurse -Force -ErrorAction SilentlyContinue
}

if ($failed -gt 0) {
    Write-Host ("FAILED {0}" -f $failed)
    exit 1
}
Write-Host 'ALL PASSED'
exit 0
