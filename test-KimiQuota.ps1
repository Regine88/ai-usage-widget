# Encoding: UTF-8 with BOM.
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $here 'UsageValidation.ps1')
. (Join-Path $here 'KimiQuota.ps1')

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

# 真实 /usages 响应样本（字符串数字，remaining 字段，2026-09-17 实抓）。
$live = @'
{
  "usage": { "limit": "100", "remaining": "40", "resetTime": "2026-09-21T06:48:43Z" },
  "limits": [
    { "window": { "duration": 300, "timeUnit": "TIME_UNIT_MINUTE" }, "detail": { "limit": "100", "remaining": "100", "resetTime": "2026-09-17T05:48:43Z" } }
  ],
  "booster_wallet": { "monthlyUsed": { "currency": "CNY", "priceInCents": "0" } }
}
'@ | ConvertFrom-Json

$q = Convert-KimiUsagePayload -Data $live
Assert-Eq $q.Percent '60' 'percent uses limit minus remaining'
Assert-Eq ([Math]::Round($q.Windows[0].Percent, 1)) '0' 'window percent uses limit minus remaining'
Assert-Eq $q.Windows[0].Label '5小时窗' 'window label from duration'
Assert-Eq $q.PeriodEnd.ToUniversalTime().ToString('yyyy-MM-dd') '2026-09-21' 'period end parsed'
Assert-Eq $q.ExtraCents '0' 'booster wallet zero extra'

$legacy = @{ usage = @{ used = 25; limit = 100 } } | ConvertTo-Json -Depth 8 | ConvertFrom-Json
$q2 = Convert-KimiUsagePayload -Data $legacy
Assert-Eq $q2.Percent '25' 'legacy used field still works'

$zero = @{ usage = @{ limit = '100'; remaining = '100' } } | ConvertTo-Json -Depth 8 | ConvertFrom-Json
$q3 = Convert-KimiUsagePayload -Data $zero
Assert-Eq $q3.Percent '0' 'full remaining keeps explicit zero'

$numeric = @{ usage = @{ limit = 100; remaining = 55 } } | ConvertTo-Json -Depth 8 | ConvertFrom-Json
$q4 = Convert-KimiUsagePayload -Data $numeric
Assert-Eq $q4.Percent '45' 'numeric limit and remaining accepted'

Assert-Throws { Convert-KimiUsagePayload -Data (@{ } | ConvertTo-Json | ConvertFrom-Json) } 'missing usage throws'
Assert-Throws { Convert-KimiUsagePayload -Data (@{ usage = @{ remaining = '40' } } | ConvertTo-Json -Depth 8 | ConvertFrom-Json) } 'missing limit throws'
Assert-Throws { Convert-KimiUsagePayload -Data (@{ usage = @{ limit = '100' } } | ConvertTo-Json -Depth 8 | ConvertFrom-Json) } 'missing used and remaining throws'
Assert-Throws { Convert-KimiUsagePayload -Data (@{ usage = @{ limit = '100'; remaining = 'abc' } } | ConvertTo-Json -Depth 8 | ConvertFrom-Json) } 'invalid remaining throws'
Assert-Throws { Convert-KimiUsagePayload -Data (@{ usage = @{ limit = '0'; remaining = '0' } } | ConvertTo-Json -Depth 8 | ConvertFrom-Json) } 'zero limit throws'
Assert-Throws { Convert-KimiUsagePayload -Data (@{ usage = @{ limit = '100'; remaining = '150' } } | ConvertTo-Json -Depth 8 | ConvertFrom-Json) } 'negative used throws'

$noWindows = @{ usage = @{ limit = '100'; remaining = '50' } } | ConvertTo-Json -Depth 8 | ConvertFrom-Json
Assert-Eq (@(Convert-KimiUsagePayload -Data $noWindows).Windows.Count) '0' 'missing limits yields empty windows'

if ($failed -gt 0) {
    Write-Host ("FAILED {0}" -f $failed)
    exit 1
}
Write-Host 'ALL PASSED'
exit 0
