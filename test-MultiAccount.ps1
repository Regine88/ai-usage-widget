# Encoding: UTF-8 with BOM.
# Run: powershell -NoProfile -File .\test-MultiAccount.ps1
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $here 'UsageValidation.ps1')
. (Join-Path $here 'SecureSnapshot.ps1')
. (Join-Path $here 'ApiKeyAuth.ps1')
. (Join-Path $here 'WidgetStrings.ps1')
. (Join-Path $here 'WidgetFormat.ps1')
. (Join-Path $here 'ClaudeQuota.ps1')
. (Join-Path $here 'KimiQuota.ps1')
. (Join-Path $here 'CommandCodeQuota.ps1')
. (Join-Path $here 'CopilotQuota.ps1')
. (Join-Path $here 'ZaiQuota.ps1')

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

$names = @(
    'Find-MatchingSnapshotAccount', 'Get-ProviderRowId', 'Get-ProviderRowName', 'Add-CurrentSnapshotAccount',
    'Get-KimiAccountId', 'Convert-KimiRawAuth', 'Read-KimiAuthFromFile', 'Read-KimiAuth', 'Get-KimiSnapshotAuths',
    'Get-KimiAccounts', 'Add-CurrentKimiAccount', 'Set-KimiAuthFields', 'Save-KimiSnapshot',
    'Get-KimiHosts', 'Get-KimiUsageSnapshot', 'Invoke-KimiGet', 'Update-KimiToken', 'Save-KimiAuth',
    'Test-CommandCodeCredExists', 'Read-CommandCodeAuth', 'Get-CommandCodeAccounts', 'Get-CommandCodeAuthHeaders', 'Invoke-CommandCodeGet', 'Get-CommandCodeUsageSnapshot',
    'Test-ClaudeCredExists', 'Read-ClaudeAuthFromFile', 'Get-ClaudeSnapshotAuths', 'Get-ClaudeAccounts',
    'Set-ClaudeAuthFields', 'Save-ClaudeSnapshot', 'Save-ClaudeAuth', 'Get-ClaudeAuthHeaders',
    'Get-TokenEmail', 'Convert-CodexRawAuth', 'Read-CodexAuth', 'Get-SnapshotPath', 'Set-CodexAuthFields', 'Save-CodexAuth',
    'Read-CursorSnapshot', 'Get-CursorAccounts',
    'Get-ZaiZcodeKey', 'Get-ZaiActiveAuth', 'Read-ZaiSnapshot', 'Get-ZaiAccounts', 'Resolve-ZaiCredential', 'Get-ZaiAuthHeaders', 'Get-ZaiUsageSnapshot',
    'Get-CopilotAuthToken', 'Convert-CopilotAuth', 'Read-CopilotSnapshot', 'Get-CopilotAccounts', 'Read-CopilotTokenFromFile', 'Get-CopilotToken', 'Get-CopilotAuthHeaders', 'Get-CopilotUsageSnapshot'
)
$entry = Join-Path $here 'AiUsageWidget.ps1'
$definitions = @()
foreach ($name in $names) { $definitions += (Get-ScriptFunctionDefinition $entry $name) }
. ([ScriptBlock]::Create(($definitions -join [Environment]::NewLine)))

$script:WidgetStrings = Read-WidgetStrings -Language 'en-US' -Dir $here
$script:responses = @()
$script:calls = @()
$script:callIndex = 0
function Invoke-WidgetRest {
    param($Method, $Uri, $Headers, $Body, $ContentType, $TimeoutSec)
    $auth = $null
    if ($Headers) { $auth = [string]$Headers['Authorization'] }
    $script:calls += [pscustomobject]@{ Method = $Method; Uri = $Uri; Auth = $auth }
    if ($script:callIndex -ge @($script:responses).Count) { throw 'unexpected request' }
    $response = @($script:responses)[$script:callIndex]
    $script:callIndex++
    return $response
}
function Write-WidgetLog { param([string]$Message) }
function Get-HttpStatusCode { param($ErrorRecord) return 500 }

$dir = Join-Path $env:TEMP ('multi-account-test-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $dir -Force | Out-Null
$script:SecureSnapshotRoot = Join-Path $dir 'snapshots'
try {
    $script:KimiCredPath = Join-Path $dir 'kimi-code.json'
    $script:KimiRegionPath = Join-Path $dir 'no-region'
    $script:KimiOAuthClientId = 'kimi-client'
    $future = [DateTimeOffset]::UtcNow.AddHours(4).ToUnixTimeSeconds()
    $kimiA = '{"access_token":"kimi-a","refresh_token":"kimi-refresh-a","expires_at":' + $future + ',"user_id":"user-a"}'
    [IO.File]::WriteAllText($script:KimiCredPath, $kimiA, [Text.UTF8Encoding]::new($false))
    $added = Add-CurrentKimiAccount
    Assert-Eq $added.Status 'registered' 'kimi registration stores the current login'
    Assert-Eq (Add-CurrentKimiAccount).Status 'same-account' 'registering the same kimi login does not add a row'
    $kimiB = '{"access_token":"kimi-b","refresh_token":"kimi-refresh-b","expires_at":' + $future + ',"user_id":"user-b"}' | ConvertFrom-Json
    [void](Write-SecureSnapshot -Provider kimi -AccountId 'user-b' -Value $kimiB)
    $kimiAccounts = @(Get-KimiAccounts)
    Assert-Eq $kimiAccounts.Count '2' 'kimi lists the live login and the registered snapshot'
    Assert-Eq (@($kimiAccounts | ForEach-Object { Get-ProviderRowId $_ 'kimi' } | Sort-Object -Unique).Count) '2' 'kimi accounts keep distinct row ids'
    $snapB = $kimiAccounts | Where-Object { $_.AccountId -eq 'user-b' } | Select-Object -First 1
    $script:responses = @('{"usage":{"limit":100,"used":10,"remaining":90,"reset_at":"2026-09-28T00:00:00Z"}}' | ConvertFrom-Json)
    $script:calls = @()
    $script:callIndex = 0
    try { [void](Get-KimiUsageSnapshot -Auth $snapB) } catch { }
    Assert-Eq $script:calls[0].Auth 'Bearer kimi-b' 'a kimi snapshot requests usage with its own token'

    $activeKimiA = Read-KimiAuth
    $kimiBWithMarker = '{"access_token":"kimi-b-live","refresh_token":"kimi-refresh-b-live","expires_at":' + $future + ',"user_id":"user-b","marker":"keep-b"}' | ConvertFrom-Json
    [IO.File]::WriteAllText($script:KimiCredPath, ($kimiBWithMarker | ConvertTo-Json -Depth 6 -Compress), [Text.UTF8Encoding]::new($false))
    $activeKimiA.Token = 'kimi-a-fresh'
    $activeKimiA.Refresh = 'kimi-refresh-a-fresh'
    $activeKimiA.ExpiresAt = [datetime]::UtcNow.AddHours(3)
    Save-KimiAuth $activeKimiA
    $kimiLiveAfter = Get-Content -LiteralPath $script:KimiCredPath -Raw -Encoding utf8 | ConvertFrom-Json
    Assert-Eq $kimiLiveAfter.access_token 'kimi-b-live' 'kimi account switch keeps the live B token'
    Assert-Eq $kimiLiveAfter.refresh_token 'kimi-refresh-b-live' 'kimi account switch keeps the live B refresh token'
    Assert-Eq $kimiLiveAfter.marker 'keep-b' 'kimi account switch preserves unrelated live fields'
    $kimiSnapA = Read-SecureSnapshot -Path (Get-SecureSnapshotPath -Provider kimi -AccountId 'user-a')
    Assert-Eq $kimiSnapA.access_token 'kimi-a-fresh' 'kimi switched refresh is stored in the A snapshot'
    Assert-Eq $kimiSnapA.refresh_token 'kimi-refresh-a-fresh' 'kimi switched refresh token is stored in the A snapshot'

    $pendingKimiB = Read-KimiAuth
    $newerKimiB = '{"access_token":"newer-client-b","refresh_token":"newer-client-b-refresh","expires_at":' + $future + ',"user_id":"user-b","marker":"keep-newer"}' | ConvertFrom-Json
    [IO.File]::WriteAllText($script:KimiCredPath, ($newerKimiB | ConvertTo-Json -Depth 6 -Compress), [Text.UTF8Encoding]::new($false))
    $pendingKimiB.Token = 'late-worker-b'
    $pendingKimiB.Refresh = 'late-worker-b-refresh'
    Save-KimiAuth $pendingKimiB
    $newerAfter = Get-Content -LiteralPath $script:KimiCredPath -Raw -Encoding utf8 | ConvertFrom-Json
    Assert-Eq $newerAfter.access_token 'newer-client-b' 'a stale same-account Kimi refresh cannot overwrite newer credentials'
    Assert-Eq $newerAfter.marker 'keep-newer' 'a stale same-account Kimi refresh preserves newer fields'

    $script:CommandCodeAuthPath = Join-Path $dir 'commandcode.json'
    $script:CommandCodeApiBaseUrl = 'https://api.commandcode.ai'
    [IO.File]::WriteAllText($script:CommandCodeAuthPath, '{"apiKey":"cc-a","userId":"org-user-a"}', [Text.UTF8Encoding]::new($false))
    $ccB = '{"apiKey":"cc-b","userId":"org-user-b"}' | ConvertFrom-Json
    [void](Write-SecureSnapshot -Provider commandcode -AccountId 'org-user-b' -Value $ccB)
    $ccAccounts = @(Get-CommandCodeAccounts)
    Assert-Eq $ccAccounts.Count '2' 'command code lists both accounts'
    $ccSnap = $ccAccounts | Where-Object { $_.AccountId -eq 'org-user-b' } | Select-Object -First 1
    Assert-Eq $ccSnap.ApiKey 'cc-b' 'the command code snapshot keeps its own key'

    $script:ClaudeCredPath = Join-Path $dir 'claude.json'
    [IO.File]::WriteAllText($script:ClaudeCredPath, '{"claudeAiOauth":{"accessToken":"claude-a","refreshToken":"claude-refresh-a","accountUuid":"claude-user-a"}}', [Text.UTF8Encoding]::new($false))
    $claudeB = '{"claudeAiOauth":{"accessToken":"claude-b","refreshToken":"claude-refresh-b","accountUuid":"claude-user-b"}}' | ConvertFrom-Json
    [void](Write-SecureSnapshot -Provider claude -AccountId 'claude-user-b' -Value $claudeB)
    $claudeAccounts = @(Get-ClaudeAccounts)
    Assert-Eq $claudeAccounts.Count '2' 'claude lists both accounts'
    $claudeSnap = $claudeAccounts | Where-Object { $_.AccountId -eq 'claude-user-b' } | Select-Object -First 1
    Assert-Eq $claudeSnap.AccessToken 'claude-b' 'the claude snapshot keeps its own access token'
    Assert-Eq $claudeSnap.Source 'snapshot' 'the second claude account comes from a snapshot'

    $claudePath = Join-Path $dir 'claude-live.json'
    [IO.File]::WriteAllText($claudePath, '{"claudeAiOauth":{"accessToken":"claude-live-a","refreshToken":"claude-live-refresh-a","accountUuid":"claude-user-a"}}', [Text.UTF8Encoding]::new($false))
    $activeClaudeA = Read-ClaudeAuthFromFile -Path $claudePath
    [IO.File]::WriteAllText($claudePath, '{"claudeAiOauth":{"accessToken":"claude-live-b","refreshToken":"claude-live-refresh-b","accountUuid":"claude-user-b"},"marker":"keep-b"}', [Text.UTF8Encoding]::new($false))
    $activeClaudeA.AccessToken = 'claude-a-fresh'
    $activeClaudeA.RefreshToken = 'claude-refresh-a-fresh'
    $activeClaudeA.ExpiresAt = [datetime]::UtcNow.AddHours(3)
    Save-ClaudeAuth $activeClaudeA
    $claudeLiveAfter = Get-Content -LiteralPath $claudePath -Raw -Encoding utf8 | ConvertFrom-Json
    Assert-Eq $claudeLiveAfter.claudeAiOauth.accessToken 'claude-live-b' 'claude account switch keeps the live B token'
    Assert-Eq $claudeLiveAfter.marker 'keep-b' 'claude account switch preserves unrelated live fields'
    $claudeSnapA = Read-SecureSnapshot -Path (Get-SecureSnapshotPath -Provider claude -AccountId 'claude-user-a')
    Assert-Eq $claudeSnapA.claudeAiOauth.accessToken 'claude-a-fresh' 'claude switched refresh is stored in the A snapshot'

    $codexPath = Join-Path $dir 'codex-live.json'
    $codexA = [pscustomobject]@{
        tokens = [pscustomobject]@{ access_token = 'codex-a'; refresh_token = 'codex-refresh-a'; account_id = 'codex-user-a'; id_token = $null }
        marker = 'keep-a'
    }
    [IO.File]::WriteAllText($codexPath, ($codexA | ConvertTo-Json -Depth 6 -Compress), [Text.UTF8Encoding]::new($false))
    $activeCodexA = Read-CodexAuth -Path $codexPath
    $codexB = [pscustomobject]@{
        tokens = [pscustomobject]@{ access_token = 'codex-b'; refresh_token = 'codex-refresh-b'; account_id = 'codex-user-b'; id_token = $null }
        marker = 'keep-b'
    }
    [IO.File]::WriteAllText($codexPath, ($codexB | ConvertTo-Json -Depth 6 -Compress), [Text.UTF8Encoding]::new($false))
    Save-CodexAuth -Auth $activeCodexA -AccessToken 'codex-a-fresh' -RefreshToken 'codex-refresh-a-fresh'
    $codexLiveAfter = Get-Content -LiteralPath $codexPath -Raw -Encoding utf8 | ConvertFrom-Json
    Assert-Eq $codexLiveAfter.tokens.access_token 'codex-b' 'codex account switch keeps the live B token'
    Assert-Eq $codexLiveAfter.marker 'keep-b' 'codex account switch preserves unrelated live fields'
    $codexSnapA = Read-SecureSnapshot -Path (Get-SnapshotPath 'codex-user-a')
    Assert-Eq $codexSnapA.tokens.access_token 'codex-a-fresh' 'codex switched refresh is stored in the A snapshot'

    $script:CursorStateDbPath = Join-Path $dir 'missing-state.vscdb'
    $cursorB = [pscustomobject]@{ accessToken = 'cursor-b'; accountId = 'cursor-user-b' }
    [void](Write-SecureSnapshot -Provider cursor -AccountId 'cursor-user-b' -Value $cursorB)
    $cursorAccounts = @(Get-CursorAccounts)
    Assert-Eq $cursorAccounts.Count '1' 'cursor snapshots remain when the editor database is absent'
    Assert-Eq $cursorAccounts[0].AccessToken 'cursor-b' 'the cursor snapshot keeps its own token'

    $script:ZaiAuthPath = Join-Path $dir 'zai.json'
    $script:ZhipuAuthPath = Join-Path $dir 'missing-zhipu.json'
    $script:BigModelAuthPath = Join-Path $dir 'missing-bigmodel.json'
    $script:ZcodeConfigPath = Join-Path $dir 'missing-zcode.json'
    $script:ZaiApiBaseUrl = 'https://api.z.ai'
    $script:ZhipuApiBaseUrl = 'https://open.bigmodel.cn'
    $env:ZAI_API_KEY = ''
    $env:ZHIPU_API_KEY = ''
    $env:BIGMODEL_API_KEY = ''
    $env:ZAI_API_BASE = ''
    [IO.File]::WriteAllText($script:ZaiAuthPath, '{"apiKey":"glm-a"}', [Text.UTF8Encoding]::new($false))
    $glmB = [pscustomobject]@{ apiKey = 'glm-b'; baseUrl = 'https://open.bigmodel.cn'; accountId = 'key:glm-b' }
    [void](Write-SecureSnapshot -Provider glm -AccountId 'key:glm-b' -Value $glmB)
    $glmAccounts = @(Get-ZaiAccounts)
    Assert-Eq $glmAccounts.Count '2' 'glm lists the live key and the registered key'
    $glmSnap = $glmAccounts | Where-Object { $_.ApiKey -eq 'glm-b' } | Select-Object -First 1
    $script:responses = @('{"data":{"limits":[{"type":"TOKENS_FIVE_HOURS","percentage":9}]}}' | ConvertFrom-Json)
    $script:calls = @()
    $script:callIndex = 0
    try { [void](Get-ZaiUsageSnapshot -Auth $glmSnap) } catch { }
    Assert-Eq $script:calls[0].Uri 'https://open.bigmodel.cn/api/monitor/usage/quota/limit' 'a glm snapshot uses its own host'
    Assert-Eq $script:calls[0].Auth 'glm-b' 'a glm snapshot sends its own key'

    $script:CopilotHostsPath = Join-Path $dir 'hosts.json'
    $script:CopilotAppsPath = Join-Path $dir 'missing-apps.json'
    $script:CopilotOpencodeAuthPath = Join-Path $dir 'missing-opencode.json'
    $script:CopilotUsageUrl = 'https://api.github.com/copilot_internal/user'
    [IO.File]::WriteAllText($script:CopilotHostsPath, '{"github.com":{"oauth_token":"copilot-a"}}', [Text.UTF8Encoding]::new($false))
    $copilotB = [pscustomobject]@{ token = 'copilot-b'; accountId = 'token:copilot-b' }
    [void](Write-SecureSnapshot -Provider copilot -AccountId 'token:copilot-b' -Value $copilotB)
    $copilotAccounts = @(Get-CopilotAccounts)
    Assert-Eq $copilotAccounts.Count '2' 'copilot lists the live token and the registered token'
    $copilotSnap = $copilotAccounts | Where-Object { $_.Token -eq 'copilot-b' } | Select-Object -First 1
    $script:responses = @('{"copilot_plan":"individual","quota_snapshots":{"premium_interactions":{"entitlement":100,"remaining":80}}}' | ConvertFrom-Json)
    $script:calls = @()
    $script:callIndex = 0
    try { [void](Get-CopilotUsageSnapshot -Auth $copilotSnap) } catch { }
    Assert-Eq $script:calls[0].Auth 'token copilot-b' 'a copilot snapshot uses its own token'
} finally {
    Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
}

if ($failed -gt 0) {
    Write-Host ("FAILED {0}" -f $failed)
    exit 1
}
Write-Host 'ALL PASSED'
exit 0
