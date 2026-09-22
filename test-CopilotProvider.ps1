# Encoding: UTF-8 with BOM. Run: powershell -NoProfile -File .\test-CopilotProvider.ps1
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $here 'UsageValidation.ps1')
. (Join-Path $here 'WidgetStrings.ps1')
. (Join-Path $here 'WidgetFormat.ps1')
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
function Get-ScriptFunctionDefinition {
    param([string]$ScriptPath, [string]$Name)
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($ScriptPath, [ref]$null, [ref]$null)
    foreach ($fn in $ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)) {
        if ($fn.Name -eq $Name) { return $fn.Extent.Text }
    }
    throw ('function not found: ' + $Name)
}

$entry = Join-Path $here 'AiUsageWidget.ps1'
$entryText = Get-Content -LiteralPath $entry -Raw -Encoding utf8
$script:Language = 'en-US'
$script:WidgetStrings = Read-WidgetStrings -Language 'en-US' -Dir $here
$script:payload = $null
$script:seenUri = ''
$script:seenAuth = ''
$script:logLines = @()
function Invoke-WidgetRest {
    param($Method, $Uri, $Headers, $Body, $ContentType, $TimeoutSec)
    $script:seenUri = $Uri
    $script:seenAuth = $Headers['Authorization']
    return $script:payload
}
function Write-WidgetLog { param([string]$Message) $script:logLines += $Message }

$definitions = @()
foreach ($name in @('Get-CopilotAuthToken', 'Read-CopilotTokenFromFile', 'Get-CopilotToken', 'Test-CopilotCredExists', 'Get-CopilotAuthHeaders', 'Get-CopilotUsageSnapshot', 'Get-CopilotRowData')) {
    $definitions += (Get-ScriptFunctionDefinition $entry $name)
}
$definitions += "`$script:CopilotHostsPath = (Join-Path `$env:TEMP 'no-such-copilot-hosts.json')"
$definitions += "`$script:CopilotAppsPath = (Join-Path `$env:TEMP 'no-such-copilot-apps.json')"
$definitions += "`$script:CopilotOpencodeAuthPath = (Join-Path `$env:TEMP 'no-such-opencode-auth.json')"
$definitions += "`$script:CopilotUsageUrl = 'https://api.github.com/copilot_internal/user'"
$definitions += "`$script:CopilotDisplayName = 'Copilot'"
. ([ScriptBlock]::Create(($definitions -join [Environment]::NewLine)))

# ---------- 载荷换算与请求形状 ----------
$script:payload = '{"copilot_plan":"individual","quota_reset_date":"2026-10-01","quota_snapshots":{"premium_interactions":{"entitlement":300,"remaining":171,"percent_remaining":57.0,"unlimited":false},"chat":{"entitlement":0,"remaining":0,"percent_remaining":100.0,"unlimited":true},"completions":{"entitlement":0,"remaining":0,"percent_remaining":100.0,"unlimited":true}}}' | ConvertFrom-Json
$row = Get-CopilotRowData -Auth 'gho_test_token' -Name 'Copilot'
Assert-Eq $script:seenUri 'https://api.github.com/copilot_internal/user' 'copilot hits the internal user endpoint'
Assert-Eq $script:seenAuth 'token gho_test_token' 'copilot sends the token scheme GitHub expects'
Assert-Eq $row.Percent '43' 'copilot percent is used premium interactions'
Assert-Eq ($row.Detail -like 'individual*171/300*') 'True' 'copilot detail carries plan and remaining quota'
Assert-Eq ($row.Tip -like 'Copilot 43%*') 'True' 'copilot tip mirrors the percent'
Assert-Eq ([bool]$row.ResetAt) 'True' 'copilot keeps the reset stamp for the forecast'

$script:payload = '{"copilot_plan":"business","quota_snapshots":{"premium_interactions":{"unlimited":true}}}' | ConvertFrom-Json
$unlimited = Get-CopilotRowData -Auth 'gho_test_token' -Name 'Copilot'
Assert-Eq $unlimited.Percent '0' 'unlimited premium quota reads as unused'
Assert-Eq ($unlimited.Detail -like 'business*unlimited*') 'True' 'unlimited detail is spelled out'

$script:payload = '{"copilot_plan":"individual","quota_snapshots":{"premium_interactions":{"percent_remaining":25.0}}}' | ConvertFrom-Json
$fallback = Get-CopilotRowData -Auth 'gho_test_token' -Name 'Copilot'
Assert-Eq $fallback.Percent '75' 'percent_remaining is the fallback when counts are missing'

$script:payload = '{"copilot_plan":"individual"}' | ConvertFrom-Json
$threw = $false
try { [void](Get-CopilotRowData -Auth 'gho_test_token' -Name 'Copilot') } catch { $threw = $true }
Assert-Eq $threw 'True' 'a payload without premium snapshots is rejected'

# ---------- 凭证发现 ----------
Assert-Eq (Test-CopilotCredExists) 'False' 'missing credential files report no copilot'
$tmpDir = Join-Path $env:TEMP ('copilot-provider-test-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null
try {
    $hosts = Join-Path $tmpDir 'hosts.json'
    [IO.File]::WriteAllText($hosts, '{"github.com":{"user":"octocat","oauth_token":"gho_file_token"}}', [Text.UTF8Encoding]::new($false))
    $script:CopilotHostsPath = $hosts
    Assert-Eq (Test-CopilotCredExists) 'True' 'hosts.json oauth_token counts as a credential'
    $script:payload = '{"copilot_plan":"individual","quota_snapshots":{"premium_interactions":{"entitlement":300,"remaining":171}}}' | ConvertFrom-Json
    [void](Get-CopilotRowData -Name 'Copilot')
    Assert-Eq $script:seenAuth 'token gho_file_token' 'row data falls back to the discovered token'
} finally {
    Remove-Item -LiteralPath $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
}

# ---------- worker 注入 ----------
$fnNames = @()
$match = [regex]::Match($entryText, '(?s)function Get-WorkerScriptSource \{.*?\$fnNames = @\((.*?)\)')
if ($match.Success) { $fnNames = @([regex]::Matches($match.Groups[1].Value, "'([^']+)'") | ForEach-Object { $_.Groups[1].Value }) }
Assert-Eq ($fnNames -contains 'Get-CopilotRowData') 'True' 'worker forwards Get-CopilotRowData'
Assert-Eq ($fnNames -contains 'Find-CopilotToken') 'True' 'worker forwards Find-CopilotToken'
Assert-Eq ($entryText -match "'copilot' \{ \`$d = Get-CopilotRowData") 'True' 'worker dispatch handles copilot'
Assert-Eq ($entryText -match "CopilotHostsPath\s+= \`$script:CopilotHostsPath") 'True' 'worker config carries the copilot paths'
Assert-Eq ($entryText -match "\(Join-Path \`$script:WidgetDir 'CopilotQuota.ps1'\)") 'True' 'entry script dot-sources CopilotQuota.ps1'

if ($failed -gt 0) { Write-Host ("FAILED {0}" -f $failed); exit 1 }
Write-Host 'ALL PASSED'
exit 0
