# Encoding: UTF-8 with BOM. Run: powershell -NoProfile -File .\test-ClaudeQuota.ps1
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $here 'UsageValidation.ps1')
. (Join-Path $here 'ClaudeQuota.ps1')

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
function Assert-Throws {
    param([scriptblock]$Action, [string]$Name)
    try { & $Action; Write-Host ("FAIL {0}: expected throw" -f $Name); $script:failed++ }
    catch { Write-Host ("OK   {0}" -f $Name) }
}

$payload = @{
    five_hour = @{ utilization = 19; resets_at = '2026-09-18T15:00:00Z' }
    seven_day = @{ utilization = 45; resets_at = '2026-09-24T12:00:00Z' }
} | ConvertTo-Json -Depth 6 | ConvertFrom-Json
$u = Convert-ClaudeUsage $payload
Assert-Eq $u.Percent '45' 'the bar follows the tighter window'
Assert-Eq $u.FiveHour.Percent '19' '5h window is kept'
Assert-Eq $u.Weekly.Percent '45' 'weekly window is kept'
Assert-Eq ($null -ne $u.ResetAt) 'True' 'a reset stamp is parsed'

$onlyFive = @{ five_hour = @{ utilization = 0; resets_at = '2026-09-18T15:00:00Z' } } | ConvertTo-Json -Depth 6 | ConvertFrom-Json
Assert-Eq (Convert-ClaudeUsage $onlyFive).Percent '0' 'explicit zero stays zero'

Assert-Throws { Convert-ClaudeUsage $null } 'null payload throws'
Assert-Throws { Convert-ClaudeUsage (@{ seven_day = @{ utilization = 120 } } | ConvertTo-Json | ConvertFrom-Json) } 'over-100 throws'
Assert-Throws { Convert-ClaudeUsage (@{} | ConvertTo-Json | ConvertFrom-Json) } 'empty payload throws'

$auth = Convert-ClaudeRawAuth (@{
    claudeAiOauth = @{ accessToken = 'tok-a'; refreshToken = 'ref-a'; expiresAt = 1893456000000 }
} | ConvertTo-Json -Depth 6 | ConvertFrom-Json)
Assert-Eq $auth.AccessToken 'tok-a' 'oauth access token is read'
Assert-Eq $auth.RefreshToken 'ref-a' 'oauth refresh token is read'
Assert-Eq ($null -ne $auth.ExpiresAt) 'True' 'ms expiry is converted'

$snake = Convert-ClaudeRawAuth (@{
    oauth = @{ access_token = 'tok-b'; refresh_token = 'ref-b' }
} | ConvertTo-Json -Depth 6 | ConvertFrom-Json)
Assert-Eq $snake.AccessToken 'tok-b' 'snake_case oauth is accepted'

Assert-Throws { Convert-ClaudeRawAuth (@{} | ConvertTo-Json | ConvertFrom-Json) } 'missing oauth throws'

if ($failed -gt 0) { Write-Host ("FAILED {0}" -f $failed); exit 1 }
Write-Host 'ALL PASSED'
exit 0
