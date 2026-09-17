# Encoding: UTF-8 with BOM. Run: powershell -NoProfile -File .\test-ModelRequestRecorder.ps1
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $here 'ModelRequestRecorder.ps1')

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

$path = Join-Path $env:TEMP ('ai-request-recorder-test-' + [guid]::NewGuid().ToString('n') + '.jsonl')
try {
    $started = [datetime]::UtcNow.AddSeconds(-2)
    $finished = [datetime]::UtcNow
    $event = Write-ModelRequestEvent -Provider xai -Model "  grok-4`r`n" `
        -AccountId 'account-a' -RequestId 'request-1' -StartedAt $started `
        -CompletedAt $finished -DurationMs 123.456 -Path $path -Strict
    Assert-Eq $event.provider 'grok' 'provider alias normalized'
    Assert-Eq $event.model 'grok-4' 'model whitespace sanitized'
    Assert-Eq $event.durationMs '123.5' 'duration keeps decimal precision'

    Invoke-RecordedModelRequest -Provider chatgpt -Model gpt-5 -AccountId 'account-b' `
        -Path $path -Action { 'result' } | Out-Null

    try {
        Invoke-RecordedModelRequest -Provider kimi -Model kimi-k2 -Path $path `
            -Action { throw 'synthetic failure' } | Out-Null
        Write-Host 'FAIL failed request should rethrow'
        $failed++
    } catch {
        Write-Host 'OK   failed request rethrows'
    }

    $events = @(Get-ModelRequestEvents -Path $path)
    Assert-Eq $events.Count 3 'event count'
    Assert-Eq $events[1].provider 'codex' 'chatgpt provider normalized'
    Assert-Eq $events[2].status 'failed' 'failed event status'
    Assert-Eq (Get-LatestModelRequest -Path $path -Provider openai -AccountId 'account-b').model 'gpt-5' 'latest request lookup'
    Assert-Eq (@(Get-ModelRequestSummary -Path $path).Count) 3 'summary groups'
    if ($events[0].PSObject.Properties.Name -contains 'prompt') {
        Write-Host 'FAIL event must not contain prompt'
        $failed++
    } else {
        Write-Host 'OK   event excludes prompt'
    }

    $blankEvent = Write-ModelRequestEvent -Provider "  `t" -Model 'gpt-5' -Path $path
    if ($null -ne $blankEvent) {
        Write-Host 'FAIL blank provider should skip non-strict event'
        $failed++
    } else {
        Write-Host 'OK   blank provider skips non-strict event'
    }
    try {
        Write-ModelRequestEvent -Provider '  ' -Model 'gpt-5' -Path $path -Strict | Out-Null
        Write-Host 'FAIL blank provider strict mode should throw'
        $failed++
    } catch {
        if ($_.Exception.Message -notmatch 'provider') {
            Write-Host 'FAIL blank provider strict error should mention provider'
            $failed++
        } else {
            Write-Host 'OK   blank provider strict mode throws clearly'
        }
    }
} finally {
    if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force }
}

if ($failed -gt 0) {
    Write-Host ("FAILED {0}" -f $failed)
    exit 1
}
Write-Host 'ALL PASSED'
exit 0
