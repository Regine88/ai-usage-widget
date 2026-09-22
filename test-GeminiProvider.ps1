# Encoding: UTF-8 with BOM.
# Run: powershell -NoProfile -File .\test-GeminiProvider.ps1
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $here 'UsageValidation.ps1')
. (Join-Path $here 'SecureSnapshot.ps1')
. (Join-Path $here 'WidgetStrings.ps1')
. (Join-Path $here 'WidgetFormat.ps1')
. (Join-Path $here 'GeminiAntigravity.ps1')

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

function New-FakeJwt {
    param([string]$Email)
    $header = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes('{"alg":"none"}')).TrimEnd('=').Replace('+', '-').Replace('/', '_')
    $payloadJson = '{"email":"' + $Email + '"}'
    $payload = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($payloadJson)).TrimEnd('=').Replace('+', '-').Replace('/', '_')
    return ($header + '.' + $payload + '.sig')
}

function New-GeminiRaw {
    param([string]$Email, [string]$Access, [string]$Refresh, [string]$Expiry, [string]$JwtEmail)
    $token = @{ access_token = $Access; refresh_token = $Refresh; expiry = $Expiry }
    if ($JwtEmail) { $token.id_token = (New-FakeJwt $JwtEmail) }
    $body = @{ token = $token }
    if ($Email) { $body.email = $Email }
    return ($body | ConvertTo-Json -Depth 6 | ConvertFrom-Json)
}

$script:WidgetStrings = Read-WidgetStrings -Language 'en-US' -Dir $here
$script:responses = @()
$script:calls = @()
$script:callIndex = 0
$script:credWrites = 0
$script:AntigravityClientId = 'test-client'
$script:AntigravityClientSecret = 'test-secret'
$script:AntigravityTokenUrl = 'https://oauth2.googleapis.com/token'
$script:AntigravityQuotaUrl = 'https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuotaSummary'
$script:AntigravityCredTarget = 'gemini:antigravity'
$script:liveAuth = $null

function Invoke-WidgetRest {
    param($Method, $Uri, $Headers, $Body, $ContentType, $TimeoutSec)
    $auth = $null
    if ($Headers) { $auth = [string]$Headers['Authorization'] }
    $script:calls += [pscustomobject]@{ Method = $Method; Uri = $Uri; Auth = $auth; Body = [string]$Body }
    if ($script:callIndex -ge $script:responses.Count) { throw 'unexpected request' }
    $response = $script:responses[$script:callIndex]
    $script:callIndex++
    return $response
}
function Write-WidgetLog { param([string]$Message) }
function Test-AntigravityCredExists { return ($null -ne $script:liveAuth) }
function Read-AntigravityCred { return $script:liveAuth }
function Save-AntigravityCred { param($Auth) $script:credWrites++ }

$dir = Join-Path $env:TEMP ('gemini-provider-test-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $dir -Force | Out-Null
$script:SecureSnapshotRoot = Join-Path $dir 'snapshots'
try {
    $fromEmail = Convert-GeminiRawAuth -Raw (New-GeminiRaw -Email 'A@Example.com' -Access 'aaa' -Refresh 'rrr' -Expiry '2099-01-01T00:00:00Z') -Path 'live' -Source 'credential'
    Assert-Eq $fromEmail.AccountId 'a@example.com' 'email is the account id'
    Assert-Eq (Get-GeminiRowName $fromEmail).Contains('@') 'False' 'the row label does not show the email'
    Assert-Eq (Get-GeminiRowId $fromEmail).StartsWith('gemini-acct-') 'True' 'the row id is a fingerprint'

    $fromJwt = Convert-GeminiRawAuth -Raw (New-GeminiRaw -Access 'bbb' -Refresh 'sss' -Expiry '2099-01-01T00:00:00Z' -JwtEmail 'B@Example.com') -Path 'live' -Source 'credential'
    Assert-Eq $fromJwt.AccountId 'b@example.com' 'id_token email is the account id'
    Assert-Eq ((Get-GeminiRowId $fromEmail) -ne (Get-GeminiRowId $fromJwt)) 'True' 'different accounts get different row ids'

    $fromRefresh = Convert-GeminiRawAuth -Raw (New-GeminiRaw -Access 'ccc' -Refresh 'refresh-only' -Expiry '2099-01-01T00:00:00Z') -Path 'live' -Source 'credential'
    Assert-Eq $fromRefresh.AccountId.StartsWith('refresh:') 'True' 'a credential without an email falls back to the refresh token'
    try {
        Convert-GeminiRawAuth -Raw ('{"token":{}}' | ConvertFrom-Json) -Path 'live'
        Write-Host 'FAIL missing refresh token should throw'
        $script:failed++
    } catch {
        Write-Host 'OK   missing refresh token throws'
    }

    $script:liveAuth = $null
    Assert-Eq (Add-CurrentGeminiAccount).Status 'missing' 'registration without a login reports missing'
    $script:liveAuth = $fromEmail
    $first = Add-CurrentGeminiAccount
    Assert-Eq $first.Status 'registered' 'the current Gemini login can be registered'
    $second = Add-CurrentGeminiAccount
    Assert-Eq $second.Status 'same-account' 'registering the same login does not add a row'
    Assert-Eq (@(Get-GeminiAccounts).Count) '1' 'the live login and its snapshot are one account'

    $otherRaw = New-GeminiRaw -Email 'b@example.com' -Access 'snap-b' -Refresh 'refresh-b' -Expiry '2099-01-01T00:00:00Z'
    [void](Write-SecureSnapshot -Provider gemini -AccountId 'b@example.com' -Value $otherRaw)
    $accounts = @(Get-GeminiAccounts)
    Assert-Eq $accounts.Count '2' 'the live account and another snapshot are both listed'
    $snapB = $accounts | Where-Object { $_.AccountId -eq 'b@example.com' } | Select-Object -First 1
    Assert-Eq $snapB.Source 'snapshot' 'the second account is read from its snapshot'
    Assert-Eq $snapB.AccessToken 'snap-b' 'the snapshot keeps its own access token'
    Assert-Eq (@($accounts | ForEach-Object { Get-GeminiRowId $_ } | Sort-Object -Unique).Count) '2' 'registered accounts keep distinct row ids'

    $quota = @{
        groups = @(
            @{
                displayName = 'Gemini Models'
                buckets = @(
                    @{ bucketId = 'gemini-weekly'; window = 'weekly'; remainingFraction = 0.4; resetTime = '2026-09-01T13:54:23Z' }
                    @{ bucketId = 'gemini-5h'; window = '5h'; remainingFraction = 0.85; resetTime = '2026-08-25T18:54:23Z' }
                )
            }
        )
    } | ConvertTo-Json -Depth 8 | ConvertFrom-Json
    $script:responses = @($quota)
    $script:calls = @()
    $script:callIndex = 0
    $usage = Get-GeminiUsageSnapshot -Auth $snapB
    Assert-Eq $script:calls[0].Auth 'Bearer snap-b' 'a snapshot row uses its own token'
    Assert-Eq ([Math]::Round($usage.Remaining, 1)) '40' 'the snapshot row reads its own remaining quota'
    Assert-Eq $script:credWrites '0' 'reading a snapshot does not write the live credential'

    $expiredRaw = New-GeminiRaw -Email 'b@example.com' -Access 'old-b' -Refresh 'old-refresh-b' -Expiry '2000-01-01T00:00:00Z'
    [void](Write-SecureSnapshot -Provider gemini -AccountId 'b@example.com' -Value $expiredRaw)
    $expired = Read-GeminiSnapshot -Path (Get-SecureSnapshotPath -Provider gemini -AccountId 'b@example.com')
    $script:responses = @(
        ([pscustomobject]@{ access_token = 'fresh-b'; refresh_token = 'fresh-refresh-b'; expires_in = 3600 }),
        $quota
    )
    $script:calls = @()
    $script:callIndex = 0
    $script:credWrites = 0
    $refreshed = Get-GeminiUsageSnapshot -Auth $expired
    Assert-Eq $script:calls[0].Uri $script:AntigravityTokenUrl 'an expired snapshot refreshes itself'
    Assert-Eq $script:calls[1].Auth 'Bearer fresh-b' 'the refreshed snapshot token is used for quota'
    Assert-Eq $script:credWrites '0' 'refreshing a snapshot does not overwrite the live Antigravity login'
    $saved = Read-SecureSnapshot -Path (Get-SecureSnapshotPath -Provider gemini -AccountId 'b@example.com')
    Assert-Eq $saved.token.access_token 'fresh-b' 'the snapshot stores the refreshed access token'
    Assert-Eq $saved.token.refresh_token 'fresh-refresh-b' 'the snapshot stores the rotated refresh token'
    Assert-Eq ([Math]::Round($refreshed.Remaining, 1)) '40' 'quota is read after the snapshot refresh'

    $script:liveAuth = New-GeminiRaw -Email 'live-b@example.com' -Access 'live-b' -Refresh 'live-b-refresh' -Expiry '2099-01-01T00:00:00Z'
    $activeGeminiA = [pscustomobject]@{
        AccessToken  = 'active-a-fresh'
        RefreshToken = 'active-a-refresh-fresh'
        ExpiresAt    = [datetime]::UtcNow.AddHours(3)
        AccountId    = 'a@example.com'
        Path         = $script:AntigravityCredTarget
        Source       = 'credential'
        Raw          = New-GeminiRaw -Email 'A@Example.com' -Access 'old-a' -Refresh 'active-a-refresh' -Expiry '2000-01-01T00:00:00Z'
    }
    $script:credWrites = 0
    Save-GeminiAuth $activeGeminiA
    Assert-Eq $script:credWrites '0' 'a Gemini account switch does not overwrite the live credential'
    Assert-Eq $script:liveAuth.email 'live-b@example.com' 'the live Gemini login remains account B'
    $geminiSnapA = Read-SecureSnapshot -Path (Get-SecureSnapshotPath -Provider gemini -AccountId 'a@example.com')
    Assert-Eq $geminiSnapA.token.access_token 'active-a-fresh' 'the Gemini switched refresh is stored in the A snapshot'

    $script:liveAuth = $null
    Assert-Eq (@(Get-GeminiAccounts).Count) '2' 'registered snapshots remain after the live login disappears'
} finally {
    Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
}

$entryText = Get-Content -LiteralPath (Join-Path $here 'AiUsageWidget.ps1') -Raw -Encoding utf8
Assert-Eq ($entryText -match 'miAddGemini') 'True' 'the context menu can register the current Gemini account'
Assert-Eq ($entryText -match '\$AddGeminiAccount') 'True' 'the entry script has a Gemini registration switch'
Assert-Eq ($entryText -match '''gemini'' \{ \$d = Get-GeminiRowData -Auth \$row\.Auth -Name \$row\.Name \}') 'True' 'the worker passes each Gemini account into its row'
Assert-Eq ($entryText -match 'Sync-ActiveGeminiSnapshot') 'True' 'the current Gemini login is snapshotted on refresh'
$fnNames = @()
$match = [regex]::Match($entryText, '(?s)function Get-WorkerScriptSource \{.*?\$fnNames = @\((.*?)\)')
if ($match.Success) { $fnNames = @([regex]::Matches($match.Groups[1].Value, "'([^']+)'") | ForEach-Object { $_.Groups[1].Value }) }
foreach ($name in @('Convert-GeminiRawAuth', 'Save-GeminiAuth', 'Get-GeminiUsageSnapshot', 'Get-GeminiRowData')) {
    Assert-Eq ($fnNames -contains $name) 'True' ('worker forwards ' + $name)
}

if ($failed -gt 0) {
    Write-Host ("FAILED {0}" -f $failed)
    exit 1
}
Write-Host 'ALL PASSED'
exit 0
