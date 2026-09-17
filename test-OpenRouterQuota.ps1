# Encoding: UTF-8 with BOM. Run: powershell -NoProfile -File .\test-OpenRouterQuota.ps1
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $here 'OpenRouterQuota.ps1')

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

# ---------- 有上限的 key ----------
$limited = @{ data = @{ label = 'sk-or-v1-abcd1234'; usage = 12.5; limit = 100; limit_remaining = 87.5; limit_reset = 'monthly' } } |
    ConvertTo-Json -Depth 8 | ConvertFrom-Json
$q = Convert-OpenRouterCredits $limited
Assert-Eq $q.Percent '12.5' 'spent over limit becomes a percent'
Assert-Eq $q.Spent '12.5' 'spent is passed through'
Assert-Eq $q.Limit '100' 'limit is passed through'
Assert-Eq $q.Remaining '87.5' 'remaining is derived'
Assert-Eq $q.IsUnlimited 'False' 'limited key is not unlimited'
Assert-Eq $q.Period 'monthly' 'reset period is lowercased'
Assert-Eq $q.Label 'sk-or-v1-abcd1234' 'label is passed through'

# 顶层就是 data 时同样可用
$flat = @{ usage = 25; limit = 50 } | ConvertTo-Json -Depth 8 | ConvertFrom-Json
Assert-Eq (Convert-OpenRouterCredits $flat).Percent '50' 'payload without the data wrapper works'

# ---------- 无上限的 key ----------
$unlimited = @{ data = @{ usage = 3.25; limit = $null; limit_remaining = $null } } |
    ConvertTo-Json -Depth 8 | ConvertFrom-Json
$u = Convert-OpenRouterCredits $unlimited
if ($null -ne $u.Percent) { Write-Host 'FAIL unlimited key must not invent a percent'; $failed++ } else { Write-Host 'OK   unlimited key has no percent' }
Assert-Eq $u.IsUnlimited 'True' 'unlimited flag'
Assert-Eq $u.Spent '3.25' 'unlimited key still reports spend'

# 金额按 0.1 个百分点四舍五入
$rounding = @{ usage = 1; limit = 3 } | ConvertTo-Json -Depth 8 | ConvertFrom-Json
Assert-Eq (Convert-OpenRouterCredits $rounding).Percent '33.3' 'percent is rounded to one decimal'

# 花超时不低于 0
$over = @{ usage = 150; limit = 100 } | ConvertTo-Json -Depth 8 | ConvertFrom-Json
$o = Convert-OpenRouterCredits $over
Assert-Eq $o.Percent '100' 'spend above the limit clamps to 100 percent'
Assert-Eq $o.Remaining '0' 'remaining never goes negative'

# ---------- 非法载荷 ----------
$bad = @(
    (@{ data = @{ limit = 100 } } | ConvertTo-Json -Depth 8 | ConvertFrom-Json),
    (@{ data = @{ usage = 'garbage'; limit = 100 } } | ConvertTo-Json -Depth 8 | ConvertFrom-Json),
    (@{ data = @{ usage = -1; limit = 100 } } | ConvertTo-Json -Depth 8 | ConvertFrom-Json),
    (@{ data = @{ usage = 1; limit = 0 } } | ConvertTo-Json -Depth 8 | ConvertFrom-Json),
    (@{ data = @{ usage = 1; limit = 'garbage' } } | ConvertTo-Json -Depth 8 | ConvertFrom-Json),
    ($null)
)
foreach ($payload in $bad) {
    try {
        Convert-OpenRouterCredits $payload | Out-Null
        Write-Host 'FAIL invalid payload should throw'
        $failed++
    } catch {
        Write-Host 'OK   invalid payload throws'
    }
}

# ---------- 密钥指纹 ----------
$fingerprint = Get-OpenRouterKeyFingerprint 'sk-or-v1-0123456789abcdef'
Assert-Eq $fingerprint.StartsWith('OpenRouter-') 'True' 'fingerprint has the product prefix'
Assert-Eq $fingerprint.Length 19 'fingerprint is 8 hex characters long'
Assert-Eq ($fingerprint -match '^OpenRouter-[0-9a-f]{8}$') 'True' 'fingerprint is hexadecimal'
Assert-Eq $fingerprint (Get-OpenRouterKeyFingerprint 'sk-or-v1-0123456789abcdef') 'True' 'fingerprint is stable'
Assert-Eq ((Get-OpenRouterKeyFingerprint 'sk-or-v1-fedcba9876543210') -ne $fingerprint) 'True' 'different key yields a different fingerprint'
Assert-Eq ($fingerprint -like '*0123456789abcdef*') 'False' 'fingerprint never contains the key'
Assert-Eq (Get-OpenRouterKeyFingerprint '') 'OpenRouter' 'empty key falls back to the plain name'

if ($failed -gt 0) {
    Write-Host ("FAILED {0}" -f $failed)
    exit 1
}
Write-Host 'ALL PASSED'
exit 0