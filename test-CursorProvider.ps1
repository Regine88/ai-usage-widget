# Encoding: UTF-8 with BOM. Run: powershell -NoProfile -File .\test-CursorProvider.ps1
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $here 'UsageValidation.ps1')
. (Join-Path $here 'WidgetStrings.ps1')
. (Join-Path $here 'WidgetFormat.ps1')
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
    $script:seenMethod = $Method
    return $script:payload
}
function Write-WidgetLog { param([string]$Message) }

$definitions = @()
foreach ($name in @('Get-CursorUsageSnapshot', 'Get-CursorRowData')) {
    $definitions += (Get-ScriptFunctionDefinition $entry $name)
}
$definitions += '$script:CursorUsageUrl = ''https://api2.cursor.sh/aiserver.v1.DashboardService/GetCurrentPeriodUsage'''
$definitions += '$script:CursorDisplayName = ''Cursor'''
. ([ScriptBlock]::Create(($definitions -join [Environment]::NewLine)))

$script:payload = '{"planUsage":{"totalPercentUsed":58,"remaining":840,"limit":2000},"billingCycleEnd":1893456000000,"membershipType":"pro"}' | ConvertFrom-Json
$row = Get-CursorRowData -Auth ([pscustomobject]@{ AccessToken = 'eyJtest' }) -Name 'Cursor'
Assert-Eq $script:seenUri 'https://api2.cursor.sh/aiserver.v1.DashboardService/GetCurrentPeriodUsage' 'cursor hits the period-usage endpoint'
Assert-Eq $script:seenMethod 'Post' 'cursor usage is a POST'
Assert-Eq $row.Percent '58' 'cursor percent is the pool usage'
Assert-Eq ($row.Detail -like 'pro*') 'True' 'cursor detail includes the plan name'

$fnNames = @()
$match = [regex]::Match($entryText, '(?s)function Get-WorkerScriptSource \{.*?\$fnNames = @\((.*?)\)')
if ($match.Success) { $fnNames = @([regex]::Matches($match.Groups[1].Value, "'([^']+)'") | ForEach-Object { $_.Groups[1].Value }) }
Assert-Eq ($fnNames -contains 'Get-CursorRowData') 'True' 'worker forwards Get-CursorRowData'
Assert-Eq ($entryText -match "'cursor' \{ \`$d = Get-CursorRowData") 'True' 'worker dispatch handles cursor'

if ($failed -gt 0) { Write-Host ("FAILED {0}" -f $failed); exit 1 }
Write-Host 'ALL PASSED'
exit 0
