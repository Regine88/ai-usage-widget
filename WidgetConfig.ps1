if (-not (Get-Command ConvertTo-WidgetTheme -ErrorAction SilentlyContinue)) {
    $paletteHelper = Join-Path $PSScriptRoot 'WidgetPalette.ps1'
    if (Test-Path -LiteralPath $paletteHelper) { . $paletteHelper }
}

# Widget configuration: schema, validation and file IO for ai-config.json.
#
# Convert-WidgetConfig is pure (raw object in, validated hashtable out) so the
# whole schema can be tested offline. Every value is clamped or replaced by its
# default instead of throwing, so a hand-edited config can never break startup.

function Get-WidgetConfigDefaults {
    return @{
        intervalSeconds = 300
        language        = 'auto'
        theme           = 'dark'
        opacity         = 0.96
        showTrend       = $true
        showForecast    = $true
        trendDays       = 7
        alertThresholds = @(70, 90)
        quietHours      = @{ enabled = $false; start = '22:00'; end = '07:00' }
        providers       = @{ grok = $true; gemini = $true; kimi = $true; codex = $true; commandcode = $true; openrouter = $true; deepseek = $true }
    }
}

function Get-ConfigPropertyNames {
    param($Source)
    if ($null -eq $Source) { return @() }
    if ($Source -is [System.Collections.IDictionary]) { return @($Source.Keys | ForEach-Object { [string]$_ }) }
    return @($Source.PSObject.Properties | ForEach-Object { $_.Name })
}

function Get-ConfigPropertyValue {
    param($Source, [string]$Name)
    if ($null -eq $Source -or -not $Name) { return $null }
    if ($Source -is [System.Collections.IDictionary]) {
        if ($Source.Contains($Name)) { return $Source[$Name] }
        return $null
    }
    $property = $Source.PSObject.Properties[$Name]
    if (-not $property) { return $null }
    return $property.Value
}

function ConvertTo-ConfigInt {
    param($Value, [int]$Default, [int]$Min, [int]$Max)
    if (-not (Test-FiniteNumber $Value)) { return $Default }
    $number = [int][Math]::Round([double]$Value)
    if ($number -lt $Min) { return $Min }
    if ($number -gt $Max) { return $Max }
    return $number
}

function ConvertTo-ConfigDouble {
    param($Value, [double]$Default, [double]$Min, [double]$Max)
    if (-not (Test-FiniteNumber $Value)) { return $Default }
    $number = [double]$Value
    if ($number -lt $Min) { return $Min }
    if ($number -gt $Max) { return $Max }
    return $number
}

function ConvertTo-ConfigBool {
    param($Value, [bool]$Default)
    if ($null -eq $Value) { return $Default }
    if ($Value -is [bool]) { return [bool]$Value }
    $text = ([string]$Value).Trim().ToLowerInvariant()
    if ($text -in @('true', '1', 'yes', 'on')) { return $true }
    if ($text -in @('false', '0', 'no', 'off')) { return $false }
    return $Default
}

function ConvertTo-ClockParts {
    param($Value)
    if ($null -eq $Value) { return $null }
    $text = ([string]$Value).Trim()
    if ($text -match '^([01]?\d|2[0-3]):([0-5]?\d)$') {
        return @{ Hour = [int]$Matches[1]; Minute = [int]$Matches[2] }
    }
    return $null
}

function ConvertTo-ConfigClock {
    param($Value, [string]$Default)
    $parts = ConvertTo-ClockParts $Value
    if ($parts) { return ('{0:00}:{1:00}' -f $parts.Hour, $parts.Minute) }
    return $Default
}

function ConvertTo-ConfigLanguage {
    param($Value, [string]$Default = 'auto')
    $text = ([string]$Value).Trim()
    if ($text -in @('auto', 'zh-CN', 'en-US')) { return $text }
    return $Default
}

function ConvertTo-ConfigTheme {
    param($Value, [string]$Default = 'dark')
    return (ConvertTo-WidgetTheme $Value $Default)
}

function ConvertTo-ConfigThresholds {
    param($Value, [int[]]$Default)
    $numbers = New-Object System.Collections.Generic.List[int]
    foreach ($item in @($Value)) {
        if (-not (Test-FiniteNumber $item)) { continue }
        $number = [int][Math]::Round([double]$item)
        if ($number -lt 1 -or $number -gt 100) { continue }
        if (-not $numbers.Contains($number)) { [void]$numbers.Add($number) }
    }
    if ($numbers.Count -eq 0) { return @($Default) }
    $sorted = @($numbers | Sort-Object)
    return $sorted
}

function Convert-WidgetConfig {
    param($Raw)
    $defaults = Get-WidgetConfigDefaults
    $config = Get-WidgetConfigDefaults
    if ($null -eq $Raw) { return $config }

    $config.intervalSeconds = ConvertTo-ConfigInt (Get-ConfigPropertyValue $Raw 'intervalSeconds') $defaults.intervalSeconds 15 86400
    $config.language = ConvertTo-ConfigLanguage (Get-ConfigPropertyValue $Raw 'language') $defaults.language
    $config.theme = ConvertTo-ConfigTheme (Get-ConfigPropertyValue $Raw 'theme') $defaults.theme
    $config.opacity = ConvertTo-ConfigDouble (Get-ConfigPropertyValue $Raw 'opacity') $defaults.opacity 0.5 1.0
    $config.showTrend = ConvertTo-ConfigBool (Get-ConfigPropertyValue $Raw 'showTrend') $defaults.showTrend
    $config.showForecast = ConvertTo-ConfigBool (Get-ConfigPropertyValue $Raw 'showForecast') $defaults.showForecast
    $config.trendDays = ConvertTo-ConfigInt (Get-ConfigPropertyValue $Raw 'trendDays') $defaults.trendDays 1 14
    $config.alertThresholds = ConvertTo-ConfigThresholds (Get-ConfigPropertyValue $Raw 'alertThresholds') $defaults.alertThresholds

    $rawQuiet = Get-ConfigPropertyValue $Raw 'quietHours'
    $config.quietHours.enabled = ConvertTo-ConfigBool (Get-ConfigPropertyValue $rawQuiet 'enabled') $defaults.quietHours.enabled
    $config.quietHours.start = ConvertTo-ConfigClock (Get-ConfigPropertyValue $rawQuiet 'start') $defaults.quietHours.start
    $config.quietHours.end = ConvertTo-ConfigClock (Get-ConfigPropertyValue $rawQuiet 'end') $defaults.quietHours.end

    $rawProviders = Get-ConfigPropertyValue $Raw 'providers'
    foreach ($name in @($defaults.providers.Keys)) {
        $value = Get-ConfigPropertyValue $rawProviders $name
        if ($null -ne $value) { $config.providers[$name] = ConvertTo-ConfigBool $value $true }
    }
    return $config
}

function Test-ProviderEnabled {
    param($Config, [string]$Kind)
    if (-not $Kind) { return $true }
    if (-not $Config -or -not $Config.providers) { return $true }
    if (-not $Config.providers.Contains($Kind)) { return $true }
    return [bool]$Config.providers[$Kind]
}

function ConvertTo-ConfigMinutes {
    param([string]$Value)
    $parts = ConvertTo-ClockParts $Value
    if (-not $parts) { return $null }
    return ($parts.Hour * 60 + $parts.Minute)
}

function Test-QuietHours {
    param($Config, [datetime]$Now = (Get-Date))
    if (-not $Config -or -not $Config.quietHours -or -not $Config.quietHours.enabled) { return $false }
    $start = ConvertTo-ConfigMinutes $Config.quietHours.start
    $end = ConvertTo-ConfigMinutes $Config.quietHours.end
    if ($null -eq $start -or $null -eq $end) { return $false }
    # 起止相同视为不静音，避免误配成整天静音
    if ($start -eq $end) { return $false }
    $nowMinutes = $Now.Hour * 60 + $Now.Minute
    if ($start -lt $end) { return ($nowMinutes -ge $start -and $nowMinutes -lt $end) }
    return ($nowMinutes -ge $start -or $nowMinutes -lt $end)
}

function Get-WidgetConfigPath {
    param([string]$Dir)
    $base = if ($Dir) { $Dir } elseif ($script:WidgetDir) { $script:WidgetDir } elseif ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
    return (Join-Path $base 'ai-config.json')
}

function Read-WidgetConfig {
    param([string]$Path)
    $target = if ($Path) { $Path } else { Get-WidgetConfigPath }
    if (-not $target -or -not (Test-Path -LiteralPath $target)) { return (Convert-WidgetConfig $null) }
    try {
        $raw = Get-Content -LiteralPath $target -Raw -Encoding utf8 | ConvertFrom-Json
    } catch {
        if (Get-Command Write-WidgetLog -ErrorAction SilentlyContinue) {
            Write-WidgetLog ('config ignored: {0}' -f (Convert-SafeLogText $_.Exception.Message))
        }
        return (Convert-WidgetConfig $null)
    }
    return (Convert-WidgetConfig $raw)
}

function Write-WidgetConfig {
    param([string]$Path, $Config)
    $target = if ($Path) { $Path } else { Get-WidgetConfigPath }
    if (-not $target) { return $false }
    $json = (Convert-WidgetConfig $Config) | ConvertTo-Json -Depth 6
    $tmp = "$target.tmp"
    [IO.File]::WriteAllText($tmp, ($json.TrimEnd("`r", "`n") + "`n"), [Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath $tmp -Destination $target -Force
    return $true
}

function Get-WidgetConfigFileStamp {
    param([string]$Path)
    $target = if ($Path) { $Path } else { Get-WidgetConfigPath }
    if (-not $target -or -not (Test-Path -LiteralPath $target)) { return $null }
    try { return (Get-Item -LiteralPath $target).LastWriteTimeUtc.Ticks } catch { return $null }
}