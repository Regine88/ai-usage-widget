# Encoding: UTF-8 with BOM.
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$failed = 0
function Assert-NotMatch {
    param([string]$Text, [string]$Pattern, [string]$Name)
    if ($Text -match $Pattern) {
        Write-Host ("FAIL {0}: matched {1}" -f $Name, $Pattern)
        $script:failed++
    } else {
        Write-Host ("OK   {0}" -f $Name)
    }
}
function Assert-Contains {
    param([string]$Text, [string]$Pattern, [string]$Name)
    if ($Text -notmatch $Pattern) {
        Write-Host ("FAIL {0}: missing {1}" -f $Name, $Pattern)
        $script:failed++
    } else {
        Write-Host ("OK   {0}" -f $Name)
    }
}

$all = Get-ChildItem -LiteralPath $here -File | Where-Object { $_.Extension -in @('.ps1', '.vbs') -and $_.Name -notlike 'test-*' }
$allText = ($all | ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw -Encoding utf8 }) -join "`n"
Assert-NotMatch $allText 'ExecutionPolicy\s*[''\"]?Bypass' 'no execution policy bypass'
Assert-NotMatch $allText 'ssl-no-revoke' 'curl keeps certificate revocation checks'
Assert-NotMatch $allText 'GOCSPX-' 'no hardcoded Gemini client secret'
Assert-NotMatch $allText 'Environment\("PROCESS"\)\("PATH"\)' 'no arbitrary PATH PowerShell lookup'
Assert-NotMatch $allText 'curl\.exe|Invoke-CurlJson' 'no external curl token transport'
Assert-NotMatch (Get-Content -LiteralPath (Join-Path $here 'AiUsageWidget.ps1') -Raw -Encoding utf8) 'Copy-Item[^\r\n]*(chatgpt|grok)-auth' 'no plaintext auth snapshot copy'
Assert-Contains (Get-Content -LiteralPath (Join-Path $here 'ChatGptUsageWidget.ps1') -Raw -Encoding utf8) 'AiUsageWidget\.ps1' 'ChatGPT wrapper targets main widget'
Assert-Contains (Get-Content -LiteralPath (Join-Path $here 'GrokUsageWidget.ps1') -Raw -Encoding utf8) 'AddGrokAccount' 'Grok wrapper preserves provider add-account behavior'
Assert-Contains (Get-Content -LiteralPath (Join-Path $here 'KimiUsageWidget.ps1') -Raw -Encoding utf8) 'AiUsageWidget\.ps1' 'Kimi wrapper targets main widget'
Assert-Contains (Get-Content -LiteralPath (Join-Path $here 'AiUsageWidget.ps1') -Raw -Encoding utf8) '\$AddGrokAccount' 'main widget has Grok add-account switch'
$plainSnapshots = @(Get-ChildItem -LiteralPath $here -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -like 'chatgpt-auth-*.json' -or $_.Name -like 'grok-auth-*.json' })
if ($plainSnapshots.Count -gt 0) {
    Write-Host ("FAIL no plaintext project snapshots: {0}" -f (($plainSnapshots | ForEach-Object Name) -join ', '))
    $failed++
} else {
    Write-Host 'OK   no plaintext project snapshots'
}

if ($failed -gt 0) {
    Write-Host ("FAILED {0}" -f $failed)
    exit 1
}
Write-Host 'ALL PASSED'
exit 0
