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
        historyRetentionDays = 90
        historyMaxBytes = 10485760
        historySampleMinutes = 15
        alertThresholds = @(70, 90)
        quietHours      = @{ enabled = $false; start = '22:00'; end = '07:00' }
        lockPosition    = $false
        layout          = 'full'
        columns         = 1
        dailySummary    = @{ enabled = $false; time = '09:00' }
        accountAliases  = @{}
        hiddenAccounts  = @()
        accountOrder    = @()
        providerAlertThresholds = @{}
        providers       = @{ grok = $true; gemini = $true; kimi = $true; codex = $true; commandcode = $true; openrouter = $true; deepseek = $true; cline = $true; claude = $true; cursor = $true; glm = $true;
                            copilot = $true }
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

function ConvertTo-ConfigLayout {
    param($Value, [string]$Default = 'full')
    $text = ([string]$Value).Trim().ToLowerInvariant()
    if ($text -in @('full', 'compact')) { return $text }
    return $Default
}

function ConvertTo-ProviderAlertThresholds {
    param($Value)
    $result = @{}
    if ($null -eq $Value) { return $result }
    foreach ($name in @(Get-ConfigPropertyNames $Value)) {
        $kind = ([string]$name).Trim().ToLowerInvariant()
        if (-not $kind) { continue }
        $parsed = @(ConvertTo-ConfigThresholds (Get-ConfigPropertyValue $Value $name) @())
        if ($parsed.Count -gt 0) { $result[$kind] = $parsed }
    }
    return $result
}

function ConvertTo-ConfigStringMap {
    param($Value)
    $result = @{}
    if ($null -eq $Value) { return $result }
    foreach ($name in @(Get-ConfigPropertyNames $Value)) {
        $key = ([string]$name).Trim()
        $text = ([string](Get-ConfigPropertyValue $Value $name)).Trim()
        if ($key -and $text) { $result[$key] = $text }
    }
    return $result
}

function ConvertTo-ConfigStringList {
    param($Value)
    $result = New-Object System.Collections.Generic.List[string]
    foreach ($item in @($Value)) {
        $text = ([string]$item).Trim()
        if ($text -and -not $result.Contains($text)) { [void]$result.Add($text) }
    }
    return @($result.ToArray())
}

function Apply-WidgetAccountPreferences {
    param($Rows, $Config)
    $aliases = if ($Config -and $Config.accountAliases) { $Config.accountAliases } else { @{} }
    $hidden = @(if ($Config -and $Config.hiddenAccounts) { $Config.hiddenAccounts } else { @() })
    $order = @(if ($Config -and $Config.accountOrder) { $Config.accountOrder } else { @() })
    $result = @()
    foreach ($row in @($Rows)) {
        if (-not $row) { continue }
        $id = [string]$row.Id
        if ($hidden -contains $id) { continue }
        $alias = $null
        $centralAlias = $false
        if ($aliases.ContainsKey($id)) { $alias = [string]$aliases[$id]; $centralAlias = $true }
        if (-not $alias -and $row.Kind -eq 'grok' -and $row.Auth -and (Get-Command Get-GrokAccountAlias -ErrorAction SilentlyContinue)) {
            $alias = Get-GrokAccountAlias $row.Auth
        }
        $name = $row.Name
        if ($alias) {
            if ($row.Kind -eq 'grok' -and -not $centralAlias) { $name = 'Grok ' + $alias } else { $name = $alias }
        }
        $index = [array]::IndexOf($order, $id)
        if ($index -lt 0) { $index = 1000000 + $result.Count }
        $result += [pscustomobject]@{ Row = $row; Name = $name; Order = $index }
    }
    return @($result | Sort-Object Order, @{ Expression = { $_.Name } } | ForEach-Object {
        $_.Row.Name = $_.Name
        $_.Row
    })
}

# 设置窗口把按供应商阈值编辑成「kind=70,90」的多行文本；解析失败的单行忽略，不影响保存。
function ConvertFrom-ProviderAlertThresholdsText {
    param([string]$Text)
    $result = @{}
    if (-not $Text) { return $result }
    foreach ($line in ($Text -split "`r?`n")) {
        $item = $line.Trim()
        if (-not $item -or $item.StartsWith('#')) { continue }
        $parts = $item.Split('=', 2)
        if ($parts.Count -ne 2) { continue }
        $kind = $parts[0].Trim().ToLowerInvariant()
        if (-not $kind) { continue }
        $parsed = @(ConvertTo-ConfigThresholds ($parts[1] -split '[,;\s]+') @())
        if ($parsed.Count -gt 0) { $result[$kind] = $parsed }
    }
    return $result
}

function Format-ProviderAlertThresholds {
    param($Thresholds)
    if (-not $Thresholds) { return '' }
    $lines = @()
    foreach ($name in @(Get-ConfigPropertyNames $Thresholds | Sort-Object)) {
        $values = @(Get-ConfigPropertyValue $Thresholds $name)
        if ($values.Count -eq 0) { continue }
        $lines += ('{0}={1}' -f $name, ($values -join ','))
    }
    return ($lines -join "`n")
}

# 每日汇总：到点后每天只提示一次；LastDate 存 ai-state.json 里的本地日期。
function Test-DailySummaryDue {
    param($Config, [datetime]$Now = (Get-Date), [string]$LastDate = '')
    if (-not $Config -or -not $Config.dailySummary -or -not $Config.dailySummary.enabled) { return $false }
    if ($LastDate -eq $Now.ToString('yyyy-MM-dd')) { return $false }
    $due = ConvertTo-ConfigMinutes $Config.dailySummary.time
    if ($null -eq $due) { return $false }
    return (($Now.Hour * 60 + $Now.Minute) -ge $due)
}

function Resolve-RefreshInterval {
    param(
        [bool]$Explicit = $false,
        [int]$ExplicitValue = 300,
        $Config,
        $State,
        [bool]$ConfigFileExists = $false,
        [int]$Default = 300
    )
    if ($Explicit) {
        return (ConvertTo-ConfigInt $ExplicitValue $Default 15 86400)
    }
    if ($ConfigFileExists -and $Config) {
        return (ConvertTo-ConfigInt $Config.intervalSeconds $Default 15 86400)
    }
    if ($State -and $State.interval) {
        return (ConvertTo-ConfigInt $State.interval $Default 15 86400)
    }
    if ($Config) {
        return (ConvertTo-ConfigInt $Config.intervalSeconds $Default 15 86400)
    }
    return $Default
}

function Resolve-AlertThresholds {
    param($Config, [string]$Kind)
    $defaults = @(70, 90)
    if ($Config -and $Config.alertThresholds) { $defaults = @($Config.alertThresholds) }
    if ($Kind -and $Config -and $Config.providerAlertThresholds) {
        $override = Get-ConfigPropertyValue $Config.providerAlertThresholds $Kind
        if ($null -ne $override) {
            $parsed = @(ConvertTo-ConfigThresholds $override @())
            if ($parsed.Count -gt 0) { return $parsed }
        }
    }
    return @($defaults)
}

function Test-UsageResetTransition {
    param($Previous, $Current, [double]$High = 50, [double]$Low = 15)
    if (-not (Test-FiniteNumber $Previous) -or -not (Test-FiniteNumber $Current)) { return $false }
    return (([double]$Previous -ge $High) -and ([double]$Current -le $Low))
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
    $config.historyRetentionDays = ConvertTo-ConfigInt (Get-ConfigPropertyValue $Raw 'historyRetentionDays') $defaults.historyRetentionDays 7 3650
    $config.historyMaxBytes = ConvertTo-ConfigInt (Get-ConfigPropertyValue $Raw 'historyMaxBytes') $defaults.historyMaxBytes 1048576 1073741824
    $config.historySampleMinutes = ConvertTo-ConfigInt (Get-ConfigPropertyValue $Raw 'historySampleMinutes') $defaults.historySampleMinutes 1 1440
    $config.alertThresholds = ConvertTo-ConfigThresholds (Get-ConfigPropertyValue $Raw 'alertThresholds') $defaults.alertThresholds
    $config.lockPosition = ConvertTo-ConfigBool (Get-ConfigPropertyValue $Raw 'lockPosition') $defaults.lockPosition
    $config.layout = ConvertTo-ConfigLayout (Get-ConfigPropertyValue $Raw 'layout') $defaults.layout
    $config.columns = ConvertTo-ConfigInt (Get-ConfigPropertyValue $Raw 'columns') $defaults.columns 1 3
    $config.accountAliases = ConvertTo-ConfigStringMap (Get-ConfigPropertyValue $Raw 'accountAliases')
    $config.hiddenAccounts = ConvertTo-ConfigStringList (Get-ConfigPropertyValue $Raw 'hiddenAccounts')
    $config.accountOrder = ConvertTo-ConfigStringList (Get-ConfigPropertyValue $Raw 'accountOrder')
    $config.providerAlertThresholds = ConvertTo-ProviderAlertThresholds (Get-ConfigPropertyValue $Raw 'providerAlertThresholds')

    $rawSummary = Get-ConfigPropertyValue $Raw 'dailySummary'
    $config.dailySummary.enabled = ConvertTo-ConfigBool (Get-ConfigPropertyValue $rawSummary 'enabled') $defaults.dailySummary.enabled
    $config.dailySummary.time = ConvertTo-ConfigClock (Get-ConfigPropertyValue $rawSummary 'time') $defaults.dailySummary.time

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
