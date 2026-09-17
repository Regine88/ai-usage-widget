# Encoding: UTF-8 with BOM.
# Z.AI / Zhipu GLM Coding Plan quota helpers. Pure parsing, no network/UI.
#
# GET /api/monitor/usage/quota/limit returns:
#   { "data": { "level": "pro",
#       "limits": [
#         { "type": "TOKENS_FIVE_HOURS", "percentage": 12, "nextResetTime": 1774000000000 },
#         { "type": "TOKENS_SEVEN_DAYS", "percentage": 40, "nextResetTime": 1774500000000 }
#       ] } }
# percentage is used percent. Auth is the raw API key (no Bearer prefix).

if (-not (Get-Command Test-FiniteNumber -ErrorAction SilentlyContinue)) {
    $validationHelper = Join-Path $PSScriptRoot 'UsageValidation.ps1'
    if (Test-Path -LiteralPath $validationHelper) { . $validationHelper }
}
if (-not (Get-Command Get-ConfigPropertyValue -ErrorAction SilentlyContinue)) {
    $configHelper = Join-Path $PSScriptRoot 'WidgetConfig.ps1'
    if (Test-Path -LiteralPath $configHelper) { . $configHelper }
}

function Convert-ZaiResetTime {
    param($Value)
    if (-not (Test-FiniteNumber $Value)) { return $null }
    $number = [double]$Value
    if ($number -gt 1000000000000) { $number = $number / 1000.0 }
    if ($number -le 0) { return $null }
    try { return [datetime]::SpecifyKind([datetime]'1970-01-01', 'Utc').AddSeconds($number) } catch { return $null }
}

function Convert-ZaiLimitItem {
    param($Item)
    if (-not $Item) { return $null }
    $type = [string]$Item.type
    if (-not $type) { return $null }
    $percent = $null
    if (Test-FiniteNumber $Item.percentage) {
        $percent = Assert-UsagePercent $Item.percentage ('zai ' + $type)
    } elseif ((Test-FiniteNumber $Item.usage) -and (Test-FiniteNumber $Item.currentValue) -and [double]$Item.currentValue -gt 0) {
        $ratio = [Math]::Min(100.0, [Math]::Round(100.0 * [double]$Item.usage / [double]$Item.currentValue, 1))
        $percent = Assert-UsagePercent $ratio ('zai ' + $type)
    }
    if ($null -eq $percent) { return $null }
    return @{
        Type     = $type
        Percent  = $percent
        ResetAt  = (Convert-ZaiResetTime $Item.nextResetTime)
    }
}

function Test-ZaiFiveHourType {
    param([string]$Type)
    return [bool]($Type -match '(?i)five|5h|5_hour|5-hour')
}

function Test-ZaiWeeklyType {
    param([string]$Type)
    return [bool]($Type -match '(?i)seven|week|7d|7_day|7-day')
}

# 服务端用 code != 0 表达“账号没有 Coding Plan”这类业务错误，
# 取 msg 让界面能说清楚原因，而不是笼统地报“读取失败”。
function Get-ZaiBusinessError {
    param($Payload)
    if (-not $Payload) { return $null }
    $code = Get-ConfigPropertyValue $Payload 'code'
    if ($null -eq $code) { return $null }
    if ([string]$code -eq '0') { return $null }
    $message = Get-ConfigPropertyValue $Payload 'msg'
    if (-not $message) { return $null }
    return ([string]$message).Trim()
}

# ZCode 把智谱 BigModel 的密钥放在 provider.<id>.options.apiKey；
# 这里只做纯解析，读文件由调用方负责（便于离线测试）。
function Get-ZaiBigModelKey {
    param($Payload)
    if (-not $Payload) { return $null }
    $provider = Get-ConfigPropertyValue $Payload 'provider'
    if (-not $provider) { return $null }
    foreach ($name in @('builtin:bigmodel-coding-plan', 'builtin:bigmodel')) {
        $entry = Get-ConfigPropertyValue $provider $name
        $options = Get-ConfigPropertyValue $entry 'options'
        $key = Get-ConfigPropertyValue $options 'apiKey'
        if ($key) { return ([string]$key).Trim() }
    }
    return $null
}

function Convert-ZaiQuota {
    param($Payload)
    if (-not $Payload) { throw 'bad-payload' }
    $businessError = Get-ZaiBusinessError $Payload
    if ($businessError) { throw ('plan-missing: ' + $businessError) }
    $data = $Payload
    if ($Payload.PSObject.Properties['data'] -and $Payload.data) { $data = $Payload.data }
    $limits = @()
    if ($data.PSObject.Properties['limits'] -and $data.limits) { $limits = @($data.limits) }
    $five = $null
    $week = $null
    foreach ($item in $limits) {
        $parsed = Convert-ZaiLimitItem $item
        if (-not $parsed) { continue }
        if (-not $five -and (Test-ZaiFiveHourType $parsed.Type)) { $five = $parsed }
        elseif (-not $week -and (Test-ZaiWeeklyType $parsed.Type)) { $week = $parsed }
    }
    if (-not $five -and -not $week) { throw 'bad-payload' }
    $percent = 0.0
    if ($week) { $percent = [double]$week.Percent }
    if ($five -and [double]$five.Percent -gt $percent) { $percent = [double]$five.Percent }
    $resetAt = $null
    if ($five -and $five.ResetAt) { $resetAt = $five.ResetAt }
    if ($week -and $week.ResetAt) {
        if (-not $resetAt -or $week.ResetAt -lt $resetAt) { $resetAt = $week.ResetAt }
    }
    $level = $null
    if ($data.PSObject.Properties['level'] -and $data.level) { $level = [string]$data.level }
    return [pscustomobject]@{
        Percent   = $percent
        FiveHour  = $five
        Weekly    = $week
        Level     = $level
        ResetAt   = $resetAt
        FetchedAt = [datetime]::Now
    }
}
