# Encoding: UTF-8 with BOM. Run: powershell -NoProfile -File .\test-DeepSeekProvider.ps1
# 把主程序里的 DeepSeek 行数据函数取出来在同一个进程里跑：既不启动界面也不发网络请求。
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $here 'UsageValidation.ps1')
. (Join-Path $here 'WidgetConfig.ps1')
. (Join-Path $here 'ApiKeyAuth.ps1')
. (Join-Path $here 'DeepSeekQuota.ps1')
. (Join-Path $here 'WidgetStrings.ps1')

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

function Get-ScriptFunctionDefinition {
    param([string]$ScriptPath, [string]$Name)
    $tokens = $null
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($ScriptPath, [ref]$tokens, [ref]$errors)
    foreach ($fn in $ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)) {
        if ($fn.Name -eq $Name) { return $fn.Extent.Text }
    }
    throw ('function not found: ' + $Name)
}

$entry = Join-Path $here 'AiUsageWidget.ps1'
$entryText = Get-Content -LiteralPath $entry -Raw -Encoding utf8
$script:WidgetStrings = Read-WidgetStrings -Language 'en-US' -Dir $here

$script:payload = $null
$script:seenUri = ''
$script:seenAuth = ''
function Invoke-WidgetRest {
    param($Method, $Uri, $Headers, $Body, $ContentType, $TimeoutSec)
    $script:seenUri = $Uri
    $script:seenAuth = $Headers['Authorization']
    return $script:payload
}
function Write-WidgetLog { param([string]$Message) }

$definitions = @()
foreach ($name in @('Get-DeepSeekUsageSnapshot', 'Get-DeepSeekRowData')) {
    $definitions += (Get-ScriptFunctionDefinition $entry $name)
}
$definitions += '$script:DeepSeekApiBaseUrl = ''https://api.deepseek.com'''
$definitions += '$script:DeepSeekDisplayName = ''DeepSeek'''
$definitions += '$script:DeepSeekAuthPath = ''no-such-file.json'''
. ([ScriptBlock]::Create(($definitions -join [Environment]::NewLine)))

$auth = [pscustomobject]@{ ApiKey = 'sk-deepseek-test'; ApiKeyCount = 1 }

# ---------- 有余额 ----------
$script:payload = '{"is_available":true,"balance_infos":[{"currency":"CNY","total_balance":"1.58","granted_balance":"0.00","topped_up_balance":"1.58"}]}' | ConvertFrom-Json
$row = Get-DeepSeekRowData -Auth $auth -Name 'DeepSeek'
Assert-Eq $script:seenUri 'https://api.deepseek.com/user/balance' 'the balance is read from the documented endpoint'
Assert-Eq ($script:seenAuth -like 'Bearer sk-*') 'True' 'the request carries the bearer token'
Assert-Eq $row.Percent '0' 'a balance row has no percentage'
Assert-Eq $row.Display '¥1.58' 'the row prints the balance as its main value'
Assert-Eq $row.Detail 'Topped up ¥1.58' 'the detail line reports the top-up when nothing was granted'
Assert-Eq $row.Tip 'DeepSeek balance ¥1.58' 'the tooltip carries the balance'
Assert-Eq ($null -eq $row.Reset) 'True' 'a balance never claims a reset time'
Assert-Eq ($null -eq $row.ResetAt) 'True' 'a balance has no reset stamp either'
Assert-Eq ($null -ne $row.FetchedAt) 'True' 'the row keeps the fetch timestamp'

# ---------- 赠额 ----------
$script:payload = '{"is_available":true,"balance_infos":[{"currency":"CNY","total_balance":"14.00","granted_balance":"1.60","topped_up_balance":"12.40"}]}' | ConvertFrom-Json
$granted = Get-DeepSeekRowData -Auth $auth -Name 'DeepSeek'
Assert-Eq $granted.Display '¥14.00' 'the total includes the granted credit'
Assert-Eq $granted.Detail 'Topped up ¥12.40 · Granted ¥1.60' 'granted credit is listed next to the top-up'

# ---------- 余额不足 ----------
$script:payload = '{"is_available":false,"balance_infos":[{"currency":"USD","total_balance":"0.00","granted_balance":"0.00","topped_up_balance":"0.00"}]}' | ConvertFrom-Json
$blocked = Get-DeepSeekRowData -Auth $auth -Name 'DeepSeek'
Assert-Eq $blocked.Display '$0.00' 'an exhausted balance still shows its amount'
Assert-Eq $blocked.Detail 'Balance too low · Topped up $0.00' 'an unusable account is flagged on the detail line'

# ---------- 中文语言包 ----------
$script:WidgetStrings = Read-WidgetStrings -Language 'zh-CN' -Dir $here
$script:payload = '{"is_available":true,"balance_infos":[{"currency":"CNY","total_balance":"1.58","granted_balance":"0.00","topped_up_balance":"1.58"}]}' | ConvertFrom-Json
$zh = Get-DeepSeekRowData -Auth $auth -Name 'DeepSeek'
Assert-Eq $zh.Detail '充值 ¥1.58' 'the detail line is localized'
Assert-Eq $zh.Tip 'DeepSeek 余额 ¥1.58' 'the tooltip is localized'

# ---------- 行与 worker 接线 ----------
$script:WidgetStrings = Read-WidgetStrings -Language 'en-US' -Dir $here
Assert-Eq ($entryText -match "Kind\s*=\s*'deepseek'") 'True' 'the provider contributes a row'
Assert-Eq ($entryText -match "Test-ApiKeyCredExists -AuthPath \`$script:DeepSeekAuthPath") 'True' 'the row is gated by the DeepSeek credential'
Assert-Eq ($entryText -match "\`$script:DeepSeekUsagePageUrl = 'https://") 'True' 'the usage page is an https url'
Assert-Eq ($entryText -match "miOpenDeepSeek") 'True' 'the context menu can open the usage page'
Assert-Eq ($entryText -match "New-SettingCheckBox \`$dialog 'DeepSeek'") 'True' 'the settings dialog can switch the provider off'
Assert-Eq ($entryText -match "deepseek\s+= \[bool\]\`$chkDeepSeek.Checked") 'True' 'the settings dialog saves the switch'

$fnNames = @()
$vNames = @()
$match = [regex]::Match($entryText, '(?s)function Get-WorkerScriptSource \{.*?\$fnNames = @\((.*?)\)')
if ($match.Success) { $fnNames = @([regex]::Matches($match.Groups[1].Value, "'([^']+)'") | ForEach-Object { $_.Groups[1].Value }) }
$match2 = [regex]::Match($entryText, '(?s)foreach \(\$v in (.*?)\) \{')
if ($match2.Success) { $vNames = @([regex]::Matches($match2.Groups[1].Value, "'([^']+)'") | ForEach-Object { $_.Groups[1].Value }) }
foreach ($name in @('Get-DeepSeekRowData', 'Get-DeepSeekUsageSnapshot', 'Convert-DeepSeekBalance', 'Format-DeepSeekAmount', 'Get-DeepSeekCurrencySymbol', 'ConvertTo-DeepSeekPurse', 'Read-ApiKeyAuth', 'Invoke-ApiKeyGet', 'Get-ApiKeyAuthHeaders', 'Get-ApiKeyFileSources')) {
    Assert-Eq ($fnNames -contains $name) 'True' ('worker forwards ' + $name)
}
foreach ($name in @('DeepSeekAuthPath', 'DeepSeekApiBaseUrl', 'DeepSeekDisplayName')) {
    Assert-Eq ($vNames -contains $name) 'True' ('worker forwards ' + $name)
}
Assert-Eq ($entryText -match "'deepseek' \{ \`$d = Get-DeepSeekRowData") 'True' 'worker dispatch handles the deepseek kind'
Assert-Eq ($entryText -match "DeepSeekAuthPath\s+= \`$script:DeepSeekAuthPath") 'True' 'the worker config table carries the DeepSeek paths'
# 旧的内联凭证函数已经搬到共享模块，主程序里不能再留下第二份实现。
Assert-Eq ($entryText -match 'function Read-OpenRouterAuth') 'False' 'the OpenRouter credential helper is not duplicated in the entry script'
Assert-Eq ($entryText -match 'function Get-OpenRouterAuthHeaders') 'False' 'the OpenRouter header helper lives in the shared module'

if ($failed -gt 0) {
    Write-Host ("FAILED {0}" -f $failed)
    exit 1
}
Write-Host 'ALL PASSED'
exit 0