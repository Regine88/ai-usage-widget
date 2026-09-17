# Encoding: UTF-8 with BOM. Run: powershell -NoProfile -File .\test-WidgetStrings.ps1
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $here 'WidgetStrings.ps1')

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

# ---------- 语言解析 ----------
Assert-Eq (ConvertTo-WidgetLanguage 'auto' 'zh-CN') 'zh-CN' 'auto follows a Chinese system'
Assert-Eq (ConvertTo-WidgetLanguage 'auto' 'en-US') 'en-US' 'auto follows an English system'
Assert-Eq (ConvertTo-WidgetLanguage 'auto' 'zh-TW') 'zh-CN' 'auto treats zh-TW as Chinese'
Assert-Eq (ConvertTo-WidgetLanguage 'auto' 'de-DE') 'en-US' 'auto falls back to English'
Assert-Eq (ConvertTo-WidgetLanguage '' 'zh-CN') 'zh-CN' 'empty language follows the system'
Assert-Eq (ConvertTo-WidgetLanguage 'zh-CN' 'de-DE') 'zh-CN' 'explicit zh-CN wins'
Assert-Eq (ConvertTo-WidgetLanguage 'en-US' 'zh-CN') 'en-US' 'explicit en-US wins'
Assert-Eq (ConvertTo-WidgetLanguage 'zh' 'en-US') 'zh-CN' 'zh prefix maps to zh-CN'
Assert-Eq (ConvertTo-WidgetLanguage 'en' 'zh-CN') 'en-US' 'en prefix maps to en-US'
Assert-Eq (ConvertTo-WidgetLanguage 'fr' 'zh-CN') 'zh-CN' 'unknown language follows the system'
Assert-Eq (ConvertTo-WidgetLanguage $null 'en-US') 'en-US' 'null language follows the system'

# ---------- 表转换 ----------
$table = ConvertTo-WidgetStringTable ([pscustomobject]@{ '_skip' = 'x'; 'a' = 1; 'b' = $null; 'c' = 'text' })
Assert-Eq $table.ContainsKey('_skip') 'False' 'underscore keys are skipped'
Assert-Eq $table.ContainsKey('b') 'False' 'null values are skipped'
Assert-Eq $table['a'] '1' 'numbers become strings'
Assert-Eq $table['c'] 'text' 'strings stay strings'
Assert-Eq (ConvertTo-WidgetStringTable $null).Count 0 'null input gives an empty table'

# ---------- 文本查询 ----------
Assert-Eq (Get-WidgetText -Key 'k' -Table @{ k = 'value' }) 'value' 'plain lookup'
Assert-Eq (Get-WidgetText -Key 'k' -Table @{ k = 'x {0}' } -Arguments 'y') 'x y' 'single placeholder'
Assert-Eq (Get-WidgetText -Key 'k' -Table @{ k = '{0}-{1}' } -Arguments @('a', 'b')) 'a-b' 'two placeholders'
Assert-Eq (Get-WidgetText -Key 'missing' -Table @{ k = 'value' }) 'missing' 'missing key falls back to the key'
Assert-Eq (Get-WidgetText -Key 'k' -Table @{ k = '{0} {1}' } -Arguments 'only') '{0} {1}' 'bad format returns the raw text'
$script:WidgetStrings = @{ 'app.title' = 'title' }
Assert-Eq (T 'app.title') 'title' 'T uses the script table'
Assert-Eq (T 'app.other') 'app.other' 'T falls back to the key'
$script:WidgetStrings = $null

# ---------- 语言包 ----------
$zh = Read-WidgetStrings -Language 'zh-CN' -Dir $here
$en = Read-WidgetStrings -Language 'en-US' -Dir $here
Assert-Eq $zh['app.title'] 'AI 周用量' 'zh pack loaded'
Assert-Eq $en['app.title'] 'AI Usage Widget' 'en pack loaded'
Assert-Eq $zh['settings.title'] 'AI 周用量 · 设置' 'zh settings title'
Assert-Eq $en['settings.title'] 'AI Usage Widget - Settings' 'en settings title'
Assert-Eq ($zh['row.windowDays'] -f 7) '7天窗' 'zh window label formats'
Assert-Eq ($en['row.windowDays'] -f 7) '7d window' 'en window label formats'
Assert-Eq ($zh['status.updated'] -f '12:30') '更新于 12:30' 'zh status line formats'
Assert-Eq ($en['status.updated'] -f '12:30') 'Updated at 12:30' 'en status line formats'
Assert-Eq $zh['_comment'] $null 'comment key is not exposed'

$zhKeys = @($zh.Keys | Where-Object { $_ -notlike '_*' } | Sort-Object)
$enKeys = @($en.Keys | Where-Object { $_ -notlike '_*' } | Sort-Object)
Assert-Eq ($zhKeys.Count -gt 60) 'True' 'zh pack has a full key set'
Assert-Eq (($zhKeys -join ',') -eq ($enKeys -join ',')) 'True' 'both packs expose the same keys'
$empty = @($zhKeys | Where-Object { -not $zh[$_] } ) + @($enKeys | Where-Object { -not $en[$_] })
Assert-Eq $empty.Count 0 'no empty translations'
$untranslated = @()
foreach ($key in @('menu.refresh', 'menu.settings', 'settings.save', 'error.timeout', 'tip.openUsage', 'alert.title')) {
    if ($zh[$key] -eq $en[$key]) { $untranslated += $key }
}
Assert-Eq $untranslated.Count 0 'key phrases are actually translated'

# 关键键必须存在，避免漏改代码时才发现
foreach ($key in @('app.title', 'menu.exportCsv', 'status.noCredentials', 'reset.unknown', 'forecast.never',
                   'csv.exported', 'settings.restartHint', 'cli.migrateDone')) {
    Assert-Eq $zh.ContainsKey($key) 'True' ('zh pack has ' + $key)
}

# ---------- 回退 ----------
$fallback = Read-WidgetStrings -Language 'en-US' -Dir (Join-Path $env:TEMP 'no-such-strings-dir')
Assert-Eq $fallback['app.title'] 'AI Usage Widget' 'missing dir falls back to the built-in table'
Assert-Eq (Get-WidgetText -Key 'status.noCredentials' -Table $fallback) 'No credentials found' 'fallback is usable'

$badDir = Join-Path $env:TEMP ('widget-strings-test-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path (Join-Path $badDir 'strings') -Force | Out-Null
try {
    [IO.File]::WriteAllText((Join-Path (Join-Path $badDir 'strings') 'zh-CN.json'), '{ not json', [Text.UTF8Encoding]::new($false))
    $broken = Read-WidgetStrings -Language 'zh-CN' -Dir $badDir
    Assert-Eq $broken['app.title'] 'AI Usage Widget' 'broken json falls back to the built-in table'
} finally {
    Remove-Item -LiteralPath $badDir -Recurse -Force -ErrorAction SilentlyContinue
}

# ---------- 源码引用的键必须都在语言包里 ----------
# 漏加键时界面会直接显示键名（例如 status.refreshing），所以对着源码再扫一遍。
$referenced = New-Object System.Collections.Generic.List[string]
foreach ($file in @(Get-ChildItem -LiteralPath $here -Filter '*.ps1' | Where-Object { $_.Name -ne 'test-WidgetStrings.ps1' })) {
    $text = Get-Content -LiteralPath $file.FullName -Raw -Encoding utf8
    foreach ($match in [regex]::Matches($text, "T\s+'([A-Za-z][A-Za-z0-9_.]*)'")) {
        [void]$referenced.Add($match.Groups[1].Value)
    }
    foreach ($match in [regex]::Matches($text, "Get-WidgetText\s+-Key\s+'([A-Za-z][A-Za-z0-9_.]*)'")) {
        [void]$referenced.Add($match.Groups[1].Value)
    }
}
$unique = @($referenced | Sort-Object -Unique)
Assert-Eq ($unique.Count -gt 60) 'True' 'source scan finds the localized strings'
$missingZh = @($unique | Where-Object { -not $zh.ContainsKey($_) })
$missingEn = @($unique | Where-Object { -not $en.ContainsKey($_) })
Assert-Eq (($missingZh -join ',') + '|' + ($missingEn -join ',')) '|' 'every referenced key exists in both packs'
Assert-Eq (@($zhKeys | Where-Object { $unique -notcontains $_ }) -join ',') '' 'no unused keys in the packs'
Assert-Eq (@($fallback.Keys | Where-Object { -not $zh.ContainsKey($_) }) -join ',') '' 'fallback keys all exist in the packs'

if ($failed -gt 0) {
    Write-Host ("FAILED {0}" -f $failed)
    exit 1
}
Write-Host 'ALL PASSED'
exit 0
