# Encoding: UTF-8 with BOM.
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $here 'UsageValidation.ps1')

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
    try {
        & $Action
        Write-Host ("FAIL {0}: expected throw" -f $Name)
        $script:failed++
    } catch {
        Write-Host ("OK   {0}" -f $Name)
    }
}

Assert-Eq (Assert-UsagePercent 0) '0' 'explicit zero stays zero'
Assert-Eq (Assert-UsagePercent 42.5) '42.5' 'valid percent'
Assert-Eq ((Get-AccountFingerprint 'Example@Email.test' 'acct').Length) '13' 'account fingerprint is short'
Assert-Throws { Assert-UsagePercent $null } 'missing percent throws'
Assert-Throws { Assert-UsagePercent ([double]::NaN) } 'NaN percent throws'
Assert-Throws { Assert-UsagePercent ([double]::PositiveInfinity) } 'infinity percent throws'
Assert-Throws { Assert-UsagePercent -1 } 'negative percent throws'
Assert-Throws { Assert-UsagePercent 100.1 } 'over-100 percent throws'
Assert-Eq (Convert-SafeLogText ' account@example.com https://example.test/path?token=abc ') 'account[at]example.com https://example.test/path' 'log text redacts email and query'
Assert-Eq (Convert-SafeLogText 'key sk-or-v1-abcdefghijklmnop leftover') 'key sk-[redacted] leftover' 'log text redacts sk-shaped secrets'
Assert-Eq (Assert-TrustedHttpsHost 'https://cli-chat-proxy.grok.com/v1/billing?format=credits') 'https://cli-chat-proxy.grok.com/v1/billing?format=credits' 'trusted host allows query'
Assert-Eq (Assert-TrustedHttpsHost 'https://api.github.com/repos/x/y/releases/latest') 'https://api.github.com/repos/x/y/releases/latest' 'github releases host is trusted'
Assert-Eq (Assert-TrustedHttpsHost 'https://api.anthropic.com/api/oauth/usage') 'https://api.anthropic.com/api/oauth/usage' 'claude usage host is trusted'
Assert-Eq (Assert-TrustedHttpsHost 'https://api2.cursor.sh/aiserver.v1.DashboardService/GetCurrentPeriodUsage') 'https://api2.cursor.sh/aiserver.v1.DashboardService/GetCurrentPeriodUsage' 'cursor usage host is trusted'
Assert-Eq (Assert-TrustedHttpsHost 'https://api.z.ai/api/monitor/usage/quota/limit') 'https://api.z.ai/api/monitor/usage/quota/limit' 'glm usage host is trusted'
Assert-Throws { Assert-TrustedHttpsHost 'http://cli-chat-proxy.grok.com/v1/billing' } 'http host rejected'
Assert-Throws { Assert-TrustedHttpsHost 'https://evil.example/v1' } 'unknown host rejected'
Assert-Eq (Convert-SafeLogText '{"access_token":"abc","refresh_token":"def","client_secret":"ghi"}') '{"access_token":"[redacted]","refresh_token":"[redacted]","client_secret":"[redacted]"}' 'log text redacts JSON secrets'
Assert-Eq (Convert-SafeLogText '   ') '' 'blank log text remains empty'
Assert-Eq (Convert-UsageRatioPercent 5 20 'ratio') '25' 'ratio percent calculates'
Assert-Throws { Convert-UsageRatioPercent 'garbage' 20 'ratio' } 'ratio used must be numeric'
Assert-Throws { Convert-UsageRatioPercent 5 'garbage' 'ratio' } 'ratio limit must be numeric'
Assert-Throws { Convert-UsageRatioPercent -1 20 'ratio' } 'ratio used cannot be negative'
Assert-Throws { Convert-UsageRatioPercent 5 0 'ratio' } 'ratio limit must be positive'
Assert-Eq (Convert-DisplayPercentToUsagePercent 90 'codex') '90' 'normal display percent is usage percent'
Assert-Eq (Convert-DisplayPercentToUsagePercent 90 'gemini') '10' 'gemini remaining converts to usage percent'
Assert-Eq (Resolve-TrustedHttpsEndpoint 'https://api.kimi.com/coding/v1/' @('api.kimi.com')) 'https://api.kimi.com/coding/v1' 'trusted endpoint normalized'
Assert-Throws { Resolve-TrustedHttpsEndpoint 'http://api.kimi.com/coding/v1' @('api.kimi.com') } 'HTTP endpoint rejected'
Assert-Throws { Resolve-TrustedHttpsEndpoint 'https://evil.example/coding/v1' @('api.kimi.com') } 'untrusted endpoint rejected'
Assert-Throws { Assert-PositiveFiniteNumber 0 'expires_in' } 'non-positive duration rejected'
Assert-Eq (Assert-PositiveFiniteNumber 30 'expires_in') '30' 'positive duration accepted'
Assert-Eq (Convert-OptionalNumber 0) '0' 'optional number keeps explicit zero'
Assert-Eq (Convert-OptionalNumber '42.5') '42.5' 'optional number converts numeric string'
Assert-Eq ("$(Convert-OptionalNumber $null)") '' 'optional number null stays null'
Assert-Eq ("$(Convert-OptionalNumber '')") '' 'optional number empty stays null'
Assert-Eq ("$(Convert-OptionalNumber '   ')") '' 'optional number blank stays null'
Assert-Throws { Convert-OptionalNumber 'abc' } 'optional number garbage throws'
Assert-Throws { Convert-OptionalNumber ([double]::NaN) } 'optional number NaN throws'

if ($failed -gt 0) {
    Write-Host ("FAILED {0}" -f $failed)
    exit 1
}
Write-Host 'ALL PASSED'
exit 0
