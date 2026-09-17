# Encoding: UTF-8 with BOM. Run: powershell -NoProfile -File .\test-DeepSeekQuota.ps1
# DeepSeek 余额是纯解析：离线覆盖货币选择、金额格式与坏载荷，不发任何网络请求。
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $here 'UsageValidation.ps1')
. (Join-Path $here 'DeepSeekQuota.ps1')

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
    param([scriptblock]$Action, [string]$Expected, [string]$Name)
    $threw = $null
    try { & $Action | Out-Null } catch { $threw = $_.Exception.Message }
    Assert-Eq $threw $Expected $Name
}

function Convert-Json {
    param([string]$Text)
    return ($Text | ConvertFrom-Json)
}

# ---------- 货币符号 ----------
Assert-Eq (Get-DeepSeekCurrencySymbol 'CNY') '¥' 'CNY has a symbol'
Assert-Eq (Get-DeepSeekCurrencySymbol 'cny') '¥' 'currency codes are case insensitive'
Assert-Eq (Get-DeepSeekCurrencySymbol ' USD ') '$' 'currency codes are trimmed'
Assert-Eq (Get-DeepSeekCurrencySymbol 'EUR') '' 'an unknown currency has no symbol'
Assert-Eq (Get-DeepSeekCurrencySymbol $null) '' 'a missing currency has no symbol'

# ---------- 金额格式 ----------
Assert-Eq (Format-DeepSeekAmount 1.58 'CNY') '¥1.58' 'a CNY amount keeps two decimals'
Assert-Eq (Format-DeepSeekAmount 0 'USD') '$0.00' 'a zero balance is still readable'
Assert-Eq (Format-DeepSeekAmount 1234.5 'USD') '$1234.50' 'a large amount is padded'
Assert-Eq (Format-DeepSeekAmount 12.4 'CNY') '¥12.40' 'the second decimal is always shown'
Assert-Eq (Format-DeepSeekAmount 5 'EUR') 'EUR 5.00' 'an unknown currency keeps its code'
Assert-Eq (Format-DeepSeekAmount 5 '') '5.00' 'a missing currency prints the bare amount'
Assert-Eq (Format-DeepSeekAmount 1.239 'USD') '$1.24' 'amounts are rounded to cents'

# ---------- 真实载荷：CNY 有余额、USD 为空 ----------
$real = Convert-Json '{"is_available":true,"balance_infos":[{"currency":"USD","total_balance":"0.00","granted_balance":"0.00","topped_up_balance":"0.00"},{"currency":"CNY","total_balance":"1.58","granted_balance":"0.00","topped_up_balance":"1.58"}]}'
$balance = Convert-DeepSeekBalance $real
Assert-Eq $balance.Currency 'CNY' 'the funded purse wins over an empty one'
Assert-Eq $balance.Total '1.58' 'the total balance is read'
Assert-Eq $balance.ToppedUp '1.58' 'the top-up part is read'
Assert-Eq $balance.Granted '0' 'a zero grant is read'
Assert-Eq $balance.Display '¥1.58' 'the row value is the formatted balance'
Assert-Eq $balance.IsAvailable 'True' 'an available account is reported as usable'
Assert-Eq ($balance.FetchedAt -is [datetime]) 'True' 'the snapshot carries a fetch timestamp'

# ---------- 全部为空：退回第一条 ----------
$empty = Convert-Json '{"is_available":true,"balance_infos":[{"currency":"USD","total_balance":"0","granted_balance":"0","topped_up_balance":"0"},{"currency":"CNY","total_balance":"0.00","granted_balance":"0.00","topped_up_balance":"0.00"}]}'
$zero = Convert-DeepSeekBalance $empty
Assert-Eq $zero.Currency 'USD' 'when every purse is empty the first entry is shown'
Assert-Eq $zero.Display '$0.00' 'an empty balance still formats'

# ---------- 数字而不是字符串 ----------
$numeric = Convert-Json '{"is_available":true,"balance_infos":[{"currency":"USD","total_balance":20,"granted_balance":0,"topped_up_balance":20}]}'
$usd = Convert-DeepSeekBalance $numeric
Assert-Eq $usd.Display '$20.00' 'numeric amounts are accepted'
Assert-Eq $usd.Currency 'USD' 'the only purse is picked'
Assert-Eq $usd.Granted '0' 'a missing grant is treated as zero'

# ---------- 赠额与不可用 ----------
$granted = Convert-Json '{"balance_infos":[{"currency":"CNY","total_balance":"3.00","granted_balance":"3.00","topped_up_balance":"0.00"}]}'
$grant = Convert-DeepSeekBalance $granted
Assert-Eq $grant.Granted '3' 'a granted-only purse is read'
Assert-Eq $grant.IsAvailable 'True' 'a payload without the flag is treated as usable'
$blocked = Convert-Json '{"is_available":false,"balance_infos":[{"currency":"CNY","total_balance":"0.00","granted_balance":"0.00","topped_up_balance":"0.00"}]}'
Assert-Eq (Convert-DeepSeekBalance $blocked).IsAvailable 'False' 'an unusable account is reported'

# ---------- 坏载荷 ----------
Assert-Throws { Convert-DeepSeekBalance $null } 'bad-payload' 'a null payload is rejected'
Assert-Throws { Convert-DeepSeekBalance (Convert-Json '{"is_available":true}') } 'bad-payload' 'a payload without balances is rejected'
Assert-Throws { Convert-DeepSeekBalance (Convert-Json '{"balance_infos":[]}') } 'bad-payload' 'an empty balance list is rejected'
Assert-Throws { Convert-DeepSeekBalance (Convert-Json '{"balance_infos":[{"currency":"CNY","total_balance":"abc","granted_balance":"0","topped_up_balance":"0"}]}') } 'bad-payload' 'an unreadable amount is rejected'
Assert-Throws { Convert-DeepSeekBalance (Convert-Json '{"balance_infos":[{"currency":"CNY","total_balance":"-1.00","granted_balance":"0","topped_up_balance":"0"}]}') } 'bad-payload' 'a negative balance is rejected'

# 一条坏记录不该毁掉整行：跳过它，用下一条可用记录。
$mixed = Convert-Json '{"balance_infos":[{"currency":"CNY","total_balance":"oops","granted_balance":"0","topped_up_balance":"0"},{"currency":"USD","total_balance":"4.00","granted_balance":"0","topped_up_balance":"4.00"}]}'
Assert-Eq (Convert-DeepSeekBalance $mixed).Display '$4.00' 'a broken entry is skipped in favour of a readable one'

if ($failed -gt 0) {
    Write-Host ("FAILED {0}" -f $failed)
    exit 1
}
Write-Host 'ALL PASSED'
exit 0