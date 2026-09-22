# Cline quota helpers. Pure parsing, no network or UI dependency.
#
# Credentials are stored by the official CLI in
# ~/.cline/data/settings/providers.json. The Cline API returns the same
# rolling quota windows shown on https://app.cline.bot/dashboard:
#   { "data": { "limits": [
#     { "type": "five_hour", "percentUsed": 1, "resetsAt": "..." },
#     { "type": "weekly", "percentUsed": 0, "resetsAt": "..." },
#     { "type": "monthly", "percentUsed": 0, "resetsAt": "..." } ] } }

if (-not (Get-Command Test-FiniteNumber -ErrorAction SilentlyContinue) -or -not (Get-Command Get-AccountFingerprint -ErrorAction SilentlyContinue)) {
    $validationHelper = Join-Path $PSScriptRoot 'UsageValidation.ps1'
    if (Test-Path -LiteralPath $validationHelper) { . $validationHelper }
}

function Get-ClineProperty {
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

function Convert-ClineResetTime {
    param($Value)
    if ($null -eq $Value -or $Value -eq '') { return $null }
    if ($Value -is [datetime]) { return [datetime]$Value }
    $text = [string]$Value
    if ($text -match '^\d{10,13}$') {
        try {
            if ($text.Length -eq 13) { return [DateTimeOffset]::FromUnixTimeMilliseconds([long]$text).LocalDateTime }
            return [DateTimeOffset]::FromUnixTimeSeconds([long]$text).LocalDateTime
        } catch { return $null }
    }
    try { return [datetime]::Parse($text, $null, [Globalization.DateTimeStyles]::RoundtripKind) } catch { return $null }
}

function Convert-ClineUsageLimit {
    param($Limit)
    if ($null -eq $Limit) { return $null }
    $type = [string](Get-ClineProperty $Limit 'type')
    if ($type -notin @('five_hour', 'weekly', 'monthly')) { throw 'bad-payload' }
    $rawPercent = Get-ClineProperty $Limit 'percentUsed'
    if ($null -eq $rawPercent) { $rawPercent = Get-ClineProperty $Limit 'percent_used' }
    $percent = [Math]::Round((Assert-UsagePercent $rawPercent ('cline ' + $type + ' percent')), 1)
    $resetAt = Convert-ClineResetTime (Get-ClineProperty $Limit 'resetsAt')
    if (-not $resetAt) { $resetAt = Convert-ClineResetTime (Get-ClineProperty $Limit 'resets_at') }
    return [pscustomobject]@{
        Type    = $type
        Percent = $percent
        ResetAt = $resetAt
    }
}

function Convert-ClineUsageLimits {
    param($Payload)
    if ($null -eq $Payload) { throw 'bad-payload' }
    $data = Get-ClineProperty $Payload 'data'
    if ($null -eq $data) { $data = $Payload }
    $limits = Get-ClineProperty $data 'limits'
    if ($null -eq $limits) { throw 'bad-payload' }

    $five = $null
    $weekly = $null
    $monthly = $null
    foreach ($item in @($limits)) {
        $parsed = Convert-ClineUsageLimit $item
        if (-not $parsed) { continue }
        switch ($parsed.Type) {
            'five_hour' { $five = $parsed }
            'weekly'    { $weekly = $parsed }
            'monthly'   { $monthly = $parsed }
        }
    }
    if (-not $five -and -not $weekly -and -not $monthly) { throw 'bad-payload' }

    $overall = $weekly
    foreach ($candidate in @($five, $monthly)) {
        if ($candidate -and (-not $overall -or [double]$candidate.Percent -gt [double]$overall.Percent)) {
            $overall = $candidate
        }
    }
    return [pscustomobject]@{
        Percent   = [Math]::Round([double]$overall.Percent, 1)
        FiveHour  = $five
        Weekly    = $weekly
        Monthly   = $monthly
        ResetAt   = $overall.ResetAt
        FetchedAt = [datetime]::Now
    }
}

function Convert-ClineAuthExpiry {
    param($Value)
    if ($null -eq $Value -or $Value -eq '') { return $null }
    if (Test-FiniteNumber $Value) {
        $number = [double]$Value
        if ($number -gt 1000000000000) { $number = $number / 1000.0 }
        try { return [datetime]::SpecifyKind([datetime]'1970-01-01', 'Utc').AddSeconds($number) } catch { return $null }
    }
    try { return [datetime]::Parse([string]$Value, $null, [Globalization.DateTimeStyles]::RoundtripKind) } catch { return $null }
}

function ConvertTo-ClineStoredAccessToken {
    param([string]$Token)
    $text = ([string]$Token).Trim()
    if (-not $text) { return $null }
    if ($text -like 'workos:*') { return $text }
    return ('workos:' + $text)
}

function Get-ClineAuthEntry {
    param($Raw)
    if ($null -eq $Raw) { return $null }
    $providers = Get-ClineProperty $Raw 'providers'
    if ($null -eq $providers) { return $null }

    foreach ($name in @('cline', 'cline-pass')) {
        $provider = Get-ClineProperty $providers $name
        $settings = Get-ClineProperty $provider 'settings'
        $auth = Get-ClineProperty $settings 'auth'
        $candidateAccess = [string](Get-ClineProperty $auth 'accessToken')
        if ($candidateAccess) {
            return [pscustomobject]@{
                ProviderName = $name
                Provider     = $provider
                Settings     = $settings
                Auth         = $auth
            }
        }
    }
    return $null
}

function Convert-ClineRawAuth {
    param($Raw, [string]$Path)
    $entry = Get-ClineAuthEntry $Raw
    if (-not $entry) { throw 'missing-credential' }
    $auth = $entry.Auth
    if (-not $auth) { throw 'missing-credential' }

    $access = ConvertTo-ClineStoredAccessToken ([string](Get-ClineProperty $auth 'accessToken'))
    $refresh = [string](Get-ClineProperty $auth 'refreshToken')
    $accountId = [string](Get-ClineProperty $auth 'accountId')
    if (-not $accountId -and $refresh) {
        $accountId = 'refresh:' + (Get-AccountFingerprint -AccountId $refresh -Prefix 'tok')
    }
    $authObject = [pscustomobject]@{
        Path         = $Path
        Source       = $(if ($Path -like '*.snapshot') { 'snapshot' } else { 'file' })
        AccessToken  = $access
        RefreshToken = if ($refresh) { $refresh.Trim() } else { $null }
        ExpiresAt    = Convert-ClineAuthExpiry (Get-ClineProperty $auth 'expiresAt')
        AccountId    = $accountId.Trim()
        Raw          = $Raw
        RawProvider  = $entry.Provider
        RawSettings  = $entry.Settings
        RawAuth      = $auth
        ProviderName = $entry.ProviderName
    }
    return (Set-CredentialVersion -Auth $authObject -AccessToken $access -RefreshToken $authObject.RefreshToken -AccountId $accountId)
}
