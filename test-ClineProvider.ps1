# Run: powershell -NoProfile -File .\test-ClineProvider.ps1
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $here 'UsageValidation.ps1')
. (Join-Path $here 'WidgetStrings.ps1')
. (Join-Path $here 'WidgetFormat.ps1')
. (Join-Path $here 'ClineQuota.ps1')
. (Join-Path $here 'SecureSnapshot.ps1')

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

function Get-ScriptFunctionDefinition {
    param([string]$ScriptPath, [string]$Name)
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($ScriptPath, [ref]$null, [ref]$null)
    foreach ($fn in $ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)) {
        if ($fn.Name -eq $Name) { return $fn.Extent.Text }
    }
    throw ('function not found: ' + $Name)
}

$entry = Join-Path $here 'AiUsageWidget.ps1'
$entryText = Get-Content -LiteralPath $entry -Raw -Encoding utf8
$script:WidgetStrings = Read-WidgetStrings -Language 'en-US' -Dir $here
$script:responses = @()
$script:calls = @()
$script:callIndex = 0

function Invoke-WidgetRest {
    param($Method, $Uri, $Headers, $Body, $ContentType, $TimeoutSec)
    $auth = $null
    if ($Headers) { $auth = [string]$Headers['Authorization'] }
    $script:calls += [pscustomobject]@{ Method = $Method; Uri = $Uri; Auth = $auth; Body = [string]$Body; ContentType = $ContentType }
    if ($script:callIndex -ge $script:responses.Count) { throw 'unexpected request' }
    $response = $script:responses[$script:callIndex]
    $script:callIndex++
    return $response
}

function Invoke-SecureSnapshotFileLock {
    param([string]$Path, [scriptblock]$Action)
    & $Action
}

function Write-WidgetLog { param([string]$Message) }

$definitions = @()
foreach ($name in @('Find-MatchingSnapshotAccount', 'Test-ClineCredExists', 'Read-ClineAuth', 'Set-ClineAuthFields', 'Save-ClineSnapshot', 'Save-ClineAuth', 'Get-ClineRowId', 'Get-ClineRowName', 'Get-ClineSnapshotPath', 'Get-ClineAccounts', 'Add-CurrentClineAccount', 'Sync-ActiveClineSnapshot', 'Update-ClineToken', 'Get-ClineAuthHeaders', 'Get-ClineUsageSnapshot', 'Get-ClineRowData')) {
    $definitions += (Get-ScriptFunctionDefinition $entry $name)
}
$definitions += '$script:ClineDisplayName = ''Cline'''
$definitions += '$script:ClineUsageUrl = ''https://api.cline.bot/api/v1/users/me/plan/usage-limits'''
$definitions += '$script:ClineRefreshUrl = ''https://api.cline.bot/api/v1/auth/refresh'''
. ([ScriptBlock]::Create(($definitions -join [Environment]::NewLine)))
$dir = Join-Path $env:TEMP ('cline-provider-test-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $dir -Force | Out-Null
$script:ClineProvidersPath = Join-Path $dir 'providers.json'
$script:SecureSnapshotRoot = Join-Path $dir 'snapshots'
try {
    $future = [DateTimeOffset]::UtcNow.AddHours(2).ToUnixTimeMilliseconds()
    $raw = '{"version":1,"providers":{"cline":{"settings":{"provider":"cline","auth":{"accessToken":"workos:test-access","refreshToken":"test-refresh","expiresAt":' + $future + ',"accountId":"acct"}}}}}'
    [IO.File]::WriteAllText($script:ClineProvidersPath, $raw, [Text.UTF8Encoding]::new($false))

    Assert-Eq (Test-ClineCredExists) 'True' 'the provider file is detected'
    $auth = Read-ClineAuth
    Assert-Eq $auth.AccessToken 'workos:test-access' 'the access token is read'
    Assert-Eq $auth.Path $script:ClineProvidersPath 'the active credential keeps its source path'
    Assert-Eq (Get-ClineRowName $auth) (Get-AccountFingerprint -AccountId 'acct' -Prefix 'Cline') 'the row label is a short account fingerprint'

    $registeredResult = Add-CurrentClineAccount
    Assert-Eq $registeredResult.Status 'registered' 'a new account reports registration success'
    $sameResult = Add-CurrentClineAccount
    Assert-Eq $sameResult.Status 'same-account' 'registering the unchanged CLI account reports no new row'
    $registered = @(Get-ClineAccounts)
    Assert-Eq $registered.Count '1' 'the active account is registered without duplication'
    Assert-Eq (Test-Path -LiteralPath (Get-ClineSnapshotPath 'acct')) 'True' 'registration writes a protected snapshot'

    $script:responses = @('{"success":true,"data":{"limits":[{"type":"five_hour","percentUsed":4,"resetsAt":"2026-09-21T14:00:00Z"},{"type":"weekly","percentUsed":31,"resetsAt":"2026-09-28T09:00:00Z"},{"type":"monthly","percentUsed":64,"resetsAt":"2026-10-21T09:00:00Z"}]}}' | ConvertFrom-Json)
    $script:calls = @()
    $script:callIndex = 0
    $row = Get-ClineRowData -Auth $auth -Name 'Cline'
    Assert-Eq $script:calls[0].Uri 'https://api.cline.bot/api/v1/users/me/plan/usage-limits' 'usage is read from the dashboard limit endpoint'
    Assert-Eq $script:calls[0].Auth 'Bearer workos:test-access' 'the request carries the workos-prefixed OAuth token'
    Assert-Eq $row.Percent '64' 'the row uses the tightest quota window'
    Assert-Eq ($row.Detail -like '5h 4%*week 31%*month 64%*') 'True' 'the detail includes all three windows'
    Assert-Eq ([bool]$row.ResetAt) 'True' 'the reset stamp is retained'

    $expired = [DateTimeOffset]::UtcNow.AddMinutes(-5).ToUnixTimeMilliseconds()
    $raw = '{"version":1,"providers":{"cline":{"settings":{"provider":"cline","auth":{"accessToken":"workos:old","refreshToken":"old-refresh","expiresAt":' + $expired + ',"accountId":"acct"}}}}}'
    [IO.File]::WriteAllText($script:ClineProvidersPath, $raw, [Text.UTF8Encoding]::new($false))
    [void](Write-SecureSnapshot -Provider cline -AccountId 'acct' -Value ($raw | ConvertFrom-Json))
    $script:responses = @(
        ('{"success":true,"data":{"accessToken":"fresh-token","refreshToken":"fresh-refresh","expiresAt":"2099-01-01T00:00:00Z","tokenType":"Bearer"}}' | ConvertFrom-Json),
        ('{"success":true,"data":{"limits":[{"type":"weekly","percentUsed":12,"resetsAt":"2026-09-28T09:00:00Z"}]}}' | ConvertFrom-Json)
    )
    $script:calls = @()
    $script:callIndex = 0
    $row = Get-ClineRowData -Name 'Cline'
    Assert-Eq $script:calls[0].Method 'Post' 'an expired token is refreshed'
    Assert-Eq $script:calls[0].Uri 'https://api.cline.bot/api/v1/auth/refresh' 'the refresh endpoint matches the CLI contract'
    Assert-Eq $script:calls[0].ContentType 'application/json' 'the refresh request is JSON'
    Assert-Eq ($script:calls[0].Body -like '*"refreshToken":"old-refresh"*') 'True' 'the stored refresh token is sent'
    Assert-Eq ($script:calls[0].Body -like '*"grantType":"refresh_token"*') 'True' 'the refresh grant type is sent'
    Assert-Eq $script:calls[1].Auth 'Bearer workos:fresh-token' 'the refreshed token is prefixed for API use'
    Assert-Eq $row.Percent '12' 'the refreshed token then fetches usage'

    $saved = Get-Content -LiteralPath $script:ClineProvidersPath -Raw -Encoding utf8 | ConvertFrom-Json
    Assert-Eq $saved.providers.cline.settings.auth.accessToken 'workos:fresh-token' 'the refreshed access token is saved'
    Assert-Eq $saved.providers.cline.settings.auth.refreshToken 'fresh-refresh' 'the rotated refresh token is saved'
    Assert-Eq ($saved.providers.cline.settings.auth.expiresAt -gt 4000000000000) 'True' 'the refreshed expiry is saved as epoch milliseconds'

    $secondFuture = [DateTimeOffset]::UtcNow.AddHours(2).ToUnixTimeMilliseconds()
    $secondRaw = '{"version":1,"providers":{"cline":{"settings":{"provider":"cline","auth":{"accessToken":"workos:second","refreshToken":"second-refresh","expiresAt":' + $secondFuture + ',"accountId":"acct-2"}}}}}' | ConvertFrom-Json
    [void](Write-SecureSnapshot -Provider cline -AccountId 'acct-2' -Value $secondRaw)
    $accounts = @(Get-ClineAccounts)
    Assert-Eq $accounts.Count '2' 'the active account and one snapshot are both listed'
    Assert-Eq (@($accounts | ForEach-Object { Get-ClineRowId $_ } | Sort-Object -Unique).Count) '2' 'registered accounts keep distinct row ids'
    Assert-Eq (@($accounts | ForEach-Object { Get-ClineRowName $_ } | Sort-Object -Unique).Count) '2' 'registered accounts keep distinct row labels'

    $second = $accounts | Where-Object { $_.AccountId -eq 'acct-2' } | Select-Object -First 1
    $script:responses = @('{"success":true,"data":{"limits":[{"type":"weekly","percentUsed":8,"resetsAt":"2026-09-28T09:00:00Z"}]}}' | ConvertFrom-Json)
    $script:calls = @()
    $script:callIndex = 0
    $row = Get-ClineRowData -Auth $second -Name (Get-ClineRowName $second)
    Assert-Eq $script:calls[0].Auth 'Bearer workos:second' 'a snapshot row uses its own token'
    Assert-Eq $row.Percent '8' 'a snapshot row reads its own quota'

    $expired = [DateTimeOffset]::UtcNow.AddMinutes(-5).ToUnixTimeMilliseconds()
    $expiredSecond = '{"version":1,"providers":{"cline":{"settings":{"provider":"cline","auth":{"accessToken":"workos:second-old","refreshToken":"second-old-refresh","expiresAt":' + $expired + ',"accountId":"acct-2"}}}}}' | ConvertFrom-Json
    [void](Write-SecureSnapshot -Provider cline -AccountId 'acct-2' -Value $expiredSecond)
    $expiredAuth = Read-ClineAuth -Path (Get-ClineSnapshotPath 'acct-2')
    $script:responses = @(
        ('{"success":true,"data":{"accessToken":"second-fresh","refreshToken":"second-fresh-refresh","expiresAt":"2099-01-01T00:00:00Z"}}' | ConvertFrom-Json),
        ('{"success":true,"data":{"limits":[{"type":"weekly","percentUsed":9,"resetsAt":"2026-09-28T09:00:00Z"}]}}' | ConvertFrom-Json)
    )
    $script:calls = @()
    $script:callIndex = 0
    [void](Get-ClineRowData -Auth $expiredAuth -Name (Get-ClineRowName $expiredAuth))
    $savedSnapshot = Read-SecureSnapshot -Path (Get-ClineSnapshotPath 'acct-2')
    Assert-Eq $savedSnapshot.providers.cline.settings.auth.accessToken 'workos:second-fresh' 'a refreshed snapshot keeps its own rotated token'
    Assert-Eq $savedSnapshot.providers.cline.settings.auth.refreshToken 'second-fresh-refresh' 'a refreshed snapshot keeps its rotated refresh token'

    $activeClineA = Read-ClineAuth -Path $script:ClineProvidersPath
    $activeClineA.AccessToken = 'workos:active-a-fresh'
    $activeClineA.RefreshToken = 'active-a-fresh-refresh'
    $activeClineA.ExpiresAt = [datetime]::UtcNow.AddHours(3)
    $clineB = '{"version":1,"marker":"keep-b","providers":{"cline":{"settings":{"provider":"cline","auth":{"accessToken":"workos:live-b","refreshToken":"live-b-refresh","expiresAt":' + $future + ',"accountId":"acct-b"}}}}}'
    [IO.File]::WriteAllText($script:ClineProvidersPath, $clineB, [Text.UTF8Encoding]::new($false))
    Save-ClineAuth $activeClineA
    $clineLiveAfter = Get-Content -LiteralPath $script:ClineProvidersPath -Raw -Encoding utf8 | ConvertFrom-Json
    Assert-Eq $clineLiveAfter.providers.cline.settings.auth.accessToken 'workos:live-b' 'cline account switch keeps the live B token'
    Assert-Eq $clineLiveAfter.marker 'keep-b' 'cline account switch preserves unrelated live fields'
    $clineSnapA = Read-SecureSnapshot -Path (Get-ClineSnapshotPath 'acct')
    Assert-Eq $clineSnapA.providers.cline.settings.auth.accessToken 'workos:active-a-fresh' 'cline switched refresh is stored in the A snapshot'

    Remove-Item -LiteralPath $script:ClineProvidersPath -Force
    Assert-Eq (Test-ClineCredExists) 'True' 'registered snapshots remain visible without the active CLI file'
    Remove-Item -LiteralPath $script:SecureSnapshotRoot -Recurse -Force
    Assert-Eq (Test-ClineCredExists) 'False' 'no active file and no snapshots produces no row'
} finally {
    Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
}

# ---------- row and worker wiring ----------
Assert-Eq ($entryText -match "Kind\s*=\s*'cline'") 'True' 'the provider contributes a row'
Assert-Eq ($entryText -match 'Test-ClineCredExists') 'True' 'the row is gated by the Cline credential'
Assert-Eq ($entryText -match "\$script:ClineUsagePageUrl = 'https://") 'True' 'the usage page is an https URL'
Assert-Eq ($entryText -match 'miOpenCline') 'True' 'the context menu can open the usage page'
Assert-Eq ($entryText -match 'miAddCline') 'True' 'the context menu can register the current account'
Assert-Eq ($entryText -match 'New-SettingCheckBox \$dialog ''Cline''') 'True' 'the settings dialog can switch the provider off'
Assert-Eq ($entryText -match 'cline\s+= \[bool\]\$chkCline\.Checked') 'True' 'the settings dialog saves the switch'

$fnNames = @()
$vNames = @()
$match = [regex]::Match($entryText, '(?s)function Get-WorkerScriptSource \{.*?\$fnNames = @\((.*?)\)')
if ($match.Success) { $fnNames = @([regex]::Matches($match.Groups[1].Value, "'([^']+)'") | ForEach-Object { $_.Groups[1].Value }) }
$match2 = [regex]::Match($entryText, '(?s)foreach \(\$v in (.*?)\) \{')
if ($match2.Success) { $vNames = @([regex]::Matches($match2.Groups[1].Value, "'([^']+)'") | ForEach-Object { $_.Groups[1].Value }) }
foreach ($name in @('Convert-ClineUsageLimits', 'Get-ClineAuthEntry', 'Convert-ClineRawAuth', 'Get-ClineUsageSnapshot', 'Get-ClineRowData', 'Update-ClineToken')) {
    Assert-Eq ($fnNames -contains $name) 'True' ('worker forwards ' + $name)
}
foreach ($name in @('ClineProvidersPath', 'ClineUsageUrl', 'ClineRefreshUrl', 'ClineDisplayName')) {
    Assert-Eq ($vNames -contains $name) 'True' ('worker forwards ' + $name)
}
Assert-Eq ($entryText -match '''cline'' \{ \$d = Get-ClineRowData') 'True' 'worker dispatch handles the cline kind'
Assert-Eq ($entryText -match 'ClineProvidersPath\s+= \$script:ClineProvidersPath') 'True' 'the worker config table carries the Cline paths'

if ($failed -gt 0) {
    Write-Host ("FAILED {0}" -f $failed)
    exit 1
}
Write-Host 'ALL PASSED'
exit 0
