# Encoding: UTF-8 with BOM. Run: powershell -NoProfile -File .\test-WidgetPackage.ps1
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $here 'WidgetPackage.ps1')

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

# ---------- 禁止发布的文件 ----------
Assert-Eq (Test-WidgetPackageForbiddenEntry 'ai-config.json') 'True' 'runtime config is forbidden'
Assert-Eq (Test-WidgetPackageForbiddenEntry 'pkg/ai-history.jsonl') 'True' 'history samples are forbidden'
Assert-Eq (Test-WidgetPackageForbiddenEntry 'ai-usage-widget-1.0.0/ai-widget.log') 'True' 'logs are forbidden'
Assert-Eq (Test-WidgetPackageForbiddenEntry 'nested/credentials.json') 'True' 'credentials are forbidden'
Assert-Eq (Test-WidgetPackageForbiddenEntry 'nested/token-cache.json') 'True' 'token files are forbidden'
Assert-Eq (Test-WidgetPackageForbiddenEntry 'state.vscdb') 'True' 'browser storage is forbidden'
Assert-Eq (Test-WidgetPackageForbiddenEntry 'AiUsageWidget.ps1') 'False' 'the entry script ships'
Assert-Eq (Test-WidgetPackageForbiddenEntry 'README.md') 'False' 'docs ship'
Assert-Eq (Test-WidgetPackageForbiddenEntry '') 'False' 'an empty name is not forbidden'

# ---------- 期望清单 ----------
$expected = Get-WidgetPackageExpectedEntries -Runtime @('b.ps1', 'a.ps1', 'a.ps1') -Extra @('LICENSE', 'a.ps1')
Assert-Eq ($expected -join ',') 'a.ps1,b.ps1,LICENSE' 'expected entries are unique and sorted'
Assert-Eq ((Get-WidgetPackageExpectedEntries -Runtime @() -Extra @()).Count) 0 'empty input stays empty'
Assert-Eq (@(Get-WidgetPackageExtraFiles) -contains 'install.ps1') 'True' 'install.ps1 is part of the extras'

# ---------- 前缀剥离 ----------
Assert-Eq (ConvertTo-WidgetPackageRelativeEntry 'pkg/sub/a.ps1' 'pkg') 'sub/a.ps1' 'prefix is stripped'
Assert-Eq (ConvertTo-WidgetPackageRelativeEntry 'pkg\sub\a.ps1' 'pkg') 'sub/a.ps1' 'backslashes are normalised'
Assert-Eq (ConvertTo-WidgetPackageRelativeEntry 'other/a.ps1' 'pkg') 'other/a.ps1' 'a foreign prefix is kept'
Assert-Eq (ConvertTo-WidgetPackageRelativeEntry '' 'pkg') '' 'empty stays empty'

# ---------- 内容比对 ----------
$comparison = Compare-WidgetPackageEntries -Expected @('a.ps1', 'b.ps1') -Actual @('pkg/a.ps1', 'pkg/c.ps1', 'pkg/dir/', 'pkg/ai-config.json') -Prefix 'pkg'
Assert-Eq ($comparison.Missing -join ',') 'b.ps1' 'missing files are reported'
Assert-Eq ($comparison.Extra -join ',') 'c.ps1' 'extra files are reported'
Assert-Eq ($comparison.Forbidden -join ',') 'ai-config.json' 'forbidden files are reported'
Assert-Eq (@(Compare-WidgetPackageEntries -Expected @('a.ps1') -Actual @('pkg/a.ps1') -Prefix 'pkg').Missing.Count) 0 'a complete archive has no missing file'
Assert-Eq (@(Compare-WidgetPackageEntries -Expected @('a.ps1') -Actual @('pkg/a.ps1') -Prefix 'pkg').Extra.Count) 0 'a complete archive has no extra file'

# ---------- 版本号 ----------
Assert-Eq (Test-WidgetPackageVersionText -Text "`$script:AppVersion = '0.14.0'" -Version '0.14.0') 'True' 'the version marker matches'
Assert-Eq (Test-WidgetPackageVersionText -Text "`$script:AppVersion = '0.14.0'" -Version '0.13.0') 'False' 'a different version is rejected'
Assert-Eq (Test-WidgetPackageVersionText -Text '' -Version '0.14.0') 'False' 'empty text is rejected'
Assert-Eq (Test-WidgetPackageVersionText -Text "`$script:AppVersion='0.14.0'" -Version '0.14.0') 'True' 'spacing around the marker does not matter'

# ---------- Scoop manifest ----------
$goodManifest = [pscustomobject]@{
    version     = '0.14.0'
    url         = 'https://github.com/Regine88/ai-usage-widget/releases/download/v0.14.0/ai-usage-widget-0.14.0.zip'
    hash        = 'ABCDEF'
    extract_dir = 'ai-usage-widget-0.14.0'
    checkver    = @{ github = 'https://github.com/Regine88/ai-usage-widget' }
    persist     = @('ai-config.json', 'ai-state.json', 'ai-history.jsonl', 'history')
}
$problems = @(Get-WidgetPackageManifestProblems -Manifest $goodManifest -Version '0.14.0' -Hash 'ABCDEF' -ZipName 'ai-usage-widget-0.14.0.zip' -Repo 'Regine88/ai-usage-widget')
Assert-Eq $problems.Count 0 'a matching manifest has no problems'
$bad = $goodManifest.PSObject.Copy()
$bad.hash = 'WRONG'
$bad.version = '0.13.0'
$problems = @(Get-WidgetPackageManifestProblems -Manifest $bad -Version '0.14.0' -Hash 'ABCDEF' -ZipName 'ai-usage-widget-0.14.0.zip' -Repo 'Regine88/ai-usage-widget')
Assert-Eq (@($problems -like '*hash*').Count) 1 'a wrong hash is reported'
Assert-Eq (@($problems -like '*version*').Count) 1 'a wrong version is reported'
$noPersist = $goodManifest.PSObject.Copy()
$noPersist.persist = @('ai-config.json')
Assert-Eq (@(Get-WidgetPackageManifestProblems -Manifest $noPersist -Version '0.14.0' -Hash 'ABCDEF' -ZipName 'ai-usage-widget-0.14.0.zip' -Repo 'Regine88/ai-usage-widget').Count) 3 'missing persist entries are reported'
Assert-Eq (Get-WidgetPackageManifestProblems -Manifest $null -Version '0.14.0' -Hash 'x' -ZipName 'y' -Repo 'z') 'manifest is missing' 'a missing manifest is reported'

# ---------- 真实压缩包往返 ----------
Assert-Eq (Test-WidgetPackageZipSupport) 'True' 'zip support is available on this host'
$dir = Join-Path $env:TEMP ('widget-package-' + [guid]::NewGuid().ToString('N'))
$stage = Join-Path $dir 'ai-usage-widget-9.9.9'
New-Item -ItemType Directory -Path $stage -Force | Out-Null
$zipPath = Join-Path $dir 'ai-usage-widget-9.9.9.zip'
try {
    [IO.File]::WriteAllText((Join-Path $stage 'AiUsageWidget.ps1'), "`$script:AppVersion = '9.9.9'`n", [Text.UTF8Encoding]::new($true))
    [IO.File]::WriteAllText((Join-Path $stage 'LICENSE'), 'MIT', [Text.UTF8Encoding]::new($false))
    Compress-Archive -Path $stage -DestinationPath $zipPath -CompressionLevel Optimal

    $names = @(Read-WidgetZipEntryNames -Path $zipPath)
    Assert-Eq ($names.Count -ge 2) 'True' 'the archive lists its entries'
    $comparison = Compare-WidgetPackageEntries -Expected @('AiUsageWidget.ps1', 'LICENSE') -Actual $names -Prefix 'ai-usage-widget-9.9.9'
    Assert-Eq ($comparison.Missing.Count + $comparison.Extra.Count + $comparison.Forbidden.Count) 0 'a hand made archive compares clean'

    $text = Read-WidgetZipEntryText -Path $zipPath -EntryName 'ai-usage-widget-9.9.9/AiUsageWidget.ps1'
    Assert-Eq (Test-WidgetPackageVersionText -Text $text -Version '9.9.9') 'True' 'the entry script inside the archive carries its version'
    Assert-Eq (Read-WidgetZipEntryText -Path $zipPath -EntryName 'ai-usage-widget-9.9.9/missing.ps1') '' 'a missing entry reads as empty'
    Assert-Eq (@(Read-WidgetZipEntryNames -Path (Join-Path $dir 'no-such.zip')).Count) 0 'a missing archive has no entries'
} finally {
    Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
}

if ($failed -gt 0) {
    Write-Host ("FAILED {0}" -f $failed)
    exit 1
}
Write-Host 'ALL PASSED'
exit 0
