# Command Code quota helpers. Pure parsing, no network/UI dependency.
# Auth lives in ~/.commandcode/auth.json (or $env:COMMAND_CODE_HOME).
# Daily/5-hour/weekly rolling usage windows returned by /alpha/billing/credits.

function Convert-CCWindow {
    param($Win)
    $used = $null
    $cap = $null
    try { $used = [double]$Win.used } catch { $used = $null }
    try { $cap = [double]$Win.cap } catch { $cap = $null }
    if ($null -eq $used -or $used -lt 0) { $used = 0.0 }
    $pct = 0.0
    if ($cap -gt 0) {
        $pct = [Math]::Min(100.0, 100.0 * $used / $cap)
        $pct = [Math]::Round($pct, 1)
        if ($pct -lt 0) { $pct = 0.0 }
    }
    $reset = Convert-CommandCodeTime $Win.resetAt
    return [pscustomobject]@{
        Percent = $pct
        Used    = $used
        Cap     = $cap
        ResetAt = $reset
    }
}

# API returns resetAt as epoch milliseconds (or an ISO string). Accept both.
function Convert-CommandCodeTime {
    param($Value)
    if ($null -eq $Value -or $Value -eq '') { return $null }
    if ($Value -is [datetime]) { return [datetime]$Value }
    $s = [string]$Value
    if ($s -match '^\d{10,13}$') {
        try {
            if ($s.Length -eq 13) { return [DateTimeOffset]::FromUnixTimeMilliseconds([long]$s).LocalDateTime }
            return [DateTimeOffset]::FromUnixTimeSeconds([long]$s).LocalDateTime
        } catch { return $null }
    }
    try { return [datetime]::Parse($s, $null, [Globalization.DateTimeStyles]::RoundtripKind) } catch { }
    return $null
}

function Convert-CommandCodeCredits {
    param($Data)
    $credits = $null
    if ($Data -and $Data.credits) { $credits = $Data.credits }
    # windowLimits lives at the top level of the credits response.
    $wl = $null
    if ($Data -and $Data.windowLimits) { $wl = $Data.windowLimits }
    elseif ($credits -and $credits.windowLimits) { $wl = $credits.windowLimits }
    $five = $null
    $week = $null
    if ($wl) {
        if ($wl.fiveHour) { try { $five = Convert-CCWindow $wl.fiveHour } catch { } }
        if ($wl.weekly)   { try { $week = Convert-CCWindow $wl.weekly }   catch { } }
    }
    if (-not $five -and -not $week) { throw '用量接口没有返回限额窗口' }

    $overall = 0.0
    try {
        if ($null -ne $credits.usagePercent) { $overall = [double]$credits.usagePercent }
    } catch { }
    if (-not $overall -and $week) { $overall = $week.Percent }
    if (-not $overall -and $five) { $overall = $five.Percent }
    if ($overall -lt 0) { $overall = 0.0 }
    if ($overall -gt 100) { $overall = 100.0 }
    $overall = [Math]::Round($overall, 1)

    $periodEnd = $null
    if ($week -and $week.ResetAt) { $periodEnd = $week.ResetAt }
    elseif ($five -and $five.ResetAt) { $periodEnd = $five.ResetAt }

    $totalRemaining = $null
    try {
        if ($null -ne $credits.totalRemaining) { $totalRemaining = [double]$credits.totalRemaining }
        elseif ($null -ne $credits.monthlyCredits) { $totalRemaining = [double]$credits.monthlyCredits }
    } catch { }

    return [pscustomobject]@{
        Percent        = $overall
        Used           = if ($week) { $week.Used } else { $null }
        Cap            = if ($week) { $week.Cap } else { $null }
        Weekly         = $week
        FiveHour       = $five
        PeriodEnd      = $periodEnd
        TotalRemaining = $totalRemaining
        FetchedAt      = [datetime]::Now
    }
}