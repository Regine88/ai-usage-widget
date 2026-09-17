# Kimi 用量载荷解析（纯函数，供主 Widget、后台工作线程与测试共用）。

function Get-KimiWindowLabel {
    param($Window)
    if (-not $Window) { return $null }
    $duration = 0
    try { $duration = [int]$Window.duration } catch { return $null }
    $unit = [string]$Window.timeUnit
    $hours = 0.0
    switch ($unit) {
        'TIME_UNIT_MINUTE' { $hours = $duration / 60.0 }
        'TIME_UNIT_HOUR'   { $hours = [double]$duration }
        'TIME_UNIT_DAY'    { $hours = $duration * 24.0 }
        'TIME_UNIT_WEEK'   { $hours = $duration * 168.0 }
        default            { return $null }
    }
    if ($hours -le 0) { return $null }
    if ($hours -ge 24) { return ('{0}天窗' -f [int][Math]::Round($hours / 24.0)) }
    if ($hours -eq [int]$hours) { return ('{0}小时窗' -f [int]$hours) }
    return ('{0:0.#}小时窗' -f $hours)
}

function Resolve-KimiUsedLimit {
    param($Detail, [string]$Field = 'Kimi usage')
    if ($null -eq $Detail) { throw ("{0} 缺少数据对象" -f $Field) }
    $limit = Assert-PositiveFiniteNumber $Detail.limit ("{0} limit" -f $Field)
    $used = $null
    if ($null -ne $Detail.used) {
        if (-not (Test-FiniteNumber $Detail.used)) { throw ("{0} used 不是有限数值" -f $Field) }
        $used = [double]$Detail.used
    } elseif ($null -ne $Detail.remaining) {
        if (-not (Test-FiniteNumber $Detail.remaining)) { throw ("{0} remaining 不是有限数值" -f $Field) }
        $used = $limit - [double]$Detail.remaining
    } else {
        throw ("{0} 缺少 used 或 remaining" -f $Field)
    }
    [pscustomobject]@{ Used = $used; Limit = $limit }
}

function Convert-KimiUsagePayload {
    param($Data)
    if ($null -eq $Data -or -not $Data.usage) { throw '用量接口没有返回 usage' }
    $total = Resolve-KimiUsedLimit $Data.usage 'Kimi usage'
    $pct = Convert-UsageRatioPercent $total.Used $total.Limit 'Kimi usage'
    $periodEnd = Convert-ApiTime $Data.usage.resetTime

    $windows = @()
    foreach ($row in @($Data.limits)) {
        $d = $row.detail
        if (-not $d) { continue }
        $w = Resolve-KimiUsedLimit $d 'Kimi window'
        $wPct = Convert-UsageRatioPercent $w.Used $w.Limit 'Kimi window'
        $windows += [pscustomobject]@{
            Label   = Get-KimiWindowLabel $row.window
            Percent = [Math]::Round($wPct, 1)
        }
    }

    $extraCents = 0
    $currency = 'CNY'
    if ($Data.boosterWallet) {
        try {
            if ($Data.boosterWallet.monthlyUsed.priceInCents) {
                $extraCents = [long]$Data.boosterWallet.monthlyUsed.priceInCents
            }
            if ($Data.boosterWallet.monthlyUsed.currency) { $currency = [string]$Data.boosterWallet.monthlyUsed.currency }
        } catch { }
    }

    [pscustomobject]@{
        Percent    = [Math]::Round($pct, 1)
        Windows    = $windows
        PeriodEnd  = $periodEnd
        ExtraCents = $extraCents
        Currency   = $currency
    }
}
