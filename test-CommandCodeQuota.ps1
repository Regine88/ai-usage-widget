# Encoding: UTF-8 with BOM.
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $here 'CommandCodeQuota.ps1')

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

# --- 真实 API 结构:windowLimits 在顶层, resetAt 是 epoch 毫秒 ---
$data = @{
    credits = @{
        belowThreshold  = $false
        monthlyCredits  = 63.54
        purchasedCredits = 0
        freeCredits     = 0
    }
    windowLimits = @{
        limited  = $true
        fiveHour = @{ used = 6.46; cap = 14; exceeded = $false; resetAt = 1788186535313 }
        weekly   = @{ used = 6.46; cap = 35; exceeded = $false; resetAt = 1788773335313 }
    }
} | ConvertTo-Json -Depth 8 | ConvertFrom-Json
$q = Convert-CommandCodeCredits $data
Assert-Eq ([Math]::Round($q.Weekly.Percent, 1)) '18.5' 'weekly pct 6.46/35 = 18.5'
Assert-Eq ([Math]::Round($q.FiveHour.Percent, 1)) '46.1' 'fiveHour pct 6.46/14 = 46.1'
Assert-Eq $q.PeriodEnd.ToUniversalTime().ToString('yyyy-MM-dd') '2026-09-07' 'period end from weekly epoch ms'
Assert-Eq $q.TotalRemaining '63.54' 'total remaining from monthlyCredits'
Assert-Eq ([Math]::Round([double]$q.Used, 2)) '6.46' 'weekly used passthrough'
Assert-Eq $q.Cap '35' 'weekly cap passthrough'

# --- 兼容旧设计:windowLimits 在 credits 内, ISO resetAt ---
$dataLegacy = @{
    credits = @{
        usagePercent  = 41.5
        totalRemaining = 123.45
        windowLimits = @{
            weekly   = @{ used = 3400; cap = 10000; resetAt = '2026-09-01T13:54:23Z' }
            fiveHour = @{ used = 120; cap = 1000 }
        }
    }
} | ConvertTo-Json -Depth 8 | ConvertFrom-Json
$qL = Convert-CommandCodeCredits $dataLegacy
Assert-Eq $qL.Percent '41.5' 'legacy overall uses usagePercent'
Assert-Eq ([Math]::Round($qL.Weekly.Percent, 1)) '34' 'legacy weekly pct 34'
Assert-Eq $qL.PeriodEnd.ToUniversalTime().ToString('yyyy-MM-dd') '2026-09-01' 'legacy period end ISO'

# --- 顶层 windowLimits, 无 usagePercent -> 用 weekly ---
$data2 = @{
    windowLimits = @{
        weekly   = @{ used = 3400; cap = 10000; resetAt = '2026-09-01T13:54:23Z' }
        fiveHour = @{ used = 120; cap = 1000 }
    }
} | ConvertTo-Json -Depth 8 | ConvertFrom-Json
$q2 = Convert-CommandCodeCredits $data2
Assert-Eq $q2.Percent '34' 'overall falls back to weekly pct'

# --- 仅 fiveHour 窗口 ---
$data3 = @{
    windowLimits = @{
        fiveHour = @{ used = 120; cap = 1000; resetAt = 1788186535313 }
    }
} | ConvertTo-Json -Depth 8 | ConvertFrom-Json
$q3 = Convert-CommandCodeCredits $data3
Assert-Eq $q3.Percent '12' 'fiveHour only -> pct 12'
if ($null -ne $q3.Weekly) { Write-Host 'FAIL weekly should be null when absent'; $failed++ } else { Write-Host 'OK   weekly null when absent' }
Assert-Eq $q3.PeriodEnd.ToUniversalTime().ToString('yyyy-MM-dd') '2026-08-31' 'period end from fiveHour epoch ms'

# --- 仅 weekly 窗口, 无 resetAt ---
$data4 = @{
    windowLimits = @{
        weekly = @{ used = 500; cap = 1000 }
    }
} | ConvertTo-Json -Depth 8 | ConvertFrom-Json
$q4 = Convert-CommandCodeCredits $data4
Assert-Eq $q4.Percent '50' 'weekly only -> pct 50'
Assert-Eq $q4.PeriodEnd '' 'no resetAt -> empty period end'

# --- Convert-CommandCodeTime 时间戳解析 ---
Assert-Eq (Convert-CommandCodeTime 1788773335313).ToUniversalTime().ToString('yyyy-MM-dd') '2026-09-07' 'epoch ms parsed'
Assert-Eq (Convert-CommandCodeTime 1788773335).ToUniversalTime().ToString('yyyy-MM-dd') '2026-09-07' 'epoch seconds parsed'
Assert-Eq (Convert-CommandCodeTime '2026-09-01T13:54:23Z').ToUniversalTime().ToString('yyyy-MM-dd') '2026-09-01' 'ISO parsed'
if ($null -ne (Convert-CommandCodeTime '')) { Write-Host 'FAIL empty time should be null'; $failed++ } else { Write-Host 'OK   empty time null' }
if ($null -ne (Convert-CommandCodeTime 'garbage')) { Write-Host 'FAIL garbage time should be null'; $failed++ } else { Write-Host 'OK   garbage time null' }

# --- 空 windowLimits 抛异常 ---
try {
    Convert-CommandCodeCredits (@{ windowLimits = @{} } | ConvertTo-Json -Depth 8 | ConvertFrom-Json)
    Write-Host 'FAIL empty windowLimits should throw'
    $failed++
} catch {
    Write-Host 'OK   empty windowLimits throws'
}

# --- cap 0 不除零 ---
$data6 = @{
    windowLimits = @{
        weekly = @{ used = 100; cap = 0 }
    }
} | ConvertTo-Json -Depth 8 | ConvertFrom-Json
$q6 = Convert-CommandCodeCredits $data6
Assert-Eq $q6.Percent '0' 'cap 0 -> pct 0 no divide'

# --- 负 used 夹到 0 ---
$data7 = @{
    windowLimits = @{
        weekly = @{ used = -50; cap = 100 }
    }
} | ConvertTo-Json -Depth 8 | ConvertFrom-Json
$q7 = Convert-CommandCodeCredits $data7
Assert-Eq $q7.Weekly.Percent '0' 'negative used clamped to 0'

# --- 无窗口抛异常 ---
try {
    Convert-CommandCodeCredits (@{ credits = @{} } | ConvertTo-Json -Depth 8 | ConvertFrom-Json)
    Write-Host 'FAIL no windows should throw'
    $failed++
} catch {
    Write-Host 'OK   no windows throws'
}

# --- 无 credits 字段(顶层结构)不抛 ---
$data8 = @{
    windowLimits = @{
        weekly = @{ used = 1; cap = 100 }
    }
} | ConvertTo-Json -Depth 8 | ConvertFrom-Json
$q8 = Convert-CommandCodeCredits $data8
if ($null -eq $q8) { Write-Host 'FAIL top-level windowLimits without credits should work'; $failed++ } else { Write-Host 'OK   top-level windowLimits without credits works' }
Assert-Eq $q8.TotalRemaining '' 'no credits -> null total remaining'

if ($failed -gt 0) {
    Write-Host ("FAILED {0}" -f $failed)
    exit 1
}
Write-Host 'ALL PASSED'
exit 0
