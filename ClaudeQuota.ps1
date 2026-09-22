# Encoding: UTF-8 with BOM.
# Claude Code quota helpers. Pure parsing, no network/UI dependency.
#
# GET https://api.anthropic.com/api/oauth/usage with an OAuth access token
# returns rolling windows:
#   { "five_hour": { "utilization": 19, "resets_at": "2026-01-17T15:00:00Z" },
#     "seven_day": { "utilization": 45, "resets_at": "2026-01-20T12:00:00Z" } }
# utilization is already a used percent. API-key accounts have no quota window
# and are not handled here.

if (-not (Get-Command Test-FiniteNumber -ErrorAction SilentlyContinue)) {
    $validationHelper = Join-Path $PSScriptRoot 'UsageValidation.ps1'
    if (Test-Path -LiteralPath $validationHelper) { . $validationHelper }
}

function Convert-ClaudeWindow {
    param($Window, [string]$Field = 'claude window')
    if ($null -eq $Window) { return $null }
    $util = $null
    if ($Window.PSObject.Properties['utilization']) { $util = $Window.utilization }
    elseif ($Window.PSObject.Properties['Utilization']) { $util = $Window.Utilization }
    if (-not (Test-FiniteNumber $util)) { throw ("{0} 缺失或不是有限数值" -f $Field) }
    $percent = Assert-UsagePercent $util $Field
    $resetAt = $null
    $stamp = $null
    if ($Window.PSObject.Properties['resets_at'] -and $Window.resets_at) { $stamp = $Window.resets_at }
    elseif ($Window.PSObject.Properties['resetsAt'] -and $Window.resetsAt) { $stamp = $Window.resetsAt }
    if ($stamp) {
        try { $resetAt = Convert-ApiTime $stamp } catch { $resetAt = $null }
    }
    return @{ Percent = $percent; ResetAt = $resetAt }
}

function Convert-ClaudeUsage {
    param($Payload)
    if (-not $Payload) { throw 'bad-payload' }
    $five = $null
    $week = $null
    try { $five = Convert-ClaudeWindow $Payload.five_hour 'claude 5h' } catch { if ($Payload.five_hour) { throw } }
    try { $week = Convert-ClaudeWindow $Payload.seven_day 'claude week' } catch { if ($Payload.seven_day) { throw } }
    if (-not $five -and -not $week) { throw 'bad-payload' }
    $percent = 0.0
    if ($week) { $percent = [double]$week.Percent }
    if ($five -and [double]$five.Percent -gt $percent) { $percent = [double]$five.Percent }
    $resetAt = $null
    if ($five -and $five.ResetAt) { $resetAt = $five.ResetAt }
    if ($week -and $week.ResetAt) {
        if (-not $resetAt -or $week.ResetAt -lt $resetAt) { $resetAt = $week.ResetAt }
    }
    return [pscustomobject]@{
        Percent   = $percent
        FiveHour  = $five
        Weekly    = $week
        ResetAt   = $resetAt
        FetchedAt = [datetime]::Now
    }
}

function Get-ClaudeAccountId {
    param($Raw, $Oauth)
    foreach ($obj in @($Oauth, $Raw)) {
        if (-not $obj) { continue }
        foreach ($name in @('accountUuid', 'account_uuid', 'accountId', 'account_id', 'email')) {
            $prop = $obj.PSObject.Properties[$name]
            if ($prop -and [string]$prop.Value) { return ([string]$prop.Value).Trim().ToLowerInvariant() }
        }
    }
    $refresh = $null
    if ($Oauth) {
        $refresh = [string]$Oauth.refreshToken
        if (-not $refresh) { $refresh = [string]$Oauth.refresh_token }
    }
    if ($refresh) { return ('refresh:' + (Get-AccountFingerprint -AccountId $refresh -Prefix 'tok')) }
    return $null
}

function Convert-ClaudeRawAuth {
    param($Raw)
    if (-not $Raw) { throw 'missing-credential' }
    $oauth = $null
    if ($Raw.PSObject.Properties['claudeAiOauth']) { $oauth = $Raw.claudeAiOauth }
    if (-not $oauth -and $Raw.PSObject.Properties['oauth']) { $oauth = $Raw.oauth }
    if (-not $oauth) { throw 'missing-credential' }
    $access = [string]$oauth.accessToken
    if (-not $access) { $access = [string]$oauth.access_token }
    if (-not $access) { throw 'missing-credential' }
    $refresh = [string]$oauth.refreshToken
    if (-not $refresh) { $refresh = [string]$oauth.refresh_token }
    $expiresAt = $null
    $rawExpiry = $oauth.expiresAt
    if ($null -eq $rawExpiry) { $rawExpiry = $oauth.expires_at }
    if (Test-FiniteNumber $rawExpiry) {
        $number = [double]$rawExpiry
        if ($number -gt 1000000000000) { $number = $number / 1000.0 }
        try { $expiresAt = [datetime]::SpecifyKind([datetime]'1970-01-01', 'Utc').AddSeconds($number) } catch { }
    } elseif ($rawExpiry) {
        try { $expiresAt = Convert-ApiTime $rawExpiry } catch { }
    }
    $authObject = [pscustomobject]@{
        AccessToken  = $access.Trim()
        RefreshToken = if ($refresh) { $refresh.Trim() } else { $null }
        ExpiresAt    = $expiresAt
        AccountId    = (Get-ClaudeAccountId -Raw $Raw -Oauth $oauth)
        Raw          = $Raw
    }
    return (Set-CredentialVersion -Auth $authObject -AccessToken $authObject.AccessToken -RefreshToken $authObject.RefreshToken -AccountId $authObject.AccountId)
}
