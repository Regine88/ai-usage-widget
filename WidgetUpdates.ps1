# Encoding: UTF-8 with BOM.
# WidgetUpdates.ps1 - 版本比较与 GitHub Release 解析（纯函数）。
#
# 设计：
#  - 网络请求由调用方负责，本模块只解析已经拿到的 JSON 对象，因此可以完全离线测试。
#  - tag 前缀（v）与预发布后缀（-beta.1）都容忍；无法解析时返回 $null / $false，
#    宁可漏报更新也不误报。
#  - 失败原因用固定短码（no-release / draft / prerelease / invalid / unknown-current /
#    not-newer / newer）返回，界面层再翻译成文案。

$script:WidgetUpdateNotesLimit = 220

# 'v0.9.0' / '0.9' / 'v1.2.3-beta.1' -> [version]；无法解析时返回 $null。
function ConvertTo-WidgetVersion {
    param([string]$Tag)
    if (-not $Tag) { return $null }
    $text = ([string]$Tag).Trim()
    if ($text -match '^[vV](?=[0-9])') { $text = $text.Substring(1) }
    $match = [regex]::Match($text, '^([0-9]{1,6})\.([0-9]{1,6})(?:\.([0-9]{1,6}))?')
    if (-not $match.Success) { return $null }
    $build = if ($match.Groups[3].Success) { [int]$match.Groups[3].Value } else { 0 }
    return (New-Object System.Version ([int]$match.Groups[1].Value), ([int]$match.Groups[2].Value), $build)
}

# 候选版本是否比当前版本新；任一侧无法解析都返回 $false。
function Test-WidgetVersionNewer {
    param([string]$Current, [string]$Candidate)
    $currentVersion = ConvertTo-WidgetVersion $Current
    $candidateVersion = ConvertTo-WidgetVersion $Candidate
    if ($null -eq $currentVersion -or $null -eq $candidateVersion) { return $false }
    return ($candidateVersion -gt $currentVersion)
}

# Release 说明压成单行短文本，供关于窗口显示。
function Get-WidgetReleaseNotes {
    param($Body, [int]$MaxLength = $script:WidgetUpdateNotesLimit)
    if (-not $Body) { return '' }
    $text = ([string]$Body) -replace '\r\n|\n|\r|\t', ' '
    $text = ($text -replace '\s{2,}', ' ').Trim()
    if ($MaxLength -gt 0 -and $text.Length -gt $MaxLength) {
        $text = $text.Substring(0, $MaxLength).TrimEnd() + '...'
    }
    return $text
}

# 把 GitHub /releases/latest 的 JSON 解析成界面要用的字段。
# 返回哈希表：HasUpdate / CurrentVersion / LatestTag / LatestVersion / Name /
# Url / PublishedAt / Notes / Reason。
function Get-WidgetUpdateInfo {
    param($Release, [string]$CurrentVersion)
    $current = ConvertTo-WidgetVersion $CurrentVersion
    $info = @{
        HasUpdate      = $false
        CurrentVersion = $(if ($current) { $current.ToString() } else { '' })
        LatestTag      = ''
        LatestVersion  = ''
        Name           = ''
        Url            = ''
        PublishedAt    = ''
        Notes          = ''
        Reason         = ''
    }
    if ($null -eq $Release) { $info.Reason = 'no-release'; return $info }
    if ($Release.draft) { $info.Reason = 'draft'; return $info }
    if ($Release.prerelease) { $info.Reason = 'prerelease'; return $info }
    $latest = ConvertTo-WidgetVersion ([string]$Release.tag_name)
    if (-not $latest) { $info.Reason = 'invalid'; return $info }
    $info.LatestTag = [string]$Release.tag_name
    $info.LatestVersion = $latest.ToString()
    $info.Name = [string]$Release.name
    $info.Url = [string]$Release.html_url
    $info.PublishedAt = [string]$Release.published_at
    $info.Notes = Get-WidgetReleaseNotes $Release.body
    if (-not $current) { $info.Reason = 'unknown-current'; return $info }
    if ($latest -gt $current) {
        $info.HasUpdate = $true
        $info.Reason = 'newer'
    } else {
        $info.Reason = 'not-newer'
    }
    return $info
}