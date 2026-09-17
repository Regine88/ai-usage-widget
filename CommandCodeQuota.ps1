# Command Code quota helpers. Pure parsing, no network/UI dependency.
# Auth lives in ~/.commandcode/auth.json (or $env:COMMAND_CODE_HOME).
# Daily/5-hour/weekly rolling usage windows returned by /alpha/billing/credits.

if (-not (Get-Command Convert-UsageRatioPercent -ErrorAction SilentlyContinue)) {
    $validationHelper = Join-Path $PSScriptRoot 'UsageValidation.ps1'
    if (Test-Path -LiteralPath $validationHelper) { . $validationHelper }
}

function Convert-CCWindow {
    param($Win)
    if (-not $Win) { throw 'bad-payload' }
    $used = [double]$Win.used
    $cap = [double]$Win.cap
    $pct = [Math]::Round((Convert-UsageRatioPercent $Win.used $Win.cap 'Command Code window'), 1)
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
        if ($null -ne $wl.fiveHour) { $five = Convert-CCWindow $wl.fiveHour }
        if ($null -ne $wl.weekly)   { $week = Convert-CCWindow $wl.weekly }
    }
    if (-not $five -and -not $week) { throw 'bad-payload' }

    $overall = $null
    if ($credits -and $null -ne $credits.usagePercent) {
        $overall = Assert-UsagePercent $credits.usagePercent 'Command Code usagePercent'
    }
    if ($null -eq $overall -and $week) { $overall = $week.Percent }
    if ($null -eq $overall -and $five) { $overall = $five.Percent }
    if ($null -eq $overall) { throw 'bad-payload' }
    $overall = [Math]::Round($overall, 1)

    $periodEnd = $null
    if ($week -and $week.ResetAt) { $periodEnd = $week.ResetAt }
    elseif ($five -and $five.ResetAt) { $periodEnd = $five.ResetAt }

    $totalRemaining = $null
    if ($credits -and $null -ne $credits.totalRemaining) {
        if (-not (Test-FiniteNumber $credits.totalRemaining)) { throw 'bad-payload' }
        $totalRemaining = [double]$credits.totalRemaining
    } elseif ($credits -and $null -ne $credits.monthlyCredits) {
        if (-not (Test-FiniteNumber $credits.monthlyCredits)) { throw 'bad-payload' }
        $totalRemaining = [double]$credits.monthlyCredits
    }

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
