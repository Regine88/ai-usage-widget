# Encoding: UTF-8 with BOM. Run: powershell -NoProfile -File .\test-ZaiProvider.ps1
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $here 'UsageValidation.ps1')
. (Join-Path $here 'WidgetConfig.ps1')
. (Join-Path $here 'ApiKeyAuth.ps1')
. (Join-Path $here 'WidgetStrings.ps1')
. (Join-Path $here 'WidgetFormat.ps1')
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
function Invoke-WidgetRest {
    param($Method, $Uri, $Headers, $Body, $ContentType, $TimeoutSec)
    $script:seenUri = $Uri
    $script:seenAuth = $Headers['Authorization']
    return $script:payload
}
function Write-WidgetLog { param([string]$Message) }

$definitions = @()
foreach ($name in @('Get-ZaiResolvedAuthPath', 'Get-ZaiEnvironmentKey', 'Get-ZaiResolvedBaseUrl', 'Get-ZaiAuthHeaders', 'Get-ZaiUsageSnapshot', 'Get-ZaiRowData')) {
    $definitions += (Get-ScriptFunctionDefinition $entry $name)
}
$definitions += '$script:ZaiAuthPath = ''no-such-zai.json'''
$definitions += '$script:ZhipuAuthPath = ''no-such-zhipu.json'''
$definitions += '$script:ZaiApiBaseUrl = ''https://api.z.ai'''
$definitions += '$script:ZhipuApiBaseUrl = ''https://open.bigmodel.cn'''
$definitions += '$script:ZaiDisplayName = ''GLM'''
. ([ScriptBlock]::Create(($definitions -join [Environment]::NewLine)))

$script:payload = '{"data":{"level":"pro","limits":[{"type":"TOKENS_FIVE_HOURS","percentage":8},{"type":"TOKENS_SEVEN_DAYS","percentage":22}]}}' | ConvertFrom-Json
$row = Get-ZaiRowData -Auth ([pscustomobject]@{ ApiKey = 'zai-test-key' }) -Name 'GLM'
Assert-Eq $script:seenUri 'https://api.z.ai/api/monitor/usage/quota/limit' 'glm hits the monitor quota endpoint'
Assert-Eq $script:seenAuth 'zai-test-key' 'glm sends the raw key without Bearer'
Assert-Eq $row.Percent '22' 'glm percent follows the tighter window'
Assert-Eq ($row.Detail -like 'pro*') 'True' 'glm detail includes the plan level'

$fnNames = @()
$match = [regex]::Match($entryText, '(?s)function Get-WorkerScriptSource \{.*?\$fnNames = @\((.*?)\)')
if ($match.Success) { $fnNames = @([regex]::Matches($match.Groups[1].Value, "'([^']+)'") | ForEach-Object { $_.Groups[1].Value }) }
Assert-Eq ($fnNames -contains 'Get-ZaiRowData') 'True' 'worker forwards Get-ZaiRowData'
Assert-Eq ($entryText -match "'glm' \{ \`$d = Get-ZaiRowData") 'True' 'worker dispatch handles glm'

if ($failed -gt 0) { Write-Host ("FAILED {0}" -f $failed); exit 1 }
Write-Host 'ALL PASSED'
exit 0
