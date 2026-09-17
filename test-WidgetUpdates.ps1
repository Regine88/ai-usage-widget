# Encoding: UTF-8 with BOM. Run: powershell -NoProfile -File .\test-WidgetUpdates.ps1
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $here 'WidgetUpdates.ps1')

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

# ---------- 版本解析 ----------
Assert-Eq (ConvertTo-WidgetVersion 'v0.8.0') '0.8.0' 'v prefix is dropped'
Assert-Eq (ConvertTo-WidgetVersion '0.8.0') '0.8.0' 'bare version parses'
Assert-Eq (ConvertTo-WidgetVersion 'V1.2.3') '1.2.3' 'capital V parses'
Assert-Eq (ConvertTo-WidgetVersion ' v0.9.0 ') '0.9.0' 'surrounding spaces are ignored'
Assert-Eq (ConvertTo-WidgetVersion 'v0.9') '0.9.0' 'two-part version pads the build'
Assert-Eq (ConvertTo-WidgetVersion 'v1.2.3-beta.1') '1.2.3' 'prerelease suffix is ignored'
Assert-Eq (ConvertTo-WidgetVersion 'v1.2.3.4') '1.2.3' 'extra segments are ignored'
Assert-Eq (ConvertTo-WidgetVersion 'v0.10.0') '0.10.0' 'two digit minor parses'
Assert-Eq (ConvertTo-WidgetVersion '') '' 'empty tag gives null'
Assert-Eq (ConvertTo-WidgetVersion $null) '' 'null tag gives null'
Assert-Eq (ConvertTo-WidgetVersion 'v') '' 'lone v gives null'
Assert-Eq (ConvertTo-WidgetVersion 'v1') '' 'single number gives null'
Assert-Eq (ConvertTo-WidgetVersion 'latest') '' 'non numeric tag gives null'

# ---------- 版本比较 ----------
Assert-Eq (Test-WidgetVersionNewer '0.8.0' '0.9.0') 'True' 'newer patch line wins'
Assert-Eq (Test-WidgetVersionNewer '0.8.0' 'v0.9.0') 'True' 'tag prefix does not matter'
Assert-Eq (Test-WidgetVersionNewer '0.9.0' '0.9.0') 'False' 'same version is not newer'
Assert-Eq (Test-WidgetVersionNewer '0.9.1' '0.9.0') 'False' 'older candidate is not newer'
Assert-Eq (Test-WidgetVersionNewer '0.9.0' '0.10.0') 'True' '10 is newer than 9'
Assert-Eq (Test-WidgetVersionNewer '0.10.0' '0.9.0') 'False' '9 is not newer than 10'
Assert-Eq (Test-WidgetVersionNewer '1.0.0' '1.0.1') 'True' 'build segment compares'
Assert-Eq (Test-WidgetVersionNewer '' '0.9.0') 'False' 'unknown current is never newer'
Assert-Eq (Test-WidgetVersionNewer '0.8.0' '') 'False' 'unknown candidate is never newer'
Assert-Eq (Test-WidgetVersionNewer $null $null) 'False' 'null pair is never newer'

# ---------- 说明文本 ----------
Assert-Eq (Get-WidgetReleaseNotes "line1`r`n`r`nline2") 'line1 line2' 'line breaks collapse'
Assert-Eq (Get-WidgetReleaseNotes "a`tb") 'a b' 'tabs collapse'
Assert-Eq (Get-WidgetReleaseNotes '  padded  ') 'padded' 'text is trimmed'
Assert-Eq (Get-WidgetReleaseNotes '') '' 'empty body gives empty notes'
Assert-Eq (Get-WidgetReleaseNotes $null) '' 'null body gives empty notes'
$long = 'x' * 300
$cut = Get-WidgetReleaseNotes $long
Assert-Eq $cut.Length 223 'long notes are truncated with an ellipsis'
Assert-Eq $cut.EndsWith('...') 'True' 'truncated notes end with an ellipsis'
Assert-Eq (Get-WidgetReleaseNotes 'abc' 0) 'abc' 'zero limit disables truncation'
Assert-Eq (Get-WidgetReleaseNotes 'x').Length 1 'short notes stay untouched'

# ---------- Release 解析 ----------
$current = '0.8.0'
$release = [pscustomobject]@{
    tag_name     = 'v0.9.0'
    name         = 'AI Usage Widget 0.9.0'
    draft        = $false
    prerelease   = $false
    html_url     = 'https://github.com/Regine88/ai-usage-widget/releases/tag/v0.9.0'
    published_at = '2026-09-17T10:00:00Z'
    body         = "Added`r`n`r`n- Update check"
}
$info = Get-WidgetUpdateInfo -Release $release -CurrentVersion $current
Assert-Eq $info.HasUpdate 'True' 'release newer than current reports an update'
Assert-Eq $info.LatestVersion '0.9.0' 'latest version is normalized'
Assert-Eq $info.LatestTag 'v0.9.0' 'latest tag is kept verbatim'
Assert-Eq $info.CurrentVersion '0.8.0' 'current version is normalized'
Assert-Eq $info.Reason 'newer' 'reason is newer'
Assert-Eq $info.Url 'https://github.com/Regine88/ai-usage-widget/releases/tag/v0.9.0' 'url is carried over'
Assert-Eq $info.Notes 'Added - Update check' 'notes are flattened'
Assert-Eq $info.PublishedAt '2026-09-17T10:00:00Z' 'published time is carried over'

$same = Get-WidgetUpdateInfo -Release $release -CurrentVersion '0.9.0'
Assert-Eq $same.HasUpdate 'False' 'same version reports no update'
Assert-Eq $same.Reason 'not-newer' 'same version reason is not-newer'

$older = Get-WidgetUpdateInfo -Release $release -CurrentVersion '0.10.0'
Assert-Eq $older.Reason 'not-newer' 'newer current reports no update'

$draft = Get-WidgetUpdateInfo -Release ([pscustomobject]@{ tag_name = 'v0.9.0'; draft = $true }) -CurrentVersion $current
Assert-Eq $draft.HasUpdate 'False' 'drafts are ignored'
Assert-Eq $draft.Reason 'draft' 'draft reason is reported'

$pre = Get-WidgetUpdateInfo -Release ([pscustomobject]@{ tag_name = 'v0.9.0'; prerelease = $true }) -CurrentVersion $current
Assert-Eq $pre.HasUpdate 'False' 'prereleases are ignored'
Assert-Eq $pre.Reason 'prerelease' 'prerelease reason is reported'

$invalid = Get-WidgetUpdateInfo -Release ([pscustomobject]@{ tag_name = 'nightly' }) -CurrentVersion $current
Assert-Eq $invalid.HasUpdate 'False' 'invalid tags are ignored'
Assert-Eq $invalid.Reason 'invalid' 'invalid reason is reported'

$missing = Get-WidgetUpdateInfo -Release $null -CurrentVersion $current
Assert-Eq $missing.HasUpdate 'False' 'missing release reports no update'
Assert-Eq $missing.Reason 'no-release' 'missing release reason is reported'

$unknown = Get-WidgetUpdateInfo -Release $release -CurrentVersion ''
Assert-Eq $unknown.HasUpdate 'False' 'unknown current version reports no update'
Assert-Eq $unknown.Reason 'unknown-current' 'unknown current reason is reported'
Assert-Eq $unknown.LatestVersion '0.9.0' 'unknown current still exposes the latest version'

$sparse = Get-WidgetUpdateInfo -Release ([pscustomobject]@{ tag_name = 'v1.0.0' }) -CurrentVersion '0.8.0'
Assert-Eq $sparse.HasUpdate 'True' 'sparse release still reports an update'
Assert-Eq $sparse.Url '' 'missing url becomes an empty string'
Assert-Eq $sparse.Notes '' 'missing body becomes empty notes'

# ---------- 源码回归：模块不依赖界面 ----------
$moduleText = Get-Content -LiteralPath (Join-Path $here 'WidgetUpdates.ps1') -Raw -Encoding utf8
Assert-Eq ($moduleText -match "(?m)^\s*T\s") 'False' 'module never calls the UI text helper'
if ($failed -gt 0) {
    Write-Host ("FAILED {0}" -f $failed)
    exit 1
}
Write-Host 'ALL PASSED'
exit 0