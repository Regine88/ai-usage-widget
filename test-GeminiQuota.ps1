# Encoding: UTF-8 with BOM.
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $here 'GeminiAntigravity.ps1')

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

$raw = @{
    groups = @(
        @{
            displayName = 'Gemini Models'
            description = 'Models within this group: Gemini Flash, Gemini Pro'
            buckets = @(
                @{ bucketId = 'gemini-weekly'; window = 'weekly'; remainingFraction = 0.4; resetTime = '2026-09-01T13:54:23Z' }
                @{ bucketId = 'gemini-5h'; window = '5h'; remainingFraction = 0.85; resetTime = '2026-08-25T18:54:23Z' }
            )
        },
        @{
            displayName = 'Claude / GPT'
            buckets = @(
                @{ bucketId = '3p-weekly'; remainingFraction = 1 }
            )
        }
    )
} | ConvertTo-Json -Depth 8 | ConvertFrom-Json

$q = Convert-GeminiQuota $raw
Assert-Eq ([Math]::Round($q.Remaining, 1)) '40' 'remaining uses tighter bucket'
Assert-Eq ([Math]::Round($q.Used, 1)) '60' 'used is complement of remaining'
Assert-Eq ([Math]::Round($q.Remain5h, 1)) '85' '5h remaining'
Assert-Eq ([Math]::Round($q.RemainWeekly, 1)) '40' 'weekly remaining'
Assert-Eq $q.PeriodEnd.ToUniversalTime().ToString('yyyy-MM-dd') '2026-09-01' 'reset follows tighter bucket'

$full = @{
    groups = @(
        @{
            displayName = 'Gemini Models'
            buckets = @(
                @{ bucketId = 'gemini-weekly'; window = 'weekly'; remainingFraction = 1; resetTime = '2026-09-01T13:54:23Z' }
                @{ bucketId = 'gemini-5h'; window = '5h'; remainingFraction = 1; resetTime = '2026-08-25T18:54:23Z' }
            )
        }
    )
} | ConvertTo-Json -Depth 8 | ConvertFrom-Json
$q2 = Convert-GeminiQuota $full
Assert-Eq ([Math]::Round($q2.Remaining, 1)) '100' 'full remaining'
Assert-Eq ([Math]::Round($q2.Used, 1)) '0' 'full used'

try {
    Convert-GeminiQuota (@{ groups = @() } | ConvertTo-Json | ConvertFrom-Json)
    Write-Host 'FAIL missing gemini group should throw'
    $failed++
} catch {
    Write-Host 'OK   missing gemini group throws'
}

if ($failed -gt 0) {
    Write-Host ("FAILED {0}" -f $failed)
    exit 1
}
Write-Host 'ALL PASSED'
exit 0
