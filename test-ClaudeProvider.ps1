# Encoding: UTF-8 with BOM. Run: powershell -NoProfile -File .\test-ClaudeProvider.ps1
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $here 'UsageValidation.ps1')
. (Join-Path $here 'WidgetStrings.ps1')
. (Join-Path $here 'WidgetFormat.ps1')
. (Join-Path $here 'ClaudeQuota.ps1')

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
function Invoke-WidgetRest {
    param($Method, $Uri, $Headers, $Body, $ContentType, $TimeoutSec)
    $script:seenUri = $Uri
    return $script:payload
}
function Write-WidgetLog { param([string]$Message) }
function Update-ClaudeToken { param($Auth) $Auth }

$definitions = @()
foreach ($name in @('Get-ClaudeUsageSnapshot', 'Get-ClaudeRowData', 'Get-ClaudeAuthHeaders')) {
    $definitions += (Get-ScriptFunctionDefinition $entry $name)
}
$definitions += '$script:ClaudeUsageUrl = ''https://api.anthropic.com/api/oauth/usage'''
$definitions += '$script:ClaudeDisplayName = ''Claude'''
. ([ScriptBlock]::Create(($definitions -join [Environment]::NewLine)))

$script:payload = '{"five_hour":{"utilization":11,"resets_at":"2026-09-18T15:00:00Z"},"seven_day":{"utilization":37,"resets_at":"2026-09-24T12:00:00Z"}}' | ConvertFrom-Json
$row = Get-ClaudeRowData -Auth ([pscustomobject]@{ AccessToken = 'tok' }) -Name 'Claude'
Assert-Eq $script:seenUri 'https://api.anthropic.com/api/oauth/usage' 'claude usage hits the oauth endpoint'
Assert-Eq $row.Percent '37' 'claude percent follows the tighter window'
Assert-Eq ($row.Detail -like '5h 11%*') 'True' 'claude detail includes the 5h window'

$fnNames = @()
$match = [regex]::Match($entryText, '(?s)function Get-WorkerScriptSource \{.*?\$fnNames = @\((.*?)\)')
if ($match.Success) { $fnNames = @([regex]::Matches($match.Groups[1].Value, "'([^']+)'") | ForEach-Object { $_.Groups[1].Value }) }
Assert-Eq ($fnNames -contains 'Get-ClaudeRowData') 'True' 'worker forwards Get-ClaudeRowData'
Assert-Eq ($entryText -match "'claude' \{ \`$d = Get-ClaudeRowData") 'True' 'worker dispatch handles claude'

if ($failed -gt 0) { Write-Host ("FAILED {0}" -f $failed); exit 1 }
Write-Host 'ALL PASSED'
exit 0
