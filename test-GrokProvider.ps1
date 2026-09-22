# Encoding: UTF-8. Run: powershell -NoProfile -File .\test-GrokProvider.ps1
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $here 'UsageValidation.ps1')
. (Join-Path $here 'SecureSnapshot.ps1')
. (Join-Path $here 'GrokAccounts.ps1')
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
function Assert-Throws {
    param([scriptblock]$Action, [string]$Name)
    try {
        & $Action
        Write-Host ("FAIL {0}: expected throw" -f $Name)
        $script:failed++
    } catch {
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

$script:payload = $null
function Invoke-GrokGet {
    param($Auth, [string]$Url)
    return $script:payload
}
function Write-WidgetLog {
    param([string]$Message)
}

$entry = Join-Path $here 'AiUsageWidget.ps1'
$definitions = @()
foreach ($name in @('Get-ProductLabel', 'Set-GrokAuthFields', 'Save-GrokAuth', 'Get-GrokUsageSnapshot')) {
    $definitions += (Get-ScriptFunctionDefinition $entry $name)
}
. ([ScriptBlock]::Create(($definitions -join [Environment]::NewLine)))

# Live response shape with an optional product that has no usagePercent.
$script:payload = @'
{
  "config": {
    "currentPeriod": {
      "type": "USAGE_PERIOD_TYPE_WEEKLY",
      "start": "2026-09-22T08:53:56+08:00",
      "end": "2026-09-29T08:53:56+08:00"
    },
    "creditUsagePercent": 6,
    "onDemandCap": { "val": 0 },
    "onDemandUsed": { "val": 0 },
    "productUsage": [
      { "product": "GrokBuild", "usagePercent": 6 },
      { "product": "GrokChat" }
    ],
    "prepaidBalance": { "val": 0 }
  }
}
'@ | ConvertFrom-Json

$usage = Get-GrokUsageSnapshot -Auth ([pscustomobject]@{ ExpiresAt = $null })
Assert-Eq $usage.Percent '6' 'grok keeps the billing percent'
Assert-Eq @($usage.Products).Count '1' 'optional product without usagePercent is skipped'
Assert-Eq $usage.Products[0].Name 'Build' 'product label is retained'
Assert-Eq $usage.Products[0].Percent '6' 'product percent is retained'
Assert-Eq $usage.PeriodEnd.ToUniversalTime().ToString('yyyy-MM-dd') '2026-09-29' 'period end is parsed'

$script:payload = '{"config":{"creditUsagePercent":6,"productUsage":[{"product":"GrokBuild","usagePercent":"bad"}]}}' | ConvertFrom-Json
Assert-Throws { Get-GrokUsageSnapshot -Auth ([pscustomobject]@{ ExpiresAt = $null }) } 'invalid product percent still throws'

$dir = Join-Path $env:TEMP ('grok-writeback-test-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $dir | Out-Null
$oldWidgetDir = $script:WidgetDir
$oldAuthPath = $script:GrokAuthPath
$oldSnapshotRoot = $script:SecureSnapshotRoot
try {
    $script:WidgetDir = $dir
    $script:GrokAuthPath = Join-Path $dir 'auth.json'
    $script:SecureSnapshotRoot = Join-Path $dir 'secure'
    $aliceRaw = [pscustomobject]@{
        'https://auth.x.ai::a' = [pscustomobject]@{ key = 'old-a'; refresh_token = 'refresh-a'; email = 'alice@example.com' }
    }
    [IO.File]::WriteAllText($script:GrokAuthPath, ($aliceRaw | ConvertTo-Json -Depth 6 -Compress), [Text.UTF8Encoding]::new($false))
    $activeA = Read-GrokAuthFromFile -Path $script:GrokAuthPath
    [void](Write-SecureSnapshot -Provider grok -AccountId $activeA.AccountId -Value $activeA.Raw)
    $bobRaw = [pscustomobject]@{
        marker = 'keep-b'
        'https://auth.x.ai::b' = [pscustomobject]@{ key = 'live-b'; refresh_token = 'refresh-b'; email = 'bob@example.org' }
    }
    [IO.File]::WriteAllText($script:GrokAuthPath, ($bobRaw | ConvertTo-Json -Depth 6 -Compress), [Text.UTF8Encoding]::new($false))
    Save-GrokAuth -Auth $activeA -AccessToken 'fresh-a' -RefreshToken 'refresh-a-fresh' -ExpiresAt ([datetime]::UtcNow.AddHours(3))
    $grokLiveAfter = Get-Content -LiteralPath $script:GrokAuthPath -Raw -Encoding utf8 | ConvertFrom-Json
    Assert-Eq $grokLiveAfter.'https://auth.x.ai::b'.key 'live-b' 'Grok account switch keeps the live B token'
    Assert-Eq $grokLiveAfter.marker 'keep-b' 'Grok account switch preserves unrelated live fields'
    $grokSnapA = Read-SecureSnapshot -Path (Get-GrokSnapshotPath $activeA.AccountId)
    Assert-Eq $grokSnapA.'https://auth.x.ai::a'.key 'fresh-a' 'Grok switched refresh is stored in the A snapshot'
} finally {
    $script:WidgetDir = $oldWidgetDir
    $script:GrokAuthPath = $oldAuthPath
    $script:SecureSnapshotRoot = $oldSnapshotRoot
    Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
}

$entryText = Get-Content -LiteralPath $entry -Raw -Encoding utf8
$fnNames = @()
$match = [regex]::Match($entryText, '(?s)function Get-WorkerScriptSource \{.*?\$fnNames = @\((.*?)\)')
if ($match.Success) { $fnNames = @([regex]::Matches($match.Groups[1].Value, "'([^']+)'") | ForEach-Object { $_.Groups[1].Value }) }
Assert-Eq ($fnNames -contains 'Convert-OptionalNumber') 'True' 'worker forwards optional number helper'

if ($failed -gt 0) {
    Write-Host ("FAILED {0}" -f $failed)
    exit 1
}
Write-Host 'ALL PASSED'
exit 0
