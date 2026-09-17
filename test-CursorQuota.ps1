# Encoding: UTF-8 with BOM. Run: powershell -NoProfile -File .\test-CursorQuota.ps1
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $here 'UsageValidation.ps1')
. (Join-Path $here 'CursorQuota.ps1')

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
    planUsage = @{ totalPercentUsed = 42.5; remaining = 1150; limit = 2000; used = 850 }
    billingCycleEnd = 1893456000000
    membershipType = 'pro'
} | ConvertTo-Json -Depth 6 | ConvertFrom-Json
$u = Convert-CursorPeriodUsage $payload
Assert-Eq $u.Percent '42.5' 'used percent is passed through'
Assert-Eq $u.Remaining '11.5' 'remaining cents become dollars'
Assert-Eq $u.Limit '20' 'limit cents become dollars'
Assert-Eq $u.Membership 'pro' 'membership is kept'
Assert-Eq ($null -ne $u.ResetAt) 'True' 'billing cycle end is parsed'

$snake = @{
    plan_usage = @{ total_percent_used = 10; remaining = 900; limit = 1000 }
    billing_cycle_end = 1893456000
} | ConvertTo-Json -Depth 6 | ConvertFrom-Json
Assert-Eq (Convert-CursorPeriodUsage $snake).Percent '10' 'snake_case payload works'

$derived = @{ planUsage = @{ remaining = 2500; limit = 10000 } } | ConvertTo-Json -Depth 6 | ConvertFrom-Json
Assert-Eq (Convert-CursorPeriodUsage $derived).Percent '75' 'percent is derived from remaining/limit'

Assert-Throws { Convert-CursorPeriodUsage $null } 'null payload throws'
Assert-Throws { Convert-CursorPeriodUsage (@{} | ConvertTo-Json | ConvertFrom-Json) } 'empty payload throws'

$jwt = 'eyJhbGciOiJIUzI1NiJ9.aaa.bbb'
$key = 'cursorAuth/accessToken'
$pad = New-Object byte[] 8
$bytes = New-Object byte[] 0
$bytes = [Text.Encoding]::UTF8.GetBytes(('xxxx' + $key + '....' + $jwt + '!!!!'))
Assert-Eq (Get-CursorSqliteTextValue -Bytes $bytes -Key $key) $jwt 'jwt after the sqlite key is recovered'
Assert-Eq ("$(Get-CursorSqliteTextValue -Bytes $bytes -Key 'missing')") '' 'a missing key returns nothing'
Assert-Eq (ConvertTo-CursorDollars 1150) '11.5' 'cents convert'
Assert-Eq ("$(ConvertTo-CursorDollars $null)") '' 'null cents stay null'

if ($failed -gt 0) { Write-Host ("FAILED {0}" -f $failed); exit 1 }
Write-Host 'ALL PASSED'
exit 0
