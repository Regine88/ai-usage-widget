# Encoding: UTF-8 with BOM. Run: powershell -NoProfile -File .\test-WidgetConfig.ps1
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $here 'UsageValidation.ps1')
. (Join-Path $here 'WidgetPalette.ps1')
. (Join-Path $here 'WidgetConfig.ps1')

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

# ---------- 默认值 ----------
$defaults = Get-WidgetConfigDefaults
Assert-Eq $defaults.intervalSeconds 300 'default interval'
Assert-Eq $defaults.language 'auto' 'default language'
Assert-Eq $defaults.theme 'dark' 'default theme'
Assert-Eq $defaults.opacity 0.96 'default opacity'
Assert-Eq $defaults.showTrend 'True' 'default show trend'
Assert-Eq $defaults.trendDays 7 'default trend days'
Assert-Eq ($defaults.alertThresholds -join ',') '70,90' 'default thresholds'
Assert-Eq $defaults.quietHours.enabled 'False' 'default quiet off'
Assert-Eq $defaults.quietHours.start '22:00' 'default quiet start'
Assert-Eq $defaults.quietHours.end '07:00' 'default quiet end'
Assert-Eq $defaults.providers.grok 'True' 'default grok enabled'
Assert-Eq $defaults.providers.gemini 'True' 'default gemini enabled'
Assert-Eq $defaults.providers.kimi 'True' 'default kimi enabled'
Assert-Eq $defaults.providers.codex 'True' 'default codex enabled'
Assert-Eq $defaults.providers.commandcode 'True' 'default commandcode enabled'
Assert-Eq $defaults.providers.openrouter 'True' 'default openrouter enabled'
Assert-Eq $defaults.providers.deepseek 'True' 'default deepseek enabled'
Assert-Eq $defaults.providers.claude 'True' 'default claude enabled'
Assert-Eq $defaults.providers.cursor 'True' 'default cursor enabled'
Assert-Eq $defaults.providers.glm 'True' 'default glm enabled'
Assert-Eq $defaults.lockPosition 'False' 'default position unlocked'
Assert-Eq $defaults.layout 'full' 'default layout is full'
Assert-Eq ($defaults.providerAlertThresholds.Count) 0 'default has no per-provider thresholds'

# ---------- 数值校验 ----------
Assert-Eq (ConvertTo-ConfigInt -Value 600 -Default 300 -Min 15 -Max 86400) 600 'int passthrough'
Assert-Eq (ConvertTo-ConfigInt -Value 5 -Default 300 -Min 15 -Max 86400) 15 'int clamps low'
Assert-Eq (ConvertTo-ConfigInt -Value 999999 -Default 300 -Min 15 -Max 86400) 86400 'int clamps high'
Assert-Eq (ConvertTo-ConfigInt -Value 'abc' -Default 300 -Min 15 -Max 86400) 300 'int falls back on text'
Assert-Eq (ConvertTo-ConfigInt -Value $null -Default 300 -Min 15 -Max 86400) 300 'int falls back on null'
Assert-Eq (ConvertTo-ConfigInt -Value '42' -Default 300 -Min 15 -Max 86400) 42 'int parses numeric string'
Assert-Eq (ConvertTo-ConfigInt -Value ([double]::NaN) -Default 300 -Min 15 -Max 86400) 300 'int rejects NaN'
Assert-Eq (ConvertTo-ConfigInt -Value 300.6 -Default 300 -Min 15 -Max 86400) 301 'int rounds'

Assert-Eq (ConvertTo-ConfigDouble -Value 0.8 -Default 0.96 -Min 0.5 -Max 1.0) 0.8 'double passthrough'
Assert-Eq (ConvertTo-ConfigDouble -Value 0.1 -Default 0.96 -Min 0.5 -Max 1.0) 0.5 'double clamps low'
Assert-Eq (ConvertTo-ConfigDouble -Value 2 -Default 0.96 -Min 0.5 -Max 1.0) 1 'double clamps high'
Assert-Eq (ConvertTo-ConfigDouble -Value 'nope' -Default 0.96 -Min 0.5 -Max 1.0) 0.96 'double falls back'
Assert-Eq (ConvertTo-ConfigDouble -Value ([double]::PositiveInfinity) -Default 0.96 -Min 0.5 -Max 1.0) 0.96 'double rejects infinity'

# ---------- 布尔 ----------
Assert-Eq (ConvertTo-ConfigBool $true $false) 'True' 'bool true'
Assert-Eq (ConvertTo-ConfigBool $false $true) 'False' 'bool false'
Assert-Eq (ConvertTo-ConfigBool 'yes' $false) 'True' 'bool yes'
Assert-Eq (ConvertTo-ConfigBool 'OFF' $true) 'False' 'bool off case-insensitive'
Assert-Eq (ConvertTo-ConfigBool '1' $false) 'True' 'bool one'
Assert-Eq (ConvertTo-ConfigBool '0' $true) 'False' 'bool zero'
Assert-Eq (ConvertTo-ConfigBool 'maybe' $true) 'True' 'bool unknown keeps default'
Assert-Eq (ConvertTo-ConfigBool $null $false) 'False' 'bool null keeps default'

# ---------- 时钟与语言 ----------
Assert-Eq (ConvertTo-ConfigClock '7:5' '00:00') '07:05' 'clock normalizes single digit'
Assert-Eq (ConvertTo-ConfigClock '07:05' '22:00') '07:05' 'clock passthrough'
Assert-Eq (ConvertTo-ConfigClock '23:59' '22:00') '23:59' 'clock late edge'
Assert-Eq (ConvertTo-ConfigClock '24:00' '22:00') '22:00' 'clock rejects hour 24'
Assert-Eq (ConvertTo-ConfigClock '12:60' '22:00') '22:00' 'clock rejects minute 60'
Assert-Eq (ConvertTo-ConfigClock '' '22:00') '22:00' 'clock empty falls back'
Assert-Eq (ConvertTo-ConfigClock 'noon' '22:00') '22:00' 'clock text falls back'

Assert-Eq (ConvertTo-ConfigLanguage 'en-US' 'auto') 'en-US' 'language en'
Assert-Eq (ConvertTo-ConfigLanguage 'zh-CN' 'auto') 'zh-CN' 'language zh'
Assert-Eq (ConvertTo-ConfigLanguage 'auto' 'zh-CN') 'auto' 'language auto'
Assert-Eq (ConvertTo-ConfigLanguage 'fr-FR' 'auto') 'auto' 'language unknown falls back'
Assert-Eq (ConvertTo-ConfigLanguage $null 'auto') 'auto' 'language null falls back'
# ---------- 主题 ----------
Assert-Eq (ConvertTo-ConfigTheme 'light') 'light' 'theme light'
Assert-Eq (ConvertTo-ConfigTheme 'DARK') 'dark' 'theme is case insensitive'
Assert-Eq (ConvertTo-ConfigTheme 'neon') 'dark' 'unknown theme falls back'
Assert-Eq (ConvertTo-ConfigTheme $null) 'dark' 'null theme falls back'
Assert-Eq (ConvertTo-ConfigTheme '' 'light') 'light' 'empty theme keeps the given default'
Assert-Eq (Convert-WidgetConfig ([pscustomobject]@{ theme = 'light' })).theme 'light' 'theme is read from the config'
Assert-Eq (Convert-WidgetConfig ([pscustomobject]@{ theme = 7 })).theme 'dark' 'broken theme falls back'

# ---------- 阈值列表 ----------
Assert-Eq ((ConvertTo-ConfigThresholds @(90, 70, 70) @(70, 90)) -join ',') '70,90' 'thresholds sort and dedupe'
Assert-Eq ((ConvertTo-ConfigThresholds @(50, '95') @(70, 90)) -join ',') '50,95' 'thresholds accept numeric strings'
Assert-Eq ((ConvertTo-ConfigThresholds @(0, 101, -5) @(70, 90)) -join ',') '70,90' 'thresholds reject out of range'
Assert-Eq ((ConvertTo-ConfigThresholds @('x', $null) @(70, 90)) -join ',') '70,90' 'thresholds reject junk'
Assert-Eq ((ConvertTo-ConfigThresholds @() @(70, 90)) -join ',') '70,90' 'thresholds empty keeps default'
Assert-Eq ((ConvertTo-ConfigThresholds $null @(80)) -join ',') '80' 'thresholds null keeps default'

# ---------- 完整配置合并且永不抛错 ----------
$full = Convert-WidgetConfig $null
Assert-Eq $full.intervalSeconds 300 'null config gives defaults'
Assert-Eq $full.opacity 0.96 'null config keeps opacity default'

$partial = Convert-WidgetConfig ([pscustomobject]@{
    intervalSeconds = 900
    language        = 'en-US'
    opacity         = 0.75
    providers       = @{ grok = $false }
})
Assert-Eq $partial.intervalSeconds 900 'partial keeps interval'
Assert-Eq $partial.language 'en-US' 'partial keeps language'
Assert-Eq $partial.opacity 0.75 'partial keeps opacity'
Assert-Eq $partial.providers.grok 'False' 'partial disables grok'
Assert-Eq $partial.providers.kimi 'True' 'partial keeps other providers'
Assert-Eq $partial.trendDays 7 'partial keeps trend default'
Assert-Eq $partial.quietHours.start '22:00' 'partial keeps quiet default'

$broken = Convert-WidgetConfig ([pscustomobject]@{
    intervalSeconds = 'soon'
    opacity         = 'glass'
    alertThresholds = 'ninety'
    quietHours      = 'later'
    providers       = 42
})
Assert-Eq $broken.intervalSeconds 300 'broken interval falls back'
Assert-Eq $broken.opacity 0.96 'broken opacity falls back'
Assert-Eq ($broken.alertThresholds -join ',') '70,90' 'broken thresholds fall back'
Assert-Eq $broken.quietHours.start '22:00' 'broken quiet block falls back'
Assert-Eq $broken.providers.grok 'True' 'broken providers fall back'

$clamped = Convert-WidgetConfig ([pscustomobject]@{
    intervalSeconds = 1
    trendDays       = 99
    opacity         = 5
    alertThresholds = @(100, 100, 1)
    quietHours      = @{ enabled = 'on'; start = '23:30'; end = '06:15' }
})
Assert-Eq $clamped.intervalSeconds 15 'clamped interval'
Assert-Eq $clamped.trendDays 14 'clamped trend days'
Assert-Eq $clamped.opacity 1 'clamped opacity'
Assert-Eq ($clamped.alertThresholds -join ',') '1,100' 'clamped thresholds dedupe'
Assert-Eq $clamped.quietHours.enabled 'True' 'quiet enabled parsed'
Assert-Eq $clamped.quietHours.end '06:15' 'quiet end normalized'

Assert-Eq (Convert-WidgetConfig 'totally not a config').intervalSeconds 300 'string config falls back to defaults'
Assert-Eq (Convert-WidgetConfig 12345).intervalSeconds 300 'number config falls back to defaults'

Assert-Eq (ConvertTo-ConfigLayout 'COMPACT') 'compact' 'layout compact is case insensitive'
Assert-Eq (ConvertTo-ConfigLayout 'grid') 'full' 'unknown layout falls back'
Assert-Eq (Convert-WidgetConfig ([pscustomobject]@{ layout = 'compact'; lockPosition = $true })).layout 'compact' 'layout is read from the config'
Assert-Eq (Convert-WidgetConfig ([pscustomobject]@{ layout = 'compact'; lockPosition = $true })).lockPosition 'True' 'lock flag is read from the config'
Assert-Eq (Convert-WidgetConfig ([pscustomobject]@{ layout = 'wide' })).layout 'full' 'broken layout falls back'

$over = Convert-WidgetConfig ([pscustomobject]@{
    alertThresholds = @(70, 90)
    providerAlertThresholds = @{ grok = @(80, 95); kimi = @(0, 101, 60) }
})
Assert-Eq ((Resolve-AlertThresholds $over 'grok') -join ',') '80,95' 'provider overlay wins'
Assert-Eq ((Resolve-AlertThresholds $over 'kimi') -join ',') '60' 'provider overlay drops out of range'
Assert-Eq ((Resolve-AlertThresholds $over 'codex') -join ',') '70,90' 'missing overlay keeps global'
Assert-Eq (Test-UsageResetTransition 90 8) 'True' 'drop from high to low is a reset'
Assert-Eq (Test-UsageResetTransition 12 8) 'False' 'already-low is not a reset'
Assert-Eq (Test-UsageResetTransition 90 40) 'False' 'modest drop is not a reset'
Assert-Eq (Test-UsageResetTransition $null 8) 'False' 'missing previous is not a reset'

Assert-Eq (Resolve-RefreshInterval -Explicit $true -ExplicitValue 15 -Config @{ intervalSeconds = 300 } -State @{ interval = 900 } -ConfigFileExists $true) 15 'explicit interval wins'
Assert-Eq (Resolve-RefreshInterval -Explicit $false -ExplicitValue 15 -Config @{ intervalSeconds = 120 } -State @{ interval = 900 } -ConfigFileExists $true) 120 'config file wins over state'
Assert-Eq (Resolve-RefreshInterval -Explicit $false -ExplicitValue 15 -Config @{ intervalSeconds = 300 } -State @{ interval = 900 } -ConfigFileExists $false) 900 'state migrates when config file is missing'

# ---------- 供应商开关 ----------
$config = Convert-WidgetConfig ([pscustomobject]@{ providers = @{ grok = $false; codex = $false } })
Assert-Eq (Test-ProviderEnabled $config 'grok') 'False' 'provider grok disabled'
Assert-Eq (Test-ProviderEnabled $config 'codex') 'False' 'provider codex disabled'
Assert-Eq (Test-ProviderEnabled $config 'kimi') 'True' 'provider kimi enabled'
Assert-Eq (Test-ProviderEnabled $config 'unknown') 'True' 'unknown provider stays enabled'
Assert-Eq (Test-ProviderEnabled $null 'grok') 'True' 'missing config enables everything'
Assert-Eq (Test-ProviderEnabled $config '') 'True' 'empty kind stays enabled'

# ---------- 静音时段 ----------
$quietOff = Convert-WidgetConfig ([pscustomobject]@{ quietHours = @{ enabled = $false; start = '22:00'; end = '07:00' } })
Assert-Eq (Test-QuietHours $quietOff ([datetime]'2026-09-17T23:00:00')) 'False' 'quiet disabled'

$quietOvernight = Convert-WidgetConfig ([pscustomobject]@{ quietHours = @{ enabled = $true; start = '22:00'; end = '07:00' } })
Assert-Eq (Test-QuietHours $quietOvernight ([datetime]'2026-09-17T23:30:00')) 'True' 'quiet inside overnight window'
Assert-Eq (Test-QuietHours $quietOvernight ([datetime]'2026-09-17T03:00:00')) 'True' 'quiet after midnight'
Assert-Eq (Test-QuietHours $quietOvernight ([datetime]'2026-09-17T07:00:00')) 'False' 'quiet ends at end time'
Assert-Eq (Test-QuietHours $quietOvernight ([datetime]'2026-09-17T22:00:00')) 'True' 'quiet starts at start time'
Assert-Eq (Test-QuietHours $quietOvernight ([datetime]'2026-09-17T12:00:00')) 'False' 'quiet outside window'

$quietDay = Convert-WidgetConfig ([pscustomobject]@{ quietHours = @{ enabled = $true; start = '09:00'; end = '17:00' } })
Assert-Eq (Test-QuietHours $quietDay ([datetime]'2026-09-17T10:00:00')) 'True' 'quiet same-day window'
Assert-Eq (Test-QuietHours $quietDay ([datetime]'2026-09-17T18:00:00')) 'False' 'quiet same-day outside'
Assert-Eq (Test-QuietHours $quietDay ([datetime]'2026-09-17T08:59:00')) 'False' 'quiet just before start'

$quietSame = Convert-WidgetConfig ([pscustomobject]@{ quietHours = @{ enabled = $true; start = '08:00'; end = '08:00' } })
Assert-Eq (Test-QuietHours $quietSame ([datetime]'2026-09-17T08:00:00')) 'False' 'identical start and end never mutes'
Assert-Eq (Test-QuietHours $null ([datetime]'2026-09-17T08:00:00')) 'False' 'missing config never mutes'

Assert-Eq (ConvertTo-ConfigMinutes '00:00') 0 'minutes midnight'
Assert-Eq (ConvertTo-ConfigMinutes '07:30') 450 'minutes morning'
Assert-Eq (ConvertTo-ConfigMinutes '23:59') 1439 'minutes last minute'
Assert-Eq (ConvertTo-ConfigMinutes '7:5') 425 'minutes tolerates single digits'
Assert-Eq (ConvertTo-ConfigMinutes 'oops') '' 'minutes invalid'

# ---------- 文件读写 ----------
$dir = Join-Path $env:TEMP ('widget-config-test-' + [guid]::NewGuid())
New-Item -ItemType Directory -Path $dir | Out-Null
try {
    $script:WidgetDir = $dir
    Assert-Eq (Get-WidgetConfigPath) (Join-Path $dir 'ai-config.json') 'path follows widget dir'
    Assert-Eq (Get-WidgetConfigPath 'C:\custom') 'C:\custom\ai-config.json' 'path honors explicit dir'

    $configPath = Join-Path $dir 'ai-config.json'
    Assert-Eq (Read-WidgetConfig $configPath).intervalSeconds 300 'missing file reads defaults'
    Assert-Eq (Get-WidgetConfigFileStamp $configPath) '' 'missing file has no stamp'

    $written = Convert-WidgetConfig ([pscustomobject]@{
        intervalSeconds = 120
        language        = 'en-US'
        theme           = 'light'
        showTrend       = $false
        trendDays       = 3
        alertThresholds = @(60, 85)
        quietHours      = @{ enabled = $true; start = '23:00'; end = '06:30' }
        providers       = @{ gemini = $false }
    })
    Assert-Eq (Write-WidgetConfig $configPath $written) 'True' 'write returns true'
    Assert-Eq (Test-Path -LiteralPath $configPath) 'True' 'config file written'
    Assert-Eq (Test-Path -LiteralPath "$configPath.tmp") 'False' 'no temp file left behind'

    $loaded = Read-WidgetConfig $configPath
    Assert-Eq $loaded.intervalSeconds 120 'round trip interval'
    Assert-Eq $loaded.language 'en-US' 'round trip language'
Assert-Eq $loaded.theme 'light' 'round trip theme'
    Assert-Eq $loaded.showTrend 'False' 'round trip show trend'
    Assert-Eq $loaded.trendDays 3 'round trip trend days'
    Assert-Eq ($loaded.alertThresholds -join ',') '60,85' 'round trip thresholds'
    Assert-Eq $loaded.quietHours.enabled 'True' 'round trip quiet enabled'
    Assert-Eq $loaded.quietHours.end '06:30' 'round trip quiet end'
    Assert-Eq $loaded.providers.gemini 'False' 'round trip provider off'
    Assert-Eq $loaded.providers.grok 'True' 'round trip provider on'
    Assert-Eq ((Get-WidgetConfigFileStamp $configPath) -gt 0) 'True' 'stamp after write'

    $rawBytes = [IO.File]::ReadAllBytes($configPath)
    Assert-Eq ($rawBytes[0] -eq 0xEF -and $rawBytes[1] -eq 0xBB -and $rawBytes[2] -eq 0xBF) 'False' 'config written without BOM'

    Set-Content -LiteralPath $configPath -Value '{ "intervalSeconds": 900, "opacity": 0.8 }' -Encoding utf8
    Assert-Eq (Read-WidgetConfig $configPath).intervalSeconds 900 'hand-written json is honored'
    Assert-Eq (Read-WidgetConfig $configPath).opacity 0.8 'hand-written partial json keeps defaults'

    Set-Content -LiteralPath $configPath -Value '{ this is not json }' -Encoding utf8
    Assert-Eq (Read-WidgetConfig $configPath).intervalSeconds 300 'corrupt json falls back to defaults'

    Assert-Eq (Read-WidgetConfig (Join-Path $dir 'missing.json')).intervalSeconds 300 'missing explicit path reads defaults'

    $auto = Write-WidgetConfig -Config $written
    Assert-Eq $auto 'True' 'write without path uses widget dir'
    Assert-Eq (Test-Path -LiteralPath (Join-Path $dir 'ai-config.json')) 'True' 'auto path file exists'
} finally {
    $script:WidgetDir = $null
    Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
}

if ($failed -gt 0) {
    Write-Host ("FAILED {0}" -f $failed)
    exit 1
}
Write-Host 'ALL PASSED'
exit 0