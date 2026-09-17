# Encoding: UTF-8 with BOM. Run: powershell -NoProfile -File .\test-ZaiQuota.ps1
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $here 'UsageValidation.ps1')
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
function Assert-Throws {
    param([scriptblock]$Action, [string]$Name)
    try { & $Action; Write-Host ("FAIL {0}: expected throw" -f $Name); $script:failed++ }
    catch { Write-Host ("OK   {0}" -f $Name) }
}

$payload = @{
    data = @{
        level = 'pro'
        limits = @(
            @{ type = 'TOKENS_FIVE_HOURS'; percentage = 12; nextResetTime = 1893456000000 }
            @{ type = 'TOKENS_SEVEN_DAYS'; percentage = 40; nextResetTime = 1894050000000 }
        )
    }
} | ConvertTo-Json -Depth 6 | ConvertFrom-Json
$u = Convert-ZaiQuota $payload
Assert-Eq $u.Percent '40' 'the bar follows the tighter window'
Assert-Eq $u.FiveHour.Percent '12' '5h window is kept'
Assert-Eq $u.Weekly.Percent '40' 'weekly window is kept'
Assert-Eq $u.Level 'pro' 'plan level is kept'
Assert-Eq ($null -ne $u.ResetAt) 'True' 'a reset stamp is parsed'

$ratio = @{
    data = @{ limits = @(@{ type = '5h'; usage = 25; currentValue = 100 }) }
} | ConvertTo-Json -Depth 6 | ConvertFrom-Json
Assert-Eq (Convert-ZaiQuota $ratio).Percent '25' 'percent can be derived from usage/currentValue'

$zero = @{ data = @{ limits = @(@{ type = 'WEEKLY'; percentage = 0 }) } } | ConvertTo-Json -Depth 6 | ConvertFrom-Json
Assert-Eq (Convert-ZaiQuota $zero).Percent '0' 'explicit zero stays zero'

Assert-Throws { Convert-ZaiQuota $null } 'null payload throws'
Assert-Throws { Convert-ZaiQuota (@{ data = @{ limits = @() } } | ConvertTo-Json -Depth 4 | ConvertFrom-Json) } 'empty limits throw'
Assert-Eq (Test-ZaiFiveHourType 'tokens_five_hours') 'True' 'five-hour type matches'
Assert-Eq (Test-ZaiWeeklyType 'TOKENS_SEVEN_DAYS') 'True' 'weekly type matches'

# ---------- BigModel / ZCode 配置解析 ----------
$zcodeConfig = @{
    provider = @{
        'builtin:bigmodel-coding-plan' = @{ options = @{ apiKey = 'bm-key'; baseURL = 'https://open.bigmodel.cn/api/anthropic' } }
        'builtin:bigmodel' = @{ options = @{ apiKey = '' } }
    }
} | ConvertTo-Json -Depth 8 | ConvertFrom-Json
Assert-Eq (Get-ZaiBigModelKey $zcodeConfig) 'bm-key' 'zcode coding plan key is found'
$zcodeFallback = @{ provider = @{ 'builtin:bigmodel' = @{ options = @{ apiKey = 'plain-key' } } } } | ConvertTo-Json -Depth 8 | ConvertFrom-Json
Assert-Eq (Get-ZaiBigModelKey $zcodeFallback) 'plain-key' 'plain bigmodel entry is used as a fallback'
Assert-Eq (Get-ZaiBigModelKey (@{ provider = @{ 'builtin:zai' = @{ options = @{ apiKey = 'x' } } } } | ConvertTo-Json -Depth 8 | ConvertFrom-Json)) '' 'unrelated providers are ignored'
Assert-Eq (Get-ZaiBigModelKey $null) '' 'null config has no key'

# ---------- 业务错误 ----------
Assert-Eq (Get-ZaiBusinessError (@{ code = 500; msg = 'no plan'; success = $false } | ConvertTo-Json | ConvertFrom-Json)) 'no plan' 'business error keeps the server message'
Assert-Eq (Get-ZaiBusinessError (@{ code = 0; msg = '' } | ConvertTo-Json | ConvertFrom-Json)) '' 'code 0 is not an error'
Assert-Eq (Get-ZaiBusinessError (@{ data = @{ limits = @() } } | ConvertTo-Json -Depth 4 | ConvertFrom-Json)) '' 'payloads without a code are not errors'
Assert-Eq (Get-ZaiBusinessError (@{ code = 500 } | ConvertTo-Json | ConvertFrom-Json)) '' 'errors without a message stay silent'
Assert-Throws { Convert-ZaiQuota (@{ code = 500; msg = 'no coding plan'; success = $false } | ConvertTo-Json | ConvertFrom-Json) } 'a business error is thrown as plan-missing'
try {
    Convert-ZaiQuota (@{ code = 500; msg = 'no coding plan' } | ConvertTo-Json | ConvertFrom-Json) | Out-Null
} catch {
    Assert-Eq ($_.Exception.Message -like 'plan-missing*') 'True' 'plan-missing keeps the server text'
}

if ($failed -gt 0) { Write-Host ("FAILED {0}" -f $failed); exit 1 }Write-Host 'ALL PASSED'
exit 0
