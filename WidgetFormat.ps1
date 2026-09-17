# Encoding: UTF-8 with BOM.
# WidgetFormat.ps1 - 卡片上的百分比、重置时间和抓取错误文案。
#
# 这些函数会调用 T() 取语言包，所以测试要先加载 WidgetStrings.ps1。
# 主程序和 worker 都注入同一组函数，避免明细文本在后台拼出来时找不到 T。

function Format-PercentText {
    param([double]$Percent)
    if (($Percent * 10) % 10 -ne 0) { return ('{0:0.0}%' -f $Percent) }
    return ('{0:0}%' -f $Percent)
}

# Balance-only providers carry no percentage at all: their row prints the amount it
# was given, and the tooltip follows the same text so both stay in step.
function Format-RowValueText {
    param([string]$Display, [double]$Percent)
    if ($Display) { return $Display }
    return (Format-PercentText $Percent)
}

function Format-ResetText {
    param($End)
    if (-not $End) { return (T 'reset.unknown') }
    $local = $End.ToLocalTime()
    $span = $local - [datetime]::Now
    if ($span.TotalSeconds -le 0) { return (T 'reset.soon') }
    if ($span.TotalDays -ge 1) {
        return (T 'reset.daysHours' @([int][Math]::Floor($span.TotalDays), $span.Hours))
    }
    if ($span.TotalHours -ge 1) {
        return (T 'reset.hoursMinutes' @([int][Math]::Floor($span.TotalHours), $span.Minutes))
    }
    return (T 'reset.minutes' @([Math]::Max(1, [int]$span.TotalMinutes)))
}

function Format-ResetTime {
    param($End)
    if (-not $End) { return $null }
    # 日期格式跟随界面语言，而不是操作系统的区域设置：英文界面不该出现「9月 17 日」。
    $culture = [Globalization.CultureInfo]::CurrentCulture
    try { $culture = [Globalization.CultureInfo]::GetCultureInfo($script:Language) } catch { }
    return $End.ToLocalTime().ToString((T 'reset.clockFormat'), $culture)
}

# Round-trippable reset stamp for the forecast; the row tooltip keeps the
# human readable Format-ResetTime text.
function ConvertTo-ResetStamp {
    param($End)
    if (-not $End) { return $null }
    try { return ([datetime]$End).ToString('o') } catch { return $null }
}

function Format-FetchError {
    param([string]$Message, [switch]$Detail)
    if (-not $Message) { return (T 'error.readFailed') }
    $safe = Convert-SafeLogText $Message 160
    if ($safe -match 'timeout|超时|HttpClient\.Timeout|canceled due to') { return (T 'error.timeout') }
    # 公开接口常用 403 表达匿名速率限制，先于通用的 403 分支匹配。
    if ($safe -match 'rate limit|速率限制') { return (T 'error.tooMany') }
    if ($safe -match 'SSL|certificate|信任关系|could not be established') { return (T 'error.network') }
    if ($safe -match 'HTTP 401|\b401\b|Unauthorized|auth-expired|token-refresh') { return (T 'error.unauthorized') }
    if ($safe -match 'HTTP 403|\b403\b|Forbidden') { return (T 'error.forbidden') }
    if ($safe -match 'HTTP 429|\b429\b') { return (T 'error.tooMany') }
    if ($safe -match 'missing-credential|no-credential') { return (T 'error.noCredentials') }
    if ($safe -match 'plan-missing') { return (T 'error.planMissing') }
    # 未知错误用本地化兜底，但在气泡提示里附上脱敏原文，便于对着日志排查。
    if ($Detail) { return ((T 'error.generic') + ' ' + $safe) }
    return (T 'error.generic')
}

function Format-ForecastText {
    param($Forecast)
    if (-not $Forecast) { return $null }
    if ($null -eq $Forecast.EtaHours) {
        if ($null -ne $Forecast.SlopePerDay) { return (T 'forecast.never') }
        return $null
    }
    $eta = [double]$Forecast.EtaHours
    $span = if ($eta -ge 48) { T 'forecast.days' @($eta / 24.0) }
            elseif ($eta -ge 1) { T 'forecast.hours' @($eta) }
            else { T 'forecast.minutes' @([Math]::Max(1, [int]($eta * 60))) }
    if ($Forecast.ExhaustsBeforeReset) { return (T 'forecast.beforeReset' @($span)) }
    return (T 'forecast.plain' @($span))
}
