# Encoding: UTF-8 with BOM. Run: powershell -NoProfile -File .\test-CopilotQuota.ps1
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $here 'UsageValidation.ps1')
. (Join-Path $here 'CopilotQuota.ps1')

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

# ---------- 单个配额窗口 ----------
$detail = Convert-CopilotQuotaDetail ([pscustomobject]@{ entitlement = 300; remaining = 171 })
Assert-Eq $detail.UsedPercent 43 'premium used percent'
Assert-Eq $detail.Remaining 171 'premium remaining'
Assert-Eq $detail.Entitlement 300 'premium entitlement'
Assert-Eq $detail.Unlimited 'False' 'premium is limited'

$unlimited = Convert-CopilotQuotaDetail ([pscustomobject]@{ entitlement = 0; remaining = 0; unlimited = $true })
Assert-Eq $unlimited.Unlimited 'True' 'unlimited flag kept'
Assert-Eq $unlimited.UsedPercent 0 'unlimited shows zero usage'

$fallback = Convert-CopilotQuotaDetail ([pscustomobject]@{ percent_remaining = 57.0 })
Assert-Eq $fallback.UsedPercent 43 'percent_remaining fallback'

$overspent = Convert-CopilotQuotaDetail ([pscustomobject]@{ entitlement = 100; remaining = 0 })
Assert-Eq $overspent.UsedPercent 100 'used percent clamps at one hundred'

$empty = Convert-CopilotQuotaDetail ([pscustomobject]@{})
Assert-Eq $empty.UsedPercent 0 'empty detail is zero'
Assert-Eq $empty.Entitlement 0 'empty entitlement is zero'

Assert-Eq (Convert-CopilotQuotaDetail $null) '' 'null detail is null'

# ---------- 完整载荷 ----------
$payload = [pscustomobject]@{
    copilot_plan     = 'individual'
    quota_reset_date = '2026-10-01'
    quota_snapshots  = [pscustomobject]@{
        premium_interactions = [pscustomobject]@{ entitlement = 300; remaining = 171; percent_remaining = 57.0; unlimited = $false }
        chat                 = [pscustomobject]@{ entitlement = 0; remaining = 0; unlimited = $true }
        completions          = [pscustomobject]@{ entitlement = 100; remaining = 100; unlimited = $false }
    }
}
$quota = Convert-CopilotQuota $payload
Assert-Eq $quota.Plan 'individual' 'plan parsed'
Assert-Eq $quota.Premium.UsedPercent 43 'premium percent parsed'
Assert-Eq $quota.Chat.Unlimited 'True' 'chat unlimited parsed'
Assert-Eq $quota.Completions.UsedPercent 0 'completions untouched'
Assert-Eq $quota.ResetAt.ToString('yyyy-MM-dd') '2026-10-01' 'reset date parsed'

Assert-Eq (Convert-CopilotQuota ([pscustomobject]@{ copilot_plan = 'business' })).Premium '' 'missing snapshots give null premium'
Assert-Eq (Convert-CopilotResetDate 'not-a-date') '' 'junk reset date is null'
Assert-Eq (Convert-CopilotQuota $null) '' 'null payload is null'

# ---------- token 读取 ----------
$hostsJson = '{ "github.com": { "user": "octocat", "oauth_token": "ghu_hosts" } }' | ConvertFrom-Json
Assert-Eq (Find-CopilotToken $hostsJson) 'ghu_hosts' 'hosts.json token'

$appsJson = '{ "github.com": { "githubAppId": "1" }, "other": { "access_token": "ghu_apps" } }' | ConvertFrom-Json
Assert-Eq (Find-CopilotToken $appsJson) 'ghu_apps' 'apps.json token'

$openCode = '{ "github-copilot": { "type": "oauth", "access": "ghu_opencode", "refresh": "x" } }' | ConvertFrom-Json
Assert-Eq (Find-CopilotToken $openCode) 'ghu_opencode' 'opencode token'

$priority = '{ "github.com": { "oauth_token": "ghu_primary", "access": "ghu_secondary" } }' | ConvertFrom-Json
Assert-Eq (Find-CopilotToken $priority) 'ghu_primary' 'oauth_token wins over access'

$nonString = '{ "github.com": { "oauth_token": 12345 } }' | ConvertFrom-Json
Assert-Eq (Find-CopilotToken $nonString) '' 'non-string token ignored'

$blank = '{ "github.com": { "oauth_token": "   " } }' | ConvertFrom-Json
Assert-Eq (Find-CopilotToken $blank) '' 'blank token ignored'

Assert-Eq (Find-CopilotToken $null) '' 'null payload has no token'
Assert-Eq (Find-CopilotToken ([pscustomobject]@{ github = [pscustomobject]@{ user = 'x' } })) '' 'payload without token returns empty'

$hashToken = @{ 'github.com' = @{ oauth_token = 'ghu_hash' } }
Assert-Eq (Find-CopilotToken $hashToken) 'ghu_hash' 'hashtable payload token'

if ($failed -gt 0) {
    Write-Host ("FAILED {0}" -f $failed)
    exit 1
}
Write-Host 'ALL PASSED'
exit 0