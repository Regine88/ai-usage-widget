# Run: powershell -NoProfile -File .\test-ClineQuota.ps1
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $here 'UsageValidation.ps1')
. (Join-Path $here 'ClineQuota.ps1')

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

# ---------- quota payload ----------
$payload = '{"success":true,"data":{"limits":[{"type":"five_hour","percentUsed":1,"resetsAt":"2026-09-21T14:29:17.463Z"},{"type":"weekly","percentUsed":55.26,"resetsAt":"2026-09-28T09:29:17.465Z"},{"type":"monthly","percentUsed":0,"resetsAt":"2026-10-21T09:29:17.467Z"}]}}' | ConvertFrom-Json
$usage = Convert-ClineUsageLimits $payload
Assert-Eq $usage.Percent '55.3' 'weekly usage is rounded and used as the overall percentage'
Assert-Eq $usage.FiveHour.Percent '1' 'the five-hour window is parsed'
Assert-Eq $usage.Weekly.Percent '55.3' 'the weekly window is parsed'
Assert-Eq $usage.Monthly.Percent '0' 'the monthly window is parsed'
Assert-Eq $usage.ResetAt.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ') '2026-09-28T09:29:17Z' 'the overall reset follows the tightest window'
Assert-Eq ($null -ne $usage.FetchedAt) 'True' 'the parsed snapshot keeps a fetch time'

$five = '{"data":{"limits":[{"type":"five_hour","percentUsed":80,"resetsAt":"2026-09-21T14:00:00Z"},{"type":"weekly","percentUsed":12},{"type":"monthly","percentUsed":0}]}}' | ConvertFrom-Json
$tight = Convert-ClineUsageLimits $five
Assert-Eq $tight.Percent '80' 'the five-hour window can drive the overall percentage'
Assert-Eq $tight.ResetAt.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ') '2026-09-21T14:00:00Z' 'the matching window supplies the reset time'

$one = '{"limits":[{"type":"weekly","percentUsed":100,"resetsAt":1790000000}]}' | ConvertFrom-Json
$only = Convert-ClineUsageLimits $one
Assert-Eq $only.Percent '100' 'a single weekly window is accepted'
Assert-Eq ($null -ne $only.ResetAt) 'True' 'numeric reset seconds are accepted'

# ---------- validation ----------
$threw = $false
try { [void](Convert-ClineUsageLimits ('{"data":{}}' | ConvertFrom-Json)) } catch { $threw = $true }
Assert-Eq $threw 'True' 'a payload without limits is rejected'

$threw = $false
try { [void](Convert-ClineUsageLimits ('{"data":{"limits":[{"type":"weekly","percentUsed":101}]}}' | ConvertFrom-Json)) } catch { $threw = $true }
Assert-Eq $threw 'True' 'a percentage above 100 is rejected'

$threw = $false
try { [void](Convert-ClineUsageLimits ('{"data":{"limits":[{"type":"unknown","percentUsed":10}]}}' | ConvertFrom-Json)) } catch { $threw = $true }
Assert-Eq $threw 'True' 'an unknown quota type is rejected'

# ---------- credentials ----------
$raw = '{"version":1,"providers":{"cline":{"settings":{"provider":"cline","auth":{"accessToken":"workos:access","refreshToken":"refresh","expiresAt":1790000000000,"accountId":"acct"}}},"cline-pass":{"settings":{"auth":{"accessToken":"fallback"}}}}}' | ConvertFrom-Json
$auth = Convert-ClineRawAuth $raw
Assert-Eq $auth.AccessToken 'workos:access' 'the canonical cline provider is preferred'
Assert-Eq $auth.RefreshToken 'refresh' 'the refresh token is read'
Assert-Eq $auth.AccountId 'acct' 'the account id is read'
Assert-Eq $auth.ProviderName 'cline' 'the selected provider is retained'
Assert-Eq (ConvertTo-ClineStoredAccessToken 'plain') 'workos:plain' 'raw access tokens get the API prefix'
Assert-Eq (ConvertTo-ClineStoredAccessToken 'workos:plain') 'workos:plain' 'an existing prefix is not duplicated'

$fallbackRaw = '{"providers":{"cline-pass":{"settings":{"auth":{"accessToken":"fallback"}}}}}' | ConvertFrom-Json
Assert-Eq (Convert-ClineRawAuth $fallbackRaw).AccessToken 'workos:fallback' 'cline-pass credentials are a fallback'

$threw = $false
try { [void](Convert-ClineRawAuth ('{"providers":{}}' | ConvertFrom-Json)) } catch { $threw = $true }
Assert-Eq $threw 'True' 'a provider file without credentials is rejected'

$expiry = Convert-ClineAuthExpiry 1790000000000
Assert-Eq ($expiry -is [datetime]) 'True' 'epoch-millisecond expiry is parsed'

if ($failed -gt 0) {
    Write-Host ("FAILED {0}" -f $failed)
    exit 1
}
Write-Host 'ALL PASSED'
exit 0
